import Foundation
import AppKit
import SwiftUI

class SwitcherWindow: NSPanel {
    let state: SwitcherState
    private var hostingView: NSHostingView<SwitcherView>?

    /// Switcher size scaled to the screen: ~42% width / ~62% height, clamped so it stays usable
    /// on small displays and doesn't sprawl on large ones.
    private static func preferredSize(for screen: NSScreen) -> NSSize {
        let vf = screen.visibleFrame
        let w = min(max((vf.width * 0.42).rounded(), 800), 1400)
        let h = min(max((vf.height * 0.62).rounded(), 480), 900)
        return NSSize(width: w, height: h)
    }

    init(state: SwitcherState) {
        self.state = state
        
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        self.isFloatingPanel = true
        self.acceptsMouseMovedEvents = true
        // Set window to highest possible overlay level to never be trapped behind full-screen apps
        self.level = NSWindow.Level(Int(CGWindowLevelForKey(.maximumWindow)))
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hidesOnDeactivate = true
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.backgroundColor = .clear
        self.isMovable = false
        self.hasShadow = true
        
        // Wrap SwiftUI view (size set per-screen in centerOnActiveScreen)
        let hostingView = NSHostingView(rootView: SwitcherView(state: state))
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 480)
        self.hostingView = hostingView
        self.contentView = hostingView
        
