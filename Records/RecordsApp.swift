//
//  RecordsApp.swift
//  Records
//
//  Created by Shuhei Matsuoka on 2026/10/18.
//

import SwiftUI
import os

@main
struct RecordsApp: App {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    init() {
        // デバッグ: `--catalog-test <url>` で起動するとUIを出さずに
        // MediaCatalogClient.fetch を実行して結果をログに出す。
        // MusicKit(App Service)の有効性をCLIから検証するための経路。
        if let url = Self.catalogTestArgument() {
            let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "CatalogTest")
            logger.notice("catalog-test start url=\(url, privacy: .public)")
            let shouldPlay = ProcessInfo.processInfo.arguments.contains("--play")
            Task {
                defer { exit(0) }
                guard let parsed = MediaURLParser.parse(url) else {
                    logger.error("catalog-test: parse failed")
                    return
                }
                do {
                    let entry = try await MediaCatalogClient.fetch(parsed)
                    logger.notice("catalog-test OK: \(entry.kind.rawValue, privacy: .public) \(entry.title, privacy: .public) / \(entry.artist, privacy: .public) artwork=\(entry.artworkURL, privacy: .public)")
                    // `--play` も付いていたら再生まで試す(ApplicationMusicPlayerの検証用)
                    if shouldPlay {
                        try await PlaybackEngine.play(entry)
                        logger.notice("catalog-test play() OK, observing for 10s")
                        try await Task.sleep(nanoseconds: 10_000_000_000)
                    }
                } catch {
                    logger.error("catalog-test FAILED: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private static func catalogTestArgument() -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--catalog-test"), args.indices.contains(i + 1) else {
            return nil
        }
        return args[i + 1]
    }

    var body: some Scene {
        // 1シェルフ=1ウィンドウ。ウィンドウの値(シェルフID)でShelfStoreを
        // 引き当てる。起動時にシステムが作る値を持たないウィンドウは
        // プライマリシェルフになり、残りのシェルフのウィンドウを
        // 開き直す役目も担う(ShelfView.onAppear)。
        // ウィンドウサイズはShelfViewが設定(枚数・アートワークサイズ)から
        // 計算した固定フレームで決まる。contentSizeでmin=max扱い。
        WindowGroup(id: "shelf", for: String.self) { $shelfID in
            ShelfView(shelfID: $shelfID)
        }
        // 起動時に必ず1枚作る。復元された補助ウィンドウ(設定画面など)
        // だけが残った状態で起動すると、既定の.automaticでは
        // WindowGroupのウィンドウが作られないことがあるため
        .defaultLaunchBehavior(.presented)
        // ウィンドウ復元は自前で行う(shelves.jsonの全シェルフを
        // ShelfView側で開き直す)。macOS側の復元に任せると、
        // シェルフを閉じた状態で終了した場合に復元されない
        // (「閉じてもシェルフは残る」が崩れる)のと、
        // 自前オープンとの二重化が起きうるため無効化する
        .restorationBehavior(.disabled)
        // タイトルバーをネイティブに隠す。styleMaskの手動変更だけだと
        // contentLayoutRectがタイトルバー帯を含まず、帯の下端に
        // セパレータ線が残る(macOS 26実測)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            // 標準の"New Window"(⌘N)を置き換えて ⇧⌘N で新シェルフを開く
            CommandGroup(replacing: .newItem) {
                // コマンドにはopenWindow環境が無いので、ShelfViewが
                // managerに退避したopenShelfWindow経由で開く
                Button("New Shelf") {
                    let manager = ShelfManager.shared
                    let id = manager.createShelf()
                    if let openShelfWindow = manager.openShelfWindow {
                        openShelfWindow(id)
                    } else {
                        Self.logger.error("New Shelf: openShelfWindow action not installed")
                    }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }

        // 設定画面。シェルフ右上のツールバー(3点リーダー)→「Settings…」から開く
        // (SettingsシーンのCmd+,は廃止)。編集対象は最後にキーになった
        // シェルフのストア(ShelfManager.focusedStore)。
        Window("Settings", id: "settings") {
            SettingsView()
        }
        // 設定画面が単独で復元されると、WindowGroupの初期ウィンドウが
        // 作られない「部分復元」状態になることがあるため復元しない
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)
    }
}
