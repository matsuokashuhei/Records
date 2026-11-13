import Foundation
import AppKit
import os

/// 再生用ショートカットの存在確認とインストール。
///
/// アルバム再生は shortcuts://run-shortcut 経由でユーザー側の
/// ショートカット(「Sleeves Playback」。Playアクションのパラメータに
/// Shortcut Input)を呼ぶため、ショートカットが無いとアルバムは鳴らない。
/// OSにショートカットをサイレント作成するAPIは無いので、
/// 「無い」ことを検知したらバンドル同梱の署名済み .shortcut ファイルを
/// 開き、Shortcutsアプリのインポート画面でユーザーに追加してもらう。
/// (インポート画面の「Add Shortcut」クリックは必ずユーザー操作が必要)
///
/// 同梱ファイルはShortcutsアプリの File > Export(For: Anyone)で作った
/// 署名+iCloud検証済みのもの。中身にショートカット名は含まれず、
/// インポート時の名前はファイル名から取られるため、リソース名を
/// 「Sleeves Playback.shortcut」にしている(2026-11-08 実機検証)。
@MainActor
final class ShortcutInstaller: ObservableObject {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Sleeves", category: "Shortcut")

    static let shared = ShortcutInstaller()

    /// インストール案内の要求回数。アラートは「要求があった時点で
    /// キーになっているウィンドウ」だけが出す(ShelfViewのonChangeで
    /// 値が変わるたびに各窓が自分のkey状態を見て、keyの窓だけが提示)。
    /// Boolではなくカウンタにするのは、連続要求でも必ずonChangeが
    /// 発火するため
    @Published var installRequest = 0

    private init() {}

    /// バンドルに同梱している .shortcut リソース名。
    /// インポートされるショートカット名はこのベース名になる
    private static let bundledName = "Sleeves Playback"

    /// 起動時チェック。未インストールならアラートを出す
    func checkAtLaunch() async {
        let installed: [String]
        do {
            installed = try await PlaybackEngine.listShortcutNames()
        } catch {
            // 一覧取得自体の失敗(TCC拒否・タイムアウト等)は「不明」扱い。
            // 実際にはインストール済みの可能性があるため誤検知アラートは出さない
            Self.logger.error("shortcut check: list failed: \(error.localizedDescription, privacy: .public); skipping prompt")
            return
        }
        Self.logger.notice("shortcut check: installed=\(installed.joined(separator: " | "), privacy: .public)")
        guard !PlaybackEngine.shortcutNameCandidates.contains(where: { installed.contains($0) }) else {
            return
        }
        Self.logger.notice("playback shortcut not installed; prompting")
        installRequest += 1
    }

    /// 再生失敗(shortcutMissing)からの呼び出し。未インストールを
    /// 再確認せず即アラートを出す(play側が直前に一覧を確認済みなので
    /// 二重確認は避ける)
    func promptForMissing() {
        Self.logger.notice("playback failed: shortcut missing; prompting")
        installRequest += 1
    }

    /// 同梱の .shortcut を開いてShortcutsアプリのインポート画面を出す。
    /// バンドルリソースを直接開くと複数シェルフ/再実行で同一ファイルを
    /// 使い回すため、一旦tmpにコピーしてから開く
    func install() async throws {
        guard let src = Bundle.main.url(forResource: Self.bundledName, withExtension: "shortcut") else {
            Self.logger.error("bundled shortcut resource not found: \(Self.bundledName, privacy: .public).shortcut")
            throw PlaybackEngine.PlaybackError.failed(String(localized: "Bundled shortcut file not found."))
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.bundledName).shortcut")
        try? FileManager.default.removeItem(at: tmp)
        do {
            try FileManager.default.copyItem(at: src, to: tmp)
        } catch {
            Self.logger.error("copy to tmp failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        Self.logger.notice("opening bundled shortcut for import: \(tmp.path, privacy: .public)")
        // LaunchServices経由でShortcutsアプリに開かせる(/usr/bin/open)
        try await PlaybackEngine.runTool("/usr/bin/open", [tmp.path])
    }
}
