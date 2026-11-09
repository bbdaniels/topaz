/// What a menu bar click or the hotkey does to the HUD panel.
///
/// Hide it whenever it can be seen: shown, on this desktop, and not wholly
/// covered by another window (Ben, 2026-11-08: the panel's close button is
/// gone, so a click on the gem is how its part of the screen comes back). A
/// panel wholly buried under another app's window is brought forward instead
/// (Ben, 2026-11-06: the first click on a buried panel used to hide it). The
/// rule of 2026-11-06 also asked that the panel be the key window of the
/// active app, which a panel left beside Topaz is not, so a click there showed
/// it again instead of hiding it.
///
/// Pure, so the rule is unit tested; `HUDPanelController.toggle` reads the
/// window state and acts.
enum PanelToggle {
    enum Action: Equatable { case show, hide }

    static func action(isVisible: Bool, isOnActiveSpace: Bool, isUncovered: Bool) -> Action {
        isVisible && isOnActiveSpace && isUncovered ? .hide : .show
    }
}
