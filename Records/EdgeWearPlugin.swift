//
//  EdgeWearPlugin.swift
//  Records
//
//  プラグイン「フチ・角の摩耗」(P5)。
//  何度も抜き差しされたレコードジャケットの、白っぽく擦り切れた
//  フチと角のつぶれを再現する。
//
//  実物観測(70枚調査)では、フチの摩耗は「印刷が剥げて下地の紙色
//  (白〜アイボリー)が出た筋」で、四辺均等ではなく抜き差し側の辺
//  (多くは上辺/左辺)や特定の角が特に削れる。このため
//   - 四辺: 辺ごとの偏り係数(上/左を強め)×セルごとの決定論的
//     sinハッシュで摩耗強さを決め、縁に沿った紙色のグラデ帯+
//     位置・長さ・太さを散らした楕円フレークで不規則な剥げ筋にする
//   - 四隅: 幾何頂点を中心にした放射状の紙色パッチが基盤側の
//     角丸クリップで切られ、「頂点がつぶれた」白い三日月になる。
//     角丸アークの内側に小さな紙むけ点を足して角打ちの立体感にする
//  を jacketOverlay で重ねる。角丸クリップ自体は基盤側が適用済み。
//
//  摩耗パターンはセル座標だけから決まる疑似乱数なので、再描画・
//  リロード・再起動を経ても同じセルは同じ剥げ方になる(P5-3)。
//  無効時はレジストリのresolveで除外され、実効強度≈0でも
//  オーバーレイ自体を返さないので残像・レイアウト影響はない(P5-4)。
//

import SwiftUI
import os

