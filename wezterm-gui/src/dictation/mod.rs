//! Hold fn to dictate (Topaz, macOS; config.fn_dictation). While fn is held
//! the microphone streams to Anthropic's speech to text, the service behind
//! Claude Code's /voice, and the words are typed into the pane that was
//! active at fn down as they arrive. On release the stream closes at once and
//! only the tail is outstanding (about 125 ms: speed probe, 2026-11-08).
//!
//! The protocol is Claude Code's own (2.1.319): a WebSocket with the OAuth
//! token of Claude Code's login; KeepAlive on open and every 8 s; binary
//! 16-bit little-endian 16 kHz mono PCM; CloseStream at the end. The server
//! sends the running text of the current phrase as TranscriptText (or
//! TranscriptInterim) and commits it with TranscriptEndpoint. With the
//! conversation engine on it sends no endpoint until after CloseStream, so
//! the running text is typed live and any revision is deleted and retyped.
//!
//! The token is read from the Keychain at each use and never kept or logged;
//! on a 401 it is read once more, since Claude Code refreshes it.

pub mod control;
pub mod typing;

use anyhow::{anyhow, Context};
use control::{Command, Session, Shared, Timing};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use mux::pane::PaneId;
use mux::Mux;
use std::io::ErrorKind;
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender, TryRecvError};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};
use tungstenite::client::IntoClientRequest;
use tungstenite::http::HeaderValue;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message, WebSocket};
use typing::{edit_between, keyterms_header, newest_version, Resampler, Transcript};
use wezterm_term::{KeyCode, KeyModifiers};

/// The service's tuning, as Claude Code sends it. The speed probe found the
/// server ignores endpointing_ms and utterance_end_ms (100 to 3000 ms all
/// behave the same), so these stay at Claude Code's values.
const ENDPOINTING_MS: u32 = 300;
const UTTERANCE_END_MS: u32 = 1000;
const LANGUAGE: &str = "en";

fn service_url() -> String {
    format!(
        "wss://api.anthropic.com/api/ws/speech_to_text/voice_stream\
         ?encoding=linear16&sample_rate={}&channels=1\
         &endpointing_ms={ENDPOINTING_MS}&utterance_end_ms={UTTERANCE_END_MS}\
         &language={LANGUAGE}&use_conversation_engine=true",
        typing::OUTPUT_RATE
    )
}

const KEEP_ALIVE: &str = r#"{"type":"KeepAlive"}"#;
const CLOSE_STREAM: &str = r#"{"type":"CloseStream"}"#;
const KEEP_ALIVE_EVERY: Duration = Duration::from_secs(8);
/// Audio goes out in 40 ms chunks (the probe suggests small chunks save
/// 50 to 80 ms over 100 ms ones).
const CHUNK_SAMPLES: usize = typing::OUTPUT_RATE as usize / 25;
/// How long the socket read waits before the loop sends audio again.
const POLL: Duration = Duration::from_millis(10);
/// After CloseStream, how long to wait for the final text.
const FINAL_WAIT: Duration = Duration::from_secs(3);
/// How long the Keychain read, DNS, TCP, TLS and the WebSocket handshake may
/// take together, the read again after a 401 included.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

const KEYCHAIN_SERVICE: &str = "Claude Code-credentials";
/// Used in the User-Agent only when Claude Code's versions folder is unreadable.
const FALLBACK_CLAUDE_VERSION: &str = "2.1.319";

/// Shows a brief notice in the pane that was active at fn down; called on
/// the session's thread.
pub type Notice = Box<dyn Fn(String) + Send>;

/// Start a session for one hold of fn, pressed at `pressed`. `notice` is
/// used when Claude Code's sign in is missing, expired or refused, which Ben
/// must fix himself.
pub fn start(pane_id: PaneId, keyterms: Vec<String>, notice: Notice, pressed: Instant) -> Session {
    Session::spawn(pressed, move |commands, shared| {
        match run(pane_id, &keyterms, &commands, &shared) {
            Ok(end) => shared.timing.log(format_args!("session end ({end})")),
            Err(err) => {
                shared.timing.log(format_args!("session end (error)"));
                log::error!("fn dictation: {err:#}");
                if let Some(refused) = sign_in_refused(&err) {
                    notice(refused.to_string());
                }
            }
        }
    })
}

