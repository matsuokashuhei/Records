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
- レコード削除は右クリック。LazyVGridスロットの `.frame` 後ろに付けた
  `.contextMenu` で「Delete Record」を出し、確認アラートで削除(実機確認済み)
- レコードの並び替えはドラッグ&ドロップ。`.onDrag`(開始時にdraggedID記録)
  + 各セル背面の左右半分に分けた `.dropDestination(for: String.self)` ゾーン
  (左=直前、右=直後に挿入、空きスロットは末尾移動)。
  半透明表示(dropTargetOpacity)はisTargeted && willMove(実際に順番が変わる半分)のみ。
  `ShelfStore.move(_:toIndex:)` がalbums.jsonを更新。
  ドラッグ表示は自前ゴースト(GhostOverlayView=NSViewオーバーレイ)に
  一本化。`.onDrag(preview:)`に透明1pxを渡してシステムのドラッグ画像を
  無効化してある(可視のままだとドロップ時に元位置へ滑り戻る
  スライドバックが走り二重表示になる — 2026-10-24実測)。
  - ドラッグ元セルはdraggedID/ghostEntryIDの間はopacity 0で非表示
  - 追従: leftMouseDraggedはドラッグセッションに吸収されてモニタに
    届かないので、60fpsタイマーでNSEvent.mouseLocationをポーリング
    (.commonモード登録)。ゴーストはNSViewを命令的に動かす
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
- エージェントの動作確認手段: `screencapture -R x,y,w,h` で画面撮影→readで視認、
  CGEvent(`mouseEventSource` で rightMouseDown/Up をpost)で右クリック合成、
  System Eventsでウィンドウ位置取得 — すべて動作確認済み(2026-10-24)
  ※開いたNSMenu内の項目選択は合成クリックでは拾えなかった。
   メニューが出ること+項目アクションは別々に検証するのが現実的
- Apple Events / `shortcuts run` CLI は **GUIアプリプロセスからspawnすると
  ショートカット名解決に失敗する**(ターミナルからは成功するのに)。URLスキーム経由なら問題ない
- `SystemSettings → プライバシーとセキュリティ → オートメーション → Records → Shortcuts Events`
  をONにしないと、アプリプロセスからのShortcuts Events照会が空リストを返す
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

## データ

- 登録データ: `~/Library/Application Support/Records/albums.json`
- アートワーク: `~/Library/Application Support/Records/Artwork/<id>.jpg`
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
