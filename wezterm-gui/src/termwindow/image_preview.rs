//! Topaz: a preview of an image that a pane names.
//!
//! Claude Code prints the path of a screenshot or figure (`Read(/tmp/x.png)`,
//! a path in prose, a markdown link) or an http(s) image URL, never the
//! picture. When the mouse rests on such a reference, Topaz draws the image
//! in a framed box beside that line: below it when there is room in the
//! pane, otherwise above it.
//!
//! The preview never writes into the pane's grid. Claude Code is an Ink
//! application that redraws regions of the screen with cursor movement, so
//! image cells or inserted lines would be overwritten or would shift its
//! layout. Instead the preview is a quad drawn by the GUI after the panes,
//! from the same glyph cache and texture atlas that draw iTerm2 and kitty
//! image cells. It is anchored to the stable rows that name the image: it
//! moves with them when the viewport scrolls, and it vanishes as soon as the
//! text of those rows changes (a redraw that rewrites them) or the mouse
//! leaves the reference.
//!
//! Where a path is looked up depends on what runs in the pane. In a local
//! pane it names a file on this machine. In a pane whose foreground process
//! is ssh (the tabs attached to the iMac's sessions) it names a file on the
//! far host, which is read with a second ssh to the same destination and
//! options; a relative path there is resolved against the working directory
//! of the tmux session the pane attaches to, when it attaches to one.
//! Panes running mosh or et, and multiplexer domains, resolve URLs only.
//! A missing file, a file that does not decode, or a failed fetch draws
//! nothing. Files are read, and URLs fetched, on a worker thread; the image
//! is decoded and scaled down there too, so the GUI thread only uploads it.
//!
//! Every reference that would preview carries a mark, a faint dashed
//! underline drawn over the text (never into the grid), and the pointer
//! becomes a hand over it. A path on the far host is marked once its fetch
//! has succeeded, so a remote path is fetched as soon as it is on screen
//! and its preview is ready when the pointer arrives.

use crate::quad::{QuadTrait, TripleLayerQuadAllocator, TripleLayerQuadAllocatorTrait};
use crate::termwindow::render::paint::AllowImage;
use crate::termwindow::TermWindowNotif;
use ::window::bitmaps::atlas::OutOfTextureSpace;
use ::window::WindowOps;
use anyhow::{anyhow, Context};
use mux::domain::LocalDomain;
use mux::pane::{CachePolicy, Pane, PaneId};
use mux::tab::PositionedPane;
use mux::Mux;
use std::collections::HashMap;
use std::convert::TryFrom;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};
use termwiz::image::{ImageData, ImageDataType};
use termwiz::surface::SequenceNo;
use wezterm_term::{Line, StableRowIndex};
use window::color::LinearRgba;

/// File name extensions that name an image the existing decoder reads.
/// SVG and PDF are left out: the image decoder behind image cells reads
/// neither, and a second rasterizer is out of scope.
const IMAGE_EXTENSIONS: &[&str] = &["png", "jpg", "jpeg", "gif", "webp"];
/// Largest file or download read for a preview.
const MAX_SOURCE_BYTES: usize = 64 * 1024 * 1024;
/// Longest side of the decoded preview; larger images are scaled down on
/// the worker thread so the texture atlas holds a modest bitmap.
const MAX_DECODED_SIDE: u32 = 2048;
/// Number of previews kept; the oldest is dropped to make room.
const MAX_CACHED_IMAGES: usize = 48;
const FETCH_TIMEOUT: Duration = Duration::from_secs(10);
/// How many rows above and below the hovered row a wrapped reference may span.
const WRAPPED_ROWS_EACH_WAY: usize = 3;
/// Width in pixels of the frame drawn around the preview.
const FRAME_PIXELS: f32 = 2.0;
/// Longest a fetch over ssh may take, connection included.
const REMOTE_TIMEOUT: Duration = Duration::from_secs(15);
/// A remote image older than this is fetched again when the pointer comes
/// back to it (there is no modification time to watch), the old picture
/// shown meanwhile.
const REMOTE_REFRESH: Duration = Duration::from_secs(10);
/// A remote path whose fetch failed is tried again after this long, for a
/// file that is written after its name is printed.
const REMOTE_RETRY: Duration = Duration::from_secs(60);
/// The marks of a pane are found again after this long even when its text
/// has not changed, so a local file that appears or vanishes is noticed.
const MARK_RECHECK: Duration = Duration::from_secs(2);
/// Most rows joined into one logical line when looking for a reference
/// that wraps.
const MAX_JOINED_ROWS: usize = 2 * WRAPPED_ROWS_EACH_WAY + 1;
/// Most fetches over ssh running at once; a path found while they run is
/// tried again at the next look.
const MAX_REMOTE_FETCHES: usize = 4;
/// Options a fetch over ssh must not inherit: they take no value and
/// request a terminal, background the connection, open a control master,
/// run no command or a subsystem, or only print something.
const SSH_DROPPED_FLAGS: &str = "fGMNnsTtVv";
/// Options that take a value.
const SSH_FLAGS_WITH_VALUE: &str = "BbcDEeFIiJLlmOoPpQRSWw";
/// Options with a value that a fetch must not inherit: port forwards and
/// control commands.
const SSH_DROPPED_VALUE_FLAGS: &str = "DLORW";

/// True if `s` ends in `.png`, `.jpg`, `.jpeg`, `.gif` or `.webp`, in any case.
pub fn has_image_extension(s: &str) -> bool {
    let lower = s.to_ascii_lowercase();
    IMAGE_EXTENSIONS.iter().any(|ext| {
        lower.len() > ext.len() + 1
            && lower.ends_with(ext)
            && lower.as_bytes()[lower.len() - ext.len() - 1] == b'.'
    })
}

/// One spelling of a reference: where it starts (a char index into the
/// scanned text) and its text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub start: usize,
    pub text: String,
}

/// An image reference found in a run of text. A path with spaces in it
/// ("Screenshot 2026-11-08 at 10.12.33 AM.png") cannot be bounded by the
/// text alone, so a path reference carries every plausible spelling, the
/// longest first; the first that names an existing file wins.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImageReference {
    /// Char index one past the last char of the reference.
    pub end: usize,
    pub is_url: bool,
    pub candidates: Vec<Candidate>,
}

fn is_opening_delimiter(c: char) -> bool {
    matches!(
        c,
        '(' | '[' | '{' | '"' | '\'' | '`' | '<' | '=' | '|' | '*'
    )
}

fn is_closing_delimiter(c: char) -> bool {
    matches!(
        c,
        ')' | ']' | '}' | '"' | '\'' | '`' | '>' | ',' | ';' | ':' | '|' | '*'
    )
}

/// The spaces macOS puts in file names: the plain space, and the narrow
/// no-break space before AM or PM in screenshot names.
fn is_name_space(c: char) -> bool {
    c == ' ' || c == '\u{202f}' || c == '\u{a0}'
}

fn url_stop(c: char) -> bool {
    c.is_whitespace()
        || matches!(
            c,
            '"' | '\'' | '`' | '<' | '>' | '(' | ')' | '[' | ']' | '{' | '}' | '|'
        )
}

fn starts_with_at(chars: &[char], idx: usize, prefix: &str) -> bool {
    let mut i = idx;
    for p in prefix.chars() {
        match chars.get(i) {
            Some(c) if c.to_ascii_lowercase() == p => i += 1,
            _ => return false,
        }
    }
    true
}

