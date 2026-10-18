import Foundation
import MusicKit
import os

/// プレイリストを本アプリ内のプレイヤー(MusicKit ApplicationMusicPlayer)で再生する。
///
/// 「音楽を再生」ショートカットはプレイリストURLを解決できない(実測済み)ため、
/// プレイリストの再生だけこの経路を使う。音声は本アプリプロセスから出るため、
/// Musicアプリの画面は関与しない(Now PlayingはControl Centerに表示される)。
enum PlaylistPlayer {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "Playlist")

    static func play(_ entry: MediaEntry) async throws {
        logger.notice("play() start id=\(entry.id, privacy: .public) authStatus=\(MusicAuthorization.currentStatus.rawValue, privacy: .public)")

        // Musicアプリが再生中なら先に止める(二重再生の防止)
        await PlaybackEngine.stopMusicApp()

        if MusicAuthorization.currentStatus != .authorized {
            let status = await MusicAuthorization.request()
            logger.notice("authorization result=\(status.rawValue, privacy: .public)")
            guard status == .authorized else {
                throw PlaybackEngine.PlaybackError.failed("Apple Musicへのアクセスが許可されませんでした。")
            }
        }

        var request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: MusicItemID(entry.id))
        let response = try await request.response()
        logger.notice("catalog response count=\(response.items.count, privacy: .public)")
        guard let playlist = response.items.first else {
            throw PlaybackEngine.PlaybackError.failed("プレイリストが見つかりません: \(entry.title)")
        }

        let player = ApplicationMusicPlayer.shared
        player.queue = ApplicationMusicPlayer.Queue(for: [playlist])
        logger.notice("queue set, calling play()...")
        try await player.play()
        logger.notice("play() returned OK")
    }

    static func stop() {
        logger.notice("stop()")
        ApplicationMusicPlayer.shared.stop()
    }
}
