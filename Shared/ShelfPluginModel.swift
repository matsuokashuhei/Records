import Foundation
import os

/// シェルフエフェクトプラグインの永続化モデル(純データ層)。
/// UI側のプラグイン定義(ShelfPluginプロトコル・レジストリ・合成)は
/// Records/ShelfPlugins.swift にあり、ここには settings.json に
/// 保存するための値型だけを置く(Shared=アプリ/将来の拡張共用)。
///
/// 永続化スキーマ(settings.json内):
///   "plugins": {
///     "<pluginID>": { "enabled": true, "values": { "<paramID>": <値> } }
///   }
/// 既存settings.jsonには "plugins" キー自体が無いので、
/// ShelfSettings側は省略時に空辞書(=全プラグイン無効・デフォルト値)へ
/// デコードする(後方互換)。

private let pluginModelLogger = Logger(
    subsystem: "com.cacheandbuffer.Records", category: "Plugins")

/// プラグインパラメータの値。スライダーの数値以外に、将来の
/// ピッカー/セグメント選択(String)やトグル(Bool)等の型追加を
/// 見込んでenumにする。JSON上は生の値(number/bool/string)として
/// 読み書きするので、settings.jsonの手編集とも相性がよい。
enum PluginParameterValue: Codable, Equatable {
    case number(Double)
    case boolean(Bool)
    case string(String)

    /// 数値として解釈できる値(boolean/stringはnil)
    var number: Double? {
        if case .number(let v) = self { return v }
        return nil
    }
    var boolean: Bool? {
        if case .boolean(let v) = self { return v }
        return nil
    }
    var string: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// ログ用の短い表示(例: "12.5", "true", "jazz")
    var displayString: String {
        switch self {
        case .number(let v): return String(v)
        case .boolean(let v): return String(v)
        case .string(let v): return v
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // JSONの素の値を順に試す。数値→bool→文字列の順
        // ("true"をDoubleには読めない、"1"をBoolには読めないので安全)
        if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(Bool.self) {
            self = .boolean(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else {
            pluginModelLogger.error("PluginParameterValue: undecodable JSON value; falling back to number(0)")
            self = .number(0)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let v): try c.encode(v)
        case .boolean(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }
}

/// プラグインが公開する調整可能パラメータの定義(型付き・範囲・
/// デフォルト値つき)。設定画面はこの定義を見てUI(スライダー等)を生成する。
/// 将来enum選択やトグルを足す場合はcaseを追加する
/// (追加すると設定画面のswitchが未対応でコンパイルエラーになる=実装忘れ検知)。
enum PluginParameterSpec: Equatable {
    /// 連続/刻み値を取るスライダー
    case slider(Slider)

    struct Slider: Equatable {
        /// パラメータID。PluginState.valuesのキーになるので
        /// プラグイン内で安定させる(変えると保存済み値が効かなくなる)
        let id: String
        /// 設定画面の行ラベル
        let label: String
        /// 値の範囲
        let range: ClosedRange<Double>
        /// 刻み幅。nil=連続
        let step: Double?
        /// 未設定時のデフォルト値
        let defaultValue: Double
    }

    /// パラメータID(永続化キー)
    var id: String {
        switch self {
        case .slider(let s): return s.id
        }
    }

    /// 設定画面の行ラベル
    var label: String {
        switch self {
        case .slider(let s): return s.label
        }
    }

    /// 未設定時に使うデフォルト値
    var defaultValue: PluginParameterValue {
        switch self {
        case .slider(let s): return .number(s.defaultValue)
        }
    }
}

/// シェルフ単位で保存される、あるプラグインの状態。
/// settings.jsonの "plugins" 辞書値に対応する。
struct PluginState: Codable, Equatable {
    /// プラグインの有効フラグ(P0-1)。省略時は無効
    var enabled: Bool
    /// パラメータID→値。キーが無いパラメータはspecのデフォルト値で解釈する
    /// (プラグインに後からパラメータが増えても古いjsonで動く)
    var values: [String: PluginParameterValue]

    init(enabled: Bool = false, values: [String: PluginParameterValue] = [:]) {
        self.enabled = enabled
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        values = (try? c.decode([String: PluginParameterValue].self, forKey: .values)) ?? [:]
    }

    /// specのデフォルト値で欠けたキーを補完した解決済み値マップを返す。
    /// プラグインはこれをcontext.valuesとして受け取り、
    /// 「値が無い=デフォルト」を気にしなくてよい
    func resolvedValues(specs: [PluginParameterSpec]) -> [String: PluginParameterValue] {
        var resolved = values
        for spec in specs where resolved[spec.id] == nil {
            resolved[spec.id] = spec.defaultValue
        }
        return resolved
    }
}
