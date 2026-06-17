import Foundation
import AppKit
import ApplicationServices
import SwiftUI

struct WindowItem: Identifiable, Hashable {
    let id: String // Unique ID: "pid_windowId"
    let windowId: Int?
    let processId: pid_t
    let appName: String
    let appBundleId: String?
    let title: String
    let isMinimized: Bool
    var lastFocusedAt: Date?
    let axElement: AXUIElement // The actual AXUIElement for focusing
    var thumbnail: NSImage? // Live window screenshot
    
    // Tab support
    var isTab: Bool = false
    var tabIndex: Int? = nil
    var browserWindowId: Int? = nil
    var browserName: String? = nil
    var tabUrl: String? = nil
    
    init(
        id: String,
        windowId: Int?,
        processId: pid_t,
        appName: String,
        appBundleId: String?,
        title: String,
        isMinimized: Bool,
        lastFocusedAt: Date? = nil,
        axElement: AXUIElement,
        thumbnail: NSImage? = nil,
        isTab: Bool = false,
        tabIndex: Int? = nil,
        browserWindowId: Int? = nil,
        browserName: String? = nil,
        tabUrl: String? = nil
    ) {
        self.id = id
        self.windowId = windowId
        self.processId = processId
        self.appName = appName
        self.appBundleId = appBundleId
        self.title = title
        self.isMinimized = isMinimized
        self.lastFocusedAt = lastFocusedAt
        self.axElement = axElement
        self.thumbnail = thumbnail
        self.isTab = isTab
        self.tabIndex = tabIndex
        self.browserWindowId = browserWindowId
        self.browserName = browserName
        self.tabUrl = tabUrl
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: WindowItem, rhs: WindowItem) -> Bool {
        return lhs.id == rhs.id
    }
}

struct WindowGroup: Identifiable, Hashable {
    var id: String { appBundleId ?? appName }
    let appName: String
    let appBundleId: String?
    let appIcon: NSImage?
    var windows: [WindowItem]
    var mostRecentWindow: WindowItem?
}

class WindowManager {
    static let shared = WindowManager()
    
    private var cachedScripts: [String: NSAppleScript] = [:]
    private let scriptLock = NSLock()
    
    private init() {}

    /// Returns true if the AXUIElement still refers to a live, accessible window.
    /// A stale element (process exited, window closed) returns .invalidUIElement or .cannotComplete.
    private func isAXElementValid(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        return err == .success || err == .noValue
    }

    /// Snapshot of on-screen windows used to map AX elements to CGWindowIDs.
    /// Reads metadata only (PID, window number, bounds) — does NOT require Screen Recording
    /// permission and does NOT trigger any system prompt. Fetched once per scan.
    struct CGWindowSnapshot {
        let entries: [(windowID: CGWindowID, pid: pid_t, bounds: CGRect)]
    }

