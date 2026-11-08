#!/bin/zsh
# Build Topaz, Ben's fork of WezTerm (branch `dance`: Ghostty-style wobble in
# the WebGpu shader), into /Applications/Topaz.app, the one terminal on this
# Mac. Named Topaz on 2026-11-08 (Ben). The app is assembled as ci/deploy.sh
# assembles WezTerm's own macOS release, renamed in its Info.plist only, and
# signed ad hoc on this Mac. The binaries keep WezTerm's names (`wezterm`,
# `wezterm-gui`) and the config stays at ~/.config/wezterm, so upstream merges
# stay clean and `wezterm cli` keeps working.
#
#   ./topaz-build.sh            build, then install as --install does
#   ./topaz-build.sh --update   first merge upstream main and update Rust
#   ./topaz-build.sh --stage    build and sign into target/topaz/Topaz.app only
#   ./topaz-build.sh --install  install the staged app: quit Topaz, replace
#                               /Applications/Topaz.app, install the config
#                               from ~/Projects/personal, reopen Topaz
#
# Install from outside Topaz (quitting it ends the shells in its tabs), for
# example from the gate's tmux: tmux -L pi-gate new-window -d -t pi-gate-keep
# '~/Projects/wezterm/topaz-build.sh --install'. The config goes in after the
# app because config_builder() rejects keys an older build does not know.
# Config: bbdaniels/personal, deploy/mac/wezterm.
#
# The ad hoc signature changes with every build, so macOS may ask again for
# the microphone (fn dictation) after a rebuild.
set -euo pipefail
cd "${0:A:h}"
export PATH="$HOME/.cargo/bin:$PATH" CARGO_NET_GIT_FETCH_WITH_CLI=true
STAGE=target/topaz/Topaz.app
APP=/Applications/Topaz.app
CONFIG_INSTALLER=$HOME/Projects/personal/deploy/mac/wezterm/install-wezterm.sh

install_staged() {
  codesign --verify $STAGE
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
  cp -R $STAGE $APP
  "$CONFIG_INSTALLER"
  open $APP
  echo "Installed $(/usr/libexec/PlistBuddy -c 'Print :TopazCommit' $APP/Contents/Info.plist) to $APP and reopened it."
}

if [[ ${1:-} == --install ]]; then
  install_staged
  exit 0
fi

if [[ ${1:-} == --update ]]; then
  git fetch -q upstream main
  git merge --no-edit upstream/main
  git submodule update --init --recursive -q
  rustup update stable
fi

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
    $STAGE/Contents/Info.plist
rm -f $STAGE/*.dylib
mkdir -p $STAGE/Contents/MacOS $STAGE/Contents/Resources
cp -R assets/shell-integration/* $STAGE/Contents/Resources
cp -R assets/shell-completion $STAGE/Contents/Resources
tic -xe wezterm -o $STAGE/Contents/Resources/terminfo termwiz/data/wezterm.terminfo
for bin in $BINS; do cp target/release/$bin $STAGE/Contents/MacOS/$bin; done
codesign --force --deep --entitlements ci/macos-entitlement.plist --sign - $STAGE
codesign --verify $STAGE

if [[ ${1:-} == --stage ]]; then
  echo "Staged $(git rev-parse --short HEAD) at $PWD/$STAGE; install with ./topaz-build.sh --install."
  exit 0
fi
install_staged
