---
tags:
  - appearance
  - tab_bar
---

# `tab_close_button_at_title_start = false`

Topaz (fork) option. When `true`, and the fancy tab bar draws close buttons
(see [show_close_tab_button_in_tabs](show_close_tab_button_in_tabs.md)), the
first run of text that [format-tab-title](../window-events/format-tab-title.md)
returns becomes the tab's close button: hovering it draws × in its place and
clicking it closes the tab. The usual × after the title is not drawn.

A status dot as the first run works well:

```lua
config.tab_close_button_at_title_start = true
wezterm.on('format-tab-title', function(tab)
  return {
    { Text = ' ● ' },
    { Text = tab.active_pane.title },
  }
end)
```
