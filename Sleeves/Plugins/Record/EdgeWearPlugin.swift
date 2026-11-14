//
//  EdgeWearPlugin.swift
//  Sleeves
//
//  プラグイン「フチ・角の摩耗」(P5)。
//  何度も抜き差しされたレコードジャケットの、白っぽく擦り切れた
//  フチと角のつぶれを再現する。
//
//  実物観測(70枚調査)では、フチの摩耗は「印刷が剥げて下地の紙色
//  (白〜アイボリー)が出た筋」で、四辺均等ではなく抜き差し側の辺
//  (多くは上辺/左辺)や特定の角が特に削れる。このため
//   - 四辺: 辺ごとの偏り係数(上/左を強め)×セルごとの決定論的
//     sinハッシュで摩耗強さを決め、縁でほぼ不透明な紙色から内側へ
//     消えるグラデ帯を「内側境界の深さを位置ごとのハッシュで揺らした
//     ギザギザ多角形」で描き、均一な白枠ではなく不規則に途切れる
//     剥げ筋にする。さらに位置・長さ・太さ・濃さ・深さを散らした
//     楕円フレークを重ねて帯の内側へ食い込む剥げ片を足す
//   - 四隅: 実物は全角一律ではなく特定の角だけが打たれてつぶれる
//     ため、角ごとの出現の有無をセル固有ハッシュで決める
//     (1角あたり確率~0.6、cornersスライダーとは独立)。出ない角は
//     一切描画しない。出た角の実効強度は床付きhash(0.3+0.7h)で
//     底上げし、描画量はフェードイン係数で実効強度に比例させて
//     strength→0+では自然に消える。基盤は角丸アークの内側
//     (頂点から対角線上へ角丸半径+数pt)を中心とする丸い紙色の
//     つぶれパッチで、頂点寄りにずらしたグラデーション中心から
//     内側へフェードさせて「角そのものが丸く潰れた」形にする。
//     そこへ角を挟む2辺に沿った楔状の剥げパッチ(縁で濃く先端へ
//     0に先細る。長さ・深さは辺ごとのハッシュで偏らせる)を重ね、
//     対角線上の紙むけ点で角打ちの立体感を足す
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
        subsystem: "com.cacheandbuffer.Sleeves", category: "Plugins")

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
    let category: ShelfPluginCategory = .record

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

        /// 角を挟む2辺について、(頂点から辺に沿う単位ベクトル,
        /// その辺のセル内側への法線)の組。角打ちの楔パッチを
        /// 辺ごとに描く基準に使う
        var sides: ((dir: CGPoint, n: CGPoint),
                    (dir: CGPoint, n: CGPoint)) {
            switch self {
            case .topLeft:
                return ((CGPoint(x:  1, y: 0), CGPoint(x: 0, y:  1)),
                        (CGPoint(x: 0, y:  1), CGPoint(x: 1, y:  0)))
            case .topRight:
                return ((CGPoint(x: -1, y: 0), CGPoint(x: 0, y:  1)),
                        (CGPoint(x: 0, y:  1), CGPoint(x: -1, y: 0)))
            case .bottomRight:
                return ((CGPoint(x: -1, y: 0), CGPoint(x: 0, y: -1)),
                        (CGPoint(x: 0, y: -1), CGPoint(x: -1, y: 0)))
            case .bottomLeft:
                return ((CGPoint(x:  1, y: 0), CGPoint(x: 0, y: -1)),
                        (CGPoint(x: 0, y: -1), CGPoint(x: 1, y:  0)))
            }
        }

        /// この角に適用されている基盤側の角丸半径
        /// (ShelfPluginLayout.jacketCornerRadii。角丸アークの位置を
        ///  知ってつぶれパッチをその内側へ置くのに使う)
        func clipRadius(_ radii: RectangleCornerRadii) -> CGFloat {
            switch self {
            case .topLeft:     return radii.topLeading
            case .topRight:    return radii.topTrailing
            case .bottomRight: return radii.bottomTrailing
            case .bottomLeft:  return radii.bottomLeading
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
        // 角の出現判定: 実物は全角一律ではなく特定の角だけが
        // 打たれてつぶれる。セル固有ハッシュで角ごとに有無を決める
        // (1角あたり確率~0.6、saltは未使用の30帯。cornersスライダー
        //  とは独立で、スライダーは強さの制御のまま)。
        // 出ない角は強度0=一切描画せず、maxStrengthにも数えない
        let cornerStrengths = Corner.allCases.map {
            guard hash01(30 + Double($0.rawValue), context: context)
                    < 0.6 else { return 0.0 }
            // 出た角の強度は床付き(0.3+0.7h): hashが小さい角でも
            // corners=1.0で消えないよう底上げしつつ、角ごとの
            // ばらつきは残す(corners=0では従来通り全て0)
            return corners * $0.bias
                * (0.3 + 0.7 * hash01(20 + Double($0.rawValue),
                                      context: context))
        }
        let maxStrength = max(edgeStrengths.max() ?? 0,
                              cornerStrengths.max() ?? 0)
        // 実効強度≈0=事実上透明なのでオーバーレイ自体を返さない。
        // 無効時と同じく描画・ヒットの影響ゼロにする(P5-4)
        guard maxStrength > Self.minEffectiveStrength else { return nil }
        logAppliedOnce(amount: amount, corners: corners)

        let cornerRadii = ShelfPluginLayout.jacketCornerRadii(
            cellIndex: context.cellIndex)
        return AnyView(
            Canvas { gc, size in
                for (edge, strength) in zip(Edge.allCases, edgeStrengths)
                where strength > 0 {
                    drawEdgeWear(gc: &gc, size: size, edge: edge,
                                 strength: strength, radii: cornerRadii,
                                 context: context)
                }
                for (corner, strength) in zip(Corner.allCases, cornerStrengths)
                where strength > 0 {
                    drawCornerWear(gc: &gc, size: size, corner: corner,
                                   strength: strength, radii: cornerRadii,
                                   context: context)
                }
            }
            // オーバーレイがジャケットのタップ再生・D&D・右クリックの
            // ヒット判定を食わないようにする(P5-4)
            .allowsHitTesting(false)
        )
    }

    // MARK: - オーバーレイ描画

    /// 1辺の擦り切れを描く。縁でほぼ不透明な紙色から内側へ消える
    /// グラデ帯を、内側境界の深さを位置ごとのハッシュで揺らした
    /// ギザギザの多角形で描き(均一な帯にしない)、その上に
    /// 有無・位置・長さ・太さ・濃さ・深さをハッシュで散らした
    /// 楕円フレークを重ねる
    private func drawEdgeWear(
        gc: inout GraphicsContext, size: CGSize, edge: Edge,
        strength: Double, radii: RectangleCornerRadii, context: ShelfPluginContext
    ) {
        let w = size.width
        let h = size.height
        // 辺の線分(両端は隣接する角の角丸半径の分だけ詰める)と
        // セル内側への法線
        let inset0: CGFloat, inset1: CGFloat
        let p0: CGPoint, p1: CGPoint, n: CGPoint
        switch edge {
        case .top:
            inset0 = radii.topLeading; inset1 = radii.topTrailing
            p0 = CGPoint(x: inset0, y: 0); p1 = CGPoint(x: w - inset1, y: 0)
            n = CGPoint(x: 0, y: 1)
        case .bottom:
            inset0 = radii.bottomLeading; inset1 = radii.bottomTrailing
            p0 = CGPoint(x: inset0, y: h); p1 = CGPoint(x: w - inset1, y: h)
            n = CGPoint(x: 0, y: -1)
        case .left:
            inset0 = radii.topLeading; inset1 = radii.bottomLeading
            p0 = CGPoint(x: 0, y: inset0); p1 = CGPoint(x: 0, y: h - inset1)
            n = CGPoint(x: 1, y: 0)
        case .right:
            inset0 = radii.topTrailing; inset1 = radii.bottomTrailing
            p0 = CGPoint(x: w, y: inset0); p1 = CGPoint(x: w, y: h - inset1)
            n = CGPoint(x: -1, y: 0)
        }
        let dx = p1.x - p0.x
        let dy = p1.y - p0.y
        let len = hypot(dx, dy)
        let paper = Self.paperColor

        // ベース帯: 「縁で最も濃く内側で消える」グラデーションを、
        // 内側境界を~4pt間隔でサンプルして深さをハッシュで揺らした
        // ギザギザ多角形で描く。深さは「連続するランごとの基準値×
        // サンプルごとの微細ジッタ」なので、剥げは一様ノイズではなく
        // 斑のある連続した欠けになる。強い辺(strength≈0.6以上)では
        // 縁の紙色がほぼ不透明で内側へ5〜8ptまで不規則に残る
        let maxDepth = CGFloat(2.5 + 5.5 * strength)
        let peak = min(1, 0.4 + 0.9 * strength)
        let bandSalt = 200 + Double(edge.rawValue) * 37
        let sampleCount = max(6, Int(len / 4))
        let samplesPerRun = 4 // ~16ptごとに剥げの深さ基準が変わる
        var innerPts: [CGPoint] = []
        innerPts.reserveCapacity(sampleCount + 1)
        for i in 0...sampleCount {
            let t = Double(i) / Double(sampleCount)
            let run = i / samplesPerRun
            let hb = hash01(bandSalt + Double(run) * 5.77, context: context)
            // たまにほぼ消えるランを混ぜて筋の「途切れ」を作る
            let base = hb < 0.18 ? 0.05 : 0.45 + 0.55 * hb
            let jit = 0.8 + 0.4 * hash01(bandSalt + Double(i) * 2.39,
                                         context: context)
            // 両端は角のつぶれ側へ浅く逃がして段差を残さない
            let taper = min(1, min(t, 1 - t) * Double(len) / 10)
            let d = maxDepth
                * CGFloat(min(1, max(0.02, base * jit)))
                * CGFloat(max(0.35, taper))
            innerPts.append(CGPoint(x: p0.x + dx * CGFloat(t) + n.x * d,
                                    y: p0.y + dy * CGFloat(t) + n.y * d))
        }
        var band = Path()
        band.move(to: p0)
        band.addLine(to: p1)
        for pt in innerPts.reversed() { band.addLine(to: pt) }
        band.closeSubpath()
        let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        gc.fill(
            band,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: paper.opacity(peak), location: 0),
                    .init(color: paper.opacity(peak * 0.5), location: 0.5),
                    .init(color: .clear, location: 1),
                ]),
                startPoint: mid,
                endPoint: CGPoint(x: mid.x + n.x * maxDepth,
                                  y: mid.y + n.y * maxDepth)
            )
        )

        // フレーク: 辺をzoneに分け、有無・位置・長さ・太さ・濃さ・
        // 深さをセル固有ハッシュで散らす。強い辺ほど太く・濃く・
        // 帯の内側まで食い込み、弱い辺は点々としか剥げない
        let zoneCount = max(8, Int(len / 14))
        for i in 0..<zoneCount {
            let salt = 100 + Double(edge.rawValue) * 31 + Double(i)
            // 出現判定(実効強度が低いほど疎になる)
            guard hash01(salt, context: context)
                    < 0.25 + 0.6 * strength else { continue }
            let hPos = hash01(salt + 0.31, context: context)
            let hLen = hash01(salt + 0.63, context: context)
            let hThk = hash01(salt + 0.85, context: context)
            let hAlp = hash01(salt + 0.17, context: context)
            let hDep = hash01(salt + 0.47, context: context)
            // zone内の中心位置をずらしてフレーク間隔を不規則にする
            let t = (Double(i) + 0.15 + 0.7 * hPos) / Double(zoneCount)
            let segLen = (len / CGFloat(zoneCount))
                * CGFloat(0.45 + 0.9 * hLen)
            let thick = CGFloat(1.0 + 3.5 * hThk * strength)
            let alpha = min(1, strength * (0.35 + 0.7 * hAlp))
            // 縁に接するものから帯の内側境界を越えて食い込むものまで
            let inner = thick * 0.2 + CGFloat(hDep) * maxDepth * 0.55
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

    /// 1角の角打ちを描く。呼ばれるのは jacketOverlay の出現判定を
    /// 通った角だけ(出ない角は強度0でここに来ない)。
    /// 基盤は角丸アークの内側(頂点から対角線
    /// inward方向へ角丸半径+数pt)を中心に置いた丸い紙色のつぶれ
    /// パッチ。頂点中心の円がクリップで消える旧方式の教訓から、
    /// 円の中心はクリップの内側・グラデーション中心だけ頂点寄りに
    /// ずらして「角・両辺側で濃く、セル内側へ消える」つぶれにする。
    /// その上に角を挟む2辺へ沿う楔状の剥げパッチ(縁で濃く、角側で
    /// 最も深く、先端へ0に先細る。長さ・深さは辺ごとのハッシュで
    /// 偏らせる)を重ね、対角線上の紙むけ点で立体感を足す。
    /// 描画量は実効強度に比例させ、strength→0+では自然に消える
    /// (床付きhashで corners 微小でも全角にstrength>0が立つため、
    ///  不透明度・サイズの下限だけでは「スライダーほぼ0なのに
    ///  全角に見える」固定量パッチになってしまう)
    private func drawCornerWear(
        gc: inout GraphicsContext, size: CGSize, corner: Corner,
        strength: Double, radii: RectangleCornerRadii,
        context: ShelfPluginContext
    ) {
        let paper = Self.paperColor
        let vertex = corner.point(in: size)
        let inward = corner.inward
        let clipR = corner.clipRadius(radii)
        let sides = corner.sides
        // フェードイン係数: strength≈0.12以上で1(=現行の強さ)に達し、
        // それ以下では不透明度がstrengthに比例して0へ消える。
        // sizeKはサイズ側の対応係数(弱い角ほどパッチも小さく)
        let vis = min(1, strength / 0.12)
        let sizeK = CGFloat(0.4 + 0.6 * vis)

        // つぶれ本体: 角丸アークの内側を中心とする丸いパッチ。
        // 強い角では半径~10pt(対角線方向に頂点付近から~17pt)まで
        // 広がり「角そのものが丸く潰れた」存在感を出す。
        // グラデーション中心はアークのすぐ内側(頂点寄り)に置き、
        // そこを濃度のピークとして内側へフェードさせる。
        // 中心位置はセル固有ハッシュでわずかにずらす
        let hC = hash01(45 + Double(corner.rawValue), context: context)
        let blobR = CGFloat(4.5 + 5.5 * strength) * sizeK
        let centerOff = clipR + CGFloat(1.5 + 1.5 * hC) + blobR * 0.45
        let bc = CGPoint(x: vertex.x + inward.x * centerOff,
                         y: vertex.y + inward.y * centerOff)
        let gOff = clipR * 0.8 + 0.4
        let gCenter = CGPoint(x: vertex.x + inward.x * gOff,
                              y: vertex.y + inward.y * gOff)
        let endR = (centerOff - gOff) + blobR
        let peak = min(1, 0.5 + 0.8 * strength) * vis
        let blob = Path(ellipseIn: CGRect(
            x: bc.x - blobR, y: bc.y - blobR,
            width: blobR * 2, height: blobR * 2))
        gc.fill(
            blob,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: paper.opacity(peak), location: 0),
                    .init(color: paper.opacity(peak * 0.55), location: 0.45),
                    .init(color: .clear, location: 1),
                ]),
                center: gCenter,
                startRadius: 0,
                endRadius: endR
            )
        )

        // 楔パッチ: つぶれパッチの上に、角を挟む2辺それぞれへ沿う
        // 楔状の剥げを重ねる。頂点から辺に沿ってlength伸び、角側で
        // depthだけ内側へ食い込み、先端では深さ0に先細る四角形。
        // 強い角では辺に沿って最大~19pt・深さ最大~9.5ptまで達し、
        // つぶれから辺の剥げ筋へ繋げる
        let scale = CGFloat(0.5 + 0.5 * strength) * sizeK
        let wedgePeak = min(1, 0.45 + 0.8 * strength) * vis
        for (sideIndex, side) in [sides.0, sides.1].enumerated() {
            let salt = 50 + Double(corner.rawValue) * 11
                + Double(sideIndex) * 3
            let hLen = hash01(salt + 0.11, context: context)
            let hDep = hash01(salt + 0.53, context: context)
            let length = CGFloat(6 + 13 * hLen) * scale
            let depth = CGFloat(3 + 6.5 * hDep) * scale
            let n = side.n
            var wedge = Path()
            wedge.move(to: vertex)
            wedge.addLine(to: CGPoint(x: vertex.x + side.dir.x * length,
                                      y: vertex.y + side.dir.y * length))
            wedge.addLine(to: CGPoint(
                x: vertex.x + side.dir.x * length * 0.5 + n.x * depth * 0.5,
                y: vertex.y + side.dir.y * length * 0.5 + n.y * depth * 0.5))
            wedge.addLine(to: CGPoint(x: vertex.x + n.x * depth,
                                      y: vertex.y + n.y * depth))
            wedge.closeSubpath()
            gc.fill(
                wedge,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: paper.opacity(wedgePeak), location: 0),
                        .init(color: paper.opacity(wedgePeak * 0.45),
                              location: 0.55),
                        .init(color: .clear, location: 1),
                    ]),
                    startPoint: vertex,
                    endPoint: CGPoint(x: vertex.x + n.x * depth,
                                      y: vertex.y + n.y * depth)
                )
            )
        }

        // 紙むけ点: つぶれパッチの中心付近(対角線上3.0〜5.5pt)に
        // 置く明るい点。位置はセル固有ハッシュでずらす。つぶれと
        // 楔パッチに重なってめくれ/つぶれの立体感を足す
        let hOff = hash01(40 + Double(corner.rawValue), context: context)
        let spotOffset = CGFloat(3.0 + 2.5 * hOff)
        let spotRadius = CGFloat(1.8 + 3.0 * strength) * sizeK
        let sc = CGPoint(x: vertex.x + inward.x * spotOffset,
                         y: vertex.y + inward.y * spotOffset)
        let spot = Path(ellipseIn: CGRect(
            x: sc.x - spotRadius, y: sc.y - spotRadius,
            width: spotRadius * 2, height: spotRadius * 2))
        gc.fill(
            spot,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: paper.opacity(
                        min(0.9, 0.35 + 0.65 * strength) * vis),
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
        Self.logger.notice("edge-wear applied: amount=\(amount, privacy: .public) corners=\(corners, privacy: .public) model=jagged-bands+corner-crush+wedges")
    }
}
