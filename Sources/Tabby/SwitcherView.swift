import SwiftUI
import AppKit

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct SwitcherView: View {
    @ObservedObject var state: SwitcherState
    @FocusState private var isSearchFocused: Bool

    // Overall switcher size, scaled to the active screen by SwitcherWindow.
    var width: CGFloat = 800
    var height: CGFloat = 480
    // Preview pane gets the larger share so window screenshots read clearly.
    private var listWidth: CGFloat { (width * 0.42).rounded() }
    private var previewWidth: CGFloat { width - listWidth }

    var body: some View {
        HStack(spacing: 0) {
            // Left Pane (Search and List)
            VStack(spacing: 0) {
                // Search Input Header
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.secondary)
                    
                    TextField("Search apps or windows...", text: Binding(
                        get: { state.searchQuery },
                        set: { state.updateQuery($0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(.primary)
                    .focused($isSearchFocused)
                    
                    if !state.searchQuery.isEmpty {
                        Button(action: {
                            state.updateQuery("")
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                
                Divider()
                    .background(Color(NSColor.separatorColor))
                
                // Content Area
                if state.groups.isEmpty {
                    if state.isLoading {
                        LoadingStateView()
                    } else {
                        EmptyStateView(title: "No open windows", subtitle: "Open apps with standard windows to see them here.")
                    }
                } else if !state.searchQuery.isEmpty && state.searchResults.isEmpty {
                    EmptyStateView(title: "No matches found", subtitle: "Try searching for a different application or window title.")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 4) {
                                if state.searchQuery.isEmpty {
                                    GroupedList(state: state)
                                } else {
                                    FlatSearchList(state: state)
                                }
                            }
                            .padding(8)
                        }
                        .onChange(of: state.selectedGroupIndex) { _ in
                            scrollToSelected(proxy: proxy)
                        }
                        .onChange(of: state.selectedWindowIndex) { _ in
                            scrollToSelected(proxy: proxy)
                        }
                    }
                }
            }
            .frame(width: listWidth)

            // Right Pane (Preview)
            Divider()
                .background(Color(NSColor.separatorColor))

            PreviewPane(state: state)
                .id(state.getSelectedWindowItem()?.id ?? "none")
                .frame(width: previewWidth)
                .frame(maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.3))
        }
        .frame(width: width, height: height)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
        )
        .onAppear {
            isSearchFocused = true
            // Ensure search is focused whenever the view appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
            }
        }
    }
    
    private func scrollToSelected(proxy: ScrollViewProxy) {
        if state.searchQuery.isEmpty {
            if let winIdx = state.selectedWindowIndex {
                let targetId = "w_\(state.groups[state.selectedGroupIndex].id)_\(winIdx)"
                proxy.scrollTo(targetId, anchor: .center)
            } else if state.selectedGroupIndex < state.groups.count {
                let targetId = "g_\(state.groups[state.selectedGroupIndex].id)"
                proxy.scrollTo(targetId, anchor: .center)
            }
        } else {
            if state.selectedGroupIndex < state.searchResults.count {
                let targetId = state.searchResults[state.selectedGroupIndex].id
                proxy.scrollTo(targetId, anchor: .center)
            }
        }
    }
}

// MARK: - Preview Pane
struct PreviewPane: View {
    @ObservedObject var state: SwitcherState
    
