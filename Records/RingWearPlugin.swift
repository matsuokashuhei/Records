//
//  RingWearPlugin.swift
//  Records
//
//  プラグイン「リングウェア」(P7)。
//  中身のレコード盤の形がジャケット表面にうっすら浮き出る、
//  円形のすり跡を再現する。実物の特徴(70枚調査):
//   - 盤の外周に沿ったうっすら明るいリング(表面印刷が薄く削れて
//     明るくなる)。稀に盤の縁が食い込んだ暗い跡になる個体もある
//   - リング内側のごく薄い色調差(盤が密着して擦れた面)
//   - 半径は盤の直径に近い(ジャケット一辺の85〜95%程度)
//   - 円心はジャケット中心から微妙にずれていることが多い
//   - 全てのレコードに出るわけではない
//
//  描画は jacketOverlay フックで、セル中心±微小オフセットを円心とする
//  複数の「軌跡リング」を重ねて返す。リングは完全な一様円ではなく、
//  長年の収納で盤の位置が微妙に変わった想定で:
//   - 主軌跡1本 + 残像リング1〜2本(より薄く。ずれた位置 or
//     ほぼ同心で半径だけ違う二重リング)
//   - 各軌跡を短い弧(セクター)に分割し、弧ごとに濃さ・太さを変える
//   - 濃さは円周上の角度プロファイル(1〜3個のvon Mises bumpの
//     確率積混合)で決め、「狭い弧だけ濃い」「半周+局所ピーク」
//     「ほぼ一周うっすら」がレコードごとに混在する。
//     半数のbumpは下半周に偏る(収納時に盤が下へ寄るため)
//   - 色調は明るい擦れ/暗い食い込み/中間調(印刷が削れて背景の
//     明暗が中間調に近づく擦れ)の3系統
//   - 約半数の軌跡は細線に加えて「帯」(盤の面の太いすり跡)を持つ
//  半径・円心のずれ・線の太さ・濃さ・明暗・軌跡パターンはセル座標からの
//  sinハッシュ(SleeveGlossPlugin.hash01と同じ方式)で決定論的に
//  ばらつかせ、出現率はfrequencyパラメータで制御する
//  (ハッシュ値<frequencyのセルだけ描画)。
//  非該当セルと実効濃さ≈0ではnilを返すので、無効時と同じく
//  描画・ヒットの影響はゼロ(P7-4)。
//

import SwiftUI
import os

