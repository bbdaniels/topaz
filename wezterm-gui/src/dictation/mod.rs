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

pub mod typing;

use anyhow::{anyhow, Context};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use mux::pane::PaneId;
use mux::Mux;
use std::io::ErrorKind;
use std::net::TcpStream;
use std::sync::mpsc::{channel, Receiver, Sender, TryRecvError};
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

const KEYCHAIN_SERVICE: &str = "Claude Code-credentials";
/// Used in the User-Agent only when Claude Code's versions folder is unreadable.
const FALLBACK_CLAUDE_VERSION: &str = "2.1.319";

enum Command {
    Finish,
    Cancel,
}

/// One hold of fn. Dropping it without finish() cancels it.
pub struct Session {
    commands: Sender<Command>,
}

impl Session {
    pub fn start(pane_id: PaneId, keyterms: Vec<String>) -> Self {
        let (commands, receiver) = channel();
        let spawned = std::thread::Builder::new()
            .name("fn-dictation".to_string())
            .spawn(move || {
                if let Err(err) = run(pane_id, &keyterms, receiver) {
                    log::error!("fn dictation: {err:#}");
                }
            });
        if let Err(err) = spawned {
            log::error!("fn dictation: cannot start its thread: {err:#}");
        }
        Self { commands }
    }

    /// fn was released: send what is left and type the final text.
    pub fn finish(self) {
        self.commands.send(Command::Finish).ok();
    }

    /// Another key came during the hold, so this was a shortcut: stop
    /// without typing anything more.
    pub fn cancel(self) {
        self.commands.send(Command::Cancel).ok();
    }
}

type Socket = WebSocket<MaybeTlsStream<TcpStream>>;

