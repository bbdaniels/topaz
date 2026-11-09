//! fn dictation in every app (Ben, 2026-11-08: "start dictation everywhere
//! now too"). One listen-only event tap, on a thread of its own with its own
//! run loop, hears fn in whatever app is frontmost, so the Topaz window's
//! own fn detector is gone and fn is heard once. Listen-only, it never holds
//! a keystroke back, and on its own thread a busy GUI thread cannot slow it.
//! At fn down the frontmost app decides the sink (keys.rs, `target_for`):
//! Topaz's focused pane through the mux, or keyboard events posted to the
//! other app. One session runs at a time, process wide.
//!
//! The tap also hears every key and mouse button pressed from fn down until
//! the final text is typed; any of them cancels the session, as a key in
//! Topaz's window always did, so nothing is typed after Ben's own input or
//! where a click moved the caret. The events Topaz posts carry
//! `POSTED_BY_TOPAZ` in their source user data and are not taken for Ben's.
//!
//! Permissions (each asked for once, with a stable signature): the tap needs
//! Input Monitoring, asked for when the tap starts (Topaz's launch with
//! config.fn_dictation on); posting needs Accessibility, asked for at the
//! first hold of fn in another app.

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
const K_CG_SESSION_EVENT_TAP: u32 = 1;
const K_CG_HEAD_INSERT_EVENT_TAP: u32 = 0;
const K_CG_EVENT_TAP_OPTION_LISTEN_ONLY: u32 = 1;
const K_CG_EVENT_SOURCE_STATE_PRIVATE: i32 = -1;
const K_CG_KEYBOARD_EVENT_KEYCODE: u32 = 9;
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
                K_CG_SESSION_EVENT_TAP,
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
                    fn_pressed(Instant::now());
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

/// fn went down, at `pressed`, on the tap's thread.
fn fn_pressed(pressed: Instant) {
    let config = config::configuration();
    if !config.fn_dictation {
        return;
    }
    log::info!("fn dictation timing: +0 ms fn press received");
    let target = keys::target_for(frontmost_pid(), std::process::id() as i32, secure_input());
    match target {
        Target::Nowhere => {
            log::info!("fn dictation: no app is frontmost");
            return;
        }
        Target::SecureInput => {
            log::info!("fn dictation: secure input is on; nothing typed");
            notice(SECURE_INPUT_NOTICE.to_string());
            return;
        }
        Target::App(_) if !unsafe { CGPreflightPostEventAccess() } => {
            log::warn!("fn dictation: Topaz has no Accessibility permission; asking");
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
    dictation().fn_down(move || Some(super::start(target, keyterms, pressed)));
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

/// A brief notice when Topaz is not frontmost: a notification that closes
/// itself.
pub fn notice(message: String) {
    wezterm_toast_notification::show(wezterm_toast_notification::ToastNotification {
        title: "Topaz".to_string(),
        message,
        url: None,
        timeout: Some(Duration::from_secs(5)),
    });
}

/// Keyboard events into the frontmost app, from a private event source, so
/// that fn, still held, adds no modifier; their flags are set empty all the
/// same, or a Backspace with fn's flag would delete forward.
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
    fn frontmost(&self) -> Option<i32> {
        frontmost_pid()
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
