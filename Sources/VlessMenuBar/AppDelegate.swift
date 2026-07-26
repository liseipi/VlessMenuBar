import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private let store = AppStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        buildMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "VlessProxy")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        buildMainWindow()
        showMainWindow()
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 VlessProxy", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 VlessProxy", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func buildMainWindow() {
        let content = MainContentView().environmentObject(store)
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = "VlessProxy"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 640))
        window.center()
        window.isReleasedWhenClosed = false
        mainWindow = window
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showQuickMenu(with: event)
        } else {
            if mainWindow?.isVisible == true {
                mainWindow?.orderOut(nil)
            } else {
                showMainWindow()
            }
        }
    }

    private func showQuickMenu(with event: NSEvent) {
        let menu = NSMenu()
        let toggleTitle = store.isRunning ? "停止代理" : "启动代理"
        menu.addItem(withTitle: toggleTitle, action: #selector(quickToggleProxy), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开主窗口", action: #selector(quickShowWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")

        for item in menu.items { item.target = self }

        guard let button = statusItem.button else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    @objc private func quickToggleProxy() {
        if store.isRunning {
            store.stop()
        } else {
            store.start()
        }
    }

    @objc private func quickShowWindow() {
        showMainWindow()
    }

    @objc private func quit() {
        store.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }
}
