import Foundation
import os

/// 再生エンジン。
///
/// - アルバム: 「音楽を再生」ショートカットにURLを渡してMusicアプリで再生
///   (`shortcuts://run-shortcut` URLスキーム経由。LaunchServicesを介すため
///   呼び出し元の文脈に引きずられず、オートメーション許可(TCC)も不要。
///   Apple Events / shortcuts CLI はGUIアプリプロセスからだとショートカットの
///   名前解決に失敗するため不採用 — 2026-10-18 実機検証)
/// - プレイリスト: MusicKit ApplicationMusicPlayer で本アプリ内再生
///   (ショートカットの「音楽を再生」はプレイリストURLを解決できないため — 実測済み)
enum PlaybackEngine {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "Playback")

    /// 対応するショートカット名(この順で優先)
    static let shortcutNameCandidates = [
        "Recordsで再生",
        "Apple Musicミニプレイヤー",
    ]

    enum PlaybackError: LocalizedError {
        case shortcutMissing(visible: [String])
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .shortcutMissing(let visible):
                let names = visible.isEmpty
                    ? String(localized: "(No shortcuts are visible to the shortcuts command.)")
                    : String(localized: "Found shortcuts: \(visible.joined(separator: ", "))")
                return String(localized: "Playback shortcut (\(shortcutNameCandidates.joined(separator: " / "))) not found.\n\(names)")
            case .failed(let detail):
                return String(localized: "Playback failed: \(detail)")
            }
        }
    }

    /// 種類に応じて再生する
    static func play(_ entry: MediaEntry) async throws {
        logger.notice("play() start kind=\(entry.kind.rawValue, privacy: .public) url=\(entry.url, privacy: .public)")
        switch entry.kind {
        case .album:
            try await playAlbum(entry)
        case .playlist:
            try await PlaylistPlayer.play(entry)
        }
        logger.notice("play() requested OK")
    }

    /// 停止
    static func stop(_ entry: MediaEntry) async throws {
        logger.notice("stop() kind=\(entry.kind.rawValue, privacy: .public)")
        switch entry.kind {
        case .album:
            try await runTool("/usr/bin/osascript", ["-e", Self.stopMusicScript])
        case .playlist:
            PlaylistPlayer.stop()
        }
    }

    /// `is running` ガード付きの停止スクリプト。
    /// `tell application "Music"` 単体だと未起動のMusic.appを起動してしまうため、
    /// `is running`(起動せずに起動状態だけ調べられる)で囲む。
    private static let stopMusicScript = """
    if application "Music" is running then
        tell application "Music" to stop
    end if
    """

    /// Musicアプリの再生を止める(二重再生の防止用)
    static func stopMusicApp() async {
        _ = try? await runTool("/usr/bin/osascript", ["-e", Self.stopMusicScript])
    }

    /// Musicアプリの現在の再生状態 (isPlaying, 現在のアルバム名)。
    /// Music.appが起動していなければ起動せず (false, nil) を返す
    /// (PlaybackMonitor が2秒おきに呼ぶため、ガードがないとMusic.appを起動し続ける)。
    static func nowPlayingInfo() async -> (isPlaying: Bool, album: String?)? {
        let script = """
        if application "Music" is running then
            tell application "Music"
                set s to player state as text
                set a to ""
                try
                    set a to album of current track
                end try
                return s & "|" & a
            end tell
        else
            return "stopped|"
        end if
        """
        guard let out = try? await runTool("/usr/bin/osascript", ["-e", script], captureOutput: true) else {
            return nil
        }
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard parts.count >= 2 else { return nil }
        return (parts[0] == "playing", parts[1].isEmpty ? nil : parts[1])
    }

    // MARK: - アルバム(Musicアプリ + ショートカット)

    private static func playAlbum(_ entry: MediaEntry) async throws {
        // 本アプリ内プレイヤーが再生中なら先に止める(二重再生の防止。
        // PlaylistPlayer.play がMusicアプリを止めるのと対称)
        PlaylistPlayer.stop()

        // ショートカット名の解決には `shortcuts list` を使う
        // (一覧の取得はアプリプロセスからでも動作することを確認済み)
        let installed: [String]
        do {
            installed = try await listShortcutNames()
        } catch {
            throw PlaybackError.failed(String(localized: "Failed to list shortcuts: \(error.localizedDescription)"))
        }
        logger.notice("installed shortcuts: \(installed.joined(separator: " | "), privacy: .public)")

        guard let name = shortcutNameCandidates.first(where: { installed.contains($0) }) else {
            logger.error("no candidate name installed")
            throw PlaybackError.shortcutMissing(visible: installed)
        }

        // shortcuts://run-shortcut?name=<enc>&input=<enc>
        let encoded = "shortcuts://run-shortcut?name=\(percentEncoded(name))&input=\(percentEncoded(entry.url))"
        guard let target = URL(string: encoded) else {
            throw PlaybackError.failed(String(localized: "Failed to build the shortcut URL."))
        }
        logger.notice("opening \(encoded, privacy: .public)")

        // LaunchServices経由でShortcutsアプリに実行させる(/usr/bin/open)
        try await runTool("/usr/bin/open", [target.absoluteString])
    }

    static func listShortcutNames() async throws -> [String] {
        let output = try await runTool("/usr/bin/shortcuts", ["list"], captureOutput: true) ?? ""
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func percentEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }

    /// 子プロセスが応答しなくなった場合の打ち切り時間(秒)
    private static let toolTimeout: TimeInterval = 15

    /// terminate()を無視する子プロセスにSIGKILLを送るまでの猶予(秒)
    private static let killGracePeriod: TimeInterval = 2

    /// 外部プロセスを実行する。
    /// - 標準出力/標準エラーはプロセス終了を待たず別スレッドで排出する。
    ///   (terminationHandler 内だけで読むと、子が64KB超を出力した時点で
    ///   パイプバッファが満杯→子がwriteでブロック→終了しないデッドロックになる)
    /// - `toolTimeout` 秒で応答がなければ terminate して継続を解放する。
    @discardableResult
    private static func runTool(_ toolPath: String, _ arguments: [String], captureOutput: Bool = false) async throws -> String? {
        logger.notice("run \(toolPath, privacy: .public) \(arguments.joined(separator: " "), privacy: .public)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        /// 継続の多重resume防止と、排出スレッドからの結果受け取り用
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var stdout = Data()
            var stderr = Data()
            var resumed = false
        }

        return try await withCheckedThrowingContinuation { continuation in
            let state = State()
            @Sendable func resumeOnce(with result: Result<String?, Error>) {
                state.lock.lock()
                defer { state.lock.unlock() }
                guard !state.resumed else { return }
                state.resumed = true
                continuation.resume(with: result)
            }

            // 排出は run() 前から開始する(パイプデッドロック防止)
            let drained = DispatchGroup()
            drained.enter()
            DispatchQueue.global().async {
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                state.lock.lock(); state.stdout = data; state.lock.unlock()
                drained.leave()
            }
            drained.enter()
            DispatchQueue.global().async {
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                state.lock.lock(); state.stderr = data; state.lock.unlock()
                drained.leave()
            }

            process.terminationHandler = { proc in
                // EOFはプロセス終了直後に来るので、排出スレッドの完了を待ってから結果を読む
                drained.wait()
                let stdoutText = String(data: state.stdout, encoding: .utf8) ?? ""
                let stderrText = String(data: state.stderr, encoding: .utf8) ?? ""
                logger.notice("exit=\(proc.terminationStatus, privacy: .public) stdout='\(stdoutText, privacy: .public)' stderr='\(stderrText, privacy: .public)'")

                if proc.terminationReason == .exit && proc.terminationStatus == 0 {
                    resumeOnce(with: .success(captureOutput ? stdoutText : nil))
                } else {
                    resumeOnce(with: .failure(PlaybackError.failed(
                        (stdoutText + stderrText).isEmpty ? "exited \(proc.terminationStatus)" : (stdoutText + stderrText)
                    )))
                }
            }

            // タイムアウト: ハングした子プロセスを終了させ、継続を必ず一度だけ解放する
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.toolTimeout) {
                state.lock.lock(); let done = state.resumed; state.lock.unlock()
                guard !done else { return }
                logger.error("timeout(\(Self.toolTimeout, privacy: .public)s): terminating \(toolPath, privacy: .public)")
                process.terminate()
                // terminate()を無視する子へのエスカレーション。放置すると排出スレッドと
                // terminationHandler内のdrained.wait()が永久にリークする。
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGracePeriod) {
                    if process.isRunning {
                        logger.error("still running after terminate(); SIGKILL pid=\(process.processIdentifier, privacy: .public)")
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                resumeOnce(with: .failure(PlaybackError.failed(String(localized: "\(toolPath) timed out."))))
            }

            do {
                try process.run()
            } catch {
                logger.error("spawn failed: \(error.localizedDescription, privacy: .public)")
                // spawn失敗時は誰も書き込まないので書き込み端を閉じ、排出スレッドをEOFで抜けさせる
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                resumeOnce(with: .failure(error))
            }
        }
    }
}
