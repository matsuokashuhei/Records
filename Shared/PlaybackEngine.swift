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
                    ? "(shortcutsコマンドからショートカットが1つも見えません)"
                    : "見つかったショートカット: \(visible.joined(separator: ", "))"
                return "再生用ショートカット(\(shortcutNameCandidates.joined(separator: " / ")))が見つかりません。\n\(names)"
            case .failed(let detail):
                return "再生に失敗しました: \(detail)"
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

    /// 登録リストのIDから再生
    static func play(entryID: String) async throws {
        guard let entry = ShelfStore.shared.entries.first(where: { $0.id == entryID }) else {
            throw PlaybackError.failed("登録済みリストに見つかりません: \(entryID)")
        }
        try await play(entry)
    }

    /// 停止
    static func stop(_ entry: MediaEntry) async throws {
        logger.notice("stop() kind=\(entry.kind.rawValue, privacy: .public)")
        switch entry.kind {
        case .album:
            try await runTool("/usr/bin/osascript", ["-e", "tell application \"Music\" to stop"])
        case .playlist:
            PlaylistPlayer.stop()
        }
    }

    /// Musicアプリの再生を止める(二重再生の防止用)
    static func stopMusicApp() async {
        _ = try? await runTool("/usr/bin/osascript", ["-e", "tell application \"Music\" to stop"])
    }

    /// Musicアプリの現在の再生状態 (isPlaying, 現在のアルバム名)
    static func nowPlayingInfo() async -> (isPlaying: Bool, album: String?)? {
        let script = """
        tell application "Music"
            set s to player state as text
            set a to ""
            try
                set a to album of current track
            end try
            return s & "|" & a
        end tell
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
        // ショートカット名の解決には `shortcuts list` を使う
        // (一覧の取得はアプリプロセスからでも動作することを確認済み)
        let installed: [String]
        do {
            installed = try await listShortcutNames()
        } catch {
            throw PlaybackError.failed("ショートカット一覧の取得に失敗: \(error.localizedDescription)")
        }
        logger.notice("installed shortcuts: \(installed.joined(separator: " | "), privacy: .public)")

        guard let name = shortcutNameCandidates.first(where: { installed.contains($0) }) else {
            logger.error("no candidate name installed")
            throw PlaybackError.shortcutMissing(visible: installed)
        }

        // shortcuts://run-shortcut?name=<enc>&input=<enc>
        let encoded = "shortcuts://run-shortcut?name=\(percentEncoded(name))&input=\(percentEncoded(entry.url))"
        guard let target = URL(string: encoded) else {
            throw PlaybackError.failed("ショートカットURLの生成に失敗しました")
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

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let stdoutText = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderrText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                logger.notice("exit=\(proc.terminationStatus, privacy: .public) stdout='\(stdoutText, privacy: .public)' stderr='\(stderrText, privacy: .public)'")

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: captureOutput ? stdoutText : nil)
                } else {
                    continuation.resume(throwing: PlaybackError.failed(
                        (stdoutText + stderrText).isEmpty ? "exited \(proc.terminationStatus)" : (stdoutText + stderrText)
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                logger.error("spawn failed: \(error.localizedDescription, privacy: .public)")
                continuation.resume(throwing: error)
            }
        }
    }
}
