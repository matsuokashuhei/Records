//
//  PlaybackMonitor.swift
//  Records
//
//  Created by Shuhei Matsuoka on 2026/10/18.
//

import Foundation
import AppKit
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
    /// 再生を要求したが、実際の再生開始がまだ観測できていないエントリのID。
    /// 要求してから再生が始まるまでの間も停止アイコンを表示するために使う。
    @Published private(set) var pendingEntryID: String?
    /// pending中のエントリ(再生開始の確認にkind/titleが必要)
    private var pendingEntry: MediaEntry?
    /// 再生要求を出した時刻(pendingのタイムアウト用)
    private var pendingSince: Date?
    /// 再生開始を確認するまでの待機上限(秒)。
    /// これを超えても再生が観測できなければ要求は失敗したとみなす
    private static let pendingTimeout: TimeInterval = 30

    private var pollTask: Task<Void, Never>?
    /// ポーリングを要求しているシェルフウィンドウの数
    /// (.onAppear→+1/.onDisappear→-1。複数ウィンドウで共有するため
    ///  片方が閉じても他方が表示中ならポーリングを継続する)
    private var pollingClients = 0
    /// 表示中のビューがポーリングを要求しているか。
    /// アプリが隠れている間はポーリングを止め、unhide時にこれがtrueなら再開する。
    private var wantsPolling = false
    /// 再生/停止の切り替え中フラグ(ダブルタップなどの再入防止)
    private var isToggling = false
    private var visibilityObservers: [NSObjectProtocol] = []

    private init() {
        // NSApp.hide(nil)はビューの.onDisappearを発火させない。
        // そのままだと非表示中も2秒おきにosascriptをspawnし続けるため、
        // アプリのhide/unhideにポーリングを連動させる。
        // (隠蔽中に全ウィンドウが閉じられても、.onDisappear→stopPollingで
        //  pollingClientsが0になりwantsPolling=falseになるためunhideで再開しない)
        visibilityObservers = [
            NotificationCenter.default.addObserver(
                forName: NSApplication.didHideNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.pauseForHide() }
            },
            NotificationCenter.default.addObserver(
                forName: NSApplication.didUnhideNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeForUnhide() }
            },
        ]
    }

    var isPlaying: Bool { musicAppPlaying || inAppPlaying }

    /// このエントリが「再生中」かどうか。
    /// 再生要求から実際の再生開始を観測できるまで数秒かかるため、
    /// 要求中(pending)のエントリも再生中として扱う。
    func isCurrent(_ entry: MediaEntry) -> Bool {
        if pendingEntryID == entry.id { return true }
        return isPlayingNow(entry)
    }

    /// 実際の再生状態として観測されているか(pendingの要求は含めない)
    private func isPlayingNow(_ entry: MediaEntry) -> Bool {
        switch entry.kind {
        case .album:
            return musicAppPlaying && currentAlbumTitle == entry.title
        case .playlist:
            return inAppPlaying && activeEntryID == entry.id
        }
    }

    private func clearPending() {
        pendingEntry = nil
        pendingEntryID = nil
        pendingSince = nil
    }

    func start() {
        pollingClients += 1
        wantsPolling = true
        startPollingIfNeeded()
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        // アプリが隠れている間は回さない(didUnhideNotificationで再開する)
        guard !NSApp.isHidden else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollingClients = max(0, pollingClients - 1)
        guard pollingClients == 0 else { return }
        wantsPolling = false
        pollTask?.cancel()
        pollTask = nil
    }

    private func pauseForHide() {
        Self.logger.notice("app hidden; pausing playback polling")
        pollTask?.cancel()
        pollTask = nil
    }

    private func resumeForUnhide() {
        guard wantsPolling, pollTask == nil else { return }
        Self.logger.notice("app unhidden; resuming playback polling")
        startPollingIfNeeded()
    }

    func refresh() async {
        let info = await PlaybackEngine.nowPlayingInfo()
        // 変化がないときは@Publishedへの代入を避ける
        // (2秒おきの無変更publishで20枚のセルが再描画されるのを防ぐ)
        let newMusicAppPlaying = info?.isPlaying ?? false
        if musicAppPlaying != newMusicAppPlaying { musicAppPlaying = newMusicAppPlaying }
        if currentAlbumTitle != info?.album { currentAlbumTitle = info?.album }

        let newInAppPlaying = ApplicationMusicPlayer.shared.state.playbackStatus == .playing
        if inAppPlaying != newInAppPlaying { inAppPlaying = newInAppPlaying }

        if !isPlaying, activeEntryID != nil, activeEntryID != pendingEntryID {
            activeEntryID = nil
        }

        // pending中のエントリが実際に鳴り始めたか確認する。
        // 鳴らないままタイムアウトしたら諦める(無音失敗で
        // 停止アイコンが残り続けないようにする)
        if let pending = pendingEntry {
            if isPlayingNow(pending) {
                Self.logger.notice("pending playback confirmed for '\(pending.title, privacy: .public)'")
                clearPending()
            } else if let since = pendingSince,
                      Date().timeIntervalSince(since) > Self.pendingTimeout {
                Self.logger.notice("pending playback timed out for '\(pending.title, privacy: .public)'")
                clearPending()
            }
        }
    }

    /// 表示枚数の縮小などでアクティブなエントリが非表示になった場合に
    /// in-app再生(プレイリスト)を止める。
    /// 非表示スロットには停止UIが無いため、放置するとアプリを終了するまで
    /// 止められない。Musicアプリ側のアルバム再生はMusicアプリから止められるので対象外。
    /// 複数シェルフがあるので、どれかのシェルフで表示されていれば止めない。
    func stopIfActiveEntryHidden() {
        guard inAppPlaying, let id = activeEntryID else { return }
        let visibleIDs = ShelfManager.shared.allVisibleEntryIDs
        guard !visibleIDs.contains(id) else { return }
        Self.logger.notice("active entry \(id, privacy: .public) is now hidden; stopping in-app playback")
        PlaylistPlayer.stop()
        activeEntryID = nil
        Task { await refresh() }
    }

    /// クリックで再生/停止を切り替える
    func toggle(_ entry: MediaEntry) async throws {
        guard !isToggling else {
            Self.logger.notice("toggle ignored (already toggling)")
            return
        }
        isToggling = true
        defer { isToggling = false }

        if isCurrent(entry) {
            Self.logger.notice("stop \(entry.title, privacy: .public)")
            // Clear pending before stop so a throwing stop() can't leak the icon.
            // Known limitation: album playback is fire-and-forget (shortcuts://run-shortcut),
            // so it may still start seconds later — observed state then flips back to stop.
            if pendingEntry?.id == entry.id { clearPending() }
            try await PlaybackEngine.stop(entry)
            activeEntryID = nil
        } else {
            Self.logger.notice("play \(entry.title, privacy: .public)")
            pendingEntry = entry
            pendingEntryID = entry.id
            pendingSince = Date()
            do {
                try await PlaybackEngine.play(entry)
            } catch {
                clearPending()
                throw error
            }
            activeEntryID = entry.id
            if entry.kind == .album {
                currentAlbumTitle = entry.title
            }
        }
        await refresh()
    }
}
