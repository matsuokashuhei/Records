//
//  ShelfPlugins.swift
//  Records
//
//  シェルフエフェクトプラグインの基盤。
//  永続化モデル(PluginState/PluginParameterSpec/PluginParameterValue)は
//  Shared/ShelfPluginModel.swift、設定UIはSettingsView.swiftの
//  ShelfEffectSettings、合成点はShelfView.swiftのAlbumSlotView。
//

import SwiftUI
import os

/// ジャケット描画まわりでプラグイン基盤とセルが共有する定数
enum ShelfPluginLayout {
    /// ジャケットの角丸半径。AlbumSlotViewのclipShape/contentShapeと、
    /// ジャケットオーバーレイのクリップで同じ値を使う。
    /// LPジャケットは四角いので0(以前は4ptの角丸だった)
    static let jacketCornerRadius: CGFloat = 0
}

/// プラグインのフックに渡される実行コンテキスト。
/// パラメータ値はspecのデフォルトで解決済み(キー欠損を気にしない)。
struct ShelfPluginContext {
    /// セル(ジャケット)1辺のポイント数。サイズ比例の効果に使う
    let cellSize: CGFloat
    /// パラメータID→値(specのデフォルト値で解決済み)
    let values: [String: PluginParameterValue]
    /// このセル中心の、グリッド内での正規化座標(0〜1)。
    /// (0,0)=グリッド左上端、(1,1)=右下端。照明位置からの距離減衰など
    /// 棚全体にまたがる空間効果に使う。スロットindexと列数から
    /// (列+0.5)/columns, (行+0.5)/rows で計算した均一マッピング
    /// (セル間隔は含まない)
    let cellCenter: CGPoint
    /// グリッドの列数(1以上)。全セル中心の列挙に使う
    let gridColumns: Int
    /// グリッドの行数(1以上)。全セル中心の列挙に使う
    let gridRows: Int

    /// 数値パラメータ。未設定/型違いはfallback
    func number(_ id: String, default fallback: Double = 0) -> Double {
        values[id]?.number ?? fallback
    }
    /// Boolパラメータ(将来のトグル型spec用)
    func flag(_ id: String, default fallback: Bool = false) -> Bool {
        values[id]?.boolean ?? fallback
    }
    /// 文字列パラメータ(将来のenum選択型spec用)
    func text(_ id: String, default fallback: String = "") -> String {
        values[id]?.string ?? fallback
    }
}

/// シェルフエフェクトプラグイン。
///
/// 実装は具象型を作って ShelfPluginRegistry.all に登録するだけで
/// 設定画面への列挙・永続化・セルへの合成まで全部通る。
/// フックは必要なものだけオーバーライドする(デフォルト=何もしない)。
///
/// 拡張性(P0-8): 棚レベルの効果(木枠・区画・ヴィネット等)は、
/// このプロトコルにデフォルト実装付きの新フック(例: shelfOverlay(
/// context:) や transformShelf(_:context:))を追加し、ShelfView側の
/// グリッドを包む合成点を増やす。既存プラグインは無変更で動く。
/// パラメータ型も PluginParameterSpec にcaseを足せばよい
/// (永続化のPluginParameterValueは number/bool/string を受理済み)。
protocol ShelfPlugin {
    /// 安定なID。settings.jsonの "plugins" 辞書キーになるので
    /// 一度決めたら変更しない(変えると保存済みの有効/値が別物扱いになる)
    var id: String { get }
    /// 設定画面のトグル行に出す表示名
    var displayName: String { get }
    /// 調整可能パラメータの定義(並び=設定画面の表示順)
    var parameterSpecs: [PluginParameterSpec] { get }