/// If an image extension starts after the dot at `dot`, and is followed by
/// the end of the text, whitespace, a closing delimiter or end punctuation,
/// returns the index one past the extension.
fn extension_end(chars: &[char], dot: usize) -> Option<usize> {
    for ext in IMAGE_EXTENSIONS {
        let start = dot + 1;
        let after = start + ext.len();
        if after > chars.len() {
            continue;
        }
        let matches = chars[start..after]
            .iter()
            .zip(ext.chars())
            .all(|(c, e)| c.to_ascii_lowercase() == e);
        if !matches {
            continue;
        }
        let ends_here = |i: usize| {
            i == chars.len() || chars[i].is_whitespace() || is_closing_delimiter(chars[i])
        };
        if ends_here(after) {
            return Some(after);
        }
        if matches!(chars[after], '.' | '!' | '?') && ends_here(after + 1) {
            return Some(after);
        }
    }
    None
}

/// Strips a `file://` prefix and rejects a spelling truncated with an
/// ellipsis, which no longer names a file.
fn normalize_candidate(mut candidate: Candidate) -> Option<Candidate> {
    if let Some(rest) = candidate.text.strip_prefix("file://") {
        candidate.text = rest.to_string();
        candidate.start += "file://".len();
    }
    if candidate.text.contains('\u{2026}') || candidate.text.starts_with("...") {
        return None;
    }
    if !has_image_extension(&candidate.text) {
        return None;
    }
    Some(candidate)
}

/// Finds the image paths and http(s) image URLs in `text`, in order of
/// where they end.
pub fn find_image_references(text: &str) -> Vec<ImageReference> {
    let chars: Vec<char> = text.chars().collect();
    let mut refs = vec![];
    let mut url_spans = vec![];

    let mut i = 0;
    while i < chars.len() {
        if starts_with_at(&chars, i, "https://") || starts_with_at(&chars, i, "http://") {
            let start = i;
            let mut end = i;
            while end < chars.len() && !url_stop(chars[end]) {
                end += 1;
            }
            while end > start && matches!(chars[end - 1], '.' | ',' | ';' | ':' | '!' | '?') {
                end -= 1;
            }
            url_spans.push(start..end);
            let url: String = chars[start..end].iter().collect();
            let path_part = url.split(|c| c == '?' || c == '#').next().unwrap_or("");
            if has_image_extension(path_part) {
                refs.push(ImageReference {
                    end,
                    is_url: true,
                    candidates: vec![Candidate { start, text: url }],
                });
            }
            i = end.max(i + 1);
        } else {
            i += 1;
        }
    }

    for dot in 1..chars.len() {
        if chars[dot] != '.' || url_spans.iter().any(|span| span.contains(&dot)) {
            continue;
        }
        let prev = chars[dot - 1];
        if prev.is_whitespace() || prev == '/' || is_opening_delimiter(prev) {
            continue;
        }
        let end = match extension_end(&chars, dot) {
            Some(end) => end,
            None => continue,
        };

        // The spelling without spaces.
        let mut token_start = dot;
        while token_start > 0
            && !chars[token_start - 1].is_whitespace()
            && !is_opening_delimiter(chars[token_start - 1])
        {
            token_start -= 1;
        }

        // Spellings that reach back across single spaces, kept only if
        // they start like an absolute or home path.
        let mut spaced = vec![];
        let mut word_start = token_start;
        for _ in 0..8 {
            if word_start < 2 || !is_name_space(chars[word_start - 1]) {
                break;
            }
            let mut k = word_start - 1;
            while k > 0 && !chars[k - 1].is_whitespace() && !is_opening_delimiter(chars[k - 1]) {
                k -= 1;
            }
            if k == word_start - 1 {
                break;
            }
            let text: String = chars[k..end].iter().collect();
            if text.starts_with('/') || text.starts_with("~/") || text.starts_with("file:///") {
                spaced.push(Candidate { start: k, text });
            }
            word_start = k;
        }
        spaced.reverse();

        let mut candidates = spaced;
        candidates.push(Candidate {
            start: token_start,
            text: chars[token_start..end].iter().collect(),
        });
        let candidates: Vec<Candidate> = candidates
            .into_iter()
            .filter_map(normalize_candidate)
            .collect();
        if !candidates.is_empty() {
            refs.push(ImageReference {
                end,
                is_url: false,
                candidates,
            });
        }
    }

    refs.sort_by_key(|r| r.end);
    refs
}

/// The text of one screen row, one entry per char, with the column of the
/// cell that holds each char.
#[derive(Debug, Clone, Default)]
pub struct RowCells {
    pub chars: Vec<char>,
    pub cols: Vec<usize>,
    /// The terminal wrapped this row onto the next one.
    pub wrapped: bool,
}

impl RowCells {
    pub fn from_line(line: &Line) -> Self {
        let mut row = RowCells {
            wrapped: line.last_cell_was_wrapped(),
            ..Default::default()
        };
        for cell in line.visible_cells() {
            for c in cell.str().chars() {
                row.chars.push(c);
                row.cols.push(cell.cell_index());
            }
        }
        row
    }

    #[cfg(test)]
    pub fn from_str(s: &str) -> Self {
        let mut row = RowCells::default();
        for (col, c) in s.chars().enumerate() {
            row.chars.push(c);
            row.cols.push(col);
        }
        row
    }

    /// Text runs to the right edge, so it may continue on the next row:
    /// either the terminal wrapped it, or the application (Ink wraps long
    /// lines itself, with a newline) filled the row.
    fn is_full(&self, width: usize) -> bool {
        self.wrapped
            || self
                .chars
                .iter()
                .zip(&self.cols)
                .rev()
                .find(|(c, _)| !c.is_whitespace())
                .map(|(_, col)| col + 2 >= width)
                .unwrap_or(false)
    }
}

/// Joins the hovered row with the full rows around it, so a path that
/// wraps onto the next row reads as one. Continuation rows lose their
/// leading indentation. Returns the joined chars and, for each, its
/// (row index into `rows`, column).
pub fn join_wrapped_rows(
    rows: &[RowCells],
    hovered: usize,
    width: usize,
) -> (Vec<char>, Vec<(usize, usize)>) {
    let mut first = hovered;
    while first > 0 && hovered - first < WRAPPED_ROWS_EACH_WAY && rows[first - 1].is_full(width) {
        first -= 1;
    }
    let mut last = hovered;
    while last + 1 < rows.len()
        && last - hovered < WRAPPED_ROWS_EACH_WAY
        && rows[last].is_full(width)
    {
        last += 1;
    }
    join_rows(rows, first, last)
}

/// Joins `rows[first..=last]` into one run of text, dropping the trailing
/// spaces of each row but the last and the indentation of each row but
/// the first.
fn join_rows(rows: &[RowCells], first: usize, last: usize) -> (Vec<char>, Vec<(usize, usize)>) {
    let mut chars = vec![];
    let mut positions = vec![];
    for r in first..=last {
        let row = &rows[r];
        let mut end = row.chars.len();
        if r < last {
            while end > 0 && row.chars[end - 1] == ' ' {
                end -= 1;
            }
        }
        let mut start = 0;
        if r > first {
            while start < end && row.chars[start] == ' ' {
                start += 1;
            }
        }
        for k in start..end {
            chars.push(row.chars[k]);
            positions.push((r, row.cols[k]));
        }
    }
    (chars, positions)
}

/// One row's share of a marked reference: columns `start_col..end_col` of
/// `row` (an index into the rows given to `reference_marks`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MarkSpan {
    pub row: usize,
    pub start_col: usize,
    pub end_col: usize,
}

fn push_spans(
    spans: &mut Vec<MarkSpan>,
    positions: &[(usize, usize)],
    start: usize,
    end: usize,
) {
    for &(row, col) in &positions[start..end] {
        match spans.last_mut() {
            Some(span) if span.row == row && span.end_col == col => span.end_col = col + 1,
            _ => spans.push(MarkSpan {
                row,
                start_col: col,
                end_col: col + 1,
            }),
        }
    }
}

