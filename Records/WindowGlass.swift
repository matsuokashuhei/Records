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
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            WindowConfigurator.configure(window)
        }
    }

    func makeNSView(context: Context) -> NSView {
        View()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Self.configure(nsView.window)
    }

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        // 冪等: すでに設定済みなら何もしない(updateNSView毎のログ重複防止)
        let configured = window.styleMask.contains(.fullSizeContentView)
            && !window.isOpaque
            && window.backgroundColor == .clear
            && window.titlebarAppearsTransparent
            && window.titleVisibility == .hidden
            && window.titlebarSeparatorStyle == .none
        guard !configured else { return }

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
