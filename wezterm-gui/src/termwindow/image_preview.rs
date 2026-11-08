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
//! A path is drawn only if it names an existing file and the pane runs on
//! this machine (a local domain pane whose foreground process is not ssh or
//! mosh); a file that does not decode, or a URL whose fetch fails, draws
//! nothing. Files are read, and URLs fetched, on a worker thread; the image
//! is decoded and scaled down there too, so the GUI thread only uploads it.

use crate::quad::{QuadTrait, TripleLayerQuadAllocator, TripleLayerQuadAllocatorTrait};
use crate::termwindow::render::paint::AllowImage;
use crate::termwindow::TermWindowNotif;
use ::window::bitmaps::atlas::OutOfTextureSpace;
use ::window::WindowOps;
use anyhow::{anyhow, Context};
use mux::domain::LocalDomain;
use mux::pane::{CachePolicy, Pane, PaneId};
use mux::Mux;
use std::collections::HashMap;
use std::convert::TryFrom;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use termwiz::image::{ImageData, ImageDataType};
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
/// Number of decoded previews kept before the cache is emptied.
const MAX_CACHED_IMAGES: usize = 48;
const FETCH_TIMEOUT: Duration = Duration::from_secs(10);
/// How many rows above and below the hovered row a wrapped reference may span.
const WRAPPED_ROWS_EACH_WAY: usize = 3;
/// Width in pixels of the frame drawn around the preview.
const FRAME_PIXELS: f32 = 2.0;

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

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ImageSource {
    File(PathBuf),
    Url(String),
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
}

#[derive(Default)]
pub struct ImagePreview {
    hover: Option<ImageHover>,
    loads: HashMap<ImageSource, LoadEntry>,
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
    };
    decode_for_preview(&bytes)
}

/// Whether the paths a pane prints name files on this machine: the pane
/// belongs to the local domain and is not running ssh or mosh in front.
fn pane_paths_are_local(pane: &Arc<dyn Pane>) -> bool {
    let is_local_domain = Mux::get()
        .get_domain(pane.domain_id())
        .map(|domain| domain.downcast_ref::<LocalDomain>().is_some())
        .unwrap_or(false);
    if !is_local_domain {
        return false;
    }
    match pane.get_foreground_process_name(CachePolicy::AllowStale) {
        Some(name) => {
            let base = Path::new(&name)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("");
            !matches!(base, "ssh" | "mosh" | "mosh-client" | "et")
        }
        None => true,
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

        // Whether paths are local, the working directory and the home
        // directory; looked up only once a path covers the pointer, since
        // this runs on every mouse move.
        let mut local_context: Option<(bool, Option<PathBuf>, Option<PathBuf>)> = None;

        // The hovered row alone first, so a path that starts a row is not
        // glued to the word that ends the row above; then the joined rows.
        let single: (Vec<char>, Vec<(usize, usize)>) = {
            let row = &rows[hovered];
            (
                row.chars.clone(),
                row.cols.iter().map(|&col| (hovered, col)).collect(),
            )
        };
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
                    let (source, modified) = if reference.is_url {
                        (ImageSource::Url(candidate.text.clone()), None)
                    } else {
                        let (paths_are_local, cwd, home) = local_context.get_or_insert_with(|| {
                            let local = pane_paths_are_local(&pane);
                            let cwd = if local {
                                pane.get_current_working_dir(CachePolicy::AllowStale)
                                    .and_then(|url| url.to_file_path().ok())
                            } else {
                                None
                            };
                            (local, cwd, dirs_next::home_dir())
                        });
                        if !*paths_are_local {
                            continue;
                        }
                        match resolve_local_path(&candidate.text, cwd.as_deref(), home.as_deref()) {
                            Some(path) => {
                                let modified = file_modified(&path);
                                (ImageSource::File(path), modified)
                            }
                            None => continue,
                        }
                    };
                    let (first_r, start_col) = positions[candidate.start];
                    let (last_r, _) = positions[reference.end - 1];
                    self.ensure_image_loading(&source, modified);
                    return Some(ImageHover {
                        pane_id: pane.pane_id(),
                        source,
                        first_row: first_fetched + first_r as StableRowIndex,
                        last_row: first_fetched + last_r as StableRowIndex,
                        start_col,
                        row_texts: lines[first_r..=last_r]
                            .iter()
                            .map(|l| l.as_str().into_owned())
                            .collect(),
                    });
                }
            }
        }
        None
    }

    fn ensure_image_loading(&mut self, source: &ImageSource, modified: Option<SystemTime>) {
        if let Some(entry) = self.image_preview.loads.get(source) {
            if entry.modified == modified {
                return;
            }
        }
        if self.image_preview.loads.len() >= MAX_CACHED_IMAGES {
            self.image_preview.loads.clear();
        }
        self.image_preview.loads.insert(
            source.clone(),
            LoadEntry {
                state: LoadState::Loading,
                modified,
            },
        );
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
                        if entry.modified == modified {
                            entry.state = match result {
                                Ok((data, width, height)) => LoadState::Ready(data, width, height),
                                Err(_) => LoadState::Failed,
                            };
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
        let (padding_left, padding_top) = self.padding_left_top();
        let top_bar_height = if self.show_tab_bar && !self.config.tab_bar_at_bottom {
            self.tab_bar_pixel_height()?
        } else {
            0.
        };
        let border = self.get_os_border();
        let pane_left = padding_left + border.left.get() as f32 + pos.left as f32 * cell_width;
        let pane_top =
            top_bar_height + padding_top + border.top.get() as f32 + pos.top as f32 * cell_height;
        let pane_right = pane_left + pos.width as f32 * cell_width;
        let pane_bottom = pane_top + pos.height as f32 * cell_height;

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
