import Carbon.HIToolbox

/// The launcher's global chords, through Carbon's `RegisterEventHotKey`: it
/// needs no permission, consumes the chord, and is delivered on the main run
/// loop with no event tap in the way of other keystrokes (the plan's
/// anti-goal). One application event handler serves every chord; it finds
/// the action by the hot key's id.
///
/// The handler is a C function given this object as unretained user data,
/// so the center must outlive it: `deinit` removes the handler and releases
/// every chord before the object goes.
final class HotKeyCenter {
    static let signature: OSType = 0x5450_4C4E // 'TPLN'

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?
    /// noErr once the handler is installed.
    private(set) var installStatus: OSStatus = noErr

    init(target: EventTargetRef = GetApplicationEventTarget()) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        var installed: EventHandlerRef?
        installStatus = InstallEventHandler(target, HotKeyCenter.dispatch, 1, &spec, me, &installed)
        handler = installed
    }

    private static let dispatch: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        let read = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                     EventParamType(typeEventHotKeyID), nil,
                                     MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard read == noErr, id.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
        let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
        return center.fire(id.id) ? noErr : OSStatus(eventNotHandledErr)
    }

    deinit {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Adds `action` under a new id, without binding a chord to it yet.
    func add(_ action: @escaping () -> Void) -> UInt32 {
        let id = nextID
        nextID += 1
        actions[id] = action
        return id
    }

    /// Binds `keyCode` with Carbon `modifiers` to `action`; the id, or the
    /// status Carbon refused it with (eventHotKeyExistsErr when another app
    /// holds the chord).
    func register(keyCode: UInt32, modifiers: UInt32, _ action: @escaping () -> Void) -> Result<UInt32, OSStatusError> {
        let id = add(action)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            actions[id] = nil
            return .failure(OSStatusError(status: status))
        }
        refs[id] = ref
        return .success(id)
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }

    /// Runs the action for `id`; false if there is none.
    @discardableResult
    func fire(_ id: UInt32) -> Bool {
        guard let action = actions[id] else { return false }
        action()
        return true
    }
}

struct OSStatusError: Error, Equatable {
    let status: OSStatus
}
