//
//  LedgeShelfPlugin.swift
//  Sleeves
//
//  プラグイン「壁掛けウッドレッジ」(構造系、shelfStyle=.ledge)。
//  壁に直接取り付けるレコードディスプレイ用の小さな木製レッジを
//  スロットごとに1つずつ描く。通し棚板・前柵は持たない。
//  レッジは占有・空きを問わず全スロットに描くので、空きスロット
//  には「土台だけ」が残り、配置ガイドとしても見える。
//  壁と経年表現はスタイル非依存のWallPluginが担当する。
//
//  座標はすべて「padding適用済みグリッドの左上原点」
//  (=ShelfStructureContextの定義するフレーム)で計算する。
//   - レッジ: 幅=セル幅×width比(既定1/3、設定で1/3〜11/10)の
//     短い木片。スロットの水平中心の直下に付き、上端をセル下端
//     よりlip分だけ上に延ばしてジャケット下端へ前唇が重なる
//     (=レコードがレッジに載っている見え方)。前面の厚さは
//     設定値を min(設定値, rowSpacing-2, bottomPadding) に
//     クランプして行間と下端余白に収める(棚板と同じ規則)。
//     木目テクスチャの前面+上端の明るい稜線+下端の暗い線+小さな落ち影。
//     テクスチャは等倍で貼り、切り出し位置をスロットごとにずらす。
//     アセットが無いときは従来の縦グラデに退く。
//   - ばらつき(variation): 実物のディスプレイは1枚ごとに
//     置き方が微妙に違うので、スロットindexのsinハッシュで
//     決定論的に中心ずれと傾きを付ける(0なら整列)
//
//  オーバーレイは合成側(ShelfView.shelfGrid)が
//  .allowsHitTesting(false) で重ねるので、再生タップ・D&D・
//  右クリックメニュー・ドロップゾーンは従来通り動く。
//  shelfStyle=.ledgeが選択されていないときはレジストリの
//  resolveShelfで除外される。
//  未保存時の既定は有効(defaultEnabled=true。構造系なので
//  スタイルを選んだ時点で棚らしい見た目になる)。
//

import SwiftUI
import os

