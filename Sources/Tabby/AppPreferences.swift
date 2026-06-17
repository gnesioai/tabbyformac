import Foundation
import AppKit
import ServiceManagement
import Carbon

enum ShortcutPreset: String, CaseIterable, Identifiable {
    case optionTab = "Option + Tab"
    case controlTab = "Control + Tab"
    case cmdTab = "Command + Tab"
    case cmdOptionTab = "Command + Option + Tab"
    
    var id: String { self.rawValue }
    
    var keyCode: UInt32 {
        return 48 // Always Tab!
    }
    
    var modifiers: UInt32 {
        switch self {
        case .optionTab: return UInt32(optionKey)
        case .controlTab: return UInt32(controlKey)
        case .cmdTab: return UInt32(cmdKey)
        case .cmdOptionTab: return UInt32(cmdKey | optionKey)
        }
    }

    /// Returns true if the hotkey's modifier key(s) are currently held in the given NSEvent flags.
    func isModifierPressed(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .optionTab:    return flags.contains(.option)
        case .controlTab:   return flags.contains(.control)
        case .cmdTab:       return flags.contains(.command)
        case .cmdOptionTab: return flags.contains(.command) && flags.contains(.option)
        }
    }

    /// Returns true if the hotkey's modifier key(s) have been released.
    func isModifierReleased(_ flags: NSEvent.ModifierFlags) -> Bool {
        return !isModifierPressed(flags)
    }
}

class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    
    private let presetKey = "STShortcutPreset"
    private let showInDockKey = "STShowInDock"
    private let launchAtLoginKey = "STLaunchAtLogin"
    
    @Published var shortcutPreset: ShortcutPreset {
        didSet {
            UserDefaults.standard.set(shortcutPreset.rawValue, forKey: presetKey)
            NotificationCenter.default.post(name: .didUpdateShortcut, object: nil)
        }
    }
    
    @Published var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: showInDockKey)
            updateDockState()
        }
    }
    
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: launchAtLoginKey)
            updateLaunchAtLoginState()
        }
    }
    
    private init() {
        // Load default or saved values
        let savedPresetRaw = UserDefaults.standard.string(forKey: presetKey) ?? ShortcutPreset.optionTab.rawValue
        self.shortcutPreset = ShortcutPreset(rawValue: savedPresetRaw) ?? .optionTab
        
        self.showInDock = UserDefaults.standard.object(forKey: showInDockKey) as? Bool ?? false
        self.launchAtLogin = UserDefaults.standard.object(forKey: launchAtLoginKey) as? Bool ?? false
    }
    
    /// Updates Dock visibility policy based on preferences
    func updateDockState() {
        let apply = {
            if self.showInDock {
                NSApp.setActivationPolicy(.regular)
            } else {
                NSApp.setActivationPolicy(.accessory)
            }
            NotificationCenter.default.post(name: .didUpdateDockState, object: nil)
        }
        
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
    
    /// Configures the launch service via ServiceManagement SMAppService
    private func updateLaunchAtLoginState() {
        let service = SMAppService.mainApp
        
        if launchAtLogin {
            if service.status == .enabled { return }
            do {
                try service.register()
                print("Tabby: Successfully enabled launch at login")
            } catch {
                print("Tabby: Failed to enable launch at login: \(error.localizedDescription)")
            }
        } else {
            if service.status == .notRegistered { return }
            do {
                try service.unregister()
                print("Tabby: Successfully disabled launch at login")
            } catch {
                print("Tabby: Failed to disable launch at login: \(error.localizedDescription)")
            }
        }
    }
}

extension Notification.Name {
    static let didUpdateShortcut = Notification.Name("STDidUpdateShortcutNotification")
    static let didUpdateDockState = Notification.Name("STDidUpdateDockStateNotification")
    static let cmdTabTapFailed = Notification.Name("STCmdTabTapFailedNotification")
    static let browserAutomationDenied = Notification.Name("STBrowserAutomationDeniedNotification")
}
