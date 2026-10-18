//
//  PlaybackMonitor.swift
//  Records
//
//  Created by Shuhei Matsuoka on 2026/10/18.
//

import Foundation
import MusicKit
import os

/// Musicアプリ(アルバム)と本アプリ内プレイヤー(プレイリスト)の再生状態を監視し、
/// どのエントリが再生中かを追跡する。
@MainActor
final class PlaybackMonitor: ObservableObject {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "Monitor")

    static let shared = PlaybackMonitor()

    /// Musicアプリ側の再生状態
    @Published private(set) var musicAppPlaying = false
    /// 本アプリ内プレイヤー(ApplicationMusicPlayer)の再生状態
    @Published private(set) var inAppPlaying = false
    /// Musicアプリで再生中のアルバム名
    @Published private(set) var currentAlbumTitle: String?
    /// 自分が最後に鳴らしたエントリのID(プレイリスト表示用)
    @Published private(set) var activeEntryID: String?

    private var pollTask: Task<Void, Never>?
    private init() {}

    var isPlaying: Bool { musicAppPlaying || inAppPlaying }

    /// このエントリが「再生中」かどうか
    func isCurrent(_ entry: MediaEntry) -> Bool {
        switch entry.kind {
        case .album:
            return musicAppPlaying && currentAlbumTitle == entry.title
        case .playlist:
            return inAppPlaying && activeEntryID == entry.id
        }
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        let info = await PlaybackEngine.nowPlayingInfo()
        musicAppPlaying = info?.isPlaying ?? false
        currentAlbumTitle = info?.album

        inAppPlaying = ApplicationMusicPlayer.shared.state.playbackStatus == .playing

        if !isPlaying {
            activeEntryID = nil
        }
    }

    /// クリックで再生/停止を切り替える
    func toggle(_ entry: MediaEntry) async throws {
        if isCurrent(entry) {
            Self.logger.notice("stop \(entry.title, privacy: .public)")
            try await PlaybackEngine.stop(entry)
            activeEntryID = nil
        } else {
            Self.logger.notice("play \(entry.title, privacy: .public)")
            try await PlaybackEngine.play(entry)
            activeEntryID = entry.id
            if entry.kind == .album {
                currentAlbumTitle = entry.title
            }
        }
        await refresh()
    }
}
