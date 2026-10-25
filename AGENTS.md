# AGENTS.md — Records(レコードシェルフ)開発メモ

## このプロジェクト

macOSアプリ。Apple Musicのアルバム/プレイリスト20個を壁のレコードシェルフ風に
表示し、クリックで再生する。

## 鉄則(必ず守る)

### 1. ロギングは必須

エージェントは**UIを目視できない**。ユーザーの操作結果はすべてログで判断する。
そのため以下は必須:

- すべてのUIアクション(ボタンクリック、追加フロー、クリップボード操作など)に
  `os.Logger` を仕込む(subsystem: `com.cacheandbuffer.Records`)
- 非同期処理・外部プロセス実行・エラー経路には必ず開始/成功/失敗のログを出す
- 新しいファイル・新しい機能を書くとき、最初からログを入れる(後で足すのを忘れない)
- ログ出力例: `Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")`
- 文字列補間は `\(value, privacy: .public)` にして `log show` で読めるようにする

### 2. ユーザーに操作を依頼したら、ログは自分で監視・分析する

- ユーザーに操作を頼んだら、その後 `log show` / `log stream` で状況を
  **自分で取得して判断する**。エラーメッセージの転記などをユーザーに頼まない
- 操作を依頼 → ログ監視 → 自分で結論 → 次の手を打つ、のサイクルを回す

### 3. ファイルを追加・削除したら xcodegen を再実行

新しいSwiftファイルは `xcodegen generate` し直さないとターゲットに含まれない。

### 4. スキルは `.agents/skills/` に作成する

新しいスキル(SKILL.md)は `.agents/skills/<name>/SKILL.md` に置く。
`.devin/skills/` には置かない(既存スキルもすべて `.agents/skills/` にある)。

## ビルド・起動コマンド

```bash
# プロジェクト生成(Xcodeプロジェクトはxcodegenで管理。pbxproj直編集しない)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate

# ビルド
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Records.xcodeproj -scheme Records -configuration Debug \
  -derivedDataPath .build build

# 起動(/Applications にはインストールしないこと — ユーザー指示)
# 注意: open は起動中のインスタンスを再表示するだけで新ビルドを起動しない。
# 必ず pkill で旧プロセスを落としてから open すること(旧バイナリで
# 検証したつもりになる事故が実際に起きた — 2026-10-24)
pkill -x Records; open .build/Build/Products/Debug/Records.app

# CLI検証(UIを触らずMusicKit取得/再生を試す。結果はログへ)
.build/Build/Products/Debug/Records.app/Contents/MacOS/Records \
  --catalog-test "https://music.apple.com/jp/album/brown-sugar/1440842296" [--play]

# ログ取得
/usr/bin/log show --last 5m --style compact --info \
  --predicate 'subsystem == "com.cacheandbuffer.Records"'
```

- `xcode-select` はCLT向きなので、xcodebuild/xcodegenには必ず `DEVELOPER_DIR` を付ける
- テストで音を出すときは事前に音量を0にし、終わったら戻す
- JSONの解析にはpythonではなく `jq` を使う(ユーザー指示)
- appの場所を移すとLaunch Services登録が壊れることがある → `lsregister -f <app>` で復旧できる(実測)

## アーキテクチャと検証済み事実(2026-10-18 実機)

- **アルバムの再生**: `shortcuts://run-shortcut?name=<enc>&input=<アルバムURL>` を
  `/usr/bin/open` で開く → ユーザーのショートカット「Recordsで再生」
  (音楽を再生アクションの音楽パラメータにShortcut Input)がMusicアプリでカタログ再生
- **プレイリストの再生**: ショートカットの「音楽を再生」はプレイリストURLを解決できない
  (実測)。MusicKit `ApplicationMusicPlayer` で本アプリ内再生する
  (`ApplicationMusicPlayer.Queue(for: [playlist])`、PlaylistはPlayableMusicItem適合)
- **macOSのMusicKitに `SystemMusicPlayer` は存在しない**(iOS専用。`@available(macOS, unavailable)`)
- `music://` ディープリンクは再生せずページを開くだけ(3形式で実測)
- レコード削除は右クリック。SwiftUIの`.contextMenu`はセルの`.onTapGesture`と
  競合してレコード上で開かないため、`NSEvent.addLocalMonitorForEvents`で
  右クリックを拾ってNSMenuを出す(下の「右上ツールバーと右クリックメニュー」参照)。
  確認アラートを経て削除する(実機確認済み)