    func fetchCGWindowSnapshot() -> CGWindowSnapshot {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[CFString: Any]] ?? []
        var entries: [(windowID: CGWindowID, pid: pid_t, bounds: CGRect)] = []
        for info in list {
            guard let pid = info[kCGWindowOwnerPID] as? pid_t,
                  let windowID = info[kCGWindowNumber] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            entries.append((windowID: windowID, pid: pid, bounds: bounds))
        }
        return CGWindowSnapshot(entries: entries)
    }

    /// Maps an AXUIElement to its CGWindowID by matching owner PID + frame bounds against a
    /// pre-fetched snapshot. Uses only public APIs (App Store safe).
    private func cgWindowID(for axElement: AXUIElement, pid: pid_t,
                            in snapshot: CGWindowSnapshot) -> Int? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef,
              CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID() else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) else { return nil }

        let tolerance: CGFloat = 3.0
        for entry in snapshot.entries where entry.pid == pid {
            if abs(entry.bounds.origin.x - position.x) <= tolerance,
               abs(entry.bounds.origin.y - position.y) <= tolerance,
               abs(entry.bounds.size.width - size.width) <= tolerance,
               abs(entry.bounds.size.height - size.height) <= tolerance {
                return Int(entry.windowID)
            }
        }
        return nil
    }

    /// Check if accessibility permissions are trusted.
    /// If prompt is true and permissions are missing, macOS will show a system prompt.
    func checkAccessibilityPermission(prompt: Bool) -> Bool {
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
            let options = [key: kCFBooleanTrue] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        } else {
            return AXIsProcessTrusted()
        }
    }
    
    /// Check if Screen Recording permission is granted (needed for window thumbnails).
    func checkScreenRecordingPermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }
    
    /// Request Screen Recording permission (opens System Settings).
    func requestScreenRecordingPermission() {
        CGRequestScreenCaptureAccess()
    }
    
    /// Check if AppleEvents/Automation permission is granted for a target application bundle ID.
    /// If prompt is true, it triggers the macOS system dialog if the permission status is unknown.
    func checkAutomationPermission(bundleIdentifier: String, prompt: Bool) -> Bool {
        let targetDescriptor = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard var addressDesc = targetDescriptor.aeDesc?.pointee else {
            return false
        }
        
        let status = AEDeterminePermissionToAutomateTarget(
            &addressDesc,
            typeWildCard,
            typeWildCard,
            prompt
        )

        return status == noErr
    }

    /// Ensures Automation permission for a browser, triggering the macOS consent dialog on first
    /// use. Sending a benign AppleEvent is the reliable way to surface the prompt (unlike the
    /// AEDeterminePermissionToAutomateTarget prompt flag, which is inconsistent on first call).
    /// - Returns: true if access is now granted (tabs can be read); false if denied or undetermined.
    ///   Call OFF the main thread — the consent dialog blocks until the user responds.
    func requestBrowserAutomation(bundleId: String, browserName: String) -> Bool {
        if checkAutomationPermission(bundleIdentifier: bundleId, prompt: false) { return true }
        _ = executeAppleScript(source: "tell application \"\(browserName)\" to return name")
        return checkAutomationPermission(bundleIdentifier: bundleId, prompt: false)
    }

    /// Returns true if the bundle ID corresponds to a browser that supports tab automation.
    func isBrowser(bundleId: String) -> Bool {
        return getBrowserName(bundleId: bundleId) != nil
    }
    
    private func getBrowserName(bundleId: String) -> String? {
        switch bundleId {
        case "com.google.Chrome": return "Google Chrome"
        case "com.microsoft.edgemac": return "Microsoft Edge"
        case "com.brave.Browser": return "Brave Browser"
        case "company.thebrowser.Browser": return "Arc"
        case "com.vivaldi.Vivaldi": return "Vivaldi"
        case "com.apple.Safari": return "Safari"
        default: return nil
        }
    }
    
    private func executeAppleScript(source: String) -> String? {
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        if let result = script?.executeAndReturnError(&errorInfo) {
            return result.stringValue
        } else {
            if let err = errorInfo {
                print("Tabby AppleScript error: \(err)")
            }
            return nil
        }
    }
    
    private func executeAppleScript(_ script: NSAppleScript) -> String? {
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if errorInfo == nil {
            return result.stringValue
        } else {
            if let err = errorInfo {
                print("Tabby AppleScript error: \(err)")
            }
            return nil
        }
    }
    
    /// Builds the tab-enumeration AppleScript source for a browser. Pure string construction,
    /// safe to call from any thread.
    private func browserTabScriptSource(bundleId: String, browserName: String) -> String {
        let scriptSource: String
        if bundleId == "com.apple.Safari" {
            scriptSource = """
            tell application "Safari"
                if not running then return ""
                if not (exists window 1) then return ""
                set output to ""
                set winList to every window
                repeat with w in winList
                    try
                        set winId to id of w
                        set winTitle to name of w
                        set tabIndex to 1
                        set everyTab to every tab of w
                        repeat with t in everyTab
                            set output to output & winId & "||" & winTitle & "||" & tabIndex & "||" & name of t & "||" & URL of t & "\\n"
                            set tabIndex to tabIndex + 1
                        end repeat
                    end try
                end repeat
                return output
            end tell
            """
        } else {
            scriptSource = """
            tell application "\(browserName)"
                if not running then return ""
                if not (exists window 1) then return ""
                set output to ""
                set winList to every window
                repeat with w in winList
                    try
                        set winId to id of w
                        set winTitle to title of w
                        set tabIndex to 1
                        set everyTab to every tab of w
                        repeat with t in everyTab
                            set output to output & winId & "||" & winTitle & "||" & tabIndex & "||" & title of t & "||" & URL of t & "\\n"
                            set tabIndex to tabIndex + 1
                        end repeat
                    end try
                end repeat
                return output
            end tell
            """
        }
        return scriptSource
    }

    private func getCompiledScript(bundleId: String, browserName: String) -> NSAppleScript? {
        scriptLock.lock()
        defer { scriptLock.unlock() }

        let cacheKey = bundleId == "com.apple.Safari" ? "Safari" : browserName
        if let script = cachedScripts[cacheKey] {
            return script
        }

        let scriptSource = browserTabScriptSource(bundleId: bundleId, browserName: browserName)
        if let script = NSAppleScript(source: scriptSource) {
            cachedScripts[cacheKey] = script
            return script
        }
        return nil
    }
    
    struct BrowserTabInfo {
        let browserWindowId: Int
        let winTitle: String
        let tabIndex: Int
        let tabTitle: String
        let tabUrl: String
    }
    
    private func parseBrowserTabs(from output: String) -> [BrowserTabInfo]? {
        var tabs: [BrowserTabInfo] = []
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            let parts = line.components(separatedBy: "||")
            guard parts.count >= 5 else { continue }
            guard let winId = Int(parts[0]), let tabIdx = Int(parts[2]) else { continue }
            let winTitle = parts[1]
            let tabTitle = parts[3]
            let tabUrl = parts[4]

            if tabTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            tabs.append(BrowserTabInfo(
                browserWindowId: winId,
                winTitle: winTitle,
                tabIndex: tabIdx,
                tabTitle: tabTitle,
                tabUrl: tabUrl
            ))
        }
        return tabs.isEmpty ? nil : tabs
    }

    private func fetchBrowserTabs(bundleId: String, browserName: String) -> [BrowserTabInfo]? {
        guard let script = getCompiledScript(bundleId: bundleId, browserName: browserName),
              let output = executeAppleScript(script), !output.isEmpty else {
            return nil
        }
        return parseBrowserTabs(from: output)
    }

    /// Thread-safe variant for concurrent use: builds a FRESH NSAppleScript instance (never the
    /// shared cache) so multiple browser fetches can run on different threads without sharing a
    /// non-thread-safe NSAppleScript instance.
    private func fetchBrowserTabsConcurrentSafe(bundleId: String, browserName: String) -> [BrowserTabInfo]? {
        let source = browserTabScriptSource(bundleId: bundleId, browserName: browserName)
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil, let output = result.stringValue, !output.isEmpty else {
            if let err = errorInfo { print("Tabby AppleScript error (\(browserName)): \(err)") }
            return nil
        }
        return parseBrowserTabs(from: output)
    }
    
    /// Collect all windows grouped by application (metadata only — no thumbnails, instant)
    func collectWindowGroups(expandedGroupIds: Set<String> = []) -> [WindowGroup] {
        var groups: [WindowGroup] = []
        let workspace = NSWorkspace.shared
        let runningApps = workspace.runningApplications
        // Single metadata snapshot for the whole scan (avoids per-window system calls).
        let cgSnapshot = fetchCGWindowSnapshot()

        // Pre-fetch every browser's tabs CONCURRENTLY. AppleScript round-trips are slow; doing
        // them serially inside the loop would make the whole list wait on the sum of all browsers.
        // Concurrent fetch means it waits only on the slowest single browser.
        struct BrowserFetch { let bundleId: String; let browserName: String; let key: String }
        var fetchList: [BrowserFetch] = []
        for app in runningApps where app.activationPolicy == .regular {
            let bundleId = app.bundleIdentifier ?? ""
            guard let browserName = getBrowserName(bundleId: bundleId) else { continue }
            let appName = app.localizedName ?? "Unknown"
            let key = bundleId.isEmpty ? appName : bundleId
            let isExpanded = expandedGroupIds.contains(key)
            if checkAutomationPermission(bundleIdentifier: bundleId, prompt: false) || isExpanded {
                fetchList.append(BrowserFetch(bundleId: bundleId, browserName: browserName, key: key))
            }
        }
        var prefetchedTabs: [String: [BrowserTabInfo]] = [:]
        if !fetchList.isEmpty {
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: fetchList.count) { i in
                let f = fetchList[i]
                if let tabs = self.fetchBrowserTabsConcurrentSafe(bundleId: f.bundleId, browserName: f.browserName) {
                    lock.lock()
                    prefetchedTabs[f.key] = tabs
                    lock.unlock()
                }
            }
        }

        for app in runningApps {
            // Only inspect regular GUI applications
            guard app.activationPolicy == .regular else { continue }
            let pid = app.processIdentifier
            
            let appName = app.localizedName ?? "Unknown"
            let bundleId = app.bundleIdentifier ?? ""
            let appIcon = app.icon
            
            var items: [WindowItem] = []
            var isBrowserWithTabs = false
            
            if let browserName = getBrowserName(bundleId: bundleId) {
                let groupKey = bundleId.isEmpty ? appName : bundleId

                if let tabs = prefetchedTabs[groupKey] {
                    isBrowserWithTabs = true
                    
                    let appElement = AXUIElementCreateApplication(pid)
                    var windowListRef: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowListRef)
                    let axWindows = windowListRef as? [AXUIElement] ?? []
                    
                    for tab in tabs {
                        var matchedAXWindow: AXUIElement? = nil
                        for axWin in axWindows {
                            var titleRef: CFTypeRef?
                            AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRef)
                            let axTitle = titleRef as? String ?? ""
                            if axTitle == tab.winTitle || tab.winTitle.contains(axTitle) || axTitle.contains(tab.winTitle) {
                                matchedAXWindow = axWin
                                break
                            }
                        }
                        
                        let axElementToUse = matchedAXWindow ?? axWindows.first ?? appElement
                        
                        let finalCGWinId: Int? = cgWindowID(for: axElementToUse, pid: pid, in: cgSnapshot)
                        
                        let uniqueId = "tab_\(pid)_\(tab.browserWindowId)_\(tab.tabIndex)"
                        
                        let item = WindowItem(
                            id: uniqueId,
                            windowId: finalCGWinId,
                            processId: pid,
                            appName: appName,
                            appBundleId: bundleId,
                            title: tab.tabTitle,
                            isMinimized: false,
                            lastFocusedAt: nil,
                            axElement: axElementToUse,
                            thumbnail: nil,
                            isTab: true,
                            tabIndex: tab.tabIndex,
                            browserWindowId: tab.browserWindowId,
                            browserName: browserName,
                            tabUrl: tab.tabUrl
                        )
                        items.append(item)
                    }
                }
            }
            
            if !isBrowserWithTabs {
                let appElement = AXUIElementCreateApplication(pid)
                var windowListRef: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowListRef)
                
                // If we can't copy windows, skip
                guard result == .success, let windows = windowListRef as? [AXUIElement] else { continue }
                
                for window in windows {
                    // Filter out non-standard windows (like sheets, drawers, popups, and menus)
                    var subroleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef)
                    let subrole = subroleRef as? String ?? ""
                    
                    // Allowed window types: standard window, dialog, system dialog, or empty subrole (some apps don't set it)
                    let allowedSubroles = [kAXStandardWindowSubrole, kAXDialogSubrole, kAXSystemDialogSubrole, ""]
                    if !subrole.isEmpty && !allowedSubroles.contains(subrole) {
                        continue
                    }
                    
                    // Filter out windows that cannot be focused/interacted with
                    var roleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef)
                    let role = roleRef as? String ?? ""
                    if !role.isEmpty && role != kAXWindowRole {
                        continue
                    }
                    
                    // Get window title
                    var titleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                    let title = titleRef as? String ?? ""
                    
                    // Ignore empty or untitled windows
                    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedTitle.isEmpty {
                        continue
                    }
                    
                    // Get minimized state
                    var minimizedRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef)
                    let isMinimized = (minimizedRef as? Bool) ?? false
                    
                    let windowId: Int? = cgWindowID(for: window, pid: pid, in: cgSnapshot)
                    
                    let uniqueId = "\(pid)_\(windowId ?? Int(bitPattern: ObjectIdentifier(window)))"
                    
                    // Thumbnail is nil here — lazy-loaded separately after display
                    let item = WindowItem(
                        id: uniqueId,
                        windowId: windowId,
                        processId: pid,
                        appName: appName,
                        appBundleId: bundleId,
                        title: title,
                        isMinimized: isMinimized,
                        lastFocusedAt: nil,
                        axElement: window,
                        thumbnail: nil
                    )
                    items.append(item)
                }
            }
            
            if !items.isEmpty {
                let group = WindowGroup(
                    appName: appName,
                    appBundleId: bundleId,
                    appIcon: appIcon,
                    windows: items,
                    mostRecentWindow: items.first
                )
                groups.append(group)
            }
        }
        
        return groups
    }
    
    /// Captures a live screenshot of a window by its CGWindowID
    func captureWindowThumbnail(windowId: CGWindowID, maxWidth: CGFloat = 280) -> NSImage? {
        guard UserDefaults.standard.bool(forKey: "TabbyScreenRecordingRequested") else {
            return nil
        }
        guard checkScreenRecordingPermission() else {
            return nil
        }
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowId,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            return nil
        }
        
        let fullSize = NSSize(width: cgImage.width, height: cgImage.height)
        guard fullSize.width > 0, fullSize.height > 0 else { return nil }
        
        // Scale down to maxWidth while preserving aspect ratio
        let scale = min(maxWidth / fullSize.width, 1.0)
        let thumbSize = NSSize(width: fullSize.width * scale, height: fullSize.height * scale)
        
        let nsImage = NSImage(cgImage: cgImage, size: thumbSize)
        return nsImage
    }
    
    /// Focuses and raises a target window
    func focus(windowItem: WindowItem) -> Bool {
        let workspace = NSWorkspace.shared
        guard let runningApp = workspace.runningApplications.first(where: { $0.processIdentifier == windowItem.processId }) else {
            return false
        }
        guard isAXElementValid(windowItem.axElement) else {
            print("Tabby: AXUIElement is stale for PID \(windowItem.processId), skipping focus")
            return false
        }

        // 1. Unhide application if hidden
        if runningApp.isHidden {
            runningApp.unhide()
        }
        
        // 2. Activate target application
        runningApp.activate(options: [.activateIgnoringOtherApps])
        
        // 3. Un-minimize if minimized
        if windowItem.isMinimized {
            let result = AXUIElementSetAttributeValue(windowItem.axElement, kAXMinimizedAttribute as CFString, false as CFBoolean)
            if result != .success {
                print("Tabby: Failed to un-minimize window (PID \(windowItem.processId)): \(result)")
            }
        }
        
        // 4. Raise the window to front
        let raiseResult = AXUIElementPerformAction(windowItem.axElement, kAXRaiseAction as CFString)
        if raiseResult != .success {
            print("Tabby: Failed to raise window (PID \(windowItem.processId)): \(raiseResult)")
        }
        
        // 5. Make it the main window
        let mainResult = AXUIElementSetAttributeValue(windowItem.axElement, kAXMainAttribute as CFString, true as CFBoolean)
        
        // 6. Flash the window frame for a celebration/spotlight!
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        let posResult = AXUIElementCopyAttributeValue(windowItem.axElement, kAXPositionAttribute as CFString, &positionRef)
        let sizeResult = AXUIElementCopyAttributeValue(windowItem.axElement, kAXSizeAttribute as CFString, &sizeRef)
        
        if posResult == .success, sizeResult == .success {
            var position = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetValue(positionRef as! AXValue, .cgPoint, &position) &&
               AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) {
                let rect = CGRect(origin: position, size: size)
                let delay = windowItem.isMinimized ? 0.35 : 0.05
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    FlashOverlay.show(on: rect)
                }
            }
        }
        
        if windowItem.isTab, let tabIndex = windowItem.tabIndex, let winId = windowItem.browserWindowId, let browserName = windowItem.browserName {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let scriptSource: String
                if browserName == "Safari" {
                    scriptSource = """
                    tell application "Safari"
                        try
                            tell window id \(winId)
                                set current tab to tab \(tabIndex)
                                set index to 1
                            end tell
                            activate
                        end try
                    end tell
                    """
                } else {
                    scriptSource = """
                    tell application "\(browserName)"
                        try
                            tell window id \(winId)
                                set active tab index to \(tabIndex)
                                set index to 1
                            end tell
                            activate
                        end try
                    end tell
                    """
                }
                _ = self.executeAppleScript(source: scriptSource)
            }
        }
        
        return raiseResult == .success || mainResult == .success
    }
    
    /// Closes a target window using Accessibility APIs
    func close(windowItem: WindowItem) -> Bool {
        guard isAXElementValid(windowItem.axElement) else {
            print("Tabby: AXUIElement is stale for PID \(windowItem.processId), skipping close")
            return false
        }
        var closeButtonRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(windowItem.axElement, kAXCloseButtonAttribute as CFString, &closeButtonRef)
        
        if result == .success {
            // Swift correctly infers this to be AXUIElement
            let closeButton = closeButtonRef as! AXUIElement
            let actionResult = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            
            if actionResult != .success {
                print("Tabby: Failed to perform close action on window (PID \(windowItem.processId)): \(actionResult)")
            }
            return actionResult == .success
        } else {
            print("Tabby: Failed to find close button for window (PID \(windowItem.processId)): \(result)")
            return false
        }
    }
}

