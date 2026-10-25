//
//  SettingsView.swift
//  Records
//
//  Created by Shuhei Matsuoka on 2026/10/18.
//

import SwiftUI
import os

/// 設定画面(シェルフの余白の右クリックメニューから開く)。
/// シェルフの表示設定のみ扱う。アルバム/プレイリストの追加は
/// シェルフへのドロップで行う。
/// 表示設定の編集対象は「最後にキーになったシェルフウィンドウ」
/// (ShelfManager.focusedStore)。言語だけはアプリ全体共通。
struct SettingsView: View {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    @ObservedObject private var manager = ShelfManager.shared
    /// 言語変更後の再起動促しアラート表示フラグ
    @State private var showRestartAlert = false

    /// 編集対象のシェルフ(最後にフォーカスしたウィンドウ)。
    /// まだ一度もシェルフがキーになっていなければnil
    private var store: ShelfStore? { manager.focusedStore }

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
                // この3つのピッカーはフォーカス中のシェルフにだけ効く。
                // 監視するのはstore側(manager.focusedStoreの参照変更だけでは
                // settingsの更新で再描画されないため)、サブビューに切り出して
                // @ObservedObjectで購読する
                if let store {
                    ShelfPickers(store: store)
                }
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

}

/// 列数/行数/アートワークサイズのピッカー群。
/// @ObservedObjectでstoreを購読するためにSettingsViewから切り出した
/// (SettingsViewが見るのはmanager.focusedStoreの参照だけなので、
///  settingsが変わっても再描画されずピッカー表示が古いままになる)
private struct ShelfPickers: View {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    @ObservedObject var store: ShelfStore

    var body: some View {
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

    private var columnsSelection: Binding<Int> {
        Binding(
            get: { store.settings.columns },
            set: { newValue in
                Self.logger.notice("settings: columns picker changed to \(newValue, privacy: .public) (shelf=\(self.store.shelfID, privacy: .public))")
                updateDisplaySettings(columns: newValue, rows: store.settings.rows)
            }
        )
    }

    private var rowsSelection: Binding<Int> {
        Binding(
            get: { store.settings.rows },
            set: { newValue in
                Self.logger.notice("settings: rows picker changed to \(newValue, privacy: .public) (shelf=\(self.store.shelfID, privacy: .public))")
                updateDisplaySettings(columns: store.settings.columns, rows: newValue)
            }
        )
    }

    private var artworkSizeSelection: Binding<ShelfSettings.ArtworkSize> {
        Binding(
            get: { store.settings.artworkSize },
            set: { newValue in
                Self.logger.notice("settings: artwork size picker changed to \(newValue.rawValue, privacy: .public) (shelf=\(self.store.shelfID, privacy: .public))")
                store.updateSettings(ShelfSettings(
                    columns: store.settings.columns,
                    rows: store.settings.rows,
                    artworkSize: newValue
                ))
            }
        )
    }

    /// 列数/行数の変更をフォーカス中のシェルフの設定に反映する。
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