- レコードの並び替えはドラッグ&ドロップ。`.onDrag`(開始時にdraggedID記録)
  + 各セル背面の左右半分に分けた `.dropDestination(for: String.self)` ゾーン
  (左=直前、右=直後に挿入、空きスロットは末尾移動)。
  半透明表示(dropTargetOpacity)はisTargeted && willMove(実際に順番が変わる半分)のみ。
  `ShelfStore.move(_:toIndex:)` がalbums.jsonを更新。
  ドラッグ表示は自前ゴースト(GhostPanel=枠なし透明パネル)に一本化。
  **ウィンドウ内のNSViewオーバーレイだとポインタがウィンドウ外へ
  出た瞬間にクリップされてレコードが消える**ため、画面座標で自由に
  動ける別ウィンドウにする(Musicアプリと同様 — 2026-10-25)。
  `.onDrag(preview:)`に透明1pxを渡してシステムのドラッグ画像を
  無効化してある(可視のままだとドロップ時に元位置へ滑り戻る
  スライドバックが走り二重表示になる — 2026-10-24実測)。
  - GhostPanel: styleMask=[.borderless,.nonactivatingPanel]、
    ignoresMouseEvents、level=CGWindowLevelForKey(.draggingWindow)。
    元ウィンドウの子ウィンドウにする(親が閉じたら一緒に消える)。
    座標はすべて画面座標(overlayGridPoint等のグリッド座標変換は不要。
    飛行先だけslotScreenCenterでスロット中心→画面座標に逆変換する)
  - ゴーストはアプリ全体で1個(GhostController.shared)。
    シェルフ間ドロップ時はドロップ先がtakeOverで所有権を引き継ぎ、
    自分の着地スロットへ飛ばしてから実セル(ghostEntryIDで隠す)と
    交代する(=シェルフ内ドロップと同じ手順。即表示+ゴースト残存で
    レコードが2個に見えるのを防ぐ — 2026-10-25)。
    takeOverはポインタ追従(trackingEnabled)も切る — 元シェルフの
    追従タイマーはモニタ停止まで動き続け、着地フライを上書きして
    ガタつかせるため。元シェルフは終了検知でghost.ownerを見て、
    移譲済みならhideしない
  - 所有権のガードは他に2箇所: startDragのアートワークロード完了時
    (ロード中にドロップ成立していたらshowしない)と、flyGhostの
    completion(飛行中にtakeOverされていたらhideしない)。どちらも
    `ghost.owner == nil || == shelfID`で判定する
  - ドラッグ元セルはdraggedID/ghostEntryIDの間はopacity 0で非表示
  - 追従: leftMouseDraggedはドラッグセッションに吸収されてモニタに
    届かないので、60fpsタイマーでNSEvent.mouseLocationをポーリング
    (.commonモード登録)。パネルのframeを命令的に動かす
    ※@Stateで位置を持って毎イベントbody再評価すると、走行中セッション
      配下のクロージャが破棄されEXC_BAD_ACCESSで繰り返しクラッシュした。
      ドラッグ中の高頻度なSwiftUI状態更新は禁止(2026-10-24実機)
  - ドロップ: ゴーストを着地スロット中心へ0.25sで飛ばし、着地で実セルと交代
  - キャンセル: ゴーストを元スロットへ自前で滑り戻す
  - 終了検知: onDragに終了コールバック無し。leftMouseUp/mouseMovedの
    ローカルモニタで検知するが、mouseUpはperformより先に届くので
    判定は50ms遅延(即判定するとドロップをキャンセル誤認して以降の
    ドロップが全滅する — 2026-10-24実測)
  ※NSEvent.mouseLocationのwindow→content座標変換はfullSizeContentView
    構成のこのウィンドウではYが~280pt狂う。window.frame.heightと
    contentLayoutRect.heightの差(タイトルバー分)を引く式で変換すること。
  ※DropDelegate(onDrop)はdropExitedが呼ばれない経路がありハイライトが残った。
    pressedMouseButtonsポーリングも3本指/タップドラッグでは検知不能。
    isTargetedはセッション終了時にフレームワークが必ずfalseを送るので
    状態の手動掃除が要らない構造にした(2026-10-24)
