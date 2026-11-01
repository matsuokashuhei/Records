//
//  RingWearPlugin.swift
//  Records
//
//  プラグイン「リングウェア」。
//  中身のレコード盤の形がジャケット表面にうっすら浮き出る、
//  円形のすり跡を再現する。実物では全てのレコードに出るわけでは
//  ないため、出現率をパラメータ化する。
//

import SwiftUI
import os

struct RingWearPlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Records", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)
    private enum Param {
        /// リングの濃さ(0〜1)
        static let visibility = "visibility"
        /// セルがリングウェアを持つ確率(0〜1)
        static let frequency = "frequency"
    }

    /// デフォルトの濃さ
    static let defaultVisibility: Double = 0.5
    /// デフォルトの出現率
    static let defaultFrequency: Double = 0.7

    let id = "ring-wear"
    let displayName = "Ring Wear"

    init() {
        Self.logger.info("plugin registered: ring-wear ('Ring Wear')")
    }

    var parameterSpecs: [PluginParameterSpec] {
        [
            .slider(.init(
                id: Param.visibility,
                label: "Visibility",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultVisibility
            )),
            .slider(.init(
                id: Param.frequency,
                label: "Frequency",
                range: 0...1,
                step: 0.05,
                defaultValue: Self.defaultFrequency
            )),
        ]
    }
}
