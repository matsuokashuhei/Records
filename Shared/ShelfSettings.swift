import Foundation
import os

/// シェルフの表示設定(表示枚数=列数×行数とアートワークサイズ)。
/// ShelfStore.shelfDirectory(shelfID) 下の settings.json に JSON で保存する
/// (設定はシェルフ=ウィンドウごとに独立)。
/// 読み書きはすべて nonisolated。
struct ShelfSettings: Codable, Equatable {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "Settings")

    /// 列数/行数それぞれの選択上限
    static let maxDimension = 10

    /// 旧settings.jsonの登録枚数(capacity)を列×行へ変換するための退避表。
    /// 新フォーマットはcolumns/rowsを直接持つ。
    private static let legacyLayouts: [Int: (columns: Int, rows: Int)] = [
        6: (3, 2),
        12: (4, 3),
        20: (5, 4),
    ]

    /// アートワーク(セル)1辺のサイズ。
    enum ArtworkSize: String, Codable, CaseIterable, Identifiable {
        case s
        case m
        case l

        var id: String { rawValue }

        var points: CGFloat {
            switch self {
            case .s: return 96
            case .m: return 144
            case .l: return 216
            }
        }

        var label: String { rawValue.uppercased() }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            // 旧フォーマットの "xl" は L に寄せる
            self = ArtworkSize(rawValue: raw) ?? .l
        }
    }

    /// グリッドの列数(1...maxDimension)
    var columns: Int
    /// グリッドの行数(1...maxDimension)
    var rows: Int
    var artworkSize: ArtworkSize
    /// エフェクトプラグインの状態(プラグインID→有効/パラメータ値)。
    /// settings.jsonの "plugins" キー。既存ファイルにはキーが無いので
    /// デコード時は空辞書(=全プラグイン無効・デフォルト値)に倒す
    /// (Codable後方互換)。モデルは Shared/ShelfPluginModel.swift。
    var plugins: [String: PluginState]

    /// 表示スロット数(列×行)
    var capacity: Int { columns * rows }

    /// ログ用のプラグイン状態サマリ(例: "lean=on{angle=12.5},gloss=off")。
    /// パラメータ値も出すのでスライダー変更がsettings-changedログから追える。
    /// 登録ゼロ/全無効でもキーがあれば列挙する
    var pluginSummary: String {
        plugins
            .sorted { $0.key < $1.key }
            .map { id, state in
                let vals = state.values
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value.displayString)" }
                    .joined(separator: ",")
                let onOff = state.enabled ? "on" : "off"
                return vals.isEmpty ? "\(id)=\(onOff)" : "\(id)=\(onOff){\(vals)}"
            }
            .joined(separator: ",")
    }

    /// 設定ファイルが無い/読めない場合の既定値(5×4=20枚・Sサイズ)。
    static let `default` = ShelfSettings(columns: 5, rows: 4, artworkSize: .s)

    private enum CodingKeys: String, CodingKey {
        case columns, rows, artworkSize, plugins
        case legacyCapacity = "capacity"
    }

    init(columns: Int, rows: Int, artworkSize: ArtworkSize,
         plugins: [String: PluginState] = [:]) {
        self.columns = min(max(columns, 1), Self.maxDimension)
        self.rows = min(max(rows, 1), Self.maxDimension)
        self.artworkSize = artworkSize
        self.plugins = plugins
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let size = (try? c.decode(ArtworkSize.self, forKey: .artworkSize)) ?? .s
        // 新キー "plugins": 既存settings.jsonには無いので省略時は空
        // (=全プラグイン無効・デフォルト値)。壊れた辞書でも落ちないよう
        // try? で空へ倒す
        let plugins = (try? c.decode([String: PluginState].self, forKey: .plugins)) ?? [:]
        let columns = try? c.decode(Int.self, forKey: .columns)
        let rows = try? c.decode(Int.self, forKey: .rows)
        if columns != nil || rows != nil {
            // 手編集などで片方だけ存在する場合は、存在する方を採用し
            // 欠けた方を既定値(5列/4行)で補完する
            if columns == nil || rows == nil {
                Self.logger.notice("settings.json has only one dimension (columns=\(columns.map(String.init) ?? "nil", privacy: .public) rows=\(rows.map(String.init) ?? "nil", privacy: .public)); filling missing side with default")
            }
            self.init(
                columns: columns ?? Self.default.columns,
                rows: rows ?? Self.default.rows,
                artworkSize: size,
                plugins: plugins
            )
        } else {
            // 旧フォーマット(capacity: 6/12/20)からの移行
            let legacy = (try? c.decode(Int.self, forKey: .legacyCapacity)) ?? 20
            let layout = Self.legacyLayouts[legacy] ?? (5, 4)
            self.init(columns: layout.columns, rows: layout.rows, artworkSize: size, plugins: plugins)
        }
    }

    /// 新フォーマットではcolumns/rows(とplugins)のみ書き出す
    /// (legacyCapacityは読み取り専用)
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(columns, forKey: .columns)
        try c.encode(rows, forKey: .rows)
        try c.encode(artworkSize, forKey: .artworkSize)
        // 常に書き出す。空なら "plugins":{} となり、読み戻しも空で一致する
        try c.encode(plugins, forKey: .plugins)
    }

    /// 設定はシェルフごとに Shelves/<shelfID>/settings.json に保存する
    static func fileURL(shelfID: String) -> URL {
        ShelfStore.shelfDirectory(shelfID).appendingPathComponent("settings.json")
    }

    static func loadFromDisk(shelfID: String) -> ShelfSettings {
        do {
            let data = try Data(contentsOf: fileURL(shelfID: shelfID))
            let settings = try JSONDecoder().decode(ShelfSettings.self, from: data)
            logger.notice("settings.json loaded (shelf=\(shelfID, privacy: .public)): columns=\(settings.columns, privacy: .public) rows=\(settings.rows, privacy: .public) artworkSize=\(settings.artworkSize.rawValue, privacy: .public) plugins=\(settings.pluginSummary, privacy: .public)")
            return settings
        } catch {
            // 初回起動やファイル破損時は既定値。読めなくても既定値で動作継続する。
            logger.notice("settings.json not readable (shelf=\(shelfID, privacy: .public)), using defaults: \(error.localizedDescription, privacy: .public)")
            return .default
        }
    }

    static func saveToDisk(_ settings: ShelfSettings, shelfID: String) {
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: fileURL(shelfID: shelfID), options: .atomic)
            logger.notice("settings.json saved (shelf=\(shelfID, privacy: .public)): columns=\(settings.columns, privacy: .public) rows=\(settings.rows, privacy: .public) artworkSize=\(settings.artworkSize.rawValue, privacy: .public) plugins=\(settings.pluginSummary, privacy: .public)")
        } catch {
            logger.error("settings.json save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