- 外部ドラッグ(Music等)の画像は **`setDraggingFrame` では大きさを変えられない**
  (2026-10-25実機): `enumerateDraggingItems` のブロック内で指定すると frame の値は
  書き換わり読み戻しも一致するが、**描画は元画像の約128pt角のまま**
  (指定233pt→描画約122pt、指定432pt→約128pt)。`contents` の差し替えだけは反映される。
  +17pt の固定差補正も ×2 の倍率補正も無効。そのため外部ドラッグのモーフィングは
  「システム画像を `contents=nil` で隠し、GhostPanel(ウィンドウ内ドラッグと同じ)で
  描く」方式にしてある(ShelfView.swift の ExternalDropOverlayView)
- エージェントの動作確認手段: `screencapture -R x,y,w,h` で画面撮影→readで視認、
  CGEvent(`mouseEventSource` で rightMouseDown/Up をpost)で右クリック合成、
  System Eventsでウィンドウ位置取得 — すべて動作確認済み(2026-10-24)
  ※開いたNSMenu内の項目選択は合成クリックでは拾えなかった。
   メニューが出ること+項目アクションは別々に検証するのが現実的
  ※2026-10-25実測: 画面収録を許可しても `screencapture -R` は
   "could not create image from rect" で失敗することがある。全画面 `screencapture -x`
   は成功するので、実寸計測は全画面を撮って任意ツールでクロップ/差分する
- Apple Events / `shortcuts run` CLI は **GUIアプリプロセスからspawnすると
  ショートカット名解決に失敗する**(ターミナルからは成功するのに)。URLスキーム経由なら問題ない
- `SystemSettings → プライバシーとセキュリティ → オートメーション → Records → Shortcuts Events`
  をONにしないと、アプリプロセスからのShortcuts Events照会が空リストを返す

## ウィンドウの余白と信号ボタン(2026-10-25 実装・実機検証済み)

- グリッドの余白は**四辺8pt**。コンテンツは `.ignoresSafeArea()` で
  タイトルバー帯(32pt)の下=ウィンドウ上端まで広げ、信号ボタン
  (閉じる/最小化)はMusicアプリのミニプレーヤーと同じく
  1枚目のジャケットの上に重なる
- **`.windowResizability(.contentSize)` はウィンドウサイズを
  「ビューの理想サイズ+タイトルバー帯のセーフエリア32pt」で作る**ため、
  そのままだとウィンドウだけ32pt高くなり下側に余白が残る(実測:
  グリッド462ptに対しウィンドウ494pt)。ビュー側に `.padding(.bottom, -32)`
  を足して理想サイズを32pt差し引くと、ウィンドウとグリッドの高さが一致する
  (描画とヒットテストはグリッド側の実寸フレームが使われる)。
  32ptは `window.frame.height - window.contentLayoutRect.height` で実測
  (`WindowConfigurator.logMetrics` が titlebarInset としてログに出す)
- タイトルバー帯のクリックはコンテンツに届く(themeFrame.hitTestで実測:
  ジャケット上の帯でもSwiftUIのホスティングビューが返る)。信号ボタン上は
  `_NSThemeCloseWidget` 等が返るのでボタンも押せる
- コンテンツが上端まで来るとAppKitのタイトルバードラッグ領域が無くなるため、
  上辺の8pt余白に `WindowDragGesture` を置いてウィンドウ移動を確保している
- `slotScreenCenter` のグリッド→画面座標変換からタイトルバー帯の控除は不要
  (グリッド上端=ウィンドウ上端)

## 右上ツールバーと右クリックメニュー(2026-10-25)

- シェルフ操作は**右上のカプセル型ツールバー**(Musicアプリのウィンドウ右上と
  同じ「共有+3点リーダー」)に集約した。共有は表示のみ(実装は別途)、
  3点リーダー(SwiftUIの`Menu`)で New Shelf / Settings… / Delete Shelf… を出す
