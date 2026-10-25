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
/// 登録はシェルフへのドラッグ&ドロップで行う。
/// 1ウィンドウ=1シェルフ(シェルフIDごとにShelfStoreが1つ)。
/// シェルフ間でもレコードをドラッグ&ドロップで移動できる。
struct ShelfView: View {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    /// このウィンドウが表示するシェルフのID。
    /// 起動時にシステムが作る値を持たないウィンドウはプライマリシェルフになる
    @State private var shelfID: String
    /// シェルフIDをシーンの値と双方向にする(WindowGroupの値。復元用に書き戻す)
    private let shelfIDBinding: Binding<String?>
    /// 起動時の1枚目(値を持たない)ウィンドウか。onAppearで残りの
    /// シェルフのウィンドウを開き直す係にするためのフラグ
    @State private var isPrimaryWindow: Bool
    @ObservedObject private var store: ShelfStore
    @ObservedObject private var manager = ShelfManager.shared
    @Environment(\.openWindow) private var openWindow
    /// このビューが載っているNSWindow(マウス座標変換・シェルフ削除時の
    /// window.close()用)。@Stateに持つとviewDidMoveToWindow中の代入で
    /// 「レイアウト中の状態更新」になるため、命令的にだけ書く箱に入れる
    @StateObject private var windowBox = WindowBox()
    /// 削除確認ダイアログに出している対象。非nilの間ダイアログを表示する。
    @State private var pendingDelete: MediaEntry?
    /// シェルフ削除の確認ダイアログ表示フラグ
    @State private var pendingShelfDelete = false
    /// 重複ウィンドウと判定され、アタッチ次第自分を閉じるフラグ
    /// (onAppear時点ではwindowBox.windowがまだ無い場合があるため)
    @State private var isDuplicateWindow = false
    /// ドロップ追加の失敗(重複/満杯/取得エラー)をアラートで出すための
    /// メッセージ。非nilの間ダイアログを表示する。
    @State private var addError: String?
    /// 追加Task実行中のエントリID。URL+テキストの両方を供する外部ドラッグで
    /// URLゾーンとStringゾーンが両方performされた場合の二重追加
    /// (.addedと.duplicateアラートの同時発生)を防ぐために使う
    @State private var inFlightAddIDs: Set<String> = []
    /// ドロップ追加がfetch待ちの間、挿入先として半透明にしておくスロット。
    /// 着地アニメーションを止めたので、これがないとドロップからカタログ
    /// 取得完了までの約0.5秒、何も表示されない空白時間になる
    @State private var pendingAddSlotID: String?
    /// 外部ドラッグがシェルフに入った時点で先回り開始したfetch+
    /// アートワーク取得のTask(entry.id→Task)。ドロップ時はこれを
    /// 消費してinsertだけ済ませるので待ち時間がほぼ消える。
    /// ドロップされないまま離れた場合は無駄な取得になるが、
    /// メタデータだけなので害はない。結果Taskはdictに残し、
    /// 同じアルバムの再ドラッグでも再利用する
    @State private var prefetchedEntries: [String: Task<MediaEntry, Error>] = [:]
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
    /// ゴースト(自前ドラッグ画像)を司る枠なしパネル。
    /// ウィンドウ内のNSViewオーバーレイだとポインタがウィンドウ外へ
    /// 出た瞬間にクリップされてレコードが消えるため、透明な別
    /// ウィンドウ(GhostPanel)で画面座標のまま描く(Musicアプリと同様)
    /// ※SwiftUIの@Stateで位置を持つとドラッグ中の毎イベントでbodyが再評価
    ///   され、走行中セッション配下のonDrag/dropDestinationクロージャが
    ///   破棄されてEXC_BAD_ACCESSになる(2026-10-24実機クラッシュ)。
    ///   そのため位置は命令的にパネルへ流し、SwiftUIの状態に持たせない。
    ///   ドラッグセッションは同時に1つなのでアプリ全体で共有し、
    ///   シェルフ間ドロップ時はドロップ先が所有権を引き継いで
    ///   シェルフ内ドロップと同じ着地アニメーションを実行する
    private let ghost = GhostController.shared

