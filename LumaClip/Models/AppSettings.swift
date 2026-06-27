// AppSettings.swift
// LumaClip - macOS Clipboard Manager
//
// Centralized application settings model backed by UserDefaults.
// Provides reactive @Published properties for SwiftUI binding.

import Foundation
import Combine
import AppKit
import SwiftUI

// MARK: - Appearance Mode

/// Controls whether the app follows system, uses light, or uses dark mode.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "system"
    case light  = "light"
    case dark   = "dark"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System".loc
        case .light:  return "Light".loc
        case .dark:   return "Dark".loc
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    var nsAppearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light:  return .aqua
        case .dark:   return .darkAqua
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - Light Theme


extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8)  & 0xFF) / 255.0,
            blue:  Double(hex         & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

// MARK: - List Density

/// Controls how compact or spacious the clipboard list rows appear.
enum ListDensity: String, CaseIterable, Identifiable {
    case compact     = "compact"
    case comfortable = "comfortable"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact:     return "Compact".loc
        case .comfortable: return "Comfortable".loc
        }
    }

    var icon: String {
        switch self {
        case .compact:     return "rectangle.compress.vertical"
        case .comfortable: return "rectangle.expand.vertical"
        }
    }

    // ── Layout tokens ─────────────────────────────────────────
    var rowVerticalPadding: CGFloat  { self == .compact ? 4 : 6 }
    var rowSpacing: CGFloat          { self == .compact ? 1 : 3 }
    var contentSpacing: CGFloat      { self == .compact ? 1 : 2 }
    var titleSize: CGFloat           { self == .compact ? 11 : 12 }
    var previewSize: CGFloat         { self == .compact ? 10 : 11 }
    var metaSize: CGFloat            { self == .compact ? 9 : 10 }
    var iconSize: CGFloat            { self == .compact ? 11 : 13 }
    var iconFrame: CGFloat           { self == .compact ? 22 : 28 }
    var iconCorner: CGFloat          { self == .compact ? 6 : 8 }
    var thumbSize: CGFloat           { self == .compact ? 26 : 34 }
    var thumbCorner: CGFloat         { self == .compact ? 5 : 7 }
    var showPreview: Bool            { self == .comfortable }
}

