#!/bin/zsh
# Build Topaz, Ben's fork of WezTerm (branch `dance`: Ghostty-style wobble in
# the WebGpu shader), into /Applications/Topaz.app, the one terminal on this
# Mac. Named Topaz on 2026-11-08 (Ben). The app is assembled as ci/deploy.sh
# assembles WezTerm's own macOS release, renamed in its Info.plist only. The
# binaries keep WezTerm's names (`wezterm`, `wezterm-gui`) and the config
# stays at ~/.config/wezterm, so upstream merges stay clean and `wezterm cli`
# keeps working.
#
# Topaz.app holds its helpers (2026-11-08): Loupe and Topaz Launcher, both
# from loupe/ in this repository (merged in from bbdaniels/claudehud on
# 2026-11-08, history kept), are built here and nested in
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
#   ./topaz-build.sh --helper loupe
#                                  rebuild the helpers, replace Loupe inside
#                                  the installed Topaz.app, re-sign that, and
#                                  end the running Loupe so Topaz relaunches
#                                  the new one; Topaz keeps running (`hud`,
#                                  its name before 2026-11-08, still works)
#   ./topaz-build.sh --helper launcher
#                                  the same for Topaz Launcher (once a full
#                                  build has installed a Topaz that has it)
#
# Signing: every binary with the "Topaz Dev" certificate and the hardened
# runtime, inside out and without --deep (which would stamp Topaz's
# entitlements on a helper): Loupe with its own entitlements, Topaz
# Launcher with none, then Topaz's other binaries, then the outer bundle
# with Topaz's. A stable signature keeps each permission (Topaz's
# microphone, each helper's Accessibility) across rebuilds; each helper
# keeps its bundle id and its designated requirement, which is checked
# against the installed copy, and every permission already granted to Topaz
# or a helper is checked to name that signature (grants).
# Signing reads the keychain, which an ssh login cannot, so run this in a
# window of the gate's tmux, for example:
#   /opt/homebrew/bin/tmux -L pi-gate new-window -d -t pi-gate-keep \
#     '~/Projects/topaz/topaz-build.sh --stage'
# Install from outside Topaz (quitting it ends the shells in its tabs). The
# config goes in after the app because config_builder() rejects keys an
# older build does not know. Config: bbdaniels/personal, deploy/mac/wezterm.
# The helpers' tests (loupe/, LoupeTests, both helpers') must pass, or nothing is
# built or installed.
set -euo pipefail
cd "${0:A:h}"
export PATH="$HOME/.cargo/bin:$PATH" CARGO_NET_GIT_FETCH_WITH_CLI=true
STAGE=target/topaz/Topaz.app
APP=/Applications/Topaz.app
CONFIG_INSTALLER=$HOME/Projects/personal/deploy/mac/wezterm/install-wezterm.sh
IDENTITY="Topaz Dev"
# The helpers' source, and the last commit that changed it (HelpersCommit).
HELPERS_DIR=$PWD/loupe
HELPERS_COMMIT=$(git log -1 --format=%h -- loupe)
HELPERS_BUILD=/tmp/topaz-helpers-build
LOUPE_BUILT=$HELPERS_BUILD/Build/Products/Release/Loupe.app
LOUPE_IN=Contents/Helpers/Loupe.app
LAUNCHER_BUILT="$HELPERS_BUILD/Build/Products/Release/Topaz Launcher.app"
LAUNCHER_IN="Contents/Helpers/Topaz Launcher.app"
LOGS=$HOME/Library/Caches/topaz-build
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p $LOGS

