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
    /// ジャケットオーバーレイのクリップで同じ値を使う
    static let jacketCornerRadius: CGFloat = 4
}

/// プラグインのフックに渡される実行コンテキスト。
/// パラメータ値はspecのデフォルトで解決済み(キー欠損を気にしない)。
struct ShelfPluginContext {
    /// セル(ジャケット)1辺のポイント数。サイズ比例の効果に使う
    let cellSize: CGFloat
    /// パラメータID→値(specのデフォルト値で解決済み)
    let values: [String: PluginParameterValue]

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

    /// (a) ジャケット本体への修飾(変形・回転等)。
    /// 入力はクリップ済みジャケット。修飾を積んだビューを返す。
    /// レジストリ順に前のプラグインの出力が次の入力になる
    func transformJacket(_ jacket: AnyView, context: ShelfPluginContext) -> AnyView

    /// (b) ジャケットへのオーバーレイ重畳。nil=オーバーレイ無し。
    /// transformJacket適用後のジャケットのレイアウト境界に重なり、
    /// 角丸(clipShape)で切られる。複数プラグインはレジストリ順に重なる。
    /// 注意: transformJacketの変形(3D回転等)はビューの見た目だけを
    /// 変える修飾であり、オーバーレイには適用されない(オーバーレイは
    /// 変形前と同じ平面に描かれる)。後傾系プラグインと併用すると
    /// 帯などがジャケット面からずれて見える場合があるので、
    /// オーバーレイを返すプラグインは自前で同じ変形を当てるか、
    /// ずれても成立する表現にすること
    func jacketOverlay(context: ShelfPluginContext) -> AnyView?

    /// (c) セル単位の装飾(影・光等)。セル全体(ジャケット+オーバーレイ+
    /// 既定の影+ホバー表示)を包む修飾を返す
    func transformCell(_ cell: AnyView, context: ShelfPluginContext) -> AnyView
}

extension ShelfPlugin {
    var parameterSpecs: [PluginParameterSpec] { [] }
    func transformJacket(_ jacket: AnyView, context: ShelfPluginContext) -> AnyView { jacket }
    func jacketOverlay(context: ShelfPluginContext) -> AnyView? { nil }
    func transformCell(_ cell: AnyView, context: ShelfPluginContext) -> AnyView { cell }
}

/// 有効化済みプラグインと解決済みコンテキストのペア
struct ResolvedShelfPlugin {
    let plugin: any ShelfPlugin
    let context: ShelfPluginContext
}

/// 利用可能なプラグインの登録簿。
/// all の並び = 適用順(決定論的) = 設定画面の表示順。
/// 基盤PRでは空。プラグイン追加PRがここに具象型を登録する。
enum ShelfPluginRegistry {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Records", category: "Plugins")

    /// 登録済みプラグイン一覧。ここに足すだけで設定画面・永続化・
    /// セル合成まで全部通る
    static let all: [any ShelfPlugin] = [
        LeanDepthPlugin(),
        // 例: SleeveGlossPlugin(), TopLightPlugin()
    ]

    static func plugin(id: String) -> (any ShelfPlugin)? {
        all.first { $0.id == id }
    }

    /// settingsで有効なプラグインをレジストリ順に、解決済み
    /// コンテキストつきで返す。未登録/無効は含まない。
    /// セル描画のたびに呼ばれる軽量な変換(辞書参照+マージのみ)
    static func resolve(settings: ShelfSettings, cellSize: CGFloat) -> [ResolvedShelfPlugin] {
        checkDuplicateIDs()
        return all.compactMap { plugin in
            let state = settings.plugins[plugin.id] ?? PluginState()
            guard state.enabled else { return nil }
            return ResolvedShelfPlugin(
                plugin: plugin,
                context: ShelfPluginContext(
                    cellSize: cellSize,
                    values: state.resolvedValues(specs: plugin.parameterSpecs)
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
    /// フック(a)+(b)の合成: 有効プラグインのジャケット修飾をレジストリ順に
    /// 積み、その上に各プラグインのオーバーレイを重ねる。
    /// プラグインが無ければ入力のまま(構造も変えない)
    func applyingJacketPlugins(_ resolved: [ResolvedShelfPlugin]) -> AnyView {
        guard !resolved.isEmpty else { return AnyView(self) }
        // (a) ジャケット本体修飾: 前のプラグインの出力が次の入力
        let transformed = resolved.reduce(AnyView(self)) { view, r in
            r.plugin.transformJacket(view, context: r.context)
        }
        // (b) オーバーレイ: nilでないものだけレジストリ順に重畳
        let overlays = resolved.compactMap {
            $0.plugin.jacketOverlay(context: $0.context)
        }
        guard !overlays.isEmpty else { return transformed }
        return AnyView(transformed.overlay {
            ZStack {
                ForEach(overlays.indices, id: \.self) { overlays[$0] }
            }
            // ジャケットのclipShapeは変換前に積まれているため、
            // ここで改めて角丸クリップしないと、セル端まで描く
            // オーバーレイ(斜め帯等)が角丸の外にはみ出す
            .clipShape(RoundedRectangle(cornerRadius: ShelfPluginLayout.jacketCornerRadius))
        })
    }

    /// フック(c)の合成: セル全体を包む装飾をレジストリ順に積む
    func applyingCellPlugins(_ resolved: [ResolvedShelfPlugin]) -> AnyView {
        guard !resolved.isEmpty else { return AnyView(self) }
        return resolved.reduce(AnyView(self)) { view, r in
            r.plugin.transformCell(view, context: r.context)
        }
    }
}
