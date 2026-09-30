//
//  HanHan Agent
//  ------------
//  菜单栏后台工具:
//    全局拦截来自 "HanHan 5K3L" 蓝牙键盘的 F13~F17 这 5 个按键信号,
//    不让它们传到当前正在使用的窗口(会被直接吞掉/拦截),
//    而是"背景注入"(不切换焦点、不激活窗口)到用户指定的目标 App 实例。
//
//  关于"区分同一个 App 的多个窗口":
//    系统没有公开 API 能在完全不切换焦点的情况下把按键精确发到某个非最前的具体窗口。
//    所以采用的办法是: 由 HanHan Agent 自己启动一个全新的、独立的 App 实例
//    (NSWorkspace openApplication + createsNewApplicationInstance=true, activates=false),
//    这个新实例只有一个窗口, 不会和用户手动打开的其他窗口混在一起,
//    之后所有按键直接按这个实例的 pid 精确投递, 不需要切换焦点。
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

// 物理按键标签(对应固件 GPIO0/1/3/4/10 -> F13~F17), 用于设置界面展示与持久化 key
let physicalKeys: [(label: String, keycode: Int64)] = [
    ("按键1 (GPIO0 / F13)", VK_F13),
    ("按键2 (GPIO1 / F14)", VK_F14),
    ("按键3 (GPIO3 / F15)", VK_F15),
    ("按键4 (GPIO4 / F16)", VK_F16),
    ("按键5 (GPIO10 / F17)", VK_F17),
]

let interceptedKeycodes: Set<Int64> = Set(physicalKeys.map { $0.keycode })

// MARK: - 预设动作(按键定义界面里可选的动作列表)

enum PresetAction: String, CaseIterable {
    case passthrough = "原样转发 (F13~F17)"
    case up = "方向键: 上"
    case down = "方向键: 下"
    case left = "方向键: 左"
    case right = "方向键: 右"
    case enter = "回车 (Return)"
    case space = "空格 (Space)"
    case tab = "Tab"
    case esc = "Esc"
    case cmdC = "复制 (Cmd+C)"
    case cmdV = "粘贴 (Cmd+V)"
    case cmdZ = "撤销 (Cmd+Z)"
    case cmdW = "关闭窗口 (Cmd+W)"

    // (keycode, modifier flags) 用于合成要发送的按键; passthrough 情况下不使用这里的值
    var keycodeAndFlags: (keycode: CGKeyCode, flags: CGEventFlags) {
        switch self {
        case .passthrough: return (0, [])
        case .up:    return (126, [])
        case .down:  return (125, [])
        case .left:  return (123, [])
        case .right: return (124, [])
        case .enter: return (36, [])
        case .space: return (49, [])
        case .tab:   return (48, [])
        case .esc:   return (53, [])
        case .cmdC:  return (8,  [.maskCommand])
        case .cmdV:  return (9,  [.maskCommand])
        case .cmdZ:  return (6,  [.maskCommand])
        case .cmdW:  return (13, [.maskCommand])
        }
    }
}

