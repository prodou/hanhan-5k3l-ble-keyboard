//
//  HanHan Agent
//  ------------
//  菜单栏后台工具:
//    全局拦截来自 "HanHan 5K3L" 蓝牙键盘的 F13~F17 这 5 个按键信号,
//    不让它们传到当前正在使用的窗口(会被直接吞掉/拦截),
//    而是"背景注入"(不切换焦点、不激活窗口)到用户在菜单里选定的目标 App。
//
//  权限要求:
//    系统设置 -> 隐私与安全性 -> 辅助功能(Accessibility): 勾选 "HanHan Agent"
//    (用于安装全局 CGEventTap 监听/拦截按键, 没有这个权限 App 会完全收不到按键)
//
import Cocoa
import ApplicationServices

// macOS 标准虚拟键码(来自 Carbon HIToolbox/Events.h 的 kVK_F13~kVK_F17)
let VK_F13: Int64 = 0x69
let VK_F14: Int64 = 0x6B
let VK_F15: Int64 = 0x71
let VK_F16: Int64 = 0x6A
let VK_F17: Int64 = 0x40

let interceptedKeycodes: Set<Int64> = [VK_F13, VK_F14, VK_F15, VK_F16, VK_F17]

let kDefaultsTargetBundleIDKey = "targetBundleID"

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?

    var targetBundleID: String? {
        didSet {
            UserDefaults.standard.set(targetBundleID, forKey: kDefaultsTargetBundleIDKey)
            rebuildMenu()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        targetBundleID = UserDefaults.standard.string(forKey: kDefaultsTargetBundleIDKey)
        ensureAccessibilityPermission()
        setupEventTap()

        // App 列表可能随时启动/退出, 定期刷新菜单
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    // MARK: - 权限

    func ensureAccessibilityPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        let options: NSDictionary = [promptKey: true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            NSLog("[HanHanAgent] 尚未获得 辅助功能 权限, 请在 系统设置->隐私与安全性->辅助功能 中勾选本 App")
        }
    }

    // MARK: - 菜单栏 UI

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "HH"
        rebuildMenu()
    }

    func currentTargetDisplayName() -> String {
        guard let bundleID = targetBundleID else { return "未设置" }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return running.localizedName ?? bundleID
        }
        return "\(bundleID)(未运行)"
    }

    func rebuildMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "HanHan Agent", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let statusLine = NSMenuItem(title: "当前目标: \(currentTargetDisplayName())", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        menu.addItem(NSMenuItem.separator())

        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        if apps.isEmpty {
            let empty = NSMenuItem(title: "(没有检测到可选 App)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        for app in apps {
            guard let bundleID = app.bundleIdentifier else { continue }
            let item = NSMenuItem(title: app.localizedName ?? bundleID,
                                   action: #selector(selectTarget(_:)),
                                   keyEquivalent: "")
            item.target = self
            item.representedObject = bundleID
            item.state = (bundleID == targetBundleID) ? .on : .off
            if let icon = app.icon {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 HanHan Agent", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc func selectTarget(_ sender: NSMenuItem) {
        targetBundleID = sender.representedObject as? String
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 全局按键拦截 + 背景转发

    func setupEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, userInfo in
                guard let userInfo = userInfo else {
                    return Unmanaged.passRetained(event)
                }
                let me = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
                return me.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        ) else {
            NSLog("[HanHanAgent] 创建 EventTap 失败, 请确认已授予 辅助功能 权限, 然后重新打开本 App")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[HanHanAgent] EventTap 已启动, 正在拦截 F13~F17")
    }

    func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统在超时/用户输入时可能会自动关闭 tap, 需要重新启用
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passRetained(event)
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard interceptedKeycodes.contains(keycode) else {
            return Unmanaged.passRetained(event)
        }

        // 命中目标键: 转发到目标 App(不抢焦点), 并吞掉原始事件(不传给当前聚焦窗口)
        if let bundleID = targetBundleID,
           let target = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            let pid = target.processIdentifier
            if let copy = event.copy() {
                copy.postToPid(pid)
            }
        }

        return nil
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // 只在菜单栏显示, 不出现在 Dock/应用切换器
app.run()