    /// (a) ジャケット画像本体への修飾(色調・フィルタ等)。
    /// 入力はクリップ済みジャケット。修飾を積んだビューを返す。
    /// レジストリ順に前のプラグインの出力が次の入力になる。
    /// ここでの修飾はジャケット画像にだけ掛かり、後段の
    /// jacketOverlay で重ねる描画には掛からない。
    /// ジャケット面全体の幾何変形(3D回転等)はここではなく
    /// transformJacketSurface に実装すること(ここに回転を積むと
    /// オーバーレイが面からずれて浮いて見える)
    func transformJacket(_ jacket: AnyView, context: ShelfPluginContext) -> AnyView

    /// (b) ジャケット面上へのオーバーレイ重畳。nil=オーバーレイ無し。
    /// transformJacket適用後のジャケットのレイアウト境界に重なり、
    /// 角丸(clipShape)で切られる。複数プラグインはレジストリ順に重なる。
    /// オーバーレイはジャケット面の一部として扱われ、後段の
    /// transformJacketSurface の変形(後傾の3D回転等)に
    /// ジャケットと一緒に追従する
    func jacketOverlay(context: ShelfPluginContext) -> AnyView?

    /// (c) ジャケット面そのものの変形(3D回転等)。
    /// (a)で修飾したジャケット画像+(b)の全オーバーレイを重ねた
    /// 合成物を1枚の面として受け取り、面全体に掛かる変形を積んで返す。
    /// transformJacket(ジャケット画像だけへの修飾)と違い、
    /// オーバーレイにも同じ変形が掛かる。
    /// ジャケット合成の最後の段として、レジストリ順に前の
    /// プラグインの出力が次の入力になる
    func transformJacketSurface(_ surface: AnyView, context: ShelfPluginContext) -> AnyView

    /// (d) セル単位の装飾(影・光等)。セル全体(ジャケット面+
    /// 既定の影+ホバー表示)を包む修飾を返す
    func transformCell(_ cell: AnyView, context: ShelfPluginContext) -> AnyView
}

extension ShelfPlugin {
    var parameterSpecs: [PluginParameterSpec] { [] }
    func transformJacket(_ jacket: AnyView, context: ShelfPluginContext) -> AnyView { jacket }
    func jacketOverlay(context: ShelfPluginContext) -> AnyView? { nil }
    func transformJacketSurface(_ surface: AnyView, context: ShelfPluginContext) -> AnyView { surface }
    func transformCell(_ cell: AnyView, context: ShelfPluginContext) -> AnyView { cell }
}

/// 有効化済みプラグインと解決済みコンテキストのペア
struct ResolvedShelfPlugin {
    let plugin: any ShelfPlugin
    let context: ShelfPluginContext
}

/// 利用可能なプラグインの登録簿。
/// all の並び = 適用順(決定論的) = 設定画面の表示順。
/// プラグイン追加はここに具象型を登録するだけで
/// 設定画面・永続化・合成まで通る。
enum ShelfPluginRegistry {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Records", category: "Plugins")

    /// 登録済みプラグイン一覧。ここに足すだけで設定画面・永続化・
    /// セル合成まで全部通る
    static let all: [any ShelfPlugin] = [
        LeanDepthPlugin(),
        SleeveGlossPlugin(),
        SunFadePlugin(),
        EdgeWearPlugin(),
        YellowingPlugin(),
        RingWearPlugin(),
        ScuffsPlugin(),
    ]

    static func plugin(id: String) -> (any ShelfPlugin)? {
        all.first { $0.id == id }
    }

