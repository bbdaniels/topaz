#!/bin/zsh
# Build Topaz, Ben's fork of WezTerm (branch `dance`: Ghostty-style wobble in
# the WebGpu shader), into /Applications/Topaz.app, the one terminal on this
# Mac. Named Topaz on 2026-11-08 (Ben). The app is assembled as ci/deploy.sh
# assembles WezTerm's own macOS release, renamed in its Info.plist only, and
# signed ad hoc on this Mac. The binaries keep WezTerm's names (`wezterm`,
# `wezterm-gui`) and the config stays at ~/.config/wezterm, so upstream merges
# stay clean and `wezterm cli` keeps working.
#
#   ./topaz-build.sh            build and install the current checkout
#   ./topaz-build.sh --update   first merge upstream main and update Rust
#
# Then quit and reopen Topaz. Config: bbdaniels/personal, deploy/mac/wezterm.
set -euo pipefail
cd "${0:A:h}"
export PATH="$HOME/.cargo/bin:$PATH" CARGO_NET_GIT_FETCH_WITH_CLI=true

if [[ ${1:-} == --update ]]; then
  git fetch -q upstream main
  git merge --no-edit upstream/main
  git submodule update --init --recursive -q
  rustup update stable
fi

BINS=(wezterm wezterm-mux-server wezterm-gui strip-ansi-escapes)
PKGS=(); for b in $BINS; do PKGS+=(-p $b); done
nice -n 10 cargo build --release $PKGS

STAGE=target/topaz/Topaz.app
rm -rf target/topaz && mkdir -p target/topaz
cp -R assets/macos/WezTerm.app $STAGE
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleName Topaz" -c "Set :CFBundleDisplayName Topaz" \
    -c "Set :CFBundleIdentifier com.bbdaniels.topaz" $STAGE/Contents/Info.plist
rm -f $STAGE/*.dylib
mkdir -p $STAGE/Contents/MacOS $STAGE/Contents/Resources
cp -R assets/shell-integration/* $STAGE/Contents/Resources
cp -R assets/shell-completion $STAGE/Contents/Resources
tic -xe wezterm -o $STAGE/Contents/Resources/terminfo termwiz/data/wezterm.terminfo
for bin in $BINS; do cp target/release/$bin $STAGE/Contents/MacOS/$bin; done
codesign --force --deep --entitlements ci/macos-entitlement.plist --sign - $STAGE
codesign --verify $STAGE

rm -rf /Applications/Topaz.app /Applications/WezTerm.app
cp -R $STAGE /Applications/Topaz.app
echo "Installed $(git rev-parse --short HEAD) to /Applications/Topaz.app; quit and reopen Topaz."
