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
/// ホバーで再生/停止オーバーレイ、タップで再生/停止、右クリックで削除。
/// 登録フォームは設定画面(SettingsView、Cmd+,)に移動した。
struct ShelfView: View {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    @ObservedObject private var store = ShelfStore.shared
    /// 削除確認ダイアログに出している対象。非nilの間ダイアログを表示する。
    @State private var pendingDelete: MediaEntry?
    /// ドロップで実際に順番が変わる位置にカーソルが乗っているスロット
    /// (半透明表示用。ドロップゾーンのisTargetedがセット/クリアする)
    @State private var dropTargetSlotID: String?
    /// 現在ドラッグ中のエントリ。onDragの開始コールバックでセットし、
    /// 「ドロップで順番が変わるか」の判定とアプリ内ドラッグの判別に使う
    /// (キャンセル時は次のドラッグ開始まで残るが、参照されるのはドラッグ中のみ)
    @State private var draggedID: String?

    var body: some View {
        shelfGrid
            .background {
                // ignoresSafeAreaでタイトルバー帯の下までガラスを伸ばす
                GlassBackgroundView()
                    .ignoresSafeArea()
            }
        // 右クリックメニュー選択後の確認。「Remove "<name>"?」+ Delete Record/Cancel。
            .alert(
                "Remove “\(pendingDelete?.title ?? "")”?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { entry in
                Button("Delete Record", role: .destructive) { delete(entry) }
                Button("Cancel", role: .cancel) {
                    Self.logger.notice("delete cancelled for '\(entry.title, privacy: .public)'")
                }
            }
        // 再生状態はAlbumSlotViewが個別にmonitorを監視するので、ここでは監視せず
        // 開始/停止だけ行う(画面全体の2秒おき再描画を避ける)
            .onAppear { PlaybackMonitor.shared.start() }
            .onDisappear { PlaybackMonitor.shared.stopPolling() }
    }

    /// 確認済みの削除。storeから外し、アプリ内再生中のプレイリストなら止める
    /// (削除でスロットが非表示になると停止UIが無くなるため)。
    private func delete(_ entry: MediaEntry) {
        Self.logger.notice("record deleted: '\(entry.title, privacy: .public)' id=\(entry.id, privacy: .public)")
        store.remove(entry.id)
        PlaybackMonitor.shared.stopIfActiveEntryHidden()
    }

    // グリッドの間隔・余白。ウィンドウサイズはこれらと設定値から厳密に計算する。
    private static let columnSpacing: CGFloat = 12
    private static let rowSpacing: CGFloat = 14
    // タイトルバー帯(32pt)が上マージンを兼ねる。コンテンツ側の上パディングは
    // 0にし、他の3辺は帯と同じ32ptに揃えて四辺等しい見た目にする
    private static let edgePadding: CGFloat = 32
    private static let topPadding: CGFloat = 0
    /// ドラッグ中にドロップ先となったレコードの透明度(0.0=透明 〜 1.0=不透明)
    private static let dropTargetOpacity: CGFloat = 0.5

    /// グリッドの1スロット。ForEachの安定ID用。
    /// 空きは位置ベース("empty-N")、エントリは自身のidで同一性を取る。
    /// (位置ベースだけにすると削除でセルが詰まった際に@Stateが別エントリへ
    ///  引き継がれ、一瞬旧ジャケットが残る)
    private struct Slot: Identifiable {
        let id: String
        /// 表示順での位置(並び替えの挿入位置計算に使う)
        let index: Int
        let entry: MediaEntry?
    }

