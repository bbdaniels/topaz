//! A brief notice over a pane (Topaz, fn dictation): the message, centered,
//! for a few seconds or until any key or click.

use mux::termwiztermtab::TermWizTerminal;
use std::time::{Duration, Instant};
use termwiz::color::ColorAttribute;
use termwiz::input::{InputEvent, MouseButtons, MouseEvent};
use termwiz::surface::{Change, CursorVisibility, Position};
use termwiz::terminal::Terminal;

const SHOWN_FOR: Duration = Duration::from_secs(5);

pub fn show_notice(mut term: TermWizTerminal, message: &str) -> anyhow::Result<()> {
    term.set_raw_mode()?;
    let size = term.get_screen_size()?;
    let width = (size.cols * 80 / 100).max(1);
    let x = size.cols.saturating_sub(width) / 2;
    let wrapped = textwrap::fill(message, width);
    let rows: Vec<&str> = wrapped.lines().collect();
    let top = size.rows.saturating_sub(rows.len()) / 2;

    let mut changes = vec![
        Change::ClearScreen(ColorAttribute::Default),
        Change::CursorVisibility(CursorVisibility::Hidden),
    ];
    for (y, row) in rows.iter().enumerate() {
        changes.push(Change::CursorPosition {
            x: Position::Absolute(x),
            y: Position::Absolute(top + y),
        });
        changes.push(Change::Text(row.trim_end().to_string()));
    }
    term.render(&changes)?;
    term.flush()?;

    let until = Instant::now() + SHOWN_FOR;
    while let Some(left) = until.checked_duration_since(Instant::now()) {
        match term.poll_input(Some(left))? {
            Some(InputEvent::Key(_)) => break,
            Some(InputEvent::Mouse(MouseEvent { mouse_buttons, .. }))
                if mouse_buttons != MouseButtons::NONE =>
            {
                break
            }
            _ => {}
        }
    }
    Ok(())
}
