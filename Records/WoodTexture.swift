//
//  WoodTexture.swift
//  Records
//
//  プロシージャル木目テクスチャ生成(フィールドベース)。
//  nmpowell/texture-generator (Python/NumPy) の wood.py の
//  アルゴリズムを移植したもの。ベクター図形の重ね描きではなく、
//  ピクセルごとに「この位置は成長輪のどの位相か」を評価して
//  色を決める:
//
//   - 髄心(pith)までの距離場 r をドメインワープして引く。
//     ワープした座標で r を取るので輪のラインが有機的に歪み、
//     pith軸が板面の下を潜る「cathedral」カットでは山型杢
//     (平目)が明示的な弧を描かずに自然に現れる
//   - 輪幅は等間隔ではなく AR(1) 対数正規 + 成熟トレンドの
//     「成長した輪幅系列」を累積した半径ルックアップ。
//     同じ幅の輪が2つと無い
//   - 輪内プロファイルは鋸歯: 早材→晩材の滑らかな上昇と
//     輪境界の不連続ステップ。遷移幅・晩材比は材の気孔
//     クラス(softwood/ring-porous/semi-ring-porous)で決まる
//   - 節は輪座標を半径方向に引き寄せる pull 場 + 暗い楕円。
//     節のまわりで輪が自然に曲がる
//   - 細スジは 30〜80 倍異方性の fbm、面のトーンむらは
//     低周波 fbm、輪ごとの強弱は輪番号のハッシュ
//
//  乱数はすべて seed からの決定論(描画は毎フレーム走るので
//  結果は同一メンバーに対し常に同一)。出力は RGBA8 の CGImage。
//

import CoreGraphics
import Foundation

enum WoodTexture {

    /// 材の気孔クラス。輪内プロファイル(晩材の幅と境界の
    /// 鋭さ)と輪幅統計を決める
    enum PoreClass {
        /// 針葉樹(パイン)。輪の境が最も鋭く、晩材は細い濃線
        case softwood
        /// 環孔材(オーク)。早材管胞帯が太く、境界は固定mm幅で鋭い
        case ringPorous
        /// 半環孔材(ウォールナット)。境は中程度の鋭さ
        case semiRingPorous

        /// 輪内プロファイル: 晩材が輪に占める割合のレンジ
        var lateFrac: (Double, Double) {
            switch self {
            case .softwood:       return (0.15, 0.30)
            case .ringPorous:     return (0.50, 0.85)
            case .semiRingPorous: return (0.40, 0.70)
            }
        }
        /// 遷移幅。ring-porousは固定mm(広い輪ほど相対的に鋭い)、
        /// 他は輪幅に対する割合
        var transitionMM: (Double, Double)? {
            self == .ringPorous ? (0.10, 0.30) : nil
        }
        var transitionFrac: (Double, Double) {
            switch self {
            case .softwood:       return (0.10, 0.22)
            case .ringPorous:     return (0, 0) // transitionMMを使う
            case .semiRingPorous: return (0.30, 0.60)
            }
        }
        /// lw_fracを輪幅で補間するレンジ(環孔材のみ。
        /// 広い輪=晩材が多い、細い輪=早材帯が幅を食う)
        var lateFracWidthMM: (Double, Double)? {
            self == .ringPorous ? (1.0, 4.0) : nil
        }
        /// 輪幅系列の統計(mm): 対数幅の平均と標準偏差
        var ringMeanMM: (Double, Double) {
            switch self {
            case .softwood:       return (1.8, 3.5)
            case .ringPorous:     return (1.8, 3.5)
            case .semiRingPorous: return (1.5, 3.2)
            }
        }
        var ringSigma: (Double, Double) {
            switch self {
            case .softwood:       return (0.28, 0.35)
            default:              return (0.24, 0.32)
            }
        }
        /// 輪の線の強さ係数(<=1で使用)
        var lineStrength: Double {
            switch self {
            case .softwood:       return 1.0 // 1.3→cap
            case .ringPorous:     return 1.0
            case .semiRingPorous: return 0.75
            }
        }
    }

    /// 生成パラメータ。色は早材・晩材の2色(プロファイルで補間)
    struct Profile {
        var early: (r: Double, g: Double, b: Double)
        var late: (r: Double, g: Double, b: Double)
        var poreClass: PoreClass
        /// 板の面に見える輪数のレンジ(面のmm幅 ÷ 平均輪幅)
        var ringsAcross: (Double, Double)
        /// 節が入る確率(メンバー1つにつき最大1個)
        var knotProbability: Double
    }

