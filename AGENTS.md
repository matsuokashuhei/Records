# AGENTS.md — Records(レコードシェルフウィジェット)開発メモ

## このプロジェクト

macOSデスクトップウィジェット+管理アプリ。Apple Musicのアルバム/プレイリスト20個を
壁のレコードシェルフ風に表示し、クリックで再生する。

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
open .build/Build/Products/Debug/Records.app

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
- appの場所を移すとウィジェット登録が壊れることがある → `lsregister -f <app>`、
  `pluginkit -e use -i <bundleid>`、`killall Dock` で復旧できる(実測)
- ウィジェット拡張はsandbox必須(外すとpkdが "plug-ins must be sandboxed" で
  拡張の登録を拒否する、実測)。entitlementsのapp-sandboxを外さないこと

## アーキテクチャと検証済み事実(2026-10-18 実機)

- **アルバムの再生**: `shortcuts://run-shortcut?name=<enc>&input=<アルバムURL>` を
  `/usr/bin/open` で開く → ユーザーのショートカット「Recordsで再生」
  (音楽を再生アクションの音楽パラメータにShortcut Input)がMusicアプリでカタログ再生
- **プレイリストの再生**: ショートカットの「音楽を再生」はプレイリストURLを解決できない
  (実測)。MusicKit `ApplicationMusicPlayer` で本アプリ内再生する
  (`ApplicationMusicPlayer.Queue(for: [playlist])`、PlaylistはPlayableMusicItem適合)
- **macOSのMusicKitに `SystemMusicPlayer` は存在しない**(iOS専用。`@available(macOS, unavailable)`)
- `music://` ディープリンクは再生せずページを開くだけ(3形式で実測)
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
- アプリは非サンドボックス、ウィジェット拡張は app-sandbox +
  `temporary-exception.files.home-relative-path.read-write`
  (`/Library/Application Support/Records/`)でこのディレクトリを共有する

## 構成

- `Shared/` — アプリとウィジェット拡張の両方にリンクされる層
  (MediaEntry/MediaURLParser, MediaCatalogClient, ShelfStore, PlaybackEngine, PlaylistPlayer, PlayAlbumIntent)
- `Records/` — アプリ本体(ShelfView, SettingsView, WindowGlass, PlaybackMonitor)
- `WidgetExtension/` — WidgetKit拡張(RecordShelfWidget, extraLarge 5×4=20枚)。
  AppIntentConfiguration(RecordShelfConfigurationIntent)でウィジェットごとの
  容量を選べる(アプリ設定に従う/6/12/20)。容量→列×行はShelfSettings.Capacity
  のマッピングを共用
- `project.yml` — xcodegen定義(ターゲット変更はここを編集)

## ウィジェット拡張の検証済み事実(2026-10-20 実機・長期デバッグの成果)

- **sandbox必須**: `com.apple.security.app-sandbox` が無いと pkd が
  `plug-ins must be sandboxed` で登録拒否する
- **sandboxed拡張では `urls(for: .applicationSupportDirectory)` はコンテナ内パスを返す**
  → 共有データに届かず albums.json 読み取り失敗→プリセット3件にフォールバックする罠。
  `ShelfStore.baseDirectory` は `getpwuid(getuid())->pw_dir` で実ホームを解決している
  (sandboxでも実パスを返す)。entitlements の home-relative-path 例外とセットで使う
- **拡張のコンテナパスは `~/Library/Containers/com.cacheandbuffer.Records.widget/`**。
  `Data/SystemData/com.apple.chrono/` に描画アーカイブ(timelines/snapshots/placeholders)が
  溜まる。**壊れた描画が残るとNotificationCenterが「同じもの」として再利用し続ける**
  → コンテナごとFinderで削除するのが最も確実なリセット(TCCでターミナルからは消せない)
- **ウィジェットの `kind` 名は絶対に変えない** — 設置済みインスタンスが旧kindを参照し
  `CHSErrorDomain 1100 "No matching descriptor"` で永久に壊れる
- **デスクトップ非アクティブ時は accented(減退)レンダリングになる**。
  非accentableなコンテンツはグレーの塊になる。画像を保持するには
  **`Image` 専用修飾子 `.widgetAccentedRenderingMode(.fullColor)`** を付ける
  (Apple公式「アルバムアート等のメディア画像向け」。Image専用なので
  `.resizable()` 等とチェーンできず、表示サイズは `NSImage.size` で指定する)
- **`lsregister`/`pluginkit -a` だけでは設置済みウィジェットの描画は更新されない**
  → 再描画のトリガーは「ウィジェット削除→追加」か「アプリ側で設定保存
  (reloadAllTimelines)」
- **XcodeでDerivedDataにビルドすると `.build` 版と二重登録されて古い描画が出る**
  → 動かすのは `.build/Build/Products/Debug/Records.app` のみにする
- chronodログの調査: `log show --predicate 'process == "chronod" AND
  eventMessage CONTAINS "cacheandbuffer"'` で `extensionNotFound`(1300)/
  `unsupportedEntryKey`/`No matching descriptor`(1100) が出たら
  拡張レコードかコンテナの不整合を疑う
