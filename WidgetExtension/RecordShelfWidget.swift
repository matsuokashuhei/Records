//
//  RecordShelfWidget.swift
//  RecordsWidget
//
//  Created by Shuhei Matsuoka on 2026/10/18.
//

import WidgetKit
import SwiftUI
import AppKit

// MARK: - データ

struct ShelfEntry: TimelineEntry {
    let date: Date
    let slots: [MediaEntry?]
    /// 設定(settings.json)のグリッド構成。読めない場合は5×4。
    let columns: Int
    let rows: Int
}

struct Provider: TimelineProvider {
    /// スロットとグリッド構成をディスクから読む。設定が無い/読めない場合は
    /// ShelfSettings.default(20枚=5×4)にフォールバックする。
    /// settings.jsonはここで1回だけ読み、その値をスロット生成にも渡す
    /// (二重読み込みだとatomic writeの隙間に容量とグリッド構成がずれうる)。
    private static func makeEntry() -> ShelfEntry {
        let settings = ShelfSettings.loadFromDisk()
        return ShelfEntry(
            date: .now,
            slots: ShelfStore.paddedSlotsFromDisk(capacity: settings.capacity.rawValue),
            columns: settings.capacity.columns,
            rows: settings.capacity.rows
        )
    }

    func placeholder(in context: Context) -> ShelfEntry {
        Self.makeEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (ShelfEntry) -> Void) {
        completion(Self.makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ShelfEntry>) -> Void) {
        // 内容はplaceholder/getSnapshotと同じく毎回ディスクから読む。
        // 共有インスタンスのメモリ値は拡張プロセスの寿命中そのままなので、
        // アプリ側の編集→reloadAllTimelines()後にstaleな内容を返しうる。
        let entry = Self.makeEntry()
        // 不足アートワークのダウンロード開始という従来の副作用は維持する。
        // (ShelfStoreは@MainActorのためTaskでホップ。fire-and-forgetでよい)
        Task { @MainActor in
            ShelfStore.shared.ensureArtworkDownloaded()
        }
        // 内容の更新はアプリ側の保存時に WidgetCenter からリロードされる
        completion(Timeline(entries: [entry], policy: .never))
    }
}

// MARK: - ウィジェット本体

struct RecordShelfWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RecordShelf", provider: Provider()) { entry in
            ShelfGridView(slots: entry.slots, columns: entry.columns, rows: entry.rows)
        }
        .configurationDisplayName("レコードシェルフ")
        .description("登録したアルバムを壁のレコードシェルフのように表示します。ジャケットをクリックするとMusicアプリで再生されます。")
        .supportedFamilies([.systemExtraLarge, .systemLarge])
    }
}

// MARK: - シェルフ表示

struct ShelfGridView: View {
    let slots: [MediaEntry?]
    /// 設定のグリッド構成。アートワークサイズ設定は適用しない
    /// (ウィジェットは自身のbounds内で自動サイズ調整のまま)。
    let columns: Int
    let rows: Int

    var body: some View {
        GeometryReader { geo in
            let padding: CGFloat = 16
            let gap: CGFloat = 10

            let availableWidth = geo.size.width - padding * 2 - gap * CGFloat(columns - 1)
            let availableHeight = geo.size.height - padding * 2 - gap * CGFloat(rows - 1)
            let cellSide = min(availableWidth / CGFloat(columns), (availableHeight - 10) / CGFloat(rows))

            VStack(spacing: gap) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<columns, id: \.self) { column in
                            let index = row * columns + column
                            // slotsが想定より短い場合に備えて安全に参照する
                            cell(slots.indices.contains(index) ? slots[index] : nil, size: cellSide)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(padding)
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.95, blue: 0.93),
                    Color(red: 0.88, green: 0.86, blue: 0.83),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    @ViewBuilder
    private func cell(_ entry: MediaEntry?, size: CGFloat) -> some View {
        if let entry {
            Button(intent: PlayAlbumIntent(entryID: entry.id)) {
                sleeveView(entry, size: size)
            }
            .buttonStyle(.plain)
            .help("\(entry.title) — \(entry.artist)")
        } else {
            emptySleeve(size: size)
        }
    }

    private func sleeveView(_ entry: MediaEntry, size: CGFloat) -> some View {
        VStack(spacing: 3) {
            Group {
                if let image = NSImage(contentsOfFile: ShelfStore.artworkFileURL(for: entry).path) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    ZStack {
                        Rectangle().fill(Color(white: 0.82))
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.3))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 2)

            // シェルフの透明なレール
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 1.0).opacity(0.95), Color(white: 0.76)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size * 1.14, height: 4.5)
                .shadow(color: .black.opacity(0.22), radius: 1.5, x: 0, y: 1)
        }
    }

    private func emptySleeve(size: CGFloat) -> some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.5).opacity(0.08))
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.25))
                    .foregroundStyle(Color(white: 0.5).opacity(0.3))
            }
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color(white: 0.5).opacity(0.25))
            )
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(white: 1.0).opacity(0.5))
                .frame(width: size * 1.14, height: 4.5)
        }
    }
}
