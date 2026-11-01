//
//  ScuffsPlugin.swift
//  Records
//
//  プラグイン「スカッフ(擦りキズ)」。
//  ジャケット表面の髪の毛状の細い擦り傷と、白い斑点状の
//  すり傷を再現する。実物では暗いジャケットで特に目立つ。
//

import SwiftUI
import os

struct ScuffsPlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Records", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)
    private enum Param {
        /// 傷の量・密度(0〜1)
        static let amount = "amount"
        /// 傷の種類。選択肢idの文字列で永続化
        static let style = "style"
    }

    /// 傷の種類。rawValueはsettings.jsonへの永続化値なので
    /// 一度決めたら変更しない
    private enum Style: String, CaseIterable {
        /// 髪の毛状の細い線傷のみ
        case hairline
        /// 白い斑点状のすり傷のみ
        case speckles
        /// 両方
        case both

        /// 表示ラベル(Localizable.xcstringsのキー)
        var label: String {
            switch self {
            case .hairline: return "Hairline"
            case .speckles: return "Speckles"
            case .both: return "Hairline + Speckles"
            }
        }
    }

    /// デフォルトの傷の量
    static let defaultAmount: Double = 0.4
    /// デフォルトの種類
    private static let defaultStyle = Style.both

    let id = "scuffs"
    let displayName = "Scuffs"

    init() {
        Self.logger.info("plugin registered: scuffs ('Scuffs')")
    }

    var parameterSpecs: [PluginParameterSpec] {
        [
            .slider(.init(
                id: Param.amount,
                label: "Amount",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultAmount
            )),
            .options(.init(
                id: Param.style,
                label: "Style",
                choices: Style.allCases.map {
                    .init(id: $0.rawValue, label: $0.label)
                },
                defaultValue: Self.defaultStyle.rawValue
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
    /// 線傷1本が消費するsalt数(中心x,y・向き・長さ・湾曲・
    /// 線幅・濃さ・色味の8個分を余裕持たせて10とする)
    private static let saltsPerLine: Double = 10

    /// 斑点(speckles)の疑似乱数saltの基点。
    /// クラスタcのパラメータは salt = base + c*saltsPerCluster + …
    private static let saltSpeckle: Double = 1000
    /// 斑点クラスタ1個が消費するsalt数(ヘッダ4個+各点4個×
    /// 最大点数を余裕持たせて100とする)
    private static let saltsPerCluster: Double = 100
    /// クラスタの点1個が消費するsalt数(角度・半径・径・濃さ)
    private static let saltsPerSpeckleDot: Double = 4

    /// 線傷の最大本数(amount=1・密度係数1のセル)。
    /// 実物は数本〜十数本で、セルごとの密度係数(0.4〜1.0)を掛ける
    private static let maxLines: Double = 14
    /// 斑点クラスタの最大個数(amount=1・密度係数1のセル)
    private static let maxClusters: Double = 6
    /// クラスタ内の斑点の個数範囲(実物は小さな点の集まり)
    private static let dotsPerCluster: ClosedRange<Int> = 3...10

    /// 線傷の長さ(セル一辺に対する割合)の範囲。短い弧〜直線
    private static let lineLengthRange: ClosedRange<Double> = 0.08...0.35
    /// 線傷の線幅(pt)の範囲。髪の毛状なので細め
    private static let lineWidthRange: ClosedRange<Double> = 0.5...1.5
    /// 線傷の不透明度の範囲。実物は繊細で主張しすぎない
    private static let lineOpacityRange: ClosedRange<Double> = 0.05...0.2
    /// 線傷の弧の湾曲の最大値(長さに対する割合)。
    /// 制御点を法線方向へずらす量で、0=直線
    private static let maxLineBend: Double = 0.3

    /// 斑点クラスタの広がり半径(セル一辺に対する割合)の範囲
    private static let clusterSpreadRange: ClosedRange<Double> = 0.03...0.12
    /// 斑点1個の径(pt)の範囲(実物は1〜3ptの小さな点)
    private static let speckleSizeRange: ClosedRange<Double> = 1...3
    /// 斑点の不透明度の範囲。白いすり傷だが淡く保つ
    private static let speckleOpacityRange: ClosedRange<Double> = 0.06...0.25

    /// セルごとの密度係数の範囲。実物は傷の量が盤ごとに
    /// 偏るので、amountが同じでもセルによって傷の多寡をつける
    private static let densityFactorRange: ClosedRange<Double> = 0.4...1.0

    func jacketOverlay(context: ShelfPluginContext) -> AnyView? {
        let amount = resolvedAmount(context: context)
        // 実効量≈0=事実上無傷なのでオーバーレイ自体を返さない
        // (無効時と同じく描画・ヒットの影響ゼロにする)
        guard amount > Self.minEffectiveAmount else { return nil }
        let style = resolvedStyle(context: context)
        let lineCount = style == .speckles
            ? 0 : lineCount(amount: amount, context: context)
        let clusterCount = style == .hairline
            ? 0 : clusterCount(amount: amount, context: context)
        // 傷が1つも無いセルでは空のCanvasを積まずオーバーレイを返さない
        guard lineCount > 0 || clusterCount > 0 else { return nil }
        // ログのamountは設定値そのまま(セルごとの本数は参考情報)
        logAppliedOnce(amount: amount, style: style,
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
    /// 1本は二次ベジェの短い弧(湾曲が小さいほど直線に見える)。
    /// 傷iのsalt基点は saltHairline + i*saltsPerLine で、
    /// そこから連番で中心・向き・長さ・湾曲・線幅・濃さ・色味を引く
    /// (決定論的: 同じセルでは再描画・再起動でも同じ傷になる)
    private func drawHairlines(_ gc: inout GraphicsContext, size: CGSize,
                               count: Int, context: ShelfPluginContext) {
        for i in 0..<count {
            let base = Self.saltHairline + Double(i) * Self.saltsPerLine
            func r(_ k: Double) -> Double {
                hash01(base + k, context: context)
            }
            let cx = r(0) * size.width
            let cy = r(1) * size.height
            let angle = r(2) * 2 * .pi
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
            let opacity = Self.lineOpacityRange.lerp(r(6))
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
    /// ヘッダ(中心x,y・半径・点数)にsalt 0〜3、点dには
    /// 4 + d*saltsPerSpeckleDot から連番で角度・半径・径・濃さを引く
    private func drawSpeckles(_ gc: inout GraphicsContext, size: CGSize,
                              count: Int, context: ShelfPluginContext) {
        for c in 0..<count {
            let base = Self.saltSpeckle + Double(c) * Self.saltsPerCluster
            func r(_ k: Double) -> Double {
                hash01(base + k, context: context)
            }
            // クラスタ中心はセル縁から少し内側(点が大半はみ出さない程度)
            let cx = (0.08 + 0.84 * r(0)) * size.width
            let cy = (0.08 + 0.84 * r(1)) * size.height
            let spread = Self.clusterSpreadRange.lerp(r(2)) * size.width
            let dots = Self.dotsPerCluster.lowerBound
                + Int(r(3) * Double(Self.dotsPerCluster.upperBound
                                    - Self.dotsPerCluster.lowerBound + 1))
            for d in 0..<dots {
                let db = base + 4 + Double(d) * Self.saltsPerSpeckleDot
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

    private func resolvedAmount(context: ShelfPluginContext) -> Double {
        min(1, max(0,
            context.number(Param.amount, default: Self.defaultAmount)))
    }

    private func resolvedStyle(context: ShelfPluginContext) -> Style {
        // 手編集や古い値で未知の文字列が入ってもbothに倒す
        let raw = context.text(Param.style, default: Self.defaultStyle.rawValue)
        return Style(rawValue: raw) ?? .both
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
    private func logAppliedOnce(amount: Double, style: Style,
                                lines: Int, clusters: Int) {
        guard !Self.didLogApplied else { return }
        Self.didLogApplied = true
        Self.logger.notice("scuffs applied: amount=\(amount, privacy: .public) style=\(style.rawValue, privacy: .public) lines=\(lines, privacy: .public) clusters=\(clusters, privacy: .public)")
    }
}

private extension ClosedRange where Bound == Double {
    /// 範囲の両端の間をt(0〜1)で線形補間する
    func lerp(_ t: Double) -> Double {
        lowerBound + (upperBound - lowerBound) * t
    }
}
