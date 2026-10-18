# 引き継ぎ書 — Records(レコードシェルフウィジェット)

作成: 2026-10-18。前担当エージェントから次のエージェントへ。
**まず `AGENTS.md` を読むこと**(鉄則: ロギング必須/ユーザーに操作を依頼したらログを自分で監視分析/ファイル追加後はxcodegen再実行)。

## 1. このプロジェクトのゴール(ユーザーの要求)

macOSデスクトップウィジェット+管理アプリ。Apple Musicの**アルバム/プレイリスト20個**を
壁のレコードシェルフ風に並べ、クリックすると**Musicアプリ(またはその代替)でそのまま再生**する。

- 登録は Apple MusicのURL/IDのペースト(`https://music.apple.com/jp/album/brown-sugar/1440842296` 形式)
- ライブラリへの追加はしたくない(カタログ直接再生)
- ホバーで再生/停止アイコン(SF Symbols)を表示、クリックでトグル
- プリインストール済みアルバム3枚: Brown Sugar / Fly Girl (Queen Latifah EP) / House of Music

## 2. 現在の状態

### 動作確認済み(実機テスト済み)
- アルバム登録(iTunes Lookup API版で実績)→ シェルフ表示
- **アルバムのクリック再生**(エンドツーエンド成功):
  `shortcuts://run-shortcut?name=<enc>&input=<アルバムURL>` を `/usr/bin/open` →
  ユーザーのショートカット「**Recordsで再生**」(旧名「Apple Musicミニプレイヤー」、どちらも対応)
  →「音楽を再生」アクションが Musicアプリでカタログのアルバムを自動再生
- ウィジェットクリック → 再生(ユーザー確認「動いたぞ!」)
- 2秒ポーリングの再生状態監視(PlaybackMonitor、ログで動作確認済み)
- ホバーでplay.fill/stop.fill表示のUI(ビルド済み。目視確認は未)

### 旧ブロッカー(2026-10-18 解決済み)

**MusicKitカタログAPIが `.developerTokenRequestFailed` で失敗する問題 → 解消。**

原因と解決:
- `com.apple.developer.musickit` は存在しないentitlement(MusicKitはruntimeサービス)。
  entitlementsファイルへの記述は「invalid entitlement」で署名失敗するだけだった
- 必要だったのは developer.apple.com → Identifiers → App ID `com.cacheandbuffer.Records`
  → App Services タブで MusicKit にチェック。**ユーザーがポータルで登録済み**
- 結果: アルバム/プレイリスト両方のカタログ取得・プレイリストのApplicationMusicPlayer再生
  まで `Records --catalog-test <URL> [--play]` で実機検証OK(ログ実績あり)

### 残りの未検証項目

- **登録フロー(UI)**: 下位層(fetch)は `--catalog-test` で検証済み。UIからの追加自体は未確認
- **ウィジェットからのプレイリストクリック再生**: PlayAlbumIntent → PlaybackEngine →
  PlaylistPlayer の経路。アルバム再生は実績あり、プレイリストはユーザー確認が必要

### 代替案メモ(MusicKit解決で不要になったが知識として残す)

- 登録: アルバムはiTunes Lookup APIで代替可能(実績あり、認証不要)。
  プレイリストはWebスクレイプ(実測OK):
  `curl -s "<URL>" -H "User-Agent: Mozilla/5.0"` から
  og:title(「」内がタイトル)、og:description(「プレイリスト・199曲」)、
  og:image(1200x630形式 → URL中の `1200x630SC.DN01-60.jpg` を `600x600bb.jpg` に書き換えると
  正方形画像が取れる、HTTP 200実測)、JSON-LD内にキュレーター名と先頭曲URLあり
- プレイリスト再生の代替:
  a) 先頭曲URLをショートカットに渡して1曲だけ再生(継続性なし。未検証)
  b) `music://` ディープリンクでプレイリストページを開き、再生ボタンをアクセシビリティ操作
     (ターミナル実測: AXは未許可で-1719。脆弱・非推奨)

## 3. 実機検証済みの技術的事実(2026-10-18, macOS 27.0.1 / Xcode 27.1)

- macOSのMusicKitに `SystemMusicPlayer` は**存在しない**(iOS専用、`@available(macOS, unavailable)`)
- `music://` ディープリンク(album?i= / song / &play=1)は**再生しない**(ページを開くだけ、3形式で実測)
- Shortcutsの「音楽を再生」アクション: アルバムURLのテキスト入力は解決して再生するが、
  **プレイリストURLは解決できない**(20秒待っても無反応、実測)