    /// 決定論RNG(splitmix64)。numpyのGeneratorの代わり
    private struct RNG {
        var s: UInt64
        init(seed: UInt64) { s = seed }
        mutating func next() -> UInt64 {
            s &+= 0x9E3779B97F4A7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
            let u = Double(next() >> 11) * (1.0 / 9007199254740992.0)
            return lo + (hi - lo) * u
        }
        mutating func gaussian() -> Double {
            let u1 = max(uniform(0, 1), 1e-12)
            let u2 = uniform(0, 1)
            return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        }
    }

    // MARK: - ノイズ

    /// ラティス点の勾配ベクトル(seed+座標だけで決まる決定論)
    private static func grad(_ ix: Int, _ iy: Int, _ seed: UInt64)
        -> (Double, Double)
    {
        var z = seed
            &+ (UInt64(bitPattern: Int64(ix)) &* 0x9E3779B97F4A7C15)
            &+ (UInt64(bitPattern: Int64(iy)) &* 0xBF58476D1CE4E5B9)
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        let a = Double(z & 0xFFFF) * (2 * .pi / 65536.0)
        return (cos(a), sin(a))
    }

    private static func fade(_ t: Double) -> Double {
        t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// 2D勾配(Perlin風)ノイズ。おおよそ[-1,1]
    private static func perlin(_ x: Double, _ y: Double, _ seed: UInt64)
        -> Double
    {
        let xi = floor(x), yi = floor(y)
        let xf = x - xi, yf = y - yi
        let ix = Int(xi), iy = Int(yi)
        let g00 = grad(ix, iy, seed)
        let g10 = grad(ix + 1, iy, seed)
        let g01 = grad(ix, iy + 1, seed)
        let g11 = grad(ix + 1, iy + 1, seed)
        let n00 = g00.0 * xf + g00.1 * yf
        let n10 = g10.0 * (xf - 1) + g10.1 * yf
        let n01 = g01.0 * xf + g01.1 * (yf - 1)
        let n11 = g11.0 * (xf - 1) + g11.1 * (yf - 1)
        let u = fade(xf), v = fade(yf)
        let top = n00 + u * (n10 - n00)
        let bottom = n01 + u * (n11 - n01)
        return (top + v * (bottom - top)) * 1.41421356
    }

    /// fbm。周波数は無次元(unit domainあたりの周期数)。
    /// 合計振幅で正規化するのでだいたい[-1,1]に収まる。
    /// maxFreqを渡すとサンプリングNyquistを超えるオクターブが
    /// 滑らかに減衰する(エイリアシング防止)
    private static func fbm(
        _ x: Double, _ y: Double,
        fx: Double, fy: Double,
        octaves: Int, gain: Double,
        seed: UInt64, maxFreq: Double? = nil
    ) -> Double {
        var fx = fx, fy = fy, amp = 1.0, norm = 0.0, total = 0.0
        for o in 0..<max(1, octaves) {
            var w = amp
            if let mf = maxFreq {
                let f = max(fx, fy)
                // 0.5*mf→mfで滑らかに減衰するHermiteフォールオフ
                let t = min(max((f - 0.5 * mf) / (0.5 * mf), 0), 1)
                w *= 1 - t * t * (3 - 2 * t)
            }
            total += w * perlin(
                x * fx, y * fy,
                seed &+ UInt64(o) &* 0x9E3779B9)
            norm += amp
            amp *= gain
            fx *= 2
            fy *= 2
        }
        return total / max(norm, 1e-8)
    }

    private static func smoothstep(
        _ e0: Double, _ e1: Double, _ x: Double
    ) -> Double {
        guard e0 != e1 else { return x < e0 ? 0 : 1 }
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - 輪幅系列

    /// AR(1)対数正規 + 幼木→成熟の負指数トレンドで成長させた
    /// 輪幅系列(mm)。同じ幅の輪が2つと無い、内側ほど広い
    private static func ringWidths(
        _ rng: inout RNG, count n0: Int,
        meanMM: Double, sigma: Double
    ) -> [Double] {
        let n = max(n0, 4)
        let phi = min(max(rng.uniform(0.30, 0.40), 0), 0.95)
        // trend:AR の分散配分 — 合成系列のラグ1自己相関が
        // 0.70 になるよう解く(元実装と同じ)
        let k = max((0.70 - phi) / 0.30, 0)
        let sdAR = sigma / sqrt(1 + k)
        let sdT = sdAR * sqrt(k)

        var shape = [Double](repeating: 0, count: n)
        let sk = rng.uniform(2.0, 4.0)
        for i in 0..<n {
            let t = Double(i) / Double(max(n - 1, 1))
            shape[i] = -expm1(-sk * t) // 0→1へ単調増加
        }
        let mean = shape.reduce(0, +) / Double(n)
        var spread = 0.0
        for v in shape { spread += (v - mean) * (v - mean) }
        spread = sqrt(spread / Double(n))
        let trendScale = spread > 1e-9 ? sdT / spread : 0

        var e = [Double](repeating: 0, count: n)
        e[0] = rng.gaussian() * sdAR
        let innov = sqrt(max(1 - phi * phi, 1e-9)) * sdAR
        for i in 1..<n {
            e[i] = phi * e[i - 1] + innov * rng.gaussian()
        }
        var w = [Double](repeating: 0, count: n)
        var sum = 0.0
        for i in 0..<n {
            w[i] = exp(-shape[i] * trendScale + e[i])
            sum += w[i]
        }
        let meanW = sum / Double(n)
        for i in 0..<n {
            w[i] = min(max(w[i] * meanMM / max(meanW, 1e-9), 0.4), 8.0)
        }
        return w
    }

    // MARK: - メイン生成

    /// 木目テクスチャ1枚を生成する。
    /// - pxWidth/pxHeight: 出力ピクセルサイズ
    /// - seed: メンバーごとの決定論シード
    /// - profile: 材の色・気孔クラス・輪数・節確率
    /// - alongX: true=木理が横方向(水平板)、false=縦方向(縦材)
    static func image(
        pxWidth w: Int, pxHeight h: Int,
        seed: UInt64, profile: Profile, alongX: Bool
    ) -> CGImage? {
        guard w > 0, h > 0 else { return nil }
        var rng = RNG(seed: seed &+ 1)
        let pc = profile.poreClass

        // (along, across) 座標系。unit domainは画像幅=1
        let aspect = Double(h) / Double(w)
        let alongExtent = alongX ? 1.0 : aspect
        let acrossExtent = alongX ? aspect : 1.0
        let ref = acrossExtent
        let pxPerUnit = Double(w)

        // 描画の順序は元実装に揃える(seed→同じ系列になるよう)
        let tilt = rng.uniform(-0.105, 0.105)
        let warpAmp = rng.uniform(0.01, 0.025) * ref
        let warpFU = rng.uniform(1.2, 2.5)
        let warpFV = rng.uniform(1.2, 2.5)
        let seedW1 = UInt64(bitPattern: Int64(rng.next() >> 16))
        let seedW2 = UInt64(bitPattern: Int64(rng.next() >> 16))

        // カット: cathedral=髄軸が板面の下を潜る(山型杢)、
        // flatsawn=近めの点髄心(緩い弧)、quartersawn=遠い髄心
        // (ほぼ平行線)
        let side: Double = rng.uniform(0, 1) < 0.5 ? -1 : 1
        let cutDraw = rng.uniform(0, 1)
        enum Cut { case cathedral, flatsawn, quartersawn }
        let cut: Cut = cutDraw < 0.35 ? .cathedral
            : cutDraw < 0.80 ? .flatsawn : .quartersawn
        var pithU = 0.0, pithV = 0.0, apexU = 0.0
        var d0 = 0.0, slope = 0.0
        switch cut {
        case .cathedral:
            pithV = acrossExtent * rng.uniform(0.15, 0.85)
            apexU = alongExtent * rng.uniform(0.1, 0.9)
            d0 = rng.uniform(0.02, 0.12) * ref
            slope = rng.uniform(0.15, 0.4) * side
        case .flatsawn:
            let pd = rng.uniform(1.0, 3.0) * ref
            pithU = alongExtent * rng.uniform(-0.6, 1.6)
            pithV = acrossExtent * 0.5 + side * (pd + acrossExtent * 0.5)
        case .quartersawn:
            let pd = rng.uniform(3.0, 6.0) * ref
            pithU = alongExtent * rng.uniform(-0.6, 1.6)
            pithV = acrossExtent * 0.5 + side * (pd + acrossExtent * 0.5)
        }

        let nRings = rng.uniform(
            profile.ringsAcross.0, profile.ringsAcross.1)
        let spacing = ref / nRings // 平均の見かけ輪間隔(unit)

        // 節(引き寄せ場)。細いメンバーには入れない
        var hasKnot = false
        var ku = 0.0, kv = 0.0, kRadius = 0.0, kElong = 0.0
        var kPullAmp = 0.0, kWF = 0.0, kRingW = 0.0
        if rng.uniform(0, 1) < profile.knotProbability {
            hasKnot = true
            ku = alongExtent * rng.uniform(0.15, 0.85)
            kv = acrossExtent * rng.uniform(0.15, 0.85)
            kRadius = min(
                rng.uniform(0.4, 0.9) * ref * 0.24,
                0.38 * min(alongExtent, acrossExtent))
            kElong = rng.uniform(1.2, 2.2)
            kPullAmp = spacing * rng.uniform(1.5, 4.0)
            kWF = min(9.0 / max(kRadius, 1e-6), 0.08 * pxPerUnit)
            kRingW = rng.uniform(0.16, 0.28)
        }
        let seedKnot = UInt64(bitPattern: Int64(rng.next() >> 16))

        // 輪幅系列(半径方向mm)→ 累積境界(unit)。
        // unit_per_mmは「平均の見かけ間隔がspacingになる」よう決める
        let meanMM = rng.uniform(pc.ringMeanMM.0, pc.ringMeanMM.1)
        let sigma = rng.uniform(pc.ringSigma.0, pc.ringSigma.1)
        // 半径スパンはカット形で大きく違うので多めに成長させる
        let spanEst = (alongExtent + acrossExtent) * 2.5
        var widthsMM = ringWidths(
            &rng, count: Int(spanEst / max(spacing * 0.5, 1e-6)) + 32,
            meanMM: meanMM, sigma: sigma)
        let unitPerMM = spacing
            / max(widthsMM.reduce(0, +) / Double(widthsMM.count), 1e-9)
        var bounds = [0.0]
        var acc = 0.0
        for wm in widthsMM { acc += wm * unitPerMM; bounds.append(acc) }
        while bounds.last! < spanEst {
            // 稀な尾部ケース: 系列を繰り返して延ばす
            widthsMM += widthsMM
            bounds = [0.0]; acc = 0
            for wm in widthsMM { acc += wm * unitPerMM; bounds.append(acc) }
        }
        let nBounds = bounds.count

        // 位相ノイズ・スジ・ドリフトのパラメータ
        let beta = rng.uniform(0.12, 0.3)
        let wiggleW = rng.uniform(0.015, 0.04)
        let pnFU = rng.uniform(1.5, 3.5), pnFV = rng.uniform(1.5, 4.0)
        let wgFU = rng.uniform(4.0, 8.0), wgFV = rng.uniform(5.0, 10.0)
        let streakFA = rng.uniform(3.0, 7.0)
        let streakStretch = rng.uniform(30.0, 80.0)
        let transConst = pc.transitionMM == nil
            ? rng.uniform(pc.transitionFrac.0, pc.transitionFrac.1)
            : 0.0
        let transMMv = pc.transitionMM.map {
            rng.uniform($0.0, $0.1)
        }
        let seedP = UInt64(bitPattern: Int64(rng.next() >> 16))
        let seedG = UInt64(bitPattern: Int64(rng.next() >> 16))
        let seedF = UInt64(bitPattern: Int64(rng.next() >> 16))
        let seedS = UInt64(bitPattern: Int64(rng.next() >> 16))
        let seedD = UInt64(bitPattern: Int64(rng.next() >> 16))

        // ピクセルバッファ(線形0-1 → 後でRGBへ)
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var sumR = 0.0, sumG = 0.0, sumB = 0.0

        let ct = cos(tilt), st = sin(tilt)
        let cu = alongExtent * 0.5, cv = acrossExtent * 0.5
        let maxFreq = 0.5 * pxPerUnit
        let e = profile.early, l = profile.late
        let knotR = l.r * 0.55, knotG = l.g * 0.55, knotB = l.b * 0.55

        for j in 0..<h {
            let y = (Double(j) + 0.5) / pxPerUnit
            for i in 0..<w {
                let x = (Double(i) + 0.5) / pxPerUnit
                var u = alongX ? x : y
                var v = alongX ? y : x
                // 微小な木理の傾き
                let du = u - cu, dv = v - cv
                u = cu + ct * du - st * dv
                v = cv + st * du + ct * dv
                // ドメインワープ
                let wu = u + warpAmp * fbm(
                    u, v, fx: warpFU, fy: warpFV,
                    octaves: 3, gain: 0.5, seed: seedW1)
                let wv = v + warpAmp * fbm(
                    u, v, fx: warpFU, fy: warpFV,
                    octaves: 3, gain: 0.5, seed: seedW2)

                // 髄心距離場
                var r: Double
                var gradR: Double // |∇r|(輪の広がりで遷移幅と位相
                                  // ノイズ量を決める)
                switch cut {
                case .cathedral:
                    let depth = d0 + slope * (wu - apexU)
                    let dv2 = wv - pithV
                    r = sqrt(dv2 * dv2 + depth * depth)
                    gradR = r > 1e-9
                        ? sqrt(
                            (slope * depth) * (slope * depth)
                                + dv2 * dv2) / r
                        : 0
                case .flatsawn, .quartersawn:
                    let du2 = wu - pithU, dv2 = wv - pithV
                    r = sqrt(du2 * du2 + dv2 * dv2)
                    gradR = 1
                }

                // 節の引き寄せ + 暗がり場
                var knotDark = 0.0
                if hasKnot {
                    let kdu = (wu - ku) / kElong
                    let kdv = wv - kv
                    var kd = sqrt(kdu * kdu + kdv * kdv)
                    kd *= 1 + 0.07 * fbm(
                        u, v, fx: kWF, fy: kWF,
                        octaves: 2, gain: 0.5, seed: seedKnot)
                    let falloff = exp(
                        -(kd / (kRadius * 2.2)) * (kd / (kRadius * 2.2)))
                    r += falloff * kPullAmp
                    let stub = smoothstep(
                        kRadius * 0.58, kRadius * 0.4, kd)
                    let centre = smoothstep(
                        kRadius * 0.4, kRadius * 0.12, kd)
                    let ringZone = smoothstep(
                        kRadius * 1.02, kRadius * 0.55, kd)
                    let rim = exp(
                        -pow((kd - kRadius) / (kRadius * 0.09), 2))
                    let innerG = (kd / (kRadius * kRingW))
                        .truncatingRemainder(dividingBy: 1)
                    let inner = smoothstep(0.5, 0.8, innerG)
                        * (1 - smoothstep(0.92, 1.0, innerG))
                    knotDark = stub * 0.7 + centre * 0.25
                        + ringZone * inner * 0.4 + ringZone * 0.06
                        + rim * 0.45
                }

                // 半径→輪座標(整数部=輪番号、小数部=輪内位置)
                let rr = max(r - bounds[0], 0)
                var lo = 0, hi = nBounds - 1
                while lo + 1 < hi {
                    let m = (lo + hi) / 2
                    if bounds[m] <= rr { lo = m } else { hi = m }
                }
                let wUnits = max(bounds[hi] - bounds[lo], 1e-9)
                let ringU = Double(lo) + (rr - bounds[lo]) / wUnits
                // 輪の広がる場所では位相ノイズを殺す(王冠の頂点で
                // 輪の輪郭が壊れないよう、横方向変位=位相勾配比で
                // スケールする: 元実装と同じ工夫)
                let widthAtR = max(widthsMM[min(lo, widthsMM.count - 1)]
                    * unitPerMM, 1e-9)
                let gradRingU = gradR / widthAtR
                let lateral = min(max(gradRingU * spacing, 0), 1)
                let pn = fbm(u, v, fx: pnFU, fy: pnFV,
                             octaves: 2, gain: 0.45, seed: seedP)
                let wig = fbm(u, v, fx: wgFU, fy: wgFV,
                              octaves: 2, gain: 0.5, seed: seedG)
                let phase = ringU + lateral * (beta * pn + wiggleW * wig)
                var g = phase.truncatingRemainder(dividingBy: 1)
                if g < 0 { g += 1 }
                let ringIdx = Int(floor(phase))
                let wIdx = min(max(ringIdx, 0), widthsMM.count - 1)
                let ringMM = widthsMM[wIdx]
                // 輪ごとのばらつき(輪番号のハッシュで[-1,1])
                func ringHash(_ salt: UInt64) -> Double {
                    var z = UInt64(bitPattern: Int64(ringIdx))
                        &* 0x9E3779B97F4A7C15 &+ salt
                    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                    z = z ^ (z >> 31)
                    return Double(z & 0xFFFF) / 32768.0 - 1
                }
                let r1 = ringHash(0x51A7)
                let r2 = ringHash(0xB3D9)

                // 鋸歯プロファイル(早材上昇 + 晩材帯 + 境界ステップ)
                var lwFrac: Double
                if let (wlo, whi) = pc.lateFracWidthMM {
                    let t = min(max(
                        (ringMM - wlo) / max(whi - wlo, 1e-6), 0), 1)
                    lwFrac = pc.lateFrac.0
                        + (pc.lateFrac.1 - pc.lateFrac.0) * t
                } else {
                    lwFrac = pc.lateFrac.0
                        + (pc.lateFrac.1 - pc.lateFrac.0) * (r1 + 1) / 2
                }
                lwFrac = min(max(
                    lwFrac * (1 + 0.15 * r1), 0.08), 0.92)
                var trans: Double
                if let tm = transMMv {
                    trans = tm / max(ringMM, 0.2)
                } else {
                    trans = transConst
                }
                // ステップはピクセル分解能以下にしない
                let transFloor = 1.6 * gradRingU / pxPerUnit
                trans = min(max(max(trans, transFloor), 0.01), 0.95)
                let start = 1 - lwFrac
                var t2 = (g - start) / trans + 0.5
                t2 = min(max(t2, 0), 1)
                let lateW = t2 * t2 * (3 - 2 * t2)
                let early = 0.18 * min(g / max(start, 1e-3), 1)
                let late = 0.80
                    + 0.20 * min(max((g - start) / lwFrac, 0), 1)
                let density = early + (late - early) * lateW
                let fadeN = fbm(u, v, fx: 2.5, fy: 4.5,
                                octaves: 2, gain: 0.5, seed: seedF)
                var amp = min(max(1.00 + 0.32 * fadeN, 0.45), 1.35)
                    * min(max(1.00 + 0.34 * r2, 0.45), 1.35)
                amp *= min(pc.lineStrength, 1.0)
                let prof = min(max(density * amp, 0), 1)

                // 細スジ(強異方性fbm) + 面のトーンむら
                let streak = fbm(
                    u, v, fx: streakFA, fy: streakFA * streakStretch,
                    octaves: 3, gain: 0.6,
                    seed: seedS, maxFreq: maxFreq)
                let drift = fbm(u, v, fx: 1.5, fy: 2.0,
                                octaves: 3, gain: 0.5, seed: seedD)
                    * 0.055
                var cr = e.r + (l.r - e.r) * prof
                var cg = e.g + (l.g - e.g) * prof
                var cb = e.b + (l.b - e.b) * prof
                let mul = 1 + 0.12 * streak + drift
                cr *= mul; cg *= mul; cb *= mul
                if knotDark > 0 {
                    let k = min(max(knotDark, 0), 1) * 0.85
                    cr = cr * (1 - k) + knotR * k
                    cg = cg * (1 - k) + knotG * k
                    cb = cb * (1 - k) + knotB * k
                }
                sumR += cr; sumG += cg; sumB += cb
                let o = (j * w + i) * 4
                px[o] = UInt8(min(max(cr, 0), 1) * 255 + 0.5)
                px[o + 1] = UInt8(min(max(cg, 0), 1) * 255 + 0.5)
                px[o + 2] = UInt8(min(max(cb, 0), 1) * 255 + 0.5)
                px[o + 3] = 255
            }
        }

        // 面全体の平均を早材寄りの目標色に再帰正化(輪・スジ・
        // 節はすべて平均色まわりの変動なので)
        let n = Double(w * h)
        let tR = e.r + (l.r - e.r) * 0.30
        let tG = e.g + (l.g - e.g) * 0.30
        let tB = e.b + (l.b - e.b) * 0.30
        let sR = tR / max(sumR / n, 1e-6)
        let sG = tG / max(sumG / n, 1e-6)
        let sB = tB / max(sumB / n, 1e-6)
        for p in 0..<(w * h) {
            let o = p * 4
            px[o] = UInt8(min(
                Double(px[o]) / 255 * sR, 1) * 255 + 0.5)
            px[o + 1] = UInt8(min(
                Double(px[o + 1]) / 255 * sG, 1) * 255 + 0.5)
            px[o + 2] = UInt8(min(
                Double(px[o + 2]) / 255 * sB, 1) * 255 + 0.5)
        }

        // CGImageはプロバイダ経由でDataを保持させる
        // (スタック上の配列を参照する作りにすると寿命が切れる)
        let data = Data(px)
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(
                width: w, height: h,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast
                        .rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return img
    }
}