// MARK: - Discovery Celebration Flash Overlay
class FlashOverlay {
    static func show(on rect: CGRect) {
        DispatchQueue.main.async {
            guard let mainScreen = NSScreen.screens.first else { return }
            let screenHeight = mainScreen.frame.height
            
            // Convert CG coordinates (top-left origin, y-down) to AppKit coordinates (bottom-left origin, y-up)
            let appKitRect = NSRect(
                x: rect.origin.x,
                y: screenHeight - rect.origin.y - rect.size.height,
                width: rect.size.width,
                height: rect.size.height
            )
            
            let panel = NSPanel(
                contentRect: appKitRect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .statusBar // Display above normal windows
            
            let flashView = FlashBorderView()
            let hostingView = NSHostingView(rootView: flashView)
            panel.contentView = hostingView
            
            panel.orderFrontRegardless()
            
            // Animate fade out
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.6
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 0.0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
    }
}

struct FlashBorderView: View {
    @State private var pulse = false
    
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.accentColor,
                        Color.accentColor.opacity(0.8),
                        Color.blue,
                        Color.accentColor
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: pulse ? 6 : 3
            )
            .shadow(color: Color.accentColor.opacity(pulse ? 0.8 : 0.4), radius: 8)
            .padding(1)
            .onAppear {
                withAnimation(Animation.easeInOut(duration: 0.28).repeatCount(2, autoreverses: true)) {
                    pulse = true
                }
            }
    }
}
