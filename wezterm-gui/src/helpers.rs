//! Topaz's helpers: the apps nested in `Topaz.app/Contents/Helpers` that
//! Topaz launches and keeps alive: Loupe and Topaz Launcher (Ben,
//! 2026-11-08: one app, one Dock icon). Each runs in its own process, so a crash or a rebuild of a
//! helper never touches the terminal.
//!
//! `start` runs once, in the primary GUI process. One thread per helper
//! launches it through LaunchServices (so macOS checks it under its own
//! bundle id and it keeps its own permission grants), passing `TOPAZ_PID` so
//! the helper exits when Topaz does; waits for it to exit (kqueue
//! `EVFILT_PROC` with `NOTE_EXIT`); and relaunches it after a backoff that
//! starts at 0.5 seconds, doubles to 30, and starts over once a run has lasted
//! 60 seconds. A copy of the helper that is already running is adopted, never
//! doubled. `stop_all` sends each helper SIGTERM when Topaz terminates.

use std::time::Duration;

const BACKOFF_START: Duration = Duration::from_millis(500);
const BACKOFF_MAX: Duration = Duration::from_secs(30);
const HEALTHY_RUN: Duration = Duration::from_secs(60);

/// How long to wait before relaunching a helper that ran for `uptime`, and
/// the wait to use after the next exit. A run of `HEALTHY_RUN` or more
/// starts the backoff over.
fn backoff(current: Duration, uptime: Duration) -> (Duration, Duration) {
    let wait = if uptime >= HEALTHY_RUN {
        BACKOFF_START
    } else {
        current
    };
    (wait, (wait * 2).min(BACKOFF_MAX))
}

#[cfg(target_os = "macos")]
pub use imp::{start, stop_all};

#[cfg(not(target_os = "macos"))]
pub fn start() {}
#[cfg(not(target_os = "macos"))]
pub fn stop_all() {}

#[cfg(target_os = "macos")]
mod imp {
    use super::{backoff, BACKOFF_START};
    use block2::RcBlock;
    use objc2::rc::autoreleasepool;
    use objc2::runtime::AnyObject;
    use objc2::{class, msg_send};
    use objc2_foundation::{NSArray, NSDictionary, NSError, NSString, NSURL};
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{mpsc, Mutex, Once};
    use std::time::{Duration, Instant};

    struct Helper {
        /// The bundle's name in `Contents/Helpers`, without `.app`.
        name: &'static str,
        bundle_id: &'static str,
    }

    const HELPERS: &[Helper] = &[
        Helper {
            name: "Loupe",
            bundle_id: "com.bbdaniels.topaz.loupe",
        },
        Helper {
            name: "Topaz Launcher",
            bundle_id: "com.bbdaniels.topaz.launcher",
        },
    ];

    static START: Once = Once::new();
    static STOPPING: AtomicBool = AtomicBool::new(false);
    /// The pid of each running helper, by its index in `HELPERS`; 0 if none.
    static PIDS: Mutex<[i32; HELPERS.len()]> = Mutex::new([0; HELPERS.len()]);

    /// Starts supervising every helper found in this app's `Contents/Helpers`.
    /// A build run outside an app bundle has none, and starts nothing.
    pub fn start() {
        START.call_once(|| {
            let Some(dir) = helpers_dir() else { return };
            for (index, helper) in HELPERS.iter().enumerate() {
                let bundle = dir.join(format!("{}.app", helper.name));
                if !bundle.is_dir() {
                    log::debug!("helpers: no {}", bundle.display());
                    continue;
                }
                let spawned = std::thread::Builder::new()
                    .name(format!("helper {}", helper.name))
                    .spawn(move || supervise(index, &bundle));
                if let Err(err) = spawned {
                    log::error!("helpers: cannot start {}: {err:#}", helper.name);
                }
            }
        });
    }

    /// Sends SIGTERM to every running helper and stops relaunching them.
    /// Safe to call more than once.
    pub fn stop_all() {
        STOPPING.store(true, Ordering::SeqCst);
        let pids = *PIDS.lock().unwrap();
        for &pid in pids.iter().filter(|&&p| p > 0) {
            unsafe {
                libc::kill(pid, libc::SIGTERM);
            }
        }
    }

    fn helpers_dir() -> Option<PathBuf> {
        let exe = std::env::current_exe().ok()?;
        // Contents/MacOS/wezterm-gui -> Contents/Helpers
        Some(exe.parent()?.parent()?.join("Helpers"))
    }

    fn stopping() -> bool {
        STOPPING.load(Ordering::SeqCst)
    }

    fn supervise(index: usize, bundle: &Path) {
        let helper = &HELPERS[index];
        let mut delay = BACKOFF_START;
        while !stopping() {
            let pid = match running_pid(helper.bundle_id) {
                Some(pid) => {
                    log::info!("helpers: adopting the running {} (pid {pid})", helper.name);
                    pid
                }
                None => match launch(bundle) {
                    Ok(pid) => {
                        log::info!("helpers: launched {} (pid {pid})", helper.name);
                        pid
                    }
                    Err(err) => {
                        log::error!("helpers: cannot launch {}: {err:#}", helper.name);
                        let (wait, next) = backoff(delay, Duration::ZERO);
                        std::thread::sleep(wait);
                        delay = next;
                        continue;
                    }
                },
            };
            PIDS.lock().unwrap()[index] = pid;
            // stop_all may have run while the launch was in flight.
            if stopping() {
                unsafe {
                    libc::kill(pid, libc::SIGTERM);
                }
                return;
            }
            let started = Instant::now();
            wait_for_exit(pid);
            PIDS.lock().unwrap()[index] = 0;
            if stopping() {
                return;
            }
            let uptime = started.elapsed();
            let (wait, next) = backoff(delay, uptime);
            log::warn!(
                "helpers: {} exited after {:.1} s; relaunching in {:.1} s",
                helper.name,
                uptime.as_secs_f64(),
                wait.as_secs_f64()
            );
            std::thread::sleep(wait);
            delay = next;
        }
    }

