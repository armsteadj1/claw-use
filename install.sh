#!/bin/sh
set -e

REPO="thegreysky/agentview"
ASSET="cua-macos-universal.tar.gz"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

info() { printf "${BOLD}%s${RESET}\n" "$1"; }
success() { printf "${GREEN}%s${RESET}\n" "$1"; }
error() { printf "${RED}error: %s${RESET}\n" "$1" >&2; exit 1; }

# macOS only
case "$(uname -s)" in
  Darwin) ;;
  *) error "cua requires macOS." ;;
esac

# Determine install directory
if [ -w /usr/local/bin ]; then
  INSTALL_DIR="/usr/local/bin"
else
  INSTALL_DIR="$HOME/.local/bin"
  mkdir -p "$INSTALL_DIR"
fi

info "Installing cua to $INSTALL_DIR..."

# Get latest release URL
DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/$ASSET"

# Download and extract
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

info "Downloading from $DOWNLOAD_URL..."
curl -fsSL "$DOWNLOAD_URL" -o "$TMPDIR/$ASSET"

info "Extracting..."
tar xzf "$TMPDIR/$ASSET" -C "$TMPDIR"

# Install binaries
install -m 755 "$TMPDIR/cua" "$INSTALL_DIR/cua"
install -m 755 "$TMPDIR/cuad" "$INSTALL_DIR/cuad"

success "Installed cua and cuad to $INSTALL_DIR"

# Check PATH
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    echo ""
    echo "Add $INSTALL_DIR to your PATH:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    echo ""
    ;;
esac

echo ""
info "Next steps:"
echo "  cua daemon start    # start the daemon"
echo "  cua list             # see running apps"
echo ""
echo "Grant Accessibility permission when prompted."
echo "For Safari: enable Develop → Allow JavaScript from Apple Events."
