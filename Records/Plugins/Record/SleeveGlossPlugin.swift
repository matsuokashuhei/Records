//
//  SleeveGlossPlugin.swift
//  Sleeves
//
//  プラグイン「スリーブ光沢」(P2)。
//  透明ビニール袋に入ったレコードのように、ジャケットへ淡い
//  ハイライトを重ねる。帯の形状は feature/cubby-shelf-ui の検証済み
//  グラデーション(左上→右下、ピーク0.11白)をベースにし、
//  設定は「照明」のメタファーで行う:
//   - 位置: ジャケット周囲の3x3のどこから照らすか(正面は中央の淡い光沢)
//   - 強さ: ハイライトのピーク不透明度
//   - 色味: 電球色/温白色/昼白色/昼光色の光色
//
//  反射は物理モデルに基づく: 棚面(z=0)を鏡とみなし、棚正面の視点と
//  高架の点光源から鏡面反射点Sを幾何計算する。各セルの光沢帯は
//  セル中心→Sの向きに引くので「光源側の面」に局所的に出る
//  (全セル同じ向きの帯にはしない)。さらにセルごとの決定論的な
//  微小傾きでSをずらし、1枚ごとに反射の出方が微妙に違う
//  レコード店の実写真に近い見た目にする。
//
//  オーバーレイは jacketOverlay フックで返し、合成側がジャケットの
//  角丸(clipShape)で切る。無効時はレジストリのresolveで除外され
//  オーバーレイ自体が積まれないので残像・レイアウト影響はない(P2-3)。
//

import SwiftUI
import os

struct SleeveGlossPlugin: ShelfPlugin {

    private static let logger = Logger(
        subsystem: "com.cacheandbuffer.Sleeves", category: "Plugins")

    /// パラメータID。PluginState.valuesの永続化キーになるので
    /// 一度決めたら変更しない(変えると保存済みの値が効かなくなる)
    private enum Param {
        /// 照明の位置(3x3)。選択肢idの文字列で永続化
        static let position = "position"
        /// 照明の強さ=ハイライトのピーク不透明度(0〜1)
        static let intensity = "intensity"
        /// 照明の色味。選択肢idの文字列で永続化
        static let color = "color"
    }

    /// 照明の位置。設定画面ではallCasesの並びが3x3グリッドの
    /// 行優先配置になる。rawValueはsettings.jsonへの永続化値なので
    /// 一度決めたら変更しない
    private enum Position: String, CaseIterable {
        case topLeft = "top-left"
        case topCenter = "top-center"
        case topRight = "top-right"
        case middleLeft = "middle-left"
        case center = "center"
        case middleRight = "middle-right"
        case bottomLeft = "bottom-left"
        case bottomCenter = "bottom-center"
        case bottomRight = "bottom-right"

        /// 表示ラベル(グリッドセルのアクセシビリティ用。
        /// Localizable.xcstringsのキー)
        var label: String {
            switch self {
            case .topLeft: return "Top Left"
            case .topCenter: return "Top Center"
            case .topRight: return "Top Right"
            case .middleLeft: return "Middle Left"
            case .center: return "Center"
            case .middleRight: return "Middle Right"
            case .bottomLeft: return "Bottom Left"
            case .bottomCenter: return "Bottom Center"
            case .bottomRight: return "Bottom Right"
            }
        }

        /// グリッドの正規化空間(0〜1)での照明位置。
        /// セル中心の正規化座標(ShelfPluginContext.cellCenter)と
        /// 同じ空間で、角/辺中点/中心の9点。点光源L=(x,y,h)の
        /// 平面成分になり、距離減衰と鏡面反射点の計算に使う
        var point: CGPoint {
            switch self {
            case .topLeft:      return CGPoint(x: 0, y: 0)
            case .topCenter:    return CGPoint(x: 0.5, y: 0)
            case .topRight:     return CGPoint(x: 1, y: 0)
            case .middleLeft:   return CGPoint(x: 0, y: 0.5)
            case .center:       return CGPoint(x: 0.5, y: 0.5)
            case .middleRight:  return CGPoint(x: 1, y: 0.5)
            case .bottomLeft:   return CGPoint(x: 0, y: 1)
            case .bottomCenter: return CGPoint(x: 0.5, y: 1)
            case .bottomRight:  return CGPoint(x: 1, y: 1)
            }
        }
    }

