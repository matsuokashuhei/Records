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
    /// 外部ドラッグ中のアルバム/プレイリストID。アートワークの非同期
    /// 読み込みが終わった時点で「まだ同じドラッグをホバーしているか」を
    /// 判定するために持つ(離れた後にモーフィングすると画像が残る)
    @State private var externalHoverID: String?
    /// ドラッグ画像のモーフィングをオーバーレイのNSViewへ命令する窓口。
    /// SwiftUIの状態としてNSViewを直接持たず、weak参照の箱を介する
    @State private var overlayHandle = ExternalDropOverlayHandle()
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
    /// 右クリック(コンテキストメニュー)用のイベントモニタ。
    /// SwiftUIの.contextMenuはセルの.onTapGestureと競合してレコード上で
    /// 開かないため、AppKit側で拾ってメニューを出し分ける(2026-10-25実測)
    @State private var contextMenuMonitor: Any?
    /// タイトルバー(信号ボタン)と右上ツールバーの自動表示。
    /// アクティブなウィンドウでマウスが動いたら表示し、3秒動かなければ隠す
    @StateObject private var chrome = ChromeVisibilityController()
    /// マウス移動/クリックを拾ってchrome.noteActivity()するモニタ
    @State private var activityMonitor: Any?
    /// 出しているコンテキストメニューのNSMenuItem.target(クロージャ保持用)。
    /// NSMenuItem.targetは保持されないので、メニューが閉じるまで生かしておく
    @State private var contextMenuTargets: [ContextMenuAction] = []
    /// メニューの開閉通知(NSMenu.didBeginTracking/didEndTracking)の監視。
    /// 開いている間はchromeを自動で隠さないようにする
    @State private var menuTrackingObservers: [NSObjectProtocol] = []
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
            // タイトルバー帯のセーフエリアを無視してウィンドウ上端まで
            // コンテンツを広げる。信号ボタンはガラス/ジャケットの上に
            // 重なって表示される(Musicアプリのミニプレーヤーと同じ構成)
            .ignoresSafeArea()
            // .windowResizability(.contentSize)は「ビューの理想サイズ+
            // セーフエリア(タイトルバー帯32pt)」でウィンドウを作るため、
            // そのままではウィンドウだけが32pt高くなり下側に余白が残る
            // (2026-10-25実測)。理想サイズから帯の分を差し引いてウィンドウと
            // グリッドの高さを一致させる。なお描画とヒットテストは下の
            // shelfGrid側のフレーム(実際のグリッド高)がそのまま使われる
            .padding(.bottom, -Self.titlebarInset)
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
        // アラート(削除確認など)を出している間はchromeを自動で隠さない
            .onChange(of: hasModalAlert) { _, active in
                chrome.setHold("alert", active: active)
            }
        // 再生状態はAlbumSlotViewが個別にmonitorを監視するので、ここでは監視せず
        // 開始/停止だけ行う(画面全体の2秒おき再描画を避ける)。
        // 複数ウィンドウあるので監視は参照カウント式(片方が閉じても他方で継続)
            .onAppear {
                PlaybackMonitor.shared.start()
                installContextMenuMonitor()
                installActivityMonitor()
                installMenuTrackingMonitor()
                // 検証用: `--chrome-preview` で起動すると1.5秒後にツールバー/
                // 信号ボタンを強制表示する(UIを目視できないエージェントが
                // スクリーンショットで見た目を確認するための経路。--catalog-testと
                // 同じ扱い)。通常のマウス移動と同じく3秒で自動的に隠れる
                if ProcessInfo.processInfo.arguments.contains("--chrome-preview") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        // 複数シェルフがある場合はプライマリのウィンドウだけを対象にする
                        guard self.shelfID == ShelfManager.shared.primaryShelfID,
                              let window = self.windowBox.window else { return }
                        NSApp.activate()
                        window.makeKeyAndOrderFront(nil)
                        self.chrome.setActive(true)
                        self.chrome.noteActivity()
                        Self.logger.notice("chrome preview: forced visible")
                    }
                }
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
                if let contextMenuMonitor {
                    NSEvent.removeMonitor(contextMenuMonitor)
                    self.contextMenuMonitor = nil
                }
                if let activityMonitor {
                    NSEvent.removeMonitor(activityMonitor)
                    self.activityMonitor = nil
                }
                menuTrackingObservers.forEach { NotificationCenter.default.removeObserver($0) }
                menuTrackingObservers = []
                if !isDuplicateWindow {
                    ShelfManager.shared.noteWindowClosed(shelfID)
                }
            }
    }

    /// 確認/エラー系のアラートを出しているか(chromeの自動非表示を止める条件)
    private var hasModalAlert: Bool {
        pendingDelete != nil || pendingShelfDelete || addError != nil
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
    // 四辺すべて同じ余白。コンテンツはignoresSafeAreaでウィンドウ上端まで
    // 広がっている(信号ボタンはMusicアプリ同様にコンテンツの上へ重なる)
    private static let edgePadding: CGFloat = 8
    private static let topPadding: CGFloat = 8
    /// 右上ツールバーの余白とサイズ。信号ボタン(左上13pt, 14pt)の中心
    /// (20pt)と高さを揃えるため、上8pt・高さ24ptにしている
    /// (中心 = 8 + 24/2 = 20)。右の余白はMusic実測14pt+4pt
    private static let toolbarTopInset: CGFloat = 8
    private static let toolbarTrailingInset: CGFloat = 18
    private static let toolbarHeight: CGFloat = 24
    private static let toolbarButtonWidth: CGFloat = 37
    /// タイトルバー帯(hiddenTitleBar)の高さ。SwiftUIはウィンドウサイズを
    /// 「ビューの理想サイズ+このセーフエリア」で決めるため、理想サイズ側で
    /// 差し引いてウィンドウの下に余白が残るのを防ぐ。実寸は
    /// WindowConfigurator.logMetricsが titlebarInset として記録する
    private static let titlebarInset: CGFloat = 32
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
        // この固定フレームがそのままmin=maxのウィンドウサイズになる
        // (コンテンツは上端まで広がるので、四辺の余白は8ptずつ)。
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
        // タイトルバーを隠してコンテンツを上端まで広げたため、AppKitの
        // タイトルバー(=ウィンドウ移動)のドラッグ領域が無くなる。
        // 上辺の余白(8pt)をつかんでウィンドウを動かせるようにする
        // (Musicアプリのミニプレーヤーと同じ「余白をつかんで移動」)
        .overlay(alignment: .top) {
            Color.clear
                .frame(height: Self.topPadding)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
        // 右上のシェルフ操作ツールバー(Musicアプリのウィンドウ右上と同じ
        // 「共有+3点リーダー」のカプセル)。シェルフ操作メニューは空きスロットの
        // 右クリックではなくここに集約する
        .overlay(alignment: .topTrailing) {
            shelfToolbar
        }
        // 外部URLドラッグ専用の透明オーバーレイ(NSDraggingDestination)。
        // .dropDestinationでは止められない着地アニメーション
        // (animatesToDestination)をこちらで止めるため、public.urlを
        // 持つ外部ドラッグはこのビューが先に受け取る。hitTest=nilで
        // クリックはセルへ素通し。余白含むフレーム全体をカバーする。
        // 内部ドラッグはplain-textのみなのでこのオーバーレイは候補外。
        .overlay {
            ExternalDropOverlayRep(
                handle: overlayHandle,
                shelfID: shelfID,
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
        // クランプ状態の遷移時だけログ(body評価のたびに出るのを防ぐ)。
        // onAppearではレイアウト検証用に計算結果(グリッドの実寸と窓の関係)を1回出す
        .onAppear {
            Self.logger.notice("grid layout: cell=\(cell, privacy: .public) columns=\(columnCount, privacy: .public) rows=\(rowCount, privacy: .public) frame=\(Int(frameW), privacy: .public)x\(Int(frameH), privacy: .public) natural=\(Int(width), privacy: .public)x\(Int(height), privacy: .public)")
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
                onBecameKey: { ShelfManager.shared.shelfWindowBecameKey(self.store) },
                onActiveChanged: { active in
                    self.chrome.setActive(active)
                    Self.logger.notice("window active changed: \(active, privacy: .public) shelf=\(self.shelfID, privacy: .public)")
                },
                showTrafficLights: chrome.isVisible
            )
        }
    }

    /// 右クリックメニューを出す。SwiftUIの`.contextMenu`は
    /// セルの`.onTapGesture`と競合してレコード上で開かなくなるため
    /// (2026-10-25実測)、ウィンドウへの右クリックを直接拾っている。
    /// メニューを出すのは**レコードの上だけ**。空きスロット・レコード間の
    /// 隙間・余白はシェルフ操作を右上の3点リーダーへ集約したので何も出さない
    private func showDeleteMenu(for entry: MediaEntry, event: NSEvent, in window: NSWindow) {
        Self.logger.notice("context menu requested: entry='\(entry.title, privacy: .public)' shelf=\(self.shelfID, privacy: .public)")

        let target = ContextMenuAction {
            Self.logger.notice("delete requested for '\(entry.title, privacy: .public)' id=\(entry.id, privacy: .public)")
            // メニューの入れ子イベントループ中にシートを出さないよう一段ずらす
            DispatchQueue.main.async { self.pendingDelete = entry }
        }
        let item = NSMenuItem(
            title: String(localized: "Delete Record"),
            action: #selector(ContextMenuAction.invoke),
            keyEquivalent: ""
        )
        item.target = target
        item.attributedTitle = NSAttributedString(
            string: item.title,
            attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.menuFont(ofSize: 0)
            ]
        )
        let menu = NSMenu()
        menu.items = [item]
        // NSMenuItem.targetは保持されないので、メニューが閉じるまで
        // contextMenuTargets(@Stateの配列)で生かしておく
        contextMenuTargets.append(target)
        defer { contextMenuTargets.removeAll() }
        NSMenu.popUpContextMenu(menu, with: event, for: window.contentView ?? NSView())
    }

    /// グリッド座標にあるレコード。隙間・余白・空きスロットはnil
    private func entry(atGridPoint point: CGPoint) -> MediaEntry? {
        guard let (index, _) = slotInsertion(atGridPoint: point) else { return nil }
        let slots = store.paddedSlots()
        guard slots.indices.contains(index) else { return nil }
        return slots[index]
    }

    /// イベント位置にあるレコード(ウィンドウ座標→グリッド座標)
    private func entry(at event: NSEvent, in window: NSWindow) -> MediaEntry? {
        let topLeft = CGPoint(
            x: event.locationInWindow.x,
            y: window.frame.height - event.locationInWindow.y
        )
        return entry(atGridPoint: overlayGridPoint(topLeft))
    }

    /// ウィンドウの右クリックを拾ってレコードのメニューを出すモニタ。
    /// 信号ボタン・右上ツールバーの上はクロームに任せ、Ctrl+クリックも
    /// メニューとして扱う(通常の左クリック=再生/停止はそのまま)
    private func installContextMenuMonitor() {
        if let contextMenuMonitor {
            NSEvent.removeMonitor(contextMenuMonitor)
        }
        contextMenuMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown, .leftMouseDown]
        ) { event in
            guard let window = self.windowBox.window, event.window === window else { return event }
            if event.type == .leftMouseDown, !event.modifierFlags.contains(.control) {
                return event
            }
            if self.isOverChrome(event, in: window) { return event }
            // レコードの上だけメニュー(空きスロット・余白は何も出さない)
            guard let entry = self.entry(at: event, in: window) else { return event }
            self.showDeleteMenu(for: entry, event: event, in: window)
            return nil
        }
    }

    /// メニューの開閉を拾ってchromeの自動非表示を止める。
    /// 3点リーダーのメニューや右クリックメニューを開いたまま3秒経つと
    /// カプセル/信号ボタンごと消えてしまうため、開いている間は隠さない
    /// (SwiftUIのMenuもNSMenuなのでdidBeginTracking/didEndTrackingが来る)
    private func installMenuTrackingMonitor() {
        menuTrackingObservers.forEach { NotificationCenter.default.removeObserver($0) }
        let center = NotificationCenter.default
        menuTrackingObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
                self.chrome.setHold("menu", active: true)
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
                self.chrome.setHold("menu", active: false)
            }
        ]
    }

    /// マウス移動/クリック/スクロールを拾ってツールバーの自動表示を駆動する。
    /// ウィンドウはacceptsMouseMovedEvents=trueにしてあるので
    /// mouseMovedがここへ届く(WindowConfigurator.configure)
    private func installActivityMonitor() {
        if let activityMonitor {
            NSEvent.removeMonitor(activityMonitor)
        }
        activityMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { event in
            guard let window = self.windowBox.window, event.window === window else { return event }
            self.chrome.noteActivity()
            return event
        }
    }

    /// 信号ボタン(タイトルバー)か右上ツールバーの上か。
    /// どちらもクローム自身が操作を持つので、右クリックメニューの対象外にする
    /// (レコードの上だけでメニューを出す規則の一部)
    private func isOverChrome(_ event: NSEvent, in window: NSWindow) -> Bool {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), !button.isHidden else { continue }
            if button.convert(button.bounds, to: nil).contains(event.locationInWindow) {
                return true
            }
        }
        // 右上ツールバーはSwiftUIのビューでNSViewの矩形を持たないため、
        // ShelfViewのレイアウト定数からカプセルの矩形を組み立てる
        // (上8pt / 右18pt / 高さ24pt / 幅=ボタン2つ分)。表示中のみ有効
        guard chrome.isVisible else { return false }
        let capsule = CGRect(
            x: window.frame.width - Self.toolbarTrailingInset - Self.toolbarButtonWidth * 2,
            y: window.frame.height - Self.toolbarTopInset - Self.toolbarHeight,
            width: Self.toolbarButtonWidth * 2,
            height: Self.toolbarHeight
        )
        return capsule.contains(event.locationInWindow)
    }

    /// 右上に浮かぶシェルフ操作ツールバー。Musicアプリのウィンドウ右上と
    /// 同じ「共有+3点リーダー」のカプセル。
    /// - 共有: 表示のみ(実装は別途)
    /// - 3点リーダー: New Shelf / Settings… / Delete Shelf…
    /// 信号ボタンと同じく、ウィンドウが非アクティブの間は隠す
    private var shelfToolbar: some View {
        HStack(spacing: 0) {
            Button {
                Self.logger.notice("share button tapped: shelf=\(self.shelfID, privacy: .public) (not implemented yet)")
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: Self.toolbarButtonWidth, height: Self.toolbarHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(Text("Share"))

            Menu {
                Button("New Shelf") {
                    Self.logger.notice("new shelf requested via toolbar menu")
                    let id = ShelfManager.shared.createShelf()
                    openWindow(id: "shelf", value: id)
                }
                Button("Settings…") {
                    Self.logger.notice("settings open requested: shelf=\(self.shelfID, privacy: .public)")
                    // 設定画面は「最後にキーになったシェルフ」を編集する
                    ShelfManager.shared.shelfWindowBecameKey(store)
                    openWindow(id: "settings")
                }
                Divider()
                Button("Delete Shelf…", role: .destructive) {
                    Self.logger.notice("shelf delete requested: \(self.shelfID, privacy: .public)")
                    pendingShelfDelete = true
                }
                .disabled(manager.shelfIDs.count <= 1)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: Self.toolbarButtonWidth, height: Self.toolbarHeight)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusable(false)
            .help(Text("Shelf Options"))
        }
        // アイコンはMusicアプリ同様の白。ガラスを少し暗く染めて、
        // 明るいジャケットの上でも白アイコンのコントラストを保つ
        .foregroundStyle(.white)
        // macOS 26のLiquid Glass。ウィンドウ端のカプセルとして浮かせる。
        // GlassEffectContainerは使わない: 隣接して融合させたいガラスが
        // 離れた位置(左上と右上)にあり、片方はAppKitのNSGlassEffectViewで
        // レイヤーが別なので、まとめる意味がない
        .glassEffect(.regular.tint(.black.opacity(0.45)).interactive(), in: Capsule())
        .padding(.top, Self.toolbarTopInset)
        .padding(.trailing, Self.toolbarTrailingInset)
        .opacity(chrome.isVisible ? 1 : 0)
        .allowsHitTesting(chrome.isVisible)
        .animation(.easeInOut(duration: 0.15), value: chrome.isVisible)
    }

    /// ウィンドウが画面からはみ出さないためのコンテンツサイズ上限。
    /// NSScreen.main.visibleFrame から安全マージンを引いた値。
    /// スクリーン情報が取れない場合はクランプしない。
    private static func maxContentSize() -> CGSize {
        guard let visible = NSScreen.main?.visibleFrame else {
            return CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        let safety: CGFloat = 16
        // コンテンツはタイトルバー帯の下まで広がる(fullSizeContentView)ため
        // ウィンドウ高=コンテンツ高。タイトルバー分の控除は要らない
        return CGSize(
            width: max(320, visible.width - safety * 2),
            height: max(240, visible.height - safety * 2)
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
    /// 同時にドラッグ画像をこのシェルフのレコードサイズへモーフィングする。
    /// 登録済み・prefetch済みのidはfetchを起動しない
    private func externalDragEntered(url: URL?) {
        guard let url, let parsed = MediaURLParser.parse(url.absoluteString) else {
            externalHoverID = nil
            Self.logger.notice("external drag entered: no parseable URL, prefetch/morph skipped")
            return
        }
        externalHoverID = parsed.id
        // モーフィングは重複ガードより先に起動すること。後ろに置くと
        // 登録済みレコードをドラッグした2回目以降で画像がリサイズされない
        prefetchIfNeeded(parsed)
        morphDragImage(for: parsed.id)
    }

    /// カタログ取得+アートワーク取得の先回り。登録済み・取得中/取得済みは
    /// 何もしない(ドロップ時はprefetchedEntriesの結果を再利用する)
    private func prefetchIfNeeded(_ parsed: MediaURLParser.Parsed) {
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

    /// ドラッグ画像をこのシェルフのレコードサイズへモーフィングする。
    /// ジャケットはキャッシュ/ディスクから読むので非同期。読み込み中に
    /// ドラッグが離れた・別のレコードに変わった場合は何もしない
    private func morphDragImage(for id: String) {
        let cell = store.settings.artworkSize.points
        Task { @MainActor in
            guard let image = await self.dragImage(for: id) else {
                Self.logger.notice("drag image morph skipped: artwork unavailable id=\(id, privacy: .public)")
                return
            }
            guard self.externalHoverID == id else {
                Self.logger.debug("drag image morph skipped: hover changed id=\(id, privacy: .public)")
                return
            }
            // モーフィング開始のログはオーバーレイ側(morphTo)が
            // id・元サイズ・目標サイズを1行で出す(重複ログを避ける)
            self.overlayHandle.morphTo(image: image, id: id, size: cell)
        }
    }

    /// モーフィングに使うジャケット画像。登録済みならそのアートワーク、
    /// 未登録なら先回り取得の結果(取得完了まで待つ)から読む。
    /// 取得できなければnil(モーフィングしない=Musicの画像のまま)
    private func dragImage(for id: String) async -> NSImage? {
        if let entry = store.entries.first(where: { $0.id == id }) {
            return await ShelfStore.artworkImage(for: entry)
        }
        guard let prefetch = prefetchedEntries[id],
              let entry = try? await prefetch.value else { return nil }
        return await ShelfStore.artworkImage(for: entry)
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

    /// オーバーレイのドラッグ終了/離脱通知。挿入位置ハイライトと
    /// ホバー中のIDを戻す(自前パネルはオーバーレイ側で片付ける)
    private func externalDragEnded() {
        dropTargetSlotID = nil
        externalHoverID = nil
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
    /// (左下原点)→画面座標。コンテンツはignoresSafeAreaでウィンドウ上端まで
    /// 広がっているため、グリッドの上端=ウィンドウ上端
    /// (content.convertの座標変換はfullSizeContentView構成でYが狂うため
    ///  frame基準で自分で計算する — 2026-10-24実測)。
    /// グリッドがScrollView内にある場合はスクロール量を引いて補正する。
    private func slotScreenCenter(index: Int) -> CGPoint? {
        guard let window = windowBox.window else { return nil }
        let rect = slotRect(index: index)
        // ScrollViewはグリッドが画面より大きいときだけ存在する。
        // SwiftUIのスクロールコンテンツはflippedなので、
        // documentVisibleRect.originが左上基準のスクロール量になる。
        let scrollOffset = Self.findScrollView(in: window.contentView)?
            .documentVisibleRect.origin ?? .zero
        return window.convertPoint(toScreen: CGPoint(
            x: rect.midX + Self.edgePadding - scrollOffset.x,
            y: window.frame.height - Self.topPadding
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

    /// サイズを変えて中心を合わせ直す(外部ドラッグのモーフィング用)。
    /// screenPointは画面座標
    func resize(to cell: CGFloat, at screenPoint: CGPoint) {
        guard trackingEnabled else { return }
        panel.resize(cell: cell, centeredAt: screenPoint)
    }

    /// パネルの現在のframe(ログ用)
    var panelFrame: CGRect { panel.frame }

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
        // 非アクティブ(外部アプリのドラッグ中)でも必ず前面に出す
        orderFrontRegardless()
        Self.logger.notice("ghost shown at frame=\(NSStringFromRect(self.frame), privacy: .public)")
    }

    /// ポインタ追従移動(アニメーションなし、即時)
    func moveImage(center: CGPoint) {
        guard isVisible else { return }
        setFrameOrigin(frame(centeredAt: center).origin)
    }

    /// サイズを変えて中心を合わせ直す(外部ドラッグのモーフィング用)
    func resize(cell: CGFloat, centeredAt center: CGPoint) {
        guard isVisible else { return }
        cellSize = cell
        imageView.frame = CGRect(origin: .zero, size: CGSize(width: cell, height: cell))
        setFrame(frame(centeredAt: center), display: true)
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
///
/// あわせて、ドラッグ中の画像を「ドロップ可能になった時点」で
/// このシェルフのレコードサイズへモーフィングする(Musicアプリが
/// ウィンドウの内外でドラッグ画像の大きさを変えるのと同じ体験)。
/// 実装は「システムのドラッグ画像を隠し、自前のパネル(GhostPanel)で
/// セルサイズぴったりに描く」方式。setDraggingFrameで大きさを変える
/// 方法は実測で駄目だった: 指定値を233ptにしても432ptにしても、
/// 実際の描画は元画像と同じ約128pt角のまま(frameは変わるが描画が
/// 従わない。contentsの差し替えだけは反映される — 2026-10-25実測)。
/// 自前パネルならウィンドウ内ドラッグと同じ描画・同じ角丸・同じ影で、
/// サイズもアニメーションも完全に制御できる。
private final class ExternalDropOverlayView: NSView {
    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    /// モーフィングの所要時間(秒)
    private static let morphDuration: CFTimeInterval = 0.2

    /// このオーバーレイが属するシェルフID(自前パネルの所有権判定に使う)
    var shelfID: String = ""

    /// draggingEnteredで呼ぶ(引数はペーストボードから抽出したURL。
    /// 取れなければnil)。ドロップ前にカタログ取得を先回りするために使う
    var onEntered: ((URL?) -> Void)?
    /// draggingEntered/Updatedで呼ぶ(引数はビューローカル座標・左上原点)
    var onHover: ((CGPoint) -> Void)?
    /// draggingExited/concludeDragOperation/draggingEndedで呼ぶ
    var onLeave: (() -> Void)?
    /// performDragOperationで呼ぶ。戻り値がそのまま受理可否になる
    var onDrop: ((URL, CGPoint) -> Bool)?

    // MARK: ドラッグ画像のモーフィング状態

    /// 進行中のドラッグのinfo。セッション中だけ有効なので、終了経路
    /// (draggingExited/concludeDragOperation/draggingEnded)では
    /// 必ず同期的にnilへ戻す。NSDraggingItem/NSDraggingImageComponentは
    /// 列挙ブロックの外で保持してはいけない(寿命がブロック内だけで、
    /// 後から触るとクラッシュする)ので、保持するのはこのinfoと、
    /// 数値(フレーム)とNSImageだけにする
    private var currentInfo: NSDraggingInfo?
    /// 進入時点の先頭アイテムのフレーム(退出時の復元サイズと、
    /// モーフィング開始時の元サイズに使う。復元の各アイテムの位置は
    /// 再列挙してその場のdraggingFrameから出すので保持しない)。
    /// Musicのアルバム/プレイリストは単一アイテム前提
    private var originalFrame: CGRect?
    /// モーフィングに使うジャケット画像(ShelfViewが読み込んで渡す)
    private var morphImage: NSImage?
    /// モーフィングの目標サイズ(1辺・pt)。nil=モーフィングしていない
    private var morphTargetSide: CGFloat?
    /// アニメーション開始時のサイズ(1辺・pt)と開始時刻
    private var morphStartSide: CGFloat = 0
    private var morphStartTime: CFTimeInterval = 0
    /// 自前パネルのサイズ補間とポインタ追従を回す60fpsタイマー
    private var morphTimer: Timer?
    /// システムのドラッグ画像を隠したか(退出時に戻すため)
    private var systemImageHidden = false
    /// 元のドラッグ画像の中心がポインタからどれだけずれているか(画面座標)。
    /// パネルを同じ位置に出すことで、切り替わり時のジャンプを防ぐ
    private var panelCenterOffset: CGSize = .zero
    /// 自前パネルを表示済みか。同じセッションで二重にshowしないための
    /// ガードで、morphToは状態を代入する前にこれを見る
    private var panelShown = false
    /// 最後にdraggingEntered/Updatedを受けた時刻。ドラッグ終了通知が
    /// 来ない経路(Escape等)に備えたウォッチドッグ用
    private var lastDragActivityTime: CFTimeInterval = 0
    /// 直前のtickで見たポインタ位置(静止中でも動きを検知するため)
    private var lastTickMouseLocation: CGPoint = .zero
    /// パネルを出したままにする最大時間(秒)。終了通知が来なくても
    /// ここを超えたら片付ける(ジャケットが画面に残り続けるのを防ぐ)
    private static let panelWatchdogTimeout: CFTimeInterval = 60

    override var isFlipped: Bool { true }
    // ドロップ解決はframe登録ベースなのでnilを返してもDnDは届く。
    // 通常のマウスイベントだけ下のセルへ通すためのもの
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.URL])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// ドラッグ中にウィンドウが閉じた/このビューがウィンドウから外れた場合は
    /// 終了通知(draggingExited/conclude/draggingEnded)が来ないので、ここで
    /// セッションを片付ける。放置すると GhostController.owner に shelfID が
    /// 残り、以後のウィンドウ内ドラッグでゴーストが出なくなる。
    /// 別ウィンドウへの移動・タブ移動は newWindow != nil なので誤発火しない
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil,
              currentInfo != nil || morphTimer != nil || panelShown else { return }
        Self.logger.notice("external drop view removed from window: ending drag session")
        endSession(restoreImage: false, reason: "viewRemoved")
    }

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

    // MARK: - モーフィング(自前パネル)

    /// ドラッグ画像を1辺size(pt)の正方形へ0.2秒easeOutでモーフィングする。
    /// ジャケット画像の読み込みが終わったShelfViewから呼ぶ。
    /// システムのドラッグ画像は隠し、GhostPanel(ウィンドウ内ドラッグと
    /// 同じ描画)でこのシェルフのレコードサイズに描く。
    /// Musicのアルバム/プレイリストは単一アイテム前提で、サイズ・位置は
    /// item[0]に合わせる(複数アイテムのドラッグでも先頭基準で扱う)
    func morphTo(image: NSImage, id: String, size: CGFloat) {
        guard currentInfo != nil else {
            Self.logger.notice("drag image morph ignored: no active external drag id=\(id, privacy: .public)")
            return
        }
        // システムのドラッグ画像を列挙できなかった場合は、隠すことも
        // 元の大きさ(と中心のずれ)を知ることもできない。その状態で
        // 自前パネルを出すと画像が二重に見えるのでモーフィングしない
        guard let originalFrame else {
            Self.logger.notice("drag image morph skipped: no enumerable dragging items id=\(id, privacy: .public)")
            return
        }
        // 1セッション1モーフ(morphToはdraggingEntered経由でしか呼ばない)。
        // このガードは状態の代入より前に置くこと: 後ろに置くと2回目の
        // 呼び出しで開始サイズが元サイズへ巻き戻り、次tickから
        // 「一瞬縮んで再モーフ」する
        guard !panelShown else { return }
        // 元画像の大きさ(=システムが描いていた大きさ)から始める
        let original = max(originalFrame.width, originalFrame.height)
        morphImage = image
        morphTargetSide = size
        morphStartSide = original
        morphStartTime = CACurrentMediaTime()
        Self.logger.notice("drag image morph: id=\(id, privacy: .public) \(original, privacy: .public)pt -> \(size, privacy: .public)pt")
        hideSystemImage()
        GhostController.shared.show(
            image,
            at: panelCenter(),
            cell: original,
            parent: window,
            owner: shelfID
        )
        panelShown = true
        // ドラッグ中はイベントトラッキングモードなので.commonで登録する
        // (defaultモードでは発火しない)。補間が終わった後もポインタ追従の
        // ためにドラッグ終了まで回し続ける
        if morphTimer == nil {
            // ビューが先に破棄された場合、RunLoopがタイマーを保持したまま
            // 空回りし続けるので、自分でinvalidateして止める
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.morphTick()
            }
            RunLoop.main.add(timer, forMode: .common)
            morphTimer = timer
        }
    }

    /// パネルの中心にしたい画面座標。元のドラッグ画像の中心とポインタの
    /// ずれを保ったまま追従させる(ビュー座標は上下反転なのでYは符号反転)
    private func panelCenter() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        return CGPoint(
            x: mouse.x + panelCenterOffset.width,
            y: mouse.y - panelCenterOffset.height
        )
    }

    /// システムのドラッグ画像を隠す(contents=nilで非表示になる)。
    /// これをしないと自前パネルと二重に見える
    private func hideSystemImage() {
        guard !systemImageHidden, let info = currentInfo else { return }
        systemImageHidden = true
        info.enumerateDraggingItems(
            options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]
        ) { item, _, _ in
            item.setDraggingFrame(item.draggingFrame, contents: nil)
        }
        Self.logger.notice("system drag image hidden: showing own panel")
    }

    /// 60fpsのtick。サイズをeaseOut(1-(1-t)^3)で補間しつつ、
    /// パネルをポインタ位置へ追従させる。補間が終わった後はサイズ変更が
    /// 不要なので、原点移動だけにして毎tickの画像再設定を避ける
    private func morphTick() {
        guard currentInfo != nil, let target = morphTargetSide else {
            stopMorphTimer()
            return
        }
        // ポインタが動いていればセッションは生きているとみなす
        // (draggingUpdatedは静止中に来ないため)
        let mouse = NSEvent.mouseLocation
        if mouse != lastTickMouseLocation {
            lastTickMouseLocation = mouse
            lastDragActivityTime = CACurrentMediaTime()
        }
        // 終了通知が来ない経路の保険。一定時間やり取りが無ければ片付ける。
        // ただしボタンが押されたままならドラッグは生きている(ポインタが
        // 静止しているだけ)ので、その場合は片付けない — 片付けると
        // 隠したシステム画像が戻らずドラッグ中に画像が消えたままになる。
        // 発火時は restoreImage: false(生きたドラッグだった場合に画像が
        // 隠れたままになるのは承知の上。終了済みの NSDraggingInfo を
        // 触る危険を避けるため復元はしない)
        if NSEvent.pressedMouseButtons == 0,
           CACurrentMediaTime() - lastDragActivityTime > Self.panelWatchdogTimeout {
            Self.logger.notice("drag panel watchdog fired: no drag activity for \(Self.panelWatchdogTimeout, privacy: .public)s")
            endSession(restoreImage: false, reason: "watchdog")
            return
        }
        // 追従の中心はモーフィング中も完了後も同じ計算を使う
        let center = panelCenter()
        // 補間済み(morphStartSide==target)。サイズは変えず原点だけ動かす
        if morphStartSide == target {
            GhostController.shared.move(to: center)
            return
        }
        let elapsed = CACurrentMediaTime() - morphStartTime
        let progress = min(1, elapsed / Self.morphDuration)
        guard progress < 1 else {
            // 最終tickは目標サイズぴったりで確定させる
            GhostController.shared.resize(to: target, at: center)
            morphStartSide = target
            Self.logger.notice("morph done: panel size=\(target, privacy: .public) frame=\(NSStringFromRect(GhostController.shared.panelFrame), privacy: .public)")
            return
        }
        let eased = 1 - pow(1 - progress, 3)
        let side = morphStartSide + (target - morphStartSide) * CGFloat(eased)
        GhostController.shared.resize(to: side, at: center)
    }

    private func stopMorphTimer() {
        morphTimer?.invalidate()
        morphTimer = nil
    }

    // MARK: - セッション

    /// ドラッグ進入時。アイテム構成を記録し、退出時に戻せるよう
    /// 先頭アイテムのフレームを控える(itemsはこのブロック内だけで触る)。
    /// あわせて元画像の中心とポインタのずれを求めておく
    private func beginSession(_ info: NSDraggingInfo) {
        currentInfo = info
        originalFrame = nil
        morphImage = nil
        morphTargetSide = nil
        morphStartSide = 0
        systemImageHidden = false
        panelShown = false
        // 前のセッションのずれを引き継がない(アイテムを列挙できなかった
        // ときに古いオフセットでパネルが出るのを防ぐ)
        panelCenterOffset = .zero
        var index = 0
        info.enumerateDraggingItems(
            options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]
        ) { item, _, _ in
            // サイズ・位置の基準は先頭アイテムだけ(複数アイテムのときは
            // item[0]に合わせる。Musicのアルバム/プレイリストは単一前提)
            if index == 0 {
                let frame = item.draggingFrame
                self.originalFrame = frame
                let cursor = self.localPoint(info)
                self.panelCenterOffset = CGSize(
                    width: frame.midX - cursor.x,
                    height: frame.midY - cursor.y
                )
            }
            index += 1
        }
        Self.logger.notice("drag image source: items=\(index, privacy: .public) firstFrame=\(self.originalFrame.map(NSStringFromRect) ?? "none", privacy: .public) offset=(\(self.panelCenterOffset.width, privacy: .public), \(self.panelCenterOffset.height, privacy: .public))")
    }

    /// ドラッグセッション終了。タイマーを止め、状態を同期的に片付ける
    /// (currentInfoをnilにした後にtickが古いinfoを触ると危険なので、
    /// タイマー停止→パネル片付け→復元→クリアの順で行う)。
    /// restoreImage=trueのとき、隠したシステム画像を元の大きさに近い
    /// 正方形で戻す(ウィンドウ外へ出たときに画像が消えないように)。
    /// Music本来の画像には戻せない(contentsがNSImageではない)ため、
    /// 最後のジャケットを元サイズで表示する。
    /// 複数アイテムのドラッグでも、サイズはitem[0]基準の1辺を全アイテムに
    /// 同じ画像・同じサイズで適用する(Musicは単一アイテム前提)
    private func endSession(restoreImage: Bool, reason: String) {
        stopMorphTimer()
        if GhostController.shared.owner == shelfID {
            GhostController.shared.hide()
        }
        panelShown = false
        defer {
            currentInfo = nil
            originalFrame = nil
            morphImage = nil
            morphTargetSide = nil
            morphStartSide = 0
            systemImageHidden = false
        }
        guard restoreImage,
              systemImageHidden,
              let info = currentInfo,
              let image = morphImage,
              let originalFrame else {
            Self.logger.debug("drag session end (\(reason, privacy: .public)): panel hidden, no restore")
            return
        }
        let side = max(originalFrame.width, originalFrame.height)
        var index = 0
        info.enumerateDraggingItems(
            options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]
        ) { item, _, _ in
            let frame = item.draggingFrame
            item.setDraggingFrame(
                CGRect(
                    x: frame.midX - side / 2,
                    y: frame.midY - side / 2,
                    width: side,
                    height: side
                ),
                contents: image
            )
            index += 1
        }
        Self.logger.notice("system drag image restored (\(reason, privacy: .public)) side=\(side, privacy: .public) items=\(index, privacy: .public)")
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        // Musicアプリ等が実際に何を供給するかの調査も兼ねて毎回記録する
        let types = info.draggingPasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "none"
        Self.logger.notice("external drag entered: types=\(types, privacy: .public)")
        // onEntered(モーフィング開始)より先にセッション状態を整える
        beginSession(info)
        lastDragActivityTime = CACurrentMediaTime()
        onEntered?(extractURL(from: info))
        onHover?(localPoint(info))
        return offeredOperation(info)
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        currentInfo = info
        lastDragActivityTime = CACurrentMediaTime()
        onHover?(localPoint(info))
        return offeredOperation(info)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        endSession(restoreImage: true, reason: "exited")
        onLeave?()
    }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        // ドロップ先へ画像が滑る着地アニメーションを止める
        // (これが有効だとドロップしたレコード画像が左下へ流れて見える)
        info.animatesToDestination = false
        let p = localPoint(info)
        // ドロップが成立したらセッションは終わる。モーフィング状態は
        // 戻さずに捨てる(この後conclude/draggingEndedが来ても無害)
        endSession(restoreImage: false, reason: "drop")
        guard let url = extractURL(from: info) else {
            Self.logger.notice("external overlay drop: no URL in pasteboard point=(\(p.x, privacy: .public), \(p.y, privacy: .public))")
            return false
        }
        Self.logger.notice("external overlay drop: url=\(url.absoluteString, privacy: .public) point=(\(p.x, privacy: .public), \(p.y, privacy: .public))")
        return onDrop?(url, p) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        endSession(restoreImage: false, reason: "concluded")
        onLeave?()
    }

    // performがfalseやキャンセルでもハイライトが残らないよう念のため
    override func draggingEnded(_ sender: NSDraggingInfo) {
        endSession(restoreImage: false, reason: "ended")
        onLeave?()
    }
}

/// ドラッグ画像のモーフィング命令をShelfViewからExternalDropOverlayViewへ
/// 渡すための薄い窓口。SwiftUIの状態(@State)がこの箱を持ち、
/// NSViewRepresentableが実体をweakで差し込む(SwiftUIの状態として
/// NSViewを直接保持しないための定石)
private final class ExternalDropOverlayHandle {
    weak var view: ExternalDropOverlayView?

    func morphTo(image: NSImage, id: String, size: CGFloat) {
        view?.morphTo(image: image, id: id, size: size)
    }
}

/// ExternalDropOverlayViewをSwiftUIに載せるための薄いラッパ。
/// コールバックはmake/updateの両方で流し込む(再評価で最新の
/// クロージャに差し替える)
private struct ExternalDropOverlayRep: NSViewRepresentable {
    var handle: ExternalDropOverlayHandle
    var shelfID: String
    var onEntered: (URL?) -> Void
    var onHover: (CGPoint) -> Void
    var onLeave: () -> Void
    var onDrop: (URL, CGPoint) -> Bool

    func makeNSView(context: Context) -> ExternalDropOverlayView {
        let view = ExternalDropOverlayView()
        view.shelfID = shelfID
        view.onEntered = onEntered
        view.onHover = onHover
        view.onLeave = onLeave
        view.onDrop = onDrop
        handle.view = view
        return view
    }

    func updateNSView(_ nsView: ExternalDropOverlayView, context: Context) {
        nsView.shelfID = shelfID
        nsView.onEntered = onEntered
        nsView.onHover = onHover
        nsView.onLeave = onLeave
        nsView.onDrop = onDrop
        handle.view = nsView
    }
}

/// タイトルバー(信号ボタン)と右上ツールバーの自動表示。
/// Musicアプリのミニプレーヤーと同じ挙動:
/// - ウィンドウがアクティブな状態でマウスが動いたら表示
/// - マウスが3秒間動かない、またはウィンドウが非アクティブになったら隠す
@MainActor
final class ChromeVisibilityController: ObservableObject {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    /// マウスが止まってから隠すまでの時間
    static let hideDelay: Duration = .seconds(3)

    /// タイトルバー/ツールバーを表示中か
    @Published private(set) var isVisible = false

    /// 対象ウィンドウがアクティブか
    private var isActive = false
    private var hideTask: Task<Void, Never>?
    /// 直近に隠しタイマーを張り直した時刻。マウス移動は毎フレーム届くので、
    /// 一定間隔より短い間隔ではタイマーを作り直さない(負荷対策)
    private var lastScheduleTime: ContinuousClock.Instant?
    /// 自動で隠すのを止めている理由(メニュー/アラート表示中)。
    /// 空でない間は3秒経っても隠さない
    private var holds: Set<String> = []

    /// ウィンドウのアクティブ状態が変わったとき
    func setActive(_ active: Bool) {
        isActive = active
        if active {
            // アクティブになっただけでは出さない(マウス移動で出す)。
            // 表示中だった場合は、そこから3秒のカウントダウンをやり直す
            scheduleHide()
        } else {
            hide(reason: "window inactive")
        }
    }

    /// メニュー/アラートなどモーダルなUIを出している間の自動非表示を止める。
    /// 出し終わったら3秒のカウントダウンをやり直す
    /// (メニューを開いたまま3秒経つとカプセルごと消えるのを防ぐ)
    func setHold(_ reason: String, active: Bool) {
        if active {
            guard holds.insert(reason).inserted else { return }
            Self.logger.notice("chrome hold on (\(reason, privacy: .public))")
            hideTask?.cancel()
            hideTask = nil
        } else {
            guard holds.remove(reason) != nil else { return }
            Self.logger.notice("chrome hold off (\(reason, privacy: .public)) holds=\(self.holds.count, privacy: .public)")
            if isActive {
                scheduleHide()
            }
        }
    }

    /// マウス移動・クリック・スクロールなど、ユーザー操作があったとき
    func noteActivity() {
        guard isActive else { return }
        if !isVisible {
            isVisible = true
            Self.logger.notice("chrome shown (mouse activity)")
        }
        // mouseMovedは毎フレーム届く。タイマーの作り直しは250ms間隔に間引く
        let now = ContinuousClock.now
        if let last = lastScheduleTime, last.duration(to: now) < .milliseconds(250) {
            return
        }
        lastScheduleTime = now
        scheduleHide()
    }

    private func scheduleHide() {
        lastScheduleTime = ContinuousClock.now
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hideDelay)
            guard !Task.isCancelled else { return }
            self?.hideIfIdle()
        }
    }

    /// 3秒経過時。メニュー/アラートを出している間は隠さない
    /// (閉じたときにsetHold(false)がカウントダウンをやり直す)
    private func hideIfIdle() {
        guard holds.isEmpty else {
            Self.logger.notice("chrome hide skipped (holds=\(self.holds.sorted().joined(separator: ","), privacy: .public))")
            return
        }
        hide(reason: "idle 3s")
    }

    private func hide(reason: String) {
        hideTask?.cancel()
        hideTask = nil
        if isVisible {
            isVisible = false
            Self.logger.notice("chrome hidden (\(reason, privacy: .public))")
        }
    }
}

/// NSMenuItemのactionをクロージャで扱うためのターゲット。
/// NSMenuItem.targetは保持されないため、メニューを出している間だけ
/// ShelfViewの contextMenuTargets(@Stateの配列)で生かしておく
private final class ContextMenuAction: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke() {
        action()
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
