//
//  WindowGlass.swift
//  Records
//
//  Created by Shuhei Matsuoka on 2026/10/18.
//

import AppKit
import SwiftUI
import os

/// ウィンドウ全面に敷くリキッドグラス背景。
/// macOS 26のNSGlassEffectViewを使い、背面(デスクトップ)を透過して見せる。
struct GlassBackgroundView: NSViewRepresentable {

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        // ウィンドウ全幅に敷くので角丸は0(ウィンドウ側の角丸でクリップされる)
        view.cornerRadius = 0
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {}
}

/// NSGlassEffectViewがデスクトップ側を透過するにはウィンドウ自体を
/// 透明にする必要があるため、NSWindowの設定を行うだけのビュー。
/// 複数ウィンドウ対応として、ウィンドウ確定(onWindowReady)と
/// キー化(onBecameKey)を呼び出し側へ通知できる。
struct WindowConfigurator: NSViewRepresentable {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    /// ビューがウィンドウにアタッチ/デタッチされたとき呼ぶ
    var onWindowReady: ((NSWindow?) -> Void)?
    /// このビューのウィンドウがキーになったとき呼ぶ(フォーカス中の
    /// シェルフを追跡するため)
    var onBecameKey: (() -> Void)?
    /// このビューのウィンドウがキーになった/外れたとき呼ぶ(右上の
    /// ツールバーを信号ボタンと同じように出し入れするため)
    var onActiveChanged: ((Bool) -> Void)?
    /// 信号ボタン(タイトルバー)を表示するか。呼び出し側が
    /// 「アクティブ かつ 直近にマウスが動いた」を計算して渡す
    var showTrafficLights: Bool = true
    /// ウィンドウのサイズが変わったとき呼ぶ。リサイズ中につかんでいる
    /// 辺がカーソルの位置に残るよう原点を補正するために使う
    var onWindowResized: ((NSWindow) -> Void)?

    /// makeNSView時点ではview.windowがnilのことがあるため、
    /// viewDidMoveToWindowでwindow確定後にconfigureする。
    final class View: NSView {
        private var observers: [NSObjectProtocol] = []
        var onWindowReady: ((NSWindow?) -> Void)?
        var onBecameKey: (() -> Void)?
        var onActiveChanged: ((Bool) -> Void)?
        var showTrafficLights = true
        var onWindowResized: ((NSWindow) -> Void)?
        /// 信号ボタンの背面に敷くLiquid Glassのカプセル(ウィンドウごと)
        private var trafficLightGlass: NSGlassEffectView?
        /// 信号ボタンの位置を書き換えた回数(再適用が収束しているかの確認用)
        private var repositionCount = 0

        /// 信号ボタンの位置をMusicアプリのミニプレーヤーに合わせ直し、
        /// 表示を「キー状態 && 呼び出し側の表示フラグ」で決める。
        /// 位置はAppKitがタイトルバーをレイアウトし直すと標準に戻るため、
        /// ウィンドウ更新のたびに冪等に再適用する
        func refreshChrome() {
            let visible = showTrafficLights && (window?.isKeyWindow ?? false)
            // AppKitがタイトルバーをレイアウトし直すと標準位置へ戻るので毎回適用する。
            // 収束したか(毎回リセットされていないか)をログで追えるよう、
            // 実際に書き換えたときだけ回数付きで出す
            if WindowConfigurator.applyTrafficLightInset(window) > 0 {
                repositionCount += 1
                WindowConfigurator.logger.notice("traffic light repositioned: count=\(self.repositionCount, privacy: .public) windowNumber=\(self.window?.windowNumber ?? 0, privacy: .public)")
            }
            WindowConfigurator.updateTrafficLightVisibility(window, visible: visible)
            updateTrafficLightGlass(visible: visible)
        }

