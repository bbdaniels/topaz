//! fn dictation, the window's side (Topaz; the session is crate::dictation):
//! a press of the fn (Globe) key alone starts a session for the active pane,
//! its release finishes it, and any other key, from fn down until the final
//! text is typed, cancels it, as does losing focus; so fn shortcuts still
//! work and nothing is typed after Ben's own keys. Off unless
//! config.fn_dictation; nothing happens on other systems, which never report
//! the fn key.

impl super::TermWindow {
    pub fn function_key_changed(&mut self, down: bool) {
        #[cfg(target_os = "macos")]
        {
            let pressed = std::time::Instant::now();
            if !down {
                self.fn_dictation.fn_up();
            } else if self.config.fn_dictation {
                log::info!("fn dictation timing: +0 ms fn press received");
                let Some(pane) = self.get_active_pane_or_overlay() else {
                    return;
                };
                let pane_id = pane.pane_id();
                let keyterms = self.config.fn_dictation_keyterms.clone();
                let window = self.window.clone();
                self.fn_dictation.fn_down(move || {
                    let notice: crate::dictation::Notice = Box::new(move |message| {
                        if let Some(window) = window.clone() {
                            use ::window::WindowOps;
                            window.notify(super::TermWindowNotif::Apply(Box::new(
                                move |term_window| {
                                    term_window.show_dictation_notice(pane_id, message)
                                },
                            )));
                        }
                    });
                    Some(crate::dictation::start(pane_id, keyterms, notice, pressed))
                });
            }
        }
        #[cfg(not(target_os = "macos"))]
        let _ = down;
    }

    /// A key went down or the window lost focus: the dictation types nothing
    /// more.
    pub fn cancel_dictation(&mut self) {
        #[cfg(target_os = "macos")]
        self.fn_dictation.cancel();
    }

    /// A brief notice over the pane, for a problem only Ben can fix (Claude
    /// Code's sign in); it closes itself, or on any key. A pane that already
    /// shows an overlay, such as copy mode, keeps it, and the log has the
    /// notice.
    #[cfg(target_os = "macos")]
    fn show_dictation_notice(&mut self, pane_id: mux::pane::PaneId, message: String) {
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
