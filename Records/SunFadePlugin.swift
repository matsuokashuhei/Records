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
}
