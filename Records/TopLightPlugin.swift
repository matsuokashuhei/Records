//
//  TopLightPlugin.swift
//  Records
//
//  プラグイン「上からの光源」(P3)。
//  ジャケット/セルの影・エッジ明暗を「真上の光源」で統一する:
//    - ジャケットの下向き投影(セル影。強さ/ぼかしを調整可能)
//    - ジャケット上辺の受光ハイライト(上端が最も明るい帯)
//    - ジャケット下辺の減光(光が届かない面を同じ強度比で暗く)
//    - セル上部への柔らかい環境光(ジャケット上端から漏れる光)
//
//  P3-3: 有効時は replacesDefaultCellShadow=true でセルの既定影
//  (ShelfViewの固定.shadow)を積まず、本プラグインの
//  transformCellが描く影だけに統一する。無効時はレジストリの
//  resolveで除外されるため既定影+無修飾の従来表示に完全に戻る。
//

import SwiftUI
import os

struct TopLightPlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Records", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)
    private enum Param {
        /// 下向き投影の不透明度(0〜0.9)
        static let shadowOpacity = "shadowOpacity"
        /// 下向き投影のぼかし半径(pt)
        static let shadowRadius = "shadowRadius"
        /// 受光ハイライト強度(0〜1)。上辺の明帯・下辺の減光・
        /// セル上の環境光をまとめて制御する(光のコントラスト)
        static let highlight = "highlight"
        /// 照光がジャケット面に食い込む深さ(セル高に対する割合)
        static let reach = "reach"
    }

    /// デフォルト値。影は既定の固定影(0.25/r3)よりやや強めで、
    /// feature/cubby-shelf-ui実績(0.45/r5)に近い値
    static let defaultShadowOpacity: Double = 0.4
    static let defaultShadowRadius: Double = 6
    static let defaultHighlight: Double = 0.3
    static let defaultReach: Double = 0.22

    /// 下辺減光の強度比(ハイライトに対する割合)
    private static let bottomShadeRatio: Double = 0.4
    /// 環境光グローの強度比(ハイライトに対する割合)
    private static let ambientGlowRatio: Double = 0.22
    /// 影の縦オフセット比(ぼかし半径に対する割合)。
    /// 真上の光なので影はほぼ真下へ落ちる
    private static let shadowOffsetRatio: Double = 0.4

    let id = "top-light"
    let displayName = "Top Light"
    /// 既定のセル影はこのプラグインの光源表現に統一する(P3-3)
    let replacesDefaultCellShadow = true

    init() {
        Self.logger.info("plugin registered: top-light ('Top Light')")
    }

    var parameterSpecs: [PluginParameterSpec] {
        [
            .slider(.init(
                id: Param.shadowOpacity,
                label: "Shadow Opacity",
                range: 0...0.9,
                step: 0.01,
                defaultValue: Self.defaultShadowOpacity
            )),
            .slider(.init(
                id: Param.shadowRadius,
                label: "Shadow Blur",
                range: 0...24,
                step: 0.5,
                defaultValue: Self.defaultShadowRadius
            )),
            .slider(.init(
                id: Param.highlight,
                label: "Highlight Intensity",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultHighlight
            )),
            .slider(.init(
                id: Param.reach,
                label: "Light Reach",
                range: 0.05...0.5,
                step: 0.01,
                defaultValue: Self.defaultReach
            )),
        ]
    }

    // MARK: - (b) ジャケットへのオーバーレイ重畳(エッジ明暗)

    func jacketOverlay(context: ShelfPluginContext) -> AnyView? {
        let highlight = resolved(Param.highlight, default: Self.defaultHighlight, context: context)
        // 強度0=明暗の変化なし。オーバーレイ自体を返さず
        // 無効時と同じく描画・ヒットの影響をゼロにする
        guard highlight > 0 else { return nil }
        let size = context.cellSize
        let reach = resolved(Param.reach, default: Self.defaultReach, context: context)
        logAppliedOnce(context: context)

        return AnyView(
            ZStack {
                // 上辺の受光帯: 上端が最も明るく、reach分の深さで消える。
                // 最初のstopが受光エッジの明線も兼ねる
                VStack(spacing: 0) {
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(highlight), location: 0),
                            .init(color: .white.opacity(highlight * 0.5), location: 0.25),
                            .init(color: .white.opacity(highlight * 0.12), location: 0.7),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: size * reach)
                    Spacer(minLength: 0)
                }
                // 下辺の減光: 光の届かない面を同じ強度比で暗くして
                // 「上からの光」の明暗を統一する
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(highlight * Self.bottomShadeRatio),
                                  location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: size * reach * 0.8)
                }
            }
            // オーバーレイがジャケットのタップ再生・D&D・右クリックの
            // ヒット判定を食わないようにする
            .allowsHitTesting(false)
        )
    }

    // MARK: - (c) セル単位の装飾(下向き投影+環境光)

    func transformCell(_ cell: AnyView, context: ShelfPluginContext) -> AnyView {
        let opacity = resolved(Param.shadowOpacity, default: Self.defaultShadowOpacity, context: context)
        let radius = resolved(Param.shadowRadius, default: Self.defaultShadowRadius, context: context)
        let highlight = resolved(Param.highlight, default: Self.defaultHighlight, context: context)
        let size = context.cellSize
        logAppliedOnce(context: context)

        // セルのシルエットだけが影を落とすよう、環境光のグローは
        // shadowより後(外側)に積む(グローまで影を落とすと
        // セルの下に白い帯の落ち影が出てしまう)
        var result = AnyView(
            cell.shadow(
                color: .black.opacity(opacity),
                radius: radius,
                y: max(1, radius * Self.shadowOffsetRatio)
            )
        )
        if highlight > 0 {
            // セル上部への柔らかい照光: ジャケット上端から上へ
            // 漏れる光。楕円の下半分はジャケットの背面に隠れ、
            // 上半分だけがグリッド上に見える
            result = AnyView(
                result.background(alignment: .top) {
                    Ellipse()
                        .fill(.white.opacity(highlight * Self.ambientGlowRatio))
                        .frame(width: size * 0.85, height: size * 0.16)
                        .blur(radius: max(2, size * 0.05))
                        .offset(y: -size * 0.08)
                        // グローがドロップゾーンや隣セルのヒットを食わないように
                        .allowsHitTesting(false)
                }
            )
        }
        return result
    }

    // MARK: - パラメータ解決

    /// パラメータ値をspecのrangeにクランプして解決する。
    /// (手編集で範囲外の値が入ってもUI範囲に収める。
    ///  範囲はparameterSpecsだけを見るので二重管理にならない)
    private func resolved(
        _ param: String, default fallback: Double,
        context: ShelfPluginContext
    ) -> Double {
        let value = context.number(param, default: fallback)
        for spec in parameterSpecs {
            if case .slider(let s) = spec, s.id == param {
                return min(s.range.upperBound, max(s.range.lowerBound, value))
            }
        }
        return value
    }

    /// プロセス内で最初の1回だけ解決値を記録する
    /// (セル描画のたびに呼ばれるので、毎回ログは出さない。
    ///  有効/無効とスライダー確定のログはSettingsView側が出す)
    private static var didLogApplied = false
    private func logAppliedOnce(context: ShelfPluginContext) {
        guard !Self.didLogApplied else { return }
        Self.didLogApplied = true
        let opacity = resolved(Param.shadowOpacity, default: Self.defaultShadowOpacity, context: context)
        let radius = resolved(Param.shadowRadius, default: Self.defaultShadowRadius, context: context)
        let highlight = resolved(Param.highlight, default: Self.defaultHighlight, context: context)
        let reach = resolved(Param.reach, default: Self.defaultReach, context: context)
        Self.logger.notice("top-light applied: shadowOpacity=\(opacity, privacy: .public) shadowRadius=\(radius, privacy: .public) highlight=\(highlight, privacy: .public) reach=\(reach, privacy: .public)")
    }
}
