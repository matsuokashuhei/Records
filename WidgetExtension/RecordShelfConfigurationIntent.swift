//
//  RecordShelfConfigurationIntent.swift
//  RecordsWidget
//
//  Created by Shuhei Matsuoka on 2026/10/18.
//

import AppIntents
import WidgetKit

/// ウィジェットごとの登録枚数の選択肢。
/// ウィジェットギャラリーの編集UIに「アプリ設定に従う / 6枚 / 12枚 / 20枚」と
/// 表示される。グリッドの列×行は ShelfSettings.Capacity のマッピングを使う
/// (独自の対応表は作らない)。
enum ShelfCapacityOption: String, AppEnum {
    /// 未指定=アプリのsettings.jsonの容量に従う(デフォルト)
    case appDefault
    case six
    case twelve
    case twenty

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "登録枚数"

    static let caseDisplayRepresentations: [ShelfCapacityOption: DisplayRepresentation] = [
        .appDefault: "アプリ設定に従う",
        .six: "6枚",
        .twelve: "12枚",
        .twenty: "20枚",
    ]

    /// 明示選択された容量。.appDefault のときは nil で、呼び出し側が
    /// settings.json(ShelfSettings.loadFromDisk)の値にフォールバックする。
    var shelfCapacity: ShelfSettings.Capacity? {
        switch self {
        case .appDefault: return nil
        case .six: return .six
        case .twelve: return .twelve
        case .twenty: return .twenty
        }
    }
}

/// レコードシェルフウィジェットの設定インテント。
/// PlayAlbumIntent(再生用、Shared配下)とは別に、ウィジェット拡張だけが使う
/// 設定用なのでWidgetExtension配下に置く(アプリターゲットには不要)。
struct RecordShelfConfigurationIntent: WidgetConfigurationIntent {

    static let title: LocalizedStringResource = "レコードシェルフ設定"
    static let description = IntentDescription("表示する登録枚数を選択します。「アプリ設定に従う」ではアプリ側の設定画面の枚数が使われます。")

    @Parameter(title: "登録枚数", default: .appDefault)
    var capacity: ShelfCapacityOption

    init() {}
}
