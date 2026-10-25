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
        // ウィンドウサイズはShelfViewが設定(枚数・アートワークサイズ)から
        // 計算した固定フレームで決まる。contentSizeでmin=max扱い。
        WindowGroup {
            ShelfView()
        }
        .windowResizability(.contentSize)

        // Cmd+, で開く設定画面。シェルフの表示設定のみ扱う。
        Settings {
            SettingsView()
        }
    }
}
