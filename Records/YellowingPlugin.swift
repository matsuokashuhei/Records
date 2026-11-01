//
//  YellowingPlugin.swift
//  Records
//
//  プラグイン「黄変」(P6)。
//  白・淡色のジャケットが経年でアイボリー色に黄ばむ劣化を再現する。
//  実物観測では純白のジャケットが均一にクリーム色へ転ぶほか、
//  局所的に濃いシミができるものもある。
//
//  描画は2段構成:
//   - 均一な黄変: transformJacketで .colorMultiply を掛け、
//     青チャンネルを強く・緑チャンネルを僅かに抑制する。
//     乗算なので白・淡色部ほど強くクリーム色に転び、
//     暗部はほぼ変化しない(黒は黒のまま)
//   - 局所的なシミ: jacketOverlayで、ハッシュ生成した位置・半径・
//     個数のソフトな茶系ラジアルシミをmultiplyブレンドで散らす。
//     周縁の「たまり線」(濃い輪郭)をstopsで作って湿気シミの
//     実感にする。シミは黄変が効くセル(eff>0)にだけ描く
//
//  セルごとの黄変量・シミパターンはsinハッシュ(SleeveGlossPluginと
//  同じ方式)で決定論的に変える。無効時・intensity=0時は修飾も
//  オーバーレイも積まず、従来の描画構造と完全に同一にする(P6-4)。
//

import SwiftUI
import os