    // Show a preview whenever there's a window to preview — including a group header,
    // which defaults to the group's most recent window.
    var isExactWindowSelected: Bool {
        return state.getSelectedWindowItem() != nil
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack {
                if isExactWindowSelected, let window = state.getSelectedWindowItem() {
                    VStack(spacing: 20) {
                        if let thumb = window.thumbnail {
                            Image(nsImage: thumb)
                                .resizable()
                                .scaledToFit()
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
                                )
                                .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
                                .padding(.horizontal, 20)
                                .id(window.id)
                        } else if state.thumbnailsLoading {
                            VStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.regular)
                                Text("Loading Preview…")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if window.isTab {
                            // Background tabs share one OS window with the visible tab and have no
                            // capturable pixels. Show the tab's site instead of a fake screenshot.
                            VStack(spacing: 10) {
                                Image(systemName: "globe")
                                    .font(.system(size: 36))
                                    .foregroundColor(.secondary.opacity(0.6))
                                if let host = window.tabUrl.flatMap({ URL(string: $0)?.host }) {
                                    Text(host)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Text("Background tab")
                                    .font(.caption2)
                                    .foregroundColor(.secondary.opacity(0.7))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "photo.slash")
                                    .font(.system(size: 32))
                                    .foregroundColor(.secondary.opacity(0.5))
                                Text("No Preview Available")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        
                        VStack(spacing: 4) {
                            Text(window.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                            
                            Text(window.appName)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                    }
                    .padding(.top, 30)
                } else if state.selectedGroupIndex < state.groups.count {
                    let group = state.groups[state.selectedGroupIndex]
                    VStack(spacing: 16) {
                        if let icon = group.appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 80, height: 80)
                                .shadow(color: Color.black.opacity(0.2), radius: 6, x: 0, y: 3)
                        }
                        
                        VStack(spacing: 4) {
                            Text(group.appName)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.primary)
                            
                            Text("\(group.windows.count) windows")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        
                        Text("Select a window to preview")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary.opacity(0.7))
                            .padding(.top, 8)
                    }
                    .padding(.top, 40)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 36)
            
            // Bottom Shortcut Bar
            HStack {
                Spacer()
                HStack(spacing: 10) {
                    ShortcutHint(keys: ["→", "/", "~"], action: "Expand")
                    ShortcutHint(keys: ["return"], action: "Focus")
                    ShortcutHint(keys: ["W"], action: "Close")
                    ShortcutHint(keys: ["esc"], action: "Cancel")
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.55))
        }
        .overlay(
            HStack(spacing: 8) {
                // Visible way to reach Preferences when the menu bar icon is missing.
                Button(action: { (NSApp.delegate as? AppDelegate)?.showPreferencesWindow() }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")

                Text("Tabby")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary.opacity(0.4))
            }
            .padding(12),
            alignment: .topTrailing
        )
    }
}

struct KeyCap: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
            .foregroundColor(.primary)
    }
}

struct ShortcutHint: View {
    let keys: [String]
    let action: String
    
    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    if key == "/" {
                        Text("/")
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: true)
                            .foregroundColor(.secondary)
                    } else {
                        KeyCap(text: key)
                    }
                }
            }
            
            Text(action)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
                .foregroundColor(.secondary)
        }
    }
}


// MARK: - Close Button
struct CloseWindowButton: View {
    let isRowSelected: Bool
    let isRowHovered: Bool   // controlled by parent row's onHover
    let action: () -> Void
    @State private var isButtonHovered = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(isRowSelected ? .white.opacity(0.9) : .secondary)
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(isRowSelected
                              ? Color.white.opacity(isButtonHovered ? 0.35 : 0.18)
                              : Color.secondary.opacity(isButtonHovered ? 0.3 : 0.15))
                )
        }
        .buttonStyle(.plain)
        .opacity(isRowHovered || isRowSelected ? 1.0 : 0.4)
        .onHover { h in withAnimation(.easeInOut(duration: 0.1)) { isButtonHovered = h } }
        .help("Close window (⌘W)")
    }
}

// MARK: - Row Subviews (need @State for hover tracking)

func formatRelativeTime(date: Date?) -> String? {
    guard let date = date else { return nil }
    let now = Date()
    let diff = now.timeIntervalSince(date)
    
    // Ignore items focused in the last 10 seconds to avoid cluttering active contexts
    if diff < 10 {
        return nil
    }
    
    let seconds = Int(diff)
    if seconds < 60 {
        return "\(seconds)s ago"
    }
    
    let minutes = seconds / 60
    if minutes < 60 {
        return "\(minutes)m ago"
    }
    
    let hours = minutes / 60
    if hours < 24 {
        return "\(hours)h ago"
    }
    
    let days = hours / 24
    return "\(days)d ago"
}

