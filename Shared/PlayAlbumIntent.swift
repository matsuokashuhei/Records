import AppIntents
import AppKit
import os

/// ウィジェットのジャケットをクリックしたときに走るインテント。
/// openAppWhenRun により perform() はアプリプロセスで実行され、
/// 再生後、設定ウィンドウを隠す。
struct PlayAlbumIntent: AppIntent {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "Intent")

    static let title: LocalizedStringResource = "再生"
    static let openAppWhenRun = true

    @Parameter(title: "エントリID")
    var entryID: String

    init() {}

    init(entryID: String) {
        self.entryID = entryID
    }

    func perform() async throws -> some IntentResult {
        Self.logger.notice("perform() entryID=\(entryID, privacy: .public)")
        do {
            try await PlaybackEngine.play(entryID: entryID)
            Self.logger.notice("perform() playback requested, hiding app")
            await MainActor.run {
                NSApp.hide(nil)
            }
            return .result()
        } catch {
            Self.logger.error("perform() failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
