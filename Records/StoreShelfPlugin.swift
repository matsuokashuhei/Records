//
//  StoreShelfPlugin.swift
//  Records
//
//  プラグイン「レコード店の棚」(構造系、shelfStyle=.store)。
//  レコード店の壁面陳列棚を再現する支え構造: 各行の黒い水平棚板
//  + 棚板手前端に立つ透明アクリルの前柵。
//  壁と経年表現はスタイル非依存のWallPluginが担当する
//  (このプラグインを無効にしても壁は残る。壁も消したい場合は
//   設定画面でWallを無効にする)。
//  ジャケットの後傾(立てかけ)は Lean Depth プラグインが担当する。
//
//  座標はすべて「padding適用済みグリッドの左上原点」
//  (=ShelfStructureContextの定義するフレーム)で計算する。
//   - 棚板: 行rのセル下端 y = topPadding + (r+1)*cell + r*rowSpacing
//     を天面とし、両端に columnSpacing/2 の余白を持つ水平な板。
//     厚さは設定値を
//     min(設定値, rowSpacing-2, bottomPadding) にクランプして
//     行間と下端余白に収める(bottomPaddingはrowSpacingの導出値
//     なので、実質 min(設定値, rowSpacing-2))。
//     天面に1ptの明るい稜線、
//     下端から下へ壁への落ち影(黒0.22→0)を付ける
//   - 前柵: 棚板の手前に立つ透明アクリルのストリップ。
//     高さ=セル高さ×fence比率(既定0.22≒1/5)。上端=セル下端-高さ、
//     下端=セル下端+板厚*0.6(板の手前面に少し重なる)。
//     実物のアクリル(PMMA)は透過率~92%で面自体はほぼ見えず、
//     照明の映り込みとエッジの発光(内部を導光した光が切断面から
//     漏れ、コーナーに集まる)で存在がわかる。
//     再現は 本体の淡い帯 + 上端から下へ消える映り込み帯 +
//     上端の1pt明線と滲み + 両コーナーの集光 + 下端/左右端の明線。
//     見え方の強さは設定の「前柵のエッジ」(上端のopacity。
//     本体・映り込み・下端・左右端・コーナーは固定比率で連動。
//     0なら柵は完全に不可視)で、輝度のムラは「前柵のばらつき」
//     (長手方向の波ノイズ+段ごとの個体差)で調整できる
//
//  オーバーレイは合成側(ShelfView.shelfGrid)が
//  .allowsHitTesting(false) で重ねるので、再生タップ・D&D・
//  右クリックメニュー・ドロップゾーンは従来通り動く。
//  shelfStyle=.storeが選択されていないときはレジストリの
//  resolveShelfで除外される。
//  未保存時の既定は有効(defaultEnabled=true。構造系なので
//  最初から棚らしい見た目にする)。
//

import SwiftUI
import os