    init(shelfID: Binding<String?>) {
        self.shelfIDBinding = shelfID
        let resolved = shelfID.wrappedValue ?? ShelfManager.shared.primaryShelfID
        _shelfID = State(initialValue: resolved)
        _store = ObservedObject(wrappedValue: ShelfManager.shared.store(for: resolved))
        _isPrimaryWindow = State(initialValue: shelfID.wrappedValue == nil)
    }

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
        // 外部ドラッグで追加できなかった理由(重複/満杯/取得失敗)を通知する。
        // 成功時はグリッドにレコードが出るだけなのでアラートは出さない。
            .alert(
                "Couldn't Add Record",
                isPresented: Binding(
                    get: { addError != nil },
                    set: { if !$0 { addError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(addError ?? "")
            }
        // シェルフ自体の削除確認。コンテキストメニューの「Delete Shelf…」から。
            .alert(
                "Delete this shelf?",
                isPresented: $pendingShelfDelete
            ) {
                Button("Delete Shelf", role: .destructive) { deleteShelf() }
                Button("Cancel", role: .cancel) {
                    Self.logger.notice("shelf delete cancelled: \(self.shelfID, privacy: .public)")
                }
            } message: {
                Text("The records on this shelf will be removed.")
            }
        // 再生状態はAlbumSlotViewが個別にmonitorを監視するので、ここでは監視せず
        // 開始/停止だけ行う(画面全体の2秒おき再描画を避ける)。
        // 複数ウィンドウあるので監視は参照カウント式(片方が閉じても他方で継続)
            .onAppear {
                PlaybackMonitor.shared.start()
                // コマンドや他のシェルフのメニューからも新規ウィンドウを
                // 開けるよう、環境のopenWindowをmanagerに退避する
                ShelfManager.shared.openShelfWindow = { id in
                    openWindow(id: "shelf", value: id)
                }
                // 値を持たないウィンドウ(起動時やドックアイコンでシステムが
                // 作るもの)はプライマリシェルフになる。プライマリが既に
                // 開いているならこのウィンドウは重複なので自分を閉じる。
                // ウィンドウが開かれていないシェルフもここで開き直す。
                // 重複判定はnoteWindowOpenedより先に行うこと
                if isPrimaryWindow {
                    isPrimaryWindow = false
                    if ShelfManager.shared.openShelfIDs.contains(shelfID) {
                        Self.logger.notice("duplicate value-less window for shelf=\(self.shelfID, privacy: .public); closing self")
                        isDuplicateWindow = true
                        windowBox.window?.close()
                    } else {
                        // シーンの値にシェルフIDを書き戻して同一性を持たせる
                        shelfIDBinding.wrappedValue = shelfID
                        ShelfManager.shared.openMissingShelfWindows { id in
                            openWindow(id: "shelf", value: id)
                        }
                    }
                }
                // 重複ウィンドウ(自己クローズする側)は登録しない。
                // 登録すると、そのonDisappearのnoteWindowClosedが
                // 本来のプライマリウィンドウの登録まで解除してしまう
                if !isDuplicateWindow {
                    ShelfManager.shared.noteWindowOpened(shelfID)
                }
            }
            .onDisappear {
                // stopPollingはonAppearのstart()と対なので重複ウィンドウ
                // でも呼ぶ。noteWindowClosedは登録した側だけが呼ぶ
                PlaybackMonitor.shared.stopPolling()
                if !isDuplicateWindow {
                    ShelfManager.shared.noteWindowClosed(shelfID)
                }
            }
    }

    /// 確認済みのシェルフ削除。データを消してウィンドウを閉じる
    private func deleteShelf() {
        Self.logger.notice("shelf delete confirmed: \(self.shelfID, privacy: .public)")
        ShelfManager.shared.deleteShelf(shelfID)
        windowBox.window?.close()
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
                        // ドラッグで並び替え/シェルフ間移動。開始時にドラッグ元を記録する。
                        // ペーストボードにはシェルフID+エントリのJSONを載せ、
                        // 別シェルフのウィンドウでも再取得なしで挿入できるようにする。
                        // previewを透明にしてシステムのドラッグ画像を消す
                        // (消しておかないとドロップ時に元位置へ滑り戻る
                        //  スライドバックが走り、自前ゴーストと二重表示
                        //  になる — 2026-10-24実測)
                        AlbumSlotView(entry: entry, store: store)
                            .onDrag {
                                self.startDrag(entry)
                                let payload = ShelfDragPayload(sourceShelfID: self.shelfID, entry: entry)
                                return NSItemProvider(object: payload.encode() as NSString)
                            } preview: {
                                Color.clear.frame(width: 1, height: 1)
                            }
                            .contextMenu {
                                Button("Delete Record", role: .destructive) {
                                    Self.logger.notice("delete requested for '\(entry.title, privacy: .public)' id=\(entry.id, privacy: .public)")
                                    pendingDelete = entry
                                }
                            }
                    } else {
                        // 空きスロットは何も描かず、スペースだけ確保する
                        Color.clear
                    }
                }
                .frame(width: cell, height: cell)
                // ドロップで順番が変わる/外部追加される位置にカーソルが乗って
                // いる間と、追加fetch待ちの間だけ半透明。
                // ドラッグ元/ゴースト表示中のセルは飛んでいる画像と
                // 重複するので表示しない(即時切替)
                .opacity(
                    (draggedID == slot.id || ghostEntryID == slot.id)
                    ? 0
                    : (dropTargetSlotID == slot.id || pendingAddSlotID == slot.id
                       ? Self.dropTargetOpacity : 1)
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
            }
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
        // overlayGridPoint内でスクロールオフセットを足して補正する。
        return Group {
            if clamped {
                ScrollView([.horizontal, .vertical]) { grid }
            } else {
                grid
            }
        }
        .frame(width: frameW, height: frameH)
        // 外部URLドラッグ専用の透明オーバーレイ(NSDraggingDestination)。
        // .dropDestinationでは止められない着地アニメーション
        // (animatesToDestination)をこちらで止めるため、public.urlを
        // 持つ外部ドラッグはこのビューが先に受け取る。hitTest=nilで
        // クリックはセルへ素通し。余白含むフレーム全体をカバーする。
        // 内部ドラッグはplain-textのみなのでこのオーバーレイは候補外。
        .overlay {
            ExternalDropOverlayRep(
                onEntered: { self.externalDragEntered(url: $0) },
                onHover: { self.externalDragMoved(to: $0) },
                onLeave: { self.externalDragEnded() },
                onDrop: { url, p in self.externalDrop(url, at: p) }
            )
            .allowsHitTesting(false)
        }
        // セルの外(グリッド余白)へのドロップの受け口。スロット上の
        // ドロップゾーンが先に拾うので、ここに来るのは余白ドロップのみ。
        // 余白=末尾挿入(atIndex: Int.max)。内部ドラッグが余白に落ちた
        // 場合はfalseを返してキャンセル扱いにする。
        // URL用は付けない: 同一ビューへの.dropDestination積みは先の
        // 1つしか有効にならず、外部URLドラッグは余白もカバーする
        // ExternalDropOverlayViewが受け取るためここでは不要
        .dropDestination(for: String.self) { items, location in
            guard let text = items.first else { return false }
            // アプリ内ドラッグのペイロードを先に判定。自分のシェルフの
            // レコードが余白に落ちたら拒否(=キャンセル)。別シェルフから
            // 来たペイロードは末尾への移動として受け取る。
            // ペイロードでないテキストは外部ドロップとして追加経路へ流す
            if let payload = ShelfDragPayload.decode(text) {
                guard payload.sourceShelfID != self.shelfID else {
                    Self.logger.notice("margin drop rejected: internal drag to non-cell area")
                    return false
                }
                Self.logger.notice("grid margin cross-shelf drop: '\(payload.entry.title, privacy: .public)' from=\(payload.sourceShelfID, privacy: .public)")
                return self.transferDrop(payload, atIndex: .max)
            }
            Self.logger.notice("grid margin text dropped: '\(text, privacy: .public)' location=(\(location.x, privacy: .public), \(location.y, privacy: .public))")
            return self.addDroppedText(text, atIndex: .max)
        }
        // レコード以外の場所(余白・空きスロット)の右クリックメニュー。
        // レコードのメニュー(Delete Record)はセル側にあり、そちらが優先される。
        // 設定画面はCmd+,ではなくここから開く
        .contextMenu {
            // このビュー自身のopenWindow環境で新シェルフのウィンドウを開く
            Button("New Shelf") {
                let id = ShelfManager.shared.createShelf()
                openWindow(id: "shelf", value: id)
            }
            Button("Settings…") {
                Self.logger.notice("settings open requested: shelf=\(self.shelfID, privacy: .public)")
                // 設定画面は「最後にキーになったシェルフ」を編集する。
                // 右クリックでウィンドウはkeyになるはずだが、念のため
                // ここでもフォーカスを明示する
                ShelfManager.shared.shelfWindowBecameKey(store)
                openWindow(id: "settings")
            }
            Divider()
            Button("Delete Shelf…", role: .destructive) {
                Self.logger.notice("shelf delete requested: \(self.shelfID, privacy: .public)")
                pendingShelfDelete = true
            }
            .disabled(manager.shelfIDs.count <= 1)
        }
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
            WindowConfigurator(
                onWindowReady: {
                    self.windowBox.window = $0
                    if self.isDuplicateWindow { $0?.close() }
                },
                onBecameKey: { ShelfManager.shared.shelfWindowBecameKey(self.store) }
            )
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
        let insertIndex = slot.index + (after ? 1 : 0)
        return Color.clear
            .contentShape(Rectangle())
            // ドロップ先はString用1つのみ。同一ビューに複数の
            // .dropDestinationを積むと最初に適用したものしか有効に
            // ならない(2026-10-25実機: URL用を先に置いたらString用が
            // 死んで並び替えが壊れた)。外部URLドラッグは最前面の
            // ExternalDropOverlayViewが吸い、オーバーレイを抜けたURLも
            // plain-textフレーバ経由でこのゾーンに届くので問題ない
            .dropDestination(for: String.self) { items, location in
                guard let dropped = items.first else { return false }
                // アプリ内ドラッグのペイロードを先に判定。
                // 自シェルフ=並び替え、別シェルフ=移動。ペイロード以外は
                // 外部テキストとして追加経路へ流す(キャンセル直後に
                // draggedIDが残ったまま外部テキストが落ちたケースもここ)
                if let payload = ShelfDragPayload.decode(dropped) {
                    guard payload.sourceShelfID == self.shelfID else {
                        Self.logger.notice("cross-shelf record dropped: '\(payload.entry.title, privacy: .public)' from=\(payload.sourceShelfID, privacy: .public) slot=\(slot.index, privacy: .public) after=\(after, privacy: .public) location=(\(location.x, privacy: .public), \(location.y, privacy: .public))")
                        return self.transferDrop(payload, atIndex: insertIndex)
                    }
                    let droppedID = payload.entry.id
                    Self.logger.notice("record dropped: dragged=\(droppedID, privacy: .public) slot=\(slot.index, privacy: .public) target='\(slot.entry?.title ?? "", privacy: .public)' after=\(after, privacy: .public) location=(\(location.x, privacy: .public), \(location.y, privacy: .public)) zoneRect=\(NSStringFromRect(self.slotRect(index: slot.index)), privacy: .public)")
                    // ドロップ成立=セッション終了。モニタより先にここで戻す
                    self.draggedID = nil
                    self.dropTargetSlotID = nil
                    store.move(droppedID, toIndex: insertIndex)
                    // ゴーストはすでにポインタ位置にいるので着地スロットへ飛ばす。
                    // システム画像は不可視なので待ち不要。飛行中は着地セルが
                    // ghostEntryIDで隠れたままなので二重表示にならない
                    if let newIndex = store.entries.firstIndex(where: { $0.id == droppedID }),
                       self.ghostEntryID == droppedID {
                        self.flyGhost(toIndex: newIndex)
                    }
                    return true
                }
                Self.logger.notice("external text dropped: '\(dropped, privacy: .public)' slot=\(slot.index, privacy: .public) after=\(after, privacy: .public) location=(\(location.x, privacy: .public), \(location.y, privacy: .public))")
                return self.addDroppedText(dropped, atIndex: insertIndex, slotID: slot.id)
            } isTargeted: { targeted in
                let movable = self.willMove(slot: slot, after: after)
                Self.logger.debug("isTargeted slot=\(slot.index, privacy: .public) after=\(after, privacy: .public) targeted=\(targeted, privacy: .public) willMove=\(movable, privacy: .public)")
                // 内部ドラッグ中は実際に順番が変わる半分だけ、
                // 外部テキストのドラッグ中はどちらの半分でも半透明にする
                if targeted, (self.draggedID != nil ? movable : true) {
                    dropTargetSlotID = slot.id
                } else if dropTargetSlotID == slot.id {
                    dropTargetSlotID = nil
                }
            }
    }

