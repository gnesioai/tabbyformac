import SwiftUI

struct PreferencesView: View {
    @ObservedObject var prefs = AppPreferences.shared
    @ObservedObject var state: SwitcherState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section: Shortcut Configuration
            VStack(alignment: .leading, spacing: 8) {
                Text("Global Shortcut")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
                
                HStack(spacing: 12) {
                    Text("Trigger Hotkey:")
                        .font(.system(size: 12))
                    
                    Picker("", selection: $prefs.shortcutPreset) {
                        ForEach(ShortcutPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }
                
                Text("This shortcut opens the switcher overlay. Pressing it repeatedly while the overlay is open cycles down the application list.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineSpacing(2)
            }
            
            Divider()
            
            // Section: App Behavior Configuration
            VStack(alignment: .leading, spacing: 8) {
                Text("Application Behavior")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
                
                Toggle("Launch Tabby at login", isOn: $prefs.launchAtLogin)
                    .font(.system(size: 12))
                
                Toggle("Show application icon in Dock", isOn: $prefs.showInDock)
                    .font(.system(size: 12))
                
                Text("Hiding the Dock icon runs Tabby as a background agent app (controlled exclusively via the menu bar icon \(Image(systemName: "square.3.layers.3d.down.forward")) and your hotkey).")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineSpacing(2)
            }
            
            Divider()
            
            // Section: System Permissions
            VStack(alignment: .leading, spacing: 8) {
                Text("System Permissions")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
                
                VStack(spacing: 8) {
                    PermissionCard(
                        icon: "hand.raised.fill",
                        iconColor: .blue,
                        title: "Accessibility",
                        subtitle: "Required to discover windows and switch focus",
                        isGranted: state.hasPermission,
                        action: { state.requestPermission() }
                    )
                    
                    PermissionCard(
                        icon: "rectangle.inset.filled.and.cursorarrow",
                        iconColor: .purple,
                        title: "Screen Recording",
                        subtitle: "Required to capture window previews",
                        isGranted: state.hasScreenRecording,
                        action: { state.requestScreenRecording() }
                    )
                }
            }
            
            Divider()
            
            // Footer
            VStack(spacing: 4) {
                Text("Tabby v1.0")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                
                Text("Switch apps fast, pick windows precisely.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
                
                Button(action: {
                    if let url = URL(string: "https://paypal.me/") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "dollarsign.circle.fill")
                        Text("Donate via PayPal")
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.link)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct PreferencesView_Previews: PreviewProvider {
    static var previews: some View {
        PreferencesView(state: SwitcherState())
    }
}
