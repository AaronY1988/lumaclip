// swift-tools-version:5.9
// Package.swift
// LumaClip - macOS Clipboard Manager

import PackageDescription

let package = Package(
    name: "LumaClip",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "LumaClip",
            path: "LumaClip",
            sources: [
                "App/LumaClipApp.swift",
                "App/AppDelegate.swift",
                "Models/ClipboardItem.swift",
                "Models/Category.swift",
                "Models/RetentionRule.swift",
                "Models/AppSettings.swift",
                "ViewModels/ClipboardViewModel.swift",
                "ViewModels/SettingsViewModel.swift",
                "Views/FloatingButtonWindow.swift",
                "Views/MainPanelWindow.swift",
                "Views/MainPanelView.swift",
                "Views/SidebarView.swift",
                "Views/ClipboardListView.swift",
                "Views/DetailPanelView.swift",
                "Views/SettingsView.swift",
                "Views/OnboardingView.swift",
                "Components/DesignSystem.swift",
                "Services/ClipboardService.swift",
                "Services/FileVaultService.swift",
                "Services/SearchService.swift",
                "Services/RetentionService.swift",
                "Services/PrivacyService.swift",
                "Database/DatabaseService.swift",
                "Utils/ContentClassifier.swift",
                "Utils/GlobalHotkey.swift",
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
