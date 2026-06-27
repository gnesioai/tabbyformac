import Foundation
import AppKit
import ApplicationServices
import SwiftUI

// Private CoreGraphics SPI that returns the exact CGWindowID for an AXUIElement. Not part of the
// public SDK, so it is incompatible with Mac App Store review — but fully fine for apps distributed
// outside the store as a notarized, Developer ID-signed build (this is what AltTab uses). It gives a
// unique, stable id per window, avoiding the ambiguity of matching windows by frame bounds.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

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
    var isActiveTab: Bool = false
    
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
        tabUrl: String? = nil,
        isActiveTab: Bool = false
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
        self.isActiveTab = isActiveTab
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: WindowItem, rhs: WindowItem) -> Bool {
        return lhs.id == rhs.id
    }
}

struct WindowGroup: Identifiable, Hashable {
    let id: String          // unique per group; browsers use "<bundleId>_<winId>" so profiles are separate
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
                        set winB to bounds of w
                        set winBStr to (item 1 of winB) & "," & (item 2 of winB) & "," & (item 3 of winB) & "," & (item 4 of winB)
                        set tabIndex to 1
                        set activeTab to current tab of w
                        set everyTab to every tab of w
                        repeat with t in everyTab
                            set isActive to "0"
                            if t is activeTab then
                                set isActive to "1"
                            end if
                            set output to output & winId & "||" & winTitle & "||" & tabIndex & "||" & name of t & "||" & URL of t & "||" & winBStr & "||" & isActive & "\\n"
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
                        set winB to bounds of w
                        set winBStr to (item 1 of winB) & "," & (item 2 of winB) & "," & (item 3 of winB) & "," & (item 4 of winB)
                        set tabIndex to 1
                        set activeIdx to active tab index of w
                        set everyTab to every tab of w
                        repeat with t in everyTab
                            set isActive to "0"
                            if tabIndex is activeIdx then
                                set isActive to "1"
                            end if
                            set output to output & winId & "||" & winTitle & "||" & tabIndex & "||" & title of t & "||" & URL of t & "||" & winBStr & "||" & isActive & "\\n"
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
        let winBounds: CGRect?  // AppleScript window bounds {left,top,right,bottom}, used to match the right AX window across profiles
        let isActiveTab: Bool
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

