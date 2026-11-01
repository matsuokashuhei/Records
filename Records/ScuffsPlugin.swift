//
//  ScuffsPlugin.swift
//  Records
//
//  プラグイン「スカッフ(擦りキズ)」。
//  ジャケット表面の髪の毛状の細い擦り傷と、白い斑点状の
//  すり傷を再現する。実物では暗いジャケットで特に目立つ。
//

import SwiftUI
import os

struct ScuffsPlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Records", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)
    private enum Param {
        /// 傷の量・密度(0〜1)
        static let amount = "amount"
        /// 傷の種類。選択肢idの文字列で永続化
        static let style = "style"
    }

    /// 傷の種類。rawValueはsettings.jsonへの永続化値なので
    /// 一度決めたら変更しない
    private enum Style: String, CaseIterable {
        /// 髪の毛状の細い線傷のみ
        case hairline
        /// 白い斑点状のすり傷のみ
        case speckles
        /// 両方
        case both

        /// 表示ラベル(Localizable.xcstringsのキー)
        var label: String {
            switch self {
            case .hairline: return "Hairline"
            case .speckles: return "Speckles"
            case .both: return "Hairline + Speckles"
            }
        }
    }

    /// デフォルトの傷の量
    static let defaultAmount: Double = 0.4
    /// デフォルトの種類
    private static let defaultStyle = Style.both

    let id = "scuffs"
    let displayName = "Scuffs"

    init() {
        Self.logger.info("plugin registered: scuffs ('Scuffs')")
    }

    var parameterSpecs: [PluginParameterSpec] {
        [
            .slider(.init(
                id: Param.amount,
                label: "Amount",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultAmount
            )),
            .options(.init(
                id: Param.style,
                label: "Style",
                choices: Style.allCases.map {
                    .init(id: $0.rawValue, label: $0.label)
                },
                defaultValue: Self.defaultStyle.rawValue
            )),
        ]
    }
}
