import SwiftUI
import UserNotifications
import AVFoundation
import AppKit

// MARK: - Alert Method

struct AlertMethod: OptionSet, Codable {
    let rawValue: Int
    static let sound       = AlertMethod(rawValue: 1 << 0)
    static let notification = AlertMethod(rawValue: 1 << 1)
    static let dialog      = AlertMethod(rawValue: 1 << 2)
    static let speech      = AlertMethod(rawValue: 1 << 3)
    static let screenFlash = AlertMethod(rawValue: 1 << 4)
    static let dockBounce  = AlertMethod(rawValue: 1 << 5)

    static let defaultMethods: AlertMethod = [.sound, .notification, .dialog]
    static let allMethods: [(AlertMethod, String, String)] = [
        (.sound,       "声音提示",     "systemSpeaker.fill"),
        (.notification,"系统通知",     "bell.fill"),
        (.dialog,      "弹窗对话框",   "exclamationmark.bubble.fill"),
        (.speech,      "语音播报",     "mouth.fill"),
        (.screenFlash, "屏幕闪烁",     "sparkles.rectangle.stack.fill"),
        (.dockBounce,  "Dock 跳动",   "arrow.up.square.fill"),
    ]
}

// MARK: - Data Model

struct ReminderItem: Identifiable, Codable {
    let id: UUID
    var message: String
    var targetDate: Date
    var isActive: Bool
    var isRepeat: Bool
    var repeatInterval: Double // minutes
    var sound: String
    var alertMethods: AlertMethod

    init(message: String, targetDate: Date, isRepeat: Bool = false, repeatInterval: Double = 30, sound: String = "Glass", alertMethods: AlertMethod = .defaultMethods) {
        self.id = UUID()
        self.message = message
        self.targetDate = targetDate
        self.isActive = true
        self.isRepeat = isRepeat
        self.repeatInterval = repeatInterval
        self.sound = sound
        self.alertMethods = alertMethods
    }
}

// MARK: - Reminder Manager

