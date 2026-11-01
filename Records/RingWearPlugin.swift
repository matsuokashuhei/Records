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
//  「ぼかした細い円環のストローク」+「内側の薄い円形フィル」の2層を
//  返す。半径・円心のずれ・線の太さ・濃さ・明暗はセル座標からの
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
        /// 明るいリング/暗いリングの振り分け用
        static let tone = 7.0
        /// リングのぼかし量のばらつき用
        static let blur = 8.0
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

    /// 明るいリングの不透明度の係数(実効濃さに掛ける)。
    /// 白いすり跡がジャケット上で自然に読める上限
    private static let brightRingOpacity: Double = 0.4

    /// 暗いリングの不透明度の係数。明るいリングより控えめに
    private static let darkRingOpacity: Double = 0.3

    /// リング内側の色調差の不透明度係数。
    /// 「ごく薄い色調差」なのでリングよりかなり薄い
    private static let innerOpacityRatio: Double = 0.05

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
        let dark = hash01(Salt.tone, context: context) < Self.darkRingChance

        return ringOverlay(
            radius: radius,
            offset: offset,
            lineWidth: lineWidth,
            blur: blur,
            strength: strength,
            dark: dark
        )
    }

    // MARK: - オーバーレイ描画

    /// セル中心から微小にずれた円心を持つリングウェア。
    /// ZStackの中央(=ジャケット中央)に直径radius*2の円を置き、
    /// 円心のずれはoffsetで与える。内側の色調差を先に敷き、
    /// その上に外周リングを重ねる2層構造
    private func ringOverlay(radius: CGFloat, offset: CGPoint,
                             lineWidth: CGFloat, blur: CGFloat,
                             strength: Double, dark: Bool) -> AnyView {
        let d = radius * 2
        // 明るいすり跡=表面印刷が薄く削れた白っぽさ。
        // 暗い跡=盤の縁が食い込んだ影
        let ringColor: Color = dark ? .black : .white
        let ringOpacity = strength
            * (dark ? Self.darkRingOpacity : Self.brightRingOpacity)
        let innerOpacity = strength * Self.innerOpacityRatio
        return AnyView(
            ZStack {
                // リング内側のごく薄い色調差
                // (盤が密着して擦れた面。強くぼかして輪郭を消す)
                Circle()
                    .fill(Color.white.opacity(innerOpacity))
                    .frame(width: d, height: d)
                    .blur(radius: Self.innerBlur)
                // 盤の外周に沿ったすりリング
                Circle()
                    .stroke(ringColor.opacity(ringOpacity), lineWidth: lineWidth)
                    .frame(width: d, height: d)
                    .blur(radius: blur)
            }
            .offset(x: offset.x, y: offset.y)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // オーバーレイがジャケットのタップ再生・D&D・右クリックの
            // ヒット判定を食わないようにする
            .allowsHitTesting(false)
        )
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
