//! The parts of fn dictation in every app that need no event tap, window or
//! microphone: the fn key's state from the system's flags-changed events,
//! where the words go (the pane when Topaz has the keyboard, else the app
//! that has it), and how an edit (typing.rs) becomes the keyboard events posted to
//! another app. Plain std, so these tests also run on their own:
//! `rustc --edition 2021 --test keys.rs && ./keys`.
//!
//! The diff is typing.rs's `edit_between`, the same for both sinks; this file
//! only turns its result into events: one Backspace (key code 51, carrying
//! the Delete character) per character to delete, then the text in chunks of
//! at most
//! `MAX_CHUNK_UTF16` UTF-16 units, the most CGEventKeyboardSetUnicodeString
//! reliably carries in one event.

/// kVK_Function, the fn (Globe) key.
pub const FN_KEY_CODE: u16 = 0x3F;
/// kCGEventFlagMaskSecondaryFn (NSEventModifierFlagFunction).
pub const FN_FLAG: u64 = 0x80_0000;
/// kVK_Delete, the key that deletes backward.
pub const BACKSPACE_KEY_CODE: u16 = 51;
/// The character that key sends (NSDeleteCharacter).
pub const DELETE_CHARACTER: u16 = 0x7F;
/// The most UTF-16 units one keyboard event carries.
pub const MAX_CHUNK_UTF16: usize = 20;

/// The fn key's state after a flags-changed event, from that key's own
/// events only: arrow, Home, End, Page and function keys carry the fn flag
/// too, so a modifier released while one of them is held shows the flag
/// although fn was never touched. While fn is down, its next event is the
/// release; while it is up, its event is a press only when the flag agrees,
/// so a release whose press the tap missed (the tap was off) is not taken
/// for a press.
pub fn function_key_after(was_down: bool, key_code: u16, flags: u64) -> bool {
    if key_code != FN_KEY_CODE {
        was_down
    } else if was_down {
        false
    } else {
        flags & FN_FLAG != 0
    }
}

/// Who has the keyboard at fn down, from three readings. The frontmost
/// app is not enough: a menu bar app's panel (Tot's, 2026-11-08) takes the
/// keyboard without its app coming to the front, and the app in front, Topaz
/// say, is not told (its window stays key in its own eyes, so wezterm's
/// window focus stays set too).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Focus {
    /// The process the fn event itself was sent to (kCGEventTargetUnixProcessID,
    /// set where the system has routed it, the annotated session tap): the
    /// process that receives keystrokes, a panel's included. None when unset.
    pub event_target: Option<i32>,
    /// The system-wide focused application (Accessibility), when Topaz is
    /// trusted.
    pub focused_app: Option<i32>,
    /// NSWorkspace's frontmost application.
    pub frontmost: Option<i32>,
}

impl Focus {
    /// The process that has the keyboard: the fn event's target when the
    /// system set it, else the focused application, else the frontmost.
    pub fn owner(&self) -> Option<i32> {
        self.event_target.or(self.focused_app).or(self.frontmost)
    }

    /// The reading that can be taken again later, without an event: what
    /// AppSink compares at each edit with the same reading at fn down.
    pub fn later(&self) -> Option<i32> {
        self.focused_app.or(self.frontmost)
    }
}

/// Where a hold of fn sends its words, decided at fn down.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Target {
    /// Topaz has the keyboard: its focused window's active pane, through the mux.
    Pane,
    /// Another app has the keyboard, the one with this process id: keyboard
    /// events.
    App(i32),
    /// Another app has the keyboard and secure input is on (a password
    /// field): nothing is typed, and a notice says why.
    SecureInput,
    /// No app has the keyboard: nothing.
    Nowhere,
}

/// The target for fn down, given the process that has the keyboard
/// (`Focus::owner`), Topaz's own and whether secure input is on. Secure input
/// does not stop the pane: typing there goes through the mux, not keyboard
/// events.
pub fn target_for(owner: Option<i32>, own: i32, secure_input: bool) -> Target {
    match owner {
        Some(pid) if pid == own => Target::Pane,
        Some(_) if secure_input => Target::SecureInput,
        Some(pid) => Target::App(pid),
        None => Target::Nowhere,
    }
}

/// One keyboard event pair (down and up) to post.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyAction {
    Backspace,
    /// Text carried by the event, as UTF-16, at most MAX_CHUNK_UTF16 units.
    Type(Vec<u16>),
}