/// Claude Code's sign in is missing, expired or refused: retrying cannot help
/// until Ben signs in again, so the pane shows it.
#[derive(Debug)]
struct SignInRefused(&'static str);

impl std::fmt::Display for SignInRefused {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.write_str(self.0)
    }
}

impl std::error::Error for SignInRefused {}

const NOT_SIGNED_IN: SignInRefused = SignInRefused(
    "fn dictation needs Claude Code's sign in, and the Keychain has none. \
     Run claude and sign in with /login, then hold fn again.",
);
const TOKEN_REFUSED: SignInRefused = SignInRefused(
    "fn dictation: the speech to text service refused Claude Code's sign in \
     (the token has expired or was revoked). Run claude so that it refreshes \
     it, or sign in again with /login, then hold fn again.",
);

fn sign_in_refused(err: &anyhow::Error) -> Option<&SignInRefused> {
    err.downcast_ref::<SignInRefused>()
}

type Socket = WebSocket<MaybeTlsStream<TcpStream>>;

/// Milliseconds of audio in `samples` samples at the rate sent.
fn audio_ms(samples: usize) -> usize {
    samples * 1000 / typing::OUTPUT_RATE as usize
}

/// How a session ended, for its timing line.
type End = &'static str;

fn run(
    pane_id: PaneId,
    keyterms: &[String],
    commands: &Receiver<Command>,
    shared: &Shared,
) -> anyhow::Result<End> {
    let timing = &shared.timing;
    // Capture first, so that audio buffers while the socket opens.
    let (audio_tx, audio) = channel::<Vec<f32>>();
    let first_buffer = Arc::new(OnceLock::new());
    let (stream, input_rate) = start_capture(audio_tx, Arc::clone(&first_buffer), timing)?;
    let mut stream = Some(stream);
    let mut resampler = Resampler::new(input_rate);
    let mut first_buffer_logged = false;
    let log_first_buffer = |logged: &mut bool| {
        if !*logged {
            if let Some(&(at, frames)) = first_buffer.get() {
                *logged = true;
                log::info!(
                    "fn dictation timing: +{} ms first audio buffer received \
                     ({frames} frames, {} ms at {input_rate} Hz; logged at +{} ms)",
                    timing.ms_at(at),
                    frames as u64 * 1000 / input_rate.max(1) as u64,
                    timing.ms()
                );
            }
        }
    };

    let Some((mut socket, mut finish_now)) = connect_in_time(keyterms, commands, timing)? else {
        return Ok("cancelled while connecting");
    };
    log_first_buffer(&mut first_buffer_logged);
    set_read_timeout(&socket, POLL)?;
    socket.send(Message::text(KEEP_ALIVE))?;
    let mut last_keep_alive = Instant::now();

    let cancelled = shared.cancel_flag();
    let mut pcm: Vec<i16> = vec![];
    let mut transcript = Transcript::default();
    let mut typed = String::new();
    let mut final_by: Option<Instant> = None;
    // For the timing lines: audio sent, messages received, edits typed.
    let mut sent_samples = 0;
    let mut messages = 0;
    let mut first_interim = true;
    let mut first_text = true;
    let mut last_text_at: Option<Instant> = None;
    let end: End;

    loop {
        // Commands are read in the final wait too, so that a key Ben types
        // then stops the dictation before its last edit.
        let command = if std::mem::take(&mut finish_now) {
            Ok(Command::Finish)
        } else {
            commands.try_recv()
        };
        match command {
            Ok(Command::Cancel) | Err(TryRecvError::Disconnected) => {
                socket.close(None).ok();
                return Ok("cancelled");
            }
            _ if shared.cancelled() => {
                socket.close(None).ok();
                return Ok("cancelled");
            }
            Ok(Command::Finish) if final_by.is_none() => {
                // Stop the microphone, send all that it heard, close.
                drop(stream.take());
                while let Ok(samples) = audio.try_recv() {
                    resampler.push(&samples, &mut pcm);
                }
                let tail = send_audio(&mut socket, &mut pcm, true)?;
                sent_samples += tail;
                socket.send(Message::text(CLOSE_STREAM))?;
                timing.log(format_args!(
                    "CloseStream sent (last {} ms of audio with it, {} ms sent in all)",
                    audio_ms(tail),
                    audio_ms(sent_samples)
                ));
                final_by = Some(Instant::now() + FINAL_WAIT);
            }
            Ok(Command::Finish) => {}
            Err(TryRecvError::Empty) => match final_by {
                None => {
                    while let Ok(samples) = audio.try_recv() {
                        resampler.push(&samples, &mut pcm);
                    }
                    log_first_buffer(&mut first_buffer_logged);
                    let sent = send_audio(&mut socket, &mut pcm, false)?;
                    if sent > 0 && sent_samples == 0 {
                        timing.log(format_args!(
                            "first audio chunk sent (flushed {} ms of buffered audio \
                             in {} chunks at once)",
                            audio_ms(sent),
                            sent.div_ceil(CHUNK_SAMPLES)
                        ));
                    }
                    sent_samples += sent;
                    if last_keep_alive.elapsed() >= KEEP_ALIVE_EVERY {
                        socket.send(Message::text(KEEP_ALIVE))?;
                        last_keep_alive = Instant::now();
                    }
                }
                Some(by) if Instant::now() >= by => {
                    log::warn!("fn dictation: no final text within {FINAL_WAIT:?}");
                    end = "no final text in time";
                    break;
                }
                Some(_) => {}
            },
        }

        match socket.read() {
            Ok(Message::Text(text)) => {
                let message: serde_json::Value = match serde_json::from_str(text.as_str()) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                let kind = message.get("type").and_then(|t| t.as_str());
                messages += 1;
                match kind {
                    Some(kind @ ("TranscriptText" | "TranscriptInterim")) => {
                        let data = message.get("data").and_then(|d| d.as_str());
                        let chars = data.map_or(0, |d| d.chars().count());
                        let first = if kind == "TranscriptText" {
                            last_text_at = Some(Instant::now());
                            std::mem::take(&mut first_text)
                        } else {
                            std::mem::take(&mut first_interim)
                        };
                        if first || final_by.is_some() {
                            timing.log(format_args!(
                                "{} {kind} received ({chars} chars; {} ms of audio sent)",
                                if final_by.is_some() {
                                    "after CloseStream,"
                                } else {
                                    "first"
                                },
                                audio_ms(sent_samples)
                            ));
                        }
                        if let Some(data) = data {
                            if !data.is_empty() {
                                transcript.running(data);
                                type_into(
                                    pane_id,
                                    &cancelled,
                                    &mut typed,
                                    &transcript.text(),
                                    timing,
                                );
                            }
                        }
                    }
                    Some("TranscriptEndpoint") => {
                        transcript.endpoint();
                        type_into(pane_id, &cancelled, &mut typed, &transcript.text(), timing);
                        if final_by.is_some() {
                            timing.log(format_args!(
                                "TranscriptEndpoint after CloseStream received"
                            ));
                            end = "final endpoint";
                            break;
                        }
                    }
                    Some("TranscriptError") | Some("error") => {
                        type_into(pane_id, &cancelled, &mut typed, &transcript.text(), timing);
                        socket.close(None).ok();
                        return Err(anyhow!("the service reported {message}"));
                    }
                    _ => {}
                }
            }
            Ok(Message::Close(_)) => {
                end = "the service closed";
                break;
            }
            Ok(_) => {}
            Err(tungstenite::Error::Io(err))
                if matches!(err.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
            Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed) => {
                end = "the connection closed";
                break;
            }
            Err(err) => return Err(err).context("reading the transcript"),
        }
    }

    type_into(pane_id, &cancelled, &mut typed, &transcript.text(), timing);
    socket.close(None).ok();
    log::info!(
        "fn dictation timing: last TranscriptText was at +{} ms; {messages} messages, \
         {} ms of audio sent, {} chars typed",
        last_text_at.map_or(0, |at| timing.ms_at(at)),
        audio_ms(sent_samples),
        typed.chars().count()
    );
    Ok(end)
}

