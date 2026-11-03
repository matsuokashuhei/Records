import Foundation
import AppKit
import os

/// 1シェルフ(=1ウィンドウ)の「シェルフの内容」。
/// 非サンドボックスの個人ビルドのため、Application Support 下のファイルで永続化する。
/// シェルフの生成/管理はShelfManagerが行い、ストアはシェルフIDごとに1つ。
/// 可変状態(entries等)はメインアクター上でのみ扱う。
@MainActor
final class ShelfStore: ObservableObject {

    nonisolated private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "Shelf")

    /// このストアが表すシェルフのID(shelves.jsonに登録されたもの)
    let shelfID: String

    @Published private(set) var entries: [MediaEntry]
    /// 表示設定(列数×行数・アートワークサイズ、エフェクトプラグイン)。
    /// settings.json に永続化される。
    @Published private(set) var settings: ShelfSettings
    /// 最後にsettings.jsonへ書いたsettings。
    /// updateSettingsTransient(ドラッグ中の連続更新)はメモリ上のsettings
    /// だけを進めるので、commitSettingsで「保存済みとの差分」判定に使う
    private var persistedSettings: ShelfSettings
    /// アートワークがダウンロードされるたびに増加(ビュー再描画のトリガー)
    @Published private(set) var artworkRevision = 0

    /// 現在の設定での表示スロット数(列×行)。entries自体はこれを超えて保持しうる
    /// (縮小しても登録は消さず、slotIndex >= capacityのものは非表示になるだけ。
    ///  グリッドを広げれば同じスロット位置に再び見える)。
    var capacity: Int { settings.capacity }

    /// 表示範囲[0, capacity)の先頭の空きスロット。無ければnil(=満杯)。
    /// 「満杯」の判定はentries.countではなくこれで行う —
    /// slotIndex >= capacity の非表示エントリが居ても、表示上の
    /// 空きスロットがある限り追加を受理するため
    var firstEmptySlot: Int? {
        ShelfPlacement.firstEmptySlot(entries: entries, capacity: capacity)
    }

    /// デコード済みジャケット画像のキャッシュ(entry.id → NSImage)。
    /// セルの body が走るたびに同期ディスク読み込み+デコードしないためのもの。
    /// アートワークは全シェルフで共有するためキャッシュもstatic共有。
    private static var imageCache: [String: NSImage] = [:]

    init(shelfID: String) {
        self.shelfID = shelfID
        Self.ensureDirectories(shelfID)
        let loadedSettings = ShelfSettings.loadFromDisk(shelfID: shelfID)
        settings = loadedSettings
        persistedSettings = loadedSettings
        // 読み込み時にslotIndexを正規化する(自由配置マイグレーション):
        // 旧フォーマット(キー無し=-1)・重複・衝突はファイル順のまま先頭の
        // 空きスロットへ割り当て、slotIndex昇順に並べる。
        // 変更があった場合だけalbums.jsonを即座に保存する
        let normalized = ShelfPlacement.normalized(Self.readFromDisk(shelfID: shelfID))
        entries = normalized.entries
        if normalized.changed {
            Self.logger.notice("slotIndex normalized: shelf=\(shelfID, privacy: .public) entries=\(self.entries.count, privacy: .public) slots=\(self.entries.map(\.slotIndex).description, privacy: .public) — migrated albums.json saved")
            save()
        }
        ensureArtworkDownloaded()
    }

    // MARK: - プリインストール済みアルバム(albums.json が無い初回起動時に表示)

    nonisolated static let presetEntries: [MediaEntry] = [
        MediaEntry(
            kind: .album,
            id: "1440842296",
            title: "Brown Sugar",
            artist: "ディアンジェロ",
            country: "jp",
            url: "https://music.apple.com/jp/album/brown-sugar/1440842296",
            artworkURL: "https://is1-ssl.mzstatic.com/image/thumb/Music112/v4/3d/b7/01/3db701ab-9511-83e3-54d6-a6ccfcf560a2/13UABIM50177.rgb.jpg/300x300bb.jpg",
            addedAt: Date(timeIntervalSince1970: 0)
        ),
        MediaEntry(
            kind: .album,
            id: "6798814647",
            title: "Fly Girl / Nature of a Sista' - EP",
            artist: "クイーン・ラティファ",
            country: "jp",
            url: "https://music.apple.com/jp/album/fly-girl-nature-of-a-sista-ep/6798814647",
            artworkURL: "https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/de/8c/60/de8c60a9-ebfe-f619-d50b-71cc6e90346a/016998086384.png/300x300bb.jpg",
            addedAt: Date(timeIntervalSince1970: 0)
        ),
        MediaEntry(
            kind: .album,
            id: "1443791664",
            title: "House of Music",
            artist: "トニー・トニー・トニー",
            country: "jp",
            url: "https://music.apple.com/jp/album/house-of-music/1443791664",
            artworkURL: "https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/26/f9/32/26f9325b-8b1f-4aea-68d0-849fe7dbc6aa/00731453425026.rgb.jpg/300x300bb.jpg",
            addedAt: Date(timeIntervalSince1970: 0)
        ),
    ]

    // MARK: - ストレージ

    nonisolated static var baseDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Records", isDirectory: true)
    }

    nonisolated static var artworkDirectory: URL {
        baseDirectory.appendingPathComponent("Artwork", isDirectory: true)
    }

    /// 全シェルフのデータの親。サブディレクトリ名=シェルフID
    nonisolated static var shelvesDirectory: URL {
        baseDirectory.appendingPathComponent("Shelves", isDirectory: true)
    }

    nonisolated static func shelfDirectory(_ shelfID: String) -> URL {
        shelvesDirectory.appendingPathComponent(shelfID, isDirectory: true)
    }

    nonisolated static func albumFile(_ shelfID: String) -> URL {
        shelfDirectory(shelfID).appendingPathComponent("albums.json")
    }

    nonisolated static func ensureDirectories(_ shelfID: String) {
        for dir in [shelfDirectory(shelfID), artworkDirectory] {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                logger.error("mkdir failed: \(dir.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated static func artworkFileURL(for entry: MediaEntry) -> URL {
        artworkDirectory.appendingPathComponent("\(entry.id).jpg")
    }

    nonisolated static func readFromDisk(shelfID: String) -> [MediaEntry] {
        // プリセットはプライマリシェルフ("main")だけに入れる。
        // 新規シェルフは空で始める(プリセットが毎回出ると邪魔なため)
        let fallback = shelfID == "main" ? presetEntries : []
        let file = albumFile(shelfID)
        do {
            let data = try Data(contentsOf: file)
            do {
                return try JSONDecoder().decode([MediaEntry].self, from: data)
            } catch {
                // デコード失敗: ユーザーのファイルを失わないよう退避してからフォールバックで起動する
                // (読めないまま save() が走ると登録データが上書きで消えるため)
                logger.error("albums.json decode failed (\(shelfID, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                let backup = file.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: backup)
                if let _ = try? FileManager.default.copyItem(at: file, to: backup) {
                    logger.notice("unreadable albums.json backed up to \(backup.path, privacy: .public)")
                }
                return fallback
            }
        } catch {
            // 初回起動(まだ一度も保存していない)など
            logger.notice("albums.json not readable (\(shelfID, privacy: .public)), using fallback: \(error.localizedDescription, privacy: .public)")
            return fallback
        }
    }

    // MARK: - 編集 (メインスレッドで呼ぶこと)

    func contains(_ id: String) -> Bool {
        entries.contains { $0.id == id }
    }

    /// 追加パイプラインの結果。シェルフへのドラッグ&ドロップが
    /// これで成否を分岐する
    enum AddOutcome {
        case added(MediaEntry)
        case duplicate
        case full
    }

    /// parse済みのURL/IDから カタログ取得→アートワーク取得→登録 までを
    /// まとめて行う。重複はfetch前に弾いて無駄なカタログアクセスを避ける。
    /// atSlotを渡すと先頭の空きではなくそのスロットへ挿入する(ドロップ位置への
    /// 直接挿入。append→moveだと末尾に一瞬出てから滑るのが見えるため)
    func addFromCatalog(_ parsed: MediaURLParser.Parsed, atSlot s: Int? = nil) async throws -> AddOutcome {
        guard !contains(parsed.id) else {
            Self.logger.notice("addFromCatalog: duplicate id=\(parsed.id, privacy: .public)")
            return .duplicate
        }
        // 満杯=「[0, capacity)に空きスロットが無い」。entries.countではなく
        // 空きスロットの有無で判定する(非表示エントリが居ても空きがあれば追加可)。
        // fetch前に弾く(失敗するとfetch+アートワークDLが無駄になり、
        // 登録されない孤立jpgがArtwork/に残る)
        guard firstEmptySlot != nil else {
            Self.logger.notice("addFromCatalog: shelf full (no empty slot) capacity=\(self.capacity, privacy: .public) id=\(parsed.id, privacy: .public)")
            return .full
        }
        let entry = try await MediaCatalogClient.fetch(parsed)
        Self.logger.notice("addFromCatalog: fetched '\(entry.title, privacy: .public)' id=\(entry.id, privacy: .public)")
        _ = try await Self.downloadArtwork(for: entry)
        return registerFetched(entry, atSlot: s)
    }

    /// 取得済みエントリの最終登録(重複/満杯の再判定→挿入→保存)。
    /// ドロップのプリフェッチ経路など、fetch済みのentryを直接登録する
    /// ときに使う。atSlotは挿入先スロット(nil=先頭の空きスロット)。
    /// 対象スロットが占有済みならShelfPlacement.insertionShiftが
    /// 連続ランを左右どちらかへずらしてスロットを空ける。
    /// fetch待ちの間に同じIDが追加されたり満杯になったりする場合が
    /// あるので、ここで必ず再判定する。
    /// なおinsertionShiftのずらしは常に[0, capacity)内で完結する
    /// (右シフトはb+1 < capacityが条件なので、占有エントリが
    /// capacity超へ押し出されることはない。仮に押し出す変更を入れても、
    /// 押し出されるのは既存エントリであり slotIndex >= capacity の
    /// 「登録保持・非表示」ルールで扱える)
    func registerFetched(_ entry: MediaEntry, atSlot s: Int? = nil) -> AddOutcome {
        guard !contains(entry.id) else {
            Self.logger.notice("registerFetched: duplicate id=\(entry.id, privacy: .public)")
            return .duplicate
        }
        // 満杯=「[0, capacity)に空きスロットが無い」。entries.countでは
        // 判定しない — 非表示エントリが居ても、atSlotが範囲内の空き
        // (またはその他の空き)を指していればcount >= capacityでも受理する
        guard firstEmptySlot != nil else {
            Self.logger.notice("registerFetched: shelf full (no empty slot) capacity=\(self.capacity, privacy: .public) id=\(entry.id, privacy: .public)")
            return .full
        }
        // 指定が範囲外なら先頭の空きスロットに倒す
        let target = (s != nil && s! >= 0 && s! < capacity) ? s : firstEmptySlot
        guard let target,
              let result = ShelfPlacement.insertionShift(
                  entries: entries, inserting: entry, at: target, capacity: capacity
              ) else {
            // 空きがあれば必ず挿入できるはず。到達不能だが防御的に
            Self.logger.error("registerFetched: no insertable slot id=\(entry.id, privacy: .public) requested=\(s ?? -1, privacy: .public) capacity=\(self.capacity, privacy: .public)")
            return .full
        }
        let oldSlots = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.slotIndex) })
        entries = result
        for e in entries {
            if e.id == entry.id {
                Self.logger.notice("registerFetched: added '\(e.title, privacy: .public)' id=\(e.id, privacy: .public) slot=\(e.slotIndex, privacy: .public) shelf=\(self.shelfID, privacy: .public)")
            } else if let old = oldSlots[e.id], old != e.slotIndex {
                Self.logger.notice("entry shifted by insert: '\(e.title, privacy: .public)' \(old, privacy: .public)→\(e.slotIndex, privacy: .public)")
            }
        }
        save()
        return .added(entries.first(where: { $0.id == entry.id }) ?? entry)
    }

    /// シミュレート済みの配置結果(ShelfPlacement.place/reorder/
    /// insertionShiftの返り値。slotIndex昇順)をそのまま確定する。
    /// ドロップの着地時に遅延適用するためのもの — perform時点で
    /// entriesを変えると、ずれ込むレコードが着地フライ中に見えて
    /// ゴーストと2個表示されるため(2026-11-03報告)。
    /// 変化のあったエントリをログに出してalbums.jsonに保存する
    func applyPlacement(_ result: [MediaEntry]) {
        guard result != entries else { return }
        let oldSlots = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.slotIndex) })
        entries = result
        for e in entries {
            if let old = oldSlots[e.id] {
                if old != e.slotIndex {
                    Self.logger.notice("entry moved: '\(e.title, privacy: .public)' \(old, privacy: .public)→\(e.slotIndex, privacy: .public)")
                }
            } else {
                Self.logger.notice("entry added by landing: '\(e.title, privacy: .public)' id=\(e.id, privacy: .public) slot=\(e.slotIndex, privacy: .public)")
            }
        }
        save()
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        // 削除したエントリのデコード済み画像もキャッシュから落とす
        // (同じIDを後で追加し直した場合に古い画像が残らないように)
        Self.imageCache.removeValue(forKey: id)
        // 参照されなくなったアートワークファイルも消す。
        // ただしアートワークは全シェルフ共有なので、他のシェルフが
        // 同じエントリを持っている場合は残す(再追加時はdownloadArtworkが取り直す)
        if !ShelfManager.shared.isEntryUsedElsewhere(id, excluding: shelfID) {
            let file = Self.artworkDirectory.appendingPathComponent("\(id).jpg")
            try? FileManager.default.removeItem(at: file)
        }
        Self.logger.notice("entry removed: shelf=\(self.shelfID, privacy: .public) id=\(id, privacy: .public) remaining=\(self.entries.count, privacy: .public)")
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: Self.albumFile(shelfID), options: .atomic)
        } catch {
            Self.logger.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 表示設定を更新してこのシェルフのsettings.jsonに保存する。
    /// 同じ値なら何もしない。登録データ(albums.json)は触らないので、
    /// 枚数を縮小しても登録は残る。
    /// スライダー等の連続変更には使わないこと(毎tickディスク書き込みと
    /// ログ洪水になる)。そういう経路はupdateSettingsTransient+commitSettings。
    func updateSettings(_ newSettings: ShelfSettings) {
        guard newSettings != settings else { return }
        logSettingsChange(from: settings, to: newSettings)
        settings = newSettings
        persistedSettings = newSettings
        ShelfSettings.saveToDisk(newSettings, shelfID: shelfID)
    }

    /// settingsをメモリ上だけ更新する(永続化・変更ログなし)。
    /// @Publishedなのでセルへのライブ反映はこれだけで効く。
    /// 設定画面のスライダーのように高頻度に変わる経路用。
    /// 一連の編集が終わったら必ずcommitSettings()を呼んで永続化する
    func updateSettingsTransient(_ newSettings: ShelfSettings) {
        guard newSettings != settings else { return }
        settings = newSettings
    }

    /// updateSettingsTransientで進めたsettingsを確定・永続化する。
    /// 保存済みの値と同じなら何もしない(書き込みもログも出さない)
    func commitSettings() {
        guard settings != persistedSettings else { return }
        logSettingsChange(from: persistedSettings, to: settings)
        persistedSettings = settings
        ShelfSettings.saveToDisk(settings, shelfID: shelfID)
    }

    private func logSettingsChange(from old: ShelfSettings, to new: ShelfSettings) {
        Self.logger.notice("settings changed (shelf=\(self.shelfID, privacy: .public)): \(old.columns, privacy: .public)x\(old.rows, privacy: .public)(\(old.capacity, privacy: .public)枚)→\(new.columns, privacy: .public)x\(new.rows, privacy: .public)(\(new.capacity, privacy: .public)枚) artworkSize \(old.artworkSize.rawValue, privacy: .public)→\(new.artworkSize.rawValue, privacy: .public) colGap \(old.columnSpacing, privacy: .public)→\(new.columnSpacing, privacy: .public) rowGap \(old.rowSpacing, privacy: .public)→\(new.rowSpacing, privacy: .public) edgePad \(old.edgePadding, privacy: .public)→\(new.edgePadding, privacy: .public) topPad \(old.topPadding, privacy: .public)→\(new.topPadding, privacy: .public) bottomPad \(old.bottomPadding, privacy: .public)→\(new.bottomPadding, privacy: .public) plugins \(old.pluginSummary, privacy: .public)→\(new.pluginSummary, privacy: .public)")
    }

    // MARK: - 表示用

    /// 常に設定枚数分のスロットを返す。空きは nil。
    /// 自由配置モデル: slotIndexがそのままスロット位置になるので、
    /// 途中に空きがあってもよい。slotIndex >= capacityのエントリは
    /// 登録を保持したままここには現れない(非表示)
    func paddedSlots() -> [MediaEntry?] {
        ShelfPlacement.paddedSlots(entries, capacity: capacity)
    }

    // MARK: - アートワーク

    /// ジャケット画像を返す。初回のみバックグラウンドで読み込み・デコードし、
    /// 以降はメモリキャッシュを返す。読み込めない場合はキャッシュせず nil
    /// (後からダウンロードされるケースで再試行できるように)。
    static func artworkImage(for entry: MediaEntry) async -> NSImage? {
        if let cached = imageCache[entry.id] { return cached }
        let path = artworkFileURL(for: entry).path
        let image = await Task.detached(priority: .userInitiated) {
            NSImage(contentsOfFile: path)
        }.value
        guard let image else { return nil }
        imageCache[entry.id] = image
        return image
    }

    /// ネットワーク取得+ファイル書き込みをメインアクター外で行うため nonisolated。
    nonisolated static func downloadArtwork(for entry: MediaEntry) async throws -> URL {
        let destination = artworkFileURL(for: entry)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        guard !entry.artworkURL.isEmpty, let url = URL(string: entry.artworkURL) else {
            throw PlaybackEngine.PlaybackError.failed(String(localized: "No artwork URL."))
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// 不足しているアートワークをバックグラウンドで取得する。
    /// このクラスは@MainActorなのでTask内もメインアクターで走り、
    /// ネットワーク取得(nonisolated)のawait中だけメインを離れる。
    func ensureArtworkDownloaded() {
        Task {
            var downloadedAny = false
            for entry in entries {
                let file = Self.artworkFileURL(for: entry)
                guard !FileManager.default.fileExists(atPath: file.path) else { continue }
                if (try? await Self.downloadArtwork(for: entry)) != nil {
                    downloadedAny = true
                } else {
                    Self.logger.error("artwork download failed id=\(entry.id, privacy: .public) url=\(entry.artworkURL, privacy: .public)")
                }
            }
            if downloadedAny {
                // ダウンロード毎ではなく最後に1回だけ増やす。
                // (毎回増やすと20枚全部の.taskがそのたびに再起動する)
                artworkRevision += 1
            }
        }
    }
}