class ReminderManager: ObservableObject {
    @Published var reminders: [ReminderItem] = []
    private var timers: [UUID: Timer] = [:]
    private let saveURL: URL
    private let synthesizer = NSSpeechSynthesizer()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("定时提醒", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        saveURL = appDir.appendingPathComponent("reminders.json")
        loadReminders()
        requestNotificationPermission()
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .provisional]) { granted, error in
            if let error = error {
                print("[Notification] Authorization error: \(error)")
            }
            print("[Notification] Authorization granted: \(granted)")
        }
    }

    func addReminder(_ item: ReminderItem) {
        reminders.append(item)
        scheduleTimer(for: item)
        saveReminders()
    }

    func deleteReminder(_ item: ReminderItem) {
        timers[item.id]?.invalidate()
        timers.removeValue(forKey: item.id)
        reminders.removeAll { $0.id == item.id }
        saveReminders()
    }

    func clearCompleted() {
        let done = reminders.filter { !$0.isActive }
        for d in done {
            timers[d.id]?.invalidate()
            timers.removeValue(forKey: d.id)
        }
        reminders.removeAll { !$0.isActive }
        saveReminders()
    }

    private func scheduleTimer(for item: ReminderItem) {
        let delay = item.targetDate.timeIntervalSinceNow
        guard delay > 0 else {
            markDone(item.id)
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: max(0.1, delay), repeats: false) { [weak self] _ in
            self?.fireReminder(item.id)
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[item.id] = timer
    }

    private func fireReminder(_ id: UUID) {
        guard let idx = reminders.firstIndex(where: { $0.id == id && $0.isActive }) else { return }
        let item = reminders[idx]
        let methods = item.alertMethods

        // 1. Sound
        if methods.contains(.sound) {
            playSound(item.sound)
        }

        // 2. System notification
        if methods.contains(.notification) {
            sendNotification(title: "⏰ 定时提醒", body: item.message, sound: item.sound)
        }

        // 3. Dock bounce
        if methods.contains(.dockBounce) {
            NSApp.requestUserAttention(.criticalRequest)
        }

        // 4. Screen flash
        if methods.contains(.screenFlash) {
            showScreenFlash(message: item.message)
        }

        // 5. Speech (TTS)
        if methods.contains(.speech) {
            speakMessage(item.message)
        }

        // 6. Alert dialog (last, because it blocks)
        if methods.contains(.dialog) {
            showAlert(message: item.message)
        }

        if item.isRepeat && item.repeatInterval > 0 {
            reminders[idx].targetDate = Date().addingTimeInterval(item.repeatInterval * 60)
            scheduleTimer(for: reminders[idx])
        } else {
            reminders[idx].isActive = false
        }
        saveReminders()
    }

    private func markDone(_ id: UUID) {
        if let idx = reminders.firstIndex(where: { $0.id == id }) {
            reminders[idx].isActive = false
            saveReminders()
        }
    }

    private func playSound(_ name: String) {
        let soundPath = "/System/Library/Sounds/\(name).aiff"
        if FileManager.default.fileExists(atPath: soundPath) {
            let url = URL(fileURLWithPath: soundPath)
            NSSound(contentsOf: url, byReference: true)?.play()
        }
    }

    private func sendNotification(title: String, body: String, sound: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "\(sound).aiff"))
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func showAlert(message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "⏰ 提醒时间到！"
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "知道了")

            // Bring app to front
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func speakMessage(_ message: String) {
        synthesizer.stopSpeaking()
        synthesizer.startSpeaking("提醒: \(message)")
    }

    private func showScreenFlash(message: String) {
        DispatchQueue.main.async {
            guard let screen = NSScreen.main else { return }
            let flashWindow = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            flashWindow.level = .screenSaver
            flashWindow.backgroundColor = NSColor.systemRed.withAlphaComponent(0.35)
            flashWindow.isOpaque = false
            flashWindow.hasShadow = false
            flashWindow.ignoresMouseEvents = false
            flashWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let hostView = NSHostingView(rootView:
                VStack(spacing: 16) {
                    Text("⏰")
                        .font(.system(size: 80))
                    Text(message)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Text("点击任意位置关闭")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
            )
            flashWindow.contentView = hostView
            flashWindow.makeKeyAndOrderFront(nil)

            // Flash animation: pulse 3 times
            var flashCount = 0
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
                flashCount += 1
                flashWindow.backgroundColor = flashCount % 2 == 0
                    ? NSColor.systemRed.withAlphaComponent(0.35)
                    : NSColor.systemOrange.withAlphaComponent(0.45)
                if flashCount >= 6 {
                    timer.invalidate()
                    flashWindow.backgroundColor = NSColor.systemRed.withAlphaComponent(0.3)
                }
            }

            // Click to close
            let clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                flashWindow.orderOut(nil)
                return event
            }
            // Auto close after 15 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                flashWindow.orderOut(nil)
                if let monitor = clickMonitor {
                    NSEvent.removeMonitor(monitor)
                }
            }
        }
    }

    private func saveReminders() {
        if let data = try? JSONEncoder().encode(reminders) {
            try? data.write(to: saveURL)
        }
    }

    private func loadReminders() {
        guard let data = try? Data(contentsOf: saveURL),
              let items = try? JSONDecoder().decode([ReminderItem].self, from: data) else { return }
        reminders = items
        for item in reminders where item.isActive {
            if item.targetDate > Date() {
                scheduleTimer(for: item)
            } else {
                if let idx = reminders.firstIndex(where: { $0.id == item.id }) {
                    reminders[idx].isActive = false
                }
            }
        }
    }
}

// MARK: - App Delegate with Status Bar

