import Foundation
import os

/// シェルフの表示設定(表示枚数=列数×行数とアートワークサイズ)。
/// ShelfStore.shelfDirectory(shelfID) 下の settings.json に JSON で保存する
/// (設定はシェルフ=ウィンドウごとに独立)。
/// 読み書きはすべて nonisolated。
struct ShelfSettings: Codable, Equatable {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Sleeves", category: "Settings")

    /// 列数/行数それぞれの選択上限
    static let maxDimension = 10

    /// グリッドの間隔の既定値とスライダーの許容範囲。
    /// columnSpacing=レコード同士の横の隙間、rowSpacing=シェルフ段の縦の隙間。
    /// 外周の余白は独立した設定ではなく間隔から導出する
    /// (下の edgePadding/topPadding/bottomPadding 計算プロパティ参照)
    static let defaultColumnSpacing: Double = 12
    static let defaultRowSpacing: Double = 14
    static let columnSpacingRange: ClosedRange<Double> = 0...64
    static let rowSpacingRange: ClosedRange<Double> = 0...96

    /// 旧settings.jsonの登録枚数(capacity)を列×行へ変換するための退避表。
    /// 新フォーマットはcolumns/rowsを直接持つ。
    private static let legacyLayouts: [Int: (columns: Int, rows: Int)] = [
        6: (3, 2),
        12: (4, 3),
        20: (5, 4),
    ]

    /// シェルフの構造スタイル(排他選択)。rawValueはsettings.jsonの
    /// "shelfStyle" キーに保存される値なので一度決めたら変更しない。
    /// スタイルを足すときはcaseを追加し、対応する構造プラグインの
    /// shelfStyleに同じ値を返させる(レジストリが選択中スタイルの
    /// 構造プラグインだけをresolveする)
    enum ShelfStyle: String, Codable, CaseIterable, Identifiable {
        /// レコード店の棚(通し棚板+アクリル前柵。StoreShelfPlugin)
        case store
        /// 壁掛けウッドレッジ(スロットごとの小さな木製土台。
        /// LedgeShelfPlugin)
        case ledge

        var id: String { rawValue }

        /// 表示ラベル(Localizable.xcstringsのキー)
        var label: String {
            switch self {
            case .store: return "Store Shelf"
            case .ledge: return "Wood Ledges"
            }
        }
    }

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
    /// シェルフの構造スタイル(排他)。settings.jsonの "shelfStyle" キー。
    /// 既存ファイルにはキーが無いのでデコード時は .store に倒す
    /// (後方互換。従来の棚板+前柵の見た目が維持される)
    var shelfStyle: ShelfStyle
    /// エフェクトプラグインの状態(プラグインID→有効/パラメータ値)。
    /// settings.jsonの "plugins" キー。既存ファイルにはキーが無いので
    /// デコード時は空辞書(=全プラグイン無効・デフォルト値)に倒す
    /// (Codable後方互換)。モデルは Shared/ShelfPluginModel.swift。
    var plugins: [String: PluginState]
    /// レコード同士の横の隙間(pt)。スライダーで調整可能
    var columnSpacing: Double
    /// シェルフ段同士の縦の隙間(pt)。スライダーで調整可能
    var rowSpacing: Double
    /// レコード削除時に確認ダイアログを出すか。
    /// true=確認してから削除(従来動作)、false=確認せず即削除。
    /// settings.jsonの "confirmDelete" キー。既存ファイルにはキーが
    /// 無いのでデコード時は true に倒す(後方互換)
    var confirmDelete: Bool
    /// グリッド外周の余白のうち左右(pt)。
    /// 独立した設定ではなく、常にレコード間隔(columnSpacing)と同じ値になる
    /// 導出値(settings.jsonには保存しない)
    var edgePadding: Double { columnSpacing }
    /// グリッド外周の余白のうち上端(pt)。
    /// 独立した設定ではなくシェルフ段間隔(rowSpacing)から導出する
    /// (settings.jsonには保存しない)。下限4ptを設けるのは、
    /// ShelfViewが上端に高さtopPaddingの透明なWindowDragGesture帯を
    /// 敷いており、0だとウィンドウを動かせなくなるため(タイトルバー非表示)
    var topPadding: Double { max(4, rowSpacing) }
    /// グリッド外周の余白のうち下端(pt)。
    /// 上端と同じくシェルフ段間隔(rowSpacing)と同じ幅の導出値
    /// (settings.jsonには保存しない)。上端と違い下限は設けない —
    /// topPaddingの4pt下限はWindowDragGesture帯の確保が目的で、
    /// 下端にはその制約が無い(rowSpacing=0では最終行の棚板厚が
    /// 0へクランプされるだけで、既存の厚さクランプの意味論と一致)
    var bottomPadding: Double { rowSpacing }

