#!/bin/zsh
# Build this fork (branch `dance`: Ghostty-style wobble in the WebGpu shader)
# into /Applications/WezTerm.app, the one WezTerm on this Mac. The app is
# assembled as ci/deploy.sh assembles WezTerm's own macOS release and signed
# ad hoc on this Mac. WezTerm is not installed through Homebrew, so an upgrade
# there cannot replace this build.
#
#   ./dance-build.sh            build and install the current checkout
#   ./dance-build.sh --update   first merge upstream main and update Rust
#
# Then quit and reopen WezTerm. Config: bbdaniels/personal, deploy/mac/wezterm.
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

STAGE=target/dance/WezTerm.app
rm -rf target/dance && mkdir -p target/dance
cp -R assets/macos/WezTerm.app target/dance/
rm -f $STAGE/*.dylib
mkdir -p $STAGE/Contents/MacOS $STAGE/Contents/Resources
cp -R assets/shell-integration/* $STAGE/Contents/Resources
cp -R assets/shell-completion $STAGE/Contents/Resources
tic -xe wezterm -o $STAGE/Contents/Resources/terminfo termwiz/data/wezterm.terminfo
for bin in $BINS; do cp target/release/$bin $STAGE/Contents/MacOS/$bin; done
codesign --force --deep --entitlements ci/macos-entitlement.plist --sign - $STAGE
codesign --verify $STAGE

rm -rf /Applications/WezTerm.app
cp -R $STAGE /Applications/WezTerm.app
echo "Installed $(git rev-parse --short HEAD) to /Applications/WezTerm.app; quit and reopen WezTerm."
