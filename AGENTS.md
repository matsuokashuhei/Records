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