struct SingleWindowRow: View {
    let window: WindowItem
    let group: WindowGroup
    let isSelected: Bool
    let onTap: () -> Void
    let onClose: () -> Void
    @State private var isRowHovered = false
    var body: some View {
        HStack(spacing: 12) {
            if let icon = group.appIcon {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 24, height: 24)
            } else {
                Image(systemName: "app.fill").font(.system(size: 20)).foregroundColor(.secondary).frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(window.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1).truncationMode(.tail)
                
                if window.isTab, let url = window.tabUrl, !url.isEmpty {
                    let displayUrl = URL(string: url)?.host ?? url
                    Text("\(group.appName) • \(displayUrl)")
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1).truncationMode(.tail)
                } else {
                    Text(group.appName)
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }
            }
            Spacer()
            if let relativeTime = formatRelativeTime(date: window.lastFocusedAt) {
                Text(relativeTime)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary.opacity(0.8))
                    .padding(.horizontal, 4)
            }
            if window.isMinimized {
                Text("Minimized")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(isSelected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15))
                    .cornerRadius(4)
                    .foregroundColor(isSelected ? .white : .secondary)
            }
            CloseWindowButton(isRowSelected: isSelected, isRowHovered: isRowHovered, action: onClose)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor : Color.clear))
        .foregroundColor(isSelected ? .white : .primary)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { isRowHovered = h } }
        .onTapGesture(perform: onTap)
    }
}

struct ExpandedWindowRow: View {
    let window: WindowItem
    let isSelected: Bool
    let onTap: () -> Void
    let onClose: () -> Void
    @State private var isRowHovered = false
    var body: some View {
        HStack(spacing: 12) {
            if window.isTab {
                Image(systemName: "globe")
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                    .padding(.leading, 12)
            } else {
                Circle()
                    .fill(isSelected ? Color.white.opacity(0.8) : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6).padding(.leading, 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(window.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1).truncationMode(.tail)
                
                if window.isTab, let url = window.tabUrl, !url.isEmpty {
                    let displayUrl = URL(string: url)?.host ?? url
                    Text(displayUrl)
                        .font(.system(size: 10))
                        .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                
                if window.isMinimized {
                    Text("Minimized")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary.opacity(0.8))
                }
            }
            Spacer()
            if let relativeTime = formatRelativeTime(date: window.lastFocusedAt) {
                Text(relativeTime)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary.opacity(0.8))
                    .padding(.horizontal, 4)
            }
            CloseWindowButton(isRowSelected: isSelected, isRowHovered: isRowHovered, action: onClose)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.85) : Color.clear))
        .foregroundColor(isSelected ? .white : .primary)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { isRowHovered = h } }
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Grouped View List
struct GroupedList: View {
    @ObservedObject var state: SwitcherState
    