// MARK: - App Settings

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: General
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }

            // Push the requested state to SMAppService and record whatever
            // the system actually resolved to (it may reject or require
            // user approval). If the resolved state disagrees with what
            // we just tried to set, snap the @Published property back so
            // the UI stays truthful — guarded against re-entry because
            // reassigning here would fire didSet again.
            let resolved = LoginItemService.apply(launchAtLogin)
            UserDefaults.standard.set(resolved, forKey: "launchAtLogin")
            if resolved != launchAtLogin {
                // Re-entry guard: `launchAtLogin = resolved` would call
                // this didSet again but the `oldValue` compare at the top
                // would see `resolved == oldValue` only if the previous
                // value matched resolved — which is not guaranteed. Dispatch
                // async so the re-assignment happens outside the current
                // didSet stack frame and SwiftUI observes one clean update.
                DispatchQueue.main.async { [weak self] in
                    self?.launchAtLogin = resolved
                }
            }
        }
    }
    @Published var showFloatingButton: Bool {
        didSet { UserDefaults.standard.set(showFloatingButton, forKey: "showFloatingButton") }
    }
    @Published var maxHistoryCount: Int {
        didSet { UserDefaults.standard.set(maxHistoryCount, forKey: "maxHistoryCount") }
    }
    @Published var skipDuplicates: Bool {
        didSet { UserDefaults.standard.set(skipDuplicates, forKey: "skipDuplicates") }
    }
    @Published var captureImages: Bool {
        didSet { UserDefaults.standard.set(captureImages, forKey: "captureImages") }
    }
    /// Capture files copied from Finder (and other apps) into the
    /// clipboard history, copying small ones into LumaClip's vault.
    @Published var captureFiles: Bool {
        didSet { UserDefaults.standard.set(captureFiles, forKey: "captureFiles") }
    }
    /// Files at or below this size (in MB) are copied into the vault;
    /// larger files (and folders) are stored as a reference to the
    /// original path only. Keeps the vault from ballooning.
    @Published var fileVaultMaxMB: Int {
        didSet { UserDefaults.standard.set(fileVaultMaxMB, forKey: "fileVaultMaxMB") }
    }
    @Published var autoCategory: Bool {
        didSet { UserDefaults.standard.set(autoCategory, forKey: "autoCategory") }
    }

    // MARK: Privacy
    @Published var blacklistedApps: [String] {
        didSet {
            let valid = blacklistedApps.filter { !$0.isEmpty }
            UserDefaults.standard.set(valid, forKey: "blacklistedApps")
        }
    }
    @Published var isTrackingPaused: Bool {
        didSet { UserDefaults.standard.set(isTrackingPaused, forKey: "isTrackingPaused") }
    }
    @Published var detectAndSkipPasswords: Bool {
        didSet { UserDefaults.standard.set(detectAndSkipPasswords, forKey: "detectAndSkipPasswords") }
    }

    // MARK: Retention
    @Published var defaultRetentionDays: Int {
        didSet { UserDefaults.standard.set(defaultRetentionDays, forKey: "defaultRetentionDays") }
    }
    @Published var trashRetentionDays: Int {
        didSet { UserDefaults.standard.set(trashRetentionDays, forKey: "trashRetentionDays") }
    }

    // MARK: Appearance
    @Published var floatingButtonOpacity: Double {
        didSet { UserDefaults.standard.set(floatingButtonOpacity, forKey: "floatingButtonOpacity") }
    }
    @Published var floatingButtonSize: Double {
        didSet { UserDefaults.standard.set(floatingButtonSize, forKey: "floatingButtonSize") }
    }
    @Published var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode") }
    }
    @Published var listDensity: ListDensity {
        didSet { UserDefaults.standard.set(listDensity.rawValue, forKey: "listDensity") }
    }

    // MARK: Language
    /// Selected UI language. Persisted, and mirrored into
    /// `LocalizationManager.shared` so localized lookups and live UI
    /// rebuilds stay in sync from a single source of truth.
    @Published var appLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage")
            LocalizationManager.shared.language = appLanguage
        }
    }

    // MARK: Hotkeys — display strings
    @Published var globalToggleHotkey: String {
        didSet { UserDefaults.standard.set(globalToggleHotkey, forKey: "globalToggleHotkey") }
    }
    @Published var quickPasteHotkey: String {
        didSet { UserDefaults.standard.set(quickPasteHotkey, forKey: "quickPasteHotkey") }
    }

    // MARK: Hotkeys — raw Carbon values
    // cmdKey=256, shiftKey=512, optionKey=2048, controlKey=4096
    @Published var toggleHotkeyCode: Int {
        didSet { UserDefaults.standard.set(toggleHotkeyCode, forKey: "toggleHotkeyCode") }
    }
    @Published var toggleHotkeyMods: Int {
        didSet { UserDefaults.standard.set(toggleHotkeyMods, forKey: "toggleHotkeyMods") }
    }
    @Published var quickPasteHotkeyCode: Int {
        didSet { UserDefaults.standard.set(quickPasteHotkeyCode, forKey: "quickPasteHotkeyCode") }
    }
    @Published var quickPasteHotkeyMods: Int {
        didSet { UserDefaults.standard.set(quickPasteHotkeyMods, forKey: "quickPasteHotkeyMods") }
    }

    // MARK: Onboarding
    /// Flips to `true` the first time the user finishes (or skips) the
    /// welcome tour. Persisted to UserDefaults so the tour only auto-shows
    /// once. Settings exposes a "Show Welcome Tour" button that flips this
    /// back to `false` on demand.
    @Published var hasSeenOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasSeenOnboarding, forKey: "hasSeenOnboarding") }
    }

    // MARK: Init

    private init() {
        let ud = UserDefaults.standard
        let cmdShift = 256 + 512  // cmdKey | shiftKey = 768

        ud.register(defaults: [
            "launchAtLogin":         false,
            "showFloatingButton":    true,
            "maxHistoryCount":       5000,
            "skipDuplicates":        false,
            "captureImages":         true,
            "captureFiles":          true,
            "fileVaultMaxMB":        100,
            "autoCategory":          true,
            "blacklistedApps":       [String](),
            "isTrackingPaused":      false,
            "detectAndSkipPasswords": false,
            "defaultRetentionDays":  30,
            "trashRetentionDays":    7,
            "floatingButtonOpacity": 0.9,
            "floatingButtonSize":    48.0,
            "appearanceMode":        AppearanceMode.system.rawValue,
            "listDensity":           ListDensity.comfortable.rawValue,
            "appLanguage":           AppLanguage.english.rawValue,
            "globalToggleHotkey":    "⌘⇧V",
            "quickPasteHotkey":      "⌘⇧P",
            "toggleHotkeyCode":      9,
            "toggleHotkeyMods":      cmdShift,
            "quickPasteHotkeyCode":  35,
            "quickPasteHotkeyMods":  cmdShift,
            "hasSeenOnboarding":     false,
        ])

        // Reconcile stored bool with the system's actual SMAppService
        // registration before exposing the published value — avoids a
        // stale "on" toggle when the user has already disabled the
        // login item in System Settings (or vice versa).
        let storedLaunch = ud.bool(forKey: "launchAtLogin")
        let reconciledLaunch = LoginItemService.reconcile(stored: storedLaunch)
        if reconciledLaunch != storedLaunch {
            ud.set(reconciledLaunch, forKey: "launchAtLogin")
        }
        launchAtLogin          = reconciledLaunch
        showFloatingButton     = ud.bool(forKey: "showFloatingButton")
        maxHistoryCount        = ud.integer(forKey: "maxHistoryCount")
        skipDuplicates         = ud.bool(forKey: "skipDuplicates")
        captureImages          = ud.bool(forKey: "captureImages")
        captureFiles           = ud.bool(forKey: "captureFiles")
        fileVaultMaxMB         = ud.integer(forKey: "fileVaultMaxMB")
        autoCategory           = ud.bool(forKey: "autoCategory")
        isTrackingPaused       = ud.bool(forKey: "isTrackingPaused")
        detectAndSkipPasswords = ud.bool(forKey: "detectAndSkipPasswords")
        defaultRetentionDays   = ud.integer(forKey: "defaultRetentionDays")
        trashRetentionDays     = ud.integer(forKey: "trashRetentionDays")
        floatingButtonOpacity  = ud.double(forKey: "floatingButtonOpacity")
        floatingButtonSize     = ud.double(forKey: "floatingButtonSize")
        globalToggleHotkey     = ud.string(forKey: "globalToggleHotkey") ?? "⌘⇧V"
        quickPasteHotkey       = ud.string(forKey: "quickPasteHotkey")   ?? "⌘⇧P"

        // Hotkey codes & mods: `register(defaults:)` above already provides the
        // fallback when the key has never been written, so `integer(forKey:)` is
        // authoritative. The previous `> 0` guard here clobbered legitimate
        // stored values — keyCode 0 is the `A` key, a perfectly valid binding.
        toggleHotkeyCode     = ud.integer(forKey: "toggleHotkeyCode")
        toggleHotkeyMods     = ud.integer(forKey: "toggleHotkeyMods")
        quickPasteHotkeyCode = ud.integer(forKey: "quickPasteHotkeyCode")
        quickPasteHotkeyMods = ud.integer(forKey: "quickPasteHotkeyMods")
        hasSeenOnboarding    = ud.bool(forKey: "hasSeenOnboarding")

        if let apps = ud.stringArray(forKey: "blacklistedApps") {
            blacklistedApps = apps.filter { !$0.isEmpty }
        } else {
            blacklistedApps = []
        }

        let modeRaw = ud.string(forKey: "appearanceMode") ?? AppearanceMode.system.rawValue
        appearanceMode = AppearanceMode(rawValue: modeRaw) ?? .system

        let densityRaw = ud.string(forKey: "listDensity") ?? ListDensity.comfortable.rawValue
        listDensity = ListDensity(rawValue: densityRaw) ?? .comfortable

        let langRaw = ud.string(forKey: "appLanguage") ?? AppLanguage.english.rawValue
        let resolvedLang = AppLanguage(rawValue: langRaw) ?? .english
        appLanguage = resolvedLang
        // Seed the shared localization manager with the persisted choice
        // so the first render is already in the right language.
        LocalizationManager.shared.language = resolvedLang
    }
}