    /// 外部からドロップされたテキスト/URLをシェルフへ追加する。
    /// MediaURLParserで解釈できるものだけ受け付け(true=ドロップ成立)。
    /// 追加自体は非同期なのでここではTaskを起こすだけにし、
    /// 重複/満杯/エラーはアラート(addError)で後から通知する。
    /// slotIDを渡すとfetch待ちの間そのスロットを半透明に保つ
    /// (ドロップ→レコード出現の繋ぎ。余白ドロップはnilで呼ぶ)
    private func addDroppedText(_ text: String?, atIndex: Int, slotID: String? = nil) -> Bool {
        guard let text, let parsed = MediaURLParser.parse(text) else {
            Self.logger.notice("drop add: parse failed for '\(text ?? "nil", privacy: .public)'")
            return false
        }
        Self.logger.notice("drop add: parsed kind=\(parsed.kind.rawValue, privacy: .public) id=\(parsed.id, privacy: .public) insertIndex=\(atIndex, privacy: .public)")
        // URL+テキストの両方を供するドラッグでURLゾーンとStringゾーンが
        // 両方performされた場合、同じidの追加Taskが2つ走る。後発は
        // スキップする(.addedと.duplicateアラートが同時に出るのを防ぐ)。
        // ドロップ自体は受理してよいのでtrueを返す
        guard !inFlightAddIDs.contains(parsed.id) else {
            Self.logger.notice("drop add: add already in-flight for id=\(parsed.id, privacy: .public), skipping")
            return true
        }
        inFlightAddIDs.insert(parsed.id)
        dropTargetSlotID = nil
        // fetch完了までドロップ位置のスロットを半透明のまま待たせる
        // (ハイライトを消すと0.5秒ほど何も無い空白に見える)
        pendingAddSlotID = slotID
        Task { @MainActor in
            defer {
                inFlightAddIDs.remove(parsed.id)
                pendingAddSlotID = nil
            }
            do {
                let outcome: ShelfStore.AddOutcome
                if let prefetch = prefetchedEntries.removeValue(forKey: parsed.id) {
                    // ドラッグイン時に先回りしておいたfetchを消費する
                    // (完了済みなら即返るので待ち時間はほぼゼロ)
                    Self.logger.notice("drop add: using prefetched entry id=\(parsed.id, privacy: .public)")
                    outcome = store.registerFetched(try await prefetch.value, insertAt: atIndex)
                } else {
                    outcome = try await store.addFromCatalog(parsed, insertAt: atIndex)
                }
                switch outcome {
                case .added(let entry):
                    Self.logger.notice("drop add: added '\(entry.title, privacy: .public)' at index=\(atIndex, privacy: .public)")
                case .duplicate:
                    Self.logger.notice("drop add: duplicate id=\(parsed.id, privacy: .public)")
                    let kindName = String(localized: parsed.kind == .album ? "album" : "playlist")
                    addError = String(localized: "This \(kindName) is already on the shelf.")
                case .full:
                    Self.logger.notice("drop add: shelf full capacity=\(self.store.capacity, privacy: .public)")
                    addError = String(localized: "The shelf is full. You can add up to \(store.capacity) records.")
                }
            } catch {
                Self.logger.error("drop add failed: \(error.localizedDescription, privacy: .public)")
                addError = error.localizedDescription
            }
        }
        return true
    }