    var body: some View {
        ForEach(0..<state.groups.count, id: \.self) { gIndex in
            let group = state.groups[gIndex]
            let isSelected = (state.selectedGroupIndex == gIndex && state.selectedWindowIndex == nil)
            let isBrowser = WindowManager.shared.isBrowser(bundleId: group.appBundleId ?? "")
            let hasPermission = isBrowser ? WindowManager.shared.checkAutomationPermission(bundleIdentifier: group.appBundleId ?? "", prompt: false) : true
            let isExpanded = state.expandedGroupIds.contains(group.id) && (group.windows.count > 1 || isBrowser)
            
            VStack(spacing: 2) {
                if group.windows.count == 1 && !(isBrowser && !hasPermission) {
                    let window = group.windows[0]
                    SingleWindowRow(
                        window: window,
                        group: group,
                        isSelected: isSelected,
                        onTap: {
                            state.selectedGroupIndex = gIndex
                            state.selectedWindowIndex = nil
                            state.focusWindowDirectly(window)
                            NSApp.sendAction(#selector(NSWindow.orderOut(_:)), to: nil, from: nil)
                        },
                        onClose: {
                            state.selectedGroupIndex = gIndex
                            state.selectedWindowIndex = nil
                            state.closeSelectedWindow()
                        }
                    )
                    .id("g_\(group.id)")
                } else {
                    // Group Header Row (Multi-window app)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            if let icon = group.appIcon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 24, height: 24)
                            } else {
                                Image(systemName: "app.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.secondary)
                                    .frame(width: 24, height: 24)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(group.appName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(isSelected ? .white : .primary)
                                    
                                    Text("(\(group.windows.count))")
                                        .font(.system(size: 12))
                                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                                }
                                
                                if let recentWin = group.mostRecentWindow {
                                    Text(recentWin.title)
                                        .font(.system(size: 12))
                                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                            
                            Spacer()
                            
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                                .padding(.trailing, 8)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.accentColor : Color.clear)
                    )
                    .foregroundColor(isSelected ? .white : .primary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.selectedGroupIndex = gIndex
                        state.selectedWindowIndex = nil
                        state.toggleGroupExpansion(groupId: group.id)
                    }
                    .id("g_\(group.id)")
                    
                    // Group Windows List (expanded)
                    if isExpanded {
                        ForEach(0..<group.windows.count, id: \.self) { wIndex in
                            let window = group.windows[wIndex]
                            let isWinSelected = (state.selectedGroupIndex == gIndex && state.selectedWindowIndex == wIndex)
                            
                            ExpandedWindowRow(
                                window: window,
                                isSelected: isWinSelected,
                                onTap: {
                                    state.selectedGroupIndex = gIndex
                                    state.selectedWindowIndex = wIndex
                                    state.focusWindowDirectly(window)
                                    NSApp.sendAction(#selector(NSWindow.orderOut(_:)), to: nil, from: nil)
                                },
                                onClose: {
                                    state.selectedGroupIndex = gIndex
                                    state.selectedWindowIndex = wIndex
                                    state.closeSelectedWindow()
                                }
                            )
                            .id("w_\(group.id)_\(wIndex)")
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
    }
}

// MARK: - Flat Search View List
struct SearchResultRow: View {
    let item: SearchResultItem
    let isSelected: Bool
    let onTap: () -> Void
    let onClose: () -> Void
    @State private var isRowHovered = false

    var body: some View {
        HStack(spacing: 12) {
            leadingIcon
            rowContent
            Spacer()
            
            if case .window(let window) = item,
               let relativeTime = formatRelativeTime(date: window.lastFocusedAt) {
                Text(relativeTime)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary.opacity(0.8))
                    .padding(.horizontal, 4)
            } else if case .group(let group) = item,
                      group.windows.count == 1,
                      let relativeTime = formatRelativeTime(date: group.windows[0].lastFocusedAt) {
                Text(relativeTime)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary.opacity(0.8))
                    .padding(.horizontal, 4)
            }
            
            trailingButtons
        }
        .id(item.id)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor : Color.clear))
        .foregroundColor(isSelected ? .white : .primary)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { isRowHovered = h } }
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder private var leadingIcon: some View {
        switch item {
        case .group(let group):
            if let icon = group.appIcon {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 24, height: 24)
            } else {
                Image(systemName: "app.fill").font(.system(size: 20)).foregroundColor(.secondary).frame(width: 24, height: 24)
            }
        case .window(let window):
            if window.isTab {
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundColor(isSelected ? .white : .secondary)
                    .frame(width: 20, height: 20)
            } else if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == window.processId }),
               let icon = app.icon {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 20, height: 20)
            } else {
                Image(systemName: "window.template").frame(width: 20, height: 20)
            }
        }
    }

    @ViewBuilder private var rowContent: some View {
        switch item {
        case .group(let group) where group.windows.count == 1:
            let window = group.windows[0]
            VStack(alignment: .leading, spacing: 2) {
                Text(window.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1).truncationMode(.tail)
                
                if window.isTab, let url = window.tabUrl, !url.isEmpty {
                    let displayUrl = URL(string: url)?.host ?? url
                    Text("\(group.appName) • \(displayUrl)")
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1).truncationMode(.tail)
                } else {
                    Text(group.appName)
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }
            }
        case .group(let group):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.appName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isSelected ? .white : .primary)
                    Text("(\(group.windows.count) windows)")
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }
                if let recentWin = group.mostRecentWindow {
                    Text("Jump to: \(recentWin.title)")
                        .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }
            }
        case .window(let window):
            VStack(alignment: .leading, spacing: 2) {
                Text(window.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1).truncationMode(.tail)
                
                if window.isTab, let url = window.tabUrl, !url.isEmpty {
                    let displayUrl = URL(string: url)?.host ?? url
                    Text("\(window.appName) • \(displayUrl)")
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1).truncationMode(.tail)
                } else {
                    Text(window.appName)
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }
            }
        }
    }

    @ViewBuilder private var trailingButtons: some View {
        switch item {
        case .group(let group) where group.windows.count == 1:
            let window = group.windows[0]
            if window.isMinimized {
                Text("Minimized")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(isSelected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15))
                    .cornerRadius(4).foregroundColor(isSelected ? .white : .secondary)
            }
            CloseWindowButton(isRowSelected: isSelected, isRowHovered: isRowHovered, action: onClose)
        case .group:
            CloseWindowButton(isRowSelected: isSelected, isRowHovered: isRowHovered, action: onClose)
        case .window(let window):
            if window.isMinimized {
                Text("Minimized")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(isSelected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15))
                    .cornerRadius(4).foregroundColor(isSelected ? .white : .secondary)
            }
            CloseWindowButton(isRowSelected: isSelected, isRowHovered: isRowHovered, action: onClose)
        }
    }
}

