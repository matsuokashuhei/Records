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
                return "Apple Musicへのアクセスが許可されていません。システム設定 → プライバシーとセキュリティ → メディアとApple Music で Records を許可してください。"
            case .invalidInput:
                return "URLまたはIDの形式を認識できませんでした。アルバムまたはプレイリストのURLを入力してください。"
            case .notFound:
                return "Apple Musicに見つかりませんでした。"
            }
        }
    }

    static func fetch(_ parsed: MediaURLParser.Parsed) async throws -> MediaEntry {
        logger.notice("fetch kind=\(parsed.kind.rawValue, privacy: .public) country=\(parsed.country, privacy: .public) id=\(parsed.id, privacy: .public)")

        // カタログ取得にもメディアライブラリ許可が必要(実測: 無許可だと .permissionDenied)
        if MusicAuthorization.currentStatus != .authorized {
            let status = await MusicAuthorization.request()
            logger.notice("authorization result=\(status.rawValue, privacy: .public)")
            guard status == .authorized else { throw CatalogError.notAuthorized }
        }

        do {
            switch parsed.kind {
            case .album:
                var request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(parsed.id))
                let response = try await request.response()
                logger.notice("album response count=\(response.items.count, privacy: .public)")
                guard let album = response.items.first else { throw CatalogError.notFound }
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
                var request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: MusicItemID(parsed.id))
                let response = try await request.response()
                logger.notice("playlist response count=\(response.items.count, privacy: .public)")
                guard let playlist = response.items.first else { throw CatalogError.notFound }
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
