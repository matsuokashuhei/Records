//
//  ScuffsPlugin.swift
//  Sleeves
//
//  プラグイン「スカッフ(擦りキズ)」。
//  ジャケット表面の髪の毛状の細い擦り傷と、白い斑点状の
//  すり傷を再現する。実物では暗いジャケットで特に目立つ。
//

import SwiftUI
import os

struct ScuffsPlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Sleeves", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)
    private enum Param {
        /// 線傷(hairline)の量・密度(0〜3、1=従来の最大)
        static let hairline = "hairline"
        /// 斑点(speckles)の量・密度(0〜3、1=従来の最大)
        static let speckles = "speckles"
    }

    /// デフォルトの線傷の量
    static let defaultHairline: Double = 0.4
    /// デフォルトの斑点の量
    static let defaultSpeckles: Double = 0.4
    /// 量パラメータの範囲。1.0=従来の最大密度で、
    /// 上限3.0まで効きを強められる(値=密度倍率として線形に効く)
    private static let amountRange: ClosedRange<Double> = 0...3

    let id = "scuffs"
    let displayName = "Scuffs"
    let category: ShelfPluginCategory = .record

    init() {
        Self.logger.info("plugin registered: scuffs ('Scuffs')")
    }

    var parameterSpecs: [PluginParameterSpec] {
        [
            .slider(.init(
                id: Param.hairline,
                label: "Hairline",
                range: Self.amountRange,
                step: 0.01,
                defaultValue: Self.defaultHairline
            )),
            .slider(.init(
                id: Param.speckles,
                label: "Speckles",
                range: Self.amountRange,
                step: 0.01,
                defaultValue: Self.defaultSpeckles
            )),
        ]
    }

    // MARK: - (b) ジャケットへのオーバーレイ重畳

    /// 実効量がこれ以下ならオーバーレイ自体を返さない閾値。
    /// 肉眼でほぼ見えない傷の描画コストを省く下限(P8-4)
    private static let minEffectiveAmount: Double = 0.005

    /// 線傷(hairline)の疑似乱数saltの基点。
    /// 傷iのパラメータは salt = base + i*saltsPerLine + k の連番で取る
    private static let saltHairline: Double = 100
    /// 線傷1本が消費するsalt数(中心x,y・stray判定・長さ・湾曲・
    /// 線幅・濃さ・色味・向きのk=0-8を使用、余裕持たせて10とする)
    private static let saltsPerLine: Double = 10

    /// 斑点(speckles)の疑似乱数saltの基点。
    /// クラスタcのパラメータは salt = base + c*saltsPerCluster + …
    private static let saltSpeckle: Double = 1000
    /// 斑点クラスタ1個が消費するsalt数(ヘッダはk=0-4を使用、
    /// 0-7を予約。点は+8から各4個×最大点数。余裕持たせて100)
    private static let saltsPerCluster: Double = 100
    /// クラスタの点1個が消費するsalt数(角度・半径・径・濃さ)
    private static let saltsPerSpeckleDot: Double = 4

    /// 線傷の基準本数(hairline=1=従来の最大・密度係数1のセル)。
    /// 実物は数本〜十数本で、量パラメータとセルごとの
    /// 密度係数(0.4〜1.0)を掛ける(hairline=3で最大42本)
    private static let maxLines: Double = 14
    /// 斑点クラスタの基準個数(speckles=1・密度係数1のセル。
    /// speckles=3で最大18個)
    private static let maxClusters: Double = 6
    /// クラスタ内の斑点の個数範囲(実物は小さな点の集まり)
    private static let dotsPerCluster: ClosedRange<Int> = 3...10

    /// 線傷の長さ(セル一辺に対する割合)の範囲。実物の
    /// ヘアライン傷はセルのかなりの部分を横切る長いものが多い
    private static let lineLengthRange: ClosedRange<Double> = 0.12...0.55
    /// 線傷の線幅(pt)の範囲。髪の毛状なので細め
    private static let lineWidthRange: ClosedRange<Double> = 0.4...1.2
    /// 線傷の不透明度の範囲。実物は繊細で主張しすぎない
    /// (濃さはpowで淡い側に偏らせる — 大半はうっすら、ごく一部だけ見える)
    private static let lineOpacityRange: ClosedRange<Double> = 0.05...0.2
    /// 線傷がセルごとの主方向から外れる確率。
    /// 実物の傷はおおむね同じ向きだが、少量の外れ傷が混ざる
    private static let strayLineRate: Double = 0.18
    /// 主方向に沿う傷の角度ばらつき(±rad、約17°)。
    /// 完全平行だと機械的に見えるので緩く揺らす
    private static let angleJitter: Double = 0.3
    /// 線傷の弧の湾曲の最大値(長さに対する割合)。
    /// 制御点を法線方向へずらす量で、0=直線
    private static let maxLineBend: Double = 0.3

    /// 斑点クラスタが集まる「すれ跡エリア」の広がり
    /// (セル一辺に対する割合)。実物の斑点は全面一様ではなく、
    /// 棚や手が触れる場所に集中して付く
    private static let focalSpread: Double = 0.2
    /// 斑点クラスタの広がり半径(セル一辺に対する割合)の範囲
    private static let clusterSpreadRange: ClosedRange<Double> = 0.03...0.12
    /// 斑点1個の径(pt)の範囲(実物は1〜3ptの小さな点)
    private static let speckleSizeRange: ClosedRange<Double> = 1...3
    /// 斑点の不透明度の範囲。白いすり傷だが淡く保つ
    private static let speckleOpacityRange: ClosedRange<Double> = 0.06...0.25

    /// セルごとの密度係数の範囲。実物は傷の量が盤ごとに
    /// 偏るので、量パラメータが同じでもセルによって傷の多寡をつける
    private static let densityFactorRange: ClosedRange<Double> = 0.4...1.0

    func jacketOverlay(context: ShelfPluginContext) -> AnyView? {
        let hairline = resolvedAmount(
            Param.hairline, default: Self.defaultHairline, context: context)
        let speckles = resolvedAmount(
            Param.speckles, default: Self.defaultSpeckles, context: context)
        // 実効量≈0の種類は傷なし扱いで描画コストを省く。
        // 両方≈0ならオーバーレイ自体を返さない
        // (無効時と同じく描画・ヒットの影響ゼロにする)
        let lineCount = hairline > Self.minEffectiveAmount
            ? lineCount(amount: hairline, context: context) : 0
        let clusterCount = speckles > Self.minEffectiveAmount
            ? clusterCount(amount: speckles, context: context) : 0
        // 傷が1つも無いセルでは空のCanvasを積まずオーバーレイを返さない
        guard lineCount > 0 || clusterCount > 0 else { return nil }
        // ログの量は設定値そのまま(セルごとの本数は参考情報)
        logAppliedOnce(hairline: hairline, speckles: speckles,
                       lines: lineCount, clusters: clusterCount)

        return AnyView(
            Canvas { gc, size in
                // ゼロサイズでは傷の長さが0で除算がNaNになるので抜ける
                guard size.width > 0, size.height > 0 else { return }
                if lineCount > 0 {
                    self.drawHairlines(&gc, size: size, count: lineCount,
                                       context: context)
                }
                if clusterCount > 0 {
                    self.drawSpeckles(&gc, size: size, count: clusterCount,
                                      context: context)
                }
            }
            // オーバーレイがジャケットのタップ再生・D&D・右クリックの
            // ヒット判定を食わないようにする
            .allowsHitTesting(false)
        )
    }

    // MARK: - オーバーレイ描画

    /// (a) 髪の毛状の細い淡い線傷をcount本描く。
    /// 1本は二次ベジェの弧(湾曲が小さいほど直線に見える)。
    /// 傷iのsalt基点は saltHairline + i*saltsPerLine で、
    /// そこから連番で中心・向き・長さ・湾曲・線幅・濃さ・色味を引く
    /// (決定論的: 同じセルでは再描画・再起動でも同じ傷になる)。
    /// 向きはセルごとの主方向±angleJitterに揃える(実物はスリーブへの
    /// 出し入れ等で同じ向きに傷が付くため。strayLineRateの割合だけ
    /// 向きの違う外れ傷を混ぜる)。salt 50/60帯はセル単位の
    /// 主方向・集中エリア用に確保(線傷salt基点は100から)
    private func drawHairlines(_ gc: inout GraphicsContext, size: CGSize,
                               count: Int, context: ShelfPluginContext) {
        // セルごとの傷の主方向(0〜π。傷に表裏はないので軸として扱う)
        let main = hash01(50, context: context) * .pi
        for i in 0..<count {
            let base = Self.saltHairline + Double(i) * Self.saltsPerLine
            func r(_ k: Double) -> Double {
                hash01(base + k, context: context)
            }
            let cx = r(0) * size.width
            let cy = r(1) * size.height
            let angle = r(2) < Self.strayLineRate
                ? r(8) * .pi
                : main + (r(8) * 2 - 1) * Self.angleJitter
            let len = Self.lineLengthRange.lerp(r(3)) * size.width
            // 端点は中心から向き方向へ半長ずつ、制御点は法線方向へ
            // 湾曲分ずらす(長さの±maxLineBendまでの緩い弧)
            let dx = cos(angle) * len * 0.5
            let dy = sin(angle) * len * 0.5
            let bend = (r(4) * 2 - 1) * len * Self.maxLineBend
            var path = Path()
            path.move(to: CGPoint(x: cx - dx, y: cy - dy))
            path.addQuadCurve(
                to: CGPoint(x: cx + dx, y: cy + dy),
                control: CGPoint(x: cx - dy / (len * 0.5) * bend,
                                 y: cy + dx / (len * 0.5) * bend)
            )
            let width = Self.lineWidthRange.lerp(r(5))
            let opacity = Self.lineOpacityRange.lerp(pow(r(6), 1.5))
            // 白〜淡いグレー。紙色が透けて見えるすり傷の近似
            let whiteness = 0.85 + 0.15 * r(7)
            gc.stroke(
                path,
                with: .color(Color(white: whiteness).opacity(opacity)),
                lineWidth: width
            )
        }
    }

    /// (b) 白い斑点状のすり傷をcountクラスタ分描く。
    /// 1クラスタは中心+広がり半径を持つ小さな点群で、
    /// クラスタcのsalt基点は saltSpeckle + c*saltsPerCluster。
    /// ヘッダ(salt 0〜7: エリア選択・中心x,y・半径・点数)を引き、
    /// 点dには 8 + d*saltsPerSpeckleDot から連番で角度・半径・径・
    /// 濃さを引く。クラスタ中心は全面一様ではなく、セルごとの
    /// 「すれ跡エリア」(1〜3箇所、salt 60帯)の周辺±focalSpreadに
    /// 集まる — 実物は棚や手が触れる場所に斑点が集中する
    private func drawSpeckles(_ gc: inout GraphicsContext, size: CGSize,
                              count: Int, context: ShelfPluginContext) {
        // セルごとのすれ跡エリア数(1〜3箇所)
        let focalCount = 1 + Int(hash01(60, context: context) * 2.99)
        for c in 0..<count {
            let base = Self.saltSpeckle + Double(c) * Self.saltsPerCluster
            func r(_ k: Double) -> Double {
                hash01(base + k, context: context)
            }
            // どのすれ跡エリアに属するかを選び、そのエリア中心の
            // 周辺にクラスタを置く(エリア内で重なって密度差が出る)
            let f = Int(r(0) * Double(focalCount))
            let fx = (0.1 + 0.8 * hash01(61 + Double(f) * 13,
                                        context: context)) * size.width
            let fy = (0.1 + 0.8 * hash01(61 + Double(f) * 13 + 1,
                                        context: context)) * size.height
            let cx = fx + (r(1) * 2 - 1) * Self.focalSpread * size.width
            let cy = fy + (r(2) * 2 - 1) * Self.focalSpread * size.height
            let spread = Self.clusterSpreadRange.lerp(r(3)) * size.width
            let dots = Self.dotsPerCluster.lowerBound
                + Int(r(4) * Double(Self.dotsPerCluster.upperBound
                                    - Self.dotsPerCluster.lowerBound + 1))
            for d in 0..<dots {
                let db = base + 8 + Double(d) * Self.saltsPerSpeckleDot
                func rd(_ k: Double) -> Double {
                    hash01(db + k, context: context)
                }
                let a = rd(0) * 2 * .pi
                // sqrtで円盤内一様分布(中心寄りに偏らせない)
                let dist = sqrt(rd(1)) * spread
                let dot = Self.speckleSizeRange.lerp(rd(2))
                let opacity = Self.speckleOpacityRange.lerp(rd(3))
                gc.fill(
                    Path(ellipseIn: CGRect(
                        x: cx + cos(a) * dist - dot * 0.5,
                        y: cy + sin(a) * dist - dot * 0.5,
                        width: dot, height: dot
                    )),
                    with: .color(.white.opacity(opacity))
                )
            }
        }
    }

    // MARK: - パラメータ解決

    /// 量パラメータをspec範囲(0〜3)にクランプして解決する
    private func resolvedAmount(_ id: String, default fallback: Double,
                                context: ShelfPluginContext) -> Double {
        min(Self.amountRange.upperBound,
            max(Self.amountRange.lowerBound,
                context.number(id, default: fallback)))
    }

    /// セルごとの密度係数(0.4〜1.0)。同じamountでもセルによって
    /// 傷の量に差が出るようにする。kindで線傷/斑点を独立に引く
    private func densityFactor(_ kind: Double,
                               context: ShelfPluginContext) -> Double {
        let r = Self.densityFactorRange
        return r.lowerBound + (r.upperBound - r.lowerBound)
            * hash01(kind, context: context)
    }

    /// 線傷の本数。amountに比例し、セルごとの密度係数でばらつく
    private func lineCount(amount: Double,
                           context: ShelfPluginContext) -> Int {
        Int((Self.maxLines * amount
            * densityFactor(1, context: context)).rounded())
    }

    /// 斑点クラスタの個数。amountに比例し、セルごとの密度係数でばらつく
    private func clusterCount(amount: Double,
                              context: ShelfPluginContext) -> Int {
        Int((Self.maxClusters * amount
            * densityFactor(2, context: context)).rounded())
    }

    /// セル座標からの決定論的疑似乱数(0〜1)。同じセルでは
    /// 再描画・リロード・リブートを経ても同じ値になる
    /// (sinハッシュ。乱数生成器や状態の保持はしない)。
    /// saltは同一セルから複数の独立した値を取るための種
    private func hash01(_ salt: Double, context: ShelfPluginContext) -> Double {
        let seed = context.cellCenter.x * 127.1
            + context.cellCenter.y * 311.7
            + salt * 74.7
        let v = sin(seed) * 43758.5453123
        return v - v.rounded(.down)
    }

    /// プロセス内で最初の1回だけ解決値を記録する
    /// (セル描画のたびに呼ばれるので、毎回ログは出さない。
    ///  有効/無効とパラメータ確定のログはSettingsView側が出す)
    private static var didLogApplied = false
    private func logAppliedOnce(hairline: Double, speckles: Double,
                                lines: Int, clusters: Int) {
        guard !Self.didLogApplied else { return }
        Self.didLogApplied = true
        Self.logger.notice("scuffs applied: hairline=\(hairline, privacy: .public) speckles=\(speckles, privacy: .public) lines=\(lines, privacy: .public) clusters=\(clusters, privacy: .public)")
    }
}

private extension ClosedRange where Bound == Double {
    /// 範囲の両端の間をt(0〜1)で線形補間する
    func lerp(_ t: Double) -> Double {
        lowerBound + (upperBound - lowerBound) * t
    }
}
