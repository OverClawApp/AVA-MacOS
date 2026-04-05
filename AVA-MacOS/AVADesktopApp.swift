import SwiftUI

/// AVA Desktop — uses NSPanel for transparent frosted glass popover (Blink pattern).
@main
struct AVADesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AppDelegate (NSStatusItem + NSPanel, like Blink)

/// NSPanel that can accept keyboard input (overrides default nonactivating behavior).
class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var hostingView: NSHostingView<AnyView>!
    private var globalMonitor: Any?
    private var appState: AppState!

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            if let image = NSImage(named: "MenuBarIcon") {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "AVA")
            }
            button.action = #selector(togglePanel)
            button.target = self
        }

        // Create transparent panel
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.isOpaque = false

        // Vibrancy background (NSVisualEffectView for true see-through glass)
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        visualEffect.blendingMode = .behindWindow
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.masksToBounds = true

        // Host SwiftUI view on top of vibrancy
        let rootView = MenuBarView(appState: appState)
            .frame(width: 320, height: 480)

        hostingView = NSHostingView(rootView: AnyView(rootView))
        hostingView.frame = visualEffect.bounds
        hostingView.autoresizingMask = [.width, .height]

        // Layer: vibrancy → SwiftUI on top
        visualEffect.addSubview(hostingView)
        panel.contentView = visualEffect

        // Auto-connect
        Task { @MainActor in
            await appState.connectIfPaired()
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }

        // Position below the status bar icon, centered
        let buttonFrame = button.window?.convertToScreen(button.frame) ?? .zero
        let panelWidth = panel.frame.width
        let x = buttonFrame.midX - panelWidth / 2
        let y = buttonFrame.minY - panel.frame.height - 4

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)

        // Dismiss on outside click
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }
}