    /// settingsで有効なプラグインをレジストリ順に、解決済み
    /// コンテキストつきで返す。未登録/無効は含まない。
    /// cellIndexはグリッド内の行優先スロット位置(0始まり)で、
    /// セル中心の正規化座標はここで1回だけ計算する
    /// セル描画のたびに呼ばれる軽量な変換(辞書参照+マージ+数式数個)
    static func resolve(settings: ShelfSettings, cellSize: CGFloat, cellIndex: Int) -> [ResolvedShelfPlugin] {
        checkDuplicateIDs()
        // グリッド次元はsettingsから1以上に正規化
        // (設定UIが1以上に制約しているが、手編集値もここで保護する)
        let columns = max(1, settings.columns)
        let rows = max(1, settings.rows)
        // 行優先index→(列,行)→セル中心の正規化座標(0〜1)
        let col = cellIndex % columns
        let row = cellIndex / columns
        let cellCenter = CGPoint(
            x: (Double(col) + 0.5) / Double(columns),
            y: (Double(row) + 0.5) / Double(rows)
        )
        return all.compactMap { plugin in
            let state = settings.plugins[plugin.id] ?? PluginState()
            guard state.enabled else { return nil }
            return ResolvedShelfPlugin(
                plugin: plugin,
                context: ShelfPluginContext(
                    cellSize: cellSize,
                    values: state.resolvedValues(specs: plugin.parameterSpecs),
                    cellCenter: cellCenter,
                    gridColumns: columns,
                    gridRows: rows
                )
            )
        }
    }

    /// id衝突の検出(resolveの初回呼び出し時に1回だけ走る)。
    /// 衝突は先勝ちで動作自体はするが意図しないのでerrorを出す
    private static var didCheckDuplicateIDs = false
    private static func checkDuplicateIDs() {
        guard !didCheckDuplicateIDs else { return }
        didCheckDuplicateIDs = true
        let counts = Dictionary(grouping: all, by: { $0.id })
        let dupes = counts.filter { $0.value.count > 1 }.keys.sorted()
        if !dupes.isEmpty {
            logger.error("duplicate plugin ids registered: \(dupes.joined(separator: ","), privacy: .public) — first registration wins")
        }
    }
}

extension View {
    /// フック(a)〜(c)の合成: (a)ジャケット画像本体の修飾をレジストリ順に
    /// 積み、(b)その上に各プラグインのオーバーレイを角丸クリップ付きで
    /// 重ね、(c)最後に面全体の変形(3D回転等)をレジストリ順に掛ける。
    /// オーバーレイは(c)の内側で重なっているため、面の変形に
    /// ジャケットと一緒に追従する。
    /// プラグインが無ければ入力のまま(構造も変えない)
    func applyingJacketPlugins(_ resolved: [ResolvedShelfPlugin]) -> AnyView {
        guard !resolved.isEmpty else { return AnyView(self) }
        // (a) ジャケット画像本体の修飾: 前のプラグインの出力が次の入力
        var surface = resolved.reduce(AnyView(self)) { view, r in
            r.plugin.transformJacket(view, context: r.context)
        }
        // (b) オーバーレイ: nilでないものだけレジストリ順に重畳。
        // クリップは(c)の面変形より前の平面の状態で掛ける
        let overlays = resolved.compactMap {
            $0.plugin.jacketOverlay(context: $0.context)
        }
        if !overlays.isEmpty {
            surface = AnyView(surface.overlay {
                ZStack {
                    ForEach(overlays.indices, id: \.self) { overlays[$0] }
                }
                // ジャケットのclipShapeは(a)の前に積まれているため、
                // ここで改めて角丸クリップしないと、セル端まで描く
                // オーバーレイ(斜め帯等)が角丸の外にはみ出す
                .clipShape(RoundedRectangle(cornerRadius: ShelfPluginLayout.jacketCornerRadius))
            })
        }
        // (c) 面全体の変形: ジャケット+全オーバーレイの合成物を
        // 1枚の面として、前のプラグインの出力が次の入力になる
        return resolved.reduce(surface) { view, r in
            r.plugin.transformJacketSurface(view, context: r.context)
        }
    }

    /// フック(d)の合成: セル全体を包む装飾をレジストリ順に積む
    func applyingCellPlugins(_ resolved: [ResolvedShelfPlugin]) -> AnyView {
        guard !resolved.isEmpty else { return AnyView(self) }
        return resolved.reduce(AnyView(self)) { view, r in
            r.plugin.transformCell(view, context: r.context)
        }
    }
}
