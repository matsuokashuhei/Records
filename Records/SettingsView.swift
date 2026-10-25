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

    var body: some View {
        Form {
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
}
