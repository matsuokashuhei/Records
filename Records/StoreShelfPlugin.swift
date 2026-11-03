//
//  StoreShelfPlugin.swift
//  Records
//
//  プラグイン「レコード店の棚」(構造系)。
//  レコード店の壁面陳列棚の写真を再現する: 壁(単色グラデまたは
//  紙テクスチャ) + 各行の黒い水平棚板 + 棚板手前端に立つ透明
//  アクリルの前柵。
//  紙テクスチャの画像は texture-generator
//  (https://github.com/nmpowell/texture-generator) の paper
//  バリアントで生成したシームレスタイル(creases=0)。
//  敷き詰めた紙の上に既存と同じ天井光の縦グラデーションを重ねる。
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
//   - 経年(aging-*): 壁に重ねる5要素(暖色被せ/セピア/染み/
//     日焼け残り/周辺減光)。各要素の色・合成・強さは選択中の
//     壁の AgingProfile に従い壁材に合わせる(暗い壁はmultiply
//     が効かないので加算系に切替、日焼け残りは壁の元の色)
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
        /// 前柵(アクリル板)の見え方の強さ=上端エッジのopacity。
        /// 板の映り込み(透明度)・下端/左右端エッジ・コーナーの
        /// 集光はすべて上端に対する固定比率で連動する
        static let fenceEdge = "fence-edge"
        /// 前柵のばらつき(0-1)。アクリル板の明るさを長手方向に
        /// ゆらがせ、段ごとの個体差も付ける(実物の切断面の
        /// 発光は磨きムラで均一でない)
        static let fenceVariation = "fence-variation"
        /// 経年: 白熱灯の暖色被せ(0-1)
        static let warmth = "aging-warmth"
        /// 経年: セピア被り(0-1)
        static let sepia = "aging-sepia"
        /// 経年: 壁の染み(0-1)
        static let stains = "aging-stains"
        /// 経年: 日焼け残り — レコードに守られた壁の明るい跡(0-1)
        static let fadeMarks = "aging-fade-marks"
        /// 経年: 周辺減光(0-1)
        static let vignette = "aging-vignette"
    }

    /// 壁。rawValueはsettings.jsonへの永続化値なので
    /// 一度決めたら変更しない
    private enum Wall: String, CaseIterable {
        /// 暖色クリーム(レコード店の壁)
        case cream
        /// ニュートラルな暖灰
        case warmGray = "warm-gray"
        /// 暗色
        case charcoal
        /// 白い上質紙
        case paperWhite = "paper-white"
        /// 未晒クラフト紙
        case paperKraft = "paper-kraft"
        /// 再生紙
        case paperRecycled = "paper-recycled"
        /// 新聞用紙
        case paperNewsprint = "paper-newsprint"
        /// レース紙(手漉き風)
        case paperLaid = "paper-laid"
        /// マットコート紙
        case paperCoated = "paper-coated"

        /// 表示ラベル(Localizable.xcstringsのキー)
        var label: String {
            switch self {
            case .cream: return "Cream"
            case .warmGray: return "Warm Gray"
            case .charcoal: return "Charcoal"
            case .paperWhite: return "White Paper"
            case .paperKraft: return "Kraft Paper"
            case .paperRecycled: return "Recycled Paper"
            case .paperNewsprint: return "Newsprint"
            case .paperLaid: return "Laid Paper"
            case .paperCoated: return "Coated Paper"
            }
        }

        /// 紙壁の場合のアセット名(非紙はnil)
        var paperAsset: String? {
            switch self {
            case .cream, .warmGray, .charcoal: return nil
            case .paperWhite: return "paper-white"
            case .paperKraft: return "paper-kraft"
            case .paperRecycled: return "paper-recycled"
            case .paperNewsprint: return "paper-newsprint"
            case .paperLaid: return "paper-laid"
            case .paperCoated: return "paper-coated"
            }
        }

        /// 経年表現の壁ごとの個性。同じパラメータ値でも壁材に合った
        /// 見え方になるよう、染み/セピアの描き方・日焼け残りの色・
        /// 各要素の強さ係数を壁が持つ
        var agingProfile: AgingProfile {
            switch self {
            case .cream:
                return .init(
                    stain: .dark, stainGain: 1,
                    sepiaMultiply: true, sepiaGain: 1,
                    fadeMark: Color(red: 0.97, green: 0.94, blue: 0.86),
                    fadeMarkGain: 1, warmthGain: 1,
                    vignette: (0.45, 0.28, 0.12), vignetteGain: 1)
            case .warmGray:
                return .init(
                    stain: .dark, stainGain: 0.9,
                    sepiaMultiply: true, sepiaGain: 1,
                    fadeMark: Color(red: 0.80, green: 0.77, blue: 0.70),
                    fadeMarkGain: 1, warmthGain: 1.1,
                    vignette: (0.38, 0.26, 0.15), vignetteGain: 1)
            case .charcoal:
                // 暗い壁: multiply系(セピア・暗い染み)は効かないので
                // 加算系へ切替。染みは明るいかすれ/埃、日焼け残りは
                // 焼ける前の明るい炭色、暖色とビネットは強め
                return .init(
                    stain: .light, stainGain: 1,
                    sepiaMultiply: false, sepiaGain: 1,
                    fadeMark: Color(red: 0.33, green: 0.33, blue: 0.38),
                    fadeMarkGain: 1, warmthGain: 1.5,
                    vignette: (0.12, 0.12, 0.16), vignetteGain: 1.2)
            case .paperWhite:
                return .init(
                    stain: .dark, stainGain: 1.1,
                    sepiaMultiply: true, sepiaGain: 1,
                    fadeMark: Color(red: 0.98, green: 0.96, blue: 0.92),
                    fadeMarkGain: 1, warmthGain: 1,
                    vignette: (0.48, 0.32, 0.15), vignetteGain: 1)
            case .paperKraft:
                // 元から暖色なので暖色被せは弱め、染みは同系色で
                // 沈みがちなため強め
                return .init(
                    stain: .dark, stainGain: 1.3,
                    sepiaMultiply: true, sepiaGain: 0.8,
                    fadeMark: Color(red: 0.84, green: 0.73, blue: 0.55),
                    fadeMarkGain: 1, warmthGain: 0.7,
                    vignette: (0.40, 0.24, 0.10), vignetteGain: 1)
            case .paperRecycled:
                return .init(
                    stain: .dark, stainGain: 1,
                    sepiaMultiply: true, sepiaGain: 1,
                    fadeMark: Color(red: 0.88, green: 0.83, blue: 0.72),
                    fadeMarkGain: 1, warmthGain: 1,
                    vignette: (0.45, 0.29, 0.13), vignetteGain: 1)
            case .paperNewsprint:
                return .init(
                    stain: .dark, stainGain: 1,
                    sepiaMultiply: true, sepiaGain: 1,
                    fadeMark: Color(red: 0.92, green: 0.89, blue: 0.81),
                    fadeMarkGain: 1, warmthGain: 1,
                    vignette: (0.46, 0.30, 0.14), vignetteGain: 1)
            case .paperLaid:
                return .init(
                    stain: .dark, stainGain: 1,
                    sepiaMultiply: true, sepiaGain: 1,
                    fadeMark: Color(red: 0.96, green: 0.93, blue: 0.84),
                    fadeMarkGain: 1, warmthGain: 1,
                    vignette: (0.46, 0.30, 0.13), vignetteGain: 1)
            case .paperCoated:
                return .init(
                    stain: .dark, stainGain: 1.1,
                    sepiaMultiply: true, sepiaGain: 1,
                    fadeMark: Color(red: 0.97, green: 0.95, blue: 0.90),
                    fadeMarkGain: 1, warmthGain: 1,
                    vignette: (0.48, 0.32, 0.15), vignetteGain: 1)
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
            default:
                // 紙テクスチャ用: 呼ばれないはずだが安全側のフォールバック
                return Gradient(colors: [.white, .gray])
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
            .slider(.init(
                id: Param.warmth,
                label: "Warm Light",
                range: 0...1,
                step: 0.01,
                defaultValue: 0
            )),
            .slider(.init(
                id: Param.sepia,
                label: "Sepia Tint",
                range: 0...1,
                step: 0.01,
                defaultValue: 0
            )),
            .slider(.init(
                id: Param.stains,
                label: "Stains",
                range: 0...1,
                step: 0.01,
                defaultValue: 0
            )),
            .slider(.init(
                id: Param.fadeMarks,
                label: "Fade Marks",
                range: 0...1,
                step: 0.01,
                defaultValue: 0
            )),
            .slider(.init(
                id: Param.vignette,
                label: "Vignette",
                range: 0...1,
                step: 0.01,
                defaultValue: 0
            )),
        ]
    }

    // MARK: - (e) グリッド背面(壁)

    func shelfBackdrop(context: ShelfStructureContext) -> AnyView? {
        let wall = resolvedWall(context: context)
        let backdrop: AnyView
        if let asset = wall.paperAsset {
            // 紙壁: 生成済みシームレスタイルを敷き詰め、その上に
            // 天井光(上が明るい)の薄い縦グラデーションを重ねる
            backdrop = AnyView(
                Image(asset)
                    .resizable(resizingMode: .tile)
                    .overlay {
                        LinearGradient(
                            gradient: Gradient(colors: [
                                .white.opacity(0.10),
                                .black.opacity(0.06),
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            )
        } else {
            backdrop = AnyView(
                LinearGradient(
                    gradient: wall.gradient,
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        let aging = resolvedAging(context: context)
        logAppliedOnce(
            wall: wall, board: resolvedBoard(context: context),
            thickness: resolvedThickness(context: context),
            fence: resolvedFenceHeight(context: context),
            edge: resolvedFenceEdge(context: context),
            variation: resolvedFenceVariation(context: context),
            aging: aging, rows: context.gridRows)
        guard !aging.isOff else {
            return AnyView(backdrop.allowsHitTesting(false))
        }
        // 背面なのでセルのヒット判定には影響しないが、空き領域への
        // タップを壁が食わないよう保険を掛けておく
        return AnyView(
            backdrop
                .overlay { agingLayers(aging, wall: wall, context: context) }
                .allowsHitTesting(false)
        )
    }

    /// 経年レイヤー群。壁の上に5要素を順に重ねる:
    ///   暖色被せ → セピア → 染み → 日焼け残り → 周辺減光
    /// 乗算したい要素(セピア・暗い染み・周辺減光)は必ずView修飾子
    /// `.blendMode(.multiply)` の独立レイヤーにする。Canvas内の
    /// `gc.blendMode` はCanvas自身のバッファ内でしか効かず、
    /// 透明な下地へのmultiplyはsource-overと同義になるため、
    /// 壁そのものへ掛けるにはView側のblendModeが必要。
    /// 各要素の色・合成・強さは選択中のWallのAgingProfileで壁材に
    /// 合わせる(暗い壁はmultiplyが効かないため加算系に切替)
    @ViewBuilder
    private func agingLayers(
        _ a: Aging, wall: Wall, context: ShelfStructureContext
    ) -> some View {
        let p = wall.agingProfile
        if a.warmth > 0 {
            // 白熱灯: 上ほど強い琥珀色の被せ
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 1, green: 0.80, blue: 0.45)
                        .opacity(0.28 * a.warmth * p.warmthGain),
                    Color(red: 1, green: 0.76, blue: 0.42)
                        .opacity(0.05 * a.warmth * p.warmthGain),
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        }
        if a.sepia > 0 {
            let s = min(1, a.sepia * p.sepiaGain)
            if p.sepiaMultiply {
                Color(red: 0.93, green: 0.80, blue: 0.60)
                    .opacity(s)
                    .blendMode(.multiply)
            } else {
                // 暗い壁は乗算が効かないので暖色の加算被せにする
                Color(red: 1, green: 0.72, blue: 0.40)
                    .opacity(0.22 * s)
            }
        }
        if a.stains > 0 {
            stainsLayer(a, profile: p, context: context)
        }
        if a.fadeMarks > 0 {
            fadeMarksLayer(a, profile: p, context: context)
        }
        if a.vignette > 0 {
            vignetteLayer(a, profile: p)
        }
    }

    /// 壁の染み: 面積比例の個数の、回転した楕円形の滲み
    /// (放射グラデで縁を消す)。7割に小さな濃い芯を足す。
    /// 位置・形状は決定論ハッシュで固定(再描画・再起動で変わらない)。
    /// 明るい壁は暗い水染み(multiplyで紙の質感を残したまま沈める)、
    /// 暗い壁は明るいかすれ/埃(normal合成の淡色)
    private func stainsLayer(
        _ a: Aging, profile p: AgingProfile, context: ShelfStructureContext
    ) -> some View {
        let dark = p.stain == .dark
        let tone = dark
            ? Color(red: 0.42, green: 0.30, blue: 0.15)
            : Color(red: 0.68, green: 0.66, blue: 0.58)
        let blobOpacity = a.stains * (dark ? 0.45 : 0.20) * p.stainGain
        let coreOpacity = a.stains * (dark ? 0.35 : 0.15) * p.stainGain
        let canvas = Canvas { gc, size in
            guard size.width > 0, size.height > 0 else { return }
            let cell2 = context.cellSize * context.cellSize
            let count = max(3, min(8,
                Int(size.width * size.height / cell2 * 0.22)))
            for i in 0..<count {
                let s = Double(i)
                let cx = Self.hash01(s, salt: 3.1) * size.width
                let cy = Self.hash01(s, salt: 7.9) * size.height
                let rx = context.cellSize
                    * (0.5 + Self.hash01(s, salt: 11.3) * 1.1)
                let ry = rx * (0.55 + Self.hash01(s, salt: 17.7) * 0.6)
                var t = gc
                t.translateBy(x: cx, y: cy)
                t.rotate(by: .degrees(
                    (Self.hash01(s, salt: 23.5) - 0.5) * 80))
                let blob = CGRect(
                    x: -rx, y: -ry, width: rx * 2, height: ry * 2)
                t.fill(Path(ellipseIn: blob), with: .radialGradient(
                    Gradient(colors: [
                        tone.opacity(min(1, blobOpacity)), .clear]),
                    center: .zero, startRadius: 0, endRadius: ry))
                if Self.hash01(s, salt: 31.9) < 0.7 {
                    // 濃い芯: 染み内部のオフセット位置に小さな円
                    let cr = ry * (0.25 + Self.hash01(s, salt: 37.3) * 0.3)
                    let core = CGRect(
                        x: (Self.hash01(s, salt: 41.7) - 0.5) * rx - cr,
                        y: (Self.hash01(s, salt: 43.1) - 0.5) * ry - cr,
                        width: cr * 2, height: cr * 2)
                    t.fill(Path(ellipseIn: core), with: .radialGradient(
                        Gradient(colors: [
                            tone.opacity(min(1, coreOpacity)), .clear]),
                        center: CGPoint(x: core.midX, y: core.midY),
                        startRadius: 0, endRadius: cr))
                }
            }
        }
        return dark ? AnyView(canvas.blendMode(.multiply)) : AnyView(canvas)
    }

    /// 日焼け残り: レコードに守られた壁が周囲より明るく残る跡。
    /// 全セル位置に「その壁の焼ける前の色」のぼかした矩形を敷く。
    /// レコードのあるセルはジャケットで隠れるため「空きスロットの
    /// 裏の壁だけ残った跡」として見える
    private func fadeMarksLayer(
        _ a: Aging, profile p: AgingProfile, context: ShelfStructureContext
    ) -> some View {
        let mark = p.fadeMark.opacity(
            min(1, a.fadeMarks * 0.20 * p.fadeMarkGain))
        let cell = context.cellSize
        return Canvas { gc, size in
            guard size.width > 0, size.height > 0 else { return }
            gc.drawLayer { layer in
                layer.addFilter(.blur(radius: 4))
                for row in 0..<context.gridRows {
                    for col in 0..<context.gridColumns {
                        let rect = CGRect(
                            x: context.edgePadding + CGFloat(col)
                                * (cell + context.columnSpacing) + 1.5,
                            y: context.topPadding + CGFloat(row)
                                * (cell + context.rowSpacing) + 1.5,
                            width: cell - 3, height: cell - 3)
                        layer.fill(
                            Path(roundedRect: rect, cornerRadius: 3),
                            with: .color(mark))
                    }
                }
            }
        }
    }

    /// 周辺減光: 四辺からの帯をぼかした内側影(even-odd fillで
    /// 中央をくり抜いたリングをぼかす)。中央は一切触らず四辺の
    /// 帯と角だけを暗くする。multiplyはビュー側で掛けて自己完結
    /// させる(帯色は乗算前提の色設計なので、付け忘れると
    /// 不透明の帯として描かれてしまう)。帯の下の壁テクスチャは
    /// 残ったまま沈む(全面ベールでテクスチャが消えた問題の対策
    /// 2026-11-03)
    private func vignetteLayer(_ a: Aging, profile p: AgingProfile) -> some View {
        let k = min(1, a.vignette * p.vignetteGain)
        return Canvas { gc, size in
            guard size.width > 0, size.height > 0 else { return }
            let frame = CGRect(origin: .zero, size: size)
            let inset = min(size.width, size.height) * 0.14
            var ring = Path()
            ring.addRect(frame)
            ring.addRoundedRect(
                in: frame.insetBy(dx: inset, dy: inset),
                cornerSize: CGSize(width: inset, height: inset))
            gc.drawLayer { layer in
                layer.addFilter(.blur(radius: inset * 0.55))
                layer.fill(
                    ring,
                    with: .color(Color(
                        red: 1 - (1 - p.vignette.r) * k,
                        green: 1 - (1 - p.vignette.g) * k,
                        blue: 1 - (1 - p.vignette.b) * k)),
                    style: FillStyle(eoFill: true))
            }
        }
        .blendMode(.multiply)
    }

    // MARK: - (f) グリッド前面(棚板+前柵)

    func shelfOverlay(context: ShelfStructureContext) -> AnyView? {
        let board = resolvedBoard(context: context)
        let t = resolvedThickness(context: context)
        let fenceRatio = resolvedFenceHeight(context: context)
        let fenceEdge = resolvedFenceEdge(context: context)
        let fenceVar = resolvedFenceVariation(context: context)
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
        let lastGap = max(0, context.bottomPadding - t)

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
                    if fenceRatio > 0 && fenceEdge > 0 {
                        // 前柵: 棚板の手前に立つ透明アクリルのストリップ。
                        // 下端は板の手前面へ少し重なる(t*0.6)
                        let f = fenceRatio * cell
                        let fenceRect = CGRect(
                            x: 0, y: bottom - f,
                            width: size.width, height: f + t * 0.6)
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
                        let segW = size.width / CGFloat(segments)
                        for i in 0..<segments {
                            let x0 = CGFloat(i) * segW
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
                                    x: fx * size.width, salt: 11 + rowSalt)
                                : 1
                            edgeStops.append(.init(
                                color: .white.opacity(min(1, e * m)),
                                location: fx))
                        }
                        let edgeLine = CGRect(
                            x: 0, y: fenceRect.minY,
                            width: size.width, height: 1)
                        gc.fill(
                            Path(edgeLine),
                            with: .linearGradient(
                                Gradient(stops: edgeStops),
                                startPoint: CGPoint(x: 0, y: 0),
                                endPoint: CGPoint(
                                    x: size.width, y: 0)))
                        // 滲み: エッジの光が周囲に漏れる2ptのフェード。
                        // エッジと同じゆらぎを弱く写す
                        let glowRect = CGRect(
                            x: 0, y: fenceRect.minY + 1,
                            width: size.width,
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
                        for x in [0.0, size.width - cw] {
                            gc.fill(
                                Path(CGRect(
                                    x: x, y: fenceRect.minY,
                                    width: cw, height: cw)),
                                with: .color(.white.opacity(cornerOpacity)))
                        }
                        // 下端エッジ: 上端より弱い1ptの白線
                        gc.fill(
                            Path(CGRect(
                                x: 0, y: fenceRect.maxY - 1,
                                width: size.width, height: 1)),
                            with: .color(.white.opacity(
                                e * Self.fenceBottomEdgeRatio)))
                        // 左右端: 端面の反射の縦ハイライト
                        let side = e * Self.fenceSideEdgeRatio
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

    /// 任意シードの決定論疑似乱数(0〜1)。rowHashと同じsinハッシュ。
    /// 染みの位置・サイズ・回転のようにインデックス以外の連続シード
    /// から値を取る場面で使う
    private static func hash01(_ seed: Double, salt: Double) -> Double {
        let v = sin(seed * 127.1 + salt * 311.7) * 43758.5453
        return v - v.rounded(.down)
    }

    /// 前柵(アクリル板)の見え方の強さ(0〜1)。上端エッジの
    /// opacityそのもの。本体(透明度)・映り込み・下端/左右端・
    /// コーナー集光は固定比率で連動する
    private func resolvedFenceEdge(context: ShelfStructureContext) -> Double {
        min(1, max(0,
            context.number(Param.fenceEdge, default: Self.defaultFenceEdge)))
    }

    /// 経年表現の壁ごとの効き方(Wall.agingProfileで壁が定義)
    private struct AgingProfile {
        /// 染みの見え方。暗い壁に暗い染みは沈むので明るいかすれにする
        enum Stain { case dark, light }
        var stain: Stain
        /// 染みの強さ係数
        var stainGain: Double
        /// セピアを乗算で掛けるか。暗い壁は乗算が効かないので
        /// false にして暖色加算へ切り替える
        var sepiaMultiply: Bool
        var sepiaGain: Double
        /// 日焼け残りの色=その壁の「焼ける前」の色
        var fadeMark: Color
        var fadeMarkGain: Double
        /// 暖色被せの強さ係数
        var warmthGain: Double
        /// ビネット角の乗算色(v=1のときのRGB)と強さ係数
        var vignette: (r: Double, g: Double, b: Double)
        var vignetteGain: Double
    }

    /// 経年パラメータの解決済み値(各0-1)。全て0なら経年なし
    private struct Aging {
        /// 白熱灯の暖色被せ
        var warmth = 0.0
        /// セピア乗算
        var sepia = 0.0
        /// 壁の染み
        var stains = 0.0
        /// 日焼け残り(レコードに守られた明るい跡)
        var fadeMarks = 0.0
        /// 周辺減光
        var vignette = 0.0
        var isOff: Bool {
            warmth + sepia + stains + fadeMarks + vignette <= 0
        }
    }

    private func resolvedAging(context: ShelfStructureContext) -> Aging {
        var a = Aging()
        a.warmth = min(1, max(0, context.number(Param.warmth, default: 0)))
        a.sepia = min(1, max(0, context.number(Param.sepia, default: 0)))
        a.stains = min(1, max(0, context.number(Param.stains, default: 0)))
        a.fadeMarks = min(1, max(0, context.number(Param.fadeMarks, default: 0)))
        a.vignette = min(1, max(0, context.number(Param.vignette, default: 0)))
        return a
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
                                fence: Double, edge: Double, variation: Double,
                                aging: Aging, rows: Int) {
        guard !Self.didLogApplied else { return }
        Self.didLogApplied = true
        Self.logger.notice("store-shelf applied: wall=\(wall.rawValue, privacy: .public) board=\(board.rawValue, privacy: .public) thickness=\(thickness, privacy: .public) fence=\(fence, privacy: .public) edge=\(edge, privacy: .public) variation=\(variation, privacy: .public) aging=[warmth=\(aging.warmth, privacy: .public) sepia=\(aging.sepia, privacy: .public) stains=\(aging.stains, privacy: .public) fadeMarks=\(aging.fadeMarks, privacy: .public) vignette=\(aging.vignette, privacy: .public)] rows=\(rows, privacy: .public)")
    }
}
