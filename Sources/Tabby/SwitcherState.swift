import Foundation
import AppKit
import Combine

class SwitcherState: ObservableObject {
    @Published var groups: [WindowGroup] = []
    @Published var searchQuery: String = ""
    @Published var hasPermission: Bool = false
    @Published var hasScreenRecording: Bool = false
    @Published var isLoading: Bool = false
    @Published var thumbnailsLoading: Bool = false
    // Flat results when search is active
    @Published var searchResults: [SearchResultItem] = []
    
    // Navigation index
    @Published var selectedGroupIndex: Int = 0
    @Published var selectedWindowIndex: Int? = nil // nil means the group header itself is selected
    
    // Expanded groups (stored by group ID)
    @Published var expandedGroupIds: Set<String> = []
    
    // Focus history tracking: windowItem.id -> Date
    private var focusHistory: [String: Date] = [:]
    private var activeAppProcessId: pid_t? = nil

    // Real system MRU: records when each app was last activated (keyed by group id = bundleId ?? appName).
    // Populated event-driven via NSWorkspace activation notifications — no polling.
    private var appActivationHistory: [String: Date] = [:]
    
    // Permission polling timer
    private var permissionPollTimer: Timer?
    
    // Thumbnail lazy-load cancellation: increment to cancel any in-flight load job
    private var thumbnailLoadToken: Int = 0
    private let thumbnailQueue = DispatchQueue(label: "com.tabby.thumbnails", qos: .userInitiated)
    
    private var hasPromptedAccessibilityInSession = false
    private var hasPromptedScreenRecordingInSession = false
    
    private let activationHistoryKey = "TabbyAppActivationHistory"

