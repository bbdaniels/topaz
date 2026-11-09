#!/bin/zsh
# Build Topaz, Ben's fork of WezTerm (branch `dance`: Ghostty-style wobble in
# the WebGpu shader), into /Applications/Topaz.app, the one terminal on this
# Mac. Named Topaz on 2026-11-08 (Ben). The app is assembled as ci/deploy.sh
# assembles WezTerm's own macOS release, renamed in its Info.plist only. The
# binaries keep WezTerm's names (`wezterm`, `wezterm-gui`) and the config
# stays at ~/.config/wezterm, so upstream merges stay clean and `wezterm cli`
# keeps working.
#
# Topaz.app holds its helpers (2026-11-08): ClaudeHUD (Loupe) and Topaz
# Launcher, both from ~/Projects/ClaudeHUD, are built here and nested in
# Contents/Helpers, and Topaz launches them and keeps them alive
# (wezterm-gui/src/helpers.rs). This script is
# the one way either is built and installed; it replaced
# ~/Library/Caches/hud-install.sh.
#
#   ./topaz-build.sh               build, then install as --install does
#   ./topaz-build.sh --update      first merge upstream main and update Rust
#   ./topaz-build.sh --stage       build and sign into target/topaz/Topaz.app only
#   ./topaz-build.sh --install     install the staged app: quit Topaz, replace
#                                  /Applications/Topaz.app, install the config
#                                  from ~/Projects/personal, reopen Topaz
#   ./topaz-build.sh --helper hud  rebuild the helpers, replace ClaudeHUD inside
#                                  the installed Topaz.app, re-sign that, and
#                                  end the running ClaudeHUD so Topaz relaunches
#                                  the new one; Topaz keeps running
#   ./topaz-build.sh --helper launcher
#                                  the same for Topaz Launcher (once a full
#                                  build has installed a Topaz that has it)
#
# Signing: every binary with the "ClaudeHUD Dev" certificate and the hardened
# runtime, inside out and without --deep (which would stamp Topaz's
# entitlements on a helper): ClaudeHUD with its own entitlements, Topaz
# Launcher with none, then Topaz's other binaries, then the outer bundle
# with Topaz's. A stable signature keeps each permission (Topaz's
# microphone, each helper's Accessibility) across rebuilds; each helper
# keeps its bundle id and its designated requirement, which is checked
# against the installed copy.
# Signing reads the keychain, which an ssh login cannot, so run this in a
# window of the gate's tmux, for example:
#   /opt/homebrew/bin/tmux -L pi-gate new-window -d -t pi-gate-keep \
#     '~/Projects/wezterm/topaz-build.sh --stage'
# Install from outside Topaz (quitting it ends the shells in its tabs). The
# config goes in after the app because config_builder() rejects keys an
# older build does not know. Config: bbdaniels/personal, deploy/mac/wezterm.
# The ClaudeHUD repository's tests (both helpers') must pass, or nothing is
# built or installed.
set -euo pipefail
cd "${0:A:h}"
export PATH="$HOME/.cargo/bin:$PATH" CARGO_NET_GIT_FETCH_WITH_CLI=true
STAGE=target/topaz/Topaz.app
APP=/Applications/Topaz.app
CONFIG_INSTALLER=$HOME/Projects/personal/deploy/mac/wezterm/install-wezterm.sh
IDENTITY="ClaudeHUD Dev"
HUD_REPO=$HOME/Projects/ClaudeHUD
HUD_BUILD=/tmp/claudehud-build
HUD_BUILT=$HUD_BUILD/Build/Products/Release/ClaudeHUD.app
HUD_IN=Contents/Helpers/ClaudeHUD.app
LAUNCHER_BUILT="$HUD_BUILD/Build/Products/Release/Topaz Launcher.app"
LAUNCHER_IN="Contents/Helpers/Topaz Launcher.app"
LOGS=$HOME/Library/Caches/topaz-build
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p $LOGS

