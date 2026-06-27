// LoginItemService.swift
// LumaClip - macOS Clipboard Manager
//
// Bridges the user-facing `AppSettings.launchAtLogin` toggle to the
// platform primitive. macOS 13+ gates "launch at login" through
// `SMAppService.mainApp` — the legacy `LSSharedFileList` / helper-app
// approach is deprecated. Without this service the settings toggle
// is purely cosmetic: it flips a `UserDefaults` bool that the system
// never reads.

import Foundation
import ServiceManagement

// MARK: - Login Item Service

/// Thin wrapper around `SMAppService.mainApp` that exposes a
/// synchronous `apply(_:)` API and reconciles any drift between the
/// UserDefaults flag and the system's registration state.
enum LoginItemService {

    /// True if the current binary is registered to launch at login.
    ///
    /// `SMAppService.Status` also distinguishes `.requiresApproval` and
    /// `.notFound`; we collapse those to `false` here because from the
    /// user's perspective the toggle should read "off" until macOS
    /// actually agrees to start the app.
    static var isEnabled: Bool {
        return SMAppService.mainApp.status == .enabled
    }

    /// Apply a desired state to the system.
    ///
    /// Returns the *resolved* state after the call — callers should
    /// compare against what they requested. On `.requiresApproval`
    /// macOS has accepted the registration but the user still needs
    /// to flip a switch in System Settings → General → Login Items.
    @discardableResult
    static func apply(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp

        do {
            if enabled {
                // Register(). Idempotent when already registered.
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                // Unregister(). Idempotent when already absent.
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            // Don't surface the raw error through a crashing precondition —
            // a user might revoke approval in System Settings while the app
            // is running and we'd be unable to re-register. Log and fall
            // through; the caller will see the flipped-back UI state.
            print("[LoginItemService] apply(\(enabled)) failed: \(error)")
        }

        return isEnabled
    }

    /// Called once at startup from AppSettings to reconcile any drift
    /// between the stored user-preference bool and what the system
    /// actually has registered.
    ///
    /// Two cases to fix:
    ///  - User toggled the setting OFF while the app was running as a
    ///    background launch item on a prior boot → bool says false but
    ///    the service is still registered. Unregister now.
    ///  - User disabled the login item directly in System Settings →
    ///    bool says true but the service is no longer registered. We
    ///    respect the system's choice and sync the bool back to false.
    ///
    /// Returns the reconciled bool the caller should write back into
    /// `UserDefaults`.
    static func reconcile(stored: Bool) -> Bool {
        let systemEnabled = isEnabled
        if stored == systemEnabled { return stored }

        if stored {
            // Settings wants it on; try to register.
            return apply(true)
        } else {
            // Settings wants it off; tear down any stale registration.
            return apply(false)
        }
    }
}
