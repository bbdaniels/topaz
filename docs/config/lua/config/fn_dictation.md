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
releasing fn types the last words. Pressing another key while fn is held
cancels, so fn shortcuts keep working.

The first use asks for the microphone. Set macOS's "Press 🌐 key to" to
"Do Nothing", and turn off any other dictation app's fn hotkey.

`fn_dictation_keyterms` lists words and names to bias recognition toward,
up to 1024 characters in all:

```lua
config.fn_dictation = true
config.fn_dictation_keyterms = { 'Topaz', 'ClaudeHUD', 'WezTerm' }
```