// MARK: - Localization
//
// Lightweight in-app localization that supports *live* switching without
// an app restart. Keys are the English source strings themselves, so a
// call site reads naturally — `Text("Settings".loc)` — and any string
// without a translation simply falls back to English. Views rebuild on
// language change because each window root observes
// `LocalizationManager.shared` and tags its content with
// `.id(i18n.language)`, forcing the subtree to re-render and re-evaluate
// every `.loc` lookup.

/// Supported UI languages.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh-Hans"   // Simplified Chinese

    var id: String { rawValue }

    /// Name shown in the language switcher, written in its own script.
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }

    var shortLabel: String {
        switch self {
        case .english: return "EN"
        case .chinese: return "中"
        }
    }
}

/// Observable holder for the active language. SwiftUI roots observe this
/// so a change triggers a full re-render of localized text.
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    @Published var language: AppLanguage = .english

    private init() {}

    /// Translate a source (English) string for the active language,
    /// falling back to the original when no translation exists.
    func string(_ key: String) -> String {
        switch language {
        case .english:
            return key
        case .chinese:
            return Localization.zhHans[key] ?? key
        }
    }
}

extension String {
    /// Localized version of this string for the active UI language.
    /// Unknown strings return themselves (English fallback), which makes
    /// wrapping every user-facing literal completely safe.
    var loc: String { LocalizationManager.shared.string(self) }
}

