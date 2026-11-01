# Linear Issue Draft

Title: スリーブ光沢プラグイン: 照明設定UIと鏡面反射モデルを一から作り直す

---

## 背景・目的

プラグイン「スリーブ光沢」(SleeveGlossPlugin)の設定UIと反射モデルを、
現状の課題を踏まえて一から作り直す。

現行実装は以下のイテレーションを経ており、今回その成果と課題を
仕様として整理した:

1. 初期: Intensity / Band Angle / Band Width の3スライダー(技術的で不直感的)
2. 照明メタファーUI化: 位置9択 / 強さスライダー / 色味4択 ← 採用方向
3. 距離減衰 v1: 最遠=0の線形減衰 → 角照明で棚の大半が消えて却下
4. 距離減衰 v2: 棚面上方の点光源・逆二乗減衰 ← 採用方向
5. 反射 v3: 全セル同一方向の帯は不自然 → 鏡面反射点をセル毎に計算 ← 採用方向

## 参照するべき写真の特徴(レコード店実写真)

- 光源は棚の手前・上方に浮いている(吊りランプ)
- 光沢は光源に近いレコードの「光源を向く面」に局所的に出る。
  全ジャケットに同一方向の帯がかかるのは不自然
- レコードは1枚ごとに微妙に傾きが違い、反射の出方もバラつく
- スリーブによって艶が違う(マット/光沢の混在)

## 機能要件

### 1. 設定UI(照明メタファー)

プラグインの調整パラメータは次の3つ:

| パラメータ | UI | 値 |
|---|---|---|
| 照明の位置 | 3×3グリッドの視覚ピッカー(sunアイコンのセル、選択中が点灯) | top-left … bottom-right + center の9値。default "top-left" |
| 照明の強さ | スライダー | 0…1, step 0.01, default 0.15 |
| 照明の色味 | 4択(セグメント) | bulb=電球色(オレンジ系温色) / warmWhite=温白色 / neutralWhite=昼白色(≈白、default) / daylight=昼光色(青みの白) |

- ラベルは LocalizedStringKey 経由、全言語(de/es/fr/ja/ko/zh-Hans)でカタログ登録
- パラメータは settings.json に文字列/数値で永続化(既存 PluginParameterSpec に
  `.options` 選択型caseを追加済み — そのまま使う)

### 2. セル位置情報の配管(実装済み・そのまま使う)

- `ShelfPluginContext` に `cellCenter`(0-1正規化セル中心、(0,0)=左上 (1,1)=右下)、
  `gridColumns`/`gridRows` がある
- `ShelfPluginRegistry.resolve(settings:cellSize:cellIndex:)` が
  行優先indexからセル中心を計算して注入。`AlbumSlotView` は `slotIndex` を渡す

### 3. 反射モデル(物理要件)

**光源**: L = (Px, Py, h)。Px,Py = 位置パラメータの0-1座標、
h = 0.5(棚面から手前方向への高さ、グリッド正規化単位)

**鏡面反射点S**(光沢の中心になる棚面上の点):
- 視点 E = (0.5, 0.5, eyeDepth)、eyeDepth = 3.5
- 視点を棚面で折り返した像 E' = (0.5, 0.5, −eyeDepth) と L を結ぶ直線と
  z=0 の交点が S: `t = eyeDepth/(eyeDepth+h)`、`S = E_xy + t·(P_xy − E_xy)`
- これにより S は光源の棚面投影のやや内側(角照明で約0.94,0.06等)に来る

**セルごとの光沢方向**:
- 正規化座標を「セル1個=1」の物理座標に変換(s.x*=cols, s.y*=rows)してから
  dir = normalize(S − C)。非正方グリッドでも向きが潰れない
- 帯のグラデ軸 = `center + dir·0.5` → `center − dir·0.5`(S側の縁から内側へ)
- Sがセル内/ごく近傍(dist < 0.5セル)のセルは、S位置中心の小さめ
  RadialGradient(直接反射)。position=center は従来どおり中央 radial

**距離減衰**(逆二乗・全セル照らす):
- r = hypot(d, h)(d=Pからセル中心への平面距離)
- m = (r_min / r)²(r_min=全セル中心のr最小値)→ 最近傍=1、最遠は0にならない
- 参考値(4×4, h=0.5): 角照明の最遠 ≈0.16、辺中点 ≈0.24、中心 ≈0.53
- r ≤ r_min(1×1等)は m=1

**傾き(反射への影響のみ)**:
- セルごとに決定論的疑似傾き(cellCenter座標のsinハッシュで生成、
  yaw/pitch ±5°程度)を反射計算に混入。面をα傾けると鏡面反射は2α動くので
  Sを `2·tan(α)` セル分ずらす。ジャケット自体は変形しない
  (見た目の傾きはLeanDepthPluginの役割)

**質感バラつき**: 同じ疑似乱数源から intensity に 0.85〜1.0 の倍率

**その他**:
- 実効intensity = 設定値 × m × 質感倍率。≈0(≤0.005)なら overlay nil
- `.allowsHitTesting(false)` 必須(タップ再生・D&D・右クリックを食わない)
- オーバーレイ内で角丸clipしない(合成側が適用済み)

## 技術要件・制約

- ロギング: UIアクション・非同期処理・エラー経路に
  `Logger(subsystem: "com.cacheandbuffer.Records", ...)`。
  補間は `\(v, privacy: .public)`。per-cellログ禁止(描画毎に呼ばれる)。
  解決値は once-log で1回だけ
- ファイル追加時は `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate`。
  project.pbxproj 手編集禁止
- `Records --catalog-test <URL>` CLI経路を壊さない
- Shared/ 層はFoundation+osのみ(SwiftUI非依存)
- ビルド: `DEVELOPER_DIR=… xcodebuild -project Records.xcodeproj -scheme Records -configuration Debug -derivedDataPath .build build`

## 完了条件

- [ ] ビルド成功
- [ ] 設定画面で位置9択・強さスライダー・色味4択が操作できる
- [ ] 任意の照明位置で全レコードに段階的に光が当たり、最遠も消えない
- [ ] 各レコードの光沢が光源方向を向く(同一方向の帯ではない)
- [ ] `sleeve-gloss applied:` ログが1回だけ出る
- [ ] 設定がsettings.jsonに保存され再起動後も効く
