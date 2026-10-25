import Foundation
import MusicKit
import os

/// MusicKitカタログAPIでアルバム/プレイリストのメタデータを取得する。
/// カタログの読み取りにはユーザー認可は不要(再生時にのみ必要)。
enum MediaCatalogClient {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "Catalog")

    enum CatalogError: LocalizedError {
        case notAuthorized
        case invalidInput
        case notFound
        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return String(localized: "Access to Apple Music is not allowed. Allow Records in System Settings → Privacy & Security → Media & Apple Music.")
            case .invalidInput:
                return String(localized: "The URL or ID format was not recognized. Enter an album or playlist URL.")
            case .notFound:
                return String(localized: "Not found on Apple Music.")
            }
        }
    }

    /// カタログ取得・再生の前にApple Musicへのアクセス許可を確認する。
    /// カタログの読み取りにもメディアライブラリ許可が必要(実測: 無許可だと .permissionDenied)。
    /// PlaylistPlayerからも共用する。
    static func ensureAuthorized() async throws {
        if MusicAuthorization.currentStatus != .authorized {
            let status = await MusicAuthorization.request()
            logger.notice("authorization result=\(status.rawValue, privacy: .public)")
            guard status == .authorized else { throw CatalogError.notAuthorized }
        }
    }

    static func fetch(_ parsed: MediaURLParser.Parsed) async throws -> MediaEntry {
        logger.notice("fetch kind=\(parsed.kind.rawValue, privacy: .public) country=\(parsed.country, privacy: .public) id=\(parsed.id, privacy: .public)")

        try await ensureAuthorized()

        do {
            switch parsed.kind {
            case .album:
                let request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(parsed.id))
                let response = try await request.response()
                logger.notice("album response count=\(response.items.count, privacy: .public)")
                guard let album = response.items.first else { throw CatalogError.notFound }
                // カタログリクエストはデバイスのストアフロントで解決される(MusicKitに
                // ストアフロント指定の公開APIはない)。album.url が nil の場合の
                // フォールバックはユーザーが貼ったURLのストアフロント(parsed.country)
                // から決定的に組み立てる — デバイス側とはズレ得るが、ショートカット経由で
                // Musicアプリが解決する正規形式。
                let entry = MediaEntry(
                    kind: .album,
                    id: parsed.id,
                    title: album.title,
                    artist: album.artistName,
                    country: parsed.country,
                    url: album.url?.absoluteString ?? "https://music.apple.com/\(parsed.country)/album/\(parsed.id)",
                    artworkURL: album.artwork?.url(width: 300, height: 300)?.absoluteString ?? "",
                    addedAt: .now
                )
                logger.notice("album ok title=\(entry.title, privacy: .public) artwork=\(entry.artworkURL, privacy: .public)")
                return entry
            case .playlist:
                let request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: MusicItemID(parsed.id))
                let response = try await request.response()
                logger.notice("playlist response count=\(response.items.count, privacy: .public)")
                guard let playlist = response.items.first else { throw CatalogError.notFound }
                // ストアフロントの扱いは上記アルバム側のコメントと同じ
                let entry = MediaEntry(
                    kind: .playlist,
                    id: parsed.id,
                    title: playlist.name,
                    artist: playlist.curatorName ?? "Apple Music",
                    country: parsed.country,
                    url: playlist.url?.absoluteString ?? "https://music.apple.com/\(parsed.country)/playlist/\(parsed.id)",
                    artworkURL: playlist.artwork?.url(width: 300, height: 300)?.absoluteString ?? "",
                    addedAt: .now
                )
                logger.notice("playlist ok title=\(entry.title, privacy: .public) curator=\(entry.artist, privacy: .public) artwork=\(entry.artworkURL, privacy: .public)")
                return entry
            }
        } catch {
            logger.error("fetch failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}