    /// 照明の色味。rawValueはsettings.jsonへの永続化値。
    /// ビニール越しの淡い反射なので着色は彩度を抑えた近似にする
    private enum LightColor: String, CaseIterable {
        /// 電球色。オレンジがかった温かい光
        case bulb
        /// 温白色。電球色と昼白色の中間
        case warmWhite
        /// 昼白色。太陽の自然光に近い白さ(従来の白い光沢と同じ)
        case neutralWhite
        /// 昼光色。青みがかったシャープで明るい光
        case daylight

        /// 表示ラベル(Localizable.xcstringsのキー)
        var label: String {
            switch self {
            case .bulb: return "Bulb"
            case .warmWhite: return "Warm White"
            case .neutralWhite: return "Neutral White"
            case .daylight: return "Daylight"
            }
        }

        /// ハイライトへの着色
        var tint: Color {
            switch self {
            case .bulb:         return Color(red: 1.0, green: 0.86, blue: 0.66)
            case .warmWhite:    return Color(red: 1.0, green: 0.95, blue: 0.84)
            case .neutralWhite: return .white
            case .daylight:     return Color(red: 0.84, green: 0.91, blue: 1.0)
            }
        }
    }

    /// デフォルト値。cubby-shelf-ui実績(0.11白の帯)より少し強め。
    /// 位置top-left・色neutralWhiteは従来(45°・白い光沢)と
    /// 同じ見た目になるよう選んである
    static let defaultIntensity: Double = 0.15
    private static let defaultPosition = Position.topLeft
    private static let defaultColor = LightColor.neutralWhite

    /// ハイライト帯のピーク位置(照明側からの距離、グラデ軸上の0〜1)。
    /// cubby-shelf-uiの実績値(左上寄り0.30)
    private static let bandCenter: Double = 0.30
    /// 帯の幅(グラデ軸に対する割合)。従来のデフォルト値に固定
    /// (形状を変えないので内部定数として残す)
    private static let bandWidth: Double = 0.55
    /// 帯の立ち上がり/立ち下がりのレンジ係数。
    /// center=0.30・width=0.55で cubby-shelf-ui のstops
    /// (clear@0 / peak@0.30 / tail@0.45 / clear@0.60)を再現する値
    private static let bandFalloff: Double = 0.55
    /// ピーク後の中間stop位置の係数(0.30→0.45を再現する0.28)
    private static let bandTail: Double = 0.28
    /// 中間stopの不透明度比(cubby-shelf-uiの0.03/0.11≈0.27)
    private static let tailOpacityRatio: Double = 0.27

    let id = "sleeve-gloss"
    let displayName = "Sleeve Gloss"
    let category: ShelfPluginCategory = .record

    init() {
        Self.logger.info("plugin registered: sleeve-gloss ('Sleeve Gloss')")
    }

    var parameterSpecs: [PluginParameterSpec] {
        [
            .options(.init(
                id: Param.position,
                label: "Light Position",
                choices: Position.allCases.map {
                    .init(id: $0.rawValue, label: $0.label)
                },
                defaultValue: Self.defaultPosition.rawValue,
                presentation: .grid(columns: 3)
            )),
            .slider(.init(
                id: Param.intensity,
                label: "Intensity",
                range: 0...1,
                step: 0.01,
                defaultValue: Self.defaultIntensity
            )),
            .options(.init(
                id: Param.color,
                label: "Light Color",
                choices: LightColor.allCases.map {
                    .init(id: $0.rawValue, label: $0.label)
                },
                defaultValue: Self.defaultColor.rawValue
            )),
        ]
    }

    // MARK: - (b) ジャケットへのオーバーレイ重畳

