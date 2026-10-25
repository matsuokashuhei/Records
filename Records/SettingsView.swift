//
//  SettingsView.swift
//  Records
//
//  Created by Shuhei Matsuoka on 2026/10/18.
//

import SwiftUI
import os

/// 設定画面(Cmd+, で開く)。シェルフの表示設定のみ扱う。
/// アルバム/プレイリストの追加はシェルフへのドロップで行う。
struct SettingsView: View {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    @ObservedObject private var store = ShelfStore.shared
    /// 言語変更後の再起動促しアラート表示フラグ
    @State private var showRestartAlert = false

    /// 言語選択肢のタグ値。"system"はOS設定に従う(AppleLanguages未設定)
    private static let languageCodes = ["en", "ja", "es", "zh-Hans", "ko", "fr", "de"]

    var body: some View {
        Form {
            Section("Display") {
                Picker("Language", selection: languageSelection) {
                    Text("System").tag("system")
                    ForEach(Self.languageCodes, id: \.self) { code in
                        Text(languageName(for: code)).tag(code)
                    }
                }
                Picker("Columns", selection: columnsSelection) {
                    ForEach(1...ShelfSettings.maxDimension, id: \.self) { n in
                        Text("\(n) columns").tag(n)
                    }
                }
                Picker("Rows", selection: rowsSelection) {
                    ForEach(1...ShelfSettings.maxDimension, id: \.self) { n in
                        Text("\(n) rows").tag(n)
                    }
                }
                Picker("Artwork Size", selection: artworkSizeSelection) {
                    ForEach(ShelfSettings.ArtworkSize.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(8)
        .onAppear {
            Self.logger.notice("settings window shown")
        }
        .alert(
            "Restart Required",
            isPresented: $showRestartAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The new language will take effect after you restart Records.")
        }
    }

    // MARK: - 表示設定

    /// 言語名をその言語自体で表示する(autonym。英語なら"English")
    private func languageName(for code: String) -> String {
        Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
    }

    /// AppleLanguagesに言語コードを書き込んでアプリの表示言語を切り替える。
    /// "system"選択時はキーごと消してOS設定に戻す。反映は次回起動から。
    private var languageSelection: Binding<String> {
        Binding(
            get: {
                // standard.stringArrayはNSGlobalDomainまでフォールバックして
                // OSの言語一覧を拾ってしまう(未設定なのにピッカーが空選択になる)。
                // アプリ固有ドメインだけ読む
                let domain = UserDefaults.standard.persistentDomain(
                    forName: Bundle.main.bundleIdentifier ?? "com.cacheandbuffer.Records"
                )
                return (domain?["AppleLanguages"] as? [String])?.first ?? "system"
            },
            set: { newValue in
                Self.logger.notice("settings: language picker changed to \(newValue, privacy: .public)")
                if newValue == "system" {
                    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                } else {
                    UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                }
                showRestartAlert = true
            }
        )
    }

    private var columnsSelection: Binding<Int> {
        Binding(
            get: { store.settings.columns },
            set: { newValue in
                Self.logger.notice("settings: columns picker changed to \(newValue, privacy: .public)")
                updateDisplaySettings(columns: newValue, rows: store.settings.rows)
            }
        )
    }

    private var rowsSelection: Binding<Int> {
        Binding(
            get: { store.settings.rows },
            set: { newValue in
                Self.logger.notice("settings: rows picker changed to \(newValue, privacy: .public)")
                updateDisplaySettings(columns: store.settings.columns, rows: newValue)
            }
        )
    }

    private var artworkSizeSelection: Binding<ShelfSettings.ArtworkSize> {
        Binding(
            get: { store.settings.artworkSize },
            set: { newValue in
                Self.logger.notice("settings: artwork size picker changed to \(newValue.rawValue, privacy: .public)")
                store.updateSettings(ShelfSettings(
                    columns: store.settings.columns,
                    rows: store.settings.rows,
                    artworkSize: newValue
                ))
            }
        )
    }

    /// 列数/行数の変更を設定に反映する。
    /// 縮小で非表示になった再生中プレイリストは停止UIが消えるためここで止める。
    private func updateDisplaySettings(columns: Int, rows: Int) {
        store.updateSettings(ShelfSettings(
            columns: columns,
            rows: rows,
            artworkSize: store.settings.artworkSize
        ))
        PlaybackMonitor.shared.stopIfActiveEntryHidden()
    }
}
