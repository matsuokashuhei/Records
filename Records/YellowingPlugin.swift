//
//  YellowingPlugin.swift
//  Records
//
//  プラグイン「黄変」。
//  白・淡色のジャケットが経年でアイボリー色に黄ばむ劣化を再現する。
//  実物観測では純白のジャケットが均一にクリーム色へ転ぶほか、
//  局所的に濃いシミができるものもある。
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
}
