//
//  AmbientLightPlugin.swift
//  Sleeves
//
//  プラグイン「環境光」(効果系・照明カテゴリ)。
//  壁の上に重ねる照明系の2レイヤーを描く:
//   - warmth: 白熱灯のような、上ほど強い琥珀色の暖色被せ
//   - vignette: 四辺をぼかした内側影による周辺減光
//  もともとWallPluginの経年表現として実装されていたものを、
//  設定画面の「照明」ペイン新設に伴い独立プラグインへ分離した
//  (2026-11)。旧settings.jsonの wall プラグインが持っていた
//  aging-warmth/aging-vignette 値は ShelfSettings のデコード移行で
//  warmth/vignette キーへ引き継がれる。
//
//  壁材ごとの個性(暖色の強さ係数warmthGain、ビネット乗算色と
//  強さ係数vignetteGain)は選択中の壁の AgingProfile から取るため、
//  ShelfStructureContext.settings 経由で WallPlugin.wall(in:) を
//  呼んで同じ壁を解決する。
//
//  レジストリでは WallPlugin の直後に登録するため、
//  壁backdropの直上に照明レイヤーが重なる。
//  バックドロップはセルのヒット判定に影響しないが、
//  空き領域へのタップを食わないよう allowsHitTesting(false)
//  を掛けている。
//

import SwiftUI
import os

struct AmbientLightPlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Sleeves", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)。
    /// 旧wallプラグインの aging-warmth/aging-vignette は
    /// ShelfSettingsのデコード移行で warmth/vignette へ写される
    private enum Param {
        /// 白熱灯の暖色被せ(0-1)
        static let warmth = "warmth"
        /// 周辺減光(0-1)
        static let vignette = "vignette"
    }

    let id = "ambient-light"
    let displayName = "Ambient Light"
    let category: ShelfPluginCategory = .lighting
    /// スタイル非依存(壁と同じく、棚構造の選択に関わらず常に動く)
    let shelfStyle: ShelfSettings.ShelfStyle? = nil
    /// 効果系プラグインは既定で無効。ON/OFFトグルあり
    let defaultEnabled = false
    let canDisable = true

    init() {
        Self.logger.info("plugin registered: ambient-light ('Ambient Light')")
    }

    var parameterSpecs: [PluginParameterSpec] {
        [
            .slider(.init(
                id: Param.warmth,
                label: "Warm Light",
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

    // MARK: - (e) グリッド背面(照明レイヤー)

    /// 壁backdropの直上に重ねる照明レイヤー(レジストリ順)。
    /// 重ね順は分離前と同じく warmth を下、vignette を上にする。
    /// 合成順の注意: 分離前のwarmthは壁のagingLayers内の最下層
    /// (経年レイヤーの下)だったが、今は壁の全レイヤー
    /// (壁材+sepia/stains/fadeMarks)の上に乗る。「光は経年層にも
    /// 当たる」表現として意図的な仕様。vignetteは従来通り
    /// 最上層へのmultiplyなので見た目は等価
    func shelfBackdrop(context: ShelfStructureContext) -> AnyView? {
        let warmth = min(1, max(0, context.number(Param.warmth, default: 0)))
        let vignette = min(1, max(0, context.number(Param.vignette, default: 0)))
        guard warmth > 0 || vignette > 0 else { return nil }
        // 壁材ごとの個性(暖色の強さ係数・ビネットの乗算色/強さ係数)は
        // 選択中の壁から取る(壁を変えたら照明の見え方も壁材に合わせる)
        let wall = WallPlugin.wall(in: context.settings)
        let p = wall.agingProfile
        logAppliedOnce(wall: wall, warmth: warmth, vignette: vignette)
        // 背面なのでセルのヒット判定には影響しないが、空き領域への
        // タップを照明レイヤーが食わないよう保険を掛けておく
        return AnyView(
            ZStack {
                if warmth > 0 {
                    warmthLayer(warmth, profile: p)
                }
                if vignette > 0 {
                    vignetteLayer(vignette, profile: p)
                }
            }
            .allowsHitTesting(false)
        )
    }

    /// 白熱灯: 上ほど強い琥珀色の被せ。
    /// (WallPluginの経年表現から移したもの。天井からの暖色光が
    ///  上ほど強く当たる見た目)
    private func warmthLayer(
        _ warmth: Double, profile p: WallPlugin.AgingProfile
    ) -> some View {
        LinearGradient(
            gradient: Gradient(colors: [
                Color(red: 1, green: 0.80, blue: 0.45)
                    .opacity(0.28 * warmth * p.warmthGain),
                Color(red: 1, green: 0.76, blue: 0.42)
                    .opacity(0.05 * warmth * p.warmthGain),
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 周辺減光: 四辺からの帯をぼかした内側影(even-odd fillで
    /// 中央をくり抜いたリングをぼかす)。中央は一切触らず四辺の
    /// 帯と角だけを暗くする。multiplyはビュー側で掛けて自己完結
    /// させる(帯色は乗算前提の色設計なので、付け忘れると
    /// 不透明の帯として描かれてしまう)。帯の下の壁テクスチャは
    /// 残ったまま沈む(全面ベールでテクスチャが消えた問題の対策
    /// 2026-11-03)
    private func vignetteLayer(
        _ vignette: Double, profile p: WallPlugin.AgingProfile
    ) -> some View {
        let k = min(1, vignette * p.vignetteGain)
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

    // MARK: - パラメータ解決

    /// プロセス内で最初の1回だけ解決値を記録する
    /// (描画のたびに呼ばれるので、毎回ログは出さない。
    ///  有効/無効とパラメータ確定のログはSettingsView側が出す)
    private static var didLogApplied = false
    private func logAppliedOnce(wall: WallPlugin.Wall, warmth: Double, vignette: Double) {
        guard !Self.didLogApplied else { return }
        Self.didLogApplied = true
        Self.logger.notice("ambient-light applied: wall=\(wall.rawValue, privacy: .public) warmth=\(warmth, privacy: .public) vignette=\(vignette, privacy: .public)")
    }
}
