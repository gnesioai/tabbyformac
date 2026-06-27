import Carbon
import AppKit

class HotKeyManager {
    static let shared = HotKeyManager()
    
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onTrigger: ((Bool) -> Void)?
    
    var isWindowVisible: (() -> Bool)?
    var onTildeTriggered: (() -> Void)?
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    private init() {}
    
    /// Registers a global hotkey with a given key code and Carbon modifier flags.
    /// By default, registers Option + Tab (keyCode: 48, modifiers: optionKey).
    @discardableResult
    func register(keyCode: UInt32 = 48, modifiers: UInt32 = UInt32(optionKey), onTrigger: @escaping (Bool) -> Void) -> Bool {
        // Unregister existing hotkey/tap first
        unregister()
        
        self.onTrigger = onTrigger
        
        // If Command + Tab (keyCode 48, modifiers cmdKey), use EventTap
        if keyCode == 48 && modifiers == UInt32(cmdKey) {
            return registerEventTap(onTrigger: onTrigger)
        }
        
        // "STHK" in hex signature
        let hotKeyID = EventHotKeyID(signature: 0x5354484b, id: 1)
        
        // C-style callback bridge using userData pointer
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        
        let handlerResult = InstallEventHandler(
            GetApplicationEventTarget(),
            { (nextHandler, event, userData) -> OSStatus in
                guard let userData = userData, let event = event else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                
                // Read modifiers from event
                var modifiers: UInt32 = 0
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamKeyModifiers),
                    EventParamType(typeUInt32),
                    nil,
                    MemoryLayout<UInt32>.size,
                    nil,
                    &modifiers
                )
                
                let isShiftPressed = (status == noErr) && ((modifiers & UInt32(shiftKey)) != 0)
                
                // Dispatch to main queue for UI safety
                DispatchQueue.main.async {
                    manager.onTrigger?(isShiftPressed)
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPointer,
            &eventHandlerRef
        )
        
        guard handlerResult == noErr else {
            return false
        }
        
        let registerResult = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        guard registerResult == noErr else {
            return false
        }
        
        return true
    }
    
    private func registerEventTap(onTrigger: @escaping (Bool) -> Void) -> Bool {
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, userInfo) -> Unmanaged<CGEvent>? in
                guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                // Handle automatic tap disable (timeout from macOS)
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = manager.eventTap {
                        DispatchQueue.main.async {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }
                
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                
                // Tab keycode is 48
                if keyCode == 48 && flags.contains(.maskCommand) {
                    let isShiftPressed = flags.contains(.maskShift)
                    DispatchQueue.main.async {
                        manager.onTrigger?(isShiftPressed)
                    }
                    // Swallow the event!
                    return nil
                }
                
                // Intercept key next to 1 (50 or 10) with the preset's modifier
                let preset = AppPreferences.shared.shortcutPreset
                let nativeFlags = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
                if (keyCode == 50 || keyCode == 10) && preset.isModifierPressed(nativeFlags) {
                    if Thread.isMainThread {
                        if manager.isWindowVisible?() == true {
                            manager.onTildeTriggered?()
                            return nil // Swallow!
                        }
                    } else {
                        var isOpen = false
                        DispatchQueue.main.sync {
                            isOpen = manager.isWindowVisible?() == true
                        }
                        if isOpen {
                            DispatchQueue.main.async {
                                manager.onTildeTriggered?()
                            }
                            return nil // Swallow!
                        }
                    }
                }
                
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPointer
        ) else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .cmdTabTapFailed, object: nil)
            }
            return false
        }
        
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        
        self.eventTap = tap
        self.runLoopSource = source
        return true
    }
    
    private func unregisterEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            self.runLoopSource = nil
        }
    }
    
    /// Clean up registered hotkey and event handler
    func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef = eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        unregisterEventTap()
        onTrigger = nil
    }
    
    deinit {
        unregister()
    }
}
