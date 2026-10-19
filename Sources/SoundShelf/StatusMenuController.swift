import AppKit
import SwiftUI

final class SoundShelfAppDelegate: NSObject, NSApplicationDelegate {
    private var menuController: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        menuController = StatusMenuController()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// A native status button receives right-clicks even when the shelf is closed.
final class StatusMenuController: NSObject {
    private let model = MediaModel()
    private let macMute = MacMuteController()
    private let microphoneMute: MicrophoneMuteController
    private let shelfMute: ShelfMuteController
    private let restartController = AppRestartController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    override init() {
        shelfMute = ShelfMuteController(model: model)
        microphoneMute = MicrophoneMuteController(model: model)
        super.init()
        if let button = statusItem.button {
            button.image = SoundShelfIcon.menuBar
            button.toolTip = "SoundShelf — click for controls; right-click for Restart and Quit."
            button.setAccessibilityLabel("SoundShelf")
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        let content = ShelfView(model: model, shelfMute: shelfMute, macMute: macMute, microphoneMute: microphoneMute,
                                restartApp: { [weak self] in self?.restart() })
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
    }

    @objc private func clicked() {
        guard let button = statusItem.button else { return }
        let event = NSApplication.shared.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            let menu = NSMenu()
            let native = item("Connect Spotify & Music", action: #selector(toggleNative))
            native.state = model.nativeEnabled ? .on : .off
            menu.addItem(native)
            menu.addItem(item("Browser setup…", action: #selector(openGuide)))
            menu.addItem(.separator())
            let restart = item("Restart SoundShelf", action: #selector(restart))
            restart.isEnabled = !restartController.isRestarting
            menu.addItem(restart)
            menu.addItem(item("Quit SoundShelf", action: #selector(quit)))
            menu.autoenablesItems = false
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleNative() { model.nativeEnabled.toggle() }
    @objc private func openGuide() { model.openGuide() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    @objc private func restart() {
        popover.performClose(nil)
        restartController.restart(model: model, shelfMute: shelfMute, macMute: macMute)
    }
}
