// GlobalHotkey.swift
// LumaClip - macOS Clipboard Manager
//
// Registers a global keyboard shortcut (⌘⇧V) to toggle
// the main clipboard panel from anywhere in macOS.
// Uses Carbon Events API for system-wide hotkey registration.

import Foundation
import Carbon
import AppKit

// MARK: - Global Hotkey Manager

final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var hotkeyRef:      EventHotKeyRef?
    private var quickPasteRef:  EventHotKeyRef?
    private var onToggle:       (() -> Void)?
    private var onQuickPaste:   (() -> Void)?
    private var handlerInstalled = false
    /// Carbon handler ref returned by `InstallEventHandler` — retained so we can
    /// call `RemoveEventHandler` in `unregister()` / `deinit` and avoid leaking
    /// a stale event handler across hot-key re-registrations.
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    // MARK: - Main panel hotkey (default ⌘⇧V, keyCode 9)

    func register(keyCode: UInt32 = 9, modifiers: UInt32 = UInt32(cmdKey | shiftKey),
                  action: @escaping () -> Void) {
        self.onToggle = action
        installHandlerIfNeeded()
        let hotkeyID = EventHotKeyID(signature: OSType(0x4C4D4350), id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotkeyID,
                            GetApplicationEventTarget(), 0, &hotkeyRef)
    }

    func reRegisterToggle(keyCode: UInt32, modifiers: UInt32) {
        if let ref = hotkeyRef { UnregisterEventHotKey(ref); hotkeyRef = nil }
        let hotkeyID = EventHotKeyID(signature: OSType(0x4C4D4350), id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotkeyID,
                            GetApplicationEventTarget(), 0, &hotkeyRef)
    }

    // MARK: - Quick Paste hotkey (default ⌘⇧P, keyCode 35)

    func registerQuickPaste(keyCode: UInt32 = 35, modifiers: UInt32 = UInt32(cmdKey | shiftKey),
                            action: @escaping () -> Void) {
        self.onQuickPaste = action
        installHandlerIfNeeded()
        let hotkeyID = EventHotKeyID(signature: OSType(0x4C4D4350), id: 2)
        RegisterEventHotKey(keyCode, modifiers, hotkeyID,
                            GetApplicationEventTarget(), 0, &quickPasteRef)
    }

    func reRegisterQuickPaste(keyCode: UInt32, modifiers: UInt32) {
        if let ref = quickPasteRef { UnregisterEventHotKey(ref); quickPasteRef = nil }
        let hotkeyID = EventHotKeyID(signature: OSType(0x4C4D4350), id: 2)
        RegisterEventHotKey(keyCode, modifiers, hotkeyID,
                            GetApplicationEventTarget(), 0, &quickPasteRef)
    }

    // MARK: - Shared Carbon handler

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind:  UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                var hkID = EventHotKeyID()
                GetEventParameter(event,
                                  EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID),
                                  nil,
                                  MemoryLayout<EventHotKeyID>.size,
                                  nil,
                                  &hkID)
                switch hkID.id {
                case 1: GlobalHotkeyManager.shared.onToggle?()
                case 2: GlobalHotkeyManager.shared.onQuickPaste?()
                default: break
                }
                return noErr
            },
            1, &eventType, nil, &eventHandlerRef
        )
    }

    // MARK: - Unregister

    func unregister() {
        if let ref = hotkeyRef      { UnregisterEventHotKey(ref); hotkeyRef = nil }
        if let ref = quickPasteRef  { UnregisterEventHotKey(ref); quickPasteRef = nil }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
            handlerInstalled = false
        }
        onToggle     = nil
        onQuickPaste = nil
    }

    deinit { unregister() }
}