struct RingWearPlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Records", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)
    private enum Param {
        /// リングの濃さ(0〜1)
        static let visibility = "visibility"
        /// セルがリングウェアを持つ確率(0〜1)
        static let frequency = "frequency"
    }

    /// デフォルトの濃さ
    static let defaultVisibility: Double = 0.5
    /// デフォルトの出現率
    static let defaultFrequency: Double = 0.7

    let id = "ring-wear"
    let displayName = "Ring Wear"

    init() {
        Self.logger.info("plugin registered: ring-wear ('Ring Wear')")
    }

    var parameterSpecs: [PluginParameterSpec] {
        [
            .slider(.init(
                id: Param.visibility,
                label: "Visibility",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultVisibility
            )),
            .slider(.init(
                id: Param.frequency,
                label: "Frequency",
                range: 0...1,
                step: 0.05,
                defaultValue: Self.defaultFrequency
            )),
        ]
    }

    // MARK: - (b) ジャケットへのオーバーレイ重畳

    /// sinハッシュのsalt値。同一セルから複数の独立した
    /// 疑似乱数を取るための種。値そのものに意味はなく、
    /// 同じsaltには同じ用途を割り当てる(変えると全セルの
    /// パターンが変わるので一度決めたら変更しない)
    private enum Salt {
        /// このセルにリングウェアが出るかの判定用
        static let presence = 1.0
        /// リング半径のばらつき用
        static let radius = 2.0
        /// 円心のずれ(x成分)用
        static let offsetX = 3.0
        /// 円心のずれ(y成分)用
        static let offsetY = 4.0
        /// リング線の太さのばらつき用
        static let lineWidth = 5.0
        /// 濃さのばらつき用
        static let strength = 6.0
        /// 明るい/中間調/暗いリングの振り分け用
        static let tone = 7.0
        /// リングのぼかし量のばらつき用
        static let blur = 8.0
        /// 内側の色調差の強さ(面として浮き出る個体)用
        static let face = 9.0
        /// 残像リングの本数用
        static let ghostCount = 10.0
        /// 軌跡ごとの属性帯の基点(軌跡iは traceBase + i*traceStride。
        /// 帯内: +1〜+5=軌跡属性、+6=濃い区間の個数、+7/+8=base、
        /// +9=帯の有無/太さ、+10+j=セクターjの濃さ、+20+j=セクターjの
        /// 太さ、+30+i*4/+31+i*4/+32+i*4/+33+i*4=bump i の
        /// 中心角/集中度/強さ/角度モード、+42=残像の同心/ずれモード)
        static let traceBase = 20.0
        /// 軌跡ごとのsalt帯のストライド(帯内最大+42なので100あれば衝突しない)
        static let traceStride = 100.0
    }

    /// リング半径の範囲(セル一辺に対する比)。
    /// 実物の盤直径≈ジャケット一辺の85〜95% → 半径0.42〜0.47倍
    private static let radiusRange: ClosedRange<Double> = 0.42...0.47

    /// 円心のずれの最大量(セル一辺に対する比、片側)。
    /// 実物の「微妙にずれている」程度。大きすぎると盤ではなく
    /// 単なる円に見えるので数%に抑える
    private static let maxCenterOffset: Double = 0.035

    /// リング線の太さの範囲(pt)。印刷の削れ幅に見立てた細い帯。
    /// 太すぎると模様に見えるので数ptまで
    private static let lineWidthRange: ClosedRange<Double> = 1.2...3.0

    /// リング線のぼかし半径の範囲(pt)。
    /// すり跡はエッジが曖昧なので必ず少しぼかす
    private static let ringBlurRange: ClosedRange<Double> = 0.6...2.0

    /// 内側の色調差のぼかし半径(pt)。
    /// 色調差は「面」の変化なのでリング線より強くぼかして
    /// 輪郭を消す
    private static let innerBlur: Double = 6

    /// 濃さのセル間ばらつきの下限(この値〜1.0倍)。
    /// visibility設定に対し0.7〜1.0倍を掛ける
    private static let strengthFloor: Double = 0.7

    /// 実効濃さがこれ以下ならオーバーレイ自体を返さない閾値。
    /// 肉眼でほぼ見えない跡の描画コストを省く下限
    private static let minEffectiveStrength: Double = 0.02

    /// 暗いリング(盤の縁が食い込んだ影)になる確率。
    /// 実物は圧倒的に明るいすり跡が多いので少数派に留める
    private static let darkRingChance: Double = 0.15

    /// 中間調リングになる確率(暗いリング判定の後に振り分け)。
    /// 印刷が削れて地色が透けた擦れは、背景の明部では暗く
    /// 暗部では明るく見える=中間調への近づきとして表現する
    private static let neutralRingChance: Double = 0.3

    /// リングの色調の系統
    private enum RingTone {
        /// 表面印刷が薄く削れた白っぽいすり跡(最多)
        case bright
        /// 明暗を中間調へ近づける擦れ(明部で暗く・暗部で明るく見える)
        case neutral
        /// 盤の縁が食い込んだ暗い影
        case dark

        var color: Color {
            switch self {
            case .bright: return .white
            case .neutral: return Color(white: 0.5)
            case .dark: return .black
            }
        }

        /// 不透明度係数(実効濃さに掛ける)
        var opacityCoefficient: Double {
            switch self {
            case .bright: return 0.4
            case .neutral: return 0.35
            case .dark: return 0.3
            }
        }
    }

    /// リング内側の色調差の不透明度係数。
    /// 「ごく薄い色調差」なのでリングよりかなり薄い
    private static let innerOpacityRatio: Double = 0.05

    /// 内側色調差の個体差の上限(1+この値倍までハッシュで増やす)。
    /// 盤の面全体が色調差として浮き出る個体を表現する
    private static let faceBoostMax: Double = 3.0

    /// 「帯」(細線ではなく盤の面の太いすり跡)を持つ軌跡の確率
    private static let bandChance: Double = 0.5

    /// 帯の太さの範囲(軌跡半径に対する比)
    private static let bandWidthRange: ClosedRange<Double> = 0.03...0.08

    /// 帯の濃さ(軌跡のセクター濃さに掛ける係数)。
    /// 広い面なので細線より薄くする
    private static let bandOpacityFactor: Double = 0.35

    /// 1つの軌跡リングを分割する弧(セクター)の数。
    /// 弧ごとに濃さ・太さを変えて一様円にならないようにする
    private static let sectorCount = 8

    /// 隣接セクターの重なり量(円周比)。弧を少しだけ伸ばして
    /// 境界の隙間を埋め、blurで滑らかに繋げる
    private static let sectorOverlap: Double = 0.012

    /// 残像リングの本数の範囲(主軌跡以外に重ねる薄い環)。
    /// 盤の収納位置が年単位で1〜2回変わった想定
    private static let ghostCountRange = 1...2

    /// 残像リングの円心ずれ(主軌跡の円心からの距離、
    /// セル一辺に対する比)。盤が少しずれて入っていた程度
    private static let ghostShiftRange: ClosedRange<Double> = 0.015...0.05

    /// 残像リングの半径差(主軌跡半径に対する比)。
    /// 実物は同じ盤なのでほぼ同径。微妙な違いだけ許す
    private static let ghostRadiusFactorRange: ClosedRange<Double> = 0.97...1.03

    /// 残像リングの濃さ(主軌跡に対する比)。過去の位置の跡は
    /// 新しい位置の跡より薄い
    private static let ghostOpacityRange: ClosedRange<Double> = 0.25...0.55

    /// 残像リングの太さ(主軌跡に対する比)
    private static let ghostWidthFactorRange: ClosedRange<Double> = 0.7...1.0

    /// 残像リングのぼかし係数(主軌跡のblurに掛ける)。
    /// 古い跡ほどエッジがにじんで曖昧なので少し強めにぼかす
    private static let ghostBlurFactor: Double = 1.25

    /// 残像が「ほぼ同心で半径だけ違う二重リング」になる確率。
    /// 残りは従来の円心ずれ(収納位置が変わった跡)
    private static let ghostConcentricChance: Double = 0.4

    /// 同心残像の円心ずれ(ごく微小。完全同心だと人工的すぎる)
    private static let ghostConcentricShiftRange: ClosedRange<Double> = 0.001...0.008

    /// 同心残像の半径差(主軌跡半径に対する±比)。
    /// 主リングと視認できる程度に離す
    private static let ghostConcentricRadiusOffset: ClosedRange<Double> = 0.015...0.055

    /// セクター濃さの下限係数(この値〜1.0にハッシュで変化)。
    /// 0にすると弧が途切れて破線になるので残す
    private static let sectorOpacityFloor: Double = 0.35

    /// セクター太さの下限係数(この値〜+0.6倍にハッシュで変化)
    private static let sectorWidthFloor: Double = 0.7

    func jacketOverlay(context: ShelfPluginContext) -> AnyView? {
        let visibility = resolvedVisibility(context: context)
        let frequency = resolvedFrequency(context: context)

        // 出現判定: ハッシュ値<frequencyのセルだけリングウェアを持つ。
        // 判定は濃さと無関係にセル座標だけで決まるので、
        // visibilityを動かしても「どのセルに出るか」は変わらない
        let hasRing = hash01(Salt.presence, context: context) < frequency

        // 濃さもセルごとにばらつかせる(visibilityの0.7〜1.0倍)
        let strength = visibility
            * (Self.strengthFloor
                + (1 - Self.strengthFloor)
                    * hash01(Salt.strength, context: context))

        // 非該当セル・実効濃さ≈0はオーバーレイ自体を返さない
        // (無効時と同じく描画・ヒットの影響ゼロにする)
        guard hasRing, strength > Self.minEffectiveStrength else {
            return nil
        }
        // ログの濃さは設定値そのまま(セルごとのばらつき後ではない)
        logAppliedOnce(visibility: visibility, frequency: frequency)

        let s = context.cellSize
        let radius = s * (Self.radiusRange.lowerBound
            + (Self.radiusRange.upperBound - Self.radiusRange.lowerBound)
                * hash01(Salt.radius, context: context))
        let offset = CGPoint(
            x: (hash01(Salt.offsetX, context: context) * 2 - 1)
                * s * Self.maxCenterOffset,
            y: (hash01(Salt.offsetY, context: context) * 2 - 1)
                * s * Self.maxCenterOffset
        )
        let lineWidth = Self.lineWidthRange.lowerBound
            + (Self.lineWidthRange.upperBound - Self.lineWidthRange.lowerBound)
                * hash01(Salt.lineWidth, context: context)
        let blur = Self.ringBlurRange.lowerBound
            + (Self.ringBlurRange.upperBound - Self.ringBlurRange.lowerBound)
                * hash01(Salt.blur, context: context)
        // 色調の振り分け: 暗い食い込み(15%)→中間調(30%)→
        // 残りは明るいすり跡
        let toneH = hash01(Salt.tone, context: context)
        let tone: RingTone = toneH < Self.darkRingChance ? .dark
            : (toneH < Self.darkRingChance + Self.neutralRingChance
                ? .neutral : .bright)
        let ringColor = tone.color
        let ringOpacity = strength * tone.opacityCoefficient

        // 内側の色調差はセルごとに強さを変える
        // (盤の面全体が浮き出る個体〜ごく薄い個体)
        let faceBoost = 1 + Self.faceBoostMax
            * pow(hash01(Salt.face, context: context), 2)
        let innerOpacity = strength * Self.innerOpacityRatio * faceBoost

        // 軌跡リング群: 主軌跡 + 盤の収納位置が変わった跡の残像
        let traces = ringTraces(
            context: context,
            radius: radius,
            offset: offset,
            lineWidth: lineWidth,
            blur: blur,
            opacity: ringOpacity
        )

        return AnyView(
            ZStack {
                // リング内側のごく薄い色調差
                // (盤が密着して擦れた面。強くぼかして輪郭を消す)
                Circle()
                    .fill(ringColor.opacity(innerOpacity))
                    .frame(width: radius * 2, height: radius * 2)
                    .blur(radius: Self.innerBlur)
                    .offset(x: offset.x, y: offset.y)
                // 軌跡リング(主+残像)。セクター分割で不規則に描く
                ForEach(traces.indices, id: \.self) { i in
                    ringTraceCanvas(traces[i], color: ringColor,
                                    context: context)
                        .blur(radius: traces[i].blur)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // オーバーレイがジャケットのタップ再生・D&D・右クリックの
            // ヒット判定を食わないようにする
            .allowsHitTesting(false)
        )
    }

    // MARK: - 軌跡リング

    /// 円周上の「残りやすい向き」1個分。
    /// von Mises分布で中心角・集中度・強さを持つ
    private struct Bump {
        /// 中心角(rad)
        let angle: Double
        /// 集中度κ。小さいほど広い弧、大きいほど局所的な弧になる
        let concentration: Double
        /// 強さ(0〜1)。bump間の強弱差を生む
        let weight: Double
    }

    /// 1本分のすり跡の軌跡。盤がある位置に収まっていた期間の
    /// 痕跡で、円心・半径・濃さ・太さ・ぼかしを持つ
    private struct RingTrace {
        /// 円心のジャケット中心からのずれ(pt)
        let center: CGPoint
        /// 半径(pt)
        let radius: CGFloat
        /// この軌跡の基準不透明度(セクター濃さに掛ける)
        let opacity: Double
        /// 基準線幅(pt)
        let lineWidth: CGFloat
        /// ぼかし半径(pt)
        let blur: CGFloat
        /// セクター乱数のsalt基点(帯内オフセットで各属性を引く)
        let salt: Double
        /// 濃い区間の角度プロファイル(1〜3個のbump)
        let bumps: [Bump]
        /// bumpの外側に残る薄さ(0〜0.1)。0なら消える区間がある
        let base: Double
        /// 「帯」の太さ(pt)。0なら帯なし(細線のみ)
        let bandWidth: CGFloat
    }

    /// 主軌跡と残像リングを生成する。残像は主軌跡の円心から
    /// 少しずれた位置に、より薄く・少しにじんで置く
    /// (盤の収納位置が長年の間に変わった跡)
    private func ringTraces(context: ShelfPluginContext,
                            radius: CGFloat, offset: CGPoint,
                            lineWidth: CGFloat, blur: CGFloat,
                            opacity: Double) -> [RingTrace] {
        let main = ringBumps(saltBase: Salt.traceBase, context: context)
        var traces = [
            RingTrace(
                center: offset,
                radius: radius,
                opacity: opacity,
                lineWidth: lineWidth,
                blur: blur,
                salt: Salt.traceBase,
                bumps: main.bumps,
                base: main.base,
                bandWidth: ringBand(saltBase: Salt.traceBase,
                                    radius: radius, context: context)
            )
        ]
        // 残像の本数(1〜2本)
        let ghosts = Self.ghostCountRange.lowerBound
            + Int(hash01(Salt.ghostCount, context: context)
                * Double(Self.ghostCountRange.count))
        for i in 0..<ghosts {
            let b = Salt.traceBase + Double(i + 1) * Salt.traceStride
            // 40%はほぼ同心で半径だけ違う二重リング、
            // 60%は円心ずれ(収納位置が変わった跡)
            let concentric = hash01(b + 42, context: context)
                < Self.ghostConcentricChance
            let dir = hash01(b + 1, context: context) * 2 * .pi
            let shift = concentric
                ? Self.ghostConcentricShiftRange
                : Self.ghostShiftRange
            let dist = context.cellSize
                * (shift.lowerBound
                    + (shift.upperBound - shift.lowerBound)
                        * hash01(b + 2, context: context))
            let rfh = hash01(b + 3, context: context)
            let rfSpan = Self.ghostConcentricRadiusOffset.upperBound
                - Self.ghostConcentricRadiusOffset.lowerBound
            let rf = concentric
                ? 1 + (rfh < 0.5 ? -1 : 1)
                    * (Self.ghostConcentricRadiusOffset.lowerBound
                        + rfSpan * (rfh < 0.5 ? rfh * 2 : (rfh - 0.5) * 2))
                : Self.ghostRadiusFactorRange.lowerBound
                    + (Self.ghostRadiusFactorRange.upperBound
                        - Self.ghostRadiusFactorRange.lowerBound) * rfh
            let of = Self.ghostOpacityRange.lowerBound
                + (Self.ghostOpacityRange.upperBound
                    - Self.ghostOpacityRange.lowerBound)
                    * hash01(b + 4, context: context)
            let wf = Self.ghostWidthFactorRange.lowerBound
                + (Self.ghostWidthFactorRange.upperBound
                    - Self.ghostWidthFactorRange.lowerBound)
                    * hash01(b + 5, context: context)
            let gb = ringBumps(saltBase: b, context: context)
            traces.append(
                RingTrace(
                    center: CGPoint(
                        x: offset.x + cos(dir) * dist,
                        y: offset.y + sin(dir) * dist
                    ),
                    radius: radius * rf,
                    opacity: opacity * of,
                    lineWidth: lineWidth * wf,
                    blur: blur * Self.ghostBlurFactor,
                    salt: b,
                    bumps: gb.bumps,
                    base: gb.base,
                    bandWidth: ringBand(saltBase: b,
                                        radius: radius * rf,
                                        context: context)
                )
            )
        }
        return traces
    }

    /// 軌跡の「濃い区間」の角度プロファイルを生成する。
    /// 円周上の正規分布に相当するvon Mises分布を1〜3個混ぜ、
    /// 個数・中心角・広さ・強さをレコードごとのハッシュで決める。
    /// 帯内salt: +6=個数、+7/+8=base、+30+i*4=中心角、
    /// +31+i*4=集中度、+32+i*4=強さ、+33+i*4=角度モード
    private func ringBumps(saltBase: Double,
                           context: ShelfPluginContext)
        -> (bumps: [Bump], base: Double) {
        // 個数: 1→40%、2→40%、3→20%
        let r = hash01(saltBase + 6, context: context)
        let count = r < 0.4 ? 1 : (r < 0.8 ? 2 : 3)
        let bumps = (0..<count).map { i in
            let a = hash01(saltBase + 30 + Double(i) * 4,
                           context: context)
            // 角度モード: 約半数は下半周に偏る(収納時に盤が
            // 下へ寄り下側が強く擦れやすい。y下向き座標系で
            // 下=π/2)。残りは円周上一様
            let angle = hash01(saltBase + 33 + Double(i) * 4,
                               context: context) < 0.5
                ? .pi / 2 + (a * 2 - 1) * .pi * 0.75
                : a * 2 * .pi
            return Bump(
                angle: angle,
                // κは0.9〜5.9で3乗ばらつき。実物は広い弧の
                // 個体が多いので小さいκ寄りに寄せる
                concentration: 0.9
                    + pow(hash01(saltBase + 31 + Double(i) * 4,
                                 context: context), 3) * 5,
                weight: 0.4
                    + hash01(saltBase + 32 + Double(i) * 4,
                             context: context) * 0.6
            )
        }
        // base: 半数は0(消える区間あり)、半数はうっすら一周残る
        let base = hash01(saltBase + 7, context: context) < 0.5
            ? 0
            : hash01(saltBase + 8, context: context) * 0.1
        return (bumps, base)
    }

    /// 軌跡の「帯」(細線ではなく盤の面の太いすり跡)の太さを
    /// 決める。約半数は帯なし(0)。帯内salt: +9
    private func ringBand(saltBase: Double, radius: CGFloat,
                          context: ShelfPluginContext) -> CGFloat {
        let h = hash01(saltBase + 9, context: context)
        guard h < Self.bandChance else { return 0 }
        let t = h / Self.bandChance
        return radius * (Self.bandWidthRange.lowerBound
            + (Self.bandWidthRange.upperBound
                - Self.bandWidthRange.lowerBound) * t)
    }

    /// 軌跡1本のCanvas描画。円をsectorCount個の弧に分け、
    /// 弧ごとに濃さ・太さをハッシュで変えて一様円にならない
    /// すり跡にする。弧はoverlap分だけ伸ばして繋げる
    private func ringTraceCanvas(_ trace: RingTrace, color: Color,
                                 context: ShelfPluginContext) -> some View {
        Canvas { gc, size in
            let c = CGPoint(
                x: size.width / 2 + trace.center.x,
                y: size.height / 2 + trace.center.y
            )
            for j in 0..<Self.sectorCount {
                let n = Double(Self.sectorCount)
                let a0 = (Double(j) / n - Self.sectorOverlap) * 2 * .pi
                let a1 = (Double(j + 1) / n + Self.sectorOverlap) * 2 * .pi
                let so = sectorOpacity(trace, sector: j, context: context)
                // 帯(盤の面の太いすり跡)。細線の内側に敷く
                if trace.bandWidth > 0 {
                    var bp = Path()
                    bp.addArc(center: c,
                              radius: trace.radius - trace.bandWidth / 2,
                              startAngle: .radians(a0),
                              endAngle: .radians(a1),
                              clockwise: false)
                    gc.stroke(
                        bp,
                        with: .color(color.opacity(
                            so * Self.bandOpacityFactor)),
                        lineWidth: trace.bandWidth
                    )
                }
                var p = Path()
                p.addArc(center: c, radius: trace.radius,
                         startAngle: .radians(a0),
                         endAngle: .radians(a1),
                         clockwise: false)
                gc.stroke(
                    p,
                    with: .color(color.opacity(so)),
                    lineWidth: sectorWidth(trace, sector: j, context: context)
                )
            }
        }
    }

    /// セクター弧の濃さ。ハッシュで弧ごとにばらつかせつつ、
    /// セクター中心角での角度プロファイル(bump混合)を掛ける。
    /// profile = base + (1-base)·(1-Π(1-wᵢ·e^{κᵢ(cos(θ-θᵢ)-1)}))
    /// とし、確率積で合成するのでbumpが重なっても1に漸近し
    /// クリップ段差が出ない
    private func sectorOpacity(_ trace: RingTrace, sector: Int,
                               context: ShelfPluginContext) -> Double {
        let h = hash01(trace.salt + 10 + Double(sector), context: context)
        let vary = Self.sectorOpacityFloor
            + (1 - Self.sectorOpacityFloor) * h
        let theta = (Double(sector) + 0.5) / Double(Self.sectorCount)
            * 2 * .pi
        var remain = 1.0
        for b in trace.bumps {
            remain *= 1 - b.weight
                * exp(b.concentration * (cos(theta - b.angle) - 1))
        }
        let profile = trace.base + (1 - trace.base) * (1 - remain)
        return min(1, trace.opacity * vary * profile)
    }

    /// セクター弧の太さ。ハッシュで弧ごとにばらつかせる
    private func sectorWidth(_ trace: RingTrace, sector: Int,
                             context: ShelfPluginContext) -> CGFloat {
        let h = hash01(trace.salt + 20 + Double(sector), context: context)
        return trace.lineWidth * (Self.sectorWidthFloor + 0.6 * h)
    }

    // MARK: - パラメータ解決

    private func resolvedVisibility(context: ShelfPluginContext) -> Double {
        min(1, max(0,
            context.number(Param.visibility, default: Self.defaultVisibility)))
    }

    private func resolvedFrequency(context: ShelfPluginContext) -> Double {
        min(1, max(0,
            context.number(Param.frequency, default: Self.defaultFrequency)))
    }

    /// セル座標からの決定論的疑似乱数(0〜1)。同じセルでは
    /// 再描画・リロード・リブートを経ても同じ値になる
    /// (sinハッシュ。乱数生成器や状態の保持はしない)。
    /// saltは同一セルから複数の独立した値を取るための種
    private func hash01(_ salt: Double, context: ShelfPluginContext) -> Double {
        let seed = context.cellCenter.x * 127.1
            + context.cellCenter.y * 311.7
            + salt * 74.7
        let v = sin(seed) * 43758.5453123
        return v - v.rounded(.down)
    }

    /// プロセス内で最初の1回だけ解決値を記録する
    /// (セル描画のたびに呼ばれるので、毎回ログは出さない。
    ///  有効/無効とパラメータ確定のログはSettingsView側が出す)
    private static var didLogApplied = false
    private func logAppliedOnce(visibility: Double, frequency: Double) {
        guard !Self.didLogApplied else { return }
        Self.didLogApplied = true
        Self.logger.notice("ring-wear applied: visibility=\(visibility, privacy: .public) frequency=\(frequency, privacy: .public)")
    }
}