fn run(pane_id: PaneId, keyterms: &[String], commands: Receiver<Command>) -> anyhow::Result<()> {
    // Capture first, so that audio buffers while the socket opens.
    let (audio_tx, audio) = channel::<Vec<f32>>();
    let (stream, input_rate) = start_capture(audio_tx)?;
    let mut stream = Some(stream);
    let mut resampler = Resampler::new(input_rate);

    let mut socket = connect(keyterms)?;
    set_read_timeout(&socket, POLL)?;
    socket.send(Message::text(KEEP_ALIVE))?;
    let mut last_keep_alive = Instant::now();

    let mut pcm: Vec<i16> = vec![];
    let mut transcript = Transcript::default();
    let mut typed = String::new();
    let mut final_by: Option<Instant> = None;

    loop {
        if final_by.is_none() {
            match commands.try_recv() {
                Ok(Command::Finish) => {
                    // Stop the microphone, send all that it heard, close.
                    drop(stream.take());
                    while let Ok(samples) = audio.try_recv() {
                        resampler.push(&samples, &mut pcm);
                    }
                    send_audio(&mut socket, &mut pcm, true)?;
                    socket.send(Message::text(CLOSE_STREAM))?;
                    final_by = Some(Instant::now() + FINAL_WAIT);
                }
                Ok(Command::Cancel) | Err(TryRecvError::Disconnected) => {
                    socket.close(None).ok();
                    return Ok(());
                }
                Err(TryRecvError::Empty) => {
                    while let Ok(samples) = audio.try_recv() {
                        resampler.push(&samples, &mut pcm);
                    }
                    send_audio(&mut socket, &mut pcm, false)?;
                    if last_keep_alive.elapsed() >= KEEP_ALIVE_EVERY {
                        socket.send(Message::text(KEEP_ALIVE))?;
                        last_keep_alive = Instant::now();
                    }
                }
            }
        } else if final_by.map_or(false, |t| Instant::now() >= t) {
            log::warn!("fn dictation: no final text within {FINAL_WAIT:?}");
            break;
        }

        match socket.read() {
            Ok(Message::Text(text)) => {
                let message: serde_json::Value = match serde_json::from_str(text.as_str()) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                match message.get("type").and_then(|t| t.as_str()) {
                    Some("TranscriptText") | Some("TranscriptInterim") => {
                        if let Some(data) = message.get("data").and_then(|d| d.as_str()) {
                            if !data.is_empty() {
                                transcript.running(data);
                                type_into(pane_id, &mut typed, &transcript.text());
                            }
                        }
                    }
                    Some("TranscriptEndpoint") => {
                        transcript.endpoint();
                        type_into(pane_id, &mut typed, &transcript.text());
                        if final_by.is_some() {
                            break;
                        }
                    }
                    Some("TranscriptError") | Some("error") => {
                        type_into(pane_id, &mut typed, &transcript.text());
                        socket.close(None).ok();
                        return Err(anyhow!("the service reported {message}"));
                    }
                    _ => {}
                }
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => {}
            Err(tungstenite::Error::Io(err))
                if matches!(err.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
            Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed) => {
                break
            }
            Err(err) => return Err(err).context("reading the transcript"),
        }
    }

    type_into(pane_id, &mut typed, &transcript.text());
    socket.close(None).ok();
    Ok(())
}

/// Send the buffered audio in whole chunks, and the remainder too when `all`.
fn send_audio(socket: &mut Socket, pcm: &mut Vec<i16>, all: bool) -> anyhow::Result<()> {
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
    Ok(())
}

/// Type the difference between what was typed and what is wanted into the
/// pane, on the GUI thread.
fn type_into(pane_id: PaneId, typed: &mut String, wanted: &str) {
    let edit = edit_between(typed, wanted);
    if edit.is_empty() {
        return;
    }
    *typed = wanted.to_string();
    promise::spawn::spawn_into_main_thread(async move {
        let Some(pane) = Mux::get().get_pane(pane_id) else {
            return;
        };
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

/// The default input device, downmixed to mono f32 at its own rate.
fn start_capture(audio: Sender<Vec<f32>>) -> anyhow::Result<(cpal::Stream, u32)> {
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
                audio.send(downmix(data, channels, |s| s)).ok();
            },
            on_error,
            None,
        ),
        cpal::SampleFormat::I16 => device.build_input_stream(
            &config,
            move |data: &[i16], _: &cpal::InputCallbackInfo| {
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
    Ok((stream, config.sample_rate))
}

fn downmix<T: Copy>(data: &[T], channels: usize, to_f32: impl Fn(T) -> f32) -> Vec<f32> {
    data.chunks(channels)
        .map(|frame| frame.iter().map(|&s| to_f32(s)).sum::<f32>() / frame.len() as f32)
        .collect()
}

/// Open the socket with Claude Code's login, reading the token again once
/// on a 401.
fn connect(keyterms: &[String]) -> anyhow::Result<Socket> {
    let unauthorized = |err: &anyhow::Error| {
        matches!(
            err.downcast_ref::<tungstenite::Error>(),
            Some(tungstenite::Error::Http(response)) if response.status().as_u16() == 401
        )
    };
    match connect_once(keyterms) {
        Err(err) if unauthorized(&err) => {
            log::info!("fn dictation: 401, reading the token again");
            connect_once(keyterms).context("connecting after a 401")
        }
        other => other.context("connecting to the speech to text service"),
    }
}

fn connect_once(keyterms: &[String]) -> anyhow::Result<Socket> {
    let token = access_token()?;
    let mut request = service_url().into_client_request()?;
    let headers = request.headers_mut();
    let header = |s: &str| HeaderValue::from_bytes(s.as_bytes()).context("a request header");
    headers.insert("authorization", header(&format!("Bearer {token}"))?);
    headers.insert("user-agent", header(&format!("claude-cli/{}", claude_version()))?);
    headers.insert("x-app", header("cli")?);
    headers.insert("anthropic-client-platform", header("claude_code_cli")?);
    if let Some(terms) = keyterms_header(keyterms) {
        headers.insert("x-config-keyterms", header(&terms)?);
    }
    let (socket, _response) = tungstenite::connect(request)?;
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
        return Err(anyhow!(
            "no Keychain item {KEYCHAIN_SERVICE:?}: sign in to Claude Code first"
        ));
    }
    let credentials: serde_json::Value = serde_json::from_slice(&output.stdout)
        .with_context(|| format!("the Keychain item {KEYCHAIN_SERVICE:?} is not JSON"))?;
    credentials
        .pointer("/claudeAiOauth/accessToken")
        .and_then(|t| t.as_str())
        .filter(|t| !t.is_empty())
        .map(str::to_string)
        .ok_or_else(|| anyhow!("no claudeAiOauth.accessToken in {KEYCHAIN_SERVICE:?}"))
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
