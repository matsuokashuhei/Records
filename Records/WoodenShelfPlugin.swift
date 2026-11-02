//
//  WoodenShelfPlugin.swift
//  Records
//
//  プラグイン「木製の棚」(構造系)。
//  レコード店の壁面に使われる木製ラティス(キュービー)棚を再現する:
//  全幅に通した水平板 + 板の間に分節して入る縦仕切り(水平板より
//  細い) + 外周フレーム + 各キュービーの手前に渡した細いクロームの
//  保持ロッド。ジャケットは枠の奥に recessed に納まり、
//  空きキュービーには暗めの木の背板が見える。
//
//  座標はすべて「padding適用済みグリッドの左上原点」
//  (=ShelfStructureContextの定義するフレーム)で計算する。
//   - 背板(shelfBackdrop): フレーム全面を覆う、選んだ木材と同系色を
//     「背板の暗さ」で暗くしたパネル。上(天井側)ほど暗い縦
//     グラデーション + 縦張り板材のテクスチャタイル
//   - 枠とロッド(shelfOverlay): 1枚のCanvasに
//     (1) セル内側の陰(上の板からの落ち影が最強=セル高の20%、
//         左右は7%と薄く、下端にわずかな接触影)
//     (2) 行境界0...rowsの水平板 — 内部は行間帯の中央に
//         min(厚さ, rowSpacing-2)(両側2ptの隙間=背板が見える)、
//         上下の外周は縁にぴったり。
//         部材はstructureSpacingで帯幅を要求しており、太くすると
//         帯・余白(=棚全体)が大きくなるのでセルには決して重ならない
//     (3) 列境界0...colsの縦仕切り — 内部は列間帯の中央に
//         min(仕切りの太さ, columnSpacing-2)、左右外周は縁ぴったり。
//         水平板が通しなので、縦材は各行について
//         「上の板の下端〜下の板の上端」に分節して描く。
//         厚さは水平板と別パラメータ(実物は横板が厚く縦材が細い)
//     (4) 保持ロッド — 各キュービーに0/1/2本(2本=セル高の1/3と2/3、
//         1本=2/3=下側だけ残す)。セル幅いっぱい(両端2ptずつ仕切りの
//         下へ潜る)の高さ1.75ptのカプセル。上端の白いハイライト +
//         銀色の縦グラデーション + 直下2ptの柔らかい落ち影
//   木材の質感: 木目はベクター描画ではなくフィールドベースの
//   プロシージャルテクスチャ(WoodTexture.swift。
//   nmpowell/texture-generatorのアルゴリズム移植 — 髄心までの
//   距離場+成長輪幅系列+鋸歯プロファイルで、カテドラル(山型杢)
//   や節まわりの輪の歪みが自然に現れる)。部材ごとに別シードで
//   生成し、grainを不透明度として重ねる(grain=0で平面の木)。
//   部材(板・仕切りの各節)ごとの輝度揺らぎ±8%と琥珀/褐色の
//   色膜による色相ばらつきはgrainと独立して常に掛かる。
//   水平板は上端1pt明/下端1pt暗、縦材は左端1pt明/右端1pt暗の稜線
//   ビンテージ感(強さは「Age」パラメータ): 経年でニスが飴色になる
//   パティーナ(下段ほど濃い、上段は日焼けで白ける)+ 前縁の
//   塗装剥げと節端の欠け + キュービー手前中央の手垢の半艶と
//   ロッド端の黒ずみ + 板面の傷と仕切り接合部の釘穴 + 輪ジミ・
//   内側4隅の汚れ・見切りのホコリ。木目とは別系統なので
//   grain=0でも出る
//
//  「棚のスタイル」排他グループ(ShelfPluginGroups.shelfStyle)の一員。
//  StoreShelfPluginと同時には有効にならず、設定画面ではグループの
//  ピッカーから選択する。既定は無効(defaultEnabled=false。
//  Store Shelf側が既定ONなので、先着規則でこちらは選ばれた時だけ)。
//  オーバーレイは合成側(ShelfView.shelfGrid)が
//  .allowsHitTesting(false) で重ねるので、再生タップ・D&D・
//  右クリックメニュー・ドロップゾーンは従来通り動く。
//

import SwiftUI
import os