    /// 別シェルフのウィンドウからドラッグされたレコードをこのシェルフへ移す。
    /// エントリはペイロードに入っているのでカタログ再取得は不要
    /// (アートワークも全シェルフ共有)。重複・満杯ならfalseを返して
    /// ドロップを拒否する(=元シェルフにレコードが残る)。
    /// 元シェルフからの削除はターゲットへの追加が確定してから行う
    /// (先に消すと失敗時にどちらのシェルフにも無い状態になりうる)
    private func transferDrop(_ payload: ShelfDragPayload, atIndex: Int) -> Bool {
        let entry = payload.entry
        Self.logger.notice("cross-shelf transfer: '\(entry.title, privacy: .public)' \(payload.sourceShelfID, privacy: .public)→\(self.shelfID, privacy: .public) index=\(atIndex, privacy: .public)")
        if store.contains(entry.id) {
            Self.logger.notice("cross-shelf transfer rejected: duplicate id=\(entry.id, privacy: .public)")
            let kindName = String(localized: entry.kind == .album ? "album" : "playlist")
            addError = String(localized: "This \(kindName) is already on the shelf.")
            return false
        }
        guard store.entries.count < store.capacity else {
            Self.logger.notice("cross-shelf transfer rejected: shelf full capacity=\(self.store.capacity, privacy: .public)")
            addError = String(localized: "The shelf is full. You can add up to \(store.capacity) records.")
            return false
        }
        let outcome = store.registerFetched(entry, insertAt: atIndex)
        guard case .added = outcome else {
            Self.logger.error("cross-shelf transfer: registerFetched failed outcome=\(String(describing: outcome), privacy: .public)")
            return false
        }
        ShelfManager.shared.store(for: payload.sourceShelfID).remove(entry.id)
        dropTargetSlotID = nil
        // 着地もシェルフ内ドロップと同じ動作にする: 共有ゴーストの
        // 所有権をこのシェルフへ引き継ぎ、挿入スロットまで飛ばしてから
        // 実セル(ghostEntryIDで隠してある)と交代する。
        // 元ウィンドウ側のドラッグ状態(draggedID)は、そちらの
        // 終了検知モニタがentriesから消えたことを見て片付ける
        if let index = store.entries.firstIndex(where: { $0.id == entry.id }) {
            ghost.takeOver(owner: shelfID)
            ghostEntryID = entry.id
            flyGhost(toIndex: index)
        }
        return true
    }

