import Foundation
import AppKit
import os

/// アプリの「シェルフの内容」。
/// 非サンドボックスの個人ビルドのため、Application Support 下のファイルで永続化する。
/// 可変状態(entries等)はメインアクター上でのみ扱う。
@MainActor
final class ShelfStore: ObservableObject {

    nonisolated private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "Shelf")

    static let shared = ShelfStore()

    @Published private(set) var entries: [MediaEntry]
    /// 表示設定(列数×行数・アートワークサイズ)。settings.json に永続化される。
    @Published private(set) var settings: ShelfSettings
    /// アートワークがダウンロードされるたびに増加(ビュー再描画のトリガー)
    @Published private(set) var artworkRevision = 0

    /// 現在の設定での表示スロット数(列×行)。entries自体はこれを超えて保持しうる
    /// (縮小しても登録は消さず、先頭からcapacity分だけ表示する)。
    var capacity: Int { settings.capacity }

    /// デコード済みジャケット画像のキャッシュ(entry.id → NSImage)。
    /// セルの body が走るたびに同期ディスク読み込み+デコードしないためのもの。
    private static var imageCache: [String: NSImage] = [:]

    private init() {
        Self.ensureDirectories()
        settings = ShelfSettings.loadFromDisk()
        entries = Self.readFromDisk()
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

    nonisolated static var albumFile: URL {
        baseDirectory.appendingPathComponent("albums.json")
    }

    nonisolated static func ensureDirectories() {
        for dir in [baseDirectory, artworkDirectory] {
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

    nonisolated static func readFromDisk() -> [MediaEntry] {
        do {
            let data = try Data(contentsOf: albumFile)
            do {
                return try JSONDecoder().decode([MediaEntry].self, from: data)
            } catch {
                // デコード失敗: ユーザーのファイルを失わないよう退避してからプリセットで起動する
                // (読めないまま save() が走ると登録データが上書きで消えるため)
                logger.error("albums.json decode failed: \(error.localizedDescription, privacy: .public)")
                let backup = albumFile.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: backup)
                if let _ = try? FileManager.default.copyItem(at: albumFile, to: backup) {
                    logger.notice("unreadable albums.json backed up to \(backup.path, privacy: .public)")
                }
                return presetEntries
            }
        } catch {
            // 初回起動(まだ一度も保存していない)など: プリインストール済みアルバムを表示
            logger.notice("albums.json not readable, using presets: \(error.localizedDescription, privacy: .public)")
            return presetEntries
        }
    }

    // MARK: - 編集 (メインスレッドで呼ぶこと)

    func contains(_ id: String) -> Bool {
        entries.contains { $0.id == id }
    }

    func add(_ entry: MediaEntry) -> Bool {
        guard entries.count < capacity, !contains(entry.id) else { return false }
        entries.append(entry)
        save()
        return true
    }

    /// ドラッグ&ドロップの並び替え。rawIndexは除去前の並びでの挿入位置
    /// (レコードのセルなら左半分=index、右半分=index+1、空きはそのindex)。
    /// 除去によるずれをresolvedInsertionIndexで吸収し、albums.jsonに保存する。
    func move(_ id: String, toIndex rawIndex: Int) {
        guard let from = entries.firstIndex(where: { $0.id == id }) else {
            Self.logger.error("reorder failed: id=\(id, privacy: .public) not found")
            return
        }
        let to = Self.resolvedInsertionIndex(from: from, rawIndex: rawIndex, count: entries.count)
        guard from != to else { return }
        let entry = entries.remove(at: from)
        entries.insert(entry, at: to)
        Self.logger.notice("entry moved: '\(entry.title, privacy: .public)' \(from, privacy: .public)→\(to, privacy: .public)")
        save()
    }

    /// rawIndex(除去前の並びでの挿入位置)を除去後のindexに換算する。
    /// ドロップで実際に順番が変わるかの事前判定にも使う(=fromなら変化なし)。
    nonisolated static func resolvedInsertionIndex(from: Int, rawIndex: Int, count: Int) -> Int {
        var to = min(max(rawIndex, 0), count)
        if from < to { to -= 1 }
        return to
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        // 削除したエントリのデコード済み画像もキャッシュから落とす
        // (同じIDを後で追加し直した場合に古い画像が残らないように)
        Self.imageCache.removeValue(forKey: id)
        // 参照されなくなったアートワークファイルも消す
        // (再追加時はdownloadArtworkが取り直す)
        let file = Self.artworkDirectory.appendingPathComponent("\(id).jpg")
        try? FileManager.default.removeItem(at: file)
        Self.logger.notice("entry removed: id=\(id, privacy: .public) remaining=\(self.entries.count, privacy: .public)")
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: Self.albumFile, options: .atomic)
        } catch {
            Self.logger.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 表示設定を更新してsettings.jsonに保存する。同じ値なら何もしない。
    /// 登録データ(albums.json)は触らないので、枚数を縮小しても登録は残る。
    func updateSettings(_ newSettings: ShelfSettings) {
        guard newSettings != settings else { return }
        Self.logger.notice("settings changed: \(self.settings.columns, privacy: .public)x\(self.settings.rows, privacy: .public)(\(self.settings.capacity, privacy: .public)枚)→\(newSettings.columns, privacy: .public)x\(newSettings.rows, privacy: .public)(\(newSettings.capacity, privacy: .public)枚) artworkSize \(self.settings.artworkSize.rawValue, privacy: .public)→\(newSettings.artworkSize.rawValue, privacy: .public)")
        settings = newSettings
        ShelfSettings.saveToDisk(newSettings)
    }

    // MARK: - 表示用

    /// 常に設定枚数分のスロットに満たす。空きは nil。
    /// entriesがcapacityを超えていても先頭capacity件のみ返す(登録自体は保持)。
    func paddedSlots() -> [MediaEntry?] {
        var slots: [MediaEntry?] = entries
        while slots.count < capacity { slots.append(nil) }
        return Array(slots.prefix(capacity))
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
            throw PlaybackEngine.PlaybackError.failed("アートワークURLがありません")
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