- **タイトルバー(信号ボタン)と右上ツールバーは自動で出し入れする**
  (`ChromeVisibilityController`): ウィンドウがアクティブな状態で
  マウスが動いたら表示、**3秒間動かない/ウィンドウが非アクティブ**なら非表示。
  mouseMovedは毎フレーム届くので、隠しタイマーの張り直しは250msに間引く。
  `window.acceptsMouseMovedEvents = true`が無いとmouseMovedが来ない
  (WindowConfigurator.configureで設定)。メニュー表示中(`NSMenu`の
  didBegin/didEndTracking)とアラート表示中(pendingDelete等)は
  `setHold(_:active:)`で隠すのを止め、閉じたら3秒を数え直す
  (メニューを開いたままカプセルが消えるのを防ぐ)
- 信号ボタンの表示は`WindowConfigurator.updateTrafficLightVisibility(_:visible:)`に
  統合し、呼び出し側が「キー状態 && chrome表示中」を渡す
- 信号ボタンは**Apple標準のNSWindowボタン**(`_NSThemeCloseWidget` /
  `_NSThemeWidget` / `_NSThemeZoomWidget`)。ズームは固定サイズで意味がないため
  常に非表示(閉じる/最小化のみ)
- 信号ボタンは標準位置(左上9pt)から**4pt内側の13ptへ寄せる**
  (`applyTrafficLightInset`。ガラス/ツールバーの枠との余白を揃えるため)。
  AppKitがタイトルバーをレイアウトし直すと標準位置へ戻るので、
  `NSWindow.didUpdateNotification` で毎回冪等に再適用する。位置を実際に
  書き換えたときだけ `traffic light repositioned: count=N` をログに出す
  (chromeの表示切替時などに数回出るだけで止まる=収束する)
- **Liquid Glass**: 信号ボタンの背面と右上ツールバーに適用する
  - 信号ボタン: `NSGlassEffectView`(ヒットテストはnil)をコンテンツビューへ
    追加し、閉じる/最小化の外接矩形+5ptの角丸カプセルを背面に敷く
    (`WindowConfigurator.View.updateTrafficLightGlass`)
  - 右上ツールバー: SwiftUIの `.glassEffect(.regular.tint(.black.opacity(0.45)).interactive(), in: Capsule())`
  - 2つのガラスの染め方を揃える: 信号ボタン側は `NSGlassEffectView.tintColor`
    に同じ `.black.opacity(0.45)` を入れる(白アイコンを明るいジャケット上でも読ませる)
  - `GlassEffectContainer`(AppKitでは`NSGlassEffectContainerView`)は使わない。
    融合させたいガラスが左上と右上に離れており、片方はAppKitレイヤーなので
    まとめる意味がない
  - 右上カプセル: 上8pt / 右18pt / 高さ24pt / アイコン14pt。
    **信号ボタンの中心(13+14/2=20pt)とカプセルの中心(8+24/2=20pt)を
    揃える**ため、上8pt・高さ24ptにしてある。
    信号ボタンのガラスも外接矩形+5pt(=左上8pt)で同じ中心になる
- **右クリックメニューはレコードの上だけ**(Delete Record)。空きスロット・
  レコード間の隙間・余白では何も出さない(シェルフ操作は上のツールバーへ移動)。
  信号ボタンと右上ツールバーの矩形(`isOverChrome`)も除外してクローム自身に任せる。
  ウィンドウ座標→グリッド座標は`overlayGridPoint`、スロット判定は
  `slotInsertion`を再利用している
- SwiftUIの`.contextMenu`はセルの`.onTapGesture`(クリックで再生)と競合し、
  **レコード上でメニューが開かない**(2026-10-25実測: onTapGestureを外すと
  開くようになる)。そのため右クリックは`NSEvent.addLocalMonitorForEvents`
  で拾ってNSMenuを出している(`installContextMenuMonitor`)。
  NSMenuItem.targetは保持されないので、メニューを出している間は
  クロージャ保持用の`ContextMenuAction`を生かしておくこと

## 複数シェルフ(2026-10-25 実装・実機検証済み)

- 1シェルフ=1ウィンドウ。`ShelfManager`(Shared)がシェルフID一覧
  (shelves.json)とシェルフごとの`ShelfStore`を管理する。`ShelfStore.shared`
  は廃止。`ShelfStore(shelfID:)`を`manager.store(for:)`経由で引く