    /// ExternalDropOverlayViewのローカル座標→グリッド座標。
    /// オーバーレイはpadding込みのフレーム全体を覆うので、左上
    /// (edgePadding, topPadding)分を引く。グリッドが画面収まりに
    /// クランプされてScrollView内にある場合は、見えている矩形の
    /// 原点(スクロール量)を足して補正する(slotScreenCenterと同じ考え方)
    private func overlayGridPoint(_ p: CGPoint) -> CGPoint {
        // 複数ウィンドウがあるのでkeyWindowではなくこのビューのウィンドウ
        // のスクロールビューを探す(非keyウィンドウへのドラッグでも正しくなる)
        let scrollOffset = Self.findScrollView(in: windowBox.window?.contentView)?
            .documentVisibleRect.origin ?? .zero
        return CGPoint(
            x: p.x - Self.edgePadding + scrollOffset.x,
            y: p.y - Self.topPadding + scrollOffset.y
        )
    }

    /// グリッド座標から挿入位置(対象スロットのindexと直後フラグ)を出す。
    /// セル間のギャップやグリッド範囲外はnil(呼び出し側では末尾扱い)。
    /// セル内の左半分=直前、右半分=直後(セル背面のドロップゾーンと同じ規則)
    private func slotInsertion(atGridPoint g: CGPoint) -> (index: Int, after: Bool)? {
        let settings = store.settings
        let cell = settings.artworkSize.points
        let stepX = cell + Self.columnSpacing
        let stepY = cell + Self.rowSpacing
        guard g.x >= 0, g.y >= 0 else { return nil }
        let column = Int(g.x / stepX)
        let row = Int(g.y / stepY)
        guard column < settings.columns, row < settings.rows else { return nil }
        let intraX = g.x - CGFloat(column) * stepX
        let intraY = g.y - CGFloat(row) * stepY
        // セル間スペーシング上は挿入位置を一意に決められないので対象外
        guard intraX < cell, intraY < cell else { return nil }
        return (row * settings.columns + column, intraX >= cell / 2)
    }

    /// オーバーレイへのドラッグ進入通知。ペーストボードのURLを
    /// parseできたらカタログ取得を先回りして開始し、ドロップ位置を
    /// 選んでいる間にfetchを終わらせる(ドロップ時の待ち時間を消す)。
    /// 登録済み・prefetch済みのidは起動しない
    private func externalDragEntered(url: URL?) {
        guard let url, let parsed = MediaURLParser.parse(url.absoluteString) else {
            Self.logger.notice("external drag entered: no parseable URL, prefetch skipped")
            return
        }
        guard !store.contains(parsed.id) else {
            Self.logger.notice("prefetch skipped: already registered id=\(parsed.id, privacy: .public)")
            return
        }
        guard prefetchedEntries[parsed.id] == nil else {
            Self.logger.debug("prefetch skipped: already in-flight/done id=\(parsed.id, privacy: .public)")
            return
        }
        Self.logger.notice("prefetch start id=\(parsed.id, privacy: .public)")
        prefetchedEntries[parsed.id] = Task {
            do {
                let entry = try await MediaCatalogClient.fetch(parsed)
                _ = try await ShelfStore.downloadArtwork(for: entry)
                return entry
            } catch {
                // 失敗したTaskをdictに残すと、次のドラッグでprefetchが
                // スキップされドロップ時に古いエラーが消費される。
                // 自分で除いておけば次回は新規fetchに戻る
                Self.logger.notice("prefetch failed id=\(parsed.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    prefetchedEntries.removeValue(forKey: parsed.id)
                }
                throw error
            }
        }
    }

