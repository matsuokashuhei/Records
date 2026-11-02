//
//  StoreShelfPlugin.swift
//  Records
//
//  プラグイン「レコード店の棚」(構造系)。
//  レコード店の壁面陳列棚の写真を再現する: クリーム色の壁 +
//  各行の黒い水平棚板 + 棚板手前端に立つ透明アクリルの前柵。
//  ジャケットの後傾(立てかけ)は既存の Lean Depth プラグインが
//  担当するので、ここでは棚レベルフックで壁(shelfBackdrop)と
//  棚板+前柵(shelfOverlay)を描く。
//
//  座標はすべて「padding適用済みグリッドの左上原点」
//  (=ShelfStructureContextの定義するフレーム)で計算する。
//   - 壁: フレーム全面を覆う、上がわずかに明るい暖色の縦
//     グラデーション(天井からの光)
//   - 棚板: 行rのセル下端 y = topPadding + (r+1)*cell + r*rowSpacing
//     を天面とする全幅の水平な板。厚さは設定値を
//     min(設定値, rowSpacing-2, edgePadding) にクランプして
//     行間と下端余白に収める。天面に1ptの明るい稜線、
//     下端から下へ壁への落ち影(黒0.22→0)を付ける
//   - 前柵: 棚板の手前に立つ透明アクリルのストリップ。
//     高さ=セル高さ×fence比率(既定0.22≒1/5)。上端=セル下端-高さ、
//     下端=セル下端+板厚*0.6(板の手前面に少し重なる)。
//     本体はごく淡い白の縦グラデ、上下端の白線(切断面の発光)と
//     左右端の縦ハイライト(端面の反射)で素材感を出す。
//     エッジの強さは設定の「前柵のエッジ」(上端のopacity。
//     下端・左右端は固定比率で連動)で調整できる
//
//  オーバーレイは合成側(ShelfView.shelfGrid)が
//  .allowsHitTesting(false) で重ねるので、再生タップ・D&D・
//  右クリックメニュー・ドロップゾーンは従来通り動く。
//  無効時はレジストリのresolveShelfで除外され、従来の見た目
//  (壁・板・柵なし)と完全に同じになる。
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
        /// 壁の色。選択肢idの文字列で永続化
        static let wall = "wall"
        /// 棚板の色。選択肢idの文字列で永続化
        static let board = "board"
        /// 棚板の厚さ(pt)
        static let boardThickness = "board-thickness"
        /// 前柵の高さ(セル高さに対する比率0〜0.40)
        static let fenceHeight = "fence-height"
        /// 前柵のエッジ(切断面の発光)の強さ=上端エッジのopacity。
        /// 下端・左右端は上端に対する固定比率で連動する
        static let fenceEdge = "fence-edge"
    }

    /// 壁の色。rawValueはsettings.jsonへの永続化値なので
    /// 一度決めたら変更しない
    private enum Wall: String, CaseIterable {
        /// 暖色クリーム(レコード店の壁)
        case cream
        /// ニュートラルな暖灰
        case warmGray = "warm-gray"
        /// 暗色
        case charcoal

        /// 表示ラベル(Localizable.xcstringsのキー)
        var label: String {
            switch self {
            case .cream: return "Cream"
            case .warmGray: return "Warm Gray"
            case .charcoal: return "Charcoal"
            }
        }

        /// 上がわずかに明るい縦グラデーション
        var gradient: Gradient {
            switch self {
            case .cream:
                return Gradient(colors: [
                    Color(red: 0xF2/255, green: 0xEB/255, blue: 0xDD/255),
                    Color(red: 0xE3/255, green: 0xD8/255, blue: 0xC3/255),
                ])
            case .warmGray:
                return Gradient(colors: [
                    Color(red: 0xB8/255, green: 0xB0/255, blue: 0xA4/255),
                    Color(red: 0x9F/255, green: 0x97/255, blue: 0x8B/255),
                ])
            case .charcoal:
                return Gradient(colors: [
                    Color(red: 0x3E/255, green: 0x3E/255, blue: 0x44/255),
                    Color(red: 0x28/255, green: 0x28/255, blue: 0x2E/255),
                ])
            }
        }
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
    private static let defaultWall = Wall.cream
    private static let defaultBoard = Board.black
    static let defaultBoardThickness: Double = 7
    static let defaultFenceHeight: Double = 0.22
    /// 前柵エッジの既定の強さ(上端エッジのopacity)
    static let defaultFenceEdge: Double = 0.40

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
    /// 前柵の本体の白さ(上端→中央→下端のopacity)。
    /// アクリルは面ではなくエッジで見せるので本体はごく淡く
    private static let fenceTopOpacity: Double = 0.06
    private static let fenceMidOpacity: Double = 0.02
    private static let fenceBottomOpacity: Double = 0.05
    /// 前柵の下端エッジの強さ(上端エッジに対する比率)
    private static let fenceBottomEdgeRatio: Double = 0.30
    /// 前柵の左右端の縦ハイライトの強さ(上端エッジに対する比率)と幅
    private static let fenceSideEdgeRatio: Double = 0.625
    private static let fenceSideEdgeWidth: CGFloat = 1.5

    let id = "store-shelf"
    let displayName = "Store Shelf"
    /// 構造系プラグインは既定で有効(最初から棚らしい見た目にする)
    let defaultEnabled = true

    init() {
        Self.logger.info("plugin registered: store-shelf ('Store Shelf')")
    }

    var parameterSpecs: [PluginParameterSpec] {
        [
            .options(.init(
                id: Param.wall,
                label: "Wall",
                choices: Wall.allCases.map {
                    .init(id: $0.rawValue, label: $0.label)
                },
                defaultValue: Self.defaultWall.rawValue
            )),
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
                range: 4...10,
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
        ]
    }

    // MARK: - (e) グリッド背面(壁)

    func shelfBackdrop(context: ShelfStructureContext) -> AnyView? {
        let wall = resolvedWall(context: context)
        // 背面なのでセルのヒット判定には影響しないが、空き領域への
        // タップを壁が食わないよう保険を掛けておく
        return AnyView(
            LinearGradient(
                gradient: wall.gradient,
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        )
    }

    // MARK: - (f) グリッド前面(棚板+前柵)

    func shelfOverlay(context: ShelfStructureContext) -> AnyView? {
        let board = resolvedBoard(context: context)
        let t = resolvedThickness(context: context)
        let fenceRatio = resolvedFenceHeight(context: context)
        let fenceEdge = resolvedFenceEdge(context: context)
        let cell = context.cellSize
        // 板も柵も描くものが無ければオーバーレイ自体を返さない
        // (無効時と同じく描画の影響ゼロにする)
        guard t > 0 || fenceRatio > 0 else { return nil }

        // 行rのセル下端y(padding込みフレーム座標)
        let bottoms = (0..<context.gridRows).map { r in
            context.topPadding
                + CGFloat(r + 1) * cell
                + CGFloat(r) * context.rowSpacing
        }
        let lastGap = max(0, context.edgePadding - t)
        logAppliedOnce(
            wall: resolvedWall(context: context), board: board,
            thickness: t, fence: fenceRatio, edge: fenceEdge,
            rows: context.gridRows)

        return AnyView(
            Canvas { gc, size in
                guard size.width > 0, size.height > 0 else { return }
                for (r, bottom) in bottoms.enumerated() {
                    if t > 0 {
                        // 棚板: セル下端を天面として下方向へt延びる全幅の板
                        let boardRect = CGRect(
                            x: 0, y: bottom,
                            width: size.width, height: t)
                        gc.fill(
                            Path(boardRect),
                            with: .linearGradient(
                                board.gradient,
                                startPoint: CGPoint(x: 0, y: boardRect.minY),
                                endPoint: CGPoint(x: 0, y: boardRect.maxY)))
                        // 天面エッジ: 板上端の1ptの明るい線
                        gc.fill(
                            Path(CGRect(
                                x: 0, y: bottom, width: size.width, height: 1)),
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
                                x: 0, y: bottom + t,
                                width: size.width, height: shadowLen)
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
                                    x: 0, y: bottom + t - 1,
                                    width: size.width, height: 1)),
                                with: .color(.black.opacity(
                                    Self.boardBottomLineOpacity)))
                        }
                    }
                    if fenceRatio > 0 {
                        // 前柵: 棚板の手前に立つ透明アクリルのストリップ。
                        // 下端は板の手前面へ少し重なる(t*0.6)
                        let f = fenceRatio * cell
                        let fenceRect = CGRect(
                            x: 0, y: bottom - f,
                            width: size.width, height: f + t * 0.6)
                        // 本体: ごく淡い白の縦グラデ
                        gc.fill(
                            Path(fenceRect),
                            with: .linearGradient(
                                Gradient(stops: [
                                    .init(
                                        color: .white.opacity(Self.fenceTopOpacity),
                                        location: 0),
                                    .init(
                                        color: .white.opacity(Self.fenceMidOpacity),
                                        location: 0.5),
                                    .init(
                                        color: .white.opacity(Self.fenceBottomOpacity),
                                        location: 1),
                                ]),
                                startPoint: CGPoint(
                                    x: 0, y: fenceRect.minY),
                                endPoint: CGPoint(
                                    x: 0, y: fenceRect.maxY)))
                        // 上端エッジ: 1ptの白線(アクリル切断面の発光)
                        gc.fill(
                            Path(CGRect(
                                x: 0, y: fenceRect.minY,
                                width: size.width, height: 1)),
                            with: .color(.white.opacity(fenceEdge)))
                        // 下端エッジ: 上端より弱い1ptの白線
                        gc.fill(
                            Path(CGRect(
                                x: 0, y: fenceRect.maxY - 1,
                                width: size.width, height: 1)),
                            with: .color(.white.opacity(
                                fenceEdge * Self.fenceBottomEdgeRatio)))
                        // 左右端: 端面の反射の縦ハイライト
                        let side = fenceEdge * Self.fenceSideEdgeRatio
                        let w = Self.fenceSideEdgeWidth
                        gc.fill(
                            Path(CGRect(
                                x: 0, y: fenceRect.minY,
                                width: w, height: fenceRect.height)),
                            with: .color(.white.opacity(side)))
                        gc.fill(
                            Path(CGRect(
                                x: size.width - w, y: fenceRect.minY,
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

    /// 実厚。設定値を行間(rowSpacing-2)と下端余白(edgePadding)に
    /// 収まるようクランプする
    private func resolvedThickness(context: ShelfStructureContext) -> CGFloat {
        let raw = context.number(
            Param.boardThickness, default: Self.defaultBoardThickness)
        return max(0, min(raw, context.rowSpacing - 2, context.edgePadding))
    }

    /// 前柵の高さ比(0〜0.40)。0なら柵を描かない
    private func resolvedFenceHeight(context: ShelfStructureContext) -> Double {
        min(0.40, max(0,
            context.number(Param.fenceHeight, default: Self.defaultFenceHeight)))
    }

    /// 前柵エッジの強さ(0〜1)。上端エッジのopacityそのもの。
    /// 下端・左右端は固定比率で連動する
    private func resolvedFenceEdge(context: ShelfStructureContext) -> Double {
        min(1, max(0,
            context.number(Param.fenceEdge, default: Self.defaultFenceEdge)))
    }

    private func resolvedWall(context: ShelfStructureContext) -> Wall {
        let raw = context.text(Param.wall, default: Self.defaultWall.rawValue)
        return Wall(rawValue: raw) ?? Self.defaultWall
    }

    private func resolvedBoard(context: ShelfStructureContext) -> Board {
        let raw = context.text(Param.board, default: Self.defaultBoard.rawValue)
        return Board(rawValue: raw) ?? Self.defaultBoard
    }

    /// プロセス内で最初の1回だけ解決値を記録する
    /// (描画のたびに呼ばれるので、毎回ログは出さない。
    ///  有効/無効とパラメータ確定のログはSettingsView側が出す)
    private static var didLogApplied = false
    private func logAppliedOnce(wall: Wall, board: Board, thickness: CGFloat,
                                fence: Double, edge: Double, rows: Int) {
        guard !Self.didLogApplied else { return }
        Self.didLogApplied = true
        Self.logger.notice("store-shelf applied: wall=\(wall.rawValue, privacy: .public) board=\(board.rawValue, privacy: .public) thickness=\(thickness, privacy: .public) fence=\(fence, privacy: .public) edge=\(edge, privacy: .public) rows=\(rows, privacy: .public)")
    }
}
