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
struct WindowConfigurator: NSViewRepresentable {

    private static let logger = Logger(subsystem: "com.cacheandbuffer.Records", category: "UI")

    /// makeNSView時点ではview.windowがnilのことがあるため、
    /// viewDidMoveToWindowでwindow確定後にconfigureする。
    final class View: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            WindowConfigurator.configure(window)
            WindowConfigurator.updateTrafficLightVisibility(window)
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
                ) { notification in
                    WindowConfigurator.updateTrafficLightVisibility(
                        notification.object as? NSWindow
                    )
                }
            }
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }

    func makeNSView(context: Context) -> NSView {
        View()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Self.configure(nsView.window)
        // フルスクリーン出入り等でAppKitがタイトルバークロームを再構築すると
        // isHiddenが巻き戻ることがあるため、更新のたびに冪等に再適用する
        Self.updateTrafficLightVisibility(nsView.window)
    }

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
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

    /// 信号ボタン(閉じる/最小化/ズーム)の表示をウィンドウのアクティブ状態に合わせる。
    /// 非アクティブ時はMusicのミニプレーヤーと同じく3つとも隠す。
    static func updateTrafficLightVisibility(_ window: NSWindow?) {
        guard let window else { return }
        let hidden = !window.isKeyWindow
        var changed = false
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            // クローム再構築の途中ではボタンが取れないことがある。
            // その場合は次のviewDidMoveToWindow/updateNSViewで再適用される
            guard let button = window.standardWindowButton(kind),
                  button.isHidden != hidden else { continue }
            button.isHidden = hidden
            changed = true
        }
        // 状態変化があったときだけログ(key通知のたびに出るのを防ぐ)。
        // windowNumberは将来の複数窓でログを見分けるため。
        if changed {
            logger.notice("traffic lights \(hidden ? "hidden" : "shown", privacy: .public) (windowNumber=\(window.windowNumber, privacy: .public) isKeyWindow=\(window.isKeyWindow, privacy: .public))")
        }
    }
}
