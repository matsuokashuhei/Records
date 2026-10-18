//
//  RegistrationView.swift
//  Records
//
//  Created by Shuhei Matsuoka on 2026/10/18.
//

import SwiftUI
import AppKit
import os

/// ウィジェットに並べるアルバム20枚を管理する画面。
/// Apple MusicのURLまたはIDをペーストして登録する。
struct RegistrationView: View {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    @ObservedObject private var store = ShelfStore.shared
    @State private var input = ""
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            addForm
            shelfGrid
            footer
        }
        .padding(24)
        // 再生状態はAlbumSlotViewが個別にmonitorを監視するので、ここでは監視せず
        // 開始/停止だけ行う(画面全体の2秒おき再描画を避ける)
        .onAppear { PlaybackMonitor.shared.start() }
        .onDisappear { PlaybackMonitor.shared.stopPolling() }
    }

    // MARK: - パーツ

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("レコードシェルフ")
                .font(.title.bold())
            Text("登録 \(store.entries.count) / \(ShelfStore.capacity)枚")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text("デスクトップのウィジェットにこの並びが表示されます")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(
                    "https://music.apple.com/jp/album/… または /playlist/… のURL、もしくはアルバムID",
                    text: $input
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit(addFromInput)

                Button {
                    addFromInput()
                } label: {
                    if isBusy {
                        ProgressView().controlSize(.small).frame(width: 44)
                    } else {
                        Text("追加").frame(width: 44)
                    }
                }
                .disabled(isBusy || input.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var shelfGrid: some View {
        let slots = store.paddedSlots()
        let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 5)

        return ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, entry in
                    if let entry {
                        AlbumSlotView(entry: entry) { message in
                            statusIsError = true
                            statusMessage = message
                        }
                    } else {
                        emptySlot
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var emptySlot: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .aspectRatio(1, contentMode: .fit)
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(Color.secondary.opacity(0.4))
            }
            Text("空きスロット")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        Text("ジャケットにマウスを乗せると再生/停止アイコンが表示され、クリックで切り替わります。アルバムはMusicアプリのカタログから、プレイリストは本アプリ内プレイヤーから直接再生されます(ライブラリ追加なし)。")
            .font(.footnote)
            .foregroundStyle(.secondary)
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
                if store.contains(parsed.id) {
                    statusIsError = true
                    statusMessage = "この\(parsed.kind == .album ? "アルバム" : "プレイリスト")はすでに登録されています。"
                    return
                }
                let entry = try await MediaCatalogClient.fetch(parsed)
                Self.logger.notice("add: fetched title=\(entry.title, privacy: .public)")
                _ = try await ShelfStore.downloadArtwork(for: entry)
                Self.logger.notice("add: artwork downloaded")
                if store.add(entry) {
                    statusIsError = false
                    statusMessage = "追加しました: \(entry.title) — \(entry.artist)"
                    input = ""
                } else {
                    statusIsError = true
                    statusMessage = "登録できるのは\(ShelfStore.capacity)枚までです。"
                }
            } catch {
                Self.logger.error("add: \(error.localizedDescription, privacy: .public)")
                statusIsError = true
                statusMessage = error.localizedDescription
            }
        }
    }
}

/// シェルフの1枚分。ホバーで再生/停止アイコンを表示する。
private struct AlbumSlotView: View {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    let entry: MediaEntry
    var onPlaybackError: (String) -> Void

    /// artworkRevision(ダウンロード完了)の検知用
    @ObservedObject private var store = ShelfStore.shared
    @ObservedObject private var monitor = PlaybackMonitor.shared
    @State private var isHovered = false
    /// キャッシュ済みジャケット(bodyのたびに同期ディスク読み込みしない)
    @State private var artwork: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image = artwork {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
                        ProgressView()
                    }
                    .aspectRatio(1, contentMode: .fit)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            .overlay {
                if isHovered {
                    ZStack {
                        Circle()
                            .fill(.black.opacity(0.55))
                            .frame(width: 44, height: 44)
                        Image(systemName: monitor.isCurrent(entry) ? "stop.fill" : "play.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                    .transition(.opacity)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 4))
            .onHover { hovered in
                isHovered = hovered
            }
            .onTapGesture {
                Task {
                    do {
                        try await monitor.toggle(entry)
                    } catch {
                        Self.logger.error("playback failed for '\(entry.title, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                        onPlaybackError(error.localizedDescription)
                    }
                }
            }

            VStack(spacing: 1) {
                Text(entry.title)
                    .font(.caption)
                    .lineLimit(1)
                Text(entry.artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        // ジャケットはバックグラウンド読み込み+キャッシュ。ダウンロード完了
        // (artworkRevisionの増加)で未ロード分を再試行する。
        .task(id: "\(entry.id)#\(store.artworkRevision)") {
            artwork = await ShelfStore.artworkImage(for: entry)
        }
    }
}
