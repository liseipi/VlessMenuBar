import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private let store = AppStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory：不出现在 Dock 里、没有顶部菜单栏菜单，纯靠状态栏图标 + 主窗口交互。
        NSApp.setActivationPolicy(.accessory)

        // 必须有这一步：Cmd+C / Cmd+V / Cmd+X / Cmd+A 这些标准编辑快捷键在 macOS 上
        // 是通过"主菜单里有没有对应的 Edit 菜单项"来路由的，不是文本框自己天生就会
        // 响应这几个按键。这个 App 一直没有设置过 NSApp.mainMenu，所以哪怕主窗口
        // 临时切到 .regular 策略显示了出来，菜单栏也是空的，导致所有表单文本框
        // 都没法用快捷键复制粘贴，只能靠右键菜单（如果有的话）。
        buildMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "VlessProxy")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        buildMainWindow()
        showMainWindow()
    }

    // MARK: - 主菜单

    /// 构建一个最小但完整的标准 macOS 主菜单：App 菜单（关于/退出）+ Edit 菜单
    /// （剪切/拷贝/粘贴/全选/撤销/重做）。这里的菜单项全部用标准选择器
    /// （cut:/copy:/paste:/selectAll: 等）配 target: nil，意思是"谁是当前第一
    /// 响应者就交给谁处理"——不需要自己写这些方法的实现，NSTextField/NSTextView
    /// 内部已经实现好了，只是需要菜单系统把 Cmd+C 这类按键"翻译"成对应的动作
    /// 消息发出去，没有菜单就没有这层翻译。
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
        // 关掉主窗口不等于退出 App——这是个常驻状态栏工具，
        // 只有点菜单里的"退出"或者 Cmd+Q 才真正退出。
        false
    }

    // MARK: - 主窗口

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

        // 用户直接点窗口左上角的红色关闭按钮时也走到这里（不只是点状态栏图标切换），
        // 保持两种关闭方式的行为一致：回到纯状态栏模式，不留 Dock 图标。
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular) // 主窗口打开时短暂出现在 Dock，方便切换；关闭后可以再切回 accessory
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
                NSApp.setActivationPolicy(.accessory)
            } else {
                showMainWindow()
            }
        }
    }

    /// 右键状态栏图标：不用打开主窗口就能做的几个高频操作。
    /// 用 NSMenu.popUpContextMenu 直接弹出菜单，不要用 "赋值给 statusItem.menu
    /// 再 performClick" 那种技巧——那样会导致 performClick 又触发一次
    /// statusItemClicked，形成递归调用。
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
