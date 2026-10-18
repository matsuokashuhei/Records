import Foundation
import WidgetKit
import AppKit
import os

/// アプリとウィジェット拡張で共有する「シェルフの内容」。
/// 非サンドボックスの個人ビルドのため、Application Support 下のファイルで共有する。
/// 可変状態(entries等)はメインアクター上でのみ扱う。ウィジェット拡張など
/// メインアクター外からは nonisolated のディスク読み取りAPIを使うこと。
@MainActor
final class ShelfStore: ObservableObject {

    nonisolated private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "Shelf")

    nonisolated static let capacity = 20
    static let shared = ShelfStore()

    @Published private(set) var entries: [MediaEntry]
    /// アートワークがダウンロードされるたびに増加(ビュー再描画のトリガー)
    @Published private(set) var artworkRevision = 0

    /// デコード済みジャケット画像のキャッシュ(entry.id → NSImage)。
    /// セルの body が走るたびに同期ディスク読み込み+デコードしないためのもの。
    private static var imageCache: [String: NSImage] = [:]

    private init() {
        Self.ensureDirectories()
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
        guard entries.count < Self.capacity, !contains(entry.id) else { return false }
        entries.append(entry)
        save()
        return true
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        // 削除したエントリのデコード済み画像もキャッシュから落とす
        // (同じIDを後で追加し直した場合に古い画像が残らないように)
        Self.imageCache.removeValue(forKey: id)
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: Self.albumFile, options: .atomic)
        } catch {
            Self.logger.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - 表示用

    /// 常に20スロットに満たす。空きは nil。
    func paddedSlots() -> [MediaEntry?] {
        var slots: [MediaEntry?] = entries
        while slots.count < Self.capacity { slots.append(nil) }
        return Array(slots.prefix(Self.capacity))
    }

    /// メインアクター外(ウィジェット拡張のTimelineProvider等)からの読み取り用。
    /// 共有インスタンスを介さず、毎回ディスクから読む。
    nonisolated static func paddedSlotsFromDisk() -> [MediaEntry?] {
        var slots: [MediaEntry?] = readFromDisk()
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

    /// 不足しているアートワークをバックグラウンドで取得(アプリ/ウィジェットどちらでも)。
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
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}
