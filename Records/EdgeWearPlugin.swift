//
//  EdgeWearPlugin.swift
//  Records
//
//  プラグイン「フチ・角の摩耗」。
//  何度も抜き差しされたレコードジャケットの、白っぽく擦り切れた
//  フチと角のつぶれを再現する。
//

import SwiftUI
import os

struct EdgeWearPlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Records", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)
    private enum Param {
        /// フチの摩耗量(0〜1)
        static let amount = "amount"
        /// 角の摩耗量(0〜1)
        static let corners = "corners"
    }

    /// デフォルトのフチ摩耗量
    static let defaultAmount: Double = 0.35
    /// デフォルトの角摩耗量
    static let defaultCorners: Double = 0.4

    let id = "edge-wear"
    let displayName = "Edge Wear"

    init() {
        Self.logger.info("plugin registered: edge-wear ('Edge Wear')")
    }

    var parameterSpecs: [PluginParameterSpec] {
        [
            .slider(.init(
                id: Param.amount,
                label: "Wear",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultAmount
            )),
            .slider(.init(
                id: Param.corners,
                label: "Corner Wear",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultCorners
            )),
        ]
    }
}