struct EdgeWearPlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Records", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)
    private enum Param {
        /// フチの摩耗量(0〜1)
        static let amount = "amount"
        /// 角の摩耗量(0〜1)
        static let corners = "corners"
    }

    /// デフォルトのフチ摩耗量
    static let defaultAmount: Double = 0.35
    /// デフォルトの角摩耗量
    static let defaultCorners: Double = 0.4

    let id = "edge-wear"
    let displayName = "Edge Wear"

    init() {
        Self.logger.info("plugin registered: edge-wear ('Edge Wear')")
    }

    var parameterSpecs: [PluginParameterSpec] {
        [
            .slider(.init(
                id: Param.amount,
                label: "Wear",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultAmount
            )),
            .slider(.init(
                id: Param.corners,
                label: "Corner Wear",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultCorners
            )),
        ]
    }

    // MARK: - (b) ジャケットへのオーバーレイ重畳

    /// 実効強度がこれ以下ならオーバーレイ自体を返さない閾値(P5-4)。
    /// 肉眼でほぼ見えない描画コストを省く下限
    private static let minEffectiveStrength: Double = 0.005

    /// 擦り切れた印刷の下に出る紙の色(実物観測の白〜アイボリー系)
    private static let paperColor = Color(red: 0.90, green: 0.87, blue: 0.80)

    /// フチの辺。摩耗の偏り係数とハッシュsaltの基準に使う
    private enum Edge: Int, CaseIterable {
        case top, right, bottom, left

        /// 実物の偏り。スリーブの抜き差し側(上/左)が特に削れ、
        /// 背表紙側(右)と底辺は残りやすい
        var bias: Double {
            switch self {
            case .top:    return 1.0
            case .left:   return 0.85
            case .bottom: return 0.5
            case .right:  return 0.4
            }
        }
    }

    /// ジャケットの角。角打ちの偏り係数とハッシュsaltの基準に使う
    private enum Corner: Int, CaseIterable {
        case topLeft, topRight, bottomRight, bottomLeft

        /// 角ごとの偏り(辺と同じく左上側が削れやすい)
        var bias: Double {
            switch self {
            case .topLeft:     return 1.0
            case .topRight:    return 0.75
            case .bottomLeft:  return 0.8
            case .bottomRight: return 0.55
            }
        }

        /// 角の幾何頂点からセル内側へ向かう対角線方向(単位ベクトル)
        var inward: CGPoint {
            let d = 0.7071 // 1/√2
            switch self {
            case .topLeft:     return CGPoint(x:  d, y:  d)
            case .topRight:    return CGPoint(x: -d, y:  d)
            case .bottomRight: return CGPoint(x: -d, y: -d)
            case .bottomLeft:  return CGPoint(x:  d, y: -d)
            }
        }

        /// 角の幾何頂点のキャンバス座標
        func point(in size: CGSize) -> CGPoint {
            switch self {
            case .topLeft:     return .zero
            case .topRight:    return CGPoint(x: size.width, y: 0)
            case .bottomRight: return CGPoint(x: size.width, y: size.height)
            case .bottomLeft:  return CGPoint(x: 0, y: size.height)
            }
        }
    }

    func jacketOverlay(context: ShelfPluginContext) -> AnyView? {
        let amount = resolvedAmount(context: context)
        let corners = resolvedCorners(context: context)
        // 辺・角ごとの実効強度=パラメータ×偏り×セル固有ハッシュ。
        // 辺/角によって削れ方が違い(P5-1)、同じセルでは再描画・
        // 再起動を経ても同じパターンになる(P5-3)
        let edgeStrengths = Edge.allCases.map {
            amount * $0.bias * hash01(10 + Double($0.rawValue), context: context)
        }
        let cornerStrengths = Corner.allCases.map {
            corners * $0.bias * hash01(20 + Double($0.rawValue), context: context)
        }
        let maxStrength = max(edgeStrengths.max() ?? 0,
                              cornerStrengths.max() ?? 0)
        // 実効強度≈0=事実上透明なのでオーバーレイ自体を返さない。
        // 無効時と同じく描画・ヒットの影響ゼロにする(P5-4)
        guard maxStrength > Self.minEffectiveStrength else { return nil }
        logAppliedOnce(amount: amount, corners: corners)

        let cornerRadius = ShelfPluginLayout.jacketCornerRadius
        return AnyView(
            Canvas { gc, size in
                for (edge, strength) in zip(Edge.allCases, edgeStrengths)
                where strength > 0 {
                    drawEdgeWear(gc: &gc, size: size, edge: edge,
                                 strength: strength, inset: cornerRadius,
                                 context: context)
                }
                for (corner, strength) in zip(Corner.allCases, cornerStrengths)
                where strength > 0 {
                    drawCornerWear(gc: &gc, size: size, corner: corner,
                                   strength: strength, context: context)
                }
            }
            // オーバーレイがジャケットのタップ再生・D&D・右クリックの
            // ヒット判定を食わないようにする(P5-4)
            .allowsHitTesting(false)
        )
    }

    // MARK: - オーバーレイ描画

    /// 1辺の擦り切れを描く。縁に沿った紙色のグラデ帯(ベースの剥げ)
    /// の上に、有無・位置・長さ・太さ・濃さをハッシュで散らした
    /// 楕円フレークを重ね、「筋一本ではなく不規則に剥げた」
    /// 実物の輪郭にする
    private func drawEdgeWear(
        gc: inout GraphicsContext, size: CGSize, edge: Edge,
        strength: Double, inset: CGFloat, context: ShelfPluginContext
    ) {
        let w = size.width
        let h = size.height
        // 辺の線分(角丸の分だけ両端を詰める)とセル内側への法線
        let p0: CGPoint, p1: CGPoint, n: CGPoint
        switch edge {
        case .top:
            p0 = CGPoint(x: inset, y: 0); p1 = CGPoint(x: w - inset, y: 0)
            n = CGPoint(x: 0, y: 1)
        case .bottom:
            p0 = CGPoint(x: inset, y: h); p1 = CGPoint(x: w - inset, y: h)
            n = CGPoint(x: 0, y: -1)
        case .left:
            p0 = CGPoint(x: 0, y: inset); p1 = CGPoint(x: 0, y: h - inset)
            n = CGPoint(x: 1, y: 0)
        case .right:
            p0 = CGPoint(x: w, y: inset); p1 = CGPoint(x: w, y: h - inset)
            n = CGPoint(x: -1, y: 0)
        }
        let dx = p1.x - p0.x
        let dy = p1.y - p0.y
        let len = hypot(dx, dy)
        let paper = Self.paperColor

        // ベース帯: 辺からbandDepthだけ内側に伸びる帯を、
        // 「縁で濃く内側で消える」グラデーションで埋める。
        // 帯の深さ・濃さはこの辺の実効強度に比例する
        let bandDepth = CGFloat(0.7 + 2.6 * strength)
        let peak = 0.5 * strength
        var band = Path()
        band.move(to: p0)
        band.addLine(to: p1)
        band.addLine(to: CGPoint(x: p1.x + n.x * bandDepth,
                                 y: p1.y + n.y * bandDepth))
        band.addLine(to: CGPoint(x: p0.x + n.x * bandDepth,
                                 y: p0.y + n.y * bandDepth))
        band.closeSubpath()
        let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        gc.fill(
            band,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: paper.opacity(peak), location: 0),
                    .init(color: paper.opacity(peak * 0.45), location: 0.55),
                    .init(color: .clear, location: 1),
                ]),
                startPoint: mid,
                endPoint: CGPoint(x: mid.x + n.x * bandDepth,
                                  y: mid.y + n.y * bandDepth)
            )
        )

        // フレーク: 辺をzoneに分け、有無・位置・長さ・太さ・濃さを
        // セル固有ハッシュで散らす。強い辺ほど密度が上がり、
        // 弱い辺は点々としか剥げない
        let zoneCount = max(8, Int(len / 16))
        for i in 0..<zoneCount {
            let salt = 100 + Double(edge.rawValue) * 31 + Double(i)
            // 出現判定(実効強度が低いほど疎になる)
            guard hash01(salt, context: context)
                    < 0.2 + 0.6 * strength else { continue }
            let hPos = hash01(salt + 0.31, context: context)
            let hLen = hash01(salt + 0.63, context: context)
            let hThk = hash01(salt + 0.85, context: context)
            let hAlp = hash01(salt + 0.17, context: context)
            // zone内の中心位置をずらしてフレーク間隔を不規則にする
            let t = (Double(i) + 0.15 + 0.7 * hPos) / Double(zoneCount)
            let segLen = (len / CGFloat(zoneCount)) * CGFloat(0.35 + 0.6 * hLen)
            let thick = CGFloat(0.5 + 1.9 * hThk * strength)
            let alpha = strength * (0.18 + 0.5 * hAlp)
            // 楕円フレーク。中心は縁から太さの1/4だけ内側に潜らせ、
            // 長径は辺に沿わせる(上下辺=横長、左右辺=縦長)
            let inner = thick * 0.25
            let c = CGPoint(x: p0.x + dx * CGFloat(t) + n.x * inner,
                            y: p0.y + dy * CGFloat(t) + n.y * inner)
            let rect: CGRect
            if n.y != 0 {
                rect = CGRect(x: c.x - segLen / 2, y: c.y - thick / 2,
                              width: segLen, height: thick)
            } else {
                rect = CGRect(x: c.x - thick / 2, y: c.y - segLen / 2,
                              width: thick, height: segLen)
            }
            gc.fill(Path(ellipseIn: rect), with: .color(paper.opacity(alpha)))
        }
    }

    /// 1角の角打ちを描く。幾何頂点を中心に置いた放射状の紙色
    /// パッチが基盤側の角丸クリップで切られ、「頂点がつぶれた」
    /// 白い三日月になる。さらに角丸アークの内側へ小さな紙むけ点を
    /// 置いて、めくれ/つぶれの立体感を足す
    private func drawCornerWear(
        gc: inout GraphicsContext, size: CGSize, corner: Corner,
        strength: Double, context: ShelfPluginContext
    ) {
        let paper = Self.paperColor
        let vertex = corner.point(in: size)

        // つぶれ本体: 頂点中心の放射状グラデ。頂点は角丸クリップの
        // 外なので、角丸アークのくぼみにだけ白い三日月が残る。
        // 強いほど半径が広がり三日月が太くなる
        let radius = CGFloat(2.0 + 6.0 * strength)
        let peak = 0.55 * strength
        let blob = Path(ellipseIn: CGRect(
            x: vertex.x - radius, y: vertex.y - radius,
            width: radius * 2, height: radius * 2))
        gc.fill(
            blob,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: paper.opacity(peak), location: 0),
                    .init(color: paper.opacity(peak * 0.35), location: 0.55),
                    .init(color: .clear, location: 1),
                ]),
                center: vertex,
                startRadius: 0,
                endRadius: radius
            )
        )

        // 紙むけ点: 角丸アークのすぐ内側(対角線上1.8〜3.0pt)に
        // 小さな明るい点。位置はセル固有ハッシュでずらす。
        // 頂点から対角線1.66pt未満は角丸クリップの外なので
        // 見えない領域には置かない
        let hOff = hash01(40 + Double(corner.rawValue), context: context)
        let spotOffset = CGFloat(1.8 + 1.2 * hOff)
        let spotRadius = CGFloat(0.9 + 1.7 * strength)
        let sc = CGPoint(x: vertex.x + corner.inward.x * spotOffset,
                         y: vertex.y + corner.inward.y * spotOffset)
        let spot = Path(ellipseIn: CGRect(
            x: sc.x - spotRadius, y: sc.y - spotRadius,
            width: spotRadius * 2, height: spotRadius * 2))
        gc.fill(
            spot,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: paper.opacity(min(0.7, 0.75 * strength)),
                          location: 0),
                    .init(color: .clear, location: 1),
                ]),
                center: sc,
                startRadius: 0,
                endRadius: spotRadius
            )
        )
    }

    // MARK: - パラメータ解決

    private func resolvedAmount(context: ShelfPluginContext) -> Double {
        min(1, max(0, context.number(Param.amount, default: Self.defaultAmount)))
    }

    private func resolvedCorners(context: ShelfPluginContext) -> Double {
        min(1, max(0, context.number(Param.corners, default: Self.defaultCorners)))
    }

    /// セル座標からの決定論的疑似乱数(0〜1)。SleeveGlossPluginと
    /// 同じsinハッシュ方式。同じセルでは再描画・リロード・再起動を
    /// 経ても同じ値になる(乱数生成器や状態の保持はしない)。
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
    private func logAppliedOnce(amount: Double, corners: Double) {
        guard !Self.didLogApplied else { return }
        Self.didLogApplied = true
        Self.logger.notice("edge-wear applied: amount=\(amount, privacy: .public) corners=\(corners, privacy: .public) model=edge-bands+corner-patches")
    }
}
