import Foundation
import WidgetKit

/// アプリとウィジェット拡張で共有する「シェルフの内容」。
/// 非サンドボックスの個人ビルドのため、Application Support 下のファイルで共有する。
final class ShelfStore: ObservableObject {

    static let capacity = 20
    static let shared = ShelfStore()

    @Published private(set) var entries: [MediaEntry]
    /// アートワークがダウンロードされるたびに増加(ビュー再描画のトリガー)
    @Published private(set) var artworkRevision = 0

    private init() {
        Self.ensureDirectories()
        entries = Self.readFromDisk()
        ensureArtworkDownloaded()
    }

    // MARK: - プリインストール済みアルバム(albums.json が無い初回起動時に表示)

    static let presetEntries: [MediaEntry] = [
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

    static var baseDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Records", isDirectory: true)
    }

    static var artworkDirectory: URL {
        baseDirectory.appendingPathComponent("Artwork", isDirectory: true)
    }

    static var albumFile: URL {
        baseDirectory.appendingPathComponent("albums.json")
    }

    static func ensureDirectories() {
        for dir in [baseDirectory, artworkDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func artworkFileURL(for entry: MediaEntry) -> URL {
        artworkDirectory.appendingPathComponent("\(entry.id).jpg")
    }

    static func readFromDisk() -> [MediaEntry] {
        guard let data = try? Data(contentsOf: albumFile) else {
            // 初回起動(まだ一度も保存していない): プリインストール済みアルバムを表示
            return presetEntries
        }
        return (try? JSONDecoder().decode([MediaEntry].self, from: data)) ?? presetEntries
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
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: Self.albumFile, options: .atomic)
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

    // MARK: - アートワーク

    static func downloadArtwork(for entry: MediaEntry) async throws -> URL {
        let destination = artworkFileURL(for: entry)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        guard !entry.artworkURL.isEmpty, let url = URL(string: entry.artworkURL) else {
            throw PlaybackEngine.PlaybackError.failed("アートワークURLがありません")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// 不足しているアートワークをバックグラウンドで取得(アプリ/ウィジェットどちらでも)
    func ensureArtworkDownloaded() {
        Task {
            var downloadedAny = false
            for entry in entries {
                let file = Self.artworkFileURL(for: entry)
                guard !FileManager.default.fileExists(atPath: file.path) else { continue }
                if (try? await Self.downloadArtwork(for: entry)) != nil {
                    downloadedAny = true
                    await MainActor.run { artworkRevision += 1 }
                }
            }
            if downloadedAny {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}