    /// オーバーレイ上のホバー通知。ポインタ下のスロットを挿入位置として
    /// 半透明にする(dropTargetSlotIDは既存機構をそのまま利用)。
    /// 高頻度で呼ばれるのでログはスロットが変わったときだけ出す
    private func externalDragMoved(to p: CGPoint) {
        let g = overlayGridPoint(p)
        var slotID: String?
        if let (index, _) = slotInsertion(atGridPoint: g) {
            // indexは列・行の範囲チェック済みなので必ずcapacity未満
            slotID = store.paddedSlots()[index]?.id ?? "empty-\(index)"
        }
        if slotID != dropTargetSlotID {
            Self.logger.debug("external drag hover: grid=(\(g.x, privacy: .public), \(g.y, privacy: .public)) slot=\(slotID ?? "none", privacy: .public)")
            dropTargetSlotID = slotID
        }
    }

    /// オーバーレイのドラッグ終了/離脱通知。挿入位置ハイライトを戻す
    private func externalDragEnded() {
        dropTargetSlotID = nil
    }

    /// オーバーレイへのドロップ。セル上ならその前後、グリッド外
    /// (余白)なら末尾に挿入する
    private func externalDrop(_ url: URL, at p: CGPoint) -> Bool {
        let g = overlayGridPoint(p)
        var insertIndex = Int.max
        var slotID: String?
        if let (index, after) = slotInsertion(atGridPoint: g) {
            insertIndex = index + (after ? 1 : 0)
            // fetch待ちの間このスロットを半透明にしておくためのID
            slotID = store.paddedSlots()[index]?.id ?? "empty-\(index)"
        }
        Self.logger.notice("external overlay drop handled: url=\(url.absoluteString, privacy: .public) grid=(\(g.x, privacy: .public), \(g.y, privacy: .public)) insertIndex=\(insertIndex, privacy: .public) slot=\(slotID ?? "margin", privacy: .public)")
        dropTargetSlotID = nil
        return addDroppedText(url.absoluteString, atIndex: insertIndex, slotID: slotID)
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
            // ゴーストは別ウィンドウなので画面座標のまま追従させる
            self.ghost.move(to: NSEvent.mouseLocation)
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
            // ロード中に別シェルフへのドロップが成立していたら、ゴーストの
            // 所有権はドロップ先にある。ここでshowするとownerを取り戻して
            // 着地フライと追従が衝突するので出さない
            guard self.ghost.owner == nil || self.ghost.owner == self.shelfID else {
                Self.logger.debug("ghost skipped: ownership taken over")
                return
            }
            self.ghostEntryID = entry.id
            let cell = self.store.settings.artworkSize.points
            self.ghost.show(
                image, at: NSEvent.mouseLocation, cell: cell,
                parent: self.windowBox.window, owner: self.shelfID
            )
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
                    self.draggedID = nil
                    // システム画像は不可視なのでスライドバックは自前で:
                    // ゴーストを元のスロットへ滑り戻す。
                    // entriesに無い=別シェルフへの移動が成立済みなので、
                    // 滑り戻す先はなくゴーストを消すだけにする
                    if self.ghostEntryID == cancelledID {
                        if let index = store.entries.firstIndex(where: { $0.id == cancelledID }) {
                            Self.logger.notice("drag cancelled: id=\(cancelledID, privacy: .public)")
                            self.flyGhost(toIndex: index)
                        } else {
                            Self.logger.notice("drag ended: '\(cancelledID, privacy: .public)' moved to another shelf")
                            // ゴーストの所有権がドロップ先へ移っていれば、
                            // 着地アニメーションと後片付けは向こうが行う
                            // (ここで消すと移動先への飛行が途中で切れる)
                            if self.ghost.owner == self.shelfID {
                                self.ghost.hide()
                            }
                            self.ghostEntryID = nil
                        }
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
        let flyingID = self.ghostEntryID
        // スロット中心の画面座標へ飛ばす。変換できなければ今の位置に留める
        let target = self.slotScreenCenter(index: toIndex) ?? NSEvent.mouseLocation
        Self.logger.notice("ghost fly to index=\(toIndex, privacy: .public)")
        self.ghost.fly(to: target) {
            if self.ghostEntryID == flyingID {
                // 飛行中に所有権が別シェルフへ移っていたら、このhideは
                // ドロップ先の着地フライを途中で切ってしまうのでしない
                if self.ghost.owner == self.shelfID {
                    self.ghost.hide()
                } else {
                    Self.logger.debug("ghost hide skipped: ownership taken over by '\(self.ghost.owner ?? "?", privacy: .public)'")
                }
                self.ghostEntryID = nil
            }
        }
    }

    /// index番スロットの中心の画面座標(ゴーストパネルの飛行先用)。
    /// overlayGridPointの逆変換: グリッド座標(左上原点)→ウィンドウ座標
    /// (左下原点)→画面座標。タイトルバー帯の高さはcontentLayoutRectと
    /// frameの差から出す(content.convertの座標変換は
    /// fullSizeContentView構成でYが狂うためframe基準で自分で計算する
    ///  — 2026-10-24実測)。
    /// グリッドがScrollView内にある場合はスクロール量を引いて補正する。
    private func slotScreenCenter(index: Int) -> CGPoint? {
        guard let window = windowBox.window else { return nil }
        let rect = slotRect(index: index)
        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        // ScrollViewはグリッドが画面より大きいときだけ存在する。
        // SwiftUIのスクロールコンテンツはflippedなので、
        // documentVisibleRect.originが左上基準のスクロール量になる。
        let scrollOffset = Self.findScrollView(in: window.contentView)?
            .documentVisibleRect.origin ?? .zero
        return window.convertPoint(toScreen: CGPoint(
            x: rect.midX + Self.edgePadding - scrollOffset.x,
            y: window.frame.height - titlebarHeight - Self.topPadding
                - rect.midY + scrollOffset.y
        ))
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

/// このShelfViewが載っているNSWindowを保持するだけの箱。
/// viewDidMoveToWindow(レイアウト中)に書くため@Publishedにはせず、
/// 読む側は直接プロパティを参照する
private final class WindowBox: ObservableObject {
    weak var window: NSWindow?
}

/// ゴースト(自前ドラッグ画像)の制御窓口。GhostPanelを保持し、
/// 表示/移動/着地アニメーションを命令的に実行する。
/// ドラッグセッションは同時に1つなのでアプリ全体で1個を共有する。
/// シェルフ間ドロップでは、ドロップ先のShelfViewがtakeOverで所有権を
/// 引き継ぎ、自分の着地スロットまで飛ばしてからhideする(=シェルフ内
/// ドロップと同じ手順。元シェルフ側はownerで所有権を判定し、
/// 移譲済みならゴーストに触らない)
private final class GhostController {
    static let shared = GhostController()

    private let panel = GhostPanel()
    /// ゴーストを今管理しているシェルフID(着地/後片付けの担当者)
    private(set) var owner: String?
    /// ポインタ追従を受け付けるか。falseの間はmove()を無視する。
    /// シェルフ間ドロップ後も元シェルフの追従タイマーはモニタが
    /// 止めるまで数十ms動き続けるので、所有権移譲と同時に切る
    /// (切らないと着地フライ中にポインタ位置へ引き戻されてガタつく)
    private var trackingEnabled = false

    /// パネルをparentの子ウィンドウにして表示する。
    /// 子ウィンドウにしておくと元ウィンドウが閉じた/隠れたときに
    /// ゴーストも一緒に消える
    func show(_ image: NSImage, at screenPoint: CGPoint, cell: CGFloat, parent: NSWindow?, owner: String) {
        self.owner = owner
        self.trackingEnabled = true
        if let parent, panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.show(image, at: screenPoint, cell: cell)
    }

    /// ドロップ先シェルフへの所有権移譲。以降のfly/hideはそちらが行う。
    /// パネルは元ウィンドウの子のままだが、画面座標で動くので
    /// どのウィンドウ上でも飛ばせる
    func takeOver(owner: String) {
        self.owner = owner
        self.trackingEnabled = false
    }

    /// ポインタ追従(アニメーションなし、即時)。screenPointは画面座標
    func move(to screenPoint: CGPoint) {
        guard trackingEnabled else { return }
        panel.moveImage(center: screenPoint)
    }

    func fly(to screenPoint: CGPoint, completion: @escaping () -> Void) {
        guard panel.isVisible else {
            completion()
            return
        }
        panel.flyImage(to: screenPoint, completion: completion)
    }

    func hide() {
        owner = nil
        trackingEnabled = false
        panel.hideImage()
    }
}

/// ドラッグ中のジャケットを表示する枠なし透明パネル。
/// ウィンドウ内のオーバーレイViewだとウィンドウ外でクリップされて
/// レコードが消えるため、画面座標で自由に動ける別ウィンドウにする。
/// ignoresMouseEventsなのでドラッグセッションやクリックの邪魔をしない
private final class GhostPanel: NSPanel {
    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")
    /// シャドウ担当(クリップしない)
    private let container = NSView()
    /// 画像担当(角丸4ptでクリップ。セルのジャケットと形を揃える)
    private let imageView = NSImageView()
    private var cellSize: CGFloat = 0

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // 影はcontainerのレイヤで引く(ウィンドウの影だと透明部分にも出る)
        hasShadow = false
        ignoresMouseEvents = true
        // ドラッグ画像相当の高さで常に最前面に出す
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)))
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
        contentView = container
    }

    /// 画面座標centerを中心とするパネルのframe
    private func frame(centeredAt center: CGPoint) -> CGRect {
        CGRect(
            x: center.x - cellSize / 2, y: center.y - cellSize / 2,
            width: cellSize, height: cellSize
        )
    }

    func show(_ image: NSImage, at screenPoint: CGPoint, cell: CGFloat) {
        cellSize = cell
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: CGSize(width: cell, height: cell))
        setFrame(frame(centeredAt: screenPoint), display: false)
        orderFront(nil)
        Self.logger.notice("ghost shown at frame=\(NSStringFromRect(self.frame), privacy: .public)")
    }

    /// ポインタ追従移動(アニメーションなし、即時)
    func moveImage(center: CGPoint) {
        guard isVisible else { return }
        setFrameOrigin(frame(centeredAt: center).origin)
    }

    /// 指定位置まで0.25s easeOutで飛ばし、完了したらcompletionを呼ぶ
    func flyImage(to center: CGPoint, completion: @escaping () -> Void) {
        Self.logger.notice("ghost flyImage: frame before=\(NSStringFromRect(self.frame), privacy: .public) target=\(NSStringFromRect(self.frame(centeredAt: center)), privacy: .public)")
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.animator().setFrameOrigin(self.frame(centeredAt: center).origin)
        }, completionHandler: completion)
    }

    func hideImage() {
        orderOut(nil)
        imageView.image = nil
    }
}

