//
//  RecordShelfWidget.swift
//  RecordsWidget
//
//  Created by Shuhei Matsuoka on 2026/10/18.
//

import WidgetKit
import SwiftUI
import AppKit
import os

// MARK: - データ

struct ShelfEntry: TimelineEntry {
    let date: Date
    let slots: [MediaEntry?]
    /// 設定(settings.json)のグリッド構成。読めない場合は5×4。
    let columns: Int
    let rows: Int
}

struct Provider: AppIntentTimelineProvider {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "Widget")

    /// インテントで選択された容量を解決する。
    /// 「アプリ設定に従う」(.appDefault)のときだけsettings.jsonを読み、
    /// 明示選択時はその容量を使う。読めない場合はShelfSettings.default(20枚)に
    /// フォールバックする。
    private static func resolveCapacity(for configuration: RecordShelfConfigurationIntent) -> ShelfSettings.Capacity {
        if let capacity = configuration.capacity.shelfCapacity {
            return capacity
        }
        return ShelfSettings.loadFromDisk().capacity
    }

    /// スロットとグリッド構成をディスクから読む。
    /// 容量は呼び出し側で1回だけ決めて渡し、スロット生成とグリッド構成の
    /// 両方に使う(二重読み込みだとatomic writeの隙間にずれうる)。
    private static func makeEntry(capacity: ShelfSettings.Capacity) -> ShelfEntry {
        ShelfEntry(
            date: .now,
            slots: ShelfStore.paddedSlotsFromDisk(capacity: capacity.rawValue),
            columns: capacity.columns,
            rows: capacity.rows
        )
    }

    func placeholder(in context: Context) -> ShelfEntry {
        // プレースホルダは設定未確定なのでアプリ設定(なければ既定20枚)で描く
        Self.makeEntry(capacity: ShelfSettings.loadFromDisk().capacity)
    }

    func snapshot(for configuration: RecordShelfConfigurationIntent, in context: Context) async -> ShelfEntry {
        Self.makeEntry(capacity: Self.resolveCapacity(for: configuration))
    }

    func timeline(for configuration: RecordShelfConfigurationIntent, in context: Context) async -> Timeline<ShelfEntry> {
        // 内容はplaceholder/snapshotと同じく毎回ディスクから読む。
        // 共有インスタンスのメモリ値は拡張プロセスの寿命中そのままなので、
        // アプリ側の編集→reloadAllTimelines()後にstaleな内容を返しうる。
        let capacity = Self.resolveCapacity(for: configuration)
        Self.logger.notice("timeline: capacity=\(capacity.rawValue, privacy: .public) (option=\(configuration.capacity.rawValue, privacy: .public))")
        let entry = Self.makeEntry(capacity: capacity)
        // 不足アートワークのダウンロード開始という従来の副作用は維持する。
        // (ShelfStoreは@MainActorのためTaskでホップ。fire-and-forgetでよい)
        Task { @MainActor in
            ShelfStore.shared.ensureArtworkDownloaded()
        }
        // 内容の更新はアプリ側の保存時に WidgetCenter からリロードされる。
        // インテント設定の変更時はシステムがこのメソッドを自動で呼び直す。
        return Timeline(entries: [entry], policy: .never)
    }
}

// MARK: - ウィジェット本体

struct RecordShelfWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "RecordShelf", intent: RecordShelfConfigurationIntent.self, provider: Provider()) { entry in
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
            let cellSide = min(availableWidth / CGFloat(columns), availableHeight / CGFloat(rows))

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
        // アプリ本体はNSGlassEffectView(壁紙が透けるリキッドグラス)を敷いている。
        // ウィジェットではマテリアルが最も近い見た目になる。不透明な色塗りにしない。
        .containerBackground(.regularMaterial, for: .widget)
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

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "Widget")

    private func sleeveView(_ entry: MediaEntry, size: CGFloat) -> some View {
        // アプリ側のAlbumSlotViewと同じ見た目: ジャケット画像のみ(レール無し)、
        // 角丸4 + 薄い影。未読込時は薄いグレーのプレースホルダのみ
        // (ウィジェットは非同期で再描画されるのでProgressViewは不要)。
        // sandboxed拡張では NSImage(contentsOfFile:) がコンテナ外のファイルを
        // 読めないため、実績のあるData読み込み経路(temporary-exception対象)で
        // バイト列を取り、メモリ上でデコードする。
        let artworkURL = ShelfStore.artworkFileURL(for: entry)
        let image = (try? Data(contentsOf: artworkURL)).flatMap { NSImage(data: $0) }
        if let image {
            Self.logger.debug("artwork loaded id=\(entry.id, privacy: .public) size=\(image.size.width, privacy: .public)x\(image.size.height, privacy: .public)")
            // widgetAccentedRenderingMode はImage型専用でresizable等と
            // 併用できないため、表示サイズはNSImage.sizeで直接指定する。
            image.size = NSSize(width: size, height: size)
        } else {
            Self.logger.notice("artwork load failed id=\(entry.id, privacy: .public) path=\(artworkURL.path, privacy: .public) exists=\(FileManager.default.fileExists(atPath: artworkURL.path), privacy: .public)")
        }
        return Group {
            if let image {
                // 非アクティブ時の減退(accented)描画でもジャケットをフルカラーで
                // 維持する(Apple公式: アルバムアート等のメディア画像向け)。
                Image(nsImage: image)
                    .widgetAccentedRenderingMode(.fullColor)
            } else {
                // 未読込はグレーの下地だけ残す
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 2)
    }

    private func emptySleeve(size: CGFloat) -> some View {
        // 空きスロットは何も描かず、正方形セルとしてスペースだけ確保する
        Color.clear
            .frame(width: size, height: size)
    }
}