struct FlatSearchList: View {
    @ObservedObject var state: SwitcherState

    var body: some View {
        ForEach(0..<state.searchResults.count, id: \.self) { index in
            let item = state.searchResults[index]
            let isSelected = (state.selectedGroupIndex == index)
            SearchResultRow(
                item: item,
                isSelected: isSelected,
                onTap: {
                    state.selectedGroupIndex = index
                    state.selectedWindowIndex = nil
                    state.selectAndFocus()
                    NSApp.sendAction(#selector(NSWindow.orderOut(_:)), to: nil, from: nil)
                },
                onClose: {
                    state.selectedGroupIndex = index
                    state.selectedWindowIndex = nil
                    state.closeSelectedWindow()
                }
            )
        }
    }
}



// MARK: - Permission Card

struct PermissionCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let isGranted: Bool
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Status icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isGranted ? Color.green.opacity(0.15) : iconColor.opacity(0.12))
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: isGranted ? "checkmark.circle.fill" : icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(isGranted ? .green : iconColor)
                }
                
                // Text
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                        
                        if isGranted {
                            Text("Granted")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.15))
                                .cornerRadius(3)
                        }
                    }
                    
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // Action button or chevron
                if !isGranted {
                    Text("Allow")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            LinearGradient(
                                colors: [iconColor, iconColor.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(6)
                } else {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isGranted ? Color.green.opacity(isHovering ? 0.1 : 0.05) : Color(NSColor.controlBackgroundColor).opacity(isHovering ? 0.8 : 1.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isGranted ? Color.green.opacity(0.3) : Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isGranted)
    }
}

// MARK: - Empty States
struct EmptyStateView: View {
    let title: String
    let subtitle: String
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.top, 20)
            
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
            
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.vertical, 40)
    }
}

struct LoadingStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.regular)
                .padding(.top, 20)
            
            Text("Loading windows...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 40)
    }
}