/// Send the buffered audio in whole chunks, and the remainder too when `all`;
/// how many samples went.
fn send_audio(socket: &mut Socket, pcm: &mut Vec<i16>, all: bool) -> anyhow::Result<usize> {
    let whole = if all {
        pcm.len()
    } else {
        pcm.len() - pcm.len() % CHUNK_SAMPLES
    };
    for chunk in pcm[..whole].chunks(CHUNK_SAMPLES) {
        let bytes: Vec<u8> = chunk.iter().flat_map(|s| s.to_le_bytes()).collect();
        socket.send(Message::binary(bytes))?;
    }
    pcm.drain(..whole);
    Ok(whole)
}

/// Type the difference between what was typed and what is wanted into the
/// pane, on the GUI thread, unless the session was cancelled by then: the
/// flag is checked there, where keys are handled, so no edit lands after the
/// key that cancelled.
fn type_into(
    pane_id: PaneId,
    cancelled: &Arc<AtomicBool>,
    typed: &mut String,
    wanted: &str,
    timing: &Timing,
) {
    let edit = edit_between(typed, wanted);
    if edit.is_empty() {
        return;
    }
    *typed = wanted.to_string();
    let cancelled = Arc::clone(cancelled);
    let timing = timing.clone();
    let queued = Instant::now();
    promise::spawn::spawn_into_main_thread(async move {
        if cancelled.load(Ordering::SeqCst) {
            return;
        }
        let Some(pane) = Mux::get().get_pane(pane_id) else {
            return;
        };
        if timing.first_typed() {
            timing.log(format_args!(
                "first text typed into the pane ({} chars, {} backspaces; queued at +{} ms)",
                edit.text.chars().count(),
                edit.backspaces,
                timing.ms_at(queued)
            ));
        }
        for _ in 0..edit.backspaces {
            pane.key_down(KeyCode::Backspace, KeyModifiers::NONE).ok();
        }
        if !edit.text.is_empty() {
            if let Err(err) = pane.send_paste(&edit.text) {
                log::error!("fn dictation: typing into pane {pane_id}: {err:#}");
            }
        }
    })
    .detach();
}