# Test, then build ClaudeHUD and Topaz Launcher (Release) into $HUD_BUILT
# and $LAUNCHER_BUILT.
build_hud() {
  ( cd $HUD_REPO
    xcodebuild test -scheme ClaudeHUDTests -destination platform=macOS -jobs 2 \
      > $LOGS/hud-test.log 2>&1 || true
    /usr/bin/grep -E "Executed [0-9]+ tests" $LOGS/hud-test.log | tail -1
    if ! /usr/bin/grep -q "\*\* TEST SUCCEEDED \*\*" $LOGS/hud-test.log; then
      /usr/bin/grep -E "error:|failed" $LOGS/hud-test.log | tail -20
      echo "ClaudeHUD's tests failed ($LOGS/hud-test.log); nothing built." >&2
      exit 1
    fi
    nice -n 10 xcodebuild -scheme ClaudeHUD -configuration Release \
      -derivedDataPath $HUD_BUILD -jobs 2 build > $LOGS/hud-build.log 2>&1 || true
    if ! /usr/bin/grep -q "\*\* BUILD SUCCEEDED \*\*" $LOGS/hud-build.log; then
      /usr/bin/grep -E " error:" $LOGS/hud-build.log | tail -20
      echo "ClaudeHUD did not build ($LOGS/hud-build.log)." >&2
      exit 1
    fi
    nice -n 10 xcodebuild -scheme TopazLauncher -configuration Release \
      -derivedDataPath $HUD_BUILD -jobs 2 build > $LOGS/launcher-build.log 2>&1 || true
    if ! /usr/bin/grep -q "\*\* BUILD SUCCEEDED \*\*" $LOGS/launcher-build.log; then
      /usr/bin/grep -E " error:" $LOGS/launcher-build.log | tail -20
      echo "Topaz Launcher did not build ($LOGS/launcher-build.log)." >&2
      exit 1
    fi )
}

# Copy the built ClaudeHUD into the app at $1 and sign it. It is signed in a
# scratch folder under its own name (codesign seals a folder not named .app
# as a plain directory), then moved in whole.
nest_hud() {
  local tmp=$(mktemp -d /tmp/topaz-hud.XXXXXX)
  ditto $HUD_BUILT $tmp/ClaudeHUD.app
  codesign --force --options runtime --timestamp=none \
    --entitlements $HUD_REPO/ClaudeHUD/Resources/ClaudeHUD.entitlements \
    --sign $IDENTITY $tmp/ClaudeHUD.app
  codesign --verify --strict $tmp/ClaudeHUD.app
  mkdir -p $1/Contents/Helpers
  rm -rf $1/$HUD_IN
  mv $tmp/ClaudeHUD.app $1/$HUD_IN
  rmdir $tmp
}
# The same for Topaz Launcher, which has no entitlements.
nest_launcher() {
  local tmp=$(mktemp -d /tmp/topaz-launcher.XXXXXX)
  ditto $LAUNCHER_BUILT "$tmp/Topaz Launcher.app"
  codesign --force --options runtime --timestamp=none \
    --sign $IDENTITY "$tmp/Topaz Launcher.app"
  codesign --verify --strict "$tmp/Topaz Launcher.app"
  mkdir -p $1/Contents/Helpers
  rm -rf $1/$LAUNCHER_IN
  mv "$tmp/Topaz Launcher.app" $1/$LAUNCHER_IN
  rmdir $tmp
}

# Sign Topaz's own binaries, then the outer bundle at $1.
sign_topaz() {
  local bin
  for bin in wezterm wezterm-mux-server strip-ansi-escapes; do
    codesign --force --options runtime --timestamp=none \
      --entitlements ci/macos-entitlement.plist --sign $IDENTITY $1/Contents/MacOS/$bin
  done
  codesign --force --options runtime --timestamp=none \
    --entitlements ci/macos-entitlement.plist --sign $IDENTITY $1
}

designated() {
  codesign -d -r- $1 2>&1 | /usr/bin/sed -n 's/^designated => //p'
}

# Every signature valid, and each helper's designated requirement the one
# its permission grants were made to. ClaudeHUD's: $2 if given, else that
# of /Applications/ClaudeHUD.app while it exists, else that of the installed
# Topaz's copy. Topaz Launcher's: $3 if given, else that of the installed
# Topaz's copy, if it has one.
verify() {
  codesign --verify --deep --strict $1
  codesign --verify --deep --strict $1/$HUD_IN
  codesign --verify --deep --strict $1/$LAUNCHER_IN
  echo "Topaz:          $(designated $1)"
  echo "ClaudeHUD:      $(designated $1/$HUD_IN)"
  echo "Topaz Launcher: $(designated $1/$LAUNCHER_IN)"
  local launcher_want=${3:-}
  if [[ -z $launcher_want && $1 != $APP && -d $APP/$LAUNCHER_IN ]]; then
    launcher_want=$(designated $APP/$LAUNCHER_IN)
  fi
  if [[ -n $launcher_want && $launcher_want != "$(designated $1/$LAUNCHER_IN)" ]]; then
    echo "Topaz Launcher's designated requirement is not $launcher_want: its grants would not carry over." >&2
    exit 1
  fi
  local want=${2:-}
  if [[ -z $want && -d /Applications/ClaudeHUD.app ]]; then
    want=$(designated /Applications/ClaudeHUD.app)
  elif [[ -z $want && $1 != $APP && -d $APP/$HUD_IN ]]; then
    want=$(designated $APP/$HUD_IN)
  fi
  if [[ -n $want && $want != "$(designated $1/$HUD_IN)" ]]; then
    echo "ClaudeHUD's designated requirement is not $want: its grants would not carry over." >&2
    exit 1
  fi
}