- 新シェルフは ⇧⌘N(CommandGroupで.newItemを置き換え=標準⌘Nは無い)か
  右上ツールバーの3点リーダーメニューから。新シェルフは空で始まる
  (プリセットは"main"のみ。読み込み失敗時のfallbackも"main"のみプリセット)
- ウィンドウの値=`WindowGroup(id:"shelf", for:String.self)`のString?
  (シェルフID)。値なし(nil)のウィンドウ=起動時やドックアイコンで
  システムが作るもの → プライマリシェルフになり、
  `openMissingShelfWindows`で未オープンのシェルフのウィンドウを開き直す。
  プライマリが既に開いている値なしウィンドウは重複として自分を閉じる
- **WindowGroupの値なし初期ウィンドウは「部分復元」で作られない**:
  macOSのウィンドウ復元で補助ウィンドウ(設定画面)だけが復元されると、
  WindowGroupが初期ウィンドウを生成しない(実機で起動時にシェルフ
  ウィンドウ0枚になる現象を確認)。両シーンに
  `.restorationBehavior(.disabled)`+WindowGroupに
  `.defaultLaunchBehavior(.presented)`を付けて自前復元に一本化した。
  ※WindowGroup自身にも復元が効くと、自前オープンとmacOS復元が
  二重オープンすることがあった(実測で3窓)
- マウス座標変換(overlayGridPoint/slotScreenCenter)は`keyWindow`ではなく
  `windowBox.window`(そのビューのウィンドウ)を使う。複数窓で
  非keyウィンドウへのドラッグが狂うため。WindowConfiguratorの
  `onWindowReady`/`onBecameKey`コールバックで取得
- **フォーカス中シェルフの追跡**: WindowConfiguratorのdidBecomeKey通知で
  `ShelfManager.focusedStore`を更新。設定画面(SettingsView)はこれを編集する
  (=「設定はフォーカスしているウィンドウで有効」)
- **タイトルバー下のセパレータ線は`.windowStyle(.hiddenTitleBar)`で消す**
  (macOS 26実測): styleMaskに.fullSizeContentViewを挿入しても
  contentLayoutRectがタイトルバー帯を含まず(contentLayout={{0,0},{W,H-32}})、
  帯はシステム描画でその下端に線が残る。titlebarSeparatorStyle=.noneでも
  消えない。hiddenTitleBarなら帯自体が消え、マージンと信号ボタン表示も保たれる
- 設定画面は`Window(id:"settings")`シーン。`Settings`シーン(Cmd+,)は廃止。
  開き方: 右上ツールバーの3点リーダー→「Settings…」。
  同じメニューにNew Shelf/Delete Shelf…もある(最後の1枚は削除不可)
- PlaybackMonitorのポーリングは参照カウント式(全シェルフで共有。
  .onAppearで+1、.onDisappearで-1、0で停止)
- シェルフ間ドラッグ: ペーストボードに`ShelfDragPayload`
  (sourceShelfID+MediaEntryのJSON)を載せる。ドロップ先でdecodeし、
  同じシェルフなら並び替え(move)、別シェルフならtransferDrop
  (registerFetchedで挿入→成功後に元シェルフからremove。先に消すと
  失敗時にレコードが消える)。重複/満杯はfalseで拒否=元に残る。
  元ウィンドウのゴースト/draggedIDは、終了検知モニタがentriesから
  消えたことを見てhide(滑り戻し不要)で片付く
- **透明ガラス領域は合成クリックが素通りする**(実測): NSGlassEffectView
  だけの余白/空きスロットへのCGEvent右クリックは背面アプリに届くことが
  ある。検証時は不透明なレコード画像か、ウィンドウをAXRaiseしてから
  打つこと。実ユーザー操作では問題なくメニューが出る(実機確認済み)
- コンテキストメニュー内の項目選択は合成イベントでは不安定。
  メニューが開いた状態で矢印キー+returnのCGEventなら選択できた
  (「設定…」→設定画面オープンを実機確認)