let kDefaultsTargetPidKey = "targetPid"
let kDefaultsTargetBundleIDKey = "targetBundleID"
let kDefaultsTargetNameKey = "targetDisplayName"
let kDefaultsKeyActionsKey = "keyActions" // [String(keycode): PresetAction.rawValue]

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var settingsWindowController: SettingsWindowController?

    // 当前目标: 具体某一个正在运行的 App 实例(按 pid 精确定位, 不是笼统的 bundle id)
    var targetApp: NSRunningApplication? {
        didSet {
            if let app = targetApp {
                UserDefaults.standard.set(Int(app.processIdentifier), forKey: kDefaultsTargetPidKey)
                UserDefaults.standard.set(app.bundleIdentifier, forKey: kDefaultsTargetBundleIDKey)
                UserDefaults.standard.set(app.localizedName, forKey: kDefaultsTargetNameKey)
            }
            rebuildMenu()
        }
    }

    // 每个物理按键 -> 预设动作, 默认原样转发
    var keyActions: [Int64: PresetAction] = [:] {
        didSet {
            var raw: [String: String] = [:]
            for (k, v) in keyActions { raw[String(k)] = v.rawValue }
            UserDefaults.standard.set(raw, forKey: kDefaultsKeyActionsKey)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        loadKeyActions()
        restorePersistedTargetIfStillRunning()
        ensureAccessibilityPermission()
        setupEventTap()

        // App 列表可能随时启动/退出, 定期刷新菜单
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    func loadKeyActions() {
        let raw = UserDefaults.standard.dictionary(forKey: kDefaultsKeyActionsKey) as? [String: String] ?? [:]
        for (label, keycode) in physicalKeys.map({ (String($0.keycode), $0.keycode) }) {
            if let rawValue = raw[label], let action = PresetAction(rawValue: rawValue) {
                keyActions[keycode] = action
            } else {
                keyActions[keycode] = .passthrough
            }
        }
    }

    func restorePersistedTargetIfStillRunning() {
        let pid = UserDefaults.standard.integer(forKey: kDefaultsTargetPidKey)
        guard pid != 0, let running = NSRunningApplication(processIdentifier: pid_t(pid)), !running.isTerminated else {
            return
        }
        targetApp = running
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
        guard let app = targetApp else { return "未设置" }
        if app.isTerminated {
            return "(已退出的实例)"
        }
        return "\(app.localizedName ?? "?") · pid \(app.processIdentifier)"
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

        // ---- 选择一个已在运行的实例作为目标(按 pid 区分, 同一个 App 开多个也能分清) ----
        let runningHeader = NSMenuItem(title: "选择已运行的实例:", action: nil, keyEquivalent: "")
        runningHeader.isEnabled = false
        menu.addItem(runningHeader)

        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        if apps.isEmpty {
            let empty = NSMenuItem(title: "(没有检测到可选 App)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        for app in apps {
            let title = "\(app.localizedName ?? "?") · pid \(app.processIdentifier)"
            let item = NSMenuItem(title: title, action: #selector(selectRunningTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            item.state = (app.processIdentifier == targetApp?.processIdentifier) ? .on : .off
            if let icon = app.icon {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // ---- 打开一个全新的独立实例作为目标(避免和已有窗口混淆) ----
        let openNewItem = NSMenuItem(title: "打开新实例作为目标...", action: nil, keyEquivalent: "")
        let openNewSubmenu = NSMenu()
        for info in installedApplications() {
            let item = NSMenuItem(title: info.name, action: #selector(openNewInstance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = info.url
            openNewSubmenu.addItem(item)
        }
        openNewItem.submenu = openNewSubmenu
        menu.addItem(openNewItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "按键动作设置...", action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 HanHan Agent", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc func selectRunningTarget(_ sender: NSMenuItem) {
        targetApp = sender.representedObject as? NSRunningApplication
    }

    @objc func openNewInstance(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false // 不抢占当前焦点
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] runningApp, error in
            DispatchQueue.main.async {
                if let error = error {
                    NSLog("[HanHanAgent] 打开新实例失败: \(error.localizedDescription)")
                    return
                }
                self?.targetApp = runningApp
            }
        }
    }

    @objc func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(delegate: self)
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    // 扫描常见目录下已安装的 App, 供"打开新实例"菜单使用
    func installedApplications() -> [(name: String, url: URL)] {
        var results: [(String, URL)] = []
        let dirs = [
            "/Applications",
            "/System/Applications",
            "\(NSHomeDirectory())/Applications",
        ]
        for dir in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(item)
                let name = (item as NSString).deletingPathExtension
                results.append((name, url))
            }
        }
        return results.sorted { $0.0.localizedCompare($1.0) == .orderedAscending }
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

        // 命中目标键: 按预设动作转发到目标 App 实例(不抢焦点), 并吞掉原始事件
        guard let target = targetApp, !target.isTerminated else {
            return nil
        }
        let pid = target.processIdentifier
        let action = keyActions[keycode] ?? .passthrough

        if action == .passthrough {
            if let copy = event.copy() {
                copy.postToPid(pid)
            }
        } else {
            let (vk, flags) = action.keycodeAndFlags
            if let synthetic = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: (type == .keyDown)) {
                synthetic.flags = flags
                synthetic.postToPid(pid)
            }
        }

        return nil
    }
}

// MARK: - 按键动作设置窗口

final class SettingsWindowController: NSWindowController {
    weak var appDelegate: AppDelegate?
    var popups: [Int64: NSPopUpButton] = [:]

    convenience init(delegate: AppDelegate) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "HanHan Agent · 按键动作设置"
        window.center()
        self.init(window: window)
        self.appDelegate = delegate
        buildContent()
    }

    func buildContent() {
        guard let window = window else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "为每个物理按键选择按下后实际发送给目标 App 的动作:")
        hint.font = NSFont.systemFont(ofSize: 12)
        stack.addArrangedSubview(hint)

        for (label, keycode) in physicalKeys {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8

            let nameLabel = NSTextField(labelWithString: label)
            nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            nameLabel.widthAnchor.constraint(equalToConstant: 170).isActive = true

            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: PresetAction.allCases.map { $0.rawValue })
            let current = appDelegate?.keyActions[keycode] ?? .passthrough
            popup.selectItem(withTitle: current.rawValue)
            popup.target = self
            popup.action = #selector(popupChanged(_:))
            popup.tag = Int(keycode)
            popups[keycode] = popup

            row.addArrangedSubview(nameLabel)
            row.addArrangedSubview(popup)
            stack.addArrangedSubview(row)
        }

        let doneButton = NSButton(title: "完成", target: self, action: #selector(closeWindow))
        doneButton.bezelStyle = .rounded
        stack.addArrangedSubview(doneButton)

        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        container.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = container
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
        ])
    }

    @objc func popupChanged(_ sender: NSPopUpButton) {
        let keycode = Int64(sender.tag)
        guard let title = sender.selectedItem?.title, let action = PresetAction(rawValue: title) else { return }
        appDelegate?.keyActions[keycode] = action
    }

    @objc func closeWindow() {
        window?.close()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // 只在菜单栏显示, 不出现在 Dock/应用切换器
app.run()