struct StoreShelfPlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Records", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)
    private enum Param {
        /// 棚板の色。選択肢idの文字列で永続化
        static let board = "board"
        /// 棚板の厚さ(pt)
        static let boardThickness = "board-thickness"
        /// 前柵の高さ(セル高さに対する比率0〜0.40)
        static let fenceHeight = "fence-height"
        /// 前柵(アクリル板)の見え方の強さ=上端エッジのopacity。
        /// 板の映り込み(透明度)・下端/左右端エッジ・コーナーの
        /// 集光はすべて上端に対する固定比率で連動する
        static let fenceEdge = "fence-edge"
        /// 前柵のばらつき(0-1)。アクリル板の明るさを長手方向に
        /// ゆらがせ、段ごとの個体差も付ける(実物の切断面の
        /// 発光は磨きムラで均一でない)
        static let fenceVariation = "fence-variation"
    }

    /// 棚板の色。rawValueは永続化値
    private enum Board: String, CaseIterable {
        /// 黒い棚板(写真の再現)
        case black
        /// 暗い茶系(ウォールナット)
        case walnut

        var label: String {
            switch self {
            case .black: return "Black"
            case .walnut: return "Walnut"
            }
        }

        /// 上端がわずかに明るい縦グラデーション(天面が光を拾う)
        var gradient: Gradient {
            switch self {
            case .black:
                return Gradient(colors: [
                    Color(red: 0x26/255, green: 0x26/255, blue: 0x2A/255),
                    Color(red: 0x10/255, green: 0x10/255, blue: 0x14/255),
                ])
            case .walnut:
                return Gradient(colors: [
                    Color(red: 0x5A/255, green: 0x44/255, blue: 0x30/255),
                    Color(red: 0x38/255, green: 0x29/255, blue: 0x1C/255),
                ])
            }
        }
    }

    /// デフォルト値
    private static let defaultBoard = Board.black
    static let defaultBoardThickness: Double = 7
    static let defaultFenceHeight: Double = 0.22
    /// 前柵エッジの既定の強さ(上端エッジのopacity)
    static let defaultFenceEdge: Double = 0.40
    /// 前柵のばらつきの既定値(0-1)
    static let defaultFenceVariation: Double = 0.5

    /// 板の落ち影の長さ(pt)と濃さ。行間/下端余白に収まる分だけ描く
    private static let shadowLength: CGFloat = 5
    private static let shadowOpacity: Double = 0.22
    /// 落ち影をグラデーションで描ける最小の余白(pt)。これ未満の行
    /// (実質: 最終行で板が下端余白いっぱいのとき)は影を描かず、
    /// 代わりに板の下端へ暗い1pt線を入れて縁を締める
    private static let shadowMinGap: CGFloat = 3
    /// 余白不足時に板の下端へ入れる暗い線の濃さ
    private static let boardBottomLineOpacity: Double = 0.25
    /// 板の天面エッジの明るい線(天面が光を拾う表現)
    private static let boardEdgeOpacity: Double = 0.12
    /// 前柵の本体の白さ(上端エッジ強さに対する比率)。
    /// 実物のアクリルは透過率~92%で面自体はほぼ見えず、
    /// 照明の映り込みとエッジの発光で存在がわかる。
    /// 本体はエッジ強さ×この比率の淡さに留める
    private static let fenceBodyTopRatio: Double = 0.15
    private static let fenceBodyMidRatio: Double = 0.05
    private static let fenceBodyBottomRatio: Double = 0.125
    /// 映り込み帯: 照明がアクリル面に斜めに映る、上端から
    /// 下へ消える柔らかいハイライト。強さは上端エッジ×0.3、
    /// 深さは柵の高さの45%
    private static let fenceSheenRatio: Double = 0.3
    private static let fenceSheenDepth: Double = 0.45
    /// 上端エッジの滲み(発光が周囲に漏れる2ptのフェード)
    private static let fenceEdgeGlowRatio: Double = 0.35
    private static let fenceEdgeGlowWidth: CGFloat = 2
    /// 上端の両コーナーの集光(導光が角に集まり点状に明るくなる)。
    /// 上端エッジ×1.25、幅2.5pt
    private static let fenceCornerRatio: Double = 1.25
    private static let fenceCornerWidth: CGFloat = 2.5
    /// 前柵の下端エッジの強さ(上端エッジに対する比率)
    private static let fenceBottomEdgeRatio: Double = 0.30
    /// 前柵の左右端の縦ハイライトの強さ(上端エッジに対する比率)と幅
    private static let fenceSideEdgeRatio: Double = 0.625
    private static let fenceSideEdgeWidth: CGFloat = 1.5

    let id = "store-shelf"
    let displayName = "Store Shelf"
    /// 構造系プラグインは既定で有効(最初から棚らしい見た目にする)
    let defaultEnabled = true
    /// 通し棚板+前柵はstoreスタイルの支え構造
    let shelfStyle: ShelfSettings.ShelfStyle? = .store

    init() {
        Self.logger.info("plugin registered: store-shelf ('Store Shelf')")
    }

    var parameterSpecs: [PluginParameterSpec] {
        [
            .options(.init(
                id: Param.board,
                label: "Board",
                choices: Board.allCases.map {
                    .init(id: $0.rawValue, label: $0.label)
                },
                defaultValue: Self.defaultBoard.rawValue
            )),
            .slider(.init(
                id: Param.boardThickness,
                label: "Board Thickness",
                range: 4...20,
                step: 1,
                defaultValue: Self.defaultBoardThickness
            )),
            .slider(.init(
                id: Param.fenceHeight,
                label: "Fence Height",
                range: 0...0.40,
                step: 0.01,
                defaultValue: Self.defaultFenceHeight
            )),
            .slider(.init(
                id: Param.fenceEdge,
                label: "Fence Edge",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultFenceEdge
            )),
            .slider(.init(
                id: Param.fenceVariation,
                label: "Fence Variation",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultFenceVariation
            )),
        ]
    }

    // MARK: - (f) グリッド前面(棚板+前柵)

    func shelfOverlay(context: ShelfStructureContext) -> AnyView? {
        let board = resolvedBoard(context: context)
        let t = resolvedThickness(context: context)
        let fenceRatio = resolvedFenceHeight(context: context)
        let fenceEdge = resolvedFenceEdge(context: context)
        let fenceVar = resolvedFenceVariation(context: context)
        let cell = context.cellSize
        logAppliedOnce(
            board: board, thickness: t, fence: fenceRatio,
            edge: fenceEdge, variation: fenceVar, rows: context.gridRows)
        // 板も柵も描くものが無ければオーバーレイ自体を返さない
        // (無効時と同じく描画の影響ゼロにする)
        guard t > 0 || fenceRatio > 0 else { return nil }

        // 棚板両端の余白: レコード間隔(columnSpacing)の半分。
        // 板・天面エッジ・落ち影・下端線・前柵はすべてこの横幅に
        // 揃える(前柵は板の上に立つ部材なので板より外へ出さない)
        let endMargin = context.columnSpacing / 2

        // 行rのセル下端y(padding込みフレーム座標)
        let bottoms = (0..<context.gridRows).map { r in
            context.topPadding
                + CGFloat(r + 1) * cell
                + CGFloat(r) * context.rowSpacing
        }
        let lastGap = max(0, context.bottomPadding - t)

        return AnyView(
            Canvas { gc, size in
                guard size.width > 0, size.height > 0 else { return }
                let boardMinX = endMargin
                let boardMaxX = size.width - endMargin
                let boardWidth = max(0, boardMaxX - boardMinX)
                for (r, bottom) in bottoms.enumerated() {
                    if t > 0 {
                        // 棚板: セル下端を天面として下方向へt延びる板。
                        // 両端はendMarginだけ壁際から離す
                        let boardRect = CGRect(
                            x: boardMinX, y: bottom,
                            width: boardWidth, height: t)
                        gc.fill(
                            Path(boardRect),
                            with: .linearGradient(
                                board.gradient,
                                startPoint: CGPoint(x: 0, y: boardRect.minY),
                                endPoint: CGPoint(x: 0, y: boardRect.maxY)))
                        // 天面エッジ: 板上端の1ptの明るい線
                        gc.fill(
                            Path(CGRect(
                                x: boardMinX, y: bottom,
                                width: boardWidth, height: 1)),
                            with: .color(.white.opacity(Self.boardEdgeOpacity)))
                        // 落ち影: 板の下端から下へ 黒0.22→0。
                        // 板の下の余白(行間または下端余白から板厚を
                        // 引いた分)が3pt未満の行は影を描かず、板の下端に
                        // 1ptの暗い線を入れて縁を締める
                        // (最終行は余白いっぱいなので影が残りにくい)
                        let gap = (r == bottoms.count - 1)
                            ? lastGap
                            : context.rowSpacing - t
                        if gap >= Self.shadowMinGap {
                            let shadowLen = min(Self.shadowLength, gap)
                            let shadowRect = CGRect(
                                x: boardMinX, y: bottom + t,
                                width: boardWidth, height: shadowLen)
                            gc.fill(
                                Path(shadowRect),
                                with: .linearGradient(
                                    Gradient(colors: [
                                        .black.opacity(Self.shadowOpacity),
                                        .clear,
                                    ]),
                                    startPoint: CGPoint(
                                        x: 0, y: shadowRect.minY),
                                    endPoint: CGPoint(
                                        x: 0, y: shadowRect.maxY)))
                        } else {
                            gc.fill(
                                Path(CGRect(
                                    x: boardMinX, y: bottom + t - 1,
                                    width: boardWidth, height: 1)),
                                with: .color(.black.opacity(
                                    Self.boardBottomLineOpacity)))
                        }
                    }
                    if fenceRatio > 0 && fenceEdge > 0 {
                        // 前柵: 棚板の手前に立つ透明アクリルのストリップ。
                        // 下端は板の手前面へ少し重なる(t*0.6)
                        let f = fenceRatio * cell
                        let fenceRect = CGRect(
                            x: boardMinX, y: bottom - f,
                            width: boardWidth, height: f + t * 0.6)
                        // ばらつき: 各段のアクリル板は別個体なので
                        // 明るさが段ごとにわずかに違い(±variation*25%)、
                        // 長手方向は波ノイズで輝度がゆらぐ(切断面の
                        // 発光は磨きムラで均一でない)。
                        // variation=0 なら係数1=従来の均一な面
                        let rowVar = 1 + (Self.rowHash(r, salt: 6) - 0.5)
                            * fenceVar * 0.5
                        let e = min(1, fenceEdge * rowVar)
                        let rowSalt = Double(r) * 3.7

                        // 本体(透明度)+映り込み帯: 縦ストリップに
                        // 分け、帯ごとの係数を長手方向の波で揺らす
                        let segments = 20
                        let segW = boardWidth / CGFloat(segments)
                        for i in 0..<segments {
                            let x0 = boardMinX + CGFloat(i) * segW
                            let m = fenceVar > 0
                                ? 1 + (Self.wave01(
                                        x: x0 + segW * 0.5,
                                        salt: 9 + rowSalt) - 0.5)
                                    * fenceVar * 1.2
                                : 1
                            let strip = CGRect(
                                x: x0, y: fenceRect.minY,
                                width: segW, height: fenceRect.height)
                            // 本体: 透過率の高い板なので面はごく淡く
                            gc.fill(
                                Path(strip),
                                with: .linearGradient(
                                    Gradient(stops: [
                                        .init(
                                            color: .white.opacity(
                                                e * Self.fenceBodyTopRatio * m),
                                            location: 0),
                                        .init(
                                            color: .white.opacity(
                                                e * Self.fenceBodyMidRatio * m),
                                            location: 0.5),
                                        .init(
                                            color: .white.opacity(
                                                e * Self.fenceBodyBottomRatio * m),
                                            location: 1),
                                    ]),
                                    startPoint: CGPoint(
                                        x: 0, y: strip.minY),
                                    endPoint: CGPoint(
                                        x: 0, y: strip.maxY)))
                            // 映り込み帯: 照明がアクリル面に斜めに映る
                            // 柔らかいハイライト。上端から柵高の45%で消える
                            let sheen = CGRect(
                                x: x0, y: fenceRect.minY, width: segW,
                                height: fenceRect.height * Self.fenceSheenDepth)
                            gc.fill(
                                Path(sheen),
                                with: .linearGradient(
                                    Gradient(colors: [
                                        .white.opacity(
                                            e * Self.fenceSheenRatio * m),
                                        .clear,
                                    ]),
                                    startPoint: CGPoint(
                                        x: 0, y: sheen.minY),
                                    endPoint: CGPoint(
                                        x: 0, y: sheen.maxY)))
                        }

                        // 上端エッジ: 1ptの白線(アクリル切断面の発光)。
                        // 輝度は長手方向にゆらがせる(波ノイズを
                        // 水平グラデーションのstopで表現)
                        let edgeSegs = 12
                        var edgeStops: [Gradient.Stop] = []
                        edgeStops.reserveCapacity(edgeSegs + 1)
                        for i in 0...edgeSegs {
                            let fx = CGFloat(i) / CGFloat(edgeSegs)
                            let m = fenceVar > 0
                                ? 0.65 + 0.7 * Self.wave01(
                                    x: fx * boardWidth, salt: 11 + rowSalt)
                                : 1
                            edgeStops.append(.init(
                                color: .white.opacity(min(1, e * m)),
                                location: fx))
                        }
                        let edgeLine = CGRect(
                            x: boardMinX, y: fenceRect.minY,
                            width: boardWidth, height: 1)
                        gc.fill(
                            Path(edgeLine),
                            with: .linearGradient(
                                Gradient(stops: edgeStops),
                                startPoint: CGPoint(x: boardMinX, y: 0),
                                endPoint: CGPoint(
                                    x: boardMaxX, y: 0)))
                        // 滲み: エッジの光が周囲に漏れる2ptのフェード。
                        // エッジと同じゆらぎを弱く写す
                        let glowRect = CGRect(
                            x: boardMinX, y: fenceRect.minY + 1,
                            width: boardWidth,
                            height: Self.fenceEdgeGlowWidth)
                        gc.fill(
                            Path(glowRect),
                            with: .linearGradient(
                                Gradient(stops: edgeStops.map {
                                    .init(
                                        color: $0.color.opacity(
                                            Self.fenceEdgeGlowRatio),
                                        location: $0.location)
                                }),
                                startPoint: CGPoint(
                                    x: 0, y: glowRect.minY),
                                endPoint: CGPoint(
                                    x: 0, y: glowRect.maxY)))
                        // 上端の両コーナー: 導光が角に集まり点状に
                        // 明るくなる集光(上端エッジより強い)
                        let cw = Self.fenceCornerWidth
                        let cornerOpacity = min(1, e * Self.fenceCornerRatio)
                        for x in [boardMinX, boardMaxX - cw] {
                            gc.fill(
                                Path(CGRect(
                                    x: x, y: fenceRect.minY,
                                    width: cw, height: cw)),
                                with: .color(.white.opacity(cornerOpacity)))
                        }
                        // 下端エッジ: 上端より弱い1ptの白線
                        gc.fill(
                            Path(CGRect(
                                x: boardMinX, y: fenceRect.maxY - 1,
                                width: boardWidth, height: 1)),
                            with: .color(.white.opacity(
                                e * Self.fenceBottomEdgeRatio)))
                        // 左右端: 端面の反射の縦ハイライト
                        let side = e * Self.fenceSideEdgeRatio
                        let w = Self.fenceSideEdgeWidth
                        gc.fill(
                            Path(CGRect(
                                x: boardMinX, y: fenceRect.minY,
                                width: w, height: fenceRect.height)),
                            with: .color(.white.opacity(side)))
                        gc.fill(
                            Path(CGRect(
                                x: boardMaxX - w, y: fenceRect.minY,
                                width: w, height: fenceRect.height)),
                            with: .color(.white.opacity(side)))
                    }
                }
            }
            // 棚板・前柵がジャケットのタップ再生・D&D・右クリック・
            // ドロップゾーンのヒット判定を食わないようにする(必須)
            .allowsHitTesting(false)
        )
    }

    // MARK: - パラメータ解決

    /// 実厚。設定値を行間(rowSpacing-2)と下端余白(bottomPadding)に
    /// 収まるようクランプする。bottomPaddingはrowSpacingの導出値なので
    /// 実質 rowSpacing-2 が上限(rowSpacing=0では0になる)
    private func resolvedThickness(context: ShelfStructureContext) -> CGFloat {
        let raw = context.number(
            Param.boardThickness, default: Self.defaultBoardThickness)
        return max(0, min(raw, context.rowSpacing - 2, context.bottomPadding))
    }

    /// 前柵の高さ比(0〜0.40)。0なら柵を描かない
    private func resolvedFenceHeight(context: ShelfStructureContext) -> Double {
        min(0.40, max(0,
            context.number(Param.fenceHeight, default: Self.defaultFenceHeight)))
    }

    /// 前柵のばらつき(0-1)。長手方向の輝度のゆらぎと
    /// 段ごとの個体差の強さ。0なら従来の均一な面
    private func resolvedFenceVariation(context: ShelfStructureContext) -> Double {
        min(1, max(0,
            context.number(
                Param.fenceVariation, default: Self.defaultFenceVariation)))
    }

    /// 長手方向の滑らかな疑似ノイズ(0〜1)。長波長のsin波の
    /// 積で作る連続値 — アクリル板の明るさのゆらぎに使う。
    /// saltで系列を変える(行ごとに別パターンにするため行番号を混ぜる)
    private static func wave01(x: CGFloat, salt: Double) -> Double {
        let p = Double(x)
        let v = sin(p * 0.011 + salt * 13.1) * sin(p * 0.029 + salt * 7.7)
        return (v + 1) / 2
    }

    /// 行番号から決める固定のばらつき係数(0〜1)。
    /// 「各段のアクリル板は別個体」という明るさ差に使う
    /// (sinハッシュ。乱数生成器や状態は持たない)
    private static func rowHash(_ row: Int, salt: Double) -> Double {
        let v = sin(Double(row) * 127.1 + salt * 311.7) * 43758.5453
        return v - v.rounded(.down)
    }


    /// 前柵(アクリル板)の見え方の強さ(0〜1)。上端エッジの
    /// opacityそのもの。本体(透明度)・映り込み・下端/左右端・
    /// コーナー集光は固定比率で連動する
    private func resolvedFenceEdge(context: ShelfStructureContext) -> Double {
        min(1, max(0,
            context.number(Param.fenceEdge, default: Self.defaultFenceEdge)))
    }

    private func resolvedBoard(context: ShelfStructureContext) -> Board {
        let raw = context.text(Param.board, default: Self.defaultBoard.rawValue)
        return Board(rawValue: raw) ?? Self.defaultBoard
    }

    /// プロセス内で最初の1回だけ解決値を記録する
    /// (描画のたびに呼ばれるので、毎回ログは出さない。
    ///  有効/無効とパラメータ確定のログはSettingsView側が出す)
    private static var didLogApplied = false
    private func logAppliedOnce(board: Board, thickness: CGFloat,
                                fence: Double, edge: Double,
                                variation: Double, rows: Int) {
        guard !Self.didLogApplied else { return }
        Self.didLogApplied = true
        Self.logger.notice("store-shelf applied: board=\(board.rawValue, privacy: .public) thickness=\(thickness, privacy: .public) fence=\(fence, privacy: .public) edge=\(edge, privacy: .public) variation=\(variation, privacy: .public) rows=\(rows, privacy: .public)")
    }
}