install_staged() {
  verify $STAGE
  osascript -e 'tell application "Topaz" to quit' 2>/dev/null || true
  for _ in {1..40}; do
    pgrep -qf $APP/Contents/MacOS/wezterm-gui || break
    sleep 0.5
  done
  if pgrep -qf $APP/Contents/MacOS/wezterm-gui; then
    echo "Topaz did not quit; nothing installed." >&2
    exit 1
  fi
  rm -rf $APP /Applications/WezTerm.app
  ditto $STAGE $APP
  # From here Topaz is reopened whatever else fails, so a failed config
  # install never leaves it closed; the failure is reported and returned.
  local failed=
  $LSREGISTER -f $APP || failed="lsregister"
  "$CONFIG_INSTALLER" || failed="${failed:+$failed, }the config installer ($CONFIG_INSTALLER)"
  open $APP
  echo "Installed $(/usr/libexec/PlistBuddy -c 'Print :TopazCommit' $APP/Contents/Info.plist) to $APP and reopened it."
  if [[ -n $failed ]]; then
    echo "But $failed failed; Topaz is running on the config it had." >&2
    exit 1
  fi
}

# Replace helper $1 (hud or launcher) inside the installed Topaz.app and
# have Topaz relaunch it.
install_helper() {
  local name inside
  case $1 in
    hud) name=ClaudeHUD inside=$HUD_IN ;;
    launcher) name="Topaz Launcher" inside=$LAUNCHER_IN ;;
  esac
  [[ -d $APP/$inside ]] || { echo "$APP has no $inside; build and install Topaz first." >&2; exit 1; }
  pgrep -qf $APP/Contents/MacOS/wezterm-gui || { echo "Topaz is not running, so nothing would relaunch $name." >&2; exit 1; }
  local hud_want=$(designated $APP/$HUD_IN) launcher_want=
  [[ -d $APP/$LAUNCHER_IN ]] && launcher_want=$(designated $APP/$LAUNCHER_IN)
  build_hud
  if [[ $1 == hud ]]; then nest_hud $APP; else nest_launcher $APP; fi
  sign_topaz $APP
  verify $APP "$hud_want" "$launcher_want"
  $LSREGISTER -f $APP/$inside
  local exe="$APP/$inside/Contents/MacOS/$name" old new
  old=$(pgrep -f $exe || true)
  [[ -n $old ]] && kill -TERM ${(f)old}
  for _ in {1..40}; do
    new=$(pgrep -f $exe || true)
    [[ -n $new && $new != $old ]] && break
    sleep 0.5
  done
  if [[ -z $new || $new == $old ]]; then
    echo "Topaz has not relaunched $name after 20 s." >&2
    exit 1
  fi
  echo "$name $(git -C $HUD_REPO rev-parse --short HEAD) is running inside $APP (pid $new)."
}

case ${1:-} in
  --install) install_staged; exit 0 ;;
  --helper)
    [[ ${2:-} == (hud|launcher) ]] || { echo "usage: $0 --helper hud|launcher" >&2; exit 2; }
    install_helper $2; exit 0 ;;
  --update)
    git fetch -q upstream main
    git merge --no-edit upstream/main
    git submodule update --init --recursive -q
    rustup update stable ;;
esac

build_hud

BINS=(wezterm wezterm-mux-server wezterm-gui strip-ansi-escapes)
PKGS=(); for b in $BINS; do PKGS+=(-p $b); done
nice -n 10 cargo build --release -j 2 $PKGS

rm -rf target/topaz && mkdir -p target/topaz
cp -R assets/macos/WezTerm.app $STAGE
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleName Topaz" -c "Set :CFBundleDisplayName Topaz" \
    -c "Set :CFBundleIdentifier com.bbdaniels.topaz" \
    -c "Set :NSMicrophoneUsageDescription Topaz listens while you hold fn to dictate, and programs running in Topaz may ask to use the microphone." \
    -c "Add :TopazCommit string $(git rev-parse --short HEAD)" \
    -c "Add :ClaudeHUDCommit string $(git -C $HUD_REPO rev-parse --short HEAD)" \
    $STAGE/Contents/Info.plist
rm -f $STAGE/*.dylib
mkdir -p $STAGE/Contents/MacOS $STAGE/Contents/Resources
cp -R assets/shell-integration/* $STAGE/Contents/Resources
cp -R assets/shell-completion $STAGE/Contents/Resources
tic -xe wezterm -o $STAGE/Contents/Resources/terminfo termwiz/data/wezterm.terminfo
for bin in $BINS; do cp target/release/$bin $STAGE/Contents/MacOS/$bin; done
nest_hud $STAGE
nest_launcher $STAGE
sign_topaz $STAGE
verify $STAGE

if [[ ${1:-} == --stage ]]; then
  echo "Staged $(git rev-parse --short HEAD) at $PWD/$STAGE; install with ./topaz-build.sh --install."
  exit 0
fi
install_staged
