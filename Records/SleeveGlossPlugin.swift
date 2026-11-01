//
//  SleeveGlossPlugin.swift
//  Records
//
//  プラグイン「スリーブ光沢」(P2)。
//  透明ビニール袋に入ったレコードのように、ジャケットへ斜めの淡い
//  ハイライト帯を重ねる。帯の形状は feature/cubby-shelf-ui の検証済み
//  グラデーション(左上→右下、ピーク0.11白)をベースに、強度/角度/幅を
//  パラメータ化したもの。
//
//  オーバーレイは jacketOverlay フックで返し、合成側がジャケットの
//  角丸(clipShape)で切る。無効時はレジストリのresolveで除外され
//  オーバーレイ自体が積まれないので残像・レイアウト影響はない(P2-3)。
//

import SwiftUI
import os

struct SleeveGlossPlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Records", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)
    private enum Param {
        /// 光沢強度=ハイライト帯のピーク不透明度(0〜1)
        static let intensity = "intensity"
        /// ハイライト帯の角度(度)。グラデ軸の向きで、
        /// 45=左上→右下(feature/cubby-shelf-uiと同じ)
        static let angle = "angle"
        /// 帯の幅(グラデ軸に対する割合0〜1)
        static let width = "width"
    }

    /// デフォルト値。cubby-shelf-ui実績(0.11白の帯)より少し強め
    static let defaultIntensity: Double = 0.15
    static let defaultAngle: Double = 45
    static let defaultWidth: Double = 0.55

    /// ハイライト帯のピーク位置(グラデ軸上の0〜1)。
    /// cubby-shelf-uiの実績値(左上寄り0.30)
    private static let bandCenter: Double = 0.30

    /// 帯の立ち上がり/立ち下がりのレンジ係数。
    /// center=0.30・width=0.55で cubby-shelf-ui のstops
    /// (clear@0 / peak@0.30 / tail@0.45 / clear@0.60)を再現する値
    private static let bandFalloff: Double = 0.55
    /// ピーク後の中間stop位置の係数(0.30→0.45を再現する0.28)
    private static let bandTail: Double = 0.28
    /// 中間stopの不透明度比(cubby-shelf-uiの0.03/0.11≈0.27)
    private static let tailOpacityRatio: Double = 0.27

    let id = "sleeve-gloss"
    let displayName = "Sleeve Gloss"

    init() {
        Self.logger.info("plugin registered: sleeve-gloss ('Sleeve Gloss')")
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
                id: Param.angle,
                label: "Band Angle",
                range: 0...180,
                step: 1,
                defaultValue: Self.defaultAngle
            )),
            .slider(.init(
                id: Param.width,
                label: "Band Width",
                range: 0.1...1,
                step: 0.05,
                defaultValue: Self.defaultWidth
            )),
        ]
    }

    // MARK: - (b) ジャケットへのオーバーレイ重畳

    func jacketOverlay(context: ShelfPluginContext) -> AnyView? {
        let intensity = resolvedIntensity(context: context)
        let angle = resolvedAngle(context: context)
        let width = resolvedWidth(context: context)
        // 強度0=完全透明なのでオーバーレイ自体を返さない
        // (無効時と同じく描画・ヒットの影響ゼロにする)
        guard intensity > 0 else { return nil }
        logAppliedOnce(intensity: intensity, angle: angle, width: width)

        // 角度→グラデ軸の始点/終点。長い成分が0.5になるよう正規化
        // (45°で (0,0)→(1,1) = 左上→右下、cubby-shelf-uiと同じ帯)
        let rad = angle * .pi / 180
        let scale = max(abs(cos(rad)), abs(sin(rad)))
        let dx = cos(rad) / scale * 0.5
        let dy = sin(rad) / scale * 0.5
        let start = UnitPoint(x: 0.5 - dx, y: 0.5 - dy)
        let end = UnitPoint(x: 0.5 + dx, y: 0.5 + dy)

        // 帯の位置は軸上で固定(bandCenter)、幅パラメータで両端の
        // フェード幅だけを伸縮する。stopsは単調増加が必須なので
        // center<tail<endの順序がwidthに依らず保たれる形にする
        let c = Self.bandCenter
        let riseStart = max(0, c - Self.bandFalloff * width)
        let tailMid = min(1, c + Self.bandTail * width)
        let tailEnd = min(1, c + Self.bandFalloff * width)

        return AnyView(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: riseStart),
                    .init(color: .white.opacity(intensity), location: c),
                    .init(color: .white.opacity(intensity * Self.tailOpacityRatio),
                          location: tailMid),
                    .init(color: .clear, location: tailEnd)
                ],
                startPoint: start,
                endPoint: end
            )
            // オーバーレイがジャケットのタップ再生・D&D・右クリックの
            // ヒット判定を食わないようにする
            .allowsHitTesting(false)
        )
    }

    // MARK: - パラメータ解決

    private func resolvedIntensity(context: ShelfPluginContext) -> Double {
        min(1, max(0,
            context.number(Param.intensity, default: Self.defaultIntensity)))
    }

    private func resolvedAngle(context: ShelfPluginContext) -> Double {
        // 0〜180の周期で扱う(181°と1°は同じ帯)。手編集値も正規化する
        let raw = context.number(Param.angle, default: Self.defaultAngle)
        let wrapped = raw.truncatingRemainder(dividingBy: 180)
        return wrapped < 0 ? wrapped + 180 : wrapped
    }

    private func resolvedWidth(context: ShelfPluginContext) -> Double {
        min(1, max(0.1,
            context.number(Param.width, default: Self.defaultWidth)))
    }

    /// プロセス内で最初の1回だけ解決値を記録する
    /// (セル描画のたびに呼ばれるので、毎回ログは出さない。
    ///  有効/無効とスライダー確定のログはSettingsView側が出す)
    private static var didLogApplied = false
    private func logAppliedOnce(intensity: Double, angle: Double, width: Double) {
        guard !Self.didLogApplied else { return }
        Self.didLogApplied = true
        Self.logger.notice("sleeve-gloss applied: intensity=\(intensity, privacy: .public) angle=\(angle, privacy: .public)° width=\(width, privacy: .public)")
    }
}
