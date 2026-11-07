//
//  SunFadePlugin.swift
//  Records
//
//  プラグイン「色褪せ(日焼け褪色)」。
//  長年日差しに晒されたレコードジャケットの褪色を再現する。
//  実物観測(70枚調査)では「彩度低下+赤/マゼンタへのシフト+
//  コントラスト低下」が褪色の典型パターン。
//

import SwiftUI
import os

struct SunFadePlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Records", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)
    private enum Param {
        /// 褪色の強さ(0〜1)
        static let amount = "amount"
        /// セルごとの褪色量のばらつき(0〜1。0=全セル均一)
        static let variation = "variation"
    }

    /// デフォルトの褪色の強さ
    static let defaultAmount: Double = 0.4
    /// デフォルトのばらつき
    static let defaultVariation: Double = 0.6

    let id = "sun-fade"
    let displayName = "Sun Fade"
    let category: ShelfPluginCategory = .record

    init() {
        Self.logger.info("plugin registered: sun-fade ('Sun Fade')")
    }

    var parameterSpecs: [PluginParameterSpec] {
        [
            .slider(.init(
                id: Param.amount,
                label: "Fade",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultAmount
            )),
            .slider(.init(
                id: Param.variation,
                label: "Variation",
                range: 0...1,
                step: 0.05,
                defaultValue: Self.defaultVariation
            )),
        ]
    }

    // MARK: - (a) ジャケット本体への修飾

    /// 彩度低下の最大量(eff=1で彩度0.4まで下がる。
    /// 実物の褪色ジャケットは彩度が大きく落ちるが無彩色にはならない)
    private static let maxSaturationDrop: Double = 0.6
    /// 赤/マゼンタ方向への色相シフトの最大角(度)。
    /// 褪色印刷ではシアン版のインクが先に抜けて全体が赤転びする。
    /// 負方向に回すと 黄→橙・赤→マゼンタ・緑→黄 と暖色側へ寄る
    private static let maxHueShift: Double = -12
    /// シアン抜けの再現: colorMultiplyで緑/青チャンネルを
    /// この割合だけ抑制し、全階調に暖色キャストを乗せる。
    /// (hueRotationは有彩色しか回せずグレー・白に効かないため併用)
    private static let maxWarmMultiplyGreen: Double = 0.08
    private static let maxWarmMultiplyBlue: Double = 0.14
    /// コントラスト低下の最大量(eff=1で0.85。
    /// 極端値が中央灰へ寄り、褪色の「薄い霞」を作る)
    private static let maxContrastDrop: Double = 0.15
    /// 霞(褪色で浮き出た紙の地色)オーバーレイの最大不透明度。
    /// わずかに赤みのある暖白で「赤転び+霞」を両立させる
    private static let maxHazeOpacity: Double = 0.16
    /// 実効褪色量がこれ以下なら修飾を積まない閾値。
    /// 肉眼でほぼ見えないセルの描画コストを省く下限
    /// (variation>0ではハッシュ値の小さいセルがここに落ち、
    ///  「ほぼ褪色しないセル」として無修飾になる)
    private static let minEffectiveFade: Double = 0.005
    /// セルごとの褪色量ハッシュの種(sinハッシュのsalt)
    private static let fadeHashSalt: Double = 17

    func transformJacket(_ jacket: AnyView, context: ShelfPluginContext) -> AnyView {
        let amount = resolvedAmount(context: context)
        let variation = resolvedVariation(context: context)
        // セルごとの実効褪色量。variation=0で全セル均一(amount)、
        // variation=1で 0〜amount にばらつく(実物は全レコードが
        // 同じ焼け方をしない — 70枚調査の観測)
        let eff = amount * (1 - variation
            + variation * hash01(Self.fadeHashSalt, context: context))
        // 実効褪色量≈0なら修飾を積まず入力をそのまま返す。
        // amount=0・無効(resolve除外)のとき従来と完全同一の
        // 描画構造になる(P4-4)。小さいセルは無修飾で返す
        guard eff > Self.minEffectiveFade else { return jacket }
        logAppliedOnce(amount: amount, variation: variation)

        // 褪色の典型パターン「彩度低下+赤/マゼンタへのシフト+
        // コントラスト低下(霞)」を重ねる
        let haze = Color(red: 1.0, green: 0.90, blue: 0.93)
            .opacity(Self.maxHazeOpacity * eff)
        return AnyView(
            jacket
                .saturation(1 - Self.maxSaturationDrop * eff)
                .hueRotation(.degrees(Self.maxHueShift * eff))
                .colorMultiply(Color(
                    red: 1.0,
                    green: 1 - Self.maxWarmMultiplyGreen * eff,
                    blue: 1 - Self.maxWarmMultiplyBlue * eff
                ))
                .contrast(1 - Self.maxContrastDrop * eff)
                // 霞=褪色紙の地色が全面に薄く浮く表現。
                // ジャケットと同じ角丸で塗り、ヒット判定は
                // ジャケット側に通す(P4-5)
                .overlay {
                    ShelfPluginLayout.jacketShape(cellIndex: context.cellIndex)
                        .fill(haze)
                        .allowsHitTesting(false)
                }
        )
    }

    // MARK: - パラメータ解決

    private func resolvedAmount(context: ShelfPluginContext) -> Double {
        // 負値/上限超の手編集値が入ってもUI範囲に収める
        min(1, max(0,
            context.number(Param.amount, default: Self.defaultAmount)))
    }

    private func resolvedVariation(context: ShelfPluginContext) -> Double {
        min(1, max(0,
            context.number(Param.variation, default: Self.defaultVariation)))
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
    ///  有効/無効とスライダー確定のログはSettingsView側が出す)
    private static var didLogApplied = false
    private func logAppliedOnce(amount: Double, variation: Double) {
        guard !Self.didLogApplied else { return }
        Self.didLogApplied = true
        Self.logger.notice("sun-fade applied: amount=\(amount, privacy: .public) variation=\(variation, privacy: .public) model=desat+warm-shift+haze")
    }
}