    /// 点光源の高さ(グリッド正規化単位)。照明を棚面の真上に
    /// 浮いた点光源とみなす際の浮遊量。棚の横幅=1の空間で0.5は
    /// 物理的に「棚幅の半分ほど手前に置いたスタンドライト」相当。
    /// 4x4・角照明で最遠セル≈0.16、辺中点照明で≈0.24、中心照明で
    /// 角セル≈0.53の淡い残光が残りつつ、位置ごとの明暗差は
    /// はっきり出る値。小さくすると逆二乗の減衰が急峻になる
    private static let lightHeight: Double = 0.5

    /// 実効強度がこれ以下ならオーバーレイ自体を返さない閾値。
    /// 肉眼でほぼ見えない帯の描画コストを省く下限。
    /// (高架点光源モデルでは最遠セルにも薄い帯が残る仕様なので、
    ///  届くのはintensity設定値自体がごく小さい場合だけ)
    private static let minEffectiveIntensity: Double = 0.005

    /// 視点の棚面からの距離(グリッド正規化単位)。棚の正面中央を
    /// 見る視点E=(0.5,0.5,eyeDepth)。eyeDepth≫lightHeightなので
    /// 鏡像法のt≈0.9となり、鏡面反射点Sは光源の棚面投影の
    /// すぐ内側に来る(実写真で光源側の面にだけ光沢が出るのと一致)
    private static let eyeDepth: Double = 3.5

    /// レコード1枚ごとの微小な疑似傾きの最大角(ラジアン±5°)。
    /// 実際のレコードスリーブの微妙な反り・傾きの幅程度で、
    /// 反射のバラつきが自然に見える大きさに抑える
    private static let maxTilt: Double = 5 * .pi / 180

    /// 鏡面反射点Sがセル中心からこの距離(セル単位)以内なら、
    /// 帯ではなくS位置中心の放射状ハイライトに切り替える閾値。
    /// セル半辺=0.5なので「Sがセル内に入る」条件に相当する
    private static let directReflectionRadius: Double = 0.5

    func jacketOverlay(context: ShelfPluginContext) -> AnyView? {
        let position = resolvedPosition(context: context)
        // 棚面上方に浮いた点光源からの距離でセルごとに強度を減衰し、
        // さらにスリーブの質感のバラつき(0.85〜1.0)を掛ける。
        // 照明に一番近いセル=ほぼフル強度、遠いほど逆二乗で薄くなる
        let baseIntensity = resolvedIntensity(context: context)
        let intensity = baseIntensity
            * falloff(to: position, context: context)
            * sheenFactor(context: context)
        // 実効強度≈0=事実上透明なのでオーバーレイ自体を返さない
        // (無効時と同じく描画・ヒットの影響ゼロにする)
        guard intensity > Self.minEffectiveIntensity else { return nil }
        let color = resolvedColor(context: context)
        // ログのintensityは設定値そのまま(セルごとの減衰値ではない)
        logAppliedOnce(position: position, intensity: baseIntensity, color: color)

        // 正面照明は従来どおりジャケット中央の淡い丸い光沢
        guard position != .center else {
            return glowOverlay(
                center: .center,
                endRadius: context.cellSize * 0.75,
                tint: color.tint,
                intensity: intensity
            )
        }

        // 鏡面反射点Sを幾何計算し、セル単位の物理座標
        // (セル1個=1の空間)へ写す。正規化空間は列数と行数が
        // 異なるとx/yのスケールが違うので、方向を取る前に
        // 正方形セルの物理座標へ戻す
        let cols = Double(max(1, context.gridColumns))
        let rows = Double(max(1, context.gridRows))
        var s = specularPoint(for: position)
        s.x *= cols; s.y *= rows
        // レコードの微小傾きで反射位置をずらす(1枚ごとのバラつき)
        let tilt = tiltShift(context: context)
        s.x += tilt.x; s.y += tilt.y
        let cx = context.cellCenter.x * cols
        let cy = context.cellCenter.y * rows
        let dx = s.x - cx
        let dy = s.y - cy
        let dist = hypot(dx, dy)

        if dist < Self.directReflectionRadius {
            // Sがセル内/ごく近傍: 光源がほぼ正面に映るセルなので、
            // 帯ではなくS位置を中心にした小さめの放射状ハイライト
            let center = UnitPoint(
                x: min(1, max(0, s.x - cx + 0.5)),
                y: min(1, max(0, s.y - cy + 0.5))
            )
            return glowOverlay(
                center: center,
                endRadius: context.cellSize * 0.55,
                tint: color.tint,
                intensity: intensity
            )
        } else {
            // 帯の軸はセル中心→Sの向き(光源側の面にハイライトが出る)
            let dir = CGPoint(x: dx / dist, y: dy / dist)
            return bandOverlay(dir: dir, tint: color.tint, intensity: intensity)
        }
    }