/// The spans to mark on screen. Each row is read alone first, as the hover
/// does, so a path that starts a row is not glued to the word that ends
/// the row above; then each run of full rows is read joined, keeping only
/// the references that cross rows. `pick` says which spelling of a
/// reference would preview, if any, by its index in `candidates`.
pub fn reference_marks(
    rows: &[RowCells],
    width: usize,
    mut pick: impl FnMut(&ImageReference) -> Option<usize>,
) -> Vec<MarkSpan> {
    let mut spans = vec![];
    for r in 0..rows.len() {
        let (chars, positions) = join_rows(rows, r, r);
        let text: String = chars.iter().collect();
        for reference in find_image_references(&text) {
            if let Some(i) = pick(&reference) {
                push_spans(&mut spans, &positions, reference.candidates[i].start, reference.end);
            }
        }
    }
    let mut first = 0;
    while first < rows.len() {
        let mut last = first;
        while last + 1 < rows.len() && last - first + 1 < MAX_JOINED_ROWS && rows[last].is_full(width)
        {
            last += 1;
        }
        if last > first {
            let (chars, positions) = join_rows(rows, first, last);
            let text: String = chars.iter().collect();
            for reference in find_image_references(&text) {
                let crosses = |start: usize| positions[start].0 != positions[reference.end - 1].0;
                if !reference.candidates.iter().any(|c| crosses(c.start)) {
                    continue;
                }
                if let Some(i) = pick(&reference) {
                    let start = reference.candidates[i].start;
                    if crosses(start) {
                        push_spans(&mut spans, &positions, start, reference.end);
                    }
                }
            }
        }
        first = last + 1;
    }
    // A cell found twice (alone and joined) is drawn once, since the marks
    // are translucent.
    spans.sort_by_key(|span| (span.row, span.start_col));
    let mut merged: Vec<MarkSpan> = vec![];
    for span in spans {
        match merged.last_mut() {
            Some(last) if last.row == span.row && span.start_col <= last.end_col => {
                last.end_col = last.end_col.max(span.end_col);
            }
            _ => merged.push(span),
        }
    }
    merged
}

/// Resolves a path spelling to an existing image file: `~/` against the
/// home directory, a relative path against the pane's working directory.
pub fn resolve_local_path(
    candidate: &str,
    cwd: Option<&Path>,
    home: Option<&Path>,
) -> Option<PathBuf> {
    if !has_image_extension(candidate) {
        return None;
    }
    let path = if let Some(rest) = candidate.strip_prefix("~/") {
        home?.join(rest)
    } else if candidate.starts_with('/') {
        PathBuf::from(candidate)
    } else {
        cwd?.join(candidate)
    };
    if path.is_file() {
        Some(path)
    } else {
        None
    }
}

/// Quotes `s` for a POSIX shell.
fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// From the argument vector of an interactive ssh, the command that reaches
/// the same destination with the same options to run one command:
/// options that ask for a terminal, forward ports, background the
/// connection or control a master are dropped, and the fetch never asks a
/// question, never forwards, and gives up quickly. Returns that command
/// (without the remote command) and the remote command words of the
/// original.
pub fn ssh_fetch_command(argv: &[String]) -> Option<(Vec<String>, Vec<String>)> {
    let program = argv.first()?.clone();
    let mut kept = vec![];
    let mut destination = None;
    let mut i = 1;
    while i < argv.len() {
        let arg = &argv[i];
        i += 1;
        if arg == "--" {
            destination = Some(argv.get(i)?.clone());
            i += 1;
            break;
        }
        if !(arg.starts_with('-') && arg.len() > 1) {
            destination = Some(arg.clone());
            break;
        }
        let flags: Vec<char> = arg[1..].chars().collect();
        for (k, &flag) in flags.iter().enumerate() {
            if SSH_FLAGS_WITH_VALUE.contains(flag) {
                let value = if k + 1 < flags.len() {
                    flags[k + 1..].iter().collect()
                } else {
                    let value = argv.get(i)?.clone();
                    i += 1;
                    value
                };
                if !SSH_DROPPED_VALUE_FLAGS.contains(flag) {
                    kept.push(format!("-{flag}"));
                    kept.push(value);
                }
                break;
            }
            if !SSH_DROPPED_FLAGS.contains(flag) {
                kept.push(format!("-{flag}"));
            }
        }
    }
    let destination = destination?;
    // ssh keeps the first value it is given for an option, so these come
    // before the inherited ones.
    let mut command = vec![program];
    for option in [
        "BatchMode=yes",
        "ConnectTimeout=5",
        "ClearAllForwardings=yes",
        "RemoteCommand=none",
    ] {
        command.push("-o".to_string());
        command.push(option.to_string());
    }
    command.extend(kept);
    command.push("-T".to_string());
    command.push(destination);
    Some((command, argv[i..].to_vec()))
}

/// If the remote command attaches to a tmux session (`tmux -L pi-gate
/// attach -t =name`), shell text that changes to the working directory of
/// that session's active pane, failing when there is none.
pub fn tmux_cd_command(remote: &[String]) -> Option<String> {
    let joined = remote.join(" ");
    let words: Vec<&str> = joined.split_whitespace().collect();
    let (first, rest) = words.split_first()?;
    if Path::new(first).file_name()?.to_str()? != "tmux" {
        return None;
    }
    let mut server = vec![];
    let mut i = 0;
    while i < rest.len() && rest[i].starts_with('-') {
        if matches!(rest[i], "-L" | "-S") {
            server.push(rest[i].to_string());
            server.push(sh_quote(rest.get(i + 1)?));
            i += 1;
        } else if matches!(rest[i], "-f" | "-T" | "-c") {
            i += 1;
        }
        i += 1;
    }
    if !matches!(rest.get(i), Some(&"attach") | Some(&"attach-session") | Some(&"a") | Some(&"at")) {
        return None;
    }
    let mut target = None;
    let mut k = i + 1;
    while k < rest.len() {
        if rest[k] == "-t" {
            target = rest.get(k + 1).map(|t| t.to_string());
            k += 1;
        } else if let Some(t) = rest[k].strip_prefix("-t") {
            target = Some(t.to_string());
        }
        k += 1;
    }
    // attach names a session; display-message wants a pane, and reads a
    // bare `=name` as a pane that does not exist. `name:` is the session's
    // current window and its active pane.
    let mut target = target?;
    if !target.contains(':') {
        target.push(':');
    }
    let mut tmux = vec!["tmux".to_string()];
    tmux.extend(server);
    Some(format!(
        "d=$({} display-message -p -t {} '#{{pane_current_path}}' 2>/dev/null) && [ -n \"$d\" ] && cd -- \"$d\"",
        tmux.join(" "),
        sh_quote(&target)
    ))
}