struct LedgeShelfPlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Sleeves", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)
    private enum Param {
        /// 木材の色。選択肢idの文字列で永続化
        static let wood = "ledge-wood"
        /// レッジの幅(セル幅に対する比率。1/3〜11/10)
        static let width = "ledge-width"
        /// レッジの厚さ(pt)
        static let thickness = "ledge-thickness"
        /// 前唇の高さ(pt)。レッジ上面がジャケット下端へ重なる量
        static let lip = "ledge-lip"
        /// レッジごとの置き方のばらつき(0-1)
        static let variation = "ledge-variation"
    }

    /// デフォルト値
    private static let defaultWood = WoodMaterial.oak
    /// レッジ幅の既定値(セル幅の1/3)
    static let defaultWidth: Double = 1.0 / 3.0
    static let defaultThickness: Double = 8
    static let defaultLip: Double = 3
    /// 置き方のばらつきの既定値(0-1)
    static let defaultVariation: Double = 0.5

    /// レッジの落ち影の長さ(pt)と濃さ。行間/下端余白に収まる分だけ描く
    private static let shadowLength: CGFloat = 5
    private static let shadowOpacity: Double = 0.20
    /// 落ち影をグラデーションで描ける最小の余白(pt)。これ未満の行は
    /// 影を描かない(棚板と同じ規則)
    private static let shadowMinGap: CGFloat = 3
    /// レッジ上面の稜線(上面が光を拾う表現)
    private static let topEdgeOpacity: Double = 0.28
    /// レッジ下端の暗い線の濃さ
    private static let bottomEdgeOpacity: Double = 0.15
    /// レッジの角丸半径
    private static let cornerRadius: CGFloat = 2
    /// ばらつき最大値: 中心ずれ(セル幅比)と傾き(度)
    private static let maxJitterRatio: Double = 0.07
    private static let maxTiltDegrees: Double = 3.2

    let id = "ledge-shelf"
    let displayName = "Wood Ledges"
    let category: ShelfPluginCategory = .shelf
    /// 構造系プラグインは既定で有効(スタイルを選んだ時点で
    /// 棚らしい見た目にする)
    let defaultEnabled = true
    /// スロットごとの木製レッジはledgeスタイルの支え構造
    let shelfStyle: ShelfSettings.ShelfStyle? = .ledge

    init() {
        Self.logger.info("plugin registered: ledge-shelf ('Wood Ledges')")
    }

    var parameterSpecs: [PluginParameterSpec] {
        [
            .options(.init(
                id: Param.wood,
                label: "Wood",
                choices: WoodMaterial.allCases.map {
                    .init(id: $0.rawValue, label: $0.label)
                },
                defaultValue: Self.defaultWood.rawValue
            )),
            .slider(.init(
                id: Param.width,
                label: "Ledge Width",
                range: (1.0 / 3.0)...(11.0 / 10.0),
                step: 0.01,
                defaultValue: Self.defaultWidth
            )),
            .slider(.init(
                id: Param.thickness,
                label: "Ledge Thickness",
                range: 4...20,
                step: 1,
                defaultValue: Self.defaultThickness
            )),
            .slider(.init(
                id: Param.lip,
                label: "Ledge Lip",
                range: 0...8,
                step: 1,
                defaultValue: Self.defaultLip
            )),
            .slider(.init(
                id: Param.variation,
                label: "Variation",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultVariation
            )),
        ]
    }

    // MARK: - (f) グリッド前面(レッジ)

    func shelfOverlay(context: ShelfStructureContext) -> AnyView? {
        let wood = resolvedWood(context: context)
        let widthRatio = resolvedWidth(context: context)
        let t = resolvedThickness(context: context)
        let lip = resolvedLip(context: context)
        let variance = resolvedVariation(context: context)
        let cell = context.cellSize
        logAppliedOnce(
            wood: wood, width: widthRatio, thickness: t, lip: lip,
            variation: variance, rows: context.gridRows)
        // 描くものが無ければオーバーレイ自体を返さない
        guard t > 0 || lip > 0 else { return nil }

        // 行rのセル下端y(padding込みフレーム座標)
        let bottoms = (0..<context.gridRows).map { r in
            context.topPadding
                + CGFloat(r + 1) * cell
                + CGFloat(r) * context.rowSpacing
        }

        return AnyView(
            Canvas { gc, size in
                guard size.width > 0, size.height > 0 else { return }
                // 木目テクスチャはループの外で1回だけ解決する
                // (素材はStoreShelfPluginの棚板と共通のWoodMaterial)
                let texture = WoodTexture(material: wood, in: gc)
                if !texture.isAvailable { logMissingTextureOnce(material: wood) }
                for (r, bottom) in bottoms.enumerated() {
                    // レッジの下に残る余白(落ち影を描ける分)
                    let gap = (r == bottoms.count - 1)
                        ? max(0, context.bottomPadding - t)
                        : context.rowSpacing - t
                    for c in 0..<context.gridColumns {
                        let slot = r * context.gridColumns + c
                        // 置き方のばらつき: 中心のずれと傾き。
                        // スロットindexのsinハッシュで決定論的に固定
                        let jitterX = (Self.hash01(
                            Double(slot), salt: 5.3) - 0.5)
                            * cell * Self.maxJitterRatio * variance
                        let tilt = (Self.hash01(
                            Double(slot), salt: 9.1) - 0.5)
                            * Self.maxTiltDegrees * variance
                        let centerX = context.edgePadding
                            + CGFloat(c) * (cell + context.columnSpacing)
                            + cell / 2 + jitterX
                        let w = cell * widthRatio
                        // レッジ本体: 上端をセル下端よりlipだけ上に
                        // 延ばしてジャケット下端へ前唇が重なり、
                        // 下端はセル下端からtだけ下へ
                        let rect = CGRect(
                            x: centerX - w / 2,
                            y: bottom - lip,
                            width: w, height: lip + t)
                        // 落ち影: レッジ下端から下へ 黒→0。
                        // 壁に落ちる影なのでレッジの傾きには追従させず
                        // 水平のまま描く(光が斜めなのでわずかに右へ)
                        if t > 0 && gap >= Self.shadowMinGap {
                            let shadowLen = min(Self.shadowLength, gap)
                            let shadowRect = CGRect(
                                x: centerX - w / 2 + 2,
                                y: bottom + t,
                                width: w - 4, height: shadowLen)
                            gc.fill(
                                Path(shadowRect),
                                with: .linearGradient(
                                    Gradient(colors: [
                                        .black.opacity(Self.shadowOpacity),
                                        .clear,
                                    ]),
                                    startPoint: CGPoint(
                                        x: 0, y: shadowRect.minY),
                                    endPoint: CGPoint(
                                        x: 0, y: shadowRect.maxY)))
                        }
                        // レッジ本体: 傾きを付けた角丸の木片
                        var g = gc
                        g.translateBy(x: rect.midX, y: rect.midY)
                        g.rotate(by: .degrees(tilt))
                        g.translateBy(x: -rect.midX, y: -rect.midY)
                        let bodyPath = Path(
                            roundedRect: rect,
                            cornerRadius: Self.cornerRadius)
                        // 切り出し位置はスロットのsinハッシュでずらし、
                        // 1枚ごとに別の板から切った見え方にする
                        // (テクスチャ欠落時はWoodTexture内でグラデに退く)
                        texture.paint(
                            context: g, path: bodyPath, rect: rect,
                            seed: Double(slot))
                        // 天面エッジ: 上面が光を拾う明るい線
                        g.fill(
                            Path(CGRect(
                                x: rect.minX + 1, y: rect.minY,
                                width: rect.width - 2, height: 1)),
                            with: .color(
                                Color(red: 1, green: 0.96, blue: 0.88)
                                    .opacity(Self.topEdgeOpacity)))
                        // 下端の暗い線で縁を締める
                        g.fill(
                            Path(CGRect(
                                x: rect.minX + 1, y: rect.maxY - 1,
                                width: rect.width - 2, height: 1)),
                            with: .color(
                                .black.opacity(Self.bottomEdgeOpacity)))
                    }
                }
            }
            // レッジがジャケットのタップ再生・D&D・右クリック・
            // ドロップゾーンのヒット判定を食わないようにする(必須)
            .allowsHitTesting(false)
        )
    }

    // MARK: - パラメータ解決

    private func resolvedWood(context: ShelfStructureContext) -> WoodMaterial {
        let raw = context.text(Param.wood, default: Self.defaultWood.rawValue)
        return WoodMaterial(rawValue: raw) ?? Self.defaultWood
    }

    /// レッジ幅のセル幅比(1/3〜11/10)
    private func resolvedWidth(context: ShelfStructureContext) -> Double {
        min(11.0 / 10.0, max(1.0 / 3.0,
            context.number(Param.width, default: Self.defaultWidth)))
    }

    /// 実厚。設定値を行間(rowSpacing-2)と下端余白(bottomPadding)に
    /// 収まるようクランプする(棚板と同じ規則)
    private func resolvedThickness(context: ShelfStructureContext) -> CGFloat {
        let raw = context.number(
            Param.thickness, default: Self.defaultThickness)
        return max(0, min(raw, context.rowSpacing - 2, context.bottomPadding))
    }

    /// 前唇の高さ(pt)。ジャケット下端へ重なる量
    private func resolvedLip(context: ShelfStructureContext) -> CGFloat {
        let raw = context.number(Param.lip, default: Self.defaultLip)
        return min(8, max(0, raw))
    }

    /// 置き方のばらつき(0-1)。0なら全レッジが整列
    private func resolvedVariation(context: ShelfStructureContext) -> Double {
        min(1, max(0,
            context.number(Param.variation, default: Self.defaultVariation)))
    }

    /// 任意シードの決定論疑似乱数(0〜1)。sinハッシュ。
    /// スロットごとのずれ・傾きを「そのスロットはいつも同じ値」にする
    private static func hash01(_ seed: Double, salt: Double) -> Double {
        let v = sin(seed * 127.1 + salt * 311.7) * 43758.5453
        return v - v.rounded(.down)
    }

    /// テクスチャアセットの読み込み失敗をプロセス内で1回だけ記録する
    /// (解決は描画のたびに走るので毎回ログは出さない)
    private static var didLogMissingTexture = false
    private func logMissingTextureOnce(material: WoodMaterial) {
        guard !Self.didLogMissingTexture else { return }
        Self.didLogMissingTexture = true
        Self.logger.error("ledge-shelf: wood texture missing asset=\(material.assetName, privacy: .public) (fallback: gradient)")
    }

    /// プロセス内で最初の1回だけ解決値を記録する
    /// (描画のたびに呼ばれるので、毎回ログは出さない。
    ///  有効/無効とパラメータ確定のログはSettingsView側が出す)
    private static var didLogApplied = false
    private func logAppliedOnce(wood: WoodMaterial, width: Double, thickness: CGFloat,
                                lip: CGFloat, variation: Double, rows: Int) {
        guard !Self.didLogApplied else { return }
        Self.didLogApplied = true
        Self.logger.notice("ledge-shelf applied: wood=\(wood.rawValue, privacy: .public) width=\(width, privacy: .public) thickness=\(thickness, privacy: .public) lip=\(lip, privacy: .public) variation=\(variation, privacy: .public) rows=\(rows, privacy: .public)")
    }
}