struct YellowingPlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Records", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)
    private enum Param {
        /// 黄変の強さ(0〜1)
        static let intensity = "intensity"
        /// 局所的な濃いシミの量(0〜1)
        static let stains = "stains"
    }

    /// デフォルトの黄変の強さ
    static let defaultIntensity: Double = 0.35
    /// デフォルトのシミの量
    static let defaultStains: Double = 0.3

    /// 実効強度がこれ以下なら修飾・オーバーレイを一切返さない閾値。
    /// 肉眼でほぼ見えない変化の描画コストを省く下限
    private static let minEffectiveIntensity: Double = 0.005

    /// セルごとの黄変量のばらつき幅。実効強度は設定値の
    /// (1−この値)〜1倍になる。同じ棚でも1枚ずつ黄ばみの
    /// 進行が違う実物の再現
    private static let intensityVariation: Double = 0.45

    /// シミの最大個数(stains=1のセルで1+3個まで)
    private static let maxExtraStains = 3

    /// シミの茶系色(湿気・日焼けで残るセピア調)。
    /// multiplyブレンドなので下地の色に乗算されて沈む
    private static let stainColor = Color(red: 0.52, green: 0.36, blue: 0.16)

    let id = "yellowing"
    let displayName = "Yellowing"

    init() {
        Self.logger.info("plugin registered: yellowing ('Yellowing')")
    }

    var parameterSpecs: [PluginParameterSpec] {
        [
            .slider(.init(
                id: Param.intensity,
                label: "Intensity",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultIntensity
            )),
            .slider(.init(
                id: Param.stains,
                label: "Stains",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultStains
            )),
        ]
    }

    // MARK: - (a) ジャケット本体への修飾(均一な黄変)

    func transformJacket(_ jacket: AnyView, context: ShelfPluginContext) -> AnyView {
        let intensity = resolvedIntensity(context: context)
        let eff = effectiveIntensity(intensity, context: context)
        // 実効強度≈0なら修飾を積まず入力をそのまま返す
        // (intensity=0・無効時と見た目・構造が完全に同じになる。P6-4)
        guard eff > Self.minEffectiveIntensity else { return jacket }
        // ログのintensity/stainsは設定値そのまま(セルごとのばらつき値ではない)
        logAppliedOnce(
            intensity: intensity, stains: resolvedStains(context: context))
        // 青を強く(最大-40%)、緑を僅かに(最大-8%)、赤はそのまま。
        // 乗算フィルタなので白地だけがアイボリー〜クリーム色に転び、
        // 暗部への影響は見た目上ほぼ出ない
        return AnyView(
            jacket.colorMultiply(Color(
                red: 1.0,
                green: 1.0 - 0.08 * eff,
                blue: 1.0 - 0.40 * eff
            ))
        )
    }

    // MARK: - (b) ジャケットへのオーバーレイ重畳(局所的なシミ)

    /// 1個のシミの描画パラメータ。セル内正規化座標・セル一辺比で
    /// 持ち、生成はセル座標のsinハッシュで決定論的
    private struct StainMark: Identifiable {
        let id: Int
        /// セル内の中心位置(0〜1)。下端寄りにやや偏る
        let x: Double
        let y: Double
        /// 半径(セル一辺に対する割合)
        let radius: Double
        /// 中心のピーク不透明度
        let opacity: Double
        /// 楕円の歪み(1=正円)と回転
        let stretchX: Double
        let stretchY: Double
        let rotation: Double
    }

    func jacketOverlay(context: ShelfPluginContext) -> AnyView? {
        let intensity = resolvedIntensity(context: context)
        let stains = resolvedStains(context: context)
        let eff = effectiveIntensity(intensity, context: context)
        // 黄変自体が効かないセル・シミ量0ではオーバーレイを返さない
        // (無効時と同じく描画・ヒットの影響ゼロ。P6-4)
        guard eff > Self.minEffectiveIntensity,
              stains > Self.minEffectiveIntensity else { return nil }
        let marks = stainMarks(stains: stains, context: context)
        guard !marks.isEmpty else { return nil }
        let size = context.cellSize
        return AnyView(
            ZStack {
                ForEach(marks) { mark in
                    Circle()
                        .fill(RadialGradient(
                            stops: [
                                // 中心は薄く、外側へ一度フェードしてから
                                // 縁直前に濃い「たまり線」を挟み、
                                // 縁でclearに落とす(湿気シミの輪郭)
                                .init(color: Self.stainColor.opacity(mark.opacity),
                                      location: 0),
                                .init(color: Self.stainColor.opacity(mark.opacity * 0.5),
                                      location: 0.55),
                                .init(color: Self.stainColor.opacity(min(1, mark.opacity * 1.6)),
                                      location: 0.78),
                                .init(color: .clear, location: 1)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: mark.radius * size
                        ))
                        .frame(width: mark.radius * size * 2,
                               height: mark.radius * size * 2)
                        .scaleEffect(x: mark.stretchX, y: mark.stretchY)
                        .rotationEffect(.radians(mark.rotation))
                        .position(x: mark.x * size, y: mark.y * size)
                }
            }
            // 茶系色を下地へ乗算して沈んだシミにする
            .blendMode(.multiply)
            // オーバーレイがジャケットのタップ再生・D&D・右クリックの
            // ヒット判定を食わないようにする
            .allowsHitTesting(false)
        )
    }

    // MARK: - シミパターン生成

    /// セル座標のsinハッシュからこのセルのシミ群を決定論的に生成する。
    /// 再描画・リロード・再起動で同じセルには同じパターンが出る
    private func stainMarks(stains: Double, context: ShelfPluginContext) -> [StainMark] {
        // 個数: 常に1個は出し、stainsに比例して最大+3個。
        // 個数自体もハッシュ幅を持たせてセルごとにばらつかせる
        let extra = Int(
            hash01(21, context: context)
            * Double(Self.maxExtraStains + 1) * stains)
        let count = 1 + min(Self.maxExtraStains, extra)
        return (0..<count).map { i in
            // シミごとに離れたsalt帯を使い、各属性を独立させる
            let base = 30.0 + Double(i) * 10
            // yは0.7乗で下端寄りに偏らせる(湿気シミは裾に残りやすい)
            let x = 0.08 + 0.84 * hash01(base + 1, context: context)
            let h = hash01(base + 2, context: context)
            let y = 0.08 + 0.84 * pow(h, 0.7)
            // 小さめの点状シミ〜大きな滲みまで。stainsが強いほど大きくなる
            let radius = (0.06 + 0.14 * hash01(base + 3, context: context))
                * (0.6 + 0.4 * stains)
            let opacity = (0.10 + 0.22 * hash01(base + 4, context: context)) * stains
            return StainMark(
                id: i,
                x: x,
                y: y,
                radius: radius,
                opacity: opacity,
                stretchX: 0.7 + 0.6 * hash01(base + 5, context: context),
                stretchY: 0.7 + 0.6 * hash01(base + 6, context: context),
                rotation: hash01(base + 7, context: context) * .pi
            )
        }
    }

    // MARK: - パラメータ解決・ハッシュ

    private func resolvedIntensity(context: ShelfPluginContext) -> Double {
        min(1, max(0,
            context.number(Param.intensity, default: Self.defaultIntensity)))
    }

    private func resolvedStains(context: ShelfPluginContext) -> Double {
        min(1, max(0,
            context.number(Param.stains, default: Self.defaultStains)))
    }

    /// 設定値にセルごとのばらつきを掛けた実効強度(0〜intensity)。
    /// 全セル均一だと「フィルタを掛けただけ」に見えるので、
    /// 1枚ずつ進行度を変える
    private func effectiveIntensity(_ intensity: Double,
                                    context: ShelfPluginContext) -> Double {
        intensity * (1 - Self.intensityVariation * hash01(11, context: context))
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
    private func logAppliedOnce(intensity: Double, stains: Double) {
        guard !Self.didLogApplied else { return }
        Self.didLogApplied = true
        Self.logger.notice("yellowing applied: intensity=\(intensity, privacy: .public) stains=\(stains, privacy: .public)")
    }
}
