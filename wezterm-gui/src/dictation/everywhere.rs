//! fn dictation in every app (Ben, 2026-11-08: "start dictation everywhere
//! now too"). One listen-only event tap, on a thread of its own with its own
//! run loop, hears fn in whatever app has the keyboard, so the Topaz window's
//! own fn detector is gone and fn is heard once. Listen-only, it never holds
//! a keystroke back, and on its own thread a busy GUI thread cannot slow it.
//! At fn down the process that has the keyboard decides the sink (keys.rs,
//! `Focus` and `target_for`): Topaz's focused pane through the mux, or
//! keyboard events posted to the other app. Not the frontmost app: a menu bar
//! app's panel (Tot's) has the keyboard while Topaz stays in front, so the
//! tap sits where the system has already routed each event (the annotated
//! session tap) and reads the fn event's own target. One session runs at a
//! time, process wide.
//!
//! The tap also hears every key and mouse button pressed from fn down until
//! the final text is typed; any of them cancels the session, as a key in
//! Topaz's window always did, so nothing is typed after Ben's own input or
//! where a click moved the caret. The events Topaz posts carry
//! `POSTED_BY_TOPAZ` in their source user data and are not taken for Ben's.
//!
//! Permissions (with a stable signature): the tap needs Input Monitoring,
//! asked for when the tap starts (Topaz's launch with config.fn_dictation
//! on); posting needs Accessibility, read afresh at every press
//! (AXIsProcessTrusted, never kept) and asked for at a hold of fn in another
//! app while it is missing.

use super::control::Dictation;
use super::keys::{self, KeyAction, Poster, Target};
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

/// The one dictation of the process: fn down and up from the tap's thread,
/// cancels from there and from Topaz's windows.
static DICTATION: Mutex<Dictation> = Mutex::new(Dictation::new());

fn dictation() -> MutexGuard<'static, Dictation> {
    DICTATION
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// A key went down in a Topaz window, or one lost focus: type nothing more.
pub fn cancel() {
    dictation().cancel();
}

static TAP_STARTED: AtomicBool = AtomicBool::new(false);

/// Start the tap once config.fn_dictation is on, now or after a reload. The
/// tap is not started while it is off, so macOS asks for nothing.
pub fn start_if_enabled() {
    start_tap_if_enabled();
    // Kept for the life of the process: a later reload may turn it on.
    std::mem::forget(config::subscribe_to_config_reload(|| {
        start_tap_if_enabled();
        true
    }));
}

fn start_tap_if_enabled() {
    if !config::configuration().fn_dictation || TAP_STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    let spawned = std::thread::Builder::new()
        .name("fn-dictation-tap".to_string())
        .spawn(run_tap);
    if let Err(err) = spawned {
        log::error!("fn dictation: cannot start the event tap's thread: {err:#}");
        TAP_STARTED.store(false, Ordering::SeqCst);
    } else {
        super::warm_microphone();
    }
}

// CoreGraphics, CoreFoundation and Carbon, as declared in their headers.
type CGEventRef = *mut c_void;
type CGEventSourceRef = *mut c_void;
type CFMachPortRef = *mut c_void;
type CFRunLoopSourceRef = *mut c_void;
type CFRunLoopRef = *mut c_void;
type CFStringRef = *const c_void;
type CGEventTapCallBack = extern "C" fn(*mut c_void, u32, CGEventRef, *mut c_void) -> CGEventRef;

const K_CG_HID_EVENT_TAP: u32 = 0;
const K_CG_ANNOTATED_SESSION_EVENT_TAP: u32 = 2;
const K_CG_HEAD_INSERT_EVENT_TAP: u32 = 0;
const K_CG_EVENT_TAP_OPTION_LISTEN_ONLY: u32 = 1;
const K_CG_EVENT_SOURCE_STATE_PRIVATE: i32 = -1;
const K_CG_KEYBOARD_EVENT_KEYCODE: u32 = 9;
const K_CG_EVENT_TARGET_UNIX_PROCESS_ID: u32 = 40;
const K_CG_EVENT_SOURCE_USER_DATA: u32 = 42;

const LEFT_MOUSE_DOWN: u32 = 1;
const RIGHT_MOUSE_DOWN: u32 = 3;
const KEY_DOWN: u32 = 10;
const FLAGS_CHANGED: u32 = 12;
const OTHER_MOUSE_DOWN: u32 = 25;
const TAP_DISABLED_BY_TIMEOUT: u32 = 0xFFFF_FFFE;
const TAP_DISABLED_BY_USER_INPUT: u32 = 0xFFFF_FFFF;