- iTunes Search/Lookup APIは認証不要だがプレイリスト非対応。プレイリストの検証は
  MusicKitカタログAPI(`MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: ...)`)
  で行う。カタログ読み取りにユーザー認可は不要
- MusicKitは**entitlementではなくruntimeサービス**(2026-10-18 検証済み)。
  `com.apple.developer.musickit` というentitlementは存在せず、entitlementsファイルに書くと
  プロビジョニングで「invalid entitlement」エラーになる。**entitlementsファイルに書いてはいけない**
- MusicKitカタログAPIに必要なのは: developer.apple.com → Identifiers → App ID
  `com.cacheandbuffer.Records` → **App ServicesタブでMusicKitにチェック**(ユーザーが登録済み、2026-10-18)
  - CLI/`-allowProvisioningUpdates` からはApp IDサービスを有効化できない(pbxprojの
    `SystemCapabilities` 注入も無効だった — MusicKitはXcodeのcapabilityに無い)
- `NSAppleMusicUsageDescription`(Info.plist)が無いと、MusicAuthorization.request() 時に
  TCCがSIGABRTでアプリを即死させる(project.ymlの `INFOPLIST_KEY_NSAppleMusicUsageDescription` で対応済み)
- **CLI検証経路**: `Records --catalog-test <URL> [--play]` で起動するとUIを介さず
  MediaCatalogClient.fetch(+PlaybackEngine.play)を実行し結果をログに出して終了する
  (RecordsApp.swiftのinit内。UIを触れないエージェントの検証用)
  - `Records --chrome-preview` は起動1.5秒後にツールバー/信号ボタンを強制表示する
    (3秒で自動的に隠れる。マウス移動・クリックを合成できないエージェントが
    スクリーンショットで見た目を確認するための経路。複数シェルフがある場合は
    プライマリのウィンドウだけが対象)

## データ

- シェルフ一覧: `~/Library/Application Support/Records/shelves.json`
  (シェルフIDの配列。先頭がプライマリ="main")
- 各シェルフの登録データ/表示設定:
  `~/Library/Application Support/Records/Shelves/<shelfID>/{albums,settings}.json`
  (旧レイアウトのルートalbums.json/settings.jsonは起動時にShelves/main/へ自動移行)
- アートワーク: `~/Library/Application Support/Records/Artwork/<id>.jpg`
  (全シェルフで共有。削除時は他シェルフの使用有無をShelfManager.isEntryUsedElsewhereで判定)
- アプリは非サンドボックスでこのディレクトリを使う

## 構成

- `Shared/` — アプリにリンクされる共有層
  (MediaEntry/MediaURLParser, MediaCatalogClient, ShelfStore, ShelfSettings, PlaybackEngine, PlaylistPlayer)
- `Records/` — アプリ本体(ShelfView, SettingsView, WindowGlass, PlaybackMonitor)
  - `Localizable.xcstrings` — UI文字列カタログ。開発言語en、キーは英語リテラル
    (補間は%@/%lld形式)。対応言語: en/ja/es/zh-Hans/ko/fr/de
  - `InfoPlist.xcstrings` — NSAppleMusicUsageDescriptionの翻訳
    (project.ymlのINFOPLIST_KEY値はen表示用のフォールバック。他言語は
    カタログが生成するInfoPlist.stringsが使われる)
- `project.yml` — xcodegen定義(ターゲット変更はここを編集)

## ウィジェット拡張について(2026-10-24 撤去済み)

WidgetKit拡張(RecordsWidget)は**撤去した**。正方形ウィジェット枠内で
アプリ同等の均一余白が実現できず、見た目の要件を満たせなかったため。

もし復活させる場合の重要な知見(詳細はgit履歴参照):

- 拡張は app-sandbox 必須。sandbox内で `urls(for:.applicationSupportDirectory)` は
  コンテナを指すため共有データには `getpwuid` 実ホーム解決が必要
- デスクトップ非アクティブ時の減退描画で画像を保つには
  `Image.widgetAccentedRenderingMode(.fullColor)`(Image専用)
- 設置済みウィジェットのkind名を変えると `No matching descriptor` で壊れる
- 描画が壊れたときのリセットは `~/Library/Containers/com.cacheandbuffer.Records.widget/`
  コンテナごとFinderで削除(TCCでターミナルからは消せない)
