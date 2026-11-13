//
//  LeanDepthPlugin.swift
//  Sleeves
//
//  プラグイン「奥行き感(後傾)」(P1)。
//  ジャケット面(ジャケット画像+全オーバーレイの合成物)を底辺
//  (anchor .bottom)を軸にx軸回転させ、棚の背板に
//  後ろへ立てかけた表現にする(feature/cubby-shelf-uiの検証済み値
//  ベース)。
//  あわせてセル下端に柔らかい接地影を足し、棚板に乗っている
//  印象を強める(影の濃さは傾き角度に比例する)。
//
//  設定は「立てかけ具合」1本だけ。棚の奥行きに対してジャケットの
//  上辺がどの位置まで届くか(0=直立、50=奥行きの半分まで)を
//  スライダーで指定し、そこから実際の傾き角度を逆算する。
//  投影パースは固定値(0.7)。物理モデル: 棚の奥行きD=
//  ジャケット高さH×sin(最大角)で固定。上辺の奥へのずれd=
//  H×sin(角度)がDのlean%分なので、角度=asin(lean%×sin(最大角))。
//
//  無効時はレジストリのresolveで除外されるため修飾は一切積まれず、
//  従来の平面表示と完全に同じになる(P1-3)。
//

import SwiftUI
import os

struct LeanDepthPlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Sleeves", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)
    private enum Param {
        /// 立てかけ具合(0-50%)。棚の奥行きの何%の位置まで
        /// ジャケットの上辺が届くか
        static let lean = "lean"
    }

    /// 棚の奥行きを決める参照角(度)。奥行きD=
    /// ジャケット高さ×sin(この角度)で固定する
    static let maxAngle: Double = 15
    /// 立てかけ具合の最大値(%)。棚の奥行きの半分まで。
    /// 15°より強い傾きは実用上不自然なので半分に制限する
    static let maxLean: Double = 50
    /// デフォルトの立てかけ具合(%)。cubby-shelf-uiで実機検証済みの
    /// 5°相当 = sin(5°)/sin(15°)≈34%を丸めた値
    static let defaultLean: Double = 35
    /// rotation3DEffectに渡す投影パース。cubby-shelf-uiの実機検証
    /// 済み値に固定する(ユーザーには見せない。小さいほど強い)
    private static let perspective: Double = 0.7

    let id = "lean-depth"
    let displayName = "Lean Depth"
    let category: ShelfPluginCategory = .placement

    init() {
        Self.logger.info("plugin registered: lean-depth ('Lean Depth')")
    }

    var parameterSpecs: [PluginParameterSpec] {
        [
            .slider(.init(
                id: Param.lean,
                label: "Lean",
                range: 0...Self.maxLean,
                step: 2.5,
                defaultValue: Self.defaultLean
            )),
        ]
    }

    // MARK: - (c) ジャケット面の変形(後傾)

    func transformJacketSurface(_ surface: AnyView, context: ShelfPluginContext) -> AnyView {
        let lean = resolvedLean(context: context)
        let angle = Self.angle(forLeanPercent: lean)
        // 0%なら修飾を積まず入力をそのまま返す
        // (有効だが0%の時も見た目・レイアウトは平面と同一)
        guard angle > 0 else { return surface }
        logAppliedOnce(lean: lean, angle: angle)
        // x軸・底辺アンカーで上辺を奥へ倒す。入力はジャケット+
        // 全オーバーレイの合成物(面)なので、擦り跡・シミ・帯も
        // ジャケット面に乗ったまま一緒に傾く。rotation3DEffectは
        // 描画だけを変形しレイアウト境界(=ヒット領域)は変えないので、
        // タップ再生・D&D・右クリックの判定は従来通り(P1-4)
        return AnyView(
            surface.rotation3DEffect(
                .degrees(angle),
                axis: (x: 1, y: 0, z: 0),
                anchor: .bottom,
                perspective: Self.perspective
            )
        )
    }

    // MARK: - (d) セル単位の装飾(接地影)

    func transformCell(_ cell: AnyView, context: ShelfPluginContext) -> AnyView {
        let angle = Self.angle(forLeanPercent: resolvedLean(context: context))
        // 0%では影も付けない(平面表示と完全同一にするため)
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

    private func resolvedLean(context: ShelfPluginContext) -> Double {
        // 負値/上限超の手編集値が入ってもUI範囲に収める
        min(Self.maxLean, max(0, context.number(Param.lean, default: Self.defaultLean)))
    }

    /// 立てかけ具合(%)→実際の傾き角(度)。
    /// 棚の奥行き=ジャケット高さ×sin(最大角)で固定し、上辺の
    /// 奥へのずれが奥行きのlean%分になる角度をasinで逆算する
    static func angle(forLeanPercent lean: Double) -> Double {
        // 範囲外を渡されてもasinの定義域を外れないようクランプする
        let clamped = min(Self.maxLean, max(0, lean))
        let maxRadians = Self.maxAngle * .pi / 180
        return asin((clamped / 100) * sin(maxRadians)) * 180 / .pi
    }

    /// プロセス内で最初の1回だけ解決値を記録する
    /// (セル描画のたびに呼ばれるので、毎回ログは出さない。
    ///  有効/無効とスライダー確定のログはSettingsView側が出す)
    private static var didLogApplied = false
    private func logAppliedOnce(lean: Double, angle: Double) {
        guard !Self.didLogApplied else { return }
        Self.didLogApplied = true
        Self.logger.notice("lean-depth applied: lean=\(lean, privacy: .public)% angle=\(angle, privacy: .public)°")
    }
}