/// Format helper for strings that interpolate values. The template is
/// itself localized first, then `String(format:)` substitutes the
/// arguments — e.g. `L("%d characters", count)`.
func L(_ key: String, _ args: CVarArg...) -> String {
    let template = key.loc
    return String(format: template, arguments: args)
}

/// Translation tables. English is implicit (keys are English), so only
/// the Simplified-Chinese map is stored here.
enum Localization {
    static let zhHans: [String: String] = [
        // ── Brand / version ────────────────────────────────
        "CLIP": "剪贴",

        // ── Nav / sections ─────────────────────────────────
        "Settings": "设置",
        "General": "通用",
        "Privacy": "隐私",
        "Retention": "保留",
        "Appearance": "外观",
        "Data": "数据",
        "Data Management": "数据管理",
        "Shortcuts": "快捷键",
        "Keyboard Shortcuts": "键盘快捷键",
        "Global Shortcuts": "全局快捷键",
        "⌘ Command Shortcuts": "⌘ 命令快捷键",

        // ── Sidebar filters / groups ───────────────────────
        "All": "全部",
        "All Items": "全部项目",
        "All Clips": "全部剪贴",
        "All clips": "全部剪贴",
        "Favorites": "收藏",
        "Recent": "最近",
        "Category": "分类",
        "Trash": "回收站",
        "Bundles": "合集",
        "Pinned": "置顶",
        "Suggested": "建议",
        "CLIPS": "剪贴",
        "COLLECTIONS": "合集",
        "SETTINGS": "设置",
        "STORAGE": "存储",
        "DETAILS": "详情",
        "INSPECTOR": "检查器",
        "DOMAIN": "域名",
        "LENGTH": "长度",
        "QUICK PASTE": "快速粘贴",
        "BUNDLES": "合集",

        // ── Content type labels ────────────────────────────
        "Text": "文本",
        "URL": "网址",
        "Email": "邮箱",
        "Code": "代码",
        "Phone": "电话",
        "Color": "颜色",
        "Image": "图片",
        "Images": "图片",
        "File Path": "文件路径",
        "Unknown": "未知",
        "Links": "链接",

        // ── General settings ───────────────────────────────
        "Launch at Login": "登录时启动",
        "Launch at login": "登录时启动",
        "Show Floating Button": "显示悬浮按钮",
        "Max History Items": "最大历史数量",
        "Skip Duplicates": "跳过重复项",
        "Capture Images": "捕获图片",
        "Capture Files": "捕获文件",
        "Save files copied from Finder so you can re-paste them anytime": "保存从访达复制的文件，随时可再次粘贴",
        "Save Files Up To": "保存文件上限",
        "Files at or below this size are copied into LumaClip; larger files are linked to their original location.": "不超过该大小的文件会复制进 LumaClip；更大的文件仅链接到原始位置。",
        "File": "文件",
        "Files": "文件",
        "files": "个文件",
        "Saved": "已保存",
        "Linked": "已链接",
        "These files are linked to their original location. If the originals move or are deleted, they can no longer be pasted.": "这些文件仅链接到原始位置。如果原文件被移动或删除，将无法再粘贴。",
        "Auto Category": "自动分类",

        // ── Privacy ────────────────────────────────────────
        "Blacklisted Apps": "黑名单应用",
        "Running Apps": "运行中的应用",
        "Detect & Skip Passwords": "检测并跳过密码",
        "App name": "应用名称",
        "Clipboard content from these apps won't be saved": "这些应用的剪贴板内容将不会被保存",

        // ── Retention ──────────────────────────────────────
        "Retention Rules": "保留规则",
        "Default Retention": "默认保留",
        "Trash Auto-Cleanup": "回收站自动清理",
        "Custom Rules": "自定义规则",
        "Add Rule": "添加规则",
        "Keep for": "保留时长",
        "Apply to": "应用于",
        "Expiry": "到期",
        "Expires": "到期",
        "No Expiry": "永不过期",
        "Limit": "上限",
        "All Items ": "全部项目",
        "App": "应用",

        // ── Appearance ─────────────────────────────────────
        "Colour Mode": "颜色模式",
        "Color Preview": "颜色预览",
        "Controls whether LumaClip uses a light or dark glass theme.": "控制 LumaClip 使用浅色或深色玻璃主题。",
        "System": "跟随系统",
        "Light": "浅色",
        "Dark": "深色",
        "Compact": "紧凑",
        "Comfortable": "舒适",
        "Floating Button Opacity": "悬浮按钮不透明度",
        "Floating Button Size": "悬浮按钮大小",
        "Language": "语言",

        // ── Data ───────────────────────────────────────────
        "Back Up Data": "备份数据",
        "Back Up LumaClip Data": "备份 LumaClip 数据",
        "Backup & Restore": "备份与恢复",
        "Restore": "恢复",
        "Restore from Backup": "从备份恢复",
        "Restore LumaClip Backup": "恢复 LumaClip 备份",
        "Run Cleanup Now": "立即清理",
        "Empty Trash": "清空回收站",
        "Clear All History": "清除所有历史",
        "Reset Everything": "重置全部",
        "Danger Zone": "危险区域",
        "Total Clips": "剪贴总数",
        "Statistics": "统计",
        "Wipe all data and restore factory defaults": "清除所有数据并恢复出厂设置",
        "Backup saved to %@": "备份已保存到 %@",
        "Backup failed: %@": "备份失败：%@",
        "Restore failed: %@": "恢复失败：%@",
        "DB, journal, and image data.": "数据库、日志和图片数据。",

        // ── Onboarding / welcome ───────────────────────────
        "Welcome Tour": "欢迎导览",
        "Show Welcome Tour": "显示欢迎导览",
        "Skip": "跳过",
        "Skip the tour (Esc)": "跳过导览（Esc）",
        "Back": "返回",
        "Next": "下一步",
        "Replay the first-launch tour — useful after a major update or to refresh your memory on shortcuts.": "重新播放首次启动导览——在重大更新后或想温习快捷键时很有用。",
        "Welcome to ": "欢迎使用 ",
        "Master the ": "掌握",
        "Make it ": "让它",
        "Everything you copy, ": "你复制的一切，",
        "Find anything in ": "在毫秒间查找",
        "Bundles for ": "合集，适用于",
        "kept": "全部留存",
        "keyboard": "键盘",
        "repeat workflows": "重复工作流",
        "milliseconds": "一切",
        "yours": "专属于你",
        "Your clipboard, supercharged. Every copy you make stays one keystroke away — without you having to think about it.": "你的剪贴板，全面强化。每一次复制都触手可及——无需你费心。",
        "Text, images, links, and code — silently captured the moment you press ⌘C. Auto-classified, searchable, and never leaves your Mac.": "文本、图片、链接和代码——在你按下 ⌘C 的瞬间静默捕获。自动分类、可搜索，且永不离开你的 Mac。",
        "Finder-style column navigation. Arrows move focus across sidebar, list, and inspector — without lifting your hands.": "访达式分栏导航。方向键在侧栏、列表与检查器之间移动焦点——双手无需离开键盘。",
        "Group related clips into a Bundle, then paste them in order with one keystroke. Forms, drafts, boilerplate — solved.": "把相关剪贴归入一个合集，然后用一个按键按顺序粘贴。表单、草稿、样板文字——全部搞定。",
        "Type to filter, or use tokens like type:url and after:today to narrow down to the exact clip you remember.": "输入即可筛选，或使用 type:url、after:today 等标记，精确定位你记得的那条剪贴。",
        "Retention windows, theme, and global hotkeys — every default is a starting point. Tune them in Settings.": "保留时长、主题与全局快捷键——每一项默认设置都只是起点。在“设置”中随心调整。",

        // ── Menu bar ───────────────────────────────────────
        "Show Clipboard": "显示剪贴板",
        "Manage Bundles…": "管理合集…",
        "Pause Tracking": "暂停记录",
        "Resume Tracking": "恢复记录",
        "Toggle Floating Button": "切换悬浮按钮",
        "Quit LumaClip": "退出 LumaClip",
        "No bundles yet": "暂无合集",

        // ── Common actions ─────────────────────────────────
        "Copy": "复制",
        "Copied": "已复制",
        "Copied to clipboard": "已复制到剪贴板",
        "Copy & Dismiss": "复制并关闭",
        "Copy & paste": "复制并粘贴",
        "Paste": "粘贴",
        "Delete": "删除",
        "Delete All": "全部删除",
        "Delete Permanently": "永久删除",
        "Delete Category": "删除分类",
        "Delete all items permanently?": "永久删除所有项目？",
        "Cancel": "取消",
        "Save": "保存",
        "Edit": "编辑",
        "Edit Clip": "编辑剪贴",
        "Edit Category": "编辑分类",
        "Edit content": "编辑内容",
        "Open": "打开",
        "Open in Browser": "在浏览器中打开",
        "Open in browser": "在浏览器中打开",
        "Reveal in Finder": "在访达中显示",
        "Move to Trash": "移到回收站",
        "Add to Bundle": "添加到合集",
        "Add to Paste Queue": "添加到粘贴队列",
        "Remove from Paste Queue": "从粘贴队列移除",
        "Set Category": "设置分类",
        "Set Expiry": "设置到期",
        "Quick Look": "快速查看",
        "Inspect": "检查",
        "More": "更多",
        "More actions": "更多操作",
        "Actions": "操作",
        "Activate": "激活",
        "Deselect": "取消选择",
        "Deselect All": "取消全选",
        "Yes, delete": "确认删除",
        "Yes": "是",
        "No": "否",
        "None": "无",
        "Compose": "撰写",
        "Compose email (falls back to copying address)": "撰写邮件（否则复制地址）",
        "Copy Domain": "复制域名",
        "Copy Username": "复制用户名",
        "Copy as Markdown Link": "复制为 Markdown 链接",
        "Copy as rgb()": "复制为 rgb()",
        "Copy HSL": "复制 HSL",
        "Copy RGB": "复制 RGB",
        "Generate QR Code": "生成二维码",

        // ── Bundles ────────────────────────────────────────
        "New Bundle": "新建合集",
        "No Bundles": "暂无合集",
        "Create your first bundle": "创建你的第一个合集",
        "A bundle is a small playlist of clips you can paste in sequence — useful for repeated workflows like onboarding emails or fixed code snippets.": "合集是一个可按顺序粘贴的剪贴小清单——适用于重复性工作流，例如入职邮件或固定代码片段。",
        "Sequenced clipboard items, pasted one after another.": "按顺序排列的剪贴项，逐一粘贴。",
        "Cancel bundle session": "取消合集会话",
        "Step %d of %d — paste now, then Next": "第 %d / %d 步——现在粘贴，然后点下一步",
        "Paste Next": "粘贴下一个",
        "Copy next clip and advance": "复制下一个剪贴并前进",
        "Clear Queue": "清空队列",
        "Drag clips here": "将剪贴拖到此处",
        "Paste next queued clip (⌘V in target app to drop it in). Right-click to clear.": "粘贴下一个排队剪贴（在目标应用按 ⌘V 放入）。右键点击可清空。",

        // ── Detail / inspector ─────────────────────────────
        "Preview": "预览",
        "Content": "内容",
        "Source": "来源",
        "Transform": "转换",
        "Quick Transforms": "快速转换",
        "Encoding": "编码",
        "Word Count": "字数",
        "Line Count": "行数",
        "Lines": "行",
        "No clip selected": "未选择剪贴",
        "Click a clip to preview its contents": "点击剪贴以预览其内容",
        "No clipboard items available": "暂无剪贴板项目",
        "No matches": "无匹配",
        "No categories yet": "暂无分类",
        "Unable to render image": "无法渲染图片",
        "Cannot parse color": "无法解析颜色",
        "Detail Drawer": "详情抽屉",
        "Icon": "图标",
        "Name": "名称",
        "New category": "新建分类",

        // ── Quick transforms ───────────────────────────────
        "UPPER": "大写",
        "Title Case": "标题大小写",
        "Trim": "修剪",
        "Case": "大小写",
        "Dashes": "连字符",
        "Dots": "点",
        "Digits Only": "仅数字",
        "Dial": "拨号",
        "Intl (+1)": "国际 (+1)",
        "Format JSON": "格式化 JSON",
        "Minify JSON": "压缩 JSON",
        "Base64 Enc": "Base64 编码",
        "Base64 Dec": "Base64 解码",
        "URL Encode": "URL 编码",
        "URL Decode": "URL 解码",
        "Remove Breaks": "移除换行",
        "Remove Comments": "移除注释",
        "Whitespace": "空白",
        "Normalize": "规范化",
        "Invert": "反转",
        "Scheme Only": "仅协议",
        "Strip Params": "去除参数",

        // ── Search / command palette ───────────────────────
        "Command palette": "命令面板",
        "Query": "查询",
        "Navigate": "导航",
        "Navigation": "导航",
        "Record": "录制",
        "Press shortcut…": "按下快捷键…",
        "TRY A DIFFERENT QUERY": "尝试其他查询",
        "Clear search": "清除搜索",
        "Clear all filters": "清除所有筛选",
        "Switch column": "切换栏",
        "Move within": "在内移动",
        "Quick Paste": "快速粘贴",
        "Quick Paste hotkey": "快速粘贴快捷键",
        "Toggle Clipboard Panel": "切换剪贴板面板",
        "Configure global shortcuts in the General section.": "在“通用”部分配置全局快捷键。",

        // ── Status labels ──────────────────────────────────
        "LIVE": "实时",
        "OPEN": "打开",
        "Captured silently": "已静默捕获",
        "Sensitive content detected": "检测到敏感内容",
        "Burns after next paste": "粘贴后即焚",
        "In Trash": "在回收站",
        "now": "刚刚",
        "queued": "已排队",
        "synced": "已同步",
        "clips": "条剪贴",
        "chars": "字符",
        "characters": "字符",

        // ── Undo action names ──────────────────────────────
        "Pin": "置顶",
        "Favorite": "收藏",
        "Move to Category": "移动到分类",
    ]
}
