import Foundation
import AppKit
import SwiftUI
import Carbon
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem?
    var switcherWindow: SwitcherWindow?
    var preferencesWindow: NSWindow?
    let state = SwitcherState()
    // Sparkle auto-updater. Starts checking on launch per Info.plist (SUEnableAutomaticChecks).
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Initialize the overlay window
        let window = SwitcherWindow(state: state)
        self.switcherWindow = window
        
        // 2. Initialize Dock active policy
        AppPreferences.shared.updateDockState()
        
        // 3. Create status bar item
        createStatusItem()
        
        // 4. Register global hotkey
        registerShortcut()
        
        // 5. Watch for shortcut updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShortcutUpdate),
            name: .didUpdateShortcut,
            object: nil
        )
        
        // Watch for Dock state updates (which require status item recreation)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDockStateUpdate),
            name: .didUpdateDockState,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCmdTabTapFailed),
            name: .cmdTabTapFailed,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBrowserAutomationDenied(_:)),
            name: .browserAutomationDenied,
            object: nil
        )

        // 6. Initial permission check
        state.refreshWindows()
        
        // 7. Show Preferences on launch if permissions are missing
        if !state.hasPermission || !state.hasScreenRecording {
            showPreferencesWindow()
        }
    }
    
    @objc private func handleCmdTabTapFailed() {
        showPreferencesWindow()
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "Tabby needs Accessibility access to intercept Command+Tab. Please grant it in System Settings → Privacy & Security → Accessibility, then relaunch Tabby."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    @objc private func handleBrowserAutomationDenied(_ note: Notification) {
        let browser = (note.userInfo?["browser"] as? String) ?? "this browser"
        let alert = NSAlert()
        alert.messageText = "Allow Tabby to read \(browser)'s tabs"
        alert.informativeText = "Tabby needs Automation permission to list and switch \(browser) tabs. Enable Tabby under \(browser) in System Settings → Privacy & Security → Automation, then reopen the switcher."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Automation Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregister()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        toggleSwitcher()
        return true
    }
    
    /// Registers the global shortcut based on current preferences
    private func registerShortcut() {
        let preset = AppPreferences.shared.shortcutPreset
        
        HotKeyManager.shared.isWindowVisible = { [weak self] in
            return self?.switcherWindow?.isVisible ?? false
        }
        
        HotKeyManager.shared.onTildeTriggered = { [weak self] in
            guard let self = self else { return }
            // Tilde toggles expansion of a multi-window group, or a browser whose tabs we can't
            // read yet (expandGroup then requests Automation permission).
            let groupIndex = self.state.selectedGroupIndex
            guard groupIndex < self.state.groups.count else { return }
            let group = self.state.groups[groupIndex]
            let bundleId = group.appBundleId ?? ""
            let isBrowser = WindowManager.shared.isBrowser(bundleId: bundleId)
            let hasPermission = isBrowser ? WindowManager.shared.checkAutomationPermission(bundleIdentifier: bundleId, prompt: false) : true
            guard group.windows.count > 1 || (isBrowser && !hasPermission) else { return }

            if self.state.expandedGroupIds.contains(group.id) {
                self.state.collapseGroup()
            } else {
                self.state.expandGroup()
            }
        }
        
        let success = HotKeyManager.shared.register(
            keyCode: preset.keyCode,
            modifiers: preset.modifiers
        ) { [weak self] isShiftPressed in
            self?.toggleSwitcher(isShiftPressed: isShiftPressed, viaHotkey: true)
        }
        
        if !success {
            print("Tabby: Failed to register hotkey: \(preset.rawValue)")
        }
    }
    
    @objc private func handleShortcutUpdate() {
        registerShortcut()
    }
    
    @objc private func handleDockStateUpdate() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("Tabby: Recreating status bar item due to dock state update")
            self.createStatusItem()
        }
    }
    
    /// Create the menu bar item
    private func createStatusItem() {
        // ponytail: never recreate — destroying and rebuilding the NSStatusItem on
        // dock-state changes is what drops the icon. Keep the one we have.
        guard statusItem == nil else { return }

        // Force the status item to have a strict square length so it cannot be collapsed to 0 width
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.isVisible = true
        statusItem?.autosaveName = "TabbyMenuIcon"
        
        guard let button = statusItem?.button else { return }
        
        if let img = NSImage(systemSymbolName: "square.3.layers.3d.down.forward", accessibilityDescription: "Tabby") {
            img.isTemplate = true
            button.image = img
        }
        button.toolTip = "Tabby - Grouped Window Switcher"
        
        // Menu layout
        let menu = NSMenu()
        
        let headerItem = NSMenuItem(title: "Tabby v1.0", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(withTitle: "Toggle Switcher", action: #selector(menuToggleSwitcher), keyEquivalent: "")
        
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(withTitle: "Preferences...", action: #selector(menuShowPreferences), keyEquivalent: ",")

        menu.addItem(withTitle: "Check for Updates…", action: #selector(menuCheckForUpdates), keyEquivalent: "")

        menu.addItem(NSMenuItem.separator())

        menu.addItem(withTitle: "Quit Tabby", action: #selector(menuQuit), keyEquivalent: "q")
        
        statusItem?.menu = menu
    }
    
    // MARK: - Menu Bar Actions
    
    @objc func menuToggleSwitcher() {
        toggleSwitcher()
    }
    
    @objc func menuShowPreferences() {
        showPreferencesWindow()
    }
    
    @objc func menuCheckForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    @objc func menuQuit() {
        NSApp.terminate(nil)
    }
    
    // MARK: - Toggle Switcher
    
    func toggleSwitcher(isShiftPressed: Bool = false, viaHotkey: Bool = false) {
        // If accessibility isn't ready, show preferences instead
        if !state.hasPermission {
            showPreferencesWindow()
            return
        }

        guard let window = switcherWindow else { return }

        if window.isVisible {
            if isShiftPressed {
                state.moveSelectionUp()
            } else {
                state.moveSelectionDown()
            }
        } else {
            state.refreshWindows(preserveSelection: false)
            window.centerOnActiveScreen()
            // Arm hold-to-focus only when opened via the hotkey; menu-opened stays persistent.
            window.startTrackingModifiers(armed: viaHotkey)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
    
    // MARK: - Preferences Window
    
    func showPreferencesWindow() {
        if let window = preferencesWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let prefsView = PreferencesView(state: state)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Tabby Preferences"
        window.contentView = NSHostingView(rootView: prefsView)
        window.center()
        window.isReleasedWhenClosed = false
        
        window.delegate = self
        
        self.preferencesWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - NSWindowDelegate
    
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window == preferencesWindow {
                preferencesWindow = nil
            }
        }
    }
}