# Test, then build Loupe and Topaz Launcher (Release) into $LOUPE_BUILT
# and $LAUNCHER_BUILT.
build_helpers() {
  ( cd $HELPERS_DIR
    xcodebuild test -scheme LoupeTests -destination platform=macOS -jobs 2 \
      > $LOGS/helpers-test.log 2>&1 || true
    /usr/bin/grep -E "Executed [0-9]+ tests" $LOGS/helpers-test.log | tail -1
    if ! /usr/bin/grep -q "\*\* TEST SUCCEEDED \*\*" $LOGS/helpers-test.log; then
      /usr/bin/grep -E "error:|failed" $LOGS/helpers-test.log | tail -20
      echo "The helpers' tests failed ($LOGS/helpers-test.log); nothing built." >&2
      exit 1
    fi
    nice -n 10 xcodebuild -scheme Loupe -configuration Release \
      -derivedDataPath $HELPERS_BUILD -jobs 2 build > $LOGS/loupe-build.log 2>&1 || true
    if ! /usr/bin/grep -q "\*\* BUILD SUCCEEDED \*\*" $LOGS/loupe-build.log; then
      /usr/bin/grep -E " error:" $LOGS/loupe-build.log | tail -20
      echo "Loupe did not build ($LOGS/loupe-build.log)." >&2
      exit 1
    fi
    nice -n 10 xcodebuild -scheme TopazLauncher -configuration Release \
      -derivedDataPath $HELPERS_BUILD -jobs 2 build > $LOGS/launcher-build.log 2>&1 || true
    if ! /usr/bin/grep -q "\*\* BUILD SUCCEEDED \*\*" $LOGS/launcher-build.log; then
      /usr/bin/grep -E " error:" $LOGS/launcher-build.log | tail -20
      echo "Topaz Launcher did not build ($LOGS/launcher-build.log)." >&2
      exit 1
    fi )
}

# Copy the built Loupe into the app at $1 and sign it. It is signed in a
# scratch folder under its own name (codesign seals a folder not named .app
# as a plain directory), then moved in whole.
nest_loupe() {
  local tmp=$(mktemp -d /tmp/topaz-loupe.XXXXXX)
  ditto $LOUPE_BUILT $tmp/Loupe.app
  codesign --force --options runtime --timestamp=none \
    --entitlements $HELPERS_DIR/Loupe/Resources/Loupe.entitlements \
    --sign $IDENTITY $tmp/Loupe.app
  codesign --verify --strict $tmp/Loupe.app
  mkdir -p $1/Contents/Helpers
  rm -rf $1/$LOUPE_IN
  mv $tmp/Loupe.app $1/$LOUPE_IN
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
# its permission grants were made to: $2 (Loupe) and $3 (Topaz Launcher)
# if given, else that of the installed Topaz's copy, if it has one.
# TOPAZ_NEW_IDENTITY=1 reports a changed requirement and goes on, for the one
# build after the signing certificate is replaced (loupe/signing/README.md);
# every permission must then be granted again.
verify() {
  codesign --verify --deep --strict $1
  codesign --verify --deep --strict $1/$LOUPE_IN
  codesign --verify --deep --strict $1/$LAUNCHER_IN
  echo "Topaz:          $(designated $1)"
  echo "Loupe:          $(designated $1/$LOUPE_IN)"
  echo "Topaz Launcher: $(designated $1/$LAUNCHER_IN)"
  local launcher_want=${3:-}
  if [[ -z $launcher_want && $1 != $APP && -d $APP/$LAUNCHER_IN ]]; then
    launcher_want=$(designated $APP/$LAUNCHER_IN)
  fi
  if [[ -n $launcher_want && $launcher_want != "$(designated $1/$LAUNCHER_IN)" ]]; then
    echo "Topaz Launcher's designated requirement is not $launcher_want: its grants would not carry over." >&2
    [[ ${TOPAZ_NEW_IDENTITY:-} == 1 ]] || exit 1
  fi
  local want=${2:-}
  if [[ -z $want && $1 != $APP && -d $APP/$LOUPE_IN ]]; then
    want=$(designated $APP/$LOUPE_IN)
  fi
  if [[ -n $want && $want != "$(designated $1/$LOUPE_IN)" ]]; then
    echo "Loupe's designated requirement is not $want: its grants would not carry over." >&2
    [[ ${TOPAZ_NEW_IDENTITY:-} == 1 ]] || exit 1
  fi
  grants $1
}

# Every permission macOS has granted to Topaz or a helper (each allowed
# row of the user's and the system's TCC databases, by bundle id) names the
# designated requirement the app at $1 is signed with; a grant made to
# another (an earlier certificate) is kept on the list but never applied,
# which is how the certificate change of 2026-11-08 left Topaz without Input
# Monitoring until 2026-11-10, so fn dictation heard no key outside Topaz.
# Fails, naming each stale grant and its reset, unless TOPAZ_NEW_IDENTITY=1.
# Reading the databases needs Full Disk Access for the process running this;
# without it, it says so and goes on.
grants() {
  local stale=0 unread= app id want db rows service req tmp=$(mktemp /tmp/topaz-csreq.XXXXXX)
  for app in $1 $1/$LOUPE_IN $1/$LAUNCHER_IN; do
    [[ -d $app ]] || continue
    id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' $app/Contents/Info.plist)
    want=$(designated $app)
    for db in "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
              "/Library/Application Support/com.apple.TCC/TCC.db"; do
      if ! rows=$(/usr/bin/sqlite3 -separator ' ' "file:$db?mode=ro" \
          "select service, hex(csreq) from access where client = '$id' and client_type = 0 and auth_value >= 2 and csreq is not null" 2>/dev/null); then
        [[ $unread == *"$db"* ]] || unread="${unread:+$unread and }$db"
        continue
      fi
      for service req in ${=rows}; do
        print -rn -- $req | xxd -r -p > $tmp
        req=$(csreq -r $tmp -t 2>/dev/null)
        [[ $req == $want ]] && continue
        echo "$id's ${service#kTCCService} grant names $req, not $want, so macOS does not apply it: run tccutil reset ${service#kTCCService} $id and grant it again." >&2
        stale=1
      done
    done
  done
  rm -f $tmp
  [[ -n $unread ]] && echo "Grants not checked in $unread: this process cannot read it (Full Disk Access)." >&2
  if (( stale )); then
    [[ ${TOPAZ_NEW_IDENTITY:-} == 1 ]] || exit 1
  fi
  return 0
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

# Replace helper $1 (loupe, or hud, its old name; or launcher) inside the
# installed Topaz.app and have Topaz relaunch it.
install_helper() {
  local name inside
  case $1 in
    loupe|hud) name=Loupe inside=$LOUPE_IN ;;
    launcher) name="Topaz Launcher" inside=$LAUNCHER_IN ;;
  esac
  [[ -d $APP/$inside ]] || { echo "$APP has no $inside; build and install Topaz first." >&2; exit 1; }
  pgrep -qf $APP/Contents/MacOS/wezterm-gui || { echo "Topaz is not running, so nothing would relaunch $name." >&2; exit 1; }
  local loupe_want=$(designated $APP/$LOUPE_IN) launcher_want=
  [[ -d $APP/$LAUNCHER_IN ]] && launcher_want=$(designated $APP/$LAUNCHER_IN)
  build_helpers
  if [[ $name == Loupe ]]; then nest_loupe $APP; else nest_launcher $APP; fi
  sign_topaz $APP
  verify $APP "$loupe_want" "$launcher_want"
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
  echo "$name $HELPERS_COMMIT is running inside $APP (pid $new)."
}

