//! Loupe's menu bar gem shows blue while a dictation is listening (Ben,
//! 2026-11-08): from the instant fn is pressed, posted on the fn tap's thread
//! at the press (mod.rs `start`), before the session looks for its focused
//! pane and before the microphone and the speech to text socket open
//! (waiting for the connection made it lag the press by about half a second), until fn is released or the session ends
//! however it ends (cancel, error, the service closing). Topaz tells
//! Loupe with a distributed notification, `NOTIFICATION`, whose userInfo has
//! `state` ("listening" or "stopped") and `pid` (Topaz's, which Loupe was
//! given as TOPAZ_PID). While listening it is posted again every
//! `REFRESH_EVERY`, the wait for the connection included, and Loupe turns
//! the gem back on its own when no refresh comes in time, so a lost
//! "stopped" cannot leave it blue.
//!
//! This is the state alone, without the posting, so that it can be tested.
use std::time::{Duration, Instant};
pub const NOTIFICATION: &str = "com.bbdaniels.topaz.dictation";
/// Loupe reverts after 3 s without a refresh (DictationLight.swift).
pub const REFRESH_EVERY: Duration = Duration::from_secs(1);
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Listening,
    Stopped,
}
impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Listening => "listening",
            State::Stopped => "stopped",
        }
    }
}
/// The light for one session: `post` is called with each state to send.
/// Dropping it turns the light off, so every way out of the session's thread,
/// an error or `?` included, sends "stopped".
pub struct Light<P: FnMut(State)> {
    post: P,
    last_listening: Option<Instant>,
}
impl<P: FnMut(State)> Light<P> {
    pub fn new(post: P) -> Self {
        Self {
            post,
            last_listening: None,
        }
    }
    /// The session is listening at `now`: post "listening" when the light is
    /// off or the last post is `REFRESH_EVERY` old.
    pub fn listening(&mut self, now: Instant) {
        let due = self.last_listening.map_or(true, |at| {
            now.saturating_duration_since(at) >= REFRESH_EVERY
        });
        if due {
            self.last_listening = Some(now);
            (self.post)(State::Listening);
        }
    }
    /// Listening is over (fn released, or the session ends): post "stopped"
    /// once, if the light is on.
    pub fn stopped(&mut self) {
        if self.last_listening.take().is_some() {
            (self.post)(State::Stopped);
        }
    }
}
impl<P: FnMut(State)> Drop for Light<P> {
    fn drop(&mut self) {
        self.stopped();
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;
    fn recorded() -> (Rc<RefCell<Vec<State>>>, impl FnMut(State)) {
        let posts = Rc::new(RefCell::new(vec![]));
        let sink = Rc::clone(&posts);
        (posts, move |state| sink.borrow_mut().push(state))
    }
    #[test]
    fn listening_posts_at_once_then_once_a_refresh() {
        let (posts, post) = recorded();
        let mut light = Light::new(post);
        let start = Instant::now();
        light.listening(start);
        light.listening(start + Duration::from_millis(10));
        light.listening(start + Duration::from_millis(999));
        assert_eq!(*posts.borrow(), [State::Listening]);
        light.listening(start + REFRESH_EVERY);
        assert_eq!(*posts.borrow(), [State::Listening, State::Listening]);
    }
    #[test]
    fn stopped_posts_once_and_only_after_listening() {
        let (posts, post) = recorded();
        let mut light = Light::new(post);
        light.stopped();
        assert!(posts.borrow().is_empty(), "stopped before it was ever on");
        light.listening(Instant::now());
        light.stopped();
        light.stopped();
        assert_eq!(*posts.borrow(), [State::Listening, State::Stopped]);
    }
    #[test]
    fn dropping_a_lit_light_posts_stopped() {
        let (posts, post) = recorded();
        {
            let mut light = Light::new(post);
            light.listening(Instant::now());
        }
        assert_eq!(*posts.borrow(), [State::Listening, State::Stopped]);
    }
    #[test]
    fn dropping_after_stopped_posts_nothing_more() {
        let (posts, post) = recorded();
        {
            let mut light = Light::new(post);
            light.listening(Instant::now());
            light.stopped();
        }
        assert_eq!(*posts.borrow(), [State::Listening, State::Stopped]);
    }
    #[test]
    fn a_slow_connection_keeps_the_light_refreshed_from_the_press() {
        // The session lights it at the press and refreshes it while it waits
        // for the socket (CONNECT_TIMEOUT is 3 s, Loupe's staleness too), so
        // the gem never lapses before the first word.
        let (posts, post) = recorded();
        let mut light = Light::new(post);
        let pressed = Instant::now();
        for ms in (0..=2500).step_by(10) {
            light.listening(pressed + Duration::from_millis(ms));
        }
        assert_eq!(posts.borrow().len(), 3, "at 0, 1 and 2 s");
        // fn released while still connecting: off at once, and only once.
        light.stopped();
        drop(light);
        assert_eq!(posts.borrow().last(), Some(&State::Stopped));
        assert_eq!(posts.borrow().len(), 4);
    }

    #[test]
    fn the_states_are_named_as_loupe_reads_them() {
        assert_eq!(State::Listening.as_str(), "listening");
        assert_eq!(State::Stopped.as_str(), "stopped");
    }
}
