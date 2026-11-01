//
//  LeanDepthPlugin.swift
//  Records
//
//  プラグイン「奥行き感(後傾)」(P1)。
//  ジャケットを底辺(anchor .bottom)を軸にx軸回転させ、棚の背板に
//  後ろへ立てかけた表現にする(feature/cubby-shelf-uiの検証済み値を
//  ベースに角度/パースをパラメータ化したもの)。
//  あわせてセル下端に柔らかい接地影を足し、棚板に乗っている
//  印象を強める(影の濃さは傾き角度に比例する)。
//
//  無効時はレジストリのresolveで除外されるため修飾は一切積まれず、
//  従来の平面表示と完全に同じになる(P1-3)。
//

import SwiftUI
import os

struct LeanDepthPlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Records", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)
    private enum Param {
        /// 後傾角(度)。0=平面、15=かなり倒れ込む
        static let angle = "angle"
        /// rotation3DEffectのperspectiveにそのまま渡す遠近感。
        /// 小さいほどパースが強い(0.05〜1.0)
        static let perspective = "perspective"
    }

    /// cubby-shelf-uiで実機検証済みの値(ShelfLayout.leanDegrees/
    /// leanPerspective)をデフォルトにする
    static let defaultAngle: Double = 5
    static let defaultPerspective: Double = 0.7

    /// perspectiveの下限。0や負値をrotation3DEffectに渡すと
    /// 投影が破綻するため、設定値を必ずこの範囲に収める
    private static let minPerspective: Double = 0.05

    let id = "lean-depth"
    let displayName = "Lean Depth"

    init() {
        Self.logger.info("plugin registered: lean-depth ('Lean Depth')")
    }

    var parameterSpecs: [PluginParameterSpec] {
        [
            .slider(.init(
                id: Param.angle,
                label: "Tilt Angle",
                range: 0...15,
                step: 0.5,
                defaultValue: Self.defaultAngle
            )),
            .slider(.init(
                id: Param.perspective,
                label: "Perspective",
                range: Self.minPerspective...1.0,
                step: 0.05,
                defaultValue: Self.defaultPerspective
            )),
        ]
    }

    // MARK: - (a) ジャケット本体への修飾

    func transformJacket(_ jacket: AnyView, context: ShelfPluginContext) -> AnyView {
        let angle = resolvedAngle(context: context)
        let perspective = resolvedPerspective(context: context)
        // 角度0なら修飾を積まず入力をそのまま返す
        // (有効だが角度0の時も見た目・レイアウトは平面と同一)
        guard angle != 0 else { return jacket }
        logAppliedOnce(angle: angle, perspective: perspective)
        // x軸・底辺アンカーで上辺を奥へ倒す。rotation3DEffectは
        // 描画だけを変形しレイアウト境界(=ヒット領域)は変えないので、
        // タップ再生・D&D・右クリックの判定は従来通り(P1-4)
        return AnyView(
            jacket.rotation3DEffect(
                .degrees(angle),
                axis: (x: 1, y: 0, z: 0),
                anchor: .bottom,
                perspective: perspective
            )
        )
    }

    // MARK: - (c) セル単位の装飾(接地影)

    func transformCell(_ cell: AnyView, context: ShelfPluginContext) -> AnyView {
        let angle = resolvedAngle(context: context)
        // 角度0では影も付けない(平面表示と完全同一にするため)
        guard angle > 0 else { return cell }
        let size = context.cellSize
        // 倒れ込むほど底辺の接地影を濃くする(最大=角度10°で打ち止め)
        let strength = min(1, angle / 10)
        let shadowHeight = max(4, size * 0.06)
        // セル下端に沿った楕円のぼかし影。セル内・背面に留まるため
        // 実質ヒットに影響しない
        return AnyView(
            cell.background(alignment: .bottom) {
                Ellipse()
                    .fill(Color.black.opacity(0.28 * strength))
                    .frame(width: size * 0.9, height: shadowHeight)
                    .blur(radius: shadowHeight * 0.4)
            }
        )
    }

    // MARK: - パラメータ解決

    private func resolvedAngle(context: ShelfPluginContext) -> Double {
        // 負値/15超の手編集値が入ってもUI範囲に収める
        min(15, max(0, context.number(Param.angle, default: Self.defaultAngle)))
    }

    private func resolvedPerspective(context: ShelfPluginContext) -> Double {
        min(1, max(Self.minPerspective,
                   context.number(Param.perspective, default: Self.defaultPerspective)))
    }

    /// プロセス内で最初の1回だけ解決値を記録する
    /// (セル描画のたびに呼ばれるので、毎回ログは出さない。
    ///  有効/無効とスライダー確定のログはSettingsView側が出す)
    private static var didLogApplied = false
    private func logAppliedOnce(angle: Double, perspective: Double) {
        guard !Self.didLogApplied else { return }
        Self.didLogApplied = true
        Self.logger.notice("lean-depth applied: angle=\(angle, privacy: .public)° perspective=\(perspective, privacy: .public)")
    }
}