            var bounds: CGRect? = nil
            if parts.count >= 6 {
                let b = parts[5].components(separatedBy: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if b.count == 4 {
                    bounds = CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1])
                }
            }
            
            var isActive = false
            if parts.count >= 7 {
                isActive = parts[6].trimmingCharacters(in: .whitespacesAndNewlines) == "1"
            }

            tabs.append(BrowserTabInfo(
                browserWindowId: winId,
                winTitle: winTitle,
                tabIndex: tabIdx,
                tabTitle: tabTitle,
                tabUrl: tabUrl,
                winBounds: bounds,
                isActiveTab: isActive
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

    /// Collect all windows grouped by application (metadata only — no thumbnails, instant)
    func collectWindowGroups(expandedGroupIds: Set<String> = []) -> [WindowGroup] {
        var groups: [WindowGroup] = []
        let workspace = NSWorkspace.shared
        let runningApps = workspace.runningApplications
        // Pre-fetch each browser's tabs CONCURRENTLY using its CACHED, compiled AppleScript.
        // Concurrency keeps the open fast with multiple browsers; reusing the cached script
        // (compiled once, never rebuilt) avoids the per-open instance churn. Each browser has its
        // own distinct cached instance run by a single task, so no instance is shared across threads.
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
            // Serial, NOT concurrent: NSAppleScript / Apple Events are not thread-safe, and running
            // multiple browser scripts at once races so every browser returns the same browser's tabs.
            for f in fetchList {
                if let tabs = self.fetchBrowserTabs(bundleId: f.bundleId, browserName: f.browserName) {
                    prefetchedTabs[f.key] = tabs
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

                    let tabsByWindow = Dictionary(grouping: tabs, by: { $0.browserWindowId })

                    // CGWindowListCopyWindowInfo sees windows on ALL Spaces; kAXWindowsAttribute
                    // only returns windows on the current Space. Use CG for thumbnail windowIds,
                    // AX for focus/raise actions.
                    // Filter to actual browser windows: same PID, layer 0, large enough to be a real window.
                    let allCGWins = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
                    let chromeCGWins = allCGWins.filter { win -> Bool in
                        guard (win[kCGWindowOwnerPID as String] as? Int) == Int(pid),
                              (win[kCGWindowLayer as String] as? Int) == 0,
                              let boundsNS = win[kCGWindowBounds as String] as? NSDictionary,
                              let rect = CGRect(dictionaryRepresentation: boundsNS as CFDictionary)
                        else { return false }
                        return rect.width > 200 && rect.height > 200
                    }
                    // AX window matching (current Space only) — used for focus/raise AND
                    // as the primary source of CGWindowIDs via _AXUIElementGetWindow.
                    // Falls back to appElement when the window is on another Space.
                    var winIdToAX: [Int: AXUIElement] = [:]
                    for (browserWinId, winTabs) in tabsByWindow {
                        guard let firstTab = winTabs.first else { continue }
                        var bestAXWindow: AXUIElement? = nil
                        var bestDist = CGFloat.infinity
                        for axWin in axWindows {
                            var posRef: CFTypeRef?
                            var sizeRef: CFTypeRef?
                            var pos = CGPoint.zero
                            var size = CGSize.zero
                            AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posRef)
                            AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &sizeRef)
                            if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
                            if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &size) }
                            if let b = firstTab.winBounds {
                                let dx = pos.x - b.origin.x; let dy = pos.y - b.origin.y
                                let dist = dx*dx + dy*dy
                                if dist < bestDist { bestDist = dist; bestAXWindow = axWin }
                            }
                        }
                        winIdToAX[browserWinId] = bestAXWindow  // nil if axWindows is empty
                    }

                    // Build CGWindowID map: primary = _AXUIElementGetWindow on matched AX window
                    // (reliable for same-Space windows); fallback = Z-order index into CGWindowList
                    // (handles cross-Space windows where AX is blind).
                    var orderedWinIds: [Int] = []
                    var seenWinIds = Set<Int>()
                    for tab in tabs where seenWinIds.insert(tab.browserWindowId).inserted {
                        orderedWinIds.append(tab.browserWindowId)
                    }
                    var winIdToCGWindowId: [Int: CGWindowID] = [:]
                    for (i, winId) in orderedWinIds.enumerated() {
                        // Primary: AX element -> _AXUIElementGetWindow
                        if let axWin = winIdToAX[winId] {
                            var cgId: CGWindowID = 0
                            if _AXUIElementGetWindow(axWin, &cgId) == .success, cgId != 0 {
                                winIdToCGWindowId[winId] = cgId
                                continue
                            }
                        }
                        // Fallback: Z-order index mapping for cross-Space windows
                        if i < chromeCGWins.count,
                           let cgId = chromeCGWins[i][kCGWindowNumber as String] as? Int {
                            winIdToCGWindowId[winId] = CGWindowID(cgId)
                        }
                    }

                    // Group tabs by their browser window ID so each profile window becomes
                    // a separate Tabby group rather than all profiles merging under one Chrome entry.
                    for (browserWinId, winTabs) in tabsByWindow {
                        let axElementToUse = winIdToAX[browserWinId] ?? appElement
                        var winItems: [WindowItem] = []
                        for tab in winTabs {
                            let finalCGWinId: Int? = winIdToCGWindowId[tab.browserWindowId].map { Int($0) }

                            let item = WindowItem(
                                id: "tab_\(pid)_\(tab.browserWindowId)_\(tab.tabIndex)",
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
                                tabUrl: tab.tabUrl,
                                isActiveTab: tab.isActiveTab
                            )
                            winItems.append(item)
                        }
                        if !winItems.isEmpty {
                            // Unique group ID per browser window — prevents profiles from merging
                            let groupId = bundleId.isEmpty ? "\(appName)_\(browserWinId)" : "\(bundleId)_\(browserWinId)"
                            groups.append(WindowGroup(
                                id: groupId,
                                appName: appName,
                                appBundleId: bundleId,
                                appIcon: appIcon,
                                windows: winItems,
                                mostRecentWindow: winItems.first
                            ))
                        }
                    }
                }
            }

            if !isBrowserWithTabs {
                let appElement = AXUIElementCreateApplication(pid)
                var windowListRef: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowListRef)

                guard result == .success, let windows = windowListRef as? [AXUIElement] else { continue }

                for window in windows {
                    var subroleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef)
                    let subrole = subroleRef as? String ?? ""

                    let allowedSubroles = [kAXStandardWindowSubrole, kAXDialogSubrole, kAXSystemDialogSubrole, ""]
                    if !subrole.isEmpty && !allowedSubroles.contains(subrole) {
                        continue
                    }

                    var roleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef)
                    let role = roleRef as? String ?? ""
                    if !role.isEmpty && role != kAXWindowRole {
                        continue
                    }

                    var titleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                    let title = titleRef as? String ?? ""
                    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedTitle = trimmedTitle.isEmpty ? appName : trimmedTitle

                    var minimizedRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef)
                    let isMinimized = (minimizedRef as? Bool) ?? false

                    var windowId: Int? = nil
                    var cgWinId: CGWindowID = 0
                    if _AXUIElementGetWindow(window, &cgWinId) == .success {
                        windowId = Int(cgWinId)
                    }

                    let uniqueId = "\(pid)_\(windowId ?? Int(bitPattern: ObjectIdentifier(window)))"

                    let item = WindowItem(
                        id: uniqueId,
                        windowId: windowId,
                        processId: pid,
                        appName: appName,
                        appBundleId: bundleId,
                        title: resolvedTitle,
                        isMinimized: isMinimized,
                        lastFocusedAt: nil,
                        axElement: window,
                        thumbnail: nil,
                        isActiveTab: true
                    )
                    items.append(item)
                }
            }

            if !items.isEmpty {
                let groupId = bundleId.isEmpty ? appName : bundleId
                let group = WindowGroup(
                    id: groupId,
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
    func captureWindowThumbnail(windowId: CGWindowID, maxWidth: CGFloat = 640) -> NSImage? {
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