/// When the first audio buffer arrived, and its frames.
type FirstBuffer = Arc<OnceLock<(Instant, usize)>>;

/// The default input device, downmixed to mono f32 at its own rate. The
/// callback only notes its first buffer in `first`; the session thread logs it.
fn start_capture(
    audio: Sender<Vec<f32>>,
    first: FirstBuffer,
    timing: &Timing,
) -> anyhow::Result<(cpal::Stream, u32)> {
    let device = cpal::default_host()
        .default_input_device()
        .ok_or_else(|| anyhow!("no microphone"))?;
    let supported = device
        .default_input_config()
        .context("reading the microphone's format")?;
    let format = supported.sample_format();
    let config = supported.config();
    let channels = config.channels.max(1) as usize;
    let on_error = |err: cpal::StreamError| log::error!("fn dictation: microphone: {err}");
    let stream = match format {
        cpal::SampleFormat::F32 => device.build_input_stream(
            &config,
            move |data: &[f32], _: &cpal::InputCallbackInfo| {
                first.get_or_init(|| (Instant::now(), data.len() / channels));
                audio.send(downmix(data, channels, |s| s)).ok();
            },
            on_error,
            None,
        ),
        cpal::SampleFormat::I16 => device.build_input_stream(
            &config,
            move |data: &[i16], _: &cpal::InputCallbackInfo| {
                first.get_or_init(|| (Instant::now(), data.len() / channels));
                audio
                    .send(downmix(data, channels, |s| s as f32 / i16::MAX as f32))
                    .ok();
            },
            on_error,
            None,
        ),
        other => return Err(anyhow!("unsupported microphone format {other:?}")),
    }
    .context("opening the microphone")?;
    stream.play().context("starting the microphone")?;
    timing.log(format_args!(
        "mic stream started ({} Hz, {channels} channels, {format:?}, buffer {:?}; \
         sent as {} Hz mono in chunks of {CHUNK_SAMPLES} samples, {} ms, \
         polled every {} ms)",
        config.sample_rate,
        config.buffer_size,
        typing::OUTPUT_RATE,
        audio_ms(CHUNK_SAMPLES),
        POLL.as_millis()
    ));
    Ok((stream, config.sample_rate))
}

