//
//  SettingsView.swift
//  Records
//
//  Created by Shuhei Matsuoka on 2026/10/18.
//

import SwiftUI
import os

/// 設定画面(Cmd+, で開く)。シェルフへのアルバム/プレイリスト追加はここで行う。
struct SettingsView: View {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    @ObservedObject private var store = ShelfStore.shared
    @State private var input = ""
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isBusy = false

    var body: some View {
        Form {
            Section("レコードシェルフ") {
                LabeledContent("登録数") {
                    // 登録総数と実際の表示数を分けて表示
                    // (capacity縮小で「15 / 6枚」のような表示になるのを防ぐ)
                    Text("登録 \(store.entries.count)件 / 表示 \(min(store.entries.count, store.capacity))枚")
                }
                Text("この並びがアプリのウィンドウに表示されます。ジャケットにマウスを乗せると再生/停止アイコンが表示され、クリックで切り替わります。右クリックのメニューから削除できます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("表示") {
                Picker("列数", selection: columnsSelection) {
                    ForEach(1...ShelfSettings.maxDimension, id: \.self) { n in
                        Text("\(n)列").tag(n)
                    }
                }
                Picker("行数", selection: rowsSelection) {
                    ForEach(1...ShelfSettings.maxDimension, id: \.self) { n in
                        Text("\(n)行").tag(n)
                    }
                }
                Picker("アートワークサイズ", selection: artworkSizeSelection) {
                    ForEach(ShelfSettings.ArtworkSize.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                Text("表示枚数(列数×行数)を減らしても登録済みのアルバムは削除されません。先頭から表示枚数分だけが表示されます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("アルバム・プレイリストを追加") {
                TextField(
                    "https://music.apple.com/jp/album/… または /playlist/… のURL、もしくはアルバムID",
                    text: $input
                )
                .onSubmit(addFromInput)

                HStack {
                    Spacer()
                    Button {
                        Self.logger.notice("settings: add button tapped")
                        addFromInput()
                    } label: {
                        if isBusy {
                            ProgressView().controlSize(.small).frame(width: 44)
                        } else {
                            Text("追加").frame(width: 44)
                        }
                    }
                    .disabled(isBusy || input.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("再生について") {
                Text("アルバムはMusicアプリのカタログから、プレイリストは本アプリ内プレイヤーから直接再生されます(ライブラリ追加なし)。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(8)
        .onAppear {
            Self.logger.notice("settings window shown")
        }
    }

    // MARK: - 表示設定

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

    // MARK: - アクション

    private func addFromInput() {
        // TextFieldのonSubmitはdisabledにならないので、処理中の再入はここで弾く
        guard !isBusy else { return }
        let text = input
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isBusy = true
        statusMessage = nil

        Task { @MainActor in
            defer { isBusy = false }
            do {
                guard let parsed = MediaURLParser.parse(text) else {
                    Self.logger.error("add: parse failed for '\(text, privacy: .public)'")
                    throw MediaCatalogClient.CatalogError.invalidInput
                }
                Self.logger.notice("add: parsed kind=\(parsed.kind.rawValue, privacy: .public) id=\(parsed.id, privacy: .public)")
                // 追加パイプライン(重複チェック→fetch→アートワーク→add)は
                // シェルフへのドロップと共通のstore.addFromCatalogを使う
                switch try await store.addFromCatalog(parsed) {
                case .added(let entry):
                    Self.logger.notice("add: added '\(entry.title, privacy: .public)'")
                    statusIsError = false
                    statusMessage = "追加しました: \(entry.title) — \(entry.artist)"
                    input = ""
                case .duplicate:
                    statusIsError = true
                    statusMessage = "この\(parsed.kind == .album ? "アルバム" : "プレイリスト")はすでに登録されています。"
                case .full:
                    statusIsError = true
                    statusMessage = "登録できるのは\(store.capacity)枚までです。"
                }
            } catch {
                Self.logger.error("add: \(error.localizedDescription, privacy: .public)")
                statusIsError = true
                statusMessage = error.localizedDescription
            }
        }
    }
}