/// `text` in chunks of at most `max` UTF-16 units, never splitting a
/// surrogate pair (a character outside the Basic Multilingual Plane).
pub fn utf16_chunks(text: &str, max: usize) -> Vec<Vec<u16>> {
    let max = max.max(2);
    let mut chunks = vec![];
    let mut chunk: Vec<u16> = vec![];
    let mut units = [0u16; 2];
    for c in text.chars() {
        let encoded = c.encode_utf16(&mut units);
        if chunk.len() + encoded.len() > max {
            chunks.push(std::mem::take(&mut chunk));
        }
        chunk.extend_from_slice(encoded);
    }
    if !chunk.is_empty() {
        chunks.push(chunk);
    }
    chunks
}

/// The events for an edit: its backspaces, then its text in chunks.
pub fn key_actions(backspaces: usize, text: &str) -> Vec<KeyAction> {
    std::iter::repeat(KeyAction::Backspace)
        .take(backspaces)
        .chain(
            utf16_chunks(text, MAX_CHUNK_UTF16)
                .into_iter()
                .map(KeyAction::Type),
        )
        .collect()
}

/// What the system offers the app sink: posting events, and the checks made
/// before each edit. Mocked in the tests.
pub trait Poster {
    /// Who has the keyboard now, read as `Focus::later` reads it.
    fn focus(&self) -> Option<i32>;
    /// Whether secure input is on (IsSecureEventInputEnabled).
    fn secure_input(&self) -> bool;
    fn post(&mut self, action: &KeyAction);
}

/// How an edit to another app went.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Applied {
    Typed,
    /// The session was cancelled first: nothing posted.
    Cancelled,
    /// Secure input came on (a password field took focus): nothing posted.
    SecureInput,
    /// The keyboard moved since fn down: nothing posted, so no backspace
    /// lands in an app whose text the dictation never typed.
    FocusMoved,
}

/// The app sink: the app that had the keyboard at fn down, typed into with
/// `P`. Events posted go wherever the keyboard is, so the sink stops when it
/// moves: `focus_at_press` is `Focus::later` at fn down, and each edit
/// compares the same reading now. Comparing a reading with itself, not with
/// the fn event's target, keeps a panel that one reading cannot see (the
/// frontmost app is Topaz while Tot's panel has the keyboard) from stopping
/// the sink at its first edit, while a real switch still changes it.
pub struct AppSink<P: Poster> {
    focus_at_press: Option<i32>,
    poster: P,
}

impl<P: Poster> AppSink<P> {
    pub fn new(focus_at_press: Option<i32>, poster: P) -> Self {
        Self {
            focus_at_press,
            poster,
        }
    }

    /// Post the events for an edit, unless `cancelled()` says the session
    /// was cancelled, secure input is on, or the keyboard has moved since fn
    /// down; all three are checked before any event of the edit, so an edit
    /// is posted whole or not at all.
    pub fn apply(
        &mut self,
        backspaces: usize,
        text: &str,
        cancelled: impl Fn() -> bool,
    ) -> Applied {
        if cancelled() {
            return Applied::Cancelled;
        }
        if self.poster.secure_input() {
            return Applied::SecureInput;
        }
        if self.poster.focus() != self.focus_at_press {
            return Applied::FocusMoved;
        }
        for action in key_actions(backspaces, text) {
            self.poster.post(&action);
        }
        Applied::Typed
    }

    #[cfg(test)]
    fn poster(&self) -> &P {
        &self.poster
    }
}