- Apple Events (Shortcuts Events) / `shortcuts run` CLI は、**GUIアプリプロセスから呼ぶと
  ショートカット名解決が失敗する**(一覧の列挙は成功するのに `-1728` / "Couldn't find shortcut")。
  ターミナルからは同じコマンドが成功する。→ URLスキーム経由が唯一の安定経路
- MusicKitカタログAPIは**メディアライブラリ許可(メディアとApple Music)が必要**
  (無許可だと `.permissionDenied`)。許可はユーザーが「許可」済み(authorized をログで確認)
- `NSAppleMusicUsageDescription` がInfo.plistに無いと、MusicAuthorization.request() 時に
  **TCCがSIGABRTでアプリを即死させる**(project.ymlの `INFOPLIST_KEY_NSAppleMusicUsageDescription`
  で対応済み)
- `com.apple.developer.musickit` エンタイトルメントは**存在しない**(MusicKitはruntimeサービス。
  App IDのApp ServicesでMusicKitを有効化するだけでOK — 解決済み)
- iTunes Search/Lookup API: 認証不要、アルバムOK、**プレイリスト非対応**
- ウィジェットは非サンドボックスのままで動作する(ギャラリーに出てクリックも動いた実績)
- アプリを /Applications にインストール**しない**(ユーザー指示)。ビルドディレクトリから起動する
- appの場所を移すとウィジェット登録が壊れることがある → `lsregister -f <app>`、
  `pluginkit -e use -i <bundleid>`、`killall Dock` で復旧できる(実測)

## 4. コマンド

```bash
cd /Users/matsuokashuhei/Development/github.com/matsuokashuhei/Records

# プロジェクト生成(Swiftファイルを増減したら必ず)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate

# ビルド
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Records.xcodeproj -scheme Records -configuration Debug \
  -derivedDataPath .build build

# 起動
open .build/Build/Products/Debug/Records.app

# CLI検証(UIを触らずMusicKit取得/再生を試す。結果はログへ)
.build/Build/Products/Debug/Records.app/Contents/MacOS/Records \
  --catalog-test "<album or playlist URL>" [--play]

# ログ(診断の基本。UIアクション系は必ずここに出る)
/usr/bin/log show --last 5m --style compact --info \
  --predicate 'subsystem == "com.cacheandbuffer.Records"'

# ライブ監視(バックグラウンドでファイルに流すと楽)
/usr/bin/log stream --style compact --level info \
  --predicate 'subsystem == "com.cacheandbuffer.Records"' > /tmp/records.log 2>&1 &

# 音量(テスト時は0に、終わったら戻す)
osascript -e 'set volume output volume 0'   # / 30 など
```

- `xcode-select` がCLT向きのため、xcodebuild/xcodegenには必ず `DEVELOPER_DIR` を付ける
- `log` コマンドは絶対パス `/usr/bin/log` で呼ぶ(シェルによってエイリアス衝突する)

## 5. 構成とデータ

- `Shared/`(アプリ+ウィジェット拡張の両方にリンク)
  - `MediaEntry.swift`: モデル + `MediaURLParser`(album/playlist URL→kind/country/id)
  - `MediaCatalogClient.swift`: MusicKitカタログ取得(動作確認済み)
  - `ShelfStore.swift`: 20スロットの登録データ + アートワークキャッシュ + presets3枚
  - `PlaybackEngine.swift`: アルバム=URLスキーム再生/停止、Musicアプリ状態取得、ロギング
  - `PlaylistPlayer.swift`: プレイリスト=ApplicationMusicPlayer再生
  - `PlayAlbumIntent.swift`: ウィジェットのButton用AppIntent(entryIDを受け取る)
- `Records/`: `RegistrationView.swift`(20スロットUI/追加フォーム)、`PlaybackMonitor.swift`(2秒ポーリング)、
  `RecordsApp.swift`
- `WidgetExtension/`: `RecordShelfWidget.swift`(extraLarge 5列×4段=20枚+large)
- `project.yml`: xcodegen定義。**pbxprojを手で編集しない**
- データ: `~/Library/Application Support/Records/albums.json` + `Artwork/<id>.jpg`

## 6. 運用上の注意

- ユーザーは質問を嫌う。**ログで状況を自分で取る**こと(取れない時だけ尋ねる)
- 再生テストで音を出す時は事前に音量0(ユーザー承認済みの運用)
- ウィジェットのクリックはエージェントから実行できない → ユーザーに押してもらうが、
  結果はログ(Intents/Playbackカテゴリ)で確認する
- git: Initial Commit(テンプレート)のみ。全実装は未コミット → 動作区切りでコミット推奨