fn downmix<T: Copy>(data: &[T], channels: usize, to_f32: impl Fn(T) -> f32) -> Vec<f32> {
    data.chunks(channels)
        .map(|frame| frame.iter().map(|&s| to_f32(s)).sum::<f32>() / frame.len() as f32)
        .collect()
}

/// Open the socket on a thread of its own, so that the whole of it (the
/// Keychain read, DNS, TCP, TLS, the handshake, the read again after a 401)
/// is bounded by CONNECT_TIMEOUT, while fn up and cancel are still heard.
/// None: cancelled meanwhile. The flag: fn was released meanwhile. A
/// connection that comes too late is dropped by its thread.
fn connect_in_time(
    keyterms: &[String],
    commands: &Receiver<Command>,
    timing: &Timing,
) -> anyhow::Result<Option<(Socket, bool)>> {
    let (result_tx, result) = channel();
    let keyterms = keyterms.to_vec();
    let connect_timing = timing.clone();
    std::thread::Builder::new()
        .name("fn-dictation-connect".to_string())
        .spawn(move || {
            result_tx.send(connect(&keyterms, &connect_timing)).ok();
        })
        .context("starting the thread that connects")?;
    let deadline = Instant::now() + CONNECT_TIMEOUT;
    let mut finished = false;
    loop {
        match commands.try_recv() {
            Ok(Command::Cancel) | Err(TryRecvError::Disconnected) => return Ok(None),
            Ok(Command::Finish) => finished = true,
            Err(TryRecvError::Empty) => {}
        }
        match result.recv_timeout(POLL) {
            Ok(socket) => return Ok(Some((socket?, finished))),
            Err(RecvTimeoutError::Timeout) if Instant::now() < deadline => {}
            Err(RecvTimeoutError::Timeout) => {
                return Err(anyhow!(
                    "no connection to the speech to text service within {CONNECT_TIMEOUT:?}"
                ))
            }
            Err(RecvTimeoutError::Disconnected) => {
                return Err(anyhow!("the thread that connects ended without a result"))
            }
        }
    }
}

/// Open the socket with Claude Code's login, reading the token again once
/// on a 401. A 401 after that, or a 403, means the sign in itself is refused.
fn connect(keyterms: &[String], timing: &Timing) -> anyhow::Result<Socket> {
    let status = |err: &anyhow::Error| match err.downcast_ref::<tungstenite::Error>() {
        Some(tungstenite::Error::Http(response)) => Some(response.status().as_u16()),
        _ => None,
    };
    let result = match connect_once(keyterms, timing) {
        Err(err) if status(&err) == Some(401) => {
            log::info!("fn dictation: 401, reading the token again");
            connect_once(keyterms, timing)
        }
        other => other,
    };
    match result {
        Err(err) if matches!(status(&err), Some(401 | 403)) => Err(err.context(TOKEN_REFUSED)),
        other => other.context("connecting to the speech to text service"),
    }
}