    private var shelfGrid: some View {
        let settings = store.settings
        let cell = settings.artworkSize.points
        let columnCount = settings.capacity.columns
        let rowCount = settings.capacity.rows
        // entry.idは数値列または"pl.xxx"なので"empty-N"と衝突しない
        let slots = store.paddedSlots().enumerated().map { offset, entry in
            Slot(id: entry?.id ?? "empty-\(offset)", index: offset, entry: entry)
        }
        let columns = Array(
            repeating: GridItem(.fixed(cell), spacing: Self.columnSpacing),
            count: columnCount
        )
        let width = CGFloat(columnCount) * cell
            + CGFloat(columnCount - 1) * Self.columnSpacing
            + Self.edgePadding * 2
        let height = CGFloat(rowCount) * cell
            + CGFloat(rowCount - 1) * Self.rowSpacing
            + Self.topPadding + Self.edgePadding

        // ウィンドウはwindowResizability(.contentSize)なので、
        // この固定フレーム+タイトルバー帯(上マージンを兼ねる、コンテンツ側の
        // 上パディングは0)がそのままmin=maxのウィンドウサイズになる。
        // 設定変更でstore.settingsが変わると自動的に追従する。
        return LazyVGrid(columns: columns, spacing: Self.rowSpacing) {
            ForEach(slots) { slot in
                Group {
                    if let entry = slot.entry {
                        // ドラッグで並び替え。開始時にドラッグ元を記録する
                        AlbumSlotView(entry: entry)
                            .onDrag {
                                self.draggedID = entry.id
                                self.dropTargetSlotID = nil
                                return NSItemProvider(object: entry.id as NSString)
                            }
                    } else {
                        // 空きスロットは何も描かず、スペースだけ確保する
                        Color.clear
                    }
                }
                .frame(width: cell, height: cell)
                // ドロップで順番が変わる位置にドラッグが乗っている間だけ半透明
                .opacity(dropTargetSlotID == slot.id ? Self.dropTargetOpacity : 1)
                .animation(.easeInOut(duration: 0.12), value: dropTargetSlotID)
                .background {
                    // ドロップゾーンをセルの左右半分に分ける(左=直前、右=直後)。
                    // ジャケットの背面に置くのでタップ/ホバー/右クリックを潰さない。
                    // ドロップ先の登録はヒットテストではなくビューの枠で決まる。
                    HStack(spacing: 0) {
                        dropZone(slot: slot, after: false)
                        dropZone(slot: slot, after: true)
                    }
                }
                .contextMenu {
                    if let entry = slot.entry {
                        Button("Delete Record", role: .destructive) {
                            Self.logger.notice("delete requested for '\(entry.title, privacy: .public)' id=\(entry.id, privacy: .public)")
                            pendingDelete = entry
                        }
                    }
                }
            }
        }
        .padding(EdgeInsets(
            top: Self.topPadding,
            leading: Self.edgePadding,
            bottom: Self.edgePadding,
            trailing: Self.edgePadding
        ))
        .frame(width: width, height: height)
        .background {
            WindowConfigurator()
        }
    }

    /// セル半分のドロップゾーン。after=falseなら直前、trueなら直後に挿入。
    /// 半透明にするのは「ドロップで実際に順番が変わる半分」にカーソルが
    /// 乗っている間だけ。isTargetedはドラッグ終了時にフレームワークが
    /// 必ずfalseで呼ぶので、ハイライトが残ることはない。
    private func dropZone(slot: Slot, after: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard draggedID != nil, let droppedID = items.first else { return false }
                Self.logger.notice("record dropped: dragged=\(droppedID, privacy: .public) slot=\(slot.index, privacy: .public) target='\(slot.entry?.title ?? "", privacy: .public)' after=\(after, privacy: .public)")
                store.move(droppedID, toIndex: slot.index + (after ? 1 : 0))
                return true
            } isTargeted: { targeted in
                let movable = self.willMove(slot: slot, after: after)
                Self.logger.debug("isTargeted slot=\(slot.index, privacy: .public) after=\(after, privacy: .public) targeted=\(targeted, privacy: .public) willMove=\(movable, privacy: .public)")
                if targeted, self.draggedID != nil, movable {
                    dropTargetSlotID = slot.id
                } else if dropTargetSlotID == slot.id {
                    dropTargetSlotID = nil
                }
            }
    }

    /// draggedIDをslotの直前(after=false)/直後(true)へ挿入したとき
    /// 実際に順番が変わるか。変わらないのは: 自分自身のセル、
    /// 右隣セルの左半分、左隣セルの右半分、末尾から空きスロットへのドロップ。
    private func willMove(slot: Slot, after: Bool) -> Bool {
        guard let draggedID,
              let from = store.entries.firstIndex(where: { $0.id == draggedID }) else {
            return false
        }
        let to = ShelfStore.resolvedInsertionIndex(
            from: from,
            rawIndex: slot.index + (after ? 1 : 0),
            count: store.entries.count
        )
        return to != from
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
                // ボタンはセルサイズ比例(S=96ptで従来の44pt/17pt相当)
                let cell = store.settings.artworkSize.points
                ZStack {
                    Circle()
                        .fill(.black.opacity(0.55))
                        .frame(width: cell * 0.45, height: cell * 0.45)
                    Image(systemName: monitor.isCurrent(entry) ? "stop.fill" : "play.fill")
                        .font(.system(size: cell * 0.18, weight: .bold))
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
