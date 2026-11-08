//! fn dictation, the window's side (Topaz; the session is crate::dictation):
//! fn down alone starts a session for the active pane, fn up finishes it,
//! and any other key during the hold cancels it, so fn shortcuts still work.
//! Off unless config.fn_dictation; nothing happens on other systems, which
//! never report the fn key.

impl super::TermWindow {
    pub fn function_key_changed(&mut self, down: bool) {
        #[cfg(target_os = "macos")]
        {
            if !down {
                self.finish_dictation();
            } else if self.config.fn_dictation && self.fn_dictation.is_none() {
                if let Some(pane) = self.get_active_pane_or_overlay() {
                    self.fn_dictation = Some(crate::dictation::Session::start(
                        pane.pane_id(),
                        self.config.fn_dictation_keyterms.clone(),
                    ));
                }
            }
        }
        #[cfg(not(target_os = "macos"))]
        let _ = down;
    }

    pub fn finish_dictation(&mut self) {
        #[cfg(target_os = "macos")]
        if let Some(session) = self.fn_dictation.take() {
            session.finish();
        }
    }

    pub fn cancel_dictation_for_key(&mut self) {
        #[cfg(target_os = "macos")]
        if let Some(session) = self.fn_dictation.take() {
            session.cancel();
        }
    }
}
