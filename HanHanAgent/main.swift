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
import CoreBluetooth

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
let kDefaultsTargetModeKey = "targetMode" // TargetMode.rawValue
let kDefaultsKeyActionsKey = "keyActions" // [String(keycode): PresetAction.rawValue]

// 目标模式: 固定某个 App 实例, 或者跟随当前最前台的窗口(全局, 谁在最前面就发给谁)
enum TargetMode: String {
    case specificApp
    case frontmost
}

// MARK: - LED 蓝牙控制(独立于 HID 连接, 直接用 CoreBluetooth 连固件自定义 LED 特征值)

// 预设 LED 效果(对应固件: byte0=mask, byte1=mode)
enum LedPreset: String, CaseIterable {
    case off = "全灭"
    case allOn = "三灯都亮(常亮)"
    case led0Only = "只亮 LED0"
    case led1Only = "只亮 LED1"
    case led2Only = "只亮 LED2"
    case blinkAll = "三灯一起闪烁"
    case chase = "流水灯"

    var payload: (mask: UInt8, mode: UInt8) {
        switch self {
        case .off:      return (0b000, 0) // mode 0 = 全灭
        case .allOn:    return (0b111, 1) // mode 1 = 常亮
        case .led0Only: return (0b001, 1)
        case .led1Only: return (0b010, 1)
        case .led2Only: return (0b100, 1)
        case .blinkAll: return (0b111, 2) // mode 2 = 闪烁
        case .chase:    return (0b111, 3) // mode 3 = 流水灯(固件内部忽略 mask)
        }
    }
}