    init() {
        checkPermission()
        // Restore recency order from previous sessions so chronology survives relaunches.
        if let stored = UserDefaults.standard.dictionary(forKey: activationHistoryKey) as? [String: Double] {
            appActivationHistory = stored.mapValues { Date(timeIntervalSinceReferenceDate: $0) }
        }
        // Record initial frontmost app
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            activeAppProcessId = frontmostApp.processIdentifier
            recordActivation(of: frontmostApp)
        }
        // Track real system app-switch order (event-driven, no polling)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        // Start polling for permissions if not already granted
        startPermissionPollingIfNeeded()
    }

    deinit {
        permissionPollTimer?.invalidate()
        thumbnailLoadToken += 1 // cancel any in-flight thumbnail work
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Stable key used both for grouping and activation history.
    private func activationKey(for app: NSRunningApplication) -> String {
        return app.bundleIdentifier ?? app.localizedName ?? ""
    }

    private func recordActivation(of app: NSRunningApplication) {
        let key = activationKey(for: app)
        // Ignore empty keys and Tabby's own activation (it never appears as a group).
        guard !key.isEmpty, key != Bundle.main.bundleIdentifier else { return }
        appActivationHistory[key] = Date()
        // Persist so recency survives relaunches.
        let serialized = appActivationHistory.mapValues { $0.timeIntervalSinceReferenceDate }
        UserDefaults.standard.set(serialized, forKey: activationHistoryKey)
    }

    @objc private func handleAppActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        recordActivation(of: app)
    }
    
    /// Starts a repeating timer that checks for permissions every 2 seconds.
    /// Automatically stops once Accessibility is acquired.
    private func startPermissionPollingIfNeeded() {
        guard !hasPermission else { return }
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let axTrusted = WindowManager.shared.checkAccessibilityPermission(prompt: false)
            
            DispatchQueue.main.async {
                if axTrusted && !self.hasPermission {
                    self.hasPermission = true
                    self.refreshWindows()
                    NotificationCenter.default.post(name: .didUpdateShortcut, object: nil)
                }
                if self.hasPermission {
                    timer.invalidate()
                    self.permissionPollTimer = nil
                }
            }
        }
    }
    
    /// Checks if accessibility and screen recording permissions are present and updates state
    func checkPermission() {
        let axTrusted = WindowManager.shared.checkAccessibilityPermission(prompt: false)
        
        let screenRecordingRequested = UserDefaults.standard.bool(forKey: "TabbyScreenRecordingRequested")
        let scrTrusted = screenRecordingRequested && WindowManager.shared.checkScreenRecordingPermission()
        
        if hasPermission != axTrusted {
            hasPermission = axTrusted
            if axTrusted {
                NotificationCenter.default.post(name: .didUpdateShortcut, object: nil)
            }
        }
        hasScreenRecording = scrTrusted
        
        if !hasPermission {
            startPermissionPollingIfNeeded()
        } else {
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
        }
    }
    
    /// Opens System Settings to the Accessibility privacy pane
    func requestPermission() {
        _ = WindowManager.shared.checkAccessibilityPermission(prompt: true)
        
        if hasPromptedAccessibilityInSession {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        } else {
            hasPromptedAccessibilityInSession = true
        }
    }
    
    /// Opens System Settings to the Screen Recording privacy pane
    func requestScreenRecording() {
        UserDefaults.standard.set(true, forKey: "TabbyScreenRecordingRequested")
        WindowManager.shared.requestScreenRecordingPermission()
        
        // Trigger a dummy window query to force macOS to register Tabby in the Screen Recording list
        _ = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        
        if hasPromptedScreenRecordingInSession {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        } else {
            hasPromptedScreenRecordingInSession = true
        }
    }
    
    /// Refreshes open windows and updates sorting/recency lists.
    /// - Parameter preserveSelection: pass `true` for in-place refreshes while the switcher is
    ///   already open (keeps the user's current highlight). Pass `false` for a fresh open so the
    ///   selection resets to the default — this also clears any stale highlight synchronously so
    ///   the previously-focused row never flashes before the async window scan completes.
    func refreshWindows(preserveSelection: Bool = true) {
        checkPermission()

        guard hasPermission else {
            groups = []
            searchResults = []
            isLoading = false
            return
        }

        // Find current frontmost app
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            activeAppProcessId = frontmostApp.processIdentifier
        }

        isLoading = groups.isEmpty

        // Fresh open: start fully collapsed (groups expand only on demand) and clear any stale
        // highlight immediately so the old selection never flashes.
        if !preserveSelection {
            expandedGroupIds.removeAll()
            resetSelection()
        }

        // Capture selection state to preserve it after the update
        let previousGroupId: String?
        let previousWindowId: String?
        let previousWindowIndex: Int?
        
        if searchQuery.isEmpty {
            if selectedGroupIndex < groups.count {
                let group = groups[selectedGroupIndex]
                previousGroupId = group.id
                if let wIdx = selectedWindowIndex, wIdx < group.windows.count {
                    previousWindowId = group.windows[wIdx].id
                    previousWindowIndex = wIdx
                } else {
                    previousWindowId = nil
                    previousWindowIndex = nil
                }
            } else {
                previousGroupId = nil
                previousWindowId = nil
                previousWindowIndex = nil
            }
        } else {
            if selectedGroupIndex < searchResults.count {
                previousGroupId = searchResults[selectedGroupIndex].id
                previousWindowId = nil
                previousWindowIndex = nil
            } else {
                previousGroupId = nil
                previousWindowId = nil
                previousWindowIndex = nil
            }
        }
        
        
        // Extract existing thumbnails to preserve them
        var oldThumbnailsById: [String: NSImage] = [:]
        var oldThumbnailsByUrl: [String: NSImage] = [:]
        for group in self.groups {
            for win in group.windows {
                if let thumb = win.thumbnail {
                    oldThumbnailsById[win.id] = thumb
                    if win.isTab, let url = win.tabUrl, !url.isEmpty {
                        oldThumbnailsByUrl[url] = thumb
                    }
                }
            }
        }

        thumbnailLoadToken += 1
        let myToken = thumbnailLoadToken
        let historyCopy = focusHistory
        let activePidCopy = activeAppProcessId
        let expandedGroupIdsCopy = expandedGroupIds
        let activationCopy = appActivationHistory
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var collected = WindowManager.shared.collectWindowGroups(expandedGroupIds: expandedGroupIdsCopy)
            
            // Apply focus history and preserve thumbnails
            for i in 0..<collected.count {
                var group = collected[i]
                for j in 0..<group.windows.count {
                    let win = group.windows[j]
                    if let date = historyCopy[win.id] {
                        group.windows[j].lastFocusedAt = date
                    }
                    if let oldThumb = oldThumbnailsById[win.id] {
                        group.windows[j].thumbnail = oldThumb
                    } else if win.isTab, let url = win.tabUrl, !url.isEmpty, let oldThumb = oldThumbnailsByUrl[url] {
                        group.windows[j].thumbnail = oldThumb
                    }
                }
                
                // Sort windows within group by recency (most recent first)
                group.windows.sort { (w1, w2) -> Bool in
                    if let d1 = w1.lastFocusedAt, let d2 = w2.lastFocusedAt {
                        return d1 > d2
                    } else if w1.lastFocusedAt != nil {
                        return true
                    } else if w2.lastFocusedAt != nil {
                        return false
                    }
                    return false // keep original Z-order returned by AX API
                }
                
                group.mostRecentWindow = group.windows.first
                collected[i] = group
            }
            
            // Sort groups by real system app-activation order (most recently used first),
            // mirroring macOS Cmd+Tab. Apps Tabby has seen activated rank by recency; apps not
            // yet seen fall back to current-frontmost-first, then alphabetical.
            collected.sort { (g1, g2) -> Bool in
                // Activation history is keyed by bundleId (same for all windows of a browser),
                // not group id (which is unique per profile window).
                let ak1 = g1.appBundleId ?? g1.appName
                let ak2 = g2.appBundleId ?? g2.appName
                let t1 = activationCopy[ak1]
                let t2 = activationCopy[ak2]

                if let d1 = t1, let d2 = t2 {
                    return d1 > d2
                } else if t1 != nil {
                    return true
                } else if t2 != nil {
                    return false
                }

                let pid1 = g1.windows.first?.processId ?? 0
                let pid2 = g2.windows.first?.processId ?? 0

                // Fallback for apps not yet seen activated: current frontmost first
                if pid1 == activePidCopy { return true }
                if pid2 == activePidCopy { return false }

                return g1.appName.lowercased() < g2.appName.lowercased()
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.thumbnailLoadToken == myToken else { return }

                self.groups = collected
                self.updateSearchResults()
                if preserveSelection {
                    self.preserveOrResetSelection(
                        previousGroupId: previousGroupId,
                        previousWindowId: previousWindowId,
                        previousWindowIndex: previousWindowIndex
                    )
                } else {
                    self.resetSelection()
                }
                self.isLoading = false
                
                // Lazy-load thumbnails in background: top 5 first, then the rest
                self.lazyLoadThumbnails(for: collected)
            }
        }
    }
    
    /// Loads thumbnails on a background thread.
    /// Top `priorityCount` windows are fetched first (priority pass), then the rest.
    private func lazyLoadThumbnails(for initialGroups: [WindowGroup], priorityCount: Int = 5) {
        DispatchQueue.main.async { [weak self] in self?.thumbnailsLoading = true }
        thumbnailLoadToken += 1
        let myToken = thumbnailLoadToken

        // Browser tab previews go first (priority), regular windows fill remaining slots then deferred.
        // One capture per CGWindowID — all tabs sharing that window get the thumbnail via propagation.
        var priorityWork: [(itemId: String, windowId: CGWindowID)] = []
        var deferredWork: [(itemId: String, windowId: CGWindowID)] = []
        var capturedWindowIds = Set<Int>()

        // Pass 1: one representative tab per browser window (prefer active, but any will do)
        for group in initialGroups {
            for win in group.windows where win.isTab {
                guard let wId = win.windowId, !win.isMinimized,
                      !capturedWindowIds.contains(wId) else { continue }
                // Skip inactive tabs only when there IS an active one for this window
                if !win.isActiveTab {
                    let hasActive = group.windows.contains(where: { $0.windowId == wId && $0.isActiveTab })
                    if hasActive { continue }
                }
                capturedWindowIds.insert(wId)
                priorityWork.append((itemId: win.id, windowId: CGWindowID(wId)))
            }
        }

        // Pass 2: regular (non-tab) windows
        var regularSeen = 0
        let remainingPriority = max(0, priorityCount - priorityWork.count)
        for group in initialGroups {
            for win in group.windows where !win.isTab {
                guard let wId = win.windowId, !win.isMinimized,
                      !capturedWindowIds.contains(wId) else { continue }
                capturedWindowIds.insert(wId)
                let entry = (itemId: win.id, windowId: CGWindowID(wId))
                if regularSeen < remainingPriority {
                    priorityWork.append(entry)
                } else {
                    deferredWork.append(entry)
                }
                regularSeen += 1
            }
        }

        thumbnailQueue.async { [weak self] in
            guard let self = self else { return }

            // Priority pass — flush to UI as a batch
            var priorityUpdates: [(itemId: String, thumb: NSImage)] = []
            for entry in priorityWork {
                guard self.thumbnailLoadToken == myToken else { return }
                if let thumb = WindowManager.shared.captureWindowThumbnail(windowId: entry.windowId) {
                    priorityUpdates.append((itemId: entry.itemId, thumb: thumb))
                }
            }
            if !priorityUpdates.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.thumbnailLoadToken == myToken else { return }
                    for update in priorityUpdates {
                        self.applyThumbnail(update.thumb, toItemWithId: update.itemId)
                    }
                }
            }

            // Deferred pass — one at a time
            for entry in deferredWork {
                guard self.thumbnailLoadToken == myToken else { return }
                guard let thumb = WindowManager.shared.captureWindowThumbnail(windowId: entry.windowId) else { continue }
                let captured = thumb
                let capturedId = entry.itemId
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.thumbnailLoadToken == myToken else { return }
                    self.applyThumbnail(captured, toItemWithId: capturedId)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.thumbnailLoadToken == myToken else { return }
                self.thumbnailsLoading = false
            }
        }
    }

    /// Sets the captured screenshot on the matched item only. We do NOT propagate to sibling tabs:
    /// a browser window only renders its frontmost tab, so the screenshot is that tab's content.
    /// Inactive tabs share the same OS window and have no capturable pixels — they render a
    /// title/site placeholder in PreviewPane instead. Must be called on main thread.
    private func applyThumbnail(_ image: NSImage, toItemWithId itemId: String) {
        objectWillChange.send()
        for gIdx in 0..<groups.count {
            for wIdx in 0..<groups[gIdx].windows.count {
                if groups[gIdx].windows[wIdx].id == itemId {
                    groups[gIdx].windows[wIdx].thumbnail = image
                    return
                }
            }
        }
    }

    /// Resets navigation coordinates based on list layout
    func resetSelection() {
        if searchQuery.isEmpty {
            // Grouped view: Default to index 1 (second item) if first group is current app
            if groups.count > 1 && groups[0].windows.first?.processId == activeAppProcessId {
                selectedGroupIndex = 1
            } else {
                selectedGroupIndex = 0
            }
            selectedWindowIndex = nil
        } else {
            // Search view (flat results): Default to first result
            selectedGroupIndex = 0
            selectedWindowIndex = nil
        }
    }
    
    /// Re-applies selection by matching the previously selected group ID and window ID/index if possible,
    /// otherwise falls back to default selection.
    func preserveOrResetSelection(previousGroupId: String?, previousWindowId: String?, previousWindowIndex: Int?) {
        if searchQuery.isEmpty {
            guard let prevGroupId = previousGroupId else {
                resetSelection()
                return
            }
            
            // Find the group in the new list
            if let newGroupIdx = groups.firstIndex(where: { $0.id == prevGroupId }) {
                selectedGroupIndex = newGroupIdx
                
                // If a specific window was selected, try to match it
                if let prevWinIndex = previousWindowIndex {
                    let group = groups[newGroupIdx]
                    if let prevWinId = previousWindowId,
                       let newWinIdx = group.windows.firstIndex(where: { $0.id == prevWinId }) {
                        selectedWindowIndex = newWinIdx
                    } else if prevWinIndex < group.windows.count {
                        selectedWindowIndex = prevWinIndex
                    } else {
                        let fallbackIdx = group.windows.isEmpty ? nil : group.windows.count - 1
                        selectedWindowIndex = fallbackIdx
                    }
                } else {
                    selectedWindowIndex = nil
                }
            } else {
                // Fallback if the group no longer exists
                resetSelection()
            }
        } else {
            // Flat search results: since it is flat and transient, we can match by item ID if possible
            guard let prevGroupId = previousGroupId else {
                resetSelection()
                return
            }
            if let newIdx = searchResults.firstIndex(where: { $0.id == prevGroupId }) {
                selectedGroupIndex = newIdx
                selectedWindowIndex = nil
            } else {
                resetSelection()
            }
        }
    }
    
    /// Recomputes search items based on the text query
    func updateSearchResults() {
        if searchQuery.isEmpty {
            searchResults = []
            return
        }
        
        let query = searchQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var results: [SearchResultItem] = []
        
        for group in groups {
            let appMatch = group.appName.lowercased().contains(query)
            let matchingWindows = group.windows.filter { $0.title.lowercased().contains(query) }
            
            if appMatch {
                // If query matches application name, show the group row
                results.append(.group(group))
            } else if !matchingWindows.isEmpty {
                // If query matches window titles, show those windows directly
                for win in matchingWindows {
                    results.append(.window(win))
                }
            }
        }
        
        self.searchResults = results
    }
    
    /// Updates search query and resets selection
    func updateQuery(_ query: String) {
        searchQuery = query
        updateSearchResults()
        selectedGroupIndex = 0
        selectedWindowIndex = nil
    }
    
    /// Returns the exact WindowItem selected, or nil if a group header (with multiple windows) is selected
    func getSelectedWindowItem() -> WindowItem? {
        if !searchQuery.isEmpty {
            guard selectedGroupIndex < searchResults.count else { return nil }
            switch searchResults[selectedGroupIndex] {
            case .window(let w): return w
            case .group(let g): return g.windows.first
            }
        }
        
        guard selectedGroupIndex < groups.count else { return nil }
        let group = groups[selectedGroupIndex]
        
        if let wIndex = selectedWindowIndex {
            guard wIndex < group.windows.count else { return nil }
            return group.windows[wIndex]
        }

        return group.windows.first
    }
    
    // MARK: - Keyboard Controls
    
    func moveSelectionDown() {
        if searchQuery.isEmpty {
            // Grouped view navigation
            guard !groups.isEmpty else { return }
            let group = groups[selectedGroupIndex]
            let isExpanded = expandedGroupIds.contains(group.id) && group.windows.count > 1
            
            if isExpanded {
                let windowsCount = group.windows.count
                if let winIndex = selectedWindowIndex {
                    if winIndex < windowsCount - 1 {
                        selectedWindowIndex = winIndex + 1
                    } else {
                        // Move past windows to the next group header and collapse the left group
                        selectedWindowIndex = nil
                        expandedGroupIds.remove(group.id)
                        if selectedGroupIndex < groups.count - 1 {
                            selectedGroupIndex += 1
                        } else {
                            selectedGroupIndex = 0
                        }
                    }
                } else {
                    // Enter window list of expanded group
                    selectedWindowIndex = 0
                }
            } else {
                // Move to next group header
                selectedWindowIndex = nil
                if selectedGroupIndex < groups.count - 1 {
                    selectedGroupIndex += 1
                } else {
                    selectedGroupIndex = 0
                }
            }
        } else {
            // Flat results list navigation
            guard !searchResults.isEmpty else { return }
            if selectedGroupIndex < searchResults.count - 1 {
                selectedGroupIndex += 1
            } else {
                selectedGroupIndex = 0
            }
        }
    }
    
    func moveSelectionUp() {
        if searchQuery.isEmpty {
            // Grouped view navigation
            guard !groups.isEmpty else { return }
            
            if let winIndex = selectedWindowIndex {
                if winIndex > 0 {
                    selectedWindowIndex = winIndex - 1
                } else {
                    // Move to group header itself
                    selectedWindowIndex = nil
                }
            } else {
                // Collapse the current group as we navigate out of it
                let group = groups[selectedGroupIndex]
                expandedGroupIds.remove(group.id)
                
                // Move to previous group
                if selectedGroupIndex > 0 {
                    selectedGroupIndex -= 1
                    let prevGroup = groups[selectedGroupIndex]
                    if prevGroup.windows.count > 1 && expandedGroupIds.contains(prevGroup.id) {
                        // Highlight the last window of the expanded previous group
                        selectedWindowIndex = prevGroup.windows.count - 1
                    } else {
                        selectedWindowIndex = nil
                    }
                } else {
                    // Wrap to bottom group
                    selectedGroupIndex = groups.count - 1
                    let lastGroup = groups[selectedGroupIndex]
                    if lastGroup.windows.count > 1 && expandedGroupIds.contains(lastGroup.id) {
                        selectedWindowIndex = lastGroup.windows.count - 1
                    } else {
                        selectedWindowIndex = nil
                    }
                }
            }
        } else {
            // Flat results list navigation
            guard !searchResults.isEmpty else { return }
            if selectedGroupIndex > 0 {
                selectedGroupIndex -= 1
            } else {
                selectedGroupIndex = searchResults.count - 1
            }
        }
    }
    
    func expandGroup() {
        guard searchQuery.isEmpty, !groups.isEmpty else { return }
        let group = groups[selectedGroupIndex]
        let bundleId = group.appBundleId ?? ""
        let isBrowser = WindowManager.shared.isBrowser(bundleId: bundleId)
        let hasPermission = isBrowser ? WindowManager.shared.checkAutomationPermission(bundleIdentifier: bundleId, prompt: false) : true

        // Browser we can't yet read tabs from: explicitly request Automation permission.
        // This surfaces the macOS consent dialog (or, if previously denied, routes the user to
        // the Automation settings pane, since macOS won't re-prompt after a denial).
        if isBrowser && !hasPermission {
            let groupId = group.id
            let browserName = group.appName
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let granted = WindowManager.shared.requestBrowserAutomation(bundleId: bundleId, browserName: browserName)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if granted {
                        self.expandedGroupIds.insert(groupId)
                        self.selectedWindowIndex = 0
                        self.refreshWindows()
                    } else {
                        NotificationCenter.default.post(
                            name: .browserAutomationDenied,
                            object: nil,
                            userInfo: ["browser": browserName]
                        )
                    }
                }
            }
            return
        }

        guard group.windows.count > 1 else { return }
        expandedGroupIds.insert(group.id)
        selectedWindowIndex = 0
        // Tabs are already fetched for browsers with Automation permission (checkAutomationPermission
        // causes collectWindowGroups to fetch regardless of expandedGroupIds). Calling refreshWindows
        // here would cancel in-flight thumbnails and cause a visible "No Preview" flash.
    }
    
    func collapseGroup() {
        guard searchQuery.isEmpty, !groups.isEmpty else { return }
        let group = groups[selectedGroupIndex]
        let isBrowser = WindowManager.shared.isBrowser(bundleId: group.appBundleId ?? "")
        let hasPermission = isBrowser ? WindowManager.shared.checkAutomationPermission(bundleIdentifier: group.appBundleId ?? "", prompt: false) : true
        
        guard group.windows.count > 1 || (isBrowser && !hasPermission) else { return }
        
        let groupId = group.id
        if expandedGroupIds.contains(groupId) {
            expandedGroupIds.remove(groupId)
            selectedWindowIndex = nil
            
            if isBrowser {
                refreshWindows()
            }
        }
    }
    
    func toggleGroupExpansion(groupId: String) {
        let isBrowser = WindowManager.shared.isBrowser(bundleId: groupId)
        if expandedGroupIds.contains(groupId) {
            expandedGroupIds.remove(groupId)
            if isBrowser {
                refreshWindows()
            }
        } else {
            expandedGroupIds.insert(groupId)
            if isBrowser {
                refreshWindows()
            }
        }
    }
    
    /// Activates and focuses the currently selected window/group.
    /// Returns true if focus succeeded.
    @discardableResult
    func selectAndFocus() -> Bool {
        var targetWindow: WindowItem? = nil
        
        if searchQuery.isEmpty {
            guard !groups.isEmpty && selectedGroupIndex < groups.count else { return false }
            let group = groups[selectedGroupIndex]
            if let winIndex = selectedWindowIndex, winIndex < group.windows.count {
                targetWindow = group.windows[winIndex]
            } else {
                targetWindow = group.mostRecentWindow
            }
        } else {
            guard !searchResults.isEmpty && selectedGroupIndex < searchResults.count else { return false }
            let item = searchResults[selectedGroupIndex]
            switch item {
            case .group(let g):
                targetWindow = g.mostRecentWindow
            case .window(let w):
                targetWindow = w
            }
        }
        
        guard let window = targetWindow else { return false }
        
        // Record focus history timestamp
        focusHistory[window.id] = Date()
        

        
        // Activate/raise window via WindowManager
        return WindowManager.shared.focus(windowItem: window)
    }
    
    /// Direct focus action (e.g. mouse click)
    @discardableResult
    func focusWindowDirectly(_ window: WindowItem) -> Bool {
        focusHistory[window.id] = Date()

        return WindowManager.shared.focus(windowItem: window)
    }
    
    /// Closes every window in the currently selected group, regardless of expanded state.
    func closeSelectedGroup() {
        guard searchQuery.isEmpty, selectedGroupIndex < groups.count else { return }
        let group = groups[selectedGroupIndex]

        var closedAny = false
        for window in group.windows {
            if WindowManager.shared.close(windowItem: window) { closedAny = true }
        }
        guard closedAny else { return }

        expandedGroupIds.remove(group.id)
        groups.remove(at: selectedGroupIndex)
        if selectedGroupIndex >= groups.count {
            selectedGroupIndex = max(0, groups.count - 1)
        }
        selectedWindowIndex = nil
    }

    /// Closes the currently selected window and updates the UI state
    func closeSelectedWindow() {
        // If a multi-window group header is selected (collapsed or on the header row),
        // close the whole group rather than a single window.
        if searchQuery.isEmpty,
           selectedWindowIndex == nil,
           selectedGroupIndex < groups.count,
           groups[selectedGroupIndex].windows.count > 1 {
            closeSelectedGroup()
            return
        }

        guard let windowToClose = getSelectedWindowItem() else { return }

        let success = WindowManager.shared.close(windowItem: windowToClose)
        guard success else { return }

        // Remove from the main groups model
        for i in (0..<groups.count).reversed() {
            groups[i].windows.removeAll(where: { $0.id == windowToClose.id })
            if groups[i].windows.isEmpty {
                groups.remove(at: i)
                if searchQuery.isEmpty {
                    if selectedGroupIndex > i {
                        selectedGroupIndex -= 1
                    } else if selectedGroupIndex == i {
                        selectedGroupIndex = max(0, i - 1)
                    }
                }
            }
        }

        // Re-derive search results from updated groups (fixes stale results in search mode)
        if !searchQuery.isEmpty {
            updateSearchResults()
            if selectedGroupIndex >= searchResults.count {
                selectedGroupIndex = max(0, searchResults.count - 1)
            }
            selectedWindowIndex = nil
            return
        }

        // Re-adjust window index in grouped view
        if selectedGroupIndex < groups.count {
            let group = groups[selectedGroupIndex]
            if let wIdx = selectedWindowIndex, wIdx >= group.windows.count {
                selectedWindowIndex = group.windows.isEmpty ? nil : group.windows.count - 1
            }
        } else if groups.isEmpty {
            selectedGroupIndex = 0
            selectedWindowIndex = nil
        }
    }
}

enum SearchResultItem: Identifiable, Hashable {
    case group(WindowGroup)
    case window(WindowItem)
    
    var id: String {
        switch self {
        case .group(let g): return "g_" + g.id
        case .window(let w): return "w_" + w.id
        }
    }
}
