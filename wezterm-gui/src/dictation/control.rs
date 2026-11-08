//! When a dictation runs and when it must stop typing: the window's side of
//! fn dictation, without the microphone, socket or pane, so that it can be
//! tested on its own.
//!
//! A session lives from fn down until its thread ends, which is after fn up
//! and the wait for the final text (about 125 ms, at most a few seconds).
//! Any key pressed during that whole time, or losing focus, cancels it: from
//! that moment nothing more is typed, so the dictation never backspaces over
//! or types after Ben's own input. A second fn press while a session is still
//! alive starts nothing.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;

pub enum Command {
    /// fn was released: stop listening and type the final text.
    Finish,
    /// Stop at once and type nothing more.
    Cancel,
}

/// What the window and a session's thread share.
#[derive(Clone, Default)]
pub struct Shared {
    cancelled: Arc<AtomicBool>,
    ended: Arc<AtomicBool>,
}

impl Shared {
    /// Whether the session was cancelled. Typing checks this on the GUI
    /// thread just before it types; cancel() sets it on the GUI thread before
    /// the key that cancelled reaches the pane, so no keystroke of the
    /// dictation can land after that key.
    pub fn cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    /// A handle the typing on the GUI thread can check.
    pub fn cancel_flag(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.cancelled)
    }
}

/// Marks the session ended when its thread returns, however it returns.
struct Ended(Arc<AtomicBool>);

impl Drop for Ended {
    fn drop(&mut self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

/// One hold of fn and the wait for its final text. Dropping it cancels it.
pub struct Session {
    commands: Sender<Command>,
    shared: Shared,
    finished: bool,
}

impl Session {
    /// Run `work` on its own thread with the commands this handle sends.
    pub fn spawn(work: impl FnOnce(Receiver<Command>, Shared) + Send + 'static) -> Self {
        let (commands, receiver) = channel();
        let shared = Shared::default();
        let thread_shared = shared.clone();
        let spawned = std::thread::Builder::new()
            .name("fn-dictation".to_string())
            .spawn(move || {
                let _ended = Ended(Arc::clone(&thread_shared.ended));
                work(receiver, thread_shared);
            });
        if let Err(err) = spawned {
            log::error!("fn dictation: cannot start its thread: {err:#}");
            shared.ended.store(true, Ordering::SeqCst);
        }
        Self {
            commands,
            shared,
            finished: false,
        }
    }

    /// fn was released: send what is left and type the final text. The
    /// handle is kept, so that a key pressed while the final text is awaited
    /// can still cancel it.
    pub fn finish(&mut self) {
        if !self.finished {
            self.finished = true;
            self.commands.send(Command::Finish).ok();
        }
    }

    /// Stop without typing anything more.
    pub fn cancel(&self) {
        self.shared.cancelled.store(true, Ordering::SeqCst);
        self.commands.send(Command::Cancel).ok();
    }

    /// Whether its thread is still running.
    pub fn is_alive(&self) -> bool {
        !self.shared.ended.load(Ordering::SeqCst)
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.shared.cancelled.store(true, Ordering::SeqCst);
    }
}

/// The window's dictation: at most one session at a time.
#[derive(Default)]
pub struct Dictation {
    session: Option<Session>,
}

impl Dictation {
    /// fn went down. While a session is still alive, holding fn or waiting
    /// for its final text, no second one starts.
    pub fn fn_down(&mut self, start: impl FnOnce() -> Option<Session>) {
        if self.session.as_ref().map_or(false, Session::is_alive) {
            log::debug!("fn dictation: the last one is still finishing");
            return;
        }
        self.session = start();
    }

    /// fn went up.
    pub fn fn_up(&mut self) {
        if let Some(session) = self.session.as_mut() {
            session.finish();
        }
    }

    /// A key went down or the window lost focus: type nothing more, whether
    /// fn is still held or the final text is still awaited.
    pub fn cancel(&mut self) {
        if let Some(session) = self.session.take() {
            session.cancel();
        }
    }

    #[cfg(test)]
    fn has_session(&self) -> bool {
        self.session.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::RecvTimeoutError;
    use std::time::Duration;

    const WAIT: Duration = Duration::from_secs(5);

    /// A session whose thread reports each command it receives and runs
    /// until it is cancelled or its handle is dropped.
    fn recording_session(seen: Sender<&'static str>) -> Session {
        Session::spawn(move |commands, _shared| loop {
            match commands.recv() {
                Ok(Command::Finish) => {
                    seen.send("finish").ok();
                }
                Ok(Command::Cancel) => {
                    seen.send("cancel").ok();
                    return;
                }
                Err(_) => {
                    seen.send("dropped").ok();
                    return;
                }
            }
        })
    }

    fn wait_until_ended(session: &Session) {
        let start = std::time::Instant::now();
        while session.is_alive() {
            assert!(start.elapsed() < WAIT, "the session thread did not end");
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    #[test]
    fn a_key_after_fn_up_cancels_the_final_text() {
        let (seen, events) = channel();
        let mut dictation = Dictation::default();
        dictation.fn_down(|| Some(recording_session(seen)));
        dictation.fn_up();
        assert_eq!(events.recv_timeout(WAIT), Ok("finish"));

        // Ben types while the final text is awaited.
        let flag = dictation.session.as_ref().unwrap().shared.cancel_flag();
        dictation.cancel();
        assert!(flag.load(Ordering::SeqCst), "typing must see the cancel");
        assert_eq!(events.recv_timeout(WAIT), Ok("cancel"));
        assert!(!dictation.has_session());
    }

    #[test]
    fn finish_is_sent_once() {
        let (seen, events) = channel();
        let mut dictation = Dictation::default();
        dictation.fn_down(|| Some(recording_session(seen)));
        dictation.fn_up();
        dictation.fn_up();
        assert_eq!(events.recv_timeout(WAIT), Ok("finish"));
        assert_eq!(
            events.recv_timeout(Duration::from_millis(50)),
            Err(RecvTimeoutError::Timeout)
        );
    }

    #[test]
    fn no_second_session_while_one_is_alive() {
        let (seen, events) = channel();
        let mut dictation = Dictation::default();
        dictation.fn_down(|| Some(recording_session(seen)));
        dictation.fn_up();
        assert_eq!(events.recv_timeout(WAIT), Ok("finish"));

        let mut started_again = false;
        dictation.fn_down(|| {
            started_again = true;
            None
        });
        assert!(!started_again);
        assert!(dictation.has_session());
    }

    #[test]
    fn a_new_session_starts_once_the_last_has_ended() {
        let mut dictation = Dictation::default();
        dictation.fn_down(|| Some(Session::spawn(|_commands, _shared| {})));
        wait_until_ended(dictation.session.as_ref().unwrap());
        dictation.fn_up();

        let mut started_again = false;
        dictation.fn_down(|| {
            started_again = true;
            Some(Session::spawn(|_commands, _shared| {}))
        });
        assert!(started_again);
    }

    #[test]
    fn dropping_the_handle_cancels() {
        let (seen, events) = channel();
        let session = recording_session(seen);
        let flag = session.shared.cancel_flag();
        drop(session);
        assert!(flag.load(Ordering::SeqCst));
        assert_eq!(events.recv_timeout(WAIT), Ok("dropped"));
    }

    #[test]
    fn cancel_with_no_session_does_nothing() {
        let mut dictation = Dictation::default();
        dictation.cancel();
        dictation.fn_up();
        assert!(!dictation.has_session());
    }
}
