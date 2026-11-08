//! The parts of fn dictation that need no microphone, socket or pane: the
//! running transcript, the keystrokes that turn what was typed into what the
//! transcript now says, the 16 kHz resampler, and the request details read
//! from Claude Code's files. Plain std, so these tests also run on their own:
//! `rustc --edition 2021 --test typing.rs && ./typing`.

/// The running text of a dictation. The service sends the whole text of the
/// current phrase each time (TranscriptText or TranscriptInterim) and commits
/// it with TranscriptEndpoint, after which a new phrase starts.
#[derive(Debug, Default)]
pub struct Transcript {
    committed: String,
    pending: String,
}

impl Transcript {
    /// The current phrase now reads `data`.
    pub fn running(&mut self, data: &str) {
        self.pending = data.to_string();
    }

    /// The current phrase is final.
    pub fn endpoint(&mut self) {
        let pending = std::mem::take(&mut self.pending);
        self.committed = join(&self.committed, &pending);
    }

    /// Everything said so far.
    pub fn text(&self) -> String {
        join(&self.committed, &self.pending)
    }
}

/// Phrases are joined by one space unless one side already has it.
fn join(a: &str, b: &str) -> String {
    if a.is_empty() {
        return b.to_string();
    }
    if b.is_empty() {
        return a.to_string();
    }
    let space = !a.ends_with(char::is_whitespace) && !b.starts_with(char::is_whitespace);
    format!("{a}{}{b}", if space { " " } else { "" })
}

/// Keystrokes that turn the typed text into the wanted text: delete the
/// typed characters after the common prefix, then type the rest.
#[derive(Debug, PartialEq, Eq)]
pub struct Edit {
    pub backspaces: usize,
    pub text: String,
}

impl Edit {
    pub fn is_empty(&self) -> bool {
        self.backspaces == 0 && self.text.is_empty()
    }
}

pub fn edit_between(typed: &str, wanted: &str) -> Edit {
    let mut prefix = 0;
    for ((i, a), b) in typed.char_indices().zip(wanted.chars()) {
        if a != b {
            break;
        }
        prefix = i + a.len_utf8();
    }
    Edit {
        backspaces: typed[prefix..].chars().count(),
        text: wanted[prefix..].to_string(),
    }
}

/// The sample rate the service takes.
pub const OUTPUT_RATE: u32 = 16_000;

/// Mono f32 samples at the microphone's rate to 16-bit samples at 16 kHz.
/// Each output sample is the mean of the input samples in its interval,
/// a box filter that is enough for speech.
#[derive(Debug)]
pub struct Resampler {
    input_rate: u64,
    /// Input samples taken since the last output sample, times the output
    /// rate, so that the intervals add up exactly (44.1 kHz is not a whole
    /// multiple of 16 kHz).
    taken: u64,
    sum: f32,
    count: u32,
    last: i16,
}

impl Resampler {
    pub fn new(input_rate: u32) -> Self {
        Self {
            input_rate: input_rate.max(1) as u64,
            taken: 0,
            sum: 0.,
            count: 0,
            last: 0,
        }
    }

    pub fn push(&mut self, input: &[f32], out: &mut Vec<i16>) {
        for &x in input {
            self.sum += x;
            self.count += 1;
            self.taken += OUTPUT_RATE as u64;
            while self.taken >= self.input_rate {
                if self.count > 0 {
                    self.last = to_i16(self.sum / self.count as f32);
                    self.sum = 0.;
                    self.count = 0;
                }
                out.push(self.last);
                self.taken -= self.input_rate;
            }
        }
    }
}

fn to_i16(x: f32) -> i16 {
    (x.clamp(-1., 1.) * i16::MAX as f32).round() as i16
}

/// The x-config-keyterms header: the terms, trimmed, without commas, joined
/// by commas, as many whole terms as fit in the service's 1024 characters.
pub const KEYTERMS_MAX_CHARS: usize = 1024;