/// The source user data of the events Topaz posts ("Topz").
const POSTED_BY_TOPAZ: i64 = 0x546F_707A;

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGEventTapCreate(
        tap: u32,
        place: u32,
        options: u32,
        events_of_interest: u64,
        callback: CGEventTapCallBack,
        user_info: *mut c_void,
    ) -> CFMachPortRef;
    fn CGEventTapEnable(tap: CFMachPortRef, enable: bool);
    fn CGEventGetFlags(event: CGEventRef) -> u64;
    fn CGEventSetFlags(event: CGEventRef, flags: u64);
    fn CGEventGetIntegerValueField(event: CGEventRef, field: u32) -> i64;
    fn CGEventSetIntegerValueField(event: CGEventRef, field: u32, value: i64);
    fn CGEventSourceCreate(state: i32) -> CGEventSourceRef;
    fn CGEventCreateKeyboardEvent(source: CGEventSourceRef, key: u16, key_down: bool)
        -> CGEventRef;
    fn CGEventKeyboardSetUnicodeString(event: CGEventRef, length: usize, string: *const u16);
    fn CGEventPost(tap: u32, event: CGEventRef);
    fn CGPreflightListenEventAccess() -> bool;
    fn CGRequestListenEventAccess() -> bool;
    fn CGPreflightPostEventAccess() -> bool;
    fn CGRequestPostEventAccess() -> bool;
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFMachPortCreateRunLoopSource(
        allocator: *const c_void,
        port: CFMachPortRef,
        order: isize,
    ) -> CFRunLoopSourceRef;
    fn CFRunLoopGetCurrent() -> CFRunLoopRef;
    fn CFRunLoopAddSource(run_loop: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFStringRef);
    fn CFRunLoopRun();
    fn CFRelease(cf: *const c_void);
    static kCFRunLoopCommonModes: CFStringRef;
}

#[link(name = "Carbon", kind = "framework")]
extern "C" {
    fn IsSecureEventInputEnabled() -> u8;
}

type AXUIElementRef = *const c_void;
const AX_SUCCESS: i32 = 0;
/// How long an Accessibility query may wait on the process it asks.
const AX_TIMEOUT_SECONDS: f32 = 0.25;

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrusted() -> u8;
    fn AXUIElementCreateSystemWide() -> AXUIElementRef;
    fn AXUIElementSetMessagingTimeout(element: AXUIElementRef, seconds: f32) -> i32;
    fn AXUIElementCopyAttributeValue(
        element: AXUIElementRef,
        attribute: CFStringRef,
        value: *mut *const c_void,
    ) -> i32;
    fn AXUIElementGetPid(element: AXUIElementRef, pid: *mut i32) -> i32;
}

fn mask(kind: u32) -> u64 {
    1 << kind
}

/// What the tap's callback keeps between events; it lives as long as the
/// tap's thread, which is the life of the process.
struct TapState {
    port: CFMachPortRef,
    fn_down: bool,
}

/// How long to wait before trying the tap again when macOS refuses it
/// (Input Monitoring not granted yet).
const TAP_RETRY: Duration = Duration::from_secs(5);