/// The remote shell command that writes the image a path names to its
/// output, or fails: `~/` against the remote home, a relative path after
/// `cd` (none: a relative path cannot be resolved).
pub fn remote_read_command(path: &str, cd: Option<&str>) -> Option<String> {
    if !has_image_extension(path) {
        return None;
    }
    let read = |target: String| format!("f={target} && test -f \"$f\" && exec cat -- \"$f\"");
    if let Some(rest) = path.strip_prefix("~/") {
        Some(read(format!("\"$HOME\"/{}", sh_quote(rest))))
    } else if path.starts_with('/') {
        Some(read(sh_quote(path)))
    } else {
        Some(format!("{} && {}", cd?, read(sh_quote(path))))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ImageSource {
    File(PathBuf),
    Url(String),
    /// A file on a host reached over ssh: the ssh command, and the remote
    /// shell command that writes the file to its output.
    Remote { ssh: Vec<String>, command: String },
}

/// The reference the mouse rests on.
#[derive(Debug, Clone, PartialEq)]
pub struct ImageHover {
    pane_id: PaneId,
    source: ImageSource,
    /// The stable rows the reference spans.
    first_row: StableRowIndex,
    last_row: StableRowIndex,
    /// Column of the reference's first char on `first_row`.
    start_col: usize,
    /// The text of `first_row..=last_row` when the hover began; the
    /// preview vanishes once it differs.
    row_texts: Vec<String>,
}

enum LoadState {
    Loading,
    Ready(Arc<ImageData>, u32, u32),
    Failed,
}

struct LoadEntry {
    state: LoadState,
    /// Modification time of the file when the load began, so an image
    /// that is rewritten in place (a figure being iterated on) reloads.
    modified: Option<SystemTime>,
    /// When the latest load began.
    started: Instant,
    /// Which load the entry waits for; the result of an older one is
    /// dropped.
    generation: u64,
}

/// What a pane's paths name, read from what runs in it.
enum PaneFiles {
    Local {
        cwd: Option<PathBuf>,
        home: Option<PathBuf>,
    },
    Ssh {
        ssh: Vec<String>,
        cd: Option<String>,
    },
    Unreachable,
}

/// Whether a spelling would preview.
enum Found {
    Ready(ImageSource, Option<SystemTime>),
    /// A remote file still being fetched.
    Pending(ImageSource),
    Unavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct MarkKey {
    viewport_top: StableRowIndex,
    rows: usize,
    cols: usize,
    seqno: SequenceNo,
    loads_finished: u64,
}

struct PaneMarks {
    key: MarkKey,
    found_at: Instant,
    /// Spans whose `row` counts from the top of the viewport.
    spans: Vec<MarkSpan>,
}

#[derive(Default)]
pub struct ImagePreview {
    hover: Option<ImageHover>,
    loads: HashMap<ImageSource, LoadEntry>,
    next_generation: u64,
    /// Counts finished loads, so the marks are found again when one ends.
    loads_finished: u64,
    marks: HashMap<PaneId, PaneMarks>,
}

/// Decodes an encoded image and scales it to fit `MAX_DECODED_SIDE`.
pub fn decode_for_preview(bytes: &[u8]) -> anyhow::Result<(Arc<ImageData>, u32, u32)> {
    let image = image::load_from_memory(bytes).context("decode image")?;
    let image = if image.width() > MAX_DECODED_SIDE || image.height() > MAX_DECODED_SIDE {
        image.thumbnail(MAX_DECODED_SIDE, MAX_DECODED_SIDE)
    } else {
        image
    };
    let rgba = image.into_rgba8();
    let (width, height) = rgba.dimensions();
    anyhow::ensure!(width > 0 && height > 0, "empty image");
    let data = ImageData::with_data(ImageDataType::new_single_frame(
        width,
        height,
        rgba.into_raw(),
    ));
    Ok((Arc::new(data), width, height))
}

/// A writer that refuses to hold more than `cap` bytes.
struct CappedWriter {
    buf: Vec<u8>,
    cap: usize,
}

impl Write for CappedWriter {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        if self.buf.len() + data.len() > self.cap {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                "image is too large to preview",
            ));
        }
        self.buf.extend_from_slice(data);
        Ok(data.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn fetch_url(url: &str) -> anyhow::Result<Vec<u8>> {
    let uri = http_req::uri::Uri::try_from(url).map_err(|e| anyhow!("{url}: {e}"))?;
    let mut body = CappedWriter {
        buf: vec![],
        cap: MAX_SOURCE_BYTES,
    };
    let response = http_req::request::Request::new(&uri)
        .timeout(FETCH_TIMEOUT)
        .header("User-Agent", "Topaz image preview")
        .send(&mut body)
        .map_err(|e| anyhow!("fetch {url}: {e}"))?;
    anyhow::ensure!(
        response.status_code().is_success(),
        "fetch {url}: status {:?}",
        response.status_code()
    );
    Ok(body.buf)
}

/// Runs `command` on the far host through `ssh` and returns its output,
/// killing it if it runs past `REMOTE_TIMEOUT` or writes more than
/// `MAX_SOURCE_BYTES`.
fn fetch_remote(ssh: &[String], command: &str) -> anyhow::Result<Vec<u8>> {
    let (program, args) = ssh.split_first().context("empty ssh command")?;
    let mut child = Command::new(program)
        .args(args)
        .arg(command)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| format!("run {program}"))?;
    let mut stdout = child.stdout.take().context("ssh output")?;
    let child = Arc::new(Mutex::new(child));
    let done = Arc::new(AtomicBool::new(false));
    {
        let child = Arc::clone(&child);
        let done = Arc::clone(&done);
        std::thread::Builder::new()
            .name("image-preview-ssh-timeout".to_string())
            .spawn(move || {
                let started = Instant::now();
                while !done.load(Ordering::Acquire) {
                    if started.elapsed() > REMOTE_TIMEOUT {
                        let _ = child.lock().unwrap().kill();
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
            })?;
    }
    let mut bytes = vec![];
    let read = (&mut stdout)
        .take(MAX_SOURCE_BYTES as u64 + 1)
        .read_to_end(&mut bytes);
    if read.is_err() || bytes.len() > MAX_SOURCE_BYTES {
        let _ = child.lock().unwrap().kill();
    }
    done.store(true, Ordering::Release);
    let status = child.lock().unwrap().wait()?;
    read.context("read ssh output")?;
    anyhow::ensure!(bytes.len() <= MAX_SOURCE_BYTES, "image is too large to preview");
    anyhow::ensure!(status.success(), "{program}: {status}");
    Ok(bytes)
}

fn load_image(source: &ImageSource) -> anyhow::Result<(Arc<ImageData>, u32, u32)> {
    let bytes = match source {
        ImageSource::File(path) => {
            let len = std::fs::metadata(path)?.len();
            anyhow::ensure!(
                len as usize <= MAX_SOURCE_BYTES,
                "{} is too large to preview",
                path.display()
            );
            std::fs::read(path)?
        }
        ImageSource::Url(url) => fetch_url(url)?,
        ImageSource::Remote { ssh, command } => fetch_remote(ssh, command)?,
    };
    decode_for_preview(&bytes)
}

/// What the paths a pane prints name: files on this machine (a local
/// domain pane running neither ssh, mosh nor et), files on the far host of
/// the ssh running in it, or nothing reachable.
fn pane_files(pane: &Arc<dyn Pane>) -> PaneFiles {
    let is_local_domain = Mux::get()
        .get_domain(pane.domain_id())
        .map(|domain| domain.downcast_ref::<LocalDomain>().is_some())
        .unwrap_or(false);
    if !is_local_domain {
        return PaneFiles::Unreachable;
    }
    if let Some(info) = pane.get_foreground_process_info(CachePolicy::AllowStale) {
        let base = |p: &Path| p.file_name().and_then(|n| n.to_str()).map(str::to_string);
        let name = base(&info.executable)
            .or_else(|| info.argv.first().and_then(|a| base(Path::new(a))))
            .unwrap_or_else(|| info.name.clone());
        match name.as_str() {
            "ssh" => {
                let mut argv = info.argv.clone();
                if let Some(program) = argv.first_mut() {
                    if info.executable.is_file() {
                        *program = info.executable.to_string_lossy().into_owned();
                    }
                }
                return match ssh_fetch_command(&argv) {
                    Some((ssh, remote)) => PaneFiles::Ssh {
                        cd: tmux_cd_command(&remote),
                        ssh,
                    },
                    None => PaneFiles::Unreachable,
                };
            }
            "mosh" | "mosh-client" | "et" => return PaneFiles::Unreachable,
            _ => {}
        }
    }
    PaneFiles::Local {
        cwd: pane
            .get_current_working_dir(CachePolicy::AllowStale)
            .and_then(|url| url.to_file_path().ok()),
        home: dirs_next::home_dir(),
    }
}

fn file_modified(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path).and_then(|m| m.modified()).ok()
}

impl crate::TermWindow {
    /// Called on every mouse event over the terminal area, with the window
    /// cell the pointer is in.
    pub fn update_image_preview_hover(&mut self, column: usize, row: i64, context: &dyn WindowOps) {
        let hover = if self.config.image_preview_on_hover {
            self.find_image_hover(column, row)
        } else {
            None
        };
        if hover != self.image_preview.hover {
            if let Some(ImageHover {
                source: source @ ImageSource::Remote { .. },
                ..
            }) = &hover
            {
                self.refresh_remote_if_stale(source);
            }
            self.image_preview.hover = hover;
            context.invalidate();
        }
    }

    /// Called when the pointer leaves the terminal area or the window.
    pub fn clear_image_preview_hover(&mut self, context: &dyn WindowOps) {
        if self.image_preview.hover.take().is_some() {
            context.invalidate();
        }
    }

    /// Whether the pointer rests on a reference that previews, so it shows
    /// as a hand.
    pub fn image_preview_wants_pointer(&self) -> bool {
        let hover = match &self.image_preview.hover {
            Some(hover) => hover,
            None => return false,
        };
        match self.image_preview.loads.get(&hover.source).map(|e| &e.state) {
            Some(LoadState::Ready(..)) => true,
            Some(LoadState::Loading) => !matches!(hover.source, ImageSource::Remote { .. }),
            _ => false,
        }
    }

    /// Whether a spelling of a path would preview in a pane whose paths
    /// name `files`; starts the fetch of a remote file not yet tried.
    fn resolve_path(&mut self, files: &PaneFiles, text: &str) -> Found {
        match files {
            PaneFiles::Local { cwd, home } => {
                match resolve_local_path(text, cwd.as_deref(), home.as_deref()) {
                    Some(path) => {
                        let modified = file_modified(&path);
                        Found::Ready(ImageSource::File(path), modified)
                    }
                    None => Found::Unavailable,
                }
            }
            PaneFiles::Ssh { ssh, cd } => {
                let command = match remote_read_command(text, cd.as_deref()) {
                    Some(command) => command,
                    None => return Found::Unavailable,
                };
                let source = ImageSource::Remote {
                    ssh: ssh.clone(),
                    command,
                };
                let retry = match self.image_preview.loads.get(&source) {
                    None => true,
                    Some(entry) => match entry.state {
                        LoadState::Ready(..) => return Found::Ready(source, None),
                        LoadState::Loading => return Found::Pending(source),
                        LoadState::Failed => entry.started.elapsed() > REMOTE_RETRY,
                    },
                };
                let in_flight = self
                    .image_preview
                    .loads
                    .iter()
                    .filter(|(source, entry)| {
                        matches!(source, ImageSource::Remote { .. })
                            && matches!(entry.state, LoadState::Loading)
                    })
                    .count();
                if retry && in_flight < MAX_REMOTE_FETCHES {
                    self.start_image_load(&source, None, false);
                    Found::Pending(source)
                } else {
                    Found::Unavailable
                }
            }
            PaneFiles::Unreachable => Found::Unavailable,
        }
    }

    fn find_image_hover(&mut self, column: usize, row: i64) -> Option<ImageHover> {
        let pos = self.get_panes_to_render().into_iter().find(|pos| {
            row >= pos.top as i64
                && row < (pos.top + pos.height) as i64
                && column >= pos.left
                && column < pos.left + pos.width
        })?;
        let pane = Arc::clone(&pos.pane);
        let column = column - pos.left;
        let dims = pane.get_dimensions();
        let viewport_top = self
            .get_viewport(pane.pane_id())
            .unwrap_or(dims.physical_top);
        let stable_row = viewport_top + (row - pos.top as i64) as StableRowIndex;

        let low = (stable_row - WRAPPED_ROWS_EACH_WAY as StableRowIndex).max(0);
        let high = stable_row + WRAPPED_ROWS_EACH_WAY as StableRowIndex + 1;
        let (first_fetched, lines) = pane.get_lines(low..high);
        let hovered = usize::try_from(stable_row - first_fetched).ok()?;
        if hovered >= lines.len() {
            return None;
        }
        let rows: Vec<RowCells> = lines.iter().map(RowCells::from_line).collect();

        // What the pane's paths name; looked up only once a path covers
        // the pointer, since this runs on every mouse move.
        let mut files: Option<PaneFiles> = None;
        // A remote spelling still being fetched, used if nothing previews
        // now.
        let mut pending: Option<ImageHover> = None;

        // The hovered row alone first, so a path that starts a row is not
        // glued to the word that ends the row above; then the joined rows.
        let single = join_rows(&rows, hovered, hovered);
        let joined = join_wrapped_rows(&rows, hovered, dims.cols);

        for (chars, positions) in [single, joined] {
            let hover_idx = match positions
                .iter()
                .position(|&(r, col)| r == hovered && col == column)
            {
                Some(idx) => idx,
                None => continue,
            };
            let text: String = chars.iter().collect();
            for reference in find_image_references(&text) {
                for candidate in &reference.candidates {
                    if !(candidate.start <= hover_idx && hover_idx < reference.end) {
                        continue;
                    }
                    let found = if reference.is_url {
                        Found::Ready(ImageSource::Url(candidate.text.clone()), None)
                    } else {
                        let files = files.get_or_insert_with(|| pane_files(&pane));
                        self.resolve_path(files, &candidate.text)
                    };
                    let (first_r, start_col) = positions[candidate.start];
                    let (last_r, _) = positions[reference.end - 1];
                    let make = |source: ImageSource| ImageHover {
                        pane_id: pane.pane_id(),
                        source,
                        first_row: first_fetched + first_r as StableRowIndex,
                        last_row: first_fetched + last_r as StableRowIndex,
                        start_col,
                        row_texts: lines[first_r..=last_r]
                            .iter()
                            .map(|l| l.as_str().into_owned())
                            .collect(),
                    };
                    match found {
                        Found::Ready(source, modified) => {
                            if !matches!(source, ImageSource::Remote { .. }) {
                                self.ensure_image_loading(&source, modified);
                            }
                            return Some(make(source));
                        }
                        Found::Pending(source) => {
                            if pending.is_none() {
                                pending = Some(make(source));
                            }
                        }
                        Found::Unavailable => {}
                    }
                }
            }
        }
        pending
    }

    fn ensure_image_loading(&mut self, source: &ImageSource, modified: Option<SystemTime>) {
        if let Some(entry) = self.image_preview.loads.get(source) {
            if entry.modified == modified {
                return;
            }
        }
        self.start_image_load(source, modified, false);
    }

    /// Fetches a remote image again if it was loaded long enough ago,
    /// showing the old picture until the new one arrives.
    fn refresh_remote_if_stale(&mut self, source: &ImageSource) {
        let stale = matches!(
            self.image_preview.loads.get(source),
            Some(LoadEntry {
                state: LoadState::Ready(..),
                started,
                ..
            }) if started.elapsed() > REMOTE_REFRESH
        );
        if stale {
            self.start_image_load(source, None, true);
        }
    }

    /// Starts loading `source` on a worker thread. With `keep_shown`, a
    /// picture already loaded stays until the new one replaces it.
    fn start_image_load(&mut self, source: &ImageSource, modified: Option<SystemTime>, keep_shown: bool) {
        let preview = &mut self.image_preview;
        let generation = preview.next_generation;
        preview.next_generation += 1;
        let now = Instant::now();
        match preview.loads.get_mut(source) {
            Some(entry) if keep_shown && matches!(entry.state, LoadState::Ready(..)) => {
                entry.modified = modified;
                entry.started = now;
                entry.generation = generation;
            }
            _ => {
                if !preview.loads.contains_key(source) && preview.loads.len() >= MAX_CACHED_IMAGES {
                    let oldest = preview
                        .loads
                        .iter()
                        .min_by_key(|(_, entry)| entry.started)
                        .map(|(source, _)| source.clone());
                    if let Some(oldest) = oldest {
                        preview.loads.remove(&oldest);
                    }
                }
                preview.loads.insert(
                    source.clone(),
                    LoadEntry {
                        state: LoadState::Loading,
                        modified,
                        started: now,
                        generation,
                    },
                );
            }
        }
        let window = match self.window.clone() {
            Some(window) => window,
            None => return,
        };
        let source = source.clone();
        let spawned = std::thread::Builder::new()
            .name("image-preview".to_string())
            .spawn(move || {
                let result = load_image(&source);
                if let Err(err) = &result {
                    log::debug!("image preview of {source:?}: {err:#}");
                }
                window.notify(TermWindowNotif::Apply(Box::new(move |tw| {
                    if let Some(entry) = tw.image_preview.loads.get_mut(&source) {
                        if entry.generation == generation {
                            entry.state = match result {
                                Ok((data, width, height)) => LoadState::Ready(data, width, height),
                                Err(_) => LoadState::Failed,
                            };
                            tw.image_preview.loads_finished += 1;
                        }
                    }
                    if let Some(window) = tw.window.as_ref() {
                        window.invalidate();
                    }
                })));
            });
        if let Err(err) = spawned {
            log::error!("image preview: cannot start a loader thread: {err:#}");
        }
    }

    /// The pixel rectangle of a pane: left, top, right, bottom.
    fn image_preview_pane_rect(&self, pos: &PositionedPane) -> anyhow::Result<(f32, f32, f32, f32)> {
        let cell_width = self.render_metrics.cell_size.width as f32;
        let cell_height = self.render_metrics.cell_size.height as f32;
        let (padding_left, padding_top) = self.padding_left_top();
        let top_bar_height = if self.show_tab_bar && !self.config.tab_bar_at_bottom {
            self.tab_bar_pixel_height()?
        } else {
            0.
        };
        let border = self.get_os_border();
        let left = padding_left + border.left.get() as f32 + pos.left as f32 * cell_width;
        let top =
            top_bar_height + padding_top + border.top.get() as f32 + pos.top as f32 * cell_height;
        Ok((
            left,
            top,
            left + pos.width as f32 * cell_width,
            top + pos.height as f32 * cell_height,
        ))
    }

    /// The marks of the references on screen in one pane.
    fn find_image_marks(
        &mut self,
        pane: &Arc<dyn Pane>,
        viewport_top: StableRowIndex,
        rows: usize,
        cols: usize,
    ) -> Vec<MarkSpan> {
        let (first, lines) = pane.get_lines(viewport_top..viewport_top + rows as StableRowIndex);
        let offset = first - viewport_top;
        let rows: Vec<RowCells> = lines.iter().map(RowCells::from_line).collect();
        let mut files: Option<PaneFiles> = None;
        let mut spans = reference_marks(&rows, cols, |reference| {
            if reference.is_url {
                return Some(0);
            }
            let files = files.get_or_insert_with(|| pane_files(pane));
            let mut picked = None;
            for (i, candidate) in reference.candidates.iter().enumerate() {
                if let Found::Ready(..) = self.resolve_path(files, &candidate.text) {
                    picked = Some(i);
                    break;
                }
            }
            picked
        });
        for span in &mut spans {
            span.row = (span.row as StableRowIndex + offset) as usize;
        }
        spans
    }

    /// Underlines, with a faint dash in each cell, every reference on
    /// screen that previews. Drawn over the panes, never into their grids.
    pub fn paint_image_marks(&mut self, layers: &mut TripleLayerQuadAllocator) -> anyhow::Result<()> {
        if !self.config.image_preview_on_hover || !self.config.image_preview_underline {
            self.image_preview.marks.clear();
            return Ok(());
        }
        let panes = self.get_panes_to_render();
        self.image_preview
            .marks
            .retain(|id, _| panes.iter().any(|pos| pos.pane.pane_id() == *id));
        let cell_width = self.render_metrics.cell_size.width as f32;
        let cell_height = self.render_metrics.cell_size.height as f32;
        let underline_top = self.render_metrics.descender_row as f32;
        let underline_height = self.render_metrics.underline_height.max(1) as f32;
        for pos in &panes {
            let pane_id = pos.pane.pane_id();
            let dims = pos.pane.get_dimensions();
            let viewport_top = self.get_viewport(pane_id).unwrap_or(dims.physical_top);
            let key = MarkKey {
                viewport_top,
                rows: dims.viewport_rows,
                cols: dims.cols,
                seqno: pos.pane.get_current_seqno(),
                loads_finished: self.image_preview.loads_finished,
            };
            let fresh = matches!(
                self.image_preview.marks.get(&pane_id),
                Some(marks) if marks.key == key && marks.found_at.elapsed() < MARK_RECHECK
            );
            if !fresh {
                let spans = self.find_image_marks(&pos.pane, viewport_top, dims.viewport_rows, dims.cols);
                // A fetch that finished while looking changes nothing found.
                let key = MarkKey {
                    loads_finished: self.image_preview.loads_finished,
                    ..key
                };
                self.image_preview.marks.insert(
                    pane_id,
                    PaneMarks {
                        key,
                        found_at: Instant::now(),
                        spans,
                    },
                );
            }
            let spans = match self.image_preview.marks.get(&pane_id) {
                Some(marks) if !marks.spans.is_empty() => marks.spans.clone(),
                _ => continue,
            };
            let (pane_left, pane_top, _, _) = self.image_preview_pane_rect(pos)?;
            let color = pos.pane.palette().foreground.to_linear().mul_alpha(0.45);
            for span in spans {
                if span.row >= pos.height {
                    continue;
                }
                let y = pane_top + span.row as f32 * cell_height + underline_top;
                for col in span.start_col..span.end_col.min(pos.width) {
                    let x = pane_left + col as f32 * cell_width + cell_width * 0.2;
                    self.filled_rectangle(
                        layers,
                        2,
                        euclid::rect(x, y, cell_width * 0.6, underline_height),
                        color,
                    )?;
                }
            }
        }
        Ok(())
    }

    /// Draws the preview for the hovered reference, on top of the panes.
    pub fn paint_image_preview(
        &mut self,
        layers: &mut TripleLayerQuadAllocator,
    ) -> anyhow::Result<()> {
        if !self.config.image_preview_on_hover || self.allow_images == AllowImage::No {
            return Ok(());
        }
        let hover = match self.image_preview.hover.clone() {
            Some(hover) => hover,
            None => return Ok(()),
        };
        let (data, image_width, image_height) = match self.image_preview.loads.get(&hover.source) {
            Some(LoadEntry {
                state: LoadState::Ready(data, width, height),
                ..
            }) => (Arc::clone(data), *width as f32, *height as f32),
            _ => return Ok(()),
        };
        let pos = match self
            .get_panes_to_render()
            .into_iter()
            .find(|pos| pos.pane.pane_id() == hover.pane_id)
        {
            Some(pos) => pos,
            None => return Ok(()),
        };

        // The rows that named the image were rewritten: draw nothing.
        let (_, lines) = pos.pane.get_lines(hover.first_row..hover.last_row + 1);
        let unchanged = lines.len() == hover.row_texts.len()
            && lines
                .iter()
                .zip(&hover.row_texts)
                .all(|(line, text)| line.as_str() == text.as_str());
        if !unchanged {
            self.image_preview.hover = None;
            return Ok(());
        }

        let dims = pos.pane.get_dimensions();
        let viewport_top = self
            .get_viewport(hover.pane_id)
            .unwrap_or(dims.physical_top);
        let first_screen_row = hover.first_row - viewport_top;
        let last_screen_row = hover.last_row - viewport_top;
        if last_screen_row < 0 || first_screen_row >= dims.viewport_rows as StableRowIndex {
            return Ok(());
        }

        let cell_width = self.render_metrics.cell_size.width as f32;
        let cell_height = self.render_metrics.cell_size.height as f32;
        let (pane_left, pane_top, pane_right, pane_bottom) = self.image_preview_pane_rect(&pos)?;

        let max_height = (self.config.image_preview_max_rows as f32 * cell_height)
            .min(pos.height as f32 * cell_height - 2. * FRAME_PIXELS);
        let max_width = pos.width as f32 * cell_width - 2. * FRAME_PIXELS;
        if max_height < cell_height || max_width < cell_width {
            return Ok(());
        }
        let scale = (max_width / image_width)
            .min(max_height / image_height)
            .min(1.0);
        let width = (image_width * scale).floor();
        let height = (image_height * scale).floor();

        let below = pane_top + (last_screen_row + 1) as f32 * cell_height + FRAME_PIXELS;
        let above = pane_top + first_screen_row as f32 * cell_height - FRAME_PIXELS - height;
        let y = if below + height + FRAME_PIXELS <= pane_bottom {
            below
        } else if above - FRAME_PIXELS >= pane_top {
            above
        } else {
            (pane_bottom - FRAME_PIXELS - height).max(pane_top + FRAME_PIXELS)
        };
        let x = (pane_left + hover.start_col as f32 * cell_width + FRAME_PIXELS)
            .min(pane_right - FRAME_PIXELS - width)
            .max(pane_left + FRAME_PIXELS);

        let gl_state = self.render_state.as_ref().unwrap();
        let cached = gl_state
            .glyph_cache
            .borrow_mut()
            .cached_image(&data, None, self.allow_images);
        let sprite = match cached {
            Ok((sprite, next_due, _)) => {
                self.update_next_frame_time(next_due);
                sprite
            }
            Err(err) => {
                if err
                    .root_cause()
                    .downcast_ref::<OutOfTextureSpace>()
                    .is_some()
                {
                    // paint_impl grows the atlas and paints again
                    return Err(err);
                }
                log::warn!("image preview of {:?}: {err:#}", hover.source);
                if let Some(entry) = self.image_preview.loads.get_mut(&hover.source) {
                    entry.state = LoadState::Failed;
                }
                return Ok(());
            }
        };

        let palette = pos.pane.palette();
        self.filled_rectangle(
            layers,
            2,
            euclid::rect(
                x - FRAME_PIXELS,
                y - FRAME_PIXELS,
                width + 2. * FRAME_PIXELS,
                height + 2. * FRAME_PIXELS,
            ),
            palette.foreground.to_linear().mul_alpha(0.5),
        )?;
        self.filled_rectangle(
            layers,
            2,
            euclid::rect(x, y, width, height),
            palette.background.to_linear(),
        )?;

        let left_offset = self.dimensions.pixel_width as f32 / 2.;
        let top_offset = self.dimensions.pixel_height as f32 / 2.;
        let mut quad = layers.allocate(2)?;
        quad.set_position(
            x - left_offset,
            y - top_offset,
            x + width - left_offset,
            y + height - top_offset,
        );
        quad.set_texture(sprite.texture_coords());
        quad.set_fg_color(LinearRgba::with_components(1., 1., 1., 1.));
        quad.set_hsv(None);
        quad.set_has_color(true);
        Ok(())
    }
}

#[cfg(test)]
mod test {
    use super::*;

    fn texts(line: &str) -> Vec<Vec<String>> {
        find_image_references(line)
            .into_iter()
            .map(|r| r.candidates.into_iter().map(|c| c.text).collect())
            .collect()
    }

    #[test]
    fn extensions() {
        assert!(has_image_extension("a.png"));
        assert!(has_image_extension("A.JPEG"));
        assert!(has_image_extension("x/y.webp"));
        assert!(has_image_extension("y.gif"));
        assert!(!has_image_extension(".png"));
        assert!(!has_image_extension("a.pngx"));
        assert!(!has_image_extension("a.svg"));
        assert!(!has_image_extension("png"));
    }

    #[test]
    fn claude_code_read_tool_line() {
        assert_eq!(
            texts("\u{23fa} Read(/tmp/dnq/g-3.png)"),
            vec![vec!["/tmp/dnq/g-3.png".to_string()]]
        );
        assert_eq!(
            texts("\u{23fa} Read(outputs/explore/fig_stitch_cascade.png)"),
            vec![vec!["outputs/explore/fig_stitch_cascade.png".to_string()]]
        );
        // The result line names no file.
        assert!(texts("  \u{23bf}  Read image (52.3KB)").is_empty());
    }

    #[test]
    fn prose_markdown_and_backticks() {
        assert_eq!(
            texts("Saved the figure to `~/Projects/x/fig1.PNG`, see it."),
            vec![vec!["~/Projects/x/fig1.PNG".to_string()]]
        );
        assert_eq!(
            texts("![chart](figures/chart.jpg) and **out/b.jpeg**."),
            vec![
                vec!["figures/chart.jpg".to_string()],
                vec!["out/b.jpeg".to_string()]
            ]
        );
        assert_eq!(
            texts("Wrote /tmp/a.png."),
            vec![vec!["/tmp/a.png".to_string()]]
        );
        assert_eq!(
            texts("open file:///tmp/a%20b.png"),
            vec![vec!["/tmp/a%20b.png".to_string()]]
        );
    }

    #[test]
    fn not_images() {
        assert!(texts("main.rs foo.pngs a.png_old .png e.g. v1.2").is_empty());
        assert!(texts("see plot.svg and paper.pdf").is_empty());
    }

    #[test]
    fn truncated_with_ellipsis_is_dropped() {
        assert!(texts("Read(\u{2026}/sheets/x1_01.png)").is_empty());
    }

    #[test]
    fn names_with_spaces_offer_longest_first() {
        let line = "Read(/Users/b/Desktop/Screenshot 2026-11-08 at 10.12.33\u{202f}AM.png)";
        assert_eq!(
            texts(line),
            vec![vec![
                "/Users/b/Desktop/Screenshot 2026-11-08 at 10.12.33\u{202f}AM.png".to_string(),
                "AM.png".to_string(),
            ]]
        );
        let line = "cp /tmp/a.png /tmp/b c.png";
        assert_eq!(
            texts(line),
            vec![
                vec!["/tmp/a.png".to_string()],
                vec![
                    "/tmp/a.png /tmp/b c.png".to_string(),
                    "/tmp/b c.png".to_string(),
                    "c.png".to_string()
                ]
            ]
        );
    }

    #[test]
    fn urls() {
        assert_eq!(
            texts("see https://example.com/img/cat.png?size=2 now"),
            vec![vec!["https://example.com/img/cat.png?size=2".to_string()]]
        );
        assert_eq!(
            texts("[x](https://example.com/a.webp)."),
            vec![vec!["https://example.com/a.webp".to_string()]]
        );
        // A page, not an image; and the image name inside it is not a path.
        assert!(texts("https://example.com/a.png/view https://claude.ai/x").is_empty());
    }

    #[test]
    fn spans_point_at_the_reference() {
        let refs = find_image_references("ab Read(/x/y.png) z");
        assert_eq!(refs.len(), 1);
        assert_eq!(refs[0].candidates[0].start, 8);
        assert_eq!(refs[0].end, 16);
    }

    #[test]
    fn wrapped_path_joins_across_rows() {
        let width = 20;
        let rows = vec![
            RowCells::from_str("\u{23fa} Read(/Users/bb/Pr"),
            RowCells::from_str("  ojects/fig.png)"),
            RowCells::from_str("  \u{23bf}  Read image"),
        ];
        // The first row is full, so rows 0 and 1 join; row 1 is not full,
        // so row 2 stays out.
        for hovered in [0, 1] {
            let (chars, positions) = join_wrapped_rows(&rows, hovered, width);
            let text: String = chars.iter().collect();
            assert_eq!(text, "\u{23fa} Read(/Users/bb/Projects/fig.png)");
            let refs = find_image_references(&text);
            assert_eq!(refs[0].candidates[0].text, "/Users/bb/Projects/fig.png");
            // The reference starts on row 0, column 7 and ends on row 1.
            assert_eq!(positions[refs[0].candidates[0].start], (0, 7));
            assert_eq!(positions[refs[0].end - 1].0, 1);
        }
        let (chars, _) = join_wrapped_rows(&rows, 2, width);
        assert_eq!(chars.iter().collect::<String>(), "  \u{23bf}  Read image");
    }

    #[test]
    fn resolves_relative_home_and_absolute() {
        let dir = tempfile::tempdir().unwrap();
        let sub = dir.path().join("out");
        std::fs::create_dir(&sub).unwrap();
        let file = sub.join("Screenshot 1\u{202f}AM.png");
        std::fs::write(&file, b"x").unwrap();
        assert_eq!(
            resolve_local_path("out/Screenshot 1\u{202f}AM.png", Some(dir.path()), None),
            Some(file.clone())
        );
        assert_eq!(
            resolve_local_path("~/out/Screenshot 1\u{202f}AM.png", None, Some(dir.path())),
            Some(file.clone())
        );
        let absolute = file.to_str().unwrap().to_string();
        assert_eq!(resolve_local_path(&absolute, None, None), Some(file));
        assert_eq!(
            resolve_local_path("out/missing.png", Some(dir.path()), None),
            None
        );
        assert_eq!(resolve_local_path("out", Some(dir.path()), None), None);
        assert_eq!(resolve_local_path("relative.png", None, None), None);
    }

    fn strings(words: &[&str]) -> Vec<String> {
        words.iter().map(|w| w.to_string()).collect()
    }

    #[test]
    fn ssh_fetch_keeps_destination_and_options() {
        let argv = strings(&[
            "/usr/bin/ssh",
            "-t",
            "-p",
            "2222",
            "-L8080:localhost:80",
            "-i",
            "/k/id",
            "imac",
            "tmux -L pi-gate attach -t =rc-x",
        ]);
        let (ssh, remote) = ssh_fetch_command(&argv).unwrap();
        assert_eq!(
            ssh,
            strings(&[
                "/usr/bin/ssh",
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=5",
                "-o",
                "ClearAllForwardings=yes",
                "-o",
                "RemoteCommand=none",
                "-p",
                "2222",
                "-i",
                "/k/id",
                "-T",
                "imac",
            ])
        );
        assert_eq!(remote, strings(&["tmux -L pi-gate attach -t =rc-x"]));
        let (ssh, remote) = ssh_fetch_command(&strings(&["ssh", "-tA", "host"])).unwrap();
        assert_eq!(ssh.last().unwrap(), "host");
        assert!(ssh.contains(&"-A".to_string()));
        assert!(!ssh.contains(&"-t".to_string()));
        assert!(remote.is_empty());
        assert_eq!(ssh_fetch_command(&strings(&["ssh", "-p"])), None);
        assert_eq!(ssh_fetch_command(&strings(&["ssh", "-V"])), None);
    }

    #[test]
    fn tmux_cd_finds_the_attached_session() {
        assert_eq!(
            tmux_cd_command(&strings(&["tmux -L pi-gate attach -t =rc-x"])).unwrap(),
            "d=$(tmux -L 'pi-gate' display-message -p -t '=rc-x:' '#{pane_current_path}' 2>/dev/null) && [ -n \"$d\" ] && cd -- \"$d\""
        );
        assert!(tmux_cd_command(&strings(&["/usr/bin/tmux", "a", "-tmain"]))
            .unwrap()
            .contains("-t 'main:'"));
        assert_eq!(tmux_cd_command(&strings(&["tmux", "new", "-s", "x"])), None);
        assert_eq!(tmux_cd_command(&strings(&["htop"])), None);
        assert_eq!(tmux_cd_command(&[]), None);
    }

    #[test]
    fn remote_read_quotes_the_path() {
        assert_eq!(
            remote_read_command("/tmp/it's.png", None).unwrap(),
            "f='/tmp/it'\\''s.png' && test -f \"$f\" && exec cat -- \"$f\""
        );
        assert_eq!(
            remote_read_command("~/a b.png", None).unwrap(),
            "f=\"$HOME\"/'a b.png' && test -f \"$f\" && exec cat -- \"$f\""
        );
        assert_eq!(remote_read_command("out/x.png", None), None);
        assert_eq!(
            remote_read_command("out/x.png", Some("cd /w")).unwrap(),
            "cd /w && f='out/x.png' && test -f \"$f\" && exec cat -- \"$f\""
        );
        assert_eq!(remote_read_command("/tmp/x.txt", None), None);
    }

    #[test]
    fn remote_read_runs_in_a_shell() {
        let dir = tempfile::tempdir().unwrap();
        let name = "it's here.png";
        std::fs::write(dir.path().join(name), b"bytes").unwrap();
        let path = dir.path().join(name).to_string_lossy().into_owned();
        let run = |command: String| {
            std::process::Command::new("sh")
                .arg("-c")
                .arg(command)
                .output()
                .unwrap()
        };
        let out = run(remote_read_command(&path, None).unwrap());
        assert!(out.status.success());
        assert_eq!(out.stdout, b"bytes");
        let cd = format!("cd -- {}", sh_quote(&dir.path().to_string_lossy()));
        let out = run(remote_read_command(name, Some(&cd)).unwrap());
        assert_eq!(out.stdout, b"bytes");
        let out = run(remote_read_command("/nonexistent/x.png", None).unwrap());
        assert!(!out.status.success());
    }

    #[test]
    fn marks_cover_each_reference_once() {
        let width = 20;
        let rows: Vec<RowCells> = [
            "see /tmp/a.png ok   ",
            "xx /tmp/long/path/to",
            "/b.png and c.txt",
        ]
        .iter()
        .map(|r| RowCells::from_str(r))
        .collect();
        let spans = reference_marks(&rows, width, |_| Some(0));
        assert_eq!(
            spans,
            vec![
                MarkSpan { row: 0, start_col: 4, end_col: 14 },
                MarkSpan { row: 1, start_col: 3, end_col: 20 },
                // Found alone and as the end of the joined path; drawn once.
                MarkSpan { row: 2, start_col: 0, end_col: 6 },
            ]
        );
        assert!(reference_marks(&rows, width, |_| None).is_empty());
    }

    #[test]
    fn decodes_and_scales_down() {
        let mut encoded = std::io::Cursor::new(vec![]);
        image::RgbaImage::from_pixel(4096, 1024, image::Rgba([10, 20, 30, 255]))
            .write_to(&mut encoded, image::ImageFormat::Png)
            .unwrap();
        let (_, width, height) = decode_for_preview(encoded.get_ref()).unwrap();
        assert_eq!((width, height), (2048, 512));
        assert!(decode_for_preview(b"not an image").is_err());
    }
}
