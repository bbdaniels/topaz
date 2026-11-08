---
tags:
  - keys
---

# `fn_dictation = false`

Topaz (fork) option, macOS only. When `true`, holding fn (Globe) on its own
dictates into the active pane with Anthropic's speech to text, the service of
Claude Code's `/voice`, signed in with Claude Code's login (its
`Claude Code-credentials` Keychain item, read at each use). Words are typed as
they are recognized and corrected in place when the service revises them;
releasing fn types the last words. Only a press of the fn key itself starts
it; arrow and function keys, which macOS marks with fn's flag, never do.
Pressing another key while fn is held, or before the last words arrive after
its release, cancels and types nothing more, so fn shortcuts keep working and
nothing lands after your own typing; so does switching to another app. A
press while the last one is still finishing starts nothing. If Claude Code's
sign in is missing, expired or refused, a notice over the pane says so for a
few seconds.

The first use asks for the microphone. Set macOS's "Press 🌐 key to" to
"Do Nothing", and turn off any other dictation app's fn hotkey.

`fn_dictation_keyterms` lists words and names to bias recognition toward,
up to 1024 characters in all:

```lua
config.fn_dictation = true
config.fn_dictation_keyterms = { 'Topaz', 'ClaudeHUD', 'WezTerm' }
```