/// 外部アプリからのURLドラッグを受け取る透明NSViewオーバーレイ。
/// SwiftUIの.dropDestinationでは、ドロップ受理時にmacOSが走らせる
/// ドラッグ画像の着地アニメーション(animatesToDestination)を
/// 無効化できず、ソースアプリの画像がドロップ先の隅へ滑って見える。
/// そのため public.url だけを登録するNSDraggingDestinationをグリッド
/// 全体に被せてこちらで受け取り、アニメーションを止める。
/// hitTestは常にnilを返すので通常のクリック/ホバーは下のセルへ素通し
/// されるが、DnDの送り先解決はヒットテストではなくframe登録ベースの
/// ためドロップは届く(GhostOverlayViewと同じ構造)。
/// public.urlのみ登録してあるので、public.plain-textだけを積む
/// アプリ内並び替えドラッグはこのオーバーレイの送り先候補にならない。
private final class ExternalDropOverlayView: NSView {
    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    /// draggingEnteredで呼ぶ(引数はペーストボードから抽出したURL。
    /// 取れなければnil)。ドロップ前にカタログ取得を先回りするために使う
    var onEntered: ((URL?) -> Void)?
    /// draggingEntered/Updatedで呼ぶ(引数はビューローカル座標・左上原点)
    var onHover: ((CGPoint) -> Void)?
    /// draggingExited/concludeDragOperation/draggingEndedで呼ぶ
    var onLeave: (() -> Void)?
    /// performDragOperationで呼ぶ。戻り値がそのまま受理可否になる
    var onDrop: ((URL, CGPoint) -> Bool)?