case ${1:-} in
  --install) install_staged; exit 0 ;;
  --helper)
    [[ ${2:-} == (loupe|hud|launcher) ]] || { echo "usage: $0 --helper loupe|launcher" >&2; exit 2; }
    install_helper $2; exit 0 ;;
  --update)
    git fetch -q upstream main
    git merge --no-edit upstream/main
    git submodule update --init --recursive -q
    rustup update stable ;;
esac

build_helpers

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
    -c "Add :HelpersCommit string $HELPERS_COMMIT" \
    $STAGE/Contents/Info.plist
rm -f $STAGE/*.dylib
mkdir -p $STAGE/Contents/MacOS $STAGE/Contents/Resources
cp -R assets/shell-integration/* $STAGE/Contents/Resources
cp -R assets/shell-completion $STAGE/Contents/Resources
tic -xe wezterm -o $STAGE/Contents/Resources/terminfo termwiz/data/wezterm.terminfo
for bin in $BINS; do cp target/release/$bin $STAGE/Contents/MacOS/$bin; done
nest_loupe $STAGE
nest_launcher $STAGE
sign_topaz $STAGE
verify $STAGE

if [[ ${1:-} == --stage ]]; then
  echo "Staged $(git rev-parse --short HEAD) at $PWD/$STAGE; install with ./topaz-build.sh --install."
  exit 0
fi
install_staged