        /// 信号ボタンの背面にLiquid Glassのカプセルを敷く。
        /// 閉じる/最小化の外接矩形+5ptの余白で、角丸は高さの半分(カプセル)。
        /// ボタンはタイトルバー側(コンテンツビューの上)にあるので、
        /// ガラスはコンテンツビューへ追加すればちょうど背面になる
        private func updateTrafficLightGlass(visible: Bool) {
            guard let window, let contentView = window.contentView else { return }
            if trafficLightGlass == nil {
                let glass = HitTestlessGlassEffectView()
                glass.style = .regular
                // 右上ツールバー(SwiftUI)の `.tint(.black.opacity(0.45))` と
                // 同じ染め方にして、2つのガラスの見た目を揃える
                glass.tintColor = NSColor.black.withAlphaComponent(0.45)
                contentView.addSubview(glass)
                trafficLightGlass = glass
                WindowConfigurator.logger.notice("traffic light glass created (windowNumber=\(window.windowNumber, privacy: .public))")
            }
            guard let glass = trafficLightGlass else { return }
            var union: CGRect?
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton] {
                guard let button = window.standardWindowButton(kind), !button.isHidden else { continue }
                let rect = button.convert(button.bounds, to: nil)
                union = union.map { $0.union(rect) } ?? rect
            }
            guard let buttons = union else {
                if !glass.isHidden { glass.isHidden = true }
                return
            }
            let windowRect = buttons.insetBy(dx: -5, dy: -5)
            let frame = contentView.convert(windowRect, from: nil)
            // didUpdateのたびに呼ばれるので、変化が無いときは触らない。
            // 毎回frameを代入するとレイアウトが再走し、タイトルバーの
            // レイアウト(信号ボタンが標準位置へ戻る)→再適用のループになる
            if glass.frame != frame {
                glass.frame = frame
            }
            let cornerRadius = windowRect.height / 2
            if abs(glass.cornerRadius - cornerRadius) > 0.5 {
                glass.cornerRadius = cornerRadius
            }
            if glass.isHidden != !visible {
                glass.isHidden = !visible
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                trafficLightGlass?.removeFromSuperview()
                trafficLightGlass = nil
            }
            WindowConfigurator.configure(window)
            refreshChrome()
            WindowConfigurator.logMetrics(window)
            onWindowReady?(window)
            // Musicのミニプレーヤー同様、ウィンドウが非アクティブなら
            // 信号ボタンを隠す。key状態の変化を監視して切り替える。
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            // デタッチ時(window=nil)にobject=nilで登録すると全ウィンドウ
            // (設定画面など)のkey通知を拾って他窓の信号ボタンまで切り替えてしまう
            guard let window else { return }
            let keyNames = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
            observers = keyNames.map { name in
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] notification in
                    let window = notification.object as? NSWindow
                    self?.refreshChrome()
                    self?.onActiveChanged?(window?.isKeyWindow ?? false)
                }
            }
            // タイトルバーのレイアウトで信号ボタンが標準位置へ戻される
            // ことがあるため、ウィンドウ更新のたびに位置を適用し直す
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didUpdateNotification, object: window, queue: .main
                ) { [weak self] _ in
                    self?.refreshChrome()
                }
            )
            // リサイズでコンテンツ(=ウィンドウ)サイズが変わったとき、
            // つかんでいる辺がカーソルの位置に残るよう原点を補正する
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main
                ) { [weak self] notification in
                    guard let window = notification.object as? NSWindow else { return }
                    self?.onWindowResized?(window)
                }
            )
            // 「フォーカス中のシェルフ」の追跡。アタッチ時にすでに
            // keyなら即通知する(ウィンドウは通常keyになってから
            // コンテンツが載る順だが、順序に依存しないため)
            if window.isKeyWindow {
                onBecameKey?()
                // キー状態の変化が来ないままアタッチされることがあるので、
                // 初期値をここでも渡す(chromeの表示条件に使っている)
                onActiveChanged?(true)
            }
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { [weak self] _ in
                    self?.onBecameKey?()
                }
            )
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = View()
        view.onWindowReady = onWindowReady
        view.onBecameKey = onBecameKey
        view.onActiveChanged = onActiveChanged
        view.showTrafficLights = showTrafficLights
        view.onWindowResized = onWindowResized
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? View {
            view.onWindowReady = onWindowReady
            view.onBecameKey = onBecameKey
            view.onActiveChanged = onActiveChanged
            view.showTrafficLights = showTrafficLights
            view.onWindowResized = onWindowResized
            // フルスクリーン出入り等でAppKitがタイトルバークロームを再構築すると
            // isHiddenが巻き戻ることがあるため、更新のたびに冪等に再適用する
            view.refreshChrome()
        }
        Self.configure(nsView.window)
    }

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        // マウス移動(mouseMoved)をウィンドウに配信させる。
        // ShelfViewがこのイベントでツールバー/信号ボタンの自動表示を駆動する
        if !window.acceptsMouseMovedEvents {
            window.acceptsMouseMovedEvents = true
        }
        let flagsConfigured = window.styleMask.contains(.fullSizeContentView)
            && !window.isOpaque
            && window.backgroundColor == .clear
            && window.titlebarAppearsTransparent
            && window.titleVisibility == .hidden
            && window.titlebarSeparatorStyle == .none
        if !flagsConfigured {
            // コンテンツをタイトルバー領域まで拡張し、ウィンドウ全面をガラスにする。
            // separatorStyle=.noneでタイトルバー下の境界線を消し、帯と同色に見せる
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            logger.notice("glass window configured: transparent + hidden title + fullSizeContentView + no separator")
        }
    }

    /// 信号ボタンを標準位置(左上9pt)から4pt内側へ寄せる。
    /// ガラスカプセル/右上ツールバーの「枠との余白」を揃えるための調整で、
    /// AppKitがタイトルバーをレイアウトし直すと標準位置に戻るため、
    /// ウィンドウ更新のたびに冪等に再適用する。
    /// 戻り値は実際に位置を書き換えたボタン数(0なら収束済み)
    @discardableResult
    static func applyTrafficLightInset(_ window: NSWindow?) -> Int {
        guard let window else { return 0 }
        var moved = 0
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, kind) in kinds.enumerated() {
            guard let button = window.standardWindowButton(kind),
                  let superview = button.superview else { continue }
            let rect = button.convert(button.bounds, to: nil)
            let desiredWindowOrigin = CGPoint(
                x: trafficLightLeftInset + CGFloat(index) * trafficLightSpacing,
                y: window.frame.height - trafficLightTopInset - rect.height
            )
            let desired = superview.convert(desiredWindowOrigin, from: nil)
            guard abs(button.frame.origin.x - desired.x) > 0.5
                    || abs(button.frame.origin.y - desired.y) > 0.5 else { continue }
            button.frame.origin = desired
            moved += 1
        }
        return moved
    }

    /// 信号ボタンのウィンドウ左上からの余白とボタン間隔
    /// (標準は左上9pt。枠との余白を4pt広げて13ptにしている)
    static let trafficLightLeftInset: CGFloat = 13
    static let trafficLightTopInset: CGFloat = 13
    static let trafficLightSpacing: CGFloat = 23

    /// ウィンドウの寸法と信号ボタンの位置を1回ログへ出す(レイアウト検証用)。
    /// コンテンツはignoresSafeAreaでタイトルバー帯の下まで広がる構成なので、
    /// ウィンドウ高とグリッド高の差・タイトルバー帯の高さを実測できるように
    /// しておく(ShelfView.titlebarInset の値がOSで変わったらここで分かる)。
    /// 信号ボタンはAppKitがタイトルバーをレイアウトするたびに標準位置へ戻る
    /// ため、アタッチ直後ではなくレイアウトが落ち着いてから測る
    static func logMetrics(_ window: NSWindow?) {
        guard let window else { return }
        let inset = window.frame.height - window.contentLayoutRect.height
        logger.notice("window metrics: frame=\(NSStringFromRect(window.frame), privacy: .public) contentLayoutRect=\(NSStringFromRect(window.contentLayoutRect), privacy: .public) titlebarInset=\(inset, privacy: .public)")
        // 信号ボタンの位置(ウィンドウ左上からの距離)とガラスの寸法。
        // ガラス/右上ツールバーと中心が揃っているかを実測するためのログ
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak window] in
            guard let window else { return }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind) else { continue }
                let rect = button.convert(button.bounds, to: nil)
                logger.notice("traffic light frame: kind=\(kind.rawValue, privacy: .public) left=\(rect.minX, privacy: .public) top=\(window.frame.height - rect.maxY, privacy: .public) size=\(rect.width, privacy: .public)x\(rect.height, privacy: .public) hidden=\(button.isHidden, privacy: .public)")
            }
        }
    }

    /// 信号ボタン(閉じる/最小化/ズーム)の表示を切り替える。
    /// Musicのミニプレーヤーと同じく、非アクティブ時と「しばらくマウスが
    /// 動いていない間」は3つとも隠す。表示条件は呼び出し側が決める
    static func updateTrafficLightVisibility(_ window: NSWindow?, visible: Bool) {
        guard let window else { return }
        let hidden = !visible
        var changed = false
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton] {
            // クローム再構築の途中ではボタンが取れないことがある。
            // その場合は次のviewDidMoveToWindow/updateNSViewで再適用される
            guard let button = window.standardWindowButton(kind),
                  button.isHidden != hidden else { continue }
            button.isHidden = hidden
            changed = true
        }
        // ズームは固定サイズのウィンドウなので意味がない。常に隠す
        if let zoom = window.standardWindowButton(.zoomButton), !zoom.isHidden {
            zoom.isHidden = true
            changed = true
        }
        // 状態変化があったときだけログ(key通知のたびに出るのを防ぐ)。
        // windowNumberは将来の複数窓でログを見分けるため。
        if changed {
            logger.notice("traffic lights \(hidden ? "hidden" : "shown", privacy: .public) (windowNumber=\(window.windowNumber, privacy: .public) isKeyWindow=\(window.isKeyWindow, privacy: .public))")
        }
    }
}

/// 信号ボタン背面のLiquid Glass。クリックは下のレコードへ素通しさせる
/// (ヒットテストを持つとジャケットの上の数ptが反応しなくなる)
private final class HitTestlessGlassEffectView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