fn run_tap() {
    if !unsafe { CGPreflightListenEventAccess() } {
        log::warn!(
            "fn dictation: Topaz has no Input Monitoring permission; asking \
             (System Settings, Privacy & Security, Input Monitoring)"
        );
        unsafe { CGRequestListenEventAccess() };
    }
    let state = Box::into_raw(Box::new(TapState {
        port: std::ptr::null_mut(),
        fn_down: false,
    }));
    let events = mask(FLAGS_CHANGED)
        | mask(KEY_DOWN)
        | mask(LEFT_MOUSE_DOWN)
        | mask(RIGHT_MOUSE_DOWN)
        | mask(OTHER_MOUSE_DOWN);
    let mut refused = 0u32;
    let port = loop {
        let port = unsafe {
            CGEventTapCreate(
                K_CG_ANNOTATED_SESSION_EVENT_TAP,
                K_CG_HEAD_INSERT_EVENT_TAP,
                K_CG_EVENT_TAP_OPTION_LISTEN_ONLY,
                events,
                on_event,
                state.cast(),
            )
        };
        if !port.is_null() {
            break port;
        }
        if refused == 0 {
            log::error!(
                "fn dictation: macOS refused the event tap (Input Monitoring for \
                 Topaz is off); trying again every {TAP_RETRY:?}"
            );
        }
        refused += 1;
        std::thread::sleep(TAP_RETRY);
    };
    unsafe {
        (*state).port = port;
        let source = CFMachPortCreateRunLoopSource(std::ptr::null(), port, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
        CGEventTapEnable(port, true);
    }
    log::info!("fn dictation: listening for fn in every app");
    unsafe { CFRunLoopRun() };
    log::error!("fn dictation: the event tap's run loop ended");
}

extern "C" fn on_event(
    _proxy: *mut c_void,
    kind: u32,
    event: CGEventRef,
    user_info: *mut c_void,
) -> CGEventRef {
    // A panic must not unwind into CoreGraphics.
    let heard = std::panic::catch_unwind(|| {
        let state = unsafe { &mut *(user_info as *mut TapState) };
        on_event_inner(state, kind, event)
    });
    if heard.is_err() {
        log::error!("fn dictation: the event tap's callback panicked");
    }
    event
}

fn on_event_inner(state: &mut TapState, kind: u32, event: CGEventRef) {
    match kind {
        TAP_DISABLED_BY_TIMEOUT | TAP_DISABLED_BY_USER_INPUT => {
            log::warn!("fn dictation: the event tap was turned off ({kind:#x}); on again");
            unsafe { CGEventTapEnable(state.port, true) };
        }
        _ if unsafe { CGEventGetIntegerValueField(event, K_CG_EVENT_SOURCE_USER_DATA) }
            == POSTED_BY_TOPAZ => {}
        FLAGS_CHANGED => {
            let key_code =
                unsafe { CGEventGetIntegerValueField(event, K_CG_KEYBOARD_EVENT_KEYCODE) } as u16;
            let flags = unsafe { CGEventGetFlags(event) };
            let down = keys::function_key_after(state.fn_down, key_code, flags);
            if down != state.fn_down {
                state.fn_down = down;
                if down {
                    let target = unsafe {
                        CGEventGetIntegerValueField(event, K_CG_EVENT_TARGET_UNIX_PROCESS_ID)
                    };
                    fn_pressed(Instant::now(), (target > 0).then_some(target as i32));
                } else {
                    dictation().fn_up();
                }
            }
        }
        KEY_DOWN | LEFT_MOUSE_DOWN | RIGHT_MOUSE_DOWN | OTHER_MOUSE_DOWN => dictation().cancel(),
        _ => {}
    }
}

pub const SECURE_INPUT_NOTICE: &str = "fn dictation types nothing while a password \
     field (secure input) has the keyboard.";
const NO_ACCESSIBILITY_NOTICE: &str = "fn dictation in other apps needs Accessibility \
     for Topaz: System Settings, Privacy & Security, Accessibility. Then hold fn again.";

/// fn went down, at `pressed`, on the tap's thread; the system sent its
/// event to `event_target`.
fn fn_pressed(pressed: Instant, event_target: Option<i32>) {
    let config = config::configuration();
    if !config.fn_dictation {
        return;
    }
    log::info!("fn dictation timing: +0 ms fn press received");
    let (focus, trusted) = read_focus(event_target);
    let own = std::process::id() as i32;
    let target = keys::target_for(focus.owner(), own, secure_input());
    log::info!(
        "fn dictation: at the press, {target:?} (Topaz is {own}; the fn event went to \
         {:?}, the focused application is {:?}, the frontmost {:?}; \
         AXIsProcessTrusted {trusted}, CGPreflightPostEventAccess {})",
        focus.event_target,
        focus.focused_app,
        focus.frontmost,
        unsafe { CGPreflightPostEventAccess() }
    );
    match target {
        Target::Nowhere => {
            log::info!("fn dictation: no app has the keyboard; nothing typed");
            super::flash(pressed);
            return;
        }
        Target::SecureInput => {
            log::info!("fn dictation: secure input is on; nothing typed");
            super::flash(pressed);
            notice(SECURE_INPUT_NOTICE.to_string());
            return;
        }
        Target::App(pid) if !trusted => {
            log::warn!(
                "fn dictation: Topaz has no Accessibility permission at this press \
                 (AXIsProcessTrusted false), so nothing can be typed into {pid}; asking"
            );
            super::flash(pressed);
            // The request may show a dialog; it is made off the tap's thread.
            std::thread::spawn(|| unsafe {
                CGRequestPostEventAccess();
            });
            notice(NO_ACCESSIBILITY_NOTICE.to_string());
            return;
        }
        Target::Pane | Target::App(_) => {}
    }
    let keyterms = config.fn_dictation_keyterms.clone();
    let focus_at_press = focus.later();
    dictation().fn_down(move || Some(super::start(target, focus_at_press, keyterms, pressed)));
}

/// Who has the keyboard, read now (keys.rs `Focus`), and whether Topaz has
/// Accessibility, read afresh each time: the focused application is asked
/// for only when it does.
fn read_focus(event_target: Option<i32>) -> (keys::Focus, bool) {
    let trusted = unsafe { AXIsProcessTrusted() != 0 };
    let focus = keys::Focus {
        event_target,
        focused_app: if trusted { focused_app_pid() } else { None },
        frontmost: frontmost_pid(),
    };
    (focus, trusted)
}

/// The system-wide focused application's process id (Accessibility): the
/// process that has the keyboard, a panel's included.
fn focused_app_pid() -> Option<i32> {
    use objc2_foundation::NSString;
    let attribute = NSString::from_str("AXFocusedApplication");
    unsafe {
        let system = AXUIElementCreateSystemWide();
        if system.is_null() {
            return None;
        }
        AXUIElementSetMessagingTimeout(system, AX_TIMEOUT_SECONDS);
        let mut app: *const c_void = std::ptr::null();
        let copied = AXUIElementCopyAttributeValue(
            system,
            (&*attribute as *const NSString).cast(),
            &mut app,
        );
        CFRelease(system);
        if copied != AX_SUCCESS || app.is_null() {
            return None;
        }
        let mut pid = 0;
        let got = AXUIElementGetPid(app, &mut pid);
        CFRelease(app);
        (got == AX_SUCCESS && pid > 0).then_some(pid)
    }
}

/// The frontmost app's process id.
pub fn frontmost_pid() -> Option<i32> {
    use objc2::rc::autoreleasepool;
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    autoreleasepool(|_| unsafe {
        let workspace: *mut AnyObject = msg_send![class!(NSWorkspace), sharedWorkspace];
        if workspace.is_null() {
            return None;
        }
        let app: *mut AnyObject = msg_send![workspace, frontmostApplication];
        if app.is_null() {
            return None;
        }
        let pid: i32 = msg_send![app, processIdentifier];
        Some(pid)
    })
}

/// Whether secure input is on (a password field has the keyboard): no app
/// sees typed events then, and none are posted.
pub fn secure_input() -> bool {
    unsafe { IsSecureEventInputEnabled() != 0 }
}

/// A brief notice when the words would go to another app: a notification that closes
/// itself.
pub fn notice(message: String) {
    wezterm_toast_notification::show(wezterm_toast_notification::ToastNotification {
        title: "Topaz".to_string(),
        message,
        url: None,
        timeout: Some(Duration::from_secs(5)),
    });
}

/// Keyboard events into the app that has the keyboard, from a private event
/// source, so that fn, still held, adds no modifier; their flags are set
/// empty all the same, or a Backspace with fn's flag would delete forward.
pub struct EventPoster {
    source: CGEventSourceRef,
}

impl EventPoster {
    pub fn new() -> Self {
        Self {
            source: unsafe { CGEventSourceCreate(K_CG_EVENT_SOURCE_STATE_PRIVATE) },
        }
    }

    fn post_key(&self, key: u16, down: bool, text: Option<&[u16]>) {
        unsafe {
            let event = CGEventCreateKeyboardEvent(self.source, key, down);
            if event.is_null() {
                log::error!("fn dictation: cannot make a keyboard event");
                return;
            }
            if let Some(text) = text {
                CGEventKeyboardSetUnicodeString(event, text.len(), text.as_ptr());
            }
            CGEventSetFlags(event, 0);
            CGEventSetIntegerValueField(event, K_CG_EVENT_SOURCE_USER_DATA, POSTED_BY_TOPAZ);
            CGEventPost(K_CG_HID_EVENT_TAP, event);
            CFRelease(event.cast_const());
        }
    }
}

impl Drop for EventPoster {
    fn drop(&mut self) {
        if !self.source.is_null() {
            unsafe { CFRelease(self.source.cast_const()) };
        }
    }
}

impl Poster for EventPoster {
    fn focus(&self) -> Option<i32> {
        read_focus(None).0.later()
    }

    fn secure_input(&self) -> bool {
        secure_input()
    }

    fn post(&mut self, action: &KeyAction) {
        match action {
            KeyAction::Backspace => {
                // With the Delete character, as the key itself sends it: an
                // event made for key code 51 alone carries a backspace
                // character (0x08), which a text view did not delete with
                // when tried (2026-11-08).
                let delete = [keys::DELETE_CHARACTER];
                self.post_key(keys::BACKSPACE_KEY_CODE, true, Some(&delete));
                self.post_key(keys::BACKSPACE_KEY_CODE, false, Some(&delete));
            }
            KeyAction::Type(units) => {
                // Key code 0 carries the text; the text, not the key, is typed.
                self.post_key(0, true, Some(units));
                self.post_key(0, false, Some(units));
            }
        }
    }
}
