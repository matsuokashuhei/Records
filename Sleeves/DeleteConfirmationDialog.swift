import AppKit
import OSLog
import SwiftUI

/// レコード削除確認のカスタムダイアログ。
/// 標準NSAlertでは「Don't Ask Again」チェックボックスをボタンより下に
/// 置けない(accessoryViewは常にボタン行の上)ため、NSPanel+NSHostingViewで
/// 自前実装している。表示中はNSApp.runModal(for:)でアプリモーダルにし、
/// ShelfView.confirmDeleteから同期的に呼ぶ
@MainActor
enum DeleteConfirmationDialog {
    private static let logger = Logger(subsystem: "com.cacheandbuffer.Sleeves", category: "UI")

    /// 確認ダイアログをモーダル表示する
    /// - Parameters:
    ///   - message: 見出しメッセージ(例: `Remove "X"?`)
    ///   - confirmDelete: 現在のsettings.confirmDelete(チェックの初期値を決める)
    ///   - onToggleDontAskAgain: チェックをトグルするたびに呼ぶ
    ///     (dontAskAgainの新値を渡す。即時settings保存は呼び出し側の責務)
    ///   - anchorWindow: このウィンドウの中心にダイアログを出す。
    ///     nilならスクリーン中央(マルチディスプレイでシェルフと
    ///     別画面に出るのを防ぐ)
    /// - Returns: Delete Recordで閉じたらtrue、Cancel/Escapeならfalse
    static func run(
        message: String,
        confirmDelete: Bool,
        onToggleDontAskAgain: @escaping (Bool) -> Void,
        anchorWindow: NSWindow? = nil
    ) -> Bool {
        var confirmed = false
        let panel = Panel()
        // ボタンのアクションはstopModalするだけでパネルを掴まない
        // (panel→hosting→view→クロージャ→panelの循環参照を避ける。
        //  closeはrunModal復帰後に行う)
        let content = DeleteConfirmationView(
            message: message,
            dontAskAgain: !confirmDelete,
            onToggleDontAskAgain: onToggleDontAskAgain,
            onDelete: {
                confirmed = true
                NSApp.stopModal()
            },
            onCancel: {
                NSApp.stopModal()
            }
        )
        let hosting = NSHostingView(rootView: content)
        panel.contentView = hosting
        // 角丸はcontentView差し替え後に設定する(Panel.init時点の
        // デフォルトcontentViewは差し替えで破棄されるため)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 12
        hosting.layer?.masksToBounds = true
        panel.setContentSize(hosting.fittingSize)
        if let anchorWindow {
            // アンカーウィンドウの中央へ出す
            let center = NSPoint(
                x: anchorWindow.frame.midX,
                y: anchorWindow.frame.midY
            )
            panel.setFrameOrigin(NSPoint(
                x: center.x - panel.frame.width / 2,
                y: center.y - panel.frame.height / 2
            ))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        logger.notice("delete confirmation dialog opened: frame=\(panel.frame.debugDescription, privacy: .public)")
        NSApp.runModal(for: panel)
        panel.close()
        return confirmed
    }

    /// borderlessでもkeyウィンドウになれるパネル。
    /// カード風の見た目(角丸+影)はここで作る
    private final class Panel: NSPanel {
        init() {
            super.init(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            isFloatingPanel = true
            level = .floating
            hasShadow = true
            backgroundColor = .clear
            isOpaque = false
            isMovable = false
            // 角丸はrun()でhostingビューへ差し替えた後に設定する
            // (ここでcontentViewへ設定しても差し替えで破棄される)
        }

        override var canBecomeKey: Bool { true }
    }

    private struct DeleteConfirmationView: View {
        let message: String
        let onToggleDontAskAgain: (Bool) -> Void
        let onDelete: () -> Void
        let onCancel: () -> Void
        @State private var dontAskAgain: Bool

        init(
            message: String,
            dontAskAgain: Bool,
            onToggleDontAskAgain: @escaping (Bool) -> Void,
            onDelete: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.message = message
            _dontAskAgain = State(initialValue: dontAskAgain)
            self.onToggleDontAskAgain = onToggleDontAskAgain
            self.onDelete = onDelete
            self.onCancel = onCancel
        }

        var body: some View {
            // カード全体をLiquid Glassにする。ウィンドウ自体は透明
            // (Panel.backgroundColor=.clear)なので背面が透ける。
            // macOS 26の.glassEffectはレイアウト修飾の後に適用する
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(.quaternary)
                        .frame(width: 56, height: 56)
                    Image(systemName: "trash")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }
                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    // 全幅ボタン。ボタンはカードより濃いガラスにするため
                    // .buttonStyle(.glass)ではなくtint付きのglassEffectを
                    // 直接当てる(.blackの濃色でダーク/ライト両方で
                    // カードより濃く見える)。Deleteは赤文字維持
                    Button(role: .destructive, action: onDelete) {
                        Text(String(localized: "Delete Record"))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .contentShape(Rectangle())
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .glassEffect(
                        .regular.tint(.black.opacity(0.35)).interactive(),
                        in: .rect(cornerRadius: 8)
                    )
                    Button(action: onCancel) {
                        Text(String(localized: "Cancel"))
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .contentShape(Rectangle())
                    }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .glassEffect(
                        .regular.tint(.black.opacity(0.35)).interactive(),
                        in: .rect(cornerRadius: 8)
                    )
                }
                Toggle(String(localized: "Don't Ask Again"), isOn: $dontAskAgain)
                    .toggleStyle(.checkbox)
                    .onChange(of: dontAskAgain) { _, newValue in
                        onToggleDontAskAgain(newValue)
                    }
            }
            .padding(24)
            .frame(width: 300)
            .glassEffect(
                .regular.tint(.black.opacity(0.15)),
                in: .rect(cornerRadius: 12)
            )
        }
    }
}
