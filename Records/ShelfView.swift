//
//  ShelfView.swift
//  Records
//
//  Created by Shuhei Matsuoka on 2026/10/18.
//

import SwiftUI
import AppKit
import os

/// メインウィンドウ。アルバムのジャケットだけをグリッド表示する。
/// ホバーで再生/停止オーバーレイ、タップで再生/停止。
/// 登録フォームは設定画面(SettingsView、Cmd+,)に移動した。
struct ShelfView: View {

    @ObservedObject private var store = ShelfStore.shared

    var body: some View {
        shelfGrid
            .background {
                // ignoresSafeAreaでタイトルバー帯の下までガラスを伸ばす
                GlassBackgroundView()
                    .ignoresSafeArea()
                WindowConfigurator()
            }
        // 再生状態はAlbumSlotViewが個別にmonitorを監視するので、ここでは監視せず
        // 開始/停止だけ行う(画面全体の2秒おき再描画を避ける)
            .onAppear { PlaybackMonitor.shared.start() }
            .onDisappear { PlaybackMonitor.shared.stopPolling() }
    }

    // グリッドの間隔・余白。ウィンドウサイズはこれらと設定値から厳密に計算する。
    private static let columnSpacing: CGFloat = 12
    private static let rowSpacing: CGFloat = 14
    private static let sidePadding: CGFloat = 18
    // タイトルバー非表示+fullSizeContentViewで信号ボタンが
    // コンテンツ上に浮くため、上だけ広めに取って1段目を避ける
    private static let topPadding: CGFloat = 34
    private static let bottomPadding: CGFloat = 18

    private var shelfGrid: some View {
        let settings = store.settings
        let cell = settings.artworkSize.points
        let columnCount = settings.capacity.columns
        let rowCount = settings.capacity.rows
        let slots = store.paddedSlots()
        let columns = Array(
            repeating: GridItem(.fixed(cell), spacing: Self.columnSpacing),
            count: columnCount
        )
        let width = CGFloat(columnCount) * cell
            + CGFloat(columnCount - 1) * Self.columnSpacing
            + Self.sidePadding * 2
        let height = CGFloat(rowCount) * cell
            + CGFloat(rowCount - 1) * Self.rowSpacing
            + Self.topPadding + Self.bottomPadding

        // ウィンドウはwindowResizability(.contentSize)なので、
        // この固定フレームがそのままmin=maxのウィンドウサイズになる。
        // 設定変更でstore.settingsが変わると自動的に追従する。
        return LazyVGrid(columns: columns, spacing: Self.rowSpacing) {
            ForEach(Array(slots.enumerated()), id: \.offset) { _, entry in
                Group {
                    if let entry {
                        AlbumSlotView(entry: entry)
                    } else {
                        emptySlot
                    }
                }
                .frame(width: cell, height: cell)
            }
        }
        .padding(EdgeInsets(
            top: Self.topPadding,
            leading: Self.sidePadding,
            bottom: Self.bottomPadding,
            trailing: Self.sidePadding
        ))
        .frame(width: width, height: height)
    }

    private var emptySlot: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(Color.secondary.opacity(0.4))
                .aspectRatio(1, contentMode: .fit)
            Image(systemName: "music.note")
                .font(.title3)
                .foregroundStyle(Color.secondary.opacity(0.4))
        }
    }
}

/// シェルフの1枚分。ホバーで再生/停止アイコンを表示する。
private struct AlbumSlotView: View {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    let entry: MediaEntry

    /// artworkRevision(ダウンロード完了)の検知用
    @ObservedObject private var store = ShelfStore.shared
    @ObservedObject private var monitor = PlaybackMonitor.shared
    @State private var isHovered = false
    /// キャッシュ済みジャケット(bodyのたびに同期ディスク読み込みしない)
    @State private var artwork: NSImage?

    var body: some View {
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
                }
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