final class HanHanBLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    // 必须和固件 setupBle() 里 NimBLEDevice::init(...) 的名字、Service/Characteristic UUID 完全一致
    static let deviceNamePrefix = "HanHan 5K3L"
    static let ledServiceUUID = CBUUID(string: "6E400100-B5A3-F393-E0A9-E50E24DCCA9E")
    static let ledCharUUID = CBUUID(string: "6E400101-B5A3-F393-E0A9-E50E24DCCA9E")
    static let ledCalibCharUUID = CBUUID(string: "6E400102-B5A3-F393-E0A9-E50E24DCCA9E")
    static let allocSumMax = 100 // 三颗灯分配百分比总和上限, 对应固件 LED_ALLOC_SUM_MAX
    static let allocDefaultsKey = "ledAllocPercent" // [Int] 长度 3, 总和 <=100

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var ledChar: CBCharacteristic?
    private var ledCalibChar: CBCharacteristic?
    private var scanTimeoutWorkItem: DispatchWorkItem?

    // 连上设备前如果调用了 send(), 先记下来, 连接建立后自动补发
    private var pendingPayload: (mask: UInt8, mode: UInt8)?

    var onStatusChanged: (() -> Void)?

    private(set) var statusText: String = "未初始化"

    // 每颗 LED 分配到的帧内占比(0~100, 三者总和 <=100), 持久化在 UserDefaults,
    // 每次重连会自动下发给固件。默认各 30(总和 90, 和之前版本的默认值一致)。
    private(set) var allocPercent: [UInt8] = {
        if let saved = UserDefaults.standard.array(forKey: HanHanBLEManager.allocDefaultsKey) as? [Int], saved.count == 3 {
            var vals = saved.map { UInt8(max(0, min(HanHanBLEManager.allocSumMax, $0))) }
            HanHanBLEManager.clampAllocation(&vals)
            return vals
        }
        return [30, 30, 30]
    }()

    // 和固件 clampLedAllocation() 逻辑一致: 单值先夹到 0~100, 总和超了就按比例整体缩小
    static func clampAllocation(_ vals: inout [UInt8]) {
        var sum = 0
        for i in 0..<vals.count {
            if Int(vals[i]) > allocSumMax { vals[i] = UInt8(allocSumMax) }
            sum += Int(vals[i])
        }
        if sum > allocSumMax && sum > 0 {
            for i in 0..<vals.count {
                vals[i] = UInt8(Int(vals[i]) * allocSumMax / sum)
            }
        }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private func setStatus(_ text: String) {
        statusText = text
        NSLog("[HanHanAgent][BLE] \(text)")
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?()
        }
    }

    func startScan() {
        guard central.state == .poweredOn else {
            setStatus("蓝牙未就绪(state=\(central.state.rawValue)), 稍后再试")
            return
        }
        if let p = peripheral, p.state == .connected {
            setStatus("已连接: \(p.name ?? "?")")
            return
        }

        // 优先复用系统已经建立好的那条蓝牙连接(比如系统设置->蓝牙里配对的 HID 键盘连接),
        // 不用自己再单独扫描建立第二条连接, 更稳定也不依赖固件"同时支持多条连接"的逻辑。
        let already = central.retrieveConnectedPeripherals(withServices: [Self.ledServiceUUID])
        if let existing = already.first {
            scanTimeoutWorkItem?.cancel()
            self.peripheral = existing
            existing.delegate = self
            setStatus("复用已有连接: \(existing.name ?? "?"), 查找服务中...")
            central.connect(existing, options: nil)
            return
        }

        setStatus("搜索中...(未发现已有系统连接, 尝试直接扫描)")
        central.scanForPeripherals(withServices: nil, options: nil)

        // 搜索超时保护: 避免因为设备不在范围内/未上电等原因导致永远卡在"搜索中"
        scanTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.peripheral?.state != .connected {
                self.central.stopScan()
                self.setStatus("未找到设备, 请确认 HanHan 5K3L 已通电且在蓝牙范围内, 然后点击「重新搜索设备」")
            }
        }
        scanTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func send(mask: UInt8, mode: UInt8) {
        guard let p = peripheral, p.state == .connected, let chr = ledChar else {
            // 还没连上: 记下待发送内容, 顺便触发一次扫描连接
            pendingPayload = (mask, mode)
            startScan()
            return
        }
        let data = Data([mask, mode])
        let writeType: CBCharacteristicWriteType = chr.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(data, for: chr, type: writeType)
        setStatus("已发送 mask=0b\(String(mask, radix: 2)) mode=\(mode)")
    }

    // 一次性设置三颗 LED 的分配百分比(每个 0~100, 总和会被自动夹到 <=100),
    // 立即持久化并在已连接时下发给固件。供亮度/分配滑块界面调用。
    func setAllocation(_ values: [UInt8]) {
        guard values.count == 3 else { return }
        var vals = values
        Self.clampAllocation(&vals)
        allocPercent = vals
        UserDefaults.standard.set(allocPercent.map { Int($0) }, forKey: Self.allocDefaultsKey)
        sendCalibration()
    }

    func sendCalibration() {
        guard let p = peripheral, p.state == .connected, let chr = ledCalibChar else { return }
        let data = Data(allocPercent)
        let writeType: CBCharacteristicWriteType = chr.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(data, for: chr, type: writeType)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            setStatus("蓝牙已就绪")
        case .poweredOff:
            setStatus("蓝牙未开启")
        case .unauthorized:
            setStatus("没有蓝牙权限, 请在 系统设置->隐私与安全性->蓝牙 中允许 HanHan Agent")
        default:
            setStatus("蓝牙状态: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        guard let n = name, n.hasPrefix(Self.deviceNamePrefix) else { return }
        central.stopScan()
        scanTimeoutWorkItem?.cancel()
        self.peripheral = peripheral
        peripheral.delegate = self
        setStatus("找到 \(n), 连接中...")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        setStatus("已连接 \(peripheral.name ?? "?"), 查找服务中...")
        peripheral.discoverServices([Self.ledServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        setStatus("连接失败: \(error?.localizedDescription ?? "未知错误")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        ledChar = nil
        ledCalibChar = nil
        setStatus("已断开")
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == Self.ledServiceUUID {
            peripheral.discoverCharacteristics([Self.ledCharUUID, Self.ledCalibCharUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            if c.uuid == Self.ledCharUUID {
                ledChar = c
            } else if c.uuid == Self.ledCalibCharUUID {
                ledCalibChar = c
            }
        }
        if ledChar != nil {
            setStatus("就绪: \(peripheral.name ?? "?")")
            // 连接建立后把本地保存的亮度校准值重新下发一遍, 固件重启后会丢失这个状态
            sendCalibration()
            if let pending = pendingPayload {
                pendingPayload = nil
                send(mask: pending.mask, mode: pending.mode)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var settingsWindowController: SettingsWindowController?
    var ledControlWindowController: LedControlWindowController?
    let bleManager = HanHanBLEManager()

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

    // 目标模式: 固定 App 实例 / 跟随当前最前台窗口(全局)
    var targetMode: TargetMode = .specificApp {
        didSet {
            UserDefaults.standard.set(targetMode.rawValue, forKey: kDefaultsTargetModeKey)
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

        bleManager.onStatusChanged = { [weak self] in
            self?.rebuildMenu()
            self?.ledControlWindowController?.refreshStatus()
        }
        bleManager.startScan()

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
        if let modeRaw = UserDefaults.standard.string(forKey: kDefaultsTargetModeKey),
           let mode = TargetMode(rawValue: modeRaw) {
            targetMode = mode
        }
        let pid = UserDefaults.standard.integer(forKey: kDefaultsTargetPidKey)
        guard pid != 0, let running = NSRunningApplication(processIdentifier: pid_t(pid)), !running.isTerminated else {
            return
        }
        targetApp = running
    }

    // 实际转发目标: 全局模式下取"当前最前台的窗口"所属 App(不含本 App 自己,
    // 因为是 LSUIElement 菜单栏小工具, 正常情况下不会变成前台); 否则用固定选中的实例。
    func resolveForwardTarget() -> NSRunningApplication? {
        switch targetMode {
        case .frontmost:
            guard let front = NSWorkspace.shared.frontmostApplication, !front.isTerminated,
                  front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return nil
            }
            return front
        case .specificApp:
            guard let app = targetApp, !app.isTerminated else { return nil }
            return app
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
        if let icon = NSImage(named: "AppIcon") {
            let menuBarIcon = NSImage(size: NSSize(width: 18, height: 18))
            menuBarIcon.lockFocus()
            icon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18),
                      from: .zero, operation: .sourceOver, fraction: 1.0)
            menuBarIcon.unlockFocus()
            menuBarIcon.isTemplate = false // 保留猫咪原色, 不走系统单色模板渲染
            statusItem.button?.image = menuBarIcon
        } else {
            statusItem.button?.title = "HH"
        }
        rebuildMenu()
    }

    func currentTargetDisplayName() -> String {
        switch targetMode {
        case .frontmost:
            return "跟随前台窗口(全局)"
        case .specificApp:
            guard let app = targetApp else { return "未设置" }
            if app.isTerminated {
                return "(已退出的实例)"
            }
            return "\(app.localizedName ?? "?") · pid \(app.processIdentifier)"
        }
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

        // ---- 全局模式: 不固定某个 App, 按键发给"当前最前台的窗口" ----
        let frontmostItem = NSMenuItem(title: "跟随前台窗口(全局)", action: #selector(selectFrontmostMode), keyEquivalent: "")
        frontmostItem.target = self
        frontmostItem.state = (targetMode == .frontmost) ? .on : .off
        menu.addItem(frontmostItem)

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
            item.state = (targetMode == .specificApp && app.processIdentifier == targetApp?.processIdentifier) ? .on : .off
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

        // ---- LED 控制(效果预设 + 亮度/分配滑块合并成一个独立窗口) ----
        menu.addItem(NSMenuItem(title: "LED 控制...", action: #selector(openLedControl), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "按键动作设置...", action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 HanHan Agent", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc func selectFrontmostMode() {
        targetMode = .frontmost
    }

    @objc func selectRunningTarget(_ sender: NSMenuItem) {
        targetMode = .specificApp
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
                self?.targetMode = .specificApp
                self?.targetApp = runningApp
            }
        }
    }

    @objc func openLedControl() {
        if ledControlWindowController == nil {
            ledControlWindowController = LedControlWindowController(bleManager: bleManager)
        }
        ledControlWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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

        NSLog("[HanHanAgent] 命中按键 keycode=\(keycode) type=\(type == .keyDown ? "down" : "up")")

        // 命中目标键: 按预设动作转发到目标 App 实例(不抢焦点), 并吞掉原始事件
        guard let target = resolveForwardTarget() else {
            NSLog("[HanHanAgent] 没有可用目标(targetApp 为空/已退出, 或全局模式下取不到前台 App), 按键被吞掉但不会转发")
            return nil
        }
        let pid = target.processIdentifier
        let action = keyActions[keycode] ?? .passthrough

        NSLog("[HanHanAgent] 转发给 pid=\(pid) (\(target.localizedName ?? "?")) action=\(action.rawValue)")

        if action == .passthrough {
            if let copy = event.copy() {
                copy.postToPid(pid)
            }
        } else {
            let (vk, flags) = action.keycodeAndFlags
            if let synthetic = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: (type == .keyDown)) {
                synthetic.flags = flags
                synthetic.postToPid(pid)
                NSLog("[HanHanAgent] 已合成并投递 vk=\(vk) flags=\(flags.rawValue)")
            } else {
                NSLog("[HanHanAgent] 合成按键事件失败!")
            }
        }

        return nil
    }
}

// MARK: - 按键动作设置窗口

// MARK: - LED 控制窗口(效果预设 + 亮度/分配滑块)

final class LedControlWindowController: NSWindowController {
    let bleManager: HanHanBLEManager
    var statusLabel: NSTextField!
    var totalLabel: NSTextField!
    var sliders: [NSSlider] = []
    var valueLabels: [NSTextField] = []
    let ledNames = ["LED0 (黄)", "LED1 (红)", "LED2 (绿)"]

    init(bleManager: HanHanBLEManager) {
        self.bleManager = bleManager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "HanHan Agent · LED 控制"
        window.center()
        super.init(window: window)
        buildContent()
        refreshStatus()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func buildContent() {
        guard let window = window else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "状态: -")
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        stack.addArrangedSubview(statusLabel)

        let rescanButton = NSButton(title: "重新搜索设备", target: self, action: #selector(rescan))
        rescanButton.bezelStyle = .rounded
        stack.addArrangedSubview(rescanButton)

        stack.addArrangedSubview(separatorView())

        let presetHint = NSTextField(labelWithString: "效果预设:")
        presetHint.font = NSFont.boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(presetHint)

        let presetGrid = NSStackView()
        presetGrid.orientation = .vertical
        presetGrid.alignment = .leading
        presetGrid.spacing = 6
        var row: NSStackView? = nil
        for (i, preset) in LedPreset.allCases.enumerated() {
            if i % 2 == 0 {
                row = NSStackView()
                row?.orientation = .horizontal
                row?.spacing = 8
                presetGrid.addArrangedSubview(row!)
            }
            let button = NSButton(title: preset.rawValue, target: self, action: #selector(applyPreset(_:)))
            button.bezelStyle = .rounded
            button.tag = i
            row?.addArrangedSubview(button)
        }
        stack.addArrangedSubview(presetGrid)

        stack.addArrangedSubview(separatorView())

        let calibHint = NSTextField(labelWithString: "亮度/分配(三者总和 <=100, 拖动调整, 各灯 Vf 不同可借此调平):")
        calibHint.font = NSFont.boldSystemFont(ofSize: 12)
        calibHint.preferredMaxLayoutWidth = 360
        stack.addArrangedSubview(calibHint)

        for i in 0..<3 {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8

            let nameLabel = NSTextField(labelWithString: ledNames[i])
            nameLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true

            let slider = NSSlider(value: Double(bleManager.allocPercent[i]), minValue: 0, maxValue: 100,
                                   target: self, action: #selector(sliderChanged(_:)))
            slider.tag = i
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
            sliders.append(slider)

            let valueLabel = NSTextField(labelWithString: "\(bleManager.allocPercent[i])%")
            valueLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
            valueLabels.append(valueLabel)

            row.addArrangedSubview(nameLabel)
            row.addArrangedSubview(slider)
            row.addArrangedSubview(valueLabel)
            stack.addArrangedSubview(row)
        }

        totalLabel = NSTextField(labelWithString: "")
        totalLabel.font = NSFont.systemFont(ofSize: 12)
        stack.addArrangedSubview(totalLabel)
        updateTotalLabel()

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

    func separatorView() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 380).isActive = true
        return line
    }

    func updateTotalLabel() {
        let sum = bleManager.allocPercent.reduce(0) { $0 + Int($1) }
        totalLabel.stringValue = "总计: \(sum) / 100"
        totalLabel.textColor = sum > 100 ? .systemRed : .secondaryLabelColor
    }

    func refreshStatus() {
        statusLabel?.stringValue = "状态: \(bleManager.statusText)"
    }

    @objc func rescan() {
        bleManager.startScan()
    }

    @objc func applyPreset(_ sender: NSButton) {
        guard sender.tag >= 0 && sender.tag < LedPreset.allCases.count else { return }
        let preset = LedPreset.allCases[sender.tag]
        let (mask, mode) = preset.payload
        bleManager.send(mask: mask, mode: mode)
    }

    // 拖动某一个滑块时, 如果会导致总和超过 100, 就把这个滑块本身夹到"剩余预算"以内
    // (不偷偷改动另外两个, 用户体感更直观: 想要更亮就得先把别的调低腾出空间)
    @objc func sliderChanged(_ sender: NSSlider) {
        let index = sender.tag
        var vals = sliders.map { UInt8($0.doubleValue.rounded()) }
        let others = (0..<3).filter { $0 != index }.reduce(0) { $0 + Int(vals[$1]) }
        let budget = max(0, 100 - others)
        if Int(vals[index]) > budget {
            vals[index] = UInt8(budget)
            sender.doubleValue = Double(budget)
        }
        for i in 0..<3 {
            valueLabels[i].stringValue = "\(vals[i])%"
        }
        updateTotalLabel()
        bleManager.setAllocation(vals)
    }

    @objc func closeWindow() {
        window?.close()
    }
}

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