    /// The pid of a running app with this bundle id, wherever it was
    /// launched from.
    fn running_pid(bundle_id: &str) -> Option<i32> {
        autoreleasepool(|_| unsafe {
            let id = NSString::from_str(bundle_id);
            let apps: *mut NSArray<AnyObject> = msg_send![
                class!(NSRunningApplication),
                runningApplicationsWithBundleIdentifier: &*id
            ];
            let apps = apps.as_ref()?;
            for i in 0..apps.count() {
                let app = apps.objectAtIndex(i);
                let terminated: bool = msg_send![&*app, isTerminated];
                let pid: i32 = msg_send![&*app, processIdentifier];
                if !terminated && pid > 0 {
                    return Some(pid);
                }
            }
            None
        })
    }

    /// Launches the app at `bundle` through LaunchServices, in the background
    /// and with `TOPAZ_PID` added to its environment, and returns its pid.
    fn launch(bundle: &Path) -> anyhow::Result<i32> {
        let (tx, rx) = mpsc::channel::<Result<i32, String>>();
        autoreleasepool(|_| unsafe {
            let path = NSString::from_str(&bundle.to_string_lossy());
            let url = NSURL::fileURLWithPath(&path);
            let config: *mut AnyObject =
                msg_send![class!(NSWorkspaceOpenConfiguration), configuration];
            let () = msg_send![config, setActivates: false];
            let () = msg_send![config, setAddsToRecentItems: false];
            let () = msg_send![config, setPromptsUserIfNeeded: false];
            let key = NSString::from_str("TOPAZ_PID");
            let value = NSString::from_str(&std::process::id().to_string());
            let env = NSDictionary::from_slices(&[&*key], &[&*value]);
            let () = msg_send![config, setEnvironment: &*env];
            let handler = RcBlock::new(move |app: *mut AnyObject, err: *mut NSError| {
                let result = match app.as_ref() {
                    Some(app) => Ok(msg_send![app, processIdentifier]),
                    None => Err(err
                        .as_ref()
                        .map(|e| e.localizedDescription().to_string())
                        .unwrap_or_else(|| "no app and no error".to_string())),
                };
                tx.send(result).ok();
            });
            let workspace: *mut AnyObject = msg_send![class!(NSWorkspace), sharedWorkspace];
            let () = msg_send![
                workspace,
                openApplicationAtURL: &*url,
                configuration: config,
                completionHandler: &*handler
            ];
        });
        match rx.recv_timeout(Duration::from_secs(30)) {
            Ok(Ok(pid)) if pid > 0 => Ok(pid),
            Ok(Ok(pid)) => anyhow::bail!("LaunchServices gave pid {pid}"),
            Ok(Err(err)) => anyhow::bail!("{err}"),
            Err(_) => anyhow::bail!("LaunchServices did not answer in 30 s"),
        }
    }

    /// Returns when process `pid` has exited (it is not our child, so this
    /// is kqueue rather than waitpid).
    fn wait_for_exit(pid: i32) {
        unsafe {
            let kq = libc::kqueue();
            if kq < 0 {
                log::error!("helpers: kqueue: {}", std::io::Error::last_os_error());
                return poll_for_exit(pid);
            }
            let mut change: libc::kevent = std::mem::zeroed();
            change.ident = pid as libc::uintptr_t;
            change.filter = libc::EVFILT_PROC;
            change.flags = libc::EV_ADD | libc::EV_ONESHOT;
            change.fflags = libc::NOTE_EXIT;
            let added = libc::kevent(kq, &change, 1, std::ptr::null_mut(), 0, std::ptr::null());
            if added < 0 {
                let err = std::io::Error::last_os_error();
                libc::close(kq);
                if err.raw_os_error() == Some(libc::ESRCH) {
                    return; // already gone
                }
                log::error!("helpers: kevent on pid {pid}: {err}");
                return poll_for_exit(pid);
            }
            loop {
                let mut event: libc::kevent = std::mem::zeroed();
                let n = libc::kevent(kq, std::ptr::null(), 0, &mut event, 1, std::ptr::null());
                if n > 0 {
                    break;
                }
                if n < 0 && std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
                    log::error!("helpers: kevent wait: {}", std::io::Error::last_os_error());
                    libc::close(kq);
                    return poll_for_exit(pid);
                }
            }
            libc::close(kq);
        }
    }

    /// Only if kqueue itself fails: check once a second.
    fn poll_for_exit(pid: i32) {
        while unsafe { libc::kill(pid, 0) } == 0 {
            std::thread::sleep(Duration::from_secs(1));
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn backoff_doubles_to_the_cap() {
        let quick = Duration::from_secs(1);
        let mut delay = BACKOFF_START;
        let mut waits = vec![];
        for _ in 0..9 {
            let (wait, next) = backoff(delay, quick);
            waits.push(wait.as_millis());
            delay = next;
        }
        assert_eq!(
            waits,
            vec![500, 1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000]
        );
    }

    #[test]
    fn a_healthy_run_starts_the_backoff_over() {
        let (wait, next) = backoff(BACKOFF_MAX, HEALTHY_RUN);
        assert_eq!((wait, next), (BACKOFF_START, BACKOFF_START * 2));
        let (wait, _) = backoff(BACKOFF_MAX, HEALTHY_RUN - Duration::from_millis(1));
        assert_eq!(wait, BACKOFF_MAX);
    }
}
