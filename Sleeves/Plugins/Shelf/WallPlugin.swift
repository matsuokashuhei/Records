//
//  WallPlugin.swift
//  Sleeves
//
//  プラグイン「壁」(構造系・スタイル非依存)。
//  グリッド背面の壁(単色グラデまたは紙テクスチャ)と、壁に重ねる
//  経年表現(セピア/染み/日焼け残り)を描く。
//  照明系の要素(暖色被せ・周辺減光)は「照明」ペイン新設に伴い
//  AmbientLightPluginへ分離した(2026-11)。
//  壁はシェルフのスタイル(棚板+前柵/レッジ/将来のスタイル)とは
//  直交するので、shelfStyle=nilで全スタイル共通に動く。
//  描画コードはStoreShelfPluginから分離したもの(2026-11)。
//
//  座標はすべて「padding適用済みグリッドの左上原点」
//  (=ShelfStructureContextの定義するフレーム)で解釈する。
//   - 壁: フレーム全面を覆う、上がわずかに明るい暖色の縦
//     グラデーション(天井からの光)
//   - 経年(aging-*): 壁に重ねる3要素。各要素の色・合成・強さは
//     選択中の壁の AgingProfile に従い壁材に合わせる(暗い壁は
//     multiplyが効かないので加算系に切替、日焼け残りは壁の元の色)
//
//  バックドロップはセルのヒット判定に影響しないが、
//  空き領域へのタップを壁が食わないよう allowsHitTesting(false)
//  を掛けている。
//  壁の無い棚は選択肢に無いため常時有効(canDisable=false。
//  設定画面にON/OFFトグルを出さず、保存済みのenabled=falseも
//  resolveで無視される)。
//

import SwiftUI
import os

struct WallPlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Sleeves", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)。
    /// 旧store-shelfプラグインが持っていたキーと同じ値を使い、
    /// ShelfSettingsのデコード時に値を引き継ぐ(wallParamKeys参照)
    private enum Param {
        /// 壁の色。選択肢idの文字列で永続化
        static let wall = "wall"
        /// 経年: セピア被り(0-1)
        static let sepia = "aging-sepia"
        /// 経年: 壁の染み(0-1)
        static let stains = "aging-stains"
        /// 経年: 日焼け残り — レコードに守られた壁の明るい跡(0-1)
        static let fadeMarks = "aging-fade-marks"
    }

    /// 壁。rawValueはsettings.jsonへの永続化値なので
    /// 一度決めたら変更しない。
    /// internalなのは、壁材ごとの個性(agingProfile)を照明系プラグイン
    /// (AmbientLightPlugin)からも同じ壁で引けるようにするため
    enum Wall: String, CaseIterable {
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


    /// デフォルト値
    private static let defaultWall = Wall.cream

    /// settingsから選択中の壁を解決する共有窓口。
    /// 壁材ごとの個性(AgingProfile)を必要とする他プラグイン
    /// (AmbientLightPluginが ShelfStructureContext.settings 経由で
    /// 呼ぶ)が、自分の値解決とは別に「同じ壁」を引けるようにする。
    /// 未知/欠損値はdefaultWallに倒す
    static func wall(in settings: ShelfSettings) -> Wall {
        let raw = settings.plugins["wall"]?.values[Param.wall]?.string
            ?? defaultWall.rawValue
        return Wall(rawValue: raw) ?? defaultWall
    }

    let id = "wall"
    let displayName = "Wall"
    let category: ShelfPluginCategory = .wall
    /// 構造系プラグインは既定で有効(壁の無い棚は選択肢に無い)
    let defaultEnabled = true
    /// 壁の無い棚は選択肢に無いので常に有効。トグルを出さず、
    /// 保存済みのenabled=falseも無視される
    let canDisable = false

    init() {
        Self.logger.info("plugin registered: wall ('Wall')")
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
        logAppliedOnce(wall: wall, aging: aging)
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

    /// 経年レイヤー群。壁の上に3要素を順に重ねる:
    ///   セピア → 染み → 日焼け残り
    /// (暖色被せ・周辺減光の照明系レイヤーはAmbientLightPluginへ分離)
    /// 乗算したい要素(セピア・暗い染み)は必ずView修飾子
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

    // MARK: - パラメータ解決

    /// 任意シードの決定論疑似乱数(0〜1)。rowHashと同じsinハッシュ。
    /// 染みの位置・サイズ・回転のようにインデックス以外の連続シード
    /// から値を取る場面で使う
    private static func hash01(_ seed: Double, salt: Double) -> Double {
        let v = sin(seed * 127.1 + salt * 311.7) * 43758.5453
        return v - v.rounded(.down)
    }

    /// 壁材ごとの経年/照明の個性。internalなのは、照明系プラグイン
    /// (AmbientLightPlugin)がwarmthGain・vignette色・vignetteGainを
    /// 同じ壁材基準で引けるようにするため
    struct AgingProfile {
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
        /// セピア乗算
        var sepia = 0.0
        /// 壁の染み
        var stains = 0.0
        /// 日焼け残り(レコードに守られた明るい跡)
        var fadeMarks = 0.0
        var isOff: Bool {
            sepia + stains + fadeMarks <= 0
        }
    }

    private func resolvedAging(context: ShelfStructureContext) -> Aging {
        var a = Aging()
        a.sepia = min(1, max(0, context.number(Param.sepia, default: 0)))
        a.stains = min(1, max(0, context.number(Param.stains, default: 0)))
        a.fadeMarks = min(1, max(0, context.number(Param.fadeMarks, default: 0)))
        return a
    }

    private func resolvedWall(context: ShelfStructureContext) -> Wall {
        let raw = context.text(Param.wall, default: Self.defaultWall.rawValue)
        return Wall(rawValue: raw) ?? Self.defaultWall
    }

    /// プロセス内で最初の1回だけ解決値を記録する
    /// (描画のたびに呼ばれるので、毎回ログは出さない。
    ///  有効/無効とパラメータ確定のログはSettingsView側が出す)
    private static var didLogApplied = false
    private func logAppliedOnce(wall: Wall, aging: Aging) {
        guard !Self.didLogApplied else { return }
        Self.didLogApplied = true
        Self.logger.notice("wall applied: wall=\(wall.rawValue, privacy: .public) aging=[sepia=\(aging.sepia, privacy: .public) stains=\(aging.stains, privacy: .public) fadeMarks=\(aging.fadeMarks, privacy: .public)]")
    }
}