struct WoodenShelfPlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Records", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)
    private enum Param {
        /// 木材の種類。選択肢idの文字列で永続化
        static let wood = "wood"
        /// 水平板の厚さ(pt)
        static let boardThickness = "board-thickness"
        /// 縦仕切りの太さ(pt)。水平板より細いのが実物
        static let dividerThickness = "divider-thickness"
        /// 保持ロッドの本数(0/1/2)
        static let rods = "rods"
        /// 木目の強さ(0-1)
        static let grain = "grain"
        /// ビンテージ感(0-1)。パティーナ・エッジ摩耗・手垢・傷・
        /// シミ汚れをまとめて連動させる
        static let age = "age"
        /// 背板の暗さ(0-1)
        static let backShade = "back-shade"
    }

    /// RGB(0〜1)の色材。部材ごとの輝度揺らぎや背板の暗化で
    /// 成分ごとの掛け算が必要なので、Colorのまま持たない
    private struct RGB {
        let r: Double, g: Double, b: Double
        /// 輝度をk倍する(各成分0〜1にクリップ)
        func scaled(_ k: Double) -> RGB {
            RGB(r: min(1, max(0, r * k)),
                g: min(1, max(0, g * k)),
                b: min(1, max(0, b * k)))
        }
        var color: Color { Color(red: r, green: g, blue: b) }
    }

    /// 木材。rawValueはsettings.jsonへの永続化値なので
    /// 一度決めたら変更しない
    private enum Wood: String, CaseIterable {
        /// 写真のライトパイン(自然色の明るい針葉樹)
        case pine
        /// 中程度の暖色ブラウン
        case oak
        /// 暗いブラウン
        case walnut

        /// 表示ラベル(Localizable.xcstringsのキー)
        var label: String {
            switch self {
            case .pine: return "Pine"
            case .oak: return "Oak"
            case .walnut: return "Walnut"
            }
        }

        /// 部材の上面色(光を受ける側)
        var light: RGB {
            switch self {
            case .pine:   return RGB(r: 0xD6/255, g: 0xB1/255, b: 0x83/255)
            case .oak:    return RGB(r: 0xB9/255, g: 0x8D/255, b: 0x54/255)
            case .walnut: return RGB(r: 0x6B/255, g: 0x4A/255, b: 0x33/255)
            }
        }
        /// 部材の下面色(陰になる側)
        var dark: RGB {
            switch self {
            case .pine:   return RGB(r: 0xC3/255, g: 0x9A/255, b: 0x66/255)
            case .oak:    return RGB(r: 0xA1/255, g: 0x77/255, b: 0x3F/255)
            case .walnut: return RGB(r: 0x54/255, g: 0x38/255, b: 0x2A/255)
            }
        }
        /// 木目テクスチャの早材色(明るい側。成長輪の広い帯)
        var early: RGB {
            switch self {
            case .pine:   return RGB(r: 0.85, g: 0.68, b: 0.47)
            case .oak:    return RGB(r: 0.74, g: 0.57, b: 0.34)
            case .walnut: return RGB(r: 0.46, g: 0.33, b: 0.22)
            }
        }
        /// 木目テクスチャの晩材色(暗い側。輪境界の濃い線)
        var late: RGB {
            switch self {
            case .pine:   return RGB(r: 0.55, g: 0.35, b: 0.16)
            case .oak:    return RGB(r: 0.48, g: 0.31, b: 0.14)
            case .walnut: return RGB(r: 0.26, g: 0.16, b: 0.09)
            }
        }
        /// 気孔クラス(輪内プロファイルの形を決める)
        var poreClass: WoodTexture.PoreClass {
            switch self {
            case .pine:   return .softwood
            case .oak:    return .ringPorous
            case .walnut: return .semiRingPorous
            }
        }
    }

    /// デフォルト値
    private static let defaultWood = Wood.pine
    static let defaultBoardThickness: Double = 12
    static let defaultDividerThickness: Double = 8
    static let defaultRods: Double = 1
    static let defaultGrain: Double = 0.6
    static let defaultAge: Double = 0.5
    static let defaultBackShade: Double = 0.35

    // セル内側の陰(キュービーの奥行き表現)
    /// 上の板からの落ち影: セル高の20%、黒0.30→0
    private static let innerTopShadowDepth: CGFloat = 0.20
    private static let innerTopShadowOpacity: Double = 0.30
    /// 左右の陰: セル幅の7%、黒0.18→0
    private static let innerSideShadowWidth: CGFloat = 0.07
    private static let innerSideShadowOpacity: Double = 0.18
    /// 下端の接触影: セル高の8%、0→黒0.14
    private static let innerBottomShadowDepth: CGFloat = 0.08
    private static let innerBottomShadowOpacity: Double = 0.14
    // 部材の質感
    /// 部材ごとの輝度の揺らぎ(±この割合。板/節は別個体なので
    /// 明るさがわずかに違う)
    private static let pieceBrightnessJitter: Double = 0.08
    /// 稜線: 光を受ける辺(水平板の天面/縦材の左端)の明るい1pt線と
    /// 陰になる辺(水平板の下端/縦材の右端)の暗い1pt線
    private static let edgeLightOpacity: Double = 0.20
    private static let edgeDarkOpacity: Double = 0.22
    /// 部材の厚さ/幅を物理サイズ(mm)に換算する係数。
    /// テクスチャの輪数は「面のmm幅÷平均輪幅」で決まるので、
    /// 16ptの板=40mmの面には約15〜25輪が乗る
    private static let mmPerPt: Double = 2.5
    /// 水平板のテクスチャに節が入る確率(細帯なので低め)
    private static let boardKnotChance: Double = 0.15
    /// 縦仕切りのテクスチャに節が入る確率
    private static let dividerKnotChance: Double = 0.12
    /// 背板の板材テクスチャに節が入る確率
    private static let plankKnotChance: Double = 0.15
    /// 背板の板材の幅(pt)。実板150〜200mm相当
    private static let plankWidthPt: CGFloat = 72
    /// 傷・輪ジミなどの暗い線の色。黒のままだと印刷物に
    /// 見えるので濃い褐色にする
    private static let grainDark = Color(red: 0.30, green: 0.18, blue: 0.08)
    /// 部材ごとの色相のばらつき(板目が別個体に見えるよう、
    /// 琥珀色か褐色の薄い色膜を部材ごとに重ねる濃さの上限)
    private static let pieceTintOpacity: Double = 0.10
    // 保持ロッド(キュービー手前のクローム棒)
    private static let rodHeight: CGFloat = 1.75
    /// ロッドの両端が仕切りの下へ潜る長さ(列間帯の両側の
    /// 隙間1ptを越えて仕切り本体へ1pt食い込む=2pt)
    private static let rodTuck: CGFloat = 2
    /// ロッド直下の落ち影の長さと濃さ
    private static let rodShadowLength: CGFloat = 2
    private static let rodShadowOpacity: Double = 0.22
    /// ロッド位置(セル高に対する比率)。2本=1/3と2/3、1本=2/3
    /// (ユーザー指定: 下側のロッドだけ残す)
    private static let rodFractions2: [CGFloat] = [1.0 / 3.0, 2.0 / 3.0]
    private static let rodFractions1: [CGFloat] = [2.0 / 3.0]
    /// ロッド本体のクローム(銀)縦グラデーション。
    /// 上面が光を拾い、下へ行くほど沈む金属
    private static let rodGradient = Gradient(stops: [
        .init(color: Color(white: 0.96), location: 0),
        .init(color: Color(white: 0.78), location: 0.45),
        .init(color: Color(white: 0.55), location: 1),
    ])
    /// ロッド上端のハイライト(反射)の濃さ
    private static let rodEdgeOpacity: Double = 0.85

    let id = "wooden-shelf"
    let displayName = "Wooden Shelf"
    /// 「棚のスタイル」排他グループ。StoreShelfPluginと同時には
    /// 有効にならない(レジストリ順の先着1つ)
    let exclusiveGroup: String? = ShelfPluginGroups.shelfStyle
    /// Store Shelfが既定ONなのでこちらはOFF(ピッカーから選ぶ)
    let defaultEnabled = false

    init() {
        Self.logger.info("plugin registered: wooden-shelf ('Wooden Shelf')")
    }

    var parameterSpecs: [PluginParameterSpec] {
        [
            .options(.init(
                id: Param.wood,
                label: "Wood",
                choices: Wood.allCases.map {
                    .init(id: $0.rawValue, label: $0.label)
                },
                defaultValue: Self.defaultWood.rawValue
            )),
            .slider(.init(
                id: Param.boardThickness,
                label: "Board Thickness",
                range: 8...16,
                step: 1,
                defaultValue: Self.defaultBoardThickness
            )),
            .slider(.init(
                id: Param.dividerThickness,
                label: "Divider Thickness",
                range: 4...12,
                step: 1,
                defaultValue: Self.defaultDividerThickness
            )),
            .slider(.init(
                id: Param.rods,
                label: "Rods",
                range: 0...2,
                step: 1,
                defaultValue: Self.defaultRods
            )),
            .slider(.init(
                id: Param.grain,
                label: "Wood Grain",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultGrain
            )),
            .slider(.init(
                id: Param.age,
                label: "Age",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultAge
            )),
            .slider(.init(
                id: Param.backShade,
                label: "Back Shade",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultBackShade
            )),
        ]
    }

    // MARK: - (g) グリッド幾何への要求

    /// 部材をセルに重ねず描くための帯の幅。
    /// 内部部材は帯の中央に置き両側に2ptの見切り(背板が見える隙間)
    /// を残すので、帯幅=部材+4。外周部材は余白の内側に収める
    /// (外縁ぴったり+セル側に見切り)ので、余白=部材+2。
    /// 厚くすると棚全体が大きくなり、レコードには決して触れない
    func structureSpacing(
        values: [String: PluginParameterValue]
    ) -> ShelfStructureSpacing? {
        let t = max(0, values[Param.boardThickness]?.number
            ?? Self.defaultBoardThickness)
        let dt = max(0, values[Param.dividerThickness]?.number
            ?? Self.defaultDividerThickness)
        return ShelfStructureSpacing(
            columnSpacing: CGFloat(dt) + 4,
            rowSpacing: CGFloat(t) + 4,
            edgePadding: CGFloat(max(t, dt)) + 2,
            topPadding: CGFloat(t) + 2)
    }

    // MARK: - (e) グリッド背面(木の背板)

    func shelfBackdrop(context: ShelfStructureContext) -> AnyView? {
        let wood = resolvedWood(context: context)
        let shade = resolvedBackShade(context: context)
        let grain = resolvedGrain(context: context)
        let age = resolvedAge(context: context)
        return AnyView(
            Canvas { gc, size in
                guard size.width > 0, size.height > 0 else { return }
                // 部材と同系色を暗くした背板。天井側(上)ほど暗い
                // (キュービーの奥は上ほど光が届かない)
                let f = 1 - shade * 0.55
                let rect = CGRect(origin: .zero, size: size)
                gc.fill(
                    Path(rect),
                    with: .linearGradient(
                        Gradient(colors: [
                            wood.dark.scaled(f).color,
                            wood.light.scaled(f).color,
                        ]),
                        startPoint: CGPoint(x: 0, y: rect.minY),
                        endPoint: CGPoint(x: 0, y: rect.maxY)))
                // 縦張りの板材: 板幅ごとに別シードのテクスチャを
                // 並べ、反転と板ごとの色膜で継ぎ目の繰り返しを
                // 隠す(テクスチャ自体は数枚生成して回す)
                if grain > 0 {
                    let plankW = Self.plankWidthPt
                    var x: CGFloat = 0
                    var idx = 0
                    while x < size.width {
                        let w = min(plankW, size.width - x)
                        let r = CGRect(
                            x: x, y: 0, width: w, height: size.height)
                        let flipX = Self.hash01(idx, salt: 81) < 0.5
                        let flipY = Self.hash01(idx, salt: 85) < 0.5
                        if let tex = Self.memberTexture(
                            wood: wood, seed: 9000 + idx % 3,
                            pxW: Int(plankW.rounded()),
                            pxH: Int(size.height.rounded()),
                            alongX: false,
                            mmAcross: Double(plankW) * Self.mmPerPt,
                            knotP: Self.plankKnotChance) {
                            gc.drawLayer { layer in
                                layer.clip(to: Path(r))
                                layer.opacity = grain
                                layer.translateBy(
                                    x: x + (flipX ? w : 0),
                                    y: flipY ? size.height : 0)
                                layer.scaleBy(
                                    x: flipX ? -1 : 1,
                                    y: flipY ? -1 : 1)
                                layer.draw(
                                    Image(nsImage: tex),
                                    in: CGRect(
                                        x: 0, y: 0,
                                        width: w, height: size.height))
                            }
                        }
                        // 板ごとの色膜(部材の色膜と同系)
                        let warm = Self.hash01(idx, salt: 82) < 0.5
                        let to = Self.pieceTintOpacity
                            * (0.4 + 0.6 * Self.hash01(idx, salt: 83))
                        gc.fill(
                            Path(r),
                            with: .color(
                                (warm
                                 ? Color(red: 0.50, green: 0.30, blue: 0.12)
                                 : Color(red: 0.78, green: 0.60, blue: 0.35))
                                .opacity(to)))
                        x += plankW
                        idx += 1
                    }
                    // 天井側(上)ほど暗い背板の陰影を
                    // テクスチャの上にも掛ける
                    gc.fill(
                        Path(rect),
                        with: .linearGradient(
                            Gradient(colors: [
                                .black.opacity(0.25 * shade),
                                .black.opacity(0.05 * shade),
                            ]),
                            startPoint: CGPoint(x: 0, y: rect.minY),
                            endPoint: CGPoint(x: 0, y: rect.maxY)))
                }
                // パティーナ: 奥の低い位置ほど経年で飴色に沈む
                if age > 0 {
                    gc.fill(
                        Path(rect),
                        with: .linearGradient(
                            Gradient(colors: [
                                .clear,
                                Color(red: 0.35, green: 0.20, blue: 0.06)
                                    .opacity(0.12 * age),
                            ]),
                            startPoint: CGPoint(x: 0, y: rect.minY),
                            endPoint: CGPoint(x: 0, y: rect.maxY)))
                }
            }
            // 背面なのでセルのヒット判定には影響しないが、空き領域への
            // タップを背板が食わないよう保険を掛けておく
            .allowsHitTesting(false)
        )
    }

    // MARK: - (f) グリッド前面(格子枠+保持ロッド)

    func shelfOverlay(context: ShelfStructureContext) -> AnyView? {
        let wood = resolvedWood(context: context)
        let t = resolvedThickness(context: context)
        let dt = resolvedDividerThickness(context: context)
        let rods = resolvedRods(context: context)
        let grain = resolvedGrain(context: context)
        let age = resolvedAge(context: context)
        let cell = context.cellSize
        let cols = context.gridColumns
        let rows = context.gridRows
        // 枠もロッドも描くものが無ければオーバーレイ自体を返さない
        // (無効時と同じく描画の影響ゼロにする)
        guard t > 0 || dt > 0 || rods > 0 else { return nil }

        // 内部部材の厚さ/幅: 行間・列間の帯に収め、両側に1pt以上の
        // 隙間(背板の見える部分)を残す。外周部材は全厚のまま。
        // 縦仕切りは水平板より細い別パラメータ(実物は横板が厚い)
        let hBand = max(0, min(t, context.rowSpacing - 2))
        let vBand = max(0, min(dt, context.columnSpacing - 2))
        logAppliedOnce(
            wood: wood, thickness: t, divider: dt, rods: rods,
            grain: grain, age: age,
            shade: resolvedBackShade(context: context),
            columns: cols, rows: rows)

        return AnyView(
            Canvas { gc, size in
                guard size.width > 0, size.height > 0 else { return }

                // 行境界b(0...rows)の水平板。0=上外周、rows=下外周、
                // 中間は行間帯の中央。すべて全幅(通しの板)
                func boardRect(_ b: Int) -> CGRect {
                    if b == 0 {
                        return CGRect(
                            x: 0, y: 0, width: size.width, height: t)
                    }
                    if b == rows {
                        return CGRect(
                            x: 0, y: size.height - t,
                            width: size.width, height: t)
                    }
                    let cy = context.topPadding + CGFloat(b) * cell
                        + (CGFloat(b) - 0.5) * context.rowSpacing
                    return CGRect(
                        x: 0, y: cy - hBand / 2,
                        width: size.width, height: hBand)
                }
                // 列境界c(0...cols)の縦仕切りのx帯(y高さは行ごとに
                // 板の間で決まるのでここではxと幅だけ)
                func dividerBand(_ c: Int) -> CGRect {
                    if c == 0 {
                        return CGRect(x: 0, y: 0, width: dt, height: 0)
                    }
                    if c == cols {
                        return CGRect(
                            x: size.width - dt, y: 0, width: dt, height: 0)
                    }
                    let cx = context.edgePadding + CGFloat(c) * cell
                        + (CGFloat(c) - 0.5) * context.columnSpacing
                    return CGRect(
                        x: cx - vBand / 2, y: 0, width: vBand, height: 0)
                }

                // (1) セル内側の陰(レコードが枠の奥に納まる表現)。
                //     枠より先に描く: 外周部材は余白を越えてセルへ
                //     重なるので、その下の影は部材に隠れる
                for r in 0..<rows {
                    for c in 0..<cols {
                        Self.drawInnerShadows(
                            gc: gc,
                            cell: Self.cellRect(
                                context: context, col: c, row: r,
                                cell: cell))
                    }
                }

                // (1.5) キュービー内側4隅の汚れの蓄積(板・仕切りの
                //       接合部は汚れが溜まる。レコードにも掛かるのが自然)
                if age > 0 {
                    for r in 0..<rows {
                        for c in 0..<cols {
                            let cr = Self.cellRect(
                                context: context, col: c, row: r,
                                cell: cell)
                            Self.drawCornerGrime(
                                gc: gc, cell: cr, age: age)
                        }
                    }
                }

                // (2) 水平板(全幅通し)。板ごとに輝度を揺らす
                for b in 0...rows {
                    let rect = boardRect(b)
                    let brightness = 1
                        + (Self.hash01(b, salt: 3) - 0.5)
                            * Self.pieceBrightnessJitter * 2
                    Self.drawHorizontalBoard(
                        gc: gc, rect: rect, wood: wood,
                        brightness: brightness, grain: grain,
                        age: age,
                        depth: Double(rect.midY / size.height),
                        piece: b)
                    // 見切りのホコリ: 内部板の直上の隙間に溜まる薄い埃
                    if age > 0 && b > 0 && b < rows {
                        gc.fill(
                            Path(CGRect(
                                x: rect.minX, y: rect.minY - 1,
                                width: rect.width, height: 1)),
                            with: .color(Color(white: 0.8)
                                .opacity(0.14 * age)))
                    }
                }

                // (2.5) 手垢の艶: キュービー手前中央の板面(レコードの
                //       出し入れで指が当たる場所)が黒ずんで半艶になる。
                //       縦仕切りより前に描くので端は仕切りに隠れる
                if age > 0 {
                    for r in 0..<rows {
                        let board = boardRect(r + 1)
                        for c in 0..<cols {
                            let cr = Self.cellRect(
                                context: context, col: c, row: r,
                                cell: cell)
                            let sheen = age
                                * (0.5 + 0.5 * Self.hash01(
                                    r * 31 + c * 7, salt: 117))
                            gc.fill(
                                Path(ellipseIn: CGRect(
                                    x: cr.midX - cell * 0.28,
                                    y: board.midY - board.height * 0.6,
                                    width: cell * 0.56,
                                    height: board.height * 1.2)),
                                with: .color(.black.opacity(0.09 * sheen)))
                            gc.fill(
                                Path(ellipseIn: CGRect(
                                    x: cr.midX - cell * 0.20,
                                    y: board.midY - board.height * 0.45,
                                    width: cell * 0.40,
                                    height: board.height * 0.8)),
                                with: .color(
                                    Color(red: 0.95, green: 0.85, blue: 0.7)
                                        .opacity(0.05 * sheen)))
                        }
                    }
                }

                // (3) 保持ロッド(全キュービー)。両端の2ptは後で描く
                //     縦仕切りの下に潜るので、ここで先に描く
                if rods > 0 {
                    let fracs = rods == 1
                        ? Self.rodFractions1 : Self.rodFractions2
                    for r in 0..<rows {
                        for c in 0..<cols {
                            let cellRect = Self.cellRect(
                                context: context, col: c, row: r,
                                cell: cell)
                            for f in fracs {
                                Self.drawRod(
                                    gc: gc, cell: cellRect, fraction: f)
                            }
                        }
                    }
                }

                // (4) 縦仕切り。水平板の間に分節して入る
                //     (ロッド端・左右の内側影より手前)
                for c in 0...cols {
                    let band = dividerBand(c)
                    for r in 0..<rows {
                        let top = boardRect(r).maxY
                        let bottom = boardRect(r + 1).minY
                        guard bottom > top else { continue }
                        let rect = CGRect(
                            x: band.minX, y: top,
                            width: band.width, height: bottom - top)
                        // 節ごとに別の輝度(縦材も1本ずつ別個体)
                        let piece = c * (rows + 1) + r
                        let brightness = 1
                            + (Self.hash01(piece, salt: 5) - 0.5)
                                * Self.pieceBrightnessJitter * 2
                        Self.drawVerticalDivider(
                            gc: gc, rect: rect, wood: wood,
                            brightness: brightness, grain: grain,
                            age: age,
                            depth: Double(rect.midY / size.height),
                            piece: piece)
                    }
                }

                // (5) 仕切り面上の経年効果(縦仕切りの最前面に乗るので
                //     最後に描く): 接合部の釘穴 + ロッド端の黒ずみ
                if age > 0 {
                    for c in 1..<cols {
                        let band = dividerBand(c)
                        for r in 0..<rows {
                            let top = boardRect(r).maxY
                            let bottom = boardRect(r + 1).minY
                            guard bottom > top else { continue }
                            let seg = CGRect(
                                x: band.minX, y: top,
                                width: band.width,
                                height: bottom - top)
                            // 釘穴: 節の上下端(横板との接合)近くの
                            // 小さな暗い点と明るいフチ
                            for endY in [seg.minY + 2.5, seg.maxY - 2.5] {
                                let salt = 111 + Double(
                                    c * 97 + r * 13 + Int(endY))
                                guard Self.hash01(0, salt: salt)
                                    < 0.4 * age else { continue }
                                let nx = seg.midX
                                    + (Self.hash01(1, salt: salt) - 0.5)
                                        * band.width * 0.4
                                gc.fill(
                                    Path(ellipseIn: CGRect(
                                        x: nx - 0.8, y: endY - 0.8,
                                        width: 1.6, height: 1.6)),
                                    with: .color(.black
                                        .opacity(0.45 * age)))
                                gc.fill(
                                    Path(ellipseIn: CGRect(
                                        x: nx - 0.5, y: endY - 0.3,
                                        width: 1.0, height: 1.0)),
                                    with: .color(.white
                                        .opacity(0.25 * age)))
                            }
                            // ロッド端の黒ずみ: ロッドが差し込む
                            // 仕切りの内側の縁が触り続けて汚れる
                            if rods > 0 {
                                let fracs = rods == 1
                                    ? Self.rodFractions1
                                    : Self.rodFractions2
                                let cr = Self.cellRect(
                                    context: context, col: c, row: r,
                                    cell: cell)
                                for f in fracs {
                                    let ry = cr.minY + cell * f
                                    for ex in [seg.minX + 1.2,
                                               seg.maxX - 1.2] {
                                        gc.fill(
                                            Path(ellipseIn: CGRect(
                                                x: ex - 1.8,
                                                y: ry - 1.4,
                                                width: 3.6,
                                                height: 2.8)),
                                            with: .color(.black
                                                .opacity(0.14 * age)))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // 枠・ロッドがジャケットのタップ再生・D&D・右クリック・
            // ドロップゾーンのヒット判定を食わないようにする(必須)
            .allowsHitTesting(false)
        )
    }

    // MARK: - 描画パーツ

    /// セル(col,row)の矩形(padding込みフレーム座標)
    private static func cellRect(
        context: ShelfStructureContext, col: Int, row: Int, cell: CGFloat
    ) -> CGRect {
        CGRect(
            x: context.edgePadding
                + CGFloat(col) * (cell + context.columnSpacing),
            y: context.topPadding
                + CGFloat(row) * (cell + context.rowSpacing),
            width: cell, height: cell)
    }

    /// キュービー内側の陰。上の板の落ち影が最も強く、左右の仕切りの
    /// 陰は薄く、下端はわずかな接触影(枠の奥に納まる奥行き)
    private static func drawInnerShadows(gc: GraphicsContext, cell: CGRect) {
        // 上: セル高の20%を黒0.30→0で
        let sh = cell.height * innerTopShadowDepth
        gc.fill(
            Path(CGRect(
                x: cell.minX, y: cell.minY,
                width: cell.width, height: sh)),
            with: .linearGradient(
                Gradient(colors: [
                    .black.opacity(innerTopShadowOpacity), .clear,
                ]),
                startPoint: CGPoint(x: 0, y: cell.minY),
                endPoint: CGPoint(x: 0, y: cell.minY + sh)))
        // 左右: セル幅の7%を黒0.18→0で
        let sw = cell.width * innerSideShadowWidth
        gc.fill(
            Path(CGRect(
                x: cell.minX, y: cell.minY,
                width: sw, height: cell.height)),
            with: .linearGradient(
                Gradient(colors: [
                    .black.opacity(innerSideShadowOpacity), .clear,
                ]),
                startPoint: CGPoint(x: cell.minX, y: 0),
                endPoint: CGPoint(x: cell.minX + sw, y: 0)))
        gc.fill(
            Path(CGRect(
                x: cell.maxX - sw, y: cell.minY,
                width: sw, height: cell.height)),
            with: .linearGradient(
                Gradient(colors: [
                    .clear, .black.opacity(innerSideShadowOpacity),
                ]),
                startPoint: CGPoint(x: cell.maxX - sw, y: 0),
                endPoint: CGPoint(x: cell.maxX, y: 0)))
        // 下端: わずかな接触影(0→黒0.14)
        let bh = cell.height * innerBottomShadowDepth
        gc.fill(
            Path(CGRect(
                x: cell.minX, y: cell.maxY - bh,
                width: cell.width, height: bh)),
            with: .linearGradient(
                Gradient(colors: [
                    .clear, .black.opacity(innerBottomShadowOpacity),
                ]),
                startPoint: CGPoint(x: 0, y: cell.maxY - bh),
                endPoint: CGPoint(x: 0, y: cell.maxY)))
    }

    /// 水平板1枚。上面→下面の縦グラデーションの本体 + 部材別
    /// シードの木目テクスチャ + 部材ごとの色相ばらつき +
    /// パティーナ + 稜線 + 前縁の剥げ + 傷 + 輪ジミ
    private static func drawHorizontalBoard(
        gc: GraphicsContext, rect: CGRect, wood: Wood,
        brightness: Double, grain: Double, age: Double,
        depth: Double, piece: Int
    ) {
        gc.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(colors: [
                    wood.light.scaled(brightness).color,
                    wood.dark.scaled(brightness).color,
                ]),
                startPoint: CGPoint(x: 0, y: rect.minY),
                endPoint: CGPoint(x: 0, y: rect.maxY)))
        // 木目テクスチャ: 部材ごとに別シードで生成した
        // フィールドベースの木目(成長輪・カテドラル・節・細スジ・
        // トーンむら込み)。grainはそのまま不透明度 —
        // 0で下のフラットな板だけが残る。上面を光が当たる
        // 板の陰影はテクスチャの上にも薄く掛ける
        if grain > 0, let tex = Self.memberTexture(
            wood: wood, seed: piece,
            pxW: Int(rect.width.rounded()),
            pxH: Int(rect.height.rounded()),
            alongX: true,
            mmAcross: Double(rect.height) * mmPerPt,
            knotP: boardKnotChance) {
            gc.drawLayer { layer in
                layer.opacity = grain
                layer.draw(Image(nsImage: tex), in: rect)
            }
            gc.fill(
                Path(rect),
                with: .linearGradient(
                    Gradient(colors: [
                        .white.opacity(0.08),
                        .black.opacity(0.10),
                    ]),
                    startPoint: CGPoint(x: 0, y: rect.minY),
                    endPoint: CGPoint(x: 0, y: rect.maxY)))
        }
        // 部材ごとの色相ばらつき: 別個体の板に見えるよう
        // 琥珀/褐色の薄い色膜を重ねる。grainとは独立 —
        // grain=0でも板が全部同色に見えないよう常に掛ける
        let warm = hash01(piece, salt: 57) < 0.5
        let pieceTint = pieceTintOpacity
            * (0.4 + 0.6 * hash01(piece, salt: 58))
        gc.fill(
            Path(rect),
            with: .color(
                (warm
                 ? Color(red: 0.50, green: 0.30, blue: 0.12)
                 : Color(red: 0.78, green: 0.60, blue: 0.35))
                .opacity(pieceTint)))
        // パティーナ: 経年でニスが飴色になる色膜(下の段ほど濃い)と、
        // 上の段ほど日に焼けて白けるムラ(板ごとにばらつく)
        if age > 0 {
            gc.fill(
                Path(rect),
                with: .color(
                    Color(red: 0.42, green: 0.26, blue: 0.08)
                        .opacity(age * (0.07 + 0.09 * depth))))
            let bleach = age * (1 - depth)
                * (0.35 + 0.65 * hash01(piece, salt: 95))
            if bleach > 0.02 {
                gc.fill(
                    Path(rect),
                    with: .color(
                        Color(red: 0.95, green: 0.88, blue: 0.72)
                            .opacity(bleach * 0.22)))
            }
        }
        // 稜線: 天面が光を拾う1pt / 下端の陰になる1pt
        gc.fill(
            Path(CGRect(
                x: rect.minX, y: rect.minY, width: rect.width, height: 1)),
            with: .color(.white.opacity(edgeLightOpacity)))
        gc.fill(
            Path(CGRect(
                x: rect.minX, y: rect.maxY - 1,
                width: rect.width, height: 1)),
            with: .color(.black.opacity(edgeDarkOpacity)))
        // 前縁の剥げ: 塗装がまだらに落ちて白い木肌が見える短冊
        if age > 0 {
            let wearN = Int(hash01(piece, salt: 93) * 3.99)
            for k in 0..<wearN {
                let salt = 96 + Double(piece) * 4.9 + Double(k) * 6.7
                let w = 3 + 10 * hash01(k, salt: salt)
                let x = rect.minX + rect.width
                    * (0.03 + 0.94 * hash01(k, salt: salt + 1.0))
                gc.fill(
                    Path(CGRect(
                        x: x, y: rect.minY,
                        width: min(w, rect.maxX - x), height: 1.2)),
                    with: .color(
                        Color(red: 0.86, green: 0.73, blue: 0.52)
                            .opacity((0.25 + 0.3
                                * hash01(k, salt: salt + 2.0)) * age)))
            }
        }
        // 傷: 木目を横切る短い線(暗い溝傷と、擦れて下地の白木が
        // 見える浅い傷を混ぜる)。木目とは別系なのでgrain=0でも出る
        if age > 0 {
            let nScratches = Int(hash01(piece, salt: 98) * 2.99)
            for k in 0..<nScratches {
                let salt = 99 + Double(piece) * 3.1 + Double(k) * 7.7
                let light = hash01(k, salt: salt + 0.3) < 0.3
                let len = 6 + 30 * hash01(k, salt: salt + 1.0)
                let x = rect.minX + rect.width
                    * (0.05 + 0.9 * hash01(k, salt: salt + 2.0))
                let y = rect.minY + rect.height
                    * (0.2 + 0.6 * hash01(k, salt: salt + 3.0))
                let ang = (hash01(k, salt: salt + 4.0) - 0.5) * 0.8
                var p = Path()
                p.move(to: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(
                    x: x + len * cos(ang), y: y + len * sin(ang)))
                gc.stroke(
                    p, with: .color(
                        (light
                         ? Color(red: 0.9, green: 0.8, blue: 0.62)
                         : grainDark)
                        .opacity((0.15 + 0.2
                            * hash01(k, salt: salt + 5.0)) * age)),
                    lineWidth: light ? 0.7 : 0.6)
            }
            // 輪ジミ: 横板に置かれた瓶やグラスの跡
            if hash01(piece, salt: 103) < 0.28 * age {
                let r = 4 + 5 * hash01(piece, salt: 104)
                let cx = rect.minX + rect.width
                    * (0.15 + 0.7 * hash01(piece, salt: 105))
                var ring = Path()
                ring.addEllipse(in: CGRect(
                    x: cx - r, y: rect.midY - r * 0.55,
                    width: r * 2, height: r * 1.1))
                gc.stroke(
                    ring,
                    with: .color(grainDark.opacity(0.16 * age)),
                    lineWidth: 1.0)
            }
        }
    }

    /// 縦仕切り1節。左端→右端のグラデーションの本体 + 節ごと
    /// 別シードの縦方向木目テクスチャ + 左端の明るい稜線1pt +
    /// 右端の暗い稜線1pt
    private static func drawVerticalDivider(
        gc: GraphicsContext, rect: CGRect, wood: Wood,
        brightness: Double, grain: Double, age: Double,
        depth: Double, piece: Int
    ) {
        gc.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(colors: [
                    wood.light.scaled(brightness).color,
                    wood.dark.scaled(brightness).color,
                ]),
                startPoint: CGPoint(x: rect.minX, y: 0),
                endPoint: CGPoint(x: rect.maxX, y: 0)))
        // 木目テクスチャ(水平板と同じフィールド生成を縦方向に。
        // grainは不透明度)。左端が光を受ける面の陰影も
        // テクスチャの上に薄く掛ける
        if grain > 0, let tex = Self.memberTexture(
            wood: wood, seed: piece,
            pxW: Int(rect.width.rounded()),
            pxH: Int(rect.height.rounded()),
            alongX: false,
            mmAcross: Double(rect.width) * mmPerPt,
            knotP: dividerKnotChance) {
            gc.drawLayer { layer in
                layer.opacity = grain
                layer.draw(Image(nsImage: tex), in: rect)
            }
            gc.fill(
                Path(rect),
                with: .linearGradient(
                    Gradient(colors: [
                        .white.opacity(0.08),
                        .black.opacity(0.10),
                    ]),
                    startPoint: CGPoint(x: rect.minX, y: 0),
                    endPoint: CGPoint(x: rect.maxX, y: 0)))
        }
        // 部材ごとの色相ばらつき(水平板と同じ色膜。
        // grainとは独立に常に掛ける)
        let warm = hash01(piece, salt: 67) < 0.5
        let pieceTint = pieceTintOpacity
            * (0.4 + 0.6 * hash01(piece, salt: 68))
        gc.fill(
            Path(rect),
            with: .color(
                (warm
                 ? Color(red: 0.50, green: 0.30, blue: 0.12)
                 : Color(red: 0.78, green: 0.60, blue: 0.35))
                .opacity(pieceTint)))
        // パティーナ(水平板と同じ飴色膜+上段の日焼け)
        if age > 0 {
            gc.fill(
                Path(rect),
                with: .color(
                    Color(red: 0.42, green: 0.26, blue: 0.08)
                        .opacity(age * (0.07 + 0.09 * depth))))
            let bleach = age * (1 - depth)
                * (0.35 + 0.65 * hash01(piece, salt: 95))
            if bleach > 0.02 {
                gc.fill(
                    Path(rect),
                    with: .color(
                        Color(red: 0.95, green: 0.88, blue: 0.72)
                            .opacity(bleach * 0.22)))
            }
        }
        gc.fill(
            Path(CGRect(
                x: rect.minX, y: rect.minY,
                width: 1, height: rect.height)),
            with: .color(.white.opacity(edgeLightOpacity)))
        gc.fill(
            Path(CGRect(
                x: rect.maxX - 1, y: rect.minY,
                width: 1, height: rect.height)),
            with: .color(.black.opacity(edgeDarkOpacity)))
        // 前縁の剥げ: 左縁(手前側)の塗装がまだらに落ちた白木筋と、
        // 節の上下端の小さな欠け
        if age > 0 {
            let wearN = Int(hash01(piece, salt: 93) * 3.99)
            for k in 0..<wearN {
                let salt = 96 + Double(piece) * 4.9 + Double(k) * 6.7
                let h = 3 + 12 * hash01(k, salt: salt)
                let y = rect.minY + rect.height
                    * (0.03 + 0.94 * hash01(k, salt: salt + 1.0))
                gc.fill(
                    Path(CGRect(
                        x: rect.minX, y: y,
                        width: 1.2, height: min(h, rect.maxY - y))),
                    with: .color(
                        Color(red: 0.86, green: 0.73, blue: 0.52)
                            .opacity((0.25 + 0.3
                                * hash01(k, salt: salt + 2.0)) * age)))
            }
            for endY in [rect.minY + 1.5, rect.maxY - 1.5] {
                let salt = 97 + Double(piece) * 2.3 + Double(endY)
                guard hash01(0, salt: salt) < 0.25 * age
                else { continue }
                let cx = rect.minX + rect.width
                    * (0.3 + 0.4 * hash01(1, salt: salt))
                gc.fill(
                    Path(ellipseIn: CGRect(
                        x: cx - 1.1, y: endY - 1.6,
                        width: 2.2, height: 3.2)),
                    with: .color(
                        Color(red: 0.88, green: 0.76, blue: 0.55)
                            .opacity(0.35 * age)))
            }
        }
        // 傷: 縦材の面を横切る短い線(水平板と同じ系統を縦に)
        if age > 0 {
            let nScratches = Int(hash01(piece, salt: 98) * 2.99)
            for k in 0..<nScratches {
                let salt = 99 + Double(piece) * 3.1 + Double(k) * 7.7
                let light = hash01(k, salt: salt + 0.3) < 0.3
                let len = 6 + 26 * hash01(k, salt: salt + 1.0)
                let x = rect.minX + rect.width
                    * (0.2 + 0.6 * hash01(k, salt: salt + 2.0))
                let y = rect.minY + rect.height
                    * (0.05 + 0.9 * hash01(k, salt: salt + 3.0))
                let ang = (hash01(k, salt: salt + 4.0) - 0.5) * 0.8
                var p = Path()
                p.move(to: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(
                    x: x + len * sin(ang), y: y + len * cos(ang)))
                gc.stroke(
                    p, with: .color(
                        (light
                         ? Color(red: 0.9, green: 0.8, blue: 0.62)
                         : grainDark)
                        .opacity((0.15 + 0.2
                            * hash01(k, salt: salt + 5.0)) * age)),
                    lineWidth: light ? 0.7 : 0.6)
            }
        }
    }

    /// キュービー内側4隅の汚れの蓄積。板と仕切りの接合部には
    /// 埃や手垢が溜まって暗くなる(レコードにも自然に掛かる)
    private static func drawCornerGrime(
        gc: GraphicsContext, cell: CGRect, age: Double
    ) {
        let rad = cell.width * 0.14
        for (cx, cy) in [
            (cell.minX + rad * 0.7, cell.minY + rad * 0.7),
            (cell.maxX - rad * 0.7, cell.minY + rad * 0.7),
            (cell.minX + rad * 0.7, cell.maxY - rad * 0.7),
            (cell.maxX - rad * 0.7, cell.maxY - rad * 0.7),
        ] {
            gc.fill(
                Path(ellipseIn: CGRect(
                    x: cx - rad, y: cy - rad,
                    width: rad * 2, height: rad * 2)),
                with: .radialGradient(
                    Gradient(colors: [
                        .black.opacity(0.15 * age), .clear,
                    ]),
                    center: CGPoint(x: cx, y: cy),
                    startRadius: 0, endRadius: rad))
        }
    }

    /// 木目テクスチャのキャッシュキー(衝突の無い構造体キー)
    private struct TextureKey: Hashable {
        var wood: String
        var seed: Int
        var pxW: Int
        var pxH: Int
        var alongX: Bool
        var mmAcross: Double
        var knotP: Double
    }

    /// 生成済み木目テクスチャのキャッシュ(NSImage=CGImageの
    /// 薄いラッパなので、毎フレームの生成を避けるためここで
    /// 作って持つ)。Canvasの描画は毎フレーム走るので生成は
    /// 初回のみ。描画スレッドがメインとは限らないため
    /// NSLockで読み書きを囲む。パラメータ空間は離散で小さい
    /// (部材種別×サイズ×材)ので追い出しは持たない
    private static var textureCache: [TextureKey: NSImage] = [:]
    /// 生成に失敗したキー(毎フレーム再試行しないよう記録)
    private static var textureFailed: Set<TextureKey> = []
    private static let textureCacheLock = NSLock()

    /// メンバー1枚分の木目テクスチャ(生成済みならキャッシュを
    /// 返す)。pxW/pxHは出力ピクセルサイズ(=部材のptサイズその
    /// まま)、mmAcrossは木理を横切る方向の物理幅 — 輪数は
    /// 「面のmm幅÷気孔クラスの平均輪幅」で決まるので、厚い
    /// 部材ほど多くの輪が乗る
    private static func memberTexture(
        wood: Wood, seed: Int, pxW: Int, pxH: Int,
        alongX: Bool, mmAcross: Double, knotP: Double
    ) -> NSImage? {
        guard pxW > 0, pxH > 0 else { return nil }
        let key = TextureKey(
            wood: wood.rawValue, seed: seed, pxW: pxW, pxH: pxH,
            alongX: alongX, mmAcross: mmAcross, knotP: knotP)
        textureCacheLock.lock()
        if let img = textureCache[key] {
            textureCacheLock.unlock()
            return img
        }
        if textureFailed.contains(key) {
            textureCacheLock.unlock()
            return nil
        }
        textureCacheLock.unlock()

        let pc = wood.poreClass
        let start = Date()
        let img = WoodTexture.image(
            pxWidth: pxW, pxHeight: pxH,
            seed: UInt64(bitPattern: Int64(seed)),
            profile: .init(
                early: (wood.early.r, wood.early.g, wood.early.b),
                late: (wood.late.r, wood.late.g, wood.late.b),
                poreClass: pc,
                ringsAcross: (
                    mmAcross / pc.ringMeanMM.1,
                    mmAcross / pc.ringMeanMM.0),
                knotProbability: knotP),
            alongX: alongX)
        let ms = Date().timeIntervalSince(start) * 1000

        textureCacheLock.lock()
        defer { textureCacheLock.unlock() }
        guard let cg = img else {
            // 失敗はキー別に1回だけログ(毎フレーム出さない)
            textureFailed.insert(key)
            logger.error("wood texture generation failed: wood=\(wood.rawValue, privacy: .public) seed=\(seed, privacy: .public) size=\(pxW, privacy: .public)x\(pxH, privacy: .public)")
            return nil
        }
        logger.info("wood texture generated: wood=\(wood.rawValue, privacy: .public) seed=\(seed, privacy: .public) size=\(pxW, privacy: .public)x\(pxH, privacy: .public) \(ms, privacy: .public)ms")
        let ns = NSImage(
            cgImage: cg,
            size: NSSize(width: pxW, height: pxH))
        textureCache[key] = ns
        return ns
    }

    /// 保持ロッド1本。セル幅+両端2pt(仕切りの下へ潜る分)の
    /// 高さ1.75ptのカプセル。直下2ptに柔らかい落ち影、本体は
    /// 銀の縦グラデーション+上端の白いハイライト筋
    private static func drawRod(
        gc: GraphicsContext, cell: CGRect, fraction: CGFloat
    ) {
        let rect = CGRect(
            x: cell.minX - rodTuck,
            y: cell.minY + cell.height * fraction - rodHeight / 2,
            width: cell.width + rodTuck * 2,
            height: rodHeight)
        // 落ち影: ロッド直下2ptの柔らかい帯(黒0.22→0)
        let shadowRect = CGRect(
            x: rect.minX + 1, y: rect.maxY,
            width: rect.width - 2, height: rodShadowLength)
        gc.fill(
            Path(shadowRect),
            with: .linearGradient(
                Gradient(colors: [
                    .black.opacity(rodShadowOpacity), .clear,
                ]),
                startPoint: CGPoint(x: 0, y: shadowRect.minY),
                endPoint: CGPoint(x: 0, y: shadowRect.maxY)))
        // 本体: 銀色のカプセル
        gc.fill(
            Path(roundedRect: rect, cornerRadius: rodHeight / 2),
            with: .linearGradient(
                rodGradient,
                startPoint: CGPoint(x: 0, y: rect.minY),
                endPoint: CGPoint(x: 0, y: rect.maxY)))
        // 上端のハイライト(金属面の反射)
        gc.fill(
            Path(roundedRect: CGRect(
                x: rect.minX + 2, y: rect.minY,
                width: rect.width - 4, height: 0.6),
                cornerRadius: 0.3),
            with: .color(.white.opacity(rodEdgeOpacity)))
    }

    // MARK: - パラメータ解決

    private func resolvedWood(context: ShelfStructureContext) -> Wood {
        let raw = context.text(Param.wood, default: Self.defaultWood.rawValue)
        return Wood(rawValue: raw) ?? Self.defaultWood
    }

    /// 水平板の厚さ。内部部材は行間帯に別途クランプするので、
    /// ここでは0以上にだけ揃える
    private func resolvedThickness(context: ShelfStructureContext) -> CGFloat {
        CGFloat(max(0, context.number(
            Param.boardThickness, default: Self.defaultBoardThickness)))
    }

    /// 縦仕切りの太さ。内部部材は列間帯に別途クランプするので、
    /// ここでは0以上にだけ揃える
    private func resolvedDividerThickness(
        context: ShelfStructureContext
    ) -> CGFloat {
        CGFloat(max(0, context.number(
            Param.dividerThickness, default: Self.defaultDividerThickness)))
    }

    /// 保持ロッドの本数(0/1/2)
    private func resolvedRods(context: ShelfStructureContext) -> Int {
        min(2, max(0, Int(context.number(
            Param.rods, default: Self.defaultRods).rounded())))
    }

    /// 木目の強さ(0-1)
    private func resolvedGrain(context: ShelfStructureContext) -> Double {
        min(1, max(0, context.number(Param.grain, default: Self.defaultGrain)))
    }

    /// ビンテージ感(0-1)。パティーナ・剥げ・手垢・傷・シミ汚れを
    /// まとめて連動させる強さ
    private func resolvedAge(context: ShelfStructureContext) -> Double {
        min(1, max(0, context.number(Param.age, default: Self.defaultAge)))
    }

    /// 背板の暗さ(0-1)
    private func resolvedBackShade(context: ShelfStructureContext) -> Double {
        min(1, max(0, context.number(
            Param.backShade, default: Self.defaultBackShade)))
    }

    /// indexだけから決まる固定の係数(0〜1)。部材ごとの輝度差や
    /// スジの位置に使う(sinハッシュ。乱数生成器や状態は持たない)
    private static func hash01(_ index: Int, salt: Double) -> Double {
        let v = sin(Double(index) * 127.1 + salt * 311.7) * 43758.5453
        return v - v.rounded(.down)
    }

    /// プロセス内で最初の1回だけ解決値を記録する
    /// (描画のたびに呼ばれるので、毎回ログは出さない。
    ///  有効/無効とパラメータ確定のログはSettingsView側が出す)
    private static var didLogApplied = false
    private func logAppliedOnce(wood: Wood, thickness: CGFloat,
                              divider: CGFloat, rods: Int,
                              grain: Double, age: Double, shade: Double,
                              columns: Int, rows: Int) {
        guard !Self.didLogApplied else { return }
        Self.didLogApplied = true
        Self.logger.notice("wooden-shelf applied: wood=\(wood.rawValue, privacy: .public) thickness=\(thickness, privacy: .public) divider=\(divider, privacy: .public) rods=\(rods, privacy: .public) grain=\(grain, privacy: .public) age=\(age, privacy: .public) backShade=\(shade, privacy: .public) grid=\(columns, privacy: .public)x\(rows, privacy: .public)")
    }
}