/// typing.rs's diff and transcript, for the test that plays a dictation into
/// another app; a path module, so that the test also runs with rustc alone.
#[cfg(test)]
#[path = "typing.rs"]
#[allow(dead_code)]
mod typing_for_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn only_the_fn_key_moves_its_state() {
        const OPTION: u16 = 0x3A;
        const RIGHT_OPTION: u16 = 0x3D;
        const COMMAND: u16 = 0x37;
        const SHIFT: u16 = 0x38;
        // fn down, fn up.
        assert!(function_key_after(false, FN_KEY_CODE, FN_FLAG));
        assert!(!function_key_after(true, FN_KEY_CODE, 0));
        // Other flags beside fn's do not matter.
        assert!(function_key_after(false, FN_KEY_CODE, FN_FLAG | 0x100));
        // Option held, an arrow pressed, Option released first: the event is
        // Option's, with the fn flag set by the arrow. Not fn.
        assert!(!function_key_after(false, OPTION, FN_FLAG));
        assert!(!function_key_after(false, RIGHT_OPTION, FN_FLAG));
        assert!(!function_key_after(false, COMMAND, FN_FLAG));
        // Nor does the next modifier change end a press that is real.
        assert!(function_key_after(true, SHIFT, 0));
        assert!(function_key_after(true, COMMAND, FN_FLAG));
        // fn released while an arrow is still held keeps the flag set:
        // still the release.
        assert!(!function_key_after(true, FN_KEY_CODE, FN_FLAG));
        // A release whose press was missed: not a press.
        assert!(!function_key_after(false, FN_KEY_CODE, 0));
    }

    #[test]
    fn the_target_follows_the_keyboard() {
        assert_eq!(target_for(Some(7), 7, false), Target::Pane);
        assert_eq!(target_for(Some(9), 7, false), Target::App(9));
        assert_eq!(target_for(None, 7, false), Target::Nowhere);
    }

    /// Topaz (7) is frontmost and Tot (9), a menu bar app, has the keyboard
    /// through a panel that never brought it to the front.
    #[test]
    fn a_panel_that_has_the_keyboard_gets_the_words_though_topaz_is_frontmost() {
        let untrusted = Focus {
            event_target: Some(9),
            focused_app: None,
            frontmost: Some(7),
        };
        assert_eq!(untrusted.owner(), Some(9));
        assert_eq!(target_for(untrusted.owner(), 7, false), Target::App(9));
        let trusted = Focus {
            focused_app: Some(9),
            ..untrusted
        };
        assert_eq!(target_for(trusted.owner(), 7, false), Target::App(9));
        // The event's target unset: the focused application decides.
        let no_target = Focus {
            event_target: None,
            ..trusted
        };
        assert_eq!(target_for(no_target.owner(), 7, false), Target::App(9));
        // Ben in Topaz's own window: the pane.
        let in_topaz = Focus {
            event_target: Some(7),
            focused_app: Some(7),
            frontmost: Some(7),
        };
        assert_eq!(target_for(in_topaz.owner(), 7, false), Target::Pane);
        // Nothing read at all.
        assert_eq!(Focus::default().owner(), None);
    }

    #[test]
    fn the_later_reading_leaves_out_the_event() {
        let focus = Focus {
            event_target: Some(9),
            focused_app: None,
            frontmost: Some(7),
        };
        assert_eq!(focus.later(), Some(7));
        let focus = Focus {
            focused_app: Some(9),
            ..focus
        };
        assert_eq!(focus.later(), Some(9));
    }

    #[test]
    fn secure_input_stops_other_apps_but_not_the_pane() {
        assert_eq!(target_for(Some(9), 7, true), Target::SecureInput);
        assert_eq!(target_for(Some(7), 7, true), Target::Pane);
        assert_eq!(target_for(None, 7, true), Target::Nowhere);
    }

    fn decode(chunks: &[Vec<u16>]) -> String {
        chunks
            .iter()
            .map(|c| String::from_utf16(c).expect("a chunk split a surrogate pair"))
            .collect()
    }

    #[test]
    fn chunks_hold_at_most_20_units() {
        assert!(utf16_chunks("", 20).is_empty());
        let short = utf16_chunks("hello", 20);
        assert_eq!(short.len(), 1);
        assert_eq!(decode(&short), "hello");

        let exact = "a".repeat(20);
        assert_eq!(utf16_chunks(&exact, 20).len(), 1);
        let over = "a".repeat(21);
        let chunks = utf16_chunks(&over, 20);
        assert_eq!(chunks.iter().map(Vec::len).collect::<Vec<_>>(), vec![20, 1]);

        let long = "The quick brown fox jumps over the lazy dog, café naïve.".repeat(3);
        let chunks = utf16_chunks(&long, MAX_CHUNK_UTF16);
        assert!(chunks
            .iter()
            .all(|c| !c.is_empty() && c.len() <= MAX_CHUNK_UTF16));
        assert_eq!(decode(&chunks), long);
    }

    #[test]
    fn chunks_never_split_a_surrogate_pair() {
        // 19 units, then a character of two units: it moves to the next chunk.
        let text = format!("{}😀b", "a".repeat(19));
        let chunks = utf16_chunks(&text, 20);
        assert_eq!(chunks.iter().map(Vec::len).collect::<Vec<_>>(), vec![19, 3]);
        assert_eq!(decode(&chunks), text);
        for n in 0..45 {
            let text = format!("{}{}", "x".repeat(n), "𝄞😀".repeat(7));
            let chunks = utf16_chunks(&text, 20);
            assert!(chunks.iter().all(|c| c.len() <= 20));
            assert_eq!(decode(&chunks), text, "{n} leading units");
        }
    }

    #[test]
    fn actions_are_backspaces_then_chunks() {
        assert_eq!(key_actions(0, ""), vec![]);
        assert_eq!(
            key_actions(2, "ld"),
            vec![
                KeyAction::Backspace,
                KeyAction::Backspace,
                KeyAction::Type("ld".encode_utf16().collect())
            ]
        );
        let actions = key_actions(1, &"y".repeat(25));
        assert_eq!(actions.len(), 3);
        assert_eq!(actions[0], KeyAction::Backspace);
    }

    /// A text field in another app: each Backspace deletes one character
    /// before the caret (at the end), each Type inserts its text.
    #[derive(Default)]
    struct Field {
        text: String,
        focus: Option<i32>,
        secure: bool,
        posted: usize,
    }

    impl Poster for Field {
        fn focus(&self) -> Option<i32> {
            self.focus
        }
        fn secure_input(&self) -> bool {
            self.secure
        }
        fn post(&mut self, action: &KeyAction) {
            self.posted += 1;
            match action {
                KeyAction::Backspace => {
                    self.text.pop();
                }
                KeyAction::Type(units) => {
                    assert!(units.len() <= MAX_CHUNK_UTF16);
                    self.text.push_str(&String::from_utf16(units).unwrap());
                }
            }
        }
    }

    fn field(pid: i32, text: &str) -> Field {
        Field {
            text: text.to_string(),
            focus: Some(pid),
            ..Default::default()
        }
    }

    /// Play running texts through typing.rs's diff into another app's field
    /// that already holds Ben's own text: after each, the field must read
    /// that text and then exactly the running text.
    #[test]
    fn revisions_land_exactly_in_another_app() {
        use super::typing_for_tests::{edit_between, Transcript};

        const BEFORE: &str = "Dear Ana, ";
        let messages = [
            ("TranscriptInterim", Some("I")),
            ("TranscriptInterim", Some("I scream")),
            ("TranscriptText", Some("ice cream")),
            ("TranscriptInterim", Some("ice cream for")),
            ("TranscriptInterim", Some("ice cream fur")),
            ("TranscriptInterim", Some("ice")),
            ("TranscriptText", Some("ice cream for everyone")),
            ("TranscriptEndpoint", None),
            ("TranscriptInterim", Some("and a café au lait for the naïve one, ")),
            (
                "TranscriptText",
                Some("and a café au lait for the naïve one, with a much longer tail 😀 than twenty units"),
            ),
            ("TranscriptText", Some("And a café.")),
            ("TranscriptEndpoint", None),
        ];
        let mut sink = AppSink::new(Some(9), field(9, BEFORE));
        let mut transcript = Transcript::default();
        let mut typed = String::new();
        for (kind, data) in messages {
            transcript.hear(Some(kind), data);
            let wanted = transcript.text();
            let edit = edit_between(&typed, &wanted);
            assert_eq!(
                sink.apply(edit.backspaces, &edit.text, || false),
                Applied::Typed
            );
            typed = wanted;
            assert_eq!(
                sink.poster().text,
                format!("{BEFORE}{typed}"),
                "after {kind} {data:?}"
            );
        }
        assert_eq!(
            sink.poster().text,
            "Dear Ana, ice cream for everyone And a café."
        );
    }

    #[test]
    fn secure_input_skips_the_edit() {
        let mut f = field(9, "pass");
        f.secure = true;
        let mut sink = AppSink::new(Some(9), f);
        assert_eq!(sink.apply(1, "word", || false), Applied::SecureInput);
        assert_eq!(sink.poster().posted, 0);
        assert_eq!(sink.poster().text, "pass");
    }

    #[test]
    fn a_moved_focus_or_a_cancel_skips_the_edit() {
        let mut sink = AppSink::new(Some(9), field(4, "other app's text"));
        assert_eq!(sink.apply(3, "word", || false), Applied::FocusMoved);
        assert_eq!(sink.poster().posted, 0);

        let mut sink = AppSink::new(Some(9), field(9, "mine"));
        let checked = Cell::new(false);
        let cancelled = || {
            checked.set(true);
            true
        };
        assert_eq!(sink.apply(2, "word", cancelled), Applied::Cancelled);
        assert!(checked.get());
        assert_eq!(sink.poster().posted, 0);
        assert_eq!(sink.poster().text, "mine");

        let mut f = field(9, "");
        f.focus = None;
        let mut sink = AppSink::new(Some(9), f);
        assert_eq!(sink.apply(0, "x", || false), Applied::FocusMoved);
    }

    /// Tot's panel has the keyboard; the later reading, untrusted, sees only
    /// the frontmost app, Topaz (7). It stays 7 while Ben dictates, so the
    /// words land; a real switch (Ben clicks into Mail, 4) changes it and
    /// stops the sink before its next edit.
    #[test]
    fn the_guard_compares_like_with_like_under_a_panel() {
        let mut f = field(7, "Tot note: ");
        f.focus = Some(7);
        let mut sink = AppSink::new(Some(7), f);
        assert_eq!(sink.apply(0, "milk", || false), Applied::Typed);
        assert_eq!(sink.poster().text, "Tot note: milk");
        sink.poster.focus = Some(4);
        assert_eq!(sink.apply(4, "eggs", || false), Applied::FocusMoved);
        assert_eq!(sink.poster().text, "Tot note: milk");
    }
}