import Combine

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var manager: ReminderManager?
    private var observation: AnyCancellable?
    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set notification delegate so notifications show even when app is in foreground
        UNUserNotificationCenter.current().delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "clock.fill", accessibilityDescription: "定时提醒")
            button.image?.size = NSSize(width: 16, height: 16)
            button.imagePosition = .imageLeading
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Find and retain the main window, set delegate to intercept close
        DispatchQueue.main.async { [weak self] in
            self?.captureMainWindow()
        }
    }

    private func captureMainWindow() {
        for window in NSApp.windows where window.canBecomeMain {
            mainWindow = window
            window.delegate = self
            break
        }
    }

    // Intercept window close: hide instead of close
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // Allow notifications to show when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    // Handle notification click
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        showMainWindow()
        completionHandler()
    }

    // Closing the last window does NOT quit the app
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // Clicking Dock icon reopens the window
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func bind(manager: ReminderManager) {
        self.manager = manager
        updateTitle()
        observation = manager.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateTitle()
            }
        }
    }

    private func updateTitle() {
        guard let manager = manager, let button = statusItem?.button else { return }
        let activeCount = manager.reminders.filter { $0.isActive }.count
        button.title = activeCount > 0 ? " \(activeCount)" : ""
    }

    // NSMenuDelegate: rebuild menu each time it opens
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let manager = manager else { return }
        let activeCount = manager.reminders.filter { $0.isActive }.count

        let headerItem = NSMenuItem(title: "⏰ 定时提醒", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        let showItem = NSMenuItem(title: "打开主窗口", action: #selector(showMainWindow), keyEquivalent: "o")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(NSMenuItem.separator())

        if activeCount > 0 {
            let activeHeader = NSMenuItem(title: "进行中 (\(activeCount))", action: nil, keyEquivalent: "")
            activeHeader.isEnabled = false
            menu.addItem(activeHeader)

            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            for item in manager.reminders where item.isActive {
                let timeStr = formatter.string(from: item.targetDate)
                let title = "  \(timeStr)  \(item.message)"
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                menuItem.isEnabled = false
                menu.addItem(menuItem)
            }
        } else {
            let emptyItem = NSMenuItem(title: "暂无进行中的提醒", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        }

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Recapture in case window reference was lost
            captureMainWindow()
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Main App

@main
struct ReminderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var manager = ReminderManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .frame(minWidth: 520, minHeight: 620)
                .onAppear {
                    appDelegate.bind(manager: manager)
                }
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var manager: ReminderManager
    @State private var mode: TimeMode = .delay
    @State private var delayMinutes: String = "5"
    @State private var clockHour: String = ""
    @State private var clockMinute: String = ""
    @State private var message: String = "该休息一下了！"
    @State private var isRepeat: Bool = false
    @State private var repeatInterval: String = "30"
    @State private var selectedSound: String = "Glass"
    @State private var alertMethods: AlertMethod = .defaultMethods

    enum TimeMode: String, CaseIterable {
        case delay = "倒计时"
        case clock = "指定时间"
    }

    let sounds = ["Glass", "Ping", "Basso", "Blow", "Bottle", "Frog", "Funk", "Hero", "Morse", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                Text("⏰ 定时提醒工具")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.top, 8)

                Text(Date(), style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)

                // New Reminder Card
                GroupBox(label: Label("新建提醒", systemImage: "plus.circle.fill").foregroundColor(.blue)) {
                    VStack(alignment: .leading, spacing: 14) {
                        // Mode picker
                        Picker("提醒方式", selection: $mode) {
                            ForEach(TimeMode.allCases, id: \.self) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)

                        // Time input
                        if mode == .delay {
                            HStack {
                                Text("分钟数")
                                    .frame(width: 60, alignment: .leading)
                                TextField("如 0.5 = 30秒", text: $delayMinutes)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 120)
                                Text("分钟后提醒")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        } else {
                            HStack {
                                Text("时间")
                                    .frame(width: 60, alignment: .leading)
                                TextField("HH", text: $clockHour)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 50)
                                Text(":")
                                    .font(.title2.bold())
                                TextField("MM", text: $clockMinute)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 50)
                            }
                            .onAppear {
                                let now = Date()
                                let cal = Calendar.current
                                clockHour = String(format: "%02d", cal.component(.hour, from: now))
                                clockMinute = String(format: "%02d", cal.component(.minute, from: now))
                            }
                        }

                        // Message
                        HStack {
                            Text("内容")
                                .frame(width: 60, alignment: .leading)
                            TextField("输入提醒内容", text: $message)
                                .textFieldStyle(.roundedBorder)
                        }

                        // Repeat
                        HStack {
                            Toggle("重复提醒", isOn: $isRepeat)
                                .toggleStyle(.checkbox)
                            if isRepeat {
                                Text("间隔")
                                    .foregroundColor(.secondary)
                                TextField("30", text: $repeatInterval)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 50)
                                Text("分钟")
                                    .foregroundColor(.secondary)
                            }
                        }

                        // Sound
                        HStack {
                            Text("提示音")
                                .frame(width: 60, alignment: .leading)
                            Picker("", selection: $selectedSound) {
                                ForEach(sounds, id: \.self) { s in
                                    Text(s).tag(s)
                                }
                            }
                            .frame(width: 140)

                            Button("试听") {
                                let path = "/System/Library/Sounds/\(selectedSound).aiff"
                                if let sound = NSSound(contentsOfFile: path, byReference: true) {
                                    sound.play()
                                }
                            }
                            .buttonStyle(.bordered)
                        }

                        // Alert methods
                        VStack(alignment: .leading, spacing: 8) {
                            Text("提醒方式")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                ForEach(AlertMethod.allMethods, id: \.0.rawValue) { method, name, icon in
                                    Button(action: {
                                        if alertMethods.contains(method) {
                                            alertMethods.remove(method)
                                        } else {
                                            alertMethods.insert(method)
                                        }
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: alertMethods.contains(method) ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(alertMethods.contains(method) ? .blue : .secondary)
                                                .font(.system(size: 14))
                                            Text(name)
                                                .font(.system(size: 12))
                                                .foregroundColor(alertMethods.contains(method) ? .primary : .secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 6)
                                        .padding(.horizontal, 8)
                                        .background(alertMethods.contains(method) ? Color.blue.opacity(0.08) : Color.gray.opacity(0.06))
                                        .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // Add button
                        Button(action: addReminder) {
                            HStack {
                                Image(systemName: "plus")
                                Text("添加提醒")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    .padding(.top, 8)
                }

                // Reminder List
                GroupBox(label: Label("提醒列表 (\(manager.reminders.filter { $0.isActive }.count) 个进行中)", systemImage: "list.bullet.circle.fill").foregroundColor(.blue)) {
                    if manager.reminders.isEmpty {
                        Text("暂无提醒，添加一个试试吧")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(manager.reminders) { item in
                                ReminderRow(item: item) {
                                    manager.deleteReminder(item)
                                }
                                if item.id != manager.reminders.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }

                    Button("清除已完成") {
                        manager.clearCompleted()
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 8)
                    .disabled(manager.reminders.allSatisfy { $0.isActive })
                }

                // Footer
                Text("提醒时会根据所选方式进行提醒")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 20)
        }
    }

    private func addReminder() {
        let trimmed = message.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let targetDate: Date
        if mode == .delay {
            guard let mins = Double(delayMinutes), mins > 0 else { return }
            targetDate = Date().addingTimeInterval(mins * 60)
        } else {
            guard let h = Int(clockHour), let m = Int(clockMinute),
                  (0...23).contains(h), (0...59).contains(m) else { return }
            let cal = Calendar.current
            var comps = cal.dateComponents([.year, .month, .day], from: Date())
            comps.hour = h
            comps.minute = m
            comps.second = 0
            guard var date = cal.date(from: comps) else { return }
            if date <= Date() {
                date = cal.date(byAdding: .day, value: 1, to: date)!
            }
            targetDate = date
        }

        let ri = Double(repeatInterval) ?? 30
        let item = ReminderItem(
            message: trimmed,
            targetDate: targetDate,
            isRepeat: isRepeat,
            repeatInterval: ri,
            sound: selectedSound,
            alertMethods: alertMethods
        )
        manager.addReminder(item)
    }
}

// MARK: - Reminder Row

struct ReminderRow: View {
    let item: ReminderItem
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.message)
                    .font(.system(size: 14, weight: .medium))
                HStack(spacing: 6) {
                    Text(item.targetDate, format: .dateTime.month().day().hour().minute().second())
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if item.isRepeat {
                        Text("每\(Int(item.repeatInterval))分钟")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(4)
                    }
                    if item.sound != "Glass" {
                        Text("🔔\(item.sound)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    let methodNames = AlertMethod.allMethods
                        .filter { item.alertMethods.contains($0.0) }
                        .map { $0.1 }
                    if !methodNames.isEmpty {
                        Text(methodNames.joined(separator: "·"))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
            }
            Spacer()
            Text(item.isActive ? "⏳ 等待中" : "✅ 已完成")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(item.isActive ? Color.green.opacity(0.1) : Color.gray.opacity(0.1))
                .cornerRadius(6)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
    }
}