pub fn keyterms_header(terms: &[String]) -> Option<String> {
    let mut header = String::new();
    for term in terms {
        let term = term.replace(',', " ");
        let term = term.trim();
        if term.is_empty() {
            continue;
        }
        let extra = if header.is_empty() { 0 } else { 1 };
        if header.chars().count() + extra + term.chars().count() > KEYTERMS_MAX_CHARS {
            break;
        }
        if extra == 1 {
            header.push(',');
        }
        header.push_str(term);
    }
    (!header.is_empty()).then_some(header)
}

/// The newest Claude Code version among the names in its versions folder
/// (~/.local/share/claude/versions holds one file per version, 2.1.319).
pub fn newest_version<I: IntoIterator<Item = String>>(names: I) -> Option<String> {
    fn parse(name: &str) -> Option<Vec<u64>> {
        name.split('.').map(|p| p.parse().ok()).collect()
    }
    names
        .into_iter()
        .filter_map(|n| parse(&n).map(|v| (v, n)))
        .max()
        .map(|(_, n)| n)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn edit(backspaces: usize, text: &str) -> Edit {
        Edit {
            backspaces,
            text: text.to_string(),
        }
    }

    #[test]
    fn edits_type_only_what_is_new() {
        assert_eq!(edit_between("", "hello"), edit(0, "hello"));
        assert_eq!(edit_between("hello", "hello world"), edit(0, " world"));
        assert_eq!(edit_between("hello", "hello"), edit(0, ""));
        assert!(edit_between("hello", "hello").is_empty());
    }

    #[test]
    fn edits_delete_a_revised_tail() {
        assert_eq!(edit_between("hello word", "hello world"), edit(1, "ld"));
        assert_eq!(edit_between("I scream", "ice cream"), edit(8, "ice cream"));
        assert_eq!(edit_between("hello there", "hello"), edit(6, ""));
    }

    #[test]
    fn edits_count_characters_not_bytes() {
        assert_eq!(edit_between("café au", "café"), edit(3, ""));
        assert_eq!(edit_between("naïve", "naive"), edit(3, "ive"));
    }

    #[test]
    fn transcript_joins_committed_phrases() {
        let mut t = Transcript::default();
        t.running("hello");
        t.running("hello world");
        assert_eq!(t.text(), "hello world");
        t.endpoint();
        assert_eq!(t.text(), "hello world");
        t.running("again");
        assert_eq!(t.text(), "hello world again");
        t.endpoint();
        t.endpoint();
        assert_eq!(t.text(), "hello world again");
        t.running(" spaced");
        assert_eq!(t.text(), "hello world again spaced");
    }

    #[test]
    fn resampler_averages_down_to_16k() {
        let mut out = vec![];
        let mut r = Resampler::new(48_000);
        r.push(&[0.5; 48], &mut out);
        assert_eq!(out, vec![16384; 16]);

        let mut out = vec![];
        let mut r = Resampler::new(44_100);
        r.push(&[0.; 441], &mut out);
        assert_eq!(out.len(), 160);

        let mut out = vec![];
        let mut r = Resampler::new(16_000);
        r.push(&[2., -2., 0.25], &mut out);
        assert_eq!(out, vec![32767, -32767, 8192]);
    }

    #[test]
    fn resampler_carries_fractions_across_pushes() {
        let mut out = vec![];
        let mut r = Resampler::new(48_000);
        r.push(&[1.; 2], &mut out);
        assert!(out.is_empty());
        r.push(&[1.; 4], &mut out);
        assert_eq!(out, vec![32767, 32767]);
    }

    #[test]
    fn keyterms_fit_the_header() {
        let terms: Vec<String> = ["Topaz", " ClaudeHUD ", "", "a,b"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(
            keyterms_header(&terms).as_deref(),
            Some("Topaz,ClaudeHUD,a b")
        );
        assert_eq!(keyterms_header(&[]), None);
        let long = vec!["x".repeat(600), "y".repeat(500), "z".repeat(10)];
        let header = keyterms_header(&long).unwrap();
        assert_eq!(header, "x".repeat(600));
    }

    #[test]
    fn newest_version_compares_numbers() {
        let names = ["2.1.99", "2.1.319", "2.1.318", "notes"].map(String::from);
        assert_eq!(newest_version(names).as_deref(), Some("2.1.319"));
        assert_eq!(newest_version(Vec::new()), None);
    }
}