    /// 表示スロット数(列×行)
    var capacity: Int { columns * rows }

    /// ログ用のプラグイン状態サマリ(例: "lean-depth=on{lean=35.0}")。
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
        case columns, rows, artworkSize, shelfStyle, plugins, confirmDelete
        case columnSpacing, rowSpacing
        case legacyCapacity = "capacity"
    }

    /// 旧settings.jsonで store-shelf プラグインが持っていた壁関連
    /// パラメータのキー。wall プラグインへ分離した際に値を引き継ぐ
    /// (WallPlugin.parameterSpecsのIDと一致させること)
    private static let wallParamKeys: Set<String> = [
        "wall",
        "aging-warmth", "aging-sepia", "aging-stains",
        "aging-fade-marks", "aging-vignette",
    ]

    init(columns: Int, rows: Int, artworkSize: ArtworkSize,
         shelfStyle: ShelfStyle = .store,
         plugins: [String: PluginState] = [:],
         columnSpacing: Double = Self.defaultColumnSpacing,
         rowSpacing: Double = Self.defaultRowSpacing,
         confirmDelete: Bool = true) {
        self.columns = min(max(columns, 1), Self.maxDimension)
        self.rows = min(max(rows, 1), Self.maxDimension)
        self.artworkSize = artworkSize
        self.shelfStyle = shelfStyle
        self.plugins = plugins
        self.columnSpacing = min(max(columnSpacing, Self.columnSpacingRange.lowerBound),
                                 Self.columnSpacingRange.upperBound)
        self.rowSpacing = min(max(rowSpacing, Self.rowSpacingRange.lowerBound),
                              Self.rowSpacingRange.upperBound)
        self.confirmDelete = confirmDelete
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let size = (try? c.decode(ArtworkSize.self, forKey: .artworkSize)) ?? .s
        // 新キー "shelfStyle": 既存settings.jsonには無いので省略時は
        // .store(従来の見た目)。未知の値も .store に倒す
        let shelfStyle = (try? c.decode(ShelfStyle.self, forKey: .shelfStyle)) ?? .store
        // 新キー "plugins": 既存settings.jsonには無いので省略時は空
        // (=全プラグイン無効・デフォルト値)。壊れた辞書でも落ちないよう
        // try? で空へ倒す
        var plugins = (try? c.decode([String: PluginState].self, forKey: .plugins)) ?? [:]
        // 壁はstore-shelfプラグインからwallプラグインへ分離した。
        // 旧ファイルでstore-shelfが保持していた壁関連の値をwallへ引き継ぐ
        // (wallが既に保存されていればそちらを優先。store-shelf側の残存
        //  キーはspec外として次回保存時に間引かれる)
        if plugins["wall"] == nil, let storeShelf = plugins["store-shelf"] {
            var migrated = storeShelf
            let wallValues = migrated.values.filter {
                Self.wallParamKeys.contains($0.key)
            }
            migrated.values = migrated.values.filter {
                !Self.wallParamKeys.contains($0.key)
            }
            plugins["wall"] = PluginState(
                enabled: storeShelf.enabled, values: wallValues)
            plugins["store-shelf"] = migrated
            Self.logger.notice("migrated wall params from store-shelf to wall (keys=\(wallValues.keys.sorted().joined(separator: ","), privacy: .public), enabled=\(storeShelf.enabled, privacy: .public))")
        }
        // 新キー "columnSpacing"/"rowSpacing": 既存settings.jsonには無いので
        // 省略時は既定値。initで範囲にクランプされる
        let columnSpacing = (try? c.decode(Double.self, forKey: .columnSpacing))
            ?? Self.defaultColumnSpacing
        let rowSpacing = (try? c.decode(Double.self, forKey: .rowSpacing))
            ?? Self.defaultRowSpacing
        // 新キー "confirmDelete": 既存settings.jsonには無いので省略時は
        // true(削除時に確認する従来動作)に倒す
        let confirmDelete = (try? c.decode(Bool.self, forKey: .confirmDelete)) ?? true
        // edgePadding/topPadding/bottomPaddingは導出値になったため
        // settings.jsonには書かない。古いファイルに残っていても
        // 未知キーとして無視される
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
                shelfStyle: shelfStyle,
                plugins: plugins,
                columnSpacing: columnSpacing,
                rowSpacing: rowSpacing,
                confirmDelete: confirmDelete
            )
        } else {
            // 旧フォーマット(capacity: 6/12/20)からの移行
            let legacy = (try? c.decode(Int.self, forKey: .legacyCapacity)) ?? 20
            let layout = Self.legacyLayouts[legacy] ?? (5, 4)
            self.init(columns: layout.columns, rows: layout.rows, artworkSize: size,
                      shelfStyle: shelfStyle,
                      plugins: plugins, columnSpacing: columnSpacing,
                      rowSpacing: rowSpacing, confirmDelete: confirmDelete)
        }
    }

    /// 新フォーマットではcolumns/rows(とplugins)のみ書き出す
    /// (legacyCapacityは読み取り専用)
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(columns, forKey: .columns)
        try c.encode(rows, forKey: .rows)
        try c.encode(artworkSize, forKey: .artworkSize)
        try c.encode(shelfStyle, forKey: .shelfStyle)
        // 常に書き出す。空なら "plugins":{} となり、読み戻しも空で一致する
        try c.encode(plugins, forKey: .plugins)
        try c.encode(columnSpacing, forKey: .columnSpacing)
        try c.encode(rowSpacing, forKey: .rowSpacing)
        // 常に書き出す(読み戻しも同じ値で一致する)
        try c.encode(confirmDelete, forKey: .confirmDelete)
        // edgePadding/topPadding/bottomPaddingは導出値なので書き出さない
    }

    /// 設定はシェルフごとに Shelves/<shelfID>/settings.json に保存する
    static func fileURL(shelfID: String) -> URL {
        ShelfStore.shelfDirectory(shelfID).appendingPathComponent("settings.json")
    }

    static func loadFromDisk(shelfID: String) -> ShelfSettings {
        do {
            let data = try Data(contentsOf: fileURL(shelfID: shelfID))
            let settings = try JSONDecoder().decode(ShelfSettings.self, from: data)
            logger.notice("settings.json loaded (shelf=\(shelfID, privacy: .public)): columns=\(settings.columns, privacy: .public) rows=\(settings.rows, privacy: .public) artworkSize=\(settings.artworkSize.rawValue, privacy: .public) shelfStyle=\(settings.shelfStyle.rawValue, privacy: .public) colGap=\(settings.columnSpacing, privacy: .public) rowGap=\(settings.rowSpacing, privacy: .public) edgePad=\(settings.edgePadding, privacy: .public) topPad=\(settings.topPadding, privacy: .public) bottomPad=\(settings.bottomPadding, privacy: .public) confirmDelete=\(settings.confirmDelete, privacy: .public) plugins=\(settings.pluginSummary, privacy: .public)")
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
            logger.notice("settings.json saved (shelf=\(shelfID, privacy: .public)): columns=\(settings.columns, privacy: .public) rows=\(settings.rows, privacy: .public) artworkSize=\(settings.artworkSize.rawValue, privacy: .public) shelfStyle=\(settings.shelfStyle.rawValue, privacy: .public) colGap=\(settings.columnSpacing, privacy: .public) rowGap=\(settings.rowSpacing, privacy: .public) edgePad=\(settings.edgePadding, privacy: .public) topPad=\(settings.topPadding, privacy: .public) bottomPad=\(settings.bottomPadding, privacy: .public) confirmDelete=\(settings.confirmDelete, privacy: .public) plugins=\(settings.pluginSummary, privacy: .public)")
        } catch {
            logger.error("settings.json save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