        // Listen for resign key to close window automatically
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: self
        )
    }
    
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return true
    }
    
    @objc private func windowDidResignKey(_ notification: Notification) {
        // Close overlay if user clicks outside
        self.orderOut(nil)
    }
    
    /// Centers the window on the active screen (slightly above absolute center for better balance)
    func centerOnActiveScreen() {
        // Position on the screen with mouse cursor
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else {
            return
        }
        
        let screenFrame = screen.visibleFrame
        let size = SwitcherWindow.preferredSize(for: screen)
        let wWidth = size.width
        let wHeight = size.height

        // Resize the SwiftUI content to match this screen.
        hostingView?.rootView = SwitcherView(state: state, width: wWidth, height: wHeight)
        hostingView?.frame = NSRect(x: 0, y: 0, width: wWidth, height: wHeight)

        let x = screenFrame.origin.x + (screenFrame.width - wWidth) / 2
        let y = screenFrame.origin.y + (screenFrame.height - wHeight) / 2 + 80

        self.setFrame(NSRect(x: x, y: y, width: wWidth, height: wHeight), display: true)
    }
    
    private var isTrackingModifiers = false
    private var localFlagsMonitor: Any?
    private var globalFlagsMonitor: Any?

    /// Arms "hold-to-preview, release-to-focus" tracking (native Cmd+Tab behavior).
    /// - Parameter armed: pass `true` when opened via the global hotkey. The hotkey inherently
    ///   required the modifier to be held, so we arm unconditionally rather than sampling the
    ///   instantaneous modifier state — which can already read as released on a fast tap.
    ///   Pass `false` when opened from the menu so the switcher stays open for browsing.
    func startTrackingModifiers(armed: Bool) {
        teardownFlagsMonitors()
        isTrackingModifiers = armed
        guard armed else { return }

        // Watch modifier release via event monitors, which fire regardless of whether this
        // panel is the key window yet — fixing the race where a fast release is missed.
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event.modifierFlags)
            return event
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event.modifierFlags)
        }

        // Fast-tap case: the modifier was already released before the panel could observe it.
        // Defer so the window is fully presented before we focus and dismiss.
        if AppPreferences.shared.shortcutPreset.isModifierReleased(NSEvent.modifierFlags) {
            DispatchQueue.main.async { [weak self] in self?.modifierReleased() }
        }
    }

    private func handleFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        guard isTrackingModifiers else { return }
        if AppPreferences.shared.shortcutPreset.isModifierReleased(flags) {
            modifierReleased()
        }
    }

    private func modifierReleased() {
        guard isTrackingModifiers else { return }
        isTrackingModifiers = false
        teardownFlagsMonitors()
        _ = state.selectAndFocus()
        self.orderOut(nil)
    }

    private func teardownFlagsMonitors() {
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m); localFlagsMonitor = nil }
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m); globalFlagsMonitor = nil }
    }

    override func orderOut(_ sender: Any?) {
        isTrackingModifiers = false
        teardownFlagsMonitors()
        super.orderOut(sender)
    }

    /// Stops hold-to-focus so the switcher stays open after the modifier is released.
    /// Used when the user starts typing a search query while still holding the hotkey.
    private func disarmModifierTracking() {
        isTrackingModifiers = false
        teardownFlagsMonitors()
    }
    
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let keyCode = event.keyCode
            let presetKeyCode = UInt16(AppPreferences.shared.shortcutPreset.keyCode)
            
            // Intercept key events before text field editor eats them
            var navigationKeys: Set<UInt16> = [
                125, // Down Arrow
                126, // Up Arrow
                124, // Right Arrow
                123, // Left Arrow
                36,  // Enter
                53,  // Escape
                48,  // Tab
                presetKeyCode
            ]
            
            // Allow Backspace to close windows only if we are not typing a search query
            if state.searchQuery.isEmpty {
                navigationKeys.insert(51)  // Backspace
                navigationKeys.insert(117) // Forward Delete
            }
            
            // Intercept Tilde (keycode 50 or keycode 10 for ISO)
            if keyCode == 50 || keyCode == 10 {
                let flags = event.modifierFlags
                let preset = AppPreferences.shared.shortcutPreset
                if preset.isModifierPressed(flags) || state.searchQuery.isEmpty {
                    navigationKeys.insert(keyCode)
                }
            }
            
            if navigationKeys.contains(keyCode) {
                self.keyDown(with: event)
                return
            }
            
            // Intercept <modifier>+W to close — Command, or the chosen trigger modifier
            // (Option/Control) which is what's actually held in hold-to-switch mode.
            if keyCode == 13 && (event.modifierFlags.contains(.command) || AppPreferences.shared.shortcutPreset.isModifierPressed(event.modifierFlags)) {
                self.keyDown(with: event)
                return
            }

            // Cmd+, opens Preferences — escape hatch when the menu bar icon is missing
            if keyCode == 43 && event.modifierFlags.contains(.command) {
                self.keyDown(with: event)
                return
            }

            // Type-to-search: if a printable character is pressed while the hotkey modifier is
            // still held (quick-switch / hold mode), disarm hold-to-focus so the switcher stays
            // open, and feed the BASE character into the search field (charactersIgnoringModifiers
            // gives "s" even for ⌥-s / ⌘-s). Once the modifier is released, normal TextField
            // typing takes over.
            let preset = AppPreferences.shared.shortcutPreset
            if preset.isModifierPressed(event.modifierFlags),
               let chars = event.charactersIgnoringModifiers, chars.count == 1,
               let scalar = chars.unicodeScalars.first,
               CharacterSet.alphanumerics.union(.whitespaces).contains(scalar) {
                disarmModifierTracking()
                state.updateQuery(state.searchQuery + chars)
                return
            }
        }
        super.sendEvent(event)
    }
    
    override func keyDown(with event: NSEvent) {
        let keyCode = event.keyCode
        let presetKeyCode = UInt16(AppPreferences.shared.shortcutPreset.keyCode)
        
        if keyCode == 48 || keyCode == presetKeyCode {
            if event.modifierFlags.contains(.shift) {
                state.moveSelectionUp()
            } else {
                state.moveSelectionDown()
            }
            return
        }
        
        switch keyCode {
        case 53: // Escape
            self.orderOut(nil)
            
        case 36: // Enter
            _ = state.selectAndFocus()
            self.orderOut(nil)
            
        case 125: // Down Arrow
            state.moveSelectionDown()
            
        case 126: // Up Arrow
            state.moveSelectionUp()
            
        case 124: // Right Arrow
            guard state.searchQuery.isEmpty else { break }
            state.expandGroup()

        case 123: // Left Arrow
            guard state.searchQuery.isEmpty else { break }
            state.collapseGroup()
            
        case 50, 10: // Tilde (`) or ISO key next to 1
            guard state.searchQuery.isEmpty, !state.groups.isEmpty else { return }
            let group = state.groups[state.selectedGroupIndex]
            let bundleId = group.appBundleId ?? ""
            let isBrowser = WindowManager.shared.isBrowser(bundleId: bundleId)
            let hasPermission = isBrowser ? WindowManager.shared.checkAutomationPermission(bundleIdentifier: bundleId, prompt: false) : true
            // Expandable if it has multiple windows, or it's a browser we can't read tabs from yet
            // (expandGroup will then request Automation permission).
            guard group.windows.count > 1 || (isBrowser && !hasPermission) else { return }
            if state.expandedGroupIds.contains(group.id) {
                state.collapseGroup()
            } else {
                state.expandGroup()
            }
            
        case 51, 117: // Backspace or Forward Delete
            if state.searchQuery.isEmpty {
                state.closeSelectedWindow()
            } else {
                super.keyDown(with: event)
            }
            
        case 13: // W
            if event.modifierFlags.contains(.command) || AppPreferences.shared.shortcutPreset.isModifierPressed(event.modifierFlags) {
                state.closeSelectedWindow()
            } else {
                super.keyDown(with: event)
            }

        case 43: // Comma — Cmd+, opens Preferences
            if event.modifierFlags.contains(.command) {
                self.orderOut(nil)
                (NSApp.delegate as? AppDelegate)?.showPreferencesWindow()
            } else {
                super.keyDown(with: event)
            }
            
        default:
            super.keyDown(with: event)
        }
    }
}