    // MARK: - オーバーレイ描画

    /// 光源側の面にかかる斜めのハイライト帯。
    /// dirはセル中心→鏡面反射点Sへの単位ベクトルで、軸の始点を
    /// 「S側のセル縁」(center+dir·0.5)に取る。帯のピークはそこから
    /// bandCenter分内側、両端のフェード幅はbandWidthで伸縮する
    /// (帯の形状・stopsは従来と同じで、軸だけがセルごとにSを向く)
    private func bandOverlay(dir: CGPoint, tint: Color, intensity: Double) -> AnyView {
        let c = Self.bandCenter
        let riseStart = max(0, c - Self.bandFalloff * Self.bandWidth)
        let tailMid = min(1, c + Self.bandTail * Self.bandWidth)
        let tailEnd = min(1, c + Self.bandFalloff * Self.bandWidth)
        return AnyView(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: riseStart),
                    .init(color: tint.opacity(intensity), location: c),
                    .init(color: tint.opacity(intensity * Self.tailOpacityRatio),
                          location: tailMid),
                    .init(color: .clear, location: tailEnd)
                ],
                startPoint: UnitPoint(x: 0.5 + dir.x * 0.5, y: 0.5 + dir.y * 0.5),
                endPoint: UnitPoint(x: 0.5 - dir.x * 0.5, y: 0.5 - dir.y * 0.5)
            )
            // オーバーレイがジャケットのタップ再生・D&D・右クリックの
            // ヒット判定を食わないようにする
            .allowsHitTesting(false)
        )
    }

    /// 正面反射の淡い丸い光沢。ピークをcenterに置いて外側へフェード
    private func glowOverlay(center: UnitPoint, endRadius: CGFloat,
                             tint: Color, intensity: Double) -> AnyView {
        AnyView(
            RadialGradient(
                stops: [
                    .init(color: tint.opacity(intensity), location: 0),
                    .init(color: tint.opacity(intensity * Self.tailOpacityRatio),
                          location: 0.45),
                    .init(color: .clear, location: 1)
                ],
                center: center,
                startRadius: 0,
                endRadius: endRadius
            )
            .allowsHitTesting(false)
        )
    }

    // MARK: - パラメータ解決

    private func resolvedIntensity(context: ShelfPluginContext) -> Double {
        min(1, max(0,
            context.number(Param.intensity, default: Self.defaultIntensity)))
    }

    private func resolvedPosition(context: ShelfPluginContext) -> Position {
        // 手編集や古い値で未知の文字列が入ってもデフォルトに倒す
        let raw = context.text(Param.position, default: Self.defaultPosition.rawValue)
        return Position(rawValue: raw) ?? Self.defaultPosition
    }

    private func resolvedColor(context: ShelfPluginContext) -> LightColor {
        let raw = context.text(Param.color, default: Self.defaultColor.rawValue)
        return LightColor(rawValue: raw) ?? Self.defaultColor
    }

    /// 棚面の上方に浮いた点光源モデルによる減衰率(0〜1)を返す。
    /// 照明位置Pの真上・高さlightHeightに光源があり、セル中心Cまでの
    /// 3D距離 r = hypot(平面距離, 高さ) で減衰する。m = (r_min / r)²
    /// (r_min=全セル中心のrの最小値)で正規化するので、
    /// 一番近いセル=1.0、それ以外は逆二乗で下がるが0にはならず
    /// どの照明位置でも棚全体が段階的に照らされる。
    /// 走査はcols×rows(最大100)の数式数個分。アロケーションなし
    private func falloff(to position: Position, context: ShelfPluginContext) -> Double {
        let p = position.point
        let h = Self.lightHeight
        let cols = max(1, context.gridColumns)
        let rows = max(1, context.gridRows)
        // 全セル中心のrの最小値(=一番強く照らされるセル)を求める
        var rMin = Double.greatestFiniteMagnitude
        for row in 0..<rows {
            let cy = (Double(row) + 0.5) / Double(rows)
            for col in 0..<cols {
                let cx = (Double(col) + 0.5) / Double(cols)
                let d = hypot(p.x - cx, p.y - cy)
                rMin = min(rMin, hypot(d, h))
            }
        }
        // このセル中心までの距離。全セルが同距離(1x1で照明が中心上等)
        // ならr<=rMinとなり減衰なし=フル強度
        let d = hypot(p.x - context.cellCenter.x, p.y - context.cellCenter.y)
        let r = hypot(d, h)
        guard r > rMin else { return 1 }
        let ratio = rMin / r
        return min(1, ratio * ratio)
    }

    /// 鏡面反射点S(mirror image法)。棚面z=0を鏡とみなすと、
    /// 光源L=(Px,Py,h)が平面上で最も強く映って見える位置Sは、
    /// 視点E=(0.5,0.5,eyeDepth)を棚面で折り返した像
    /// E'=(0.5,0.5,-eyeDepth)とLを結ぶ直線がz=0と交わる点。
    /// 直線のz成分は -eyeDepth→+h なので z=0との交点は
    /// t = eyeDepth/(eyeDepth+h) で E_xy + t·(P_xy − E_xy)。
    /// 戻り値はグリッド正規化空間(0〜1)の座標
    private func specularPoint(for position: Position) -> CGPoint {
        let p = position.point
        let t = Self.eyeDepth / (Self.eyeDepth + Self.lightHeight)
        return CGPoint(
            x: 0.5 + t * (p.x - 0.5),
            y: 0.5 + t * (p.y - 0.5)
        )
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

    /// レコード1枚ごとの微小な疑似傾き(セル単位での反射位置の
    /// ずれ量)を返す。セル座標から決定論的にyaw/pitch±5°を引き、
    /// 面をα傾けると鏡面反射は約2α動く物理に合わせて、
    /// Sを 2·tan(α) セル分ずらす量に換算する(±5°で最大約0.175セル)。
    /// ジャケット自体の見た目は変形しない
    /// (傾きの描画はLeanDepthPluginの役割)
    private func tiltShift(context: ShelfPluginContext) -> CGPoint {
        let yaw = (hash01(1, context: context) * 2 - 1) * Self.maxTilt
        let pitch = (hash01(2, context: context) * 2 - 1) * Self.maxTilt
        return CGPoint(x: 2 * tan(yaw), y: 2 * tan(pitch))
    }

    /// セルごとの光沢強度のバラつき(0.85〜1.0)。
    /// 同じ疑似乱数源から生成し、マット/光沢スリーブが
    /// 混在した棚の実感にする
    private func sheenFactor(context: ShelfPluginContext) -> Double {
        0.85 + 0.15 * hash01(3, context: context)
    }

    /// プロセス内で最初の1回だけ解決値を記録する
    /// (セル描画のたびに呼ばれるので、毎回ログは出さない。
    ///  有効/無効とパラメータ確定のログはSettingsView側が出す)
    private static var didLogApplied = false
    private func logAppliedOnce(position: Position, intensity: Double, color: LightColor) {
        guard !Self.didLogApplied else { return }
        Self.didLogApplied = true
        Self.logger.notice("sleeve-gloss applied: position=\(position.rawValue, privacy: .public) intensity=\(intensity, privacy: .public) color=\(color.rawValue, privacy: .public) model=specular")
    }
}