    override var isFlipped: Bool { true }
    // ドロップ解決はframe登録ベースなのでnilを返してもDnDは届く。
    // 通常のマウスイベントだけ下のセルへ通すためのもの
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.URL])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// draggingLocation(ウィンドウ座標・左下原点)をビューローカルへ。
    /// isFlippedなので変換後はグリッドと同じ左上原点になる
    private func localPoint(_ info: NSDraggingInfo) -> CGPoint {
        convert(info.draggingLocation, from: nil)
    }

    /// ソースが提示する演算のうち受け付けられるものを返す。空なら拒否
    private func offeredOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        let ops = info.draggingSourceOperationMask.intersection([.copy, .link, .generic])
        return ops.isEmpty ? [] : ops
    }

    /// ペーストボードからURLを取り出す。readObjectsで取れない形式が
    /// ある場合に備えて、文字列表現からの解釈も試す
    private func extractURL(from info: NSDraggingInfo) -> URL? {
        let pb = info.draggingPasteboard
        if let url = pb.readObjects(forClasses: [NSURL.self], options: nil)?
            .compactMap({ $0 as? URL }).first {
            return url
        }
        if let text = pb.string(forType: .string) {
            return URL(string: text)
        }
        return nil
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        // Musicアプリ等が実際に何を供給するかの調査も兼ねて毎回記録する
        let types = info.draggingPasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "none"
        Self.logger.notice("external drag entered: types=\(types, privacy: .public)")
        onEntered?(extractURL(from: info))
        onHover?(localPoint(info))
        return offeredOperation(info)
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        onHover?(localPoint(info))
        return offeredOperation(info)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onLeave?()
    }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        // ドロップ先へ画像が滑る着地アニメーションを止める
        // (これが有効だとドロップしたレコード画像が左下へ流れて見える)
        info.animatesToDestination = false
        let p = localPoint(info)
        guard let url = extractURL(from: info) else {
            Self.logger.notice("external overlay drop: no URL in pasteboard point=(\(p.x, privacy: .public), \(p.y, privacy: .public))")
            return false
        }
        Self.logger.notice("external overlay drop: url=\(url.absoluteString, privacy: .public) point=(\(p.x, privacy: .public), \(p.y, privacy: .public))")
        return onDrop?(url, p) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onLeave?()
    }

    // performがfalseやキャンセルでもハイライトが残らないよう念のため
    override func draggingEnded(_ sender: NSDraggingInfo) {
        onLeave?()
    }
}

/// ExternalDropOverlayViewをSwiftUIに載せるための薄いラッパ。
/// コールバックはmake/updateの両方で流し込む(再評価で最新の
/// クロージャに差し替える)
private struct ExternalDropOverlayRep: NSViewRepresentable {
    var onEntered: (URL?) -> Void
    var onHover: (CGPoint) -> Void
    var onLeave: () -> Void
    var onDrop: (URL, CGPoint) -> Bool

    func makeNSView(context: Context) -> ExternalDropOverlayView {
        let view = ExternalDropOverlayView()
        view.onEntered = onEntered
        view.onHover = onHover
        view.onLeave = onLeave
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ nsView: ExternalDropOverlayView, context: Context) {
        nsView.onEntered = onEntered
        nsView.onHover = onHover
        nsView.onLeave = onLeave
        nsView.onDrop = onDrop
    }
}

/// シェルフの1枚分。ホバーで再生/停止アイコンを表示する。
private struct AlbumSlotView: View {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    let entry: MediaEntry

    /// このセルが属するシェルフのストア(アートワークサイズと
    /// artworkRevision(ダウンロード完了)の検知用)
    @ObservedObject var store: ShelfStore
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
