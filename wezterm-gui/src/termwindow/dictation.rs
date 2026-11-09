//! fn dictation, the windows' side (Topaz, macOS; the session and the event
//! tap that hears fn in every app are crate::dictation). When Topaz is
//! frontmost at fn down, the words go to the focused window's active pane,
//! which the session asks for here; any key in a window, or a window losing
//! focus, cancels, so nothing is typed after Ben's own keys. Nothing happens
//! on other systems.

impl super::TermWindow {
    /// A key went down or the window lost focus: the dictation types nothing
    /// more.
    pub fn cancel_dictation(&mut self) {
        #[cfg(target_os = "macos")]
        crate::dictation::everywhere::cancel();
    }

    /// A brief notice over the pane, for a problem only Ben can fix (Claude
    /// Code's sign in); it closes itself, or on any key. A pane that already
    /// shows an overlay, such as copy mode, keeps it, and the log has the
    /// notice.
    #[cfg(target_os = "macos")]
    fn show_dictation_notice_here(&mut self, pane_id: mux::pane::PaneId, message: String) {
        let Some(pane) = mux::Mux::get().get_pane(pane_id) else {
            return;
        };
        if self.pane_state(pane_id).overlay.is_some() {
            return;
        }
        let (overlay, future) =
            crate::overlay::start_overlay_pane(self, &pane, move |_pane_id, term| {
                crate::overlay::notice::show_notice(term, &message)
            });
        self.assign_overlay_for_pane(pane_id, overlay);
        promise::spawn::spawn(future).detach();
    }
}

/// Show `message` over `pane_id` in `window`; from any thread.
#[cfg(target_os = "macos")]
pub fn show_dictation_notice(
    window: &::window::Window,
    pane_id: mux::pane::PaneId,
    message: String,
) {
    use ::window::WindowOps;
    window.notify(super::TermWindowNotif::Apply(Box::new(
        move |term_window| term_window.show_dictation_notice_here(pane_id, message),
    )));
}

/// The focused Topaz window's active pane (or its overlay) and that window,
/// asked of every window on the GUI thread; from any thread but that one.
/// None when no window is focused, or no answer came within `wait`.
#[cfg(target_os = "macos")]
pub fn focused_pane(wait: std::time::Duration) -> Option<(mux::pane::PaneId, ::window::Window)> {
    use std::sync::mpsc::channel;
    let (count_tx, count) = channel::<usize>();
    let (answer_tx, answers) = channel::<Option<(mux::pane::PaneId, ::window::Window)>>();
    promise::spawn::spawn_into_main_thread(async move {
        use ::window::WindowOps;
        let windows = crate::frontend::front_end().gui_windows();
        count_tx.send(windows.len()).ok();
        for gui_window in windows {
            let answer_tx = answer_tx.clone();
            let window = gui_window.window.clone();
            gui_window
                .window
                .notify(super::TermWindowNotif::Apply(Box::new(
                    move |term_window| {
                        let answer = term_window
                            .focused
                            .is_some()
                            .then(|| term_window.get_active_pane_or_overlay())
                            .flatten()
                            .map(|pane| (pane.pane_id(), window));
                        answer_tx.send(answer).ok();
                    },
                )));
        }
    })
    .detach();
    let deadline = std::time::Instant::now() + wait;
    let left = || deadline.saturating_duration_since(std::time::Instant::now());
    let windows = count.recv_timeout(left()).ok()?;
    for _ in 0..windows {
        if let Some(answer) = answers.recv_timeout(left()).ok()? {
            return Some(answer);
        }
    }
    None
}
