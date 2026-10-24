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
    /// ドラッグセッション終了検知用のイベントモニタ。onDragには終了
    /// コールバックが無いので、ドラッグ中だけ発生しないイベント
    /// (mouseUp/mouseMoved)を拾ってdraggedIDをクリアする
    @State private var dragEndMonitor: Any?
    /// ゴーストのポインタ追従用タイマー。leftMouseDraggedはドラッグ
    /// セッションに吸収されてモニタへ届かないため(2026-10-24実測)、
    /// 60fpsでmouseLocationをポーリングして追従させる
    @State private var trackTimer: Timer?
    /// ドロップ後の着地飛行をしているゴーストの対象エントリ。
    /// このIDのセルはゴーストが消えるまで非表示
    @State private var ghostEntryID: String?
    /// ゴーストの描画・移動を司るNSViewオーバーレイ。
    /// ※SwiftUIの@Stateで位置を持つとドラッグ中の毎イベントでbodyが再評価
    ///   され、走行中セッション配下のonDrag/dropDestinationクロージャが
    ///   破棄されてEXC_BAD_ACCESSになる(2026-10-24実機クラッシュ)。
    ///   そのため位置は命令的にNSViewへ流し、SwiftUIの状態に持たせない
    @StateObject private var ghost = GhostController()

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
        let columnCount = settings.columns
        let rowCount = settings.rows
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

        // 最大構成(10列×10行・L=216pt)ではコンテンツが約2332×2278ptに
        // なり、多くのディスプレイのvisibleFrameを超える。
        // windowResizability(.contentSize)でmin=max固定なので、そのままだと
        // 画面からはみ出すウィンドウが生成される。ここでフレームを
        // NSScreen.main.visibleFrame にクランプし、はみ出た分は
        // ScrollViewで到達可能にする(選択肢そのものは削らない)。
        let maxSize = Self.maxContentSize()
        let frameW = min(width, maxSize.width)
        let frameH = min(height, maxSize.height)
        let clamped = frameW < width || frameH < height

        // ウィンドウはwindowResizability(.contentSize)なので、
        // この固定フレーム+タイトルバー帯(上マージンを兼ねる、コンテンツ側の
        // 上パディングは0)がそのままmin=maxのウィンドウサイズになる。
        // 設定変更でstore.settingsが変わると自動的に追従する。
        let grid = LazyVGrid(columns: columns, spacing: Self.rowSpacing) {
            ForEach(slots) { slot in
                Group {
                    if let entry = slot.entry {
                        // ドラッグで並び替え。開始時にドラッグ元を記録する。
                        // previewを透明にしてシステムのドラッグ画像を消す
                        // (消しておかないとドロップ時に元位置へ滑り戻る
                        //  スライドバックが走り、自前ゴーストと二重表示
                        //  になる — 2026-10-24実測)
                        AlbumSlotView(entry: entry)
                            .onDrag {
                                self.startDrag(entry)
                                return NSItemProvider(object: entry.id as NSString)
                            } preview: {
                                Color.clear.frame(width: 1, height: 1)
                            }
                    } else {
                        // 空きスロットは何も描かず、スペースだけ確保する
                        Color.clear
                    }
                }
                .frame(width: cell, height: cell)
                // ドロップで順番が変わる位置にドラッグが乗っている間だけ半透明。
                // ドラッグ元/ゴースト表示中のセルは飛んでいる画像と
                // 重複するので表示しない(即時切替)
                .opacity(
                    (draggedID == slot.id || ghostEntryID == slot.id)
                    ? 0
                    : (dropTargetSlotID == slot.id ? Self.dropTargetOpacity : 1)
                )
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
        .overlay {
            // ゴースト描画用の透明NSView(グリッド座標=このビューの座標)
            GhostOverlayRep(controller: ghost)
                .allowsHitTesting(false)
        }
        .padding(EdgeInsets(
            top: Self.topPadding,
            leading: Self.edgePadding,
            bottom: Self.edgePadding,
            trailing: Self.edgePadding
        ))
        // クランプ時だけScrollViewで包み、フレームを画面内に収める。
        // グリッド座標系(スロット矩形・ゴースト位置)はコンテンツ基準のまま
        // 変わらない。マウス位置→グリッド座標の変換だけ
        // mouseGridPoint内でスクロールオフセットを足して補正する。
        return Group {
            if clamped {
                ScrollView([.horizontal, .vertical]) { grid }
            } else {
                grid
            }
        }
        .frame(width: frameW, height: frameH)
        // クランプ状態の遷移時だけログ(body評価のたびに出るのを防ぐ)
        .onAppear {
            if clamped {
                Self.logClamp(natural: CGSize(width: width, height: height),
                              clamped: CGSize(width: frameW, height: frameH))
            }
        }
        .onChange(of: clamped) { _, newValue in
            if newValue {
                Self.logClamp(natural: CGSize(width: width, height: height),
                              clamped: CGSize(width: frameW, height: frameH))
            }
        }
        .background {
            WindowConfigurator()
        }
    }

    /// ウィンドウが画面からはみ出さないためのコンテンツサイズ上限。
    /// NSScreen.main.visibleFrame からタイトルバー帯と安全マージンを引いた値。
    /// スクリーン情報が取れない場合はクランプしない。
    private static func maxContentSize() -> CGSize {
        guard let visible = NSScreen.main?.visibleFrame else {
            return CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        let safety: CGFloat = 16
        // コンテンツ側の上パディングは0でタイトルバー帯が上マージンを兼ねる
        // 構成のため、ウィンドウ高には帯の分も必要。控えめに40pt引く。
        let titlebarAllowance: CGFloat = 40
        return CGSize(
            width: max(320, visible.width - safety * 2),
            height: max(240, visible.height - safety * 2 - titlebarAllowance)
        )
    }

    /// クランプ発動のログ(発動時のみ呼ばれる)
    private static func logClamp(natural: CGSize, clamped: CGSize) {
        logger.notice("window frame clamped to screen: natural=\(Int(natural.width), privacy: .public)x\(Int(natural.height), privacy: .public) clamped=\(Int(clamped.width), privacy: .public)x\(Int(clamped.height), privacy: .public) visibleFrame=\(NSStringFromRect(NSScreen.main?.visibleFrame ?? .zero), privacy: .public)")
    }

    /// セル半分のドロップゾーン。after=falseなら直前、trueなら直後に挿入。
    /// 半透明にするのは「ドロップで実際に順番が変わる半分」にカーソルが
    /// 乗っている間だけ。isTargetedはドラッグ終了時にフレームワークが
    /// 必ずfalseで呼ぶので、ハイライトが残ることはない。
    private func dropZone(slot: Slot, after: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, location in
                guard draggedID != nil, let droppedID = items.first else { return false }
                Self.logger.notice("record dropped: dragged=\(droppedID, privacy: .public) slot=\(slot.index, privacy: .public) target='\(slot.entry?.title ?? "", privacy: .public)' after=\(after, privacy: .public) location=(\(location.x, privacy: .public), \(location.y, privacy: .public)) zoneRect=\(NSStringFromRect(self.slotRect(index: slot.index)), privacy: .public)")
                // ドロップ成立=セッション終了。モニタより先にここで戻す
                self.draggedID = nil
                self.dropTargetSlotID = nil
                store.move(droppedID, toIndex: slot.index + (after ? 1 : 0))
                // ゴーストはすでにポインタ位置にいるので着地スロットへ飛ばす。
                // システム画像は不可視なので待ち不要。飛行中は着地セルが
                // ghostEntryIDで隠れたままなので二重表示にならない
                if let newIndex = store.entries.firstIndex(where: { $0.id == droppedID }),
                   self.ghostEntryID == droppedID {
                    self.flyGhost(toIndex: newIndex)
                }
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

    /// ドラッグ開始。ドラッグ元を記録し、ポインタ追従ゴーストと
    /// 終了検知モニタを起動する
    private func startDrag(_ entry: MediaEntry) {
        self.draggedID = entry.id
        self.dropTargetSlotID = nil
        self.installDragMonitor()
        // ポインタ追従ポーリング開始(commonモードでドラッグ中の
        // イベントトラッキング中も発火する)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            if let p = self.mouseGridPoint() {
                self.ghost.move(to: p)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.trackTimer = timer
        Self.logger.notice("drag start: '\(entry.title, privacy: .public)' id=\(entry.id, privacy: .public)")
        // ジャケット読み込みが終わり次第ゴーストをポインタ位置に出す
        Task { @MainActor in
            guard let image = await ShelfStore.artworkImage(for: entry) else {
                Self.logger.error("ghost artwork load failed for '\(entry.title, privacy: .public)'")
                return
            }
            // 素早いドラッグで読み込み中にセッションが終わっていたら
            // ゴーストを出さない(出すと着地処理が走らず残存する)
            guard self.draggedID == entry.id else {
                Self.logger.debug("ghost skipped: session already ended")
                return
            }
            self.ghostEntryID = entry.id
            let cell = self.store.settings.artworkSize.points
            self.ghost.show(image, at: self.mouseGridPoint() ?? .zero, cell: cell)
        }
    }

    /// ポインタ追従・終了検知モニタを張る。ドラッグセッション中は
    /// leftMouseDragged(3本指ドラッグ含む)が流れ続けるのでそれで
    /// ゴーストを追従させ、leftMouseUpやボタン無しのmouseMovedが来た
    /// 時点で終了と判断する。
    /// (pressedMouseButtonsポーリングは3本指ドラッグで検知不能なため不採用。
    ///  セッション外へのドロップやEscapeキャンセルでも次のマウス移動で戻る)
    private func installDragMonitor() {
        if let monitor = dragEndMonitor {
            NSEvent.removeMonitor(monitor)
        }
        Self.logger.debug("drag monitor installed")
        dragEndMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .mouseMoved]
        ) { event in
            // ボタン押下中のmouseMovedはドラッグ中のstrayイベントなので無視
            if event.type == .mouseMoved, NSEvent.pressedMouseButtons != 0 {
                return event
            }
            // 終了候補。ただしmouseUpはperform(ドロップ処理)より先に
            // モニタへ届くことがある — ここで即判定するとドロップを
            // キャンセルと誤認して以降のドロップが全滅する(2026-10-24実測)。
            // 50ms待ってperformが走る時間を与えてから判定する
            Self.logger.debug("drag end candidate (event=\(event.type.rawValue, privacy: .public))")
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                // perform(ドロップ成立)が走っていればdraggedIDはnil。
                // 残っている=キャンセル/無効位置へのドロップ。システムが
                // ドラッグ画像を元位置へ滑り戻すので、その間だけ元セルの
                // 再表示を遅らせる(二重表示防止)
                if let cancelledID = self.draggedID {
                    Self.logger.notice("drag cancelled: id=\(cancelledID, privacy: .public)")
                    self.draggedID = nil
                    // システム画像は不可視なのでスライドバックは自前で:
                    // ゴーストを元のスロットへ滑り戻す
                    if let index = store.entries.firstIndex(where: { $0.id == cancelledID }),
                       self.ghostEntryID == cancelledID {
                        self.flyGhost(toIndex: index)
                    }
                }
                self.dropTargetSlotID = nil
                // モニタは1回だけ外す(複数の遅延判定が重なっても二重除去しない)
                if let monitor = self.dragEndMonitor {
                    NSEvent.removeMonitor(monitor)
                    self.dragEndMonitor = nil
                }
                self.stopTracking()
            }
            return event
        }
    }

    /// ポインタ追従ポーリングを止める(飛行アニメーションと競合させない)
    private func stopTracking() {
        self.trackTimer?.invalidate()
        self.trackTimer = nil
    }

    /// ゴーストを現在位置からindex番スロットの中心まで飛ばす。
    /// 着地したらゴーストを消し、そのエントリの実セルが姿を現す
    /// (それまでghostEntryIDで隠れている)
    private func flyGhost(toIndex: Int) {
        self.stopTracking()
        let rect = self.slotRect(index: toIndex)
        let flyingID = self.ghostEntryID
        Self.logger.notice("ghost fly to index=\(toIndex, privacy: .public)")
        self.ghost.fly(to: CGPoint(x: rect.midX, y: rect.midY)) {
            if self.ghostEntryID == flyingID {
                self.ghost.hide()
                self.ghostEntryID = nil
            }
        }
    }

    /// 現在のマウス位置をグリッド座標系(グリッド左上=0,0)に変換。
    /// タイトルバー帯の高さはcontentLayoutRectとframeの差から出す
    /// (content.convertの座標変換はfullSizeContentView構成でYが狂う
    ///  ためframe基準で自分で計算する — 2026-10-24実測)。
    /// ウィンドウが画面収まりにクランプされてグリッドがScrollView内に
    /// ある場合は、見えている矩形の原点(スクロール量)を足して補正する。
    private func mouseGridPoint() -> CGPoint? {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
            return nil
        }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        // ScrollViewはグリッドが画面より大きいときだけ存在する。
        // SwiftUIのスクロールコンテンツはflippedなので、
        // documentVisibleRect.originが左上基準のスクロール量になる。
        let scrollOffset = Self.findScrollView(in: window.contentView)?
            .documentVisibleRect.origin ?? .zero
        return CGPoint(
            x: inWindow.x - Self.edgePadding + scrollOffset.x,
            y: window.frame.height - inWindow.y - titlebarHeight - Self.topPadding
                + scrollOffset.y
        )
    }

    /// ビュー階層から最初のNSScrollViewを探す(グリッド用ScrollViewは
    /// このウィンドウに1つだけ)
    private static func findScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scrollView = view as? NSScrollView { return scrollView }
        for sub in view.subviews {
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    /// index番スロットのグリッド座標系での矩形(LazyVGridのpaddingより内側)
    private func slotRect(index: Int) -> CGRect {
        let settings = store.settings
        let cell = settings.artworkSize.points
        let column = index % settings.columns
        let row = index / settings.columns
        return CGRect(
            x: CGFloat(column) * (cell + Self.columnSpacing),
            y: CGFloat(row) * (cell + Self.rowSpacing),
            width: cell,
            height: cell
        )
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

/// ゴースト(自前ドラッグ画像)の制御窓口。NSViewを弱参照し、
/// 表示/移動/着地アニメーションを命令的に実行する。
/// @StateObjectにすることでShelfView再評価でも同一インスタンスが保たれる
private final class GhostController: ObservableObject {
    weak var view: GhostOverlayView?

    func show(_ image: NSImage, at center: CGPoint, cell: CGFloat) {
        view?.show(image, at: center, cell: cell)
    }

    /// ポインタ追従(アニメーションなし、即時)
    func move(to center: CGPoint) {
        view?.moveImage(center: center)
    }

    func fly(to center: CGPoint, completion: @escaping () -> Void) {
        guard let view else {
            completion()
            return
        }
        view.flyImage(to: center, completion: completion)
    }

    func hide() {
        view?.hideImage()
    }
}

/// グリッド上にジャケット画像を表示するオーバーレイNSView。
/// isFlippedで左上原点にし、グリッド座標系をそのまま使えるようにする
private final class GhostOverlayView: NSView {
    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")
    /// シャドウ担当(クリップしない)。移動はこのビューのframeで行う
    private let container = NSView()
    /// 画像担当(角丸4ptでクリップ。セルのジャケットと形を揃える)
    private let imageView = NSImageView()
    private var cellSize: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        container.wantsLayer = true
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.25
        container.layer?.shadowRadius = 3
        container.layer?.shadowOffset = CGSize(width: 0, height: -2)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        container.addSubview(imageView)
        container.isHidden = true
        addSubview(container)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ image: NSImage, at center: CGPoint, cell: CGFloat) {
        cellSize = cell
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: CGSize(width: cell, height: cell))
        container.frame = CGRect(
            x: center.x - cell / 2, y: center.y - cell / 2,
            width: cell, height: cell
        )
        container.isHidden = false
        Self.logger.notice("ghost shown at frame=\(NSStringFromRect(self.container.frame), privacy: .public)")
    }

    /// ポインタ追従移動(アニメーションなし、即時)
    func moveImage(center: CGPoint) {
        guard !container.isHidden else { return }
        container.setFrameOrigin(
            CGPoint(x: center.x - cellSize / 2, y: center.y - cellSize / 2)
        )
    }

    /// 指定位置まで0.25s easeOutで飛ばし、完了したらcompletionを呼ぶ
    func flyImage(to center: CGPoint, completion: @escaping () -> Void) {
        Self.logger.notice("ghost flyImage: frame before=\(NSStringFromRect(self.container.frame), privacy: .public) target origin=(\(center.x - self.cellSize / 2, privacy: .public), \(center.y - self.cellSize / 2, privacy: .public))")
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            container.animator().setFrameOrigin(
                CGPoint(x: center.x - cellSize / 2, y: center.y - cellSize / 2)
            )
        }, completionHandler: completion)
    }

    func hideImage() {
        container.isHidden = true
        imageView.image = nil
    }
}

/// GhostOverlayViewをSwiftUIに載せるための薄いラッパ。
/// 更新することは何も無い(すべて命令的に操作される)
private struct GhostOverlayRep: NSViewRepresentable {
    let controller: GhostController

    func makeNSView(context: Context) -> GhostOverlayView {
        let view = GhostOverlayView()
        controller.view = view
        return view
    }

    func updateNSView(_ nsView: GhostOverlayView, context: Context) {}
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