/// What tungstenite::connect does (less its redirects, which the service
/// never sends), in steps, so that each is timed.
fn connect_once(keyterms: &[String], timing: &Timing) -> anyhow::Result<Socket> {
    let started = Instant::now();
    let token = access_token()?;
    timing.log(format_args!(
        "Keychain token read (took {} ms)",
        started.elapsed().as_millis()
    ));
    let mut request = service_url().into_client_request()?;
    let headers = request.headers_mut();
    let header = |s: &str| HeaderValue::from_bytes(s.as_bytes()).context("a request header");
    headers.insert("authorization", header(&format!("Bearer {token}"))?);
    headers.insert(
        "user-agent",
        header(&format!("claude-cli/{}", claude_version()))?,
    );
    headers.insert("x-app", header("cli")?);
    headers.insert("anthropic-client-platform", header("claude_code_cli")?);
    if let Some(terms) = keyterms_header(keyterms) {
        headers.insert("x-config-keyterms", header(&terms)?);
    }
    let host = request
        .uri()
        .host()
        .ok_or_else(|| anyhow!("the service URL has no host"))?
        .to_string();
    let port = request.uri().port_u16().unwrap_or(443);

    let dns = Instant::now();
    let addrs: Vec<SocketAddr> = (host.as_str(), port)
        .to_socket_addrs()
        .with_context(|| format!("resolving {host}"))?
        .collect();
    let tcp = Instant::now();
    let stream = addrs
        .iter()
        .find_map(|addr| TcpStream::connect(addr).ok())
        .ok_or_else(|| anyhow!("cannot reach {host}:{port}"))?;
    stream.set_nodelay(true)?;
    let handshake = Instant::now();
    let (socket, _response) =
        tungstenite::client_tls(request, stream).map_err(|err| match err {
            tungstenite::HandshakeError::Failure(err) => anyhow::Error::from(err),
            tungstenite::HandshakeError::Interrupted(_) => anyhow!("the handshake was interrupted"),
        })?;
    let done = Instant::now();
    timing.log(format_args!(
        "WebSocket connected (DNS {} ms, TCP {} ms, TLS and WebSocket handshake {} ms)",
        (tcp - dns).as_millis(),
        (handshake - tcp).as_millis(),
        (done - handshake).as_millis()
    ));
    Ok(socket)
}

fn set_read_timeout(socket: &Socket, timeout: Duration) -> anyhow::Result<()> {
    let tcp = match socket.get_ref() {
        MaybeTlsStream::Plain(tcp) => tcp,
        MaybeTlsStream::NativeTls(tls) => tls.get_ref(),
        _ => return Err(anyhow!("unexpected socket type")),
    };
    tcp.set_read_timeout(Some(timeout))?;
    Ok(())
}

/// Claude Code's OAuth access token, from its Keychain item, read through
/// /usr/bin/security (which the item's access list trusts, so no prompt).
fn access_token() -> anyhow::Result<String> {
    let output = std::process::Command::new("/usr/bin/security")
        .args(["find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"])
        .output()
        .context("running /usr/bin/security")?;
    if !output.status.success() {
        log::error!("fn dictation: no Keychain item {KEYCHAIN_SERVICE:?}");
        return Err(anyhow!(NOT_SIGNED_IN));
    }
    let credentials: serde_json::Value = serde_json::from_slice(&output.stdout)
        .with_context(|| format!("the Keychain item {KEYCHAIN_SERVICE:?} is not JSON"))?;
    credentials
        .pointer("/claudeAiOauth/accessToken")
        .and_then(|t| t.as_str())
        .filter(|t| !t.is_empty())
        .map(str::to_string)
        .ok_or_else(|| {
            log::error!("fn dictation: no claudeAiOauth.accessToken in {KEYCHAIN_SERVICE:?}");
            anyhow!(NOT_SIGNED_IN)
        })
}

/// The newest installed Claude Code, for the User-Agent.
fn claude_version() -> String {
    let dir = dirs_next::home_dir()
        .unwrap_or_default()
        .join(".local/share/claude/versions");
    std::fs::read_dir(dir)
        .ok()
        .and_then(|entries| {
            newest_version(
                entries
                    .filter_map(|e| e.ok())
                    .filter_map(|e| e.file_name().into_string().ok()),
            )
        })
        .unwrap_or_else(|| FALLBACK_CLAUDE_VERSION.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_refused_sign_in_is_found_under_its_context() {
        let err = Err::<(), _>(anyhow!(NOT_SIGNED_IN))
            .context("connecting to the speech to text service")
            .unwrap_err();
        assert_eq!(sign_in_refused(&err).map(|r| r.0), Some(NOT_SIGNED_IN.0));

        let err = anyhow!("a 401").context(TOKEN_REFUSED);
        assert_eq!(sign_in_refused(&err).map(|r| r.0), Some(TOKEN_REFUSED.0));

        let err = anyhow!("a timeout").context("connecting");
        assert!(sign_in_refused(&err).is_none());
    }
}
