#!/bin/sh
set -e

REPO="armsteadj1/claw-use"
ASSET="cua-macos-universal.tar.gz"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { printf "${BOLD}%s${RESET}\n" "$1"; }
success() { printf "${GREEN}%s${RESET}\n" "$1"; }
error()   { printf "${RED}error: %s${RESET}\n" "$1" >&2; exit 1; }

# --version flag: print what would be installed and exit
if [ "${1:-}" = "--version" ]; then
  LATEST=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
  echo "Latest available: $LATEST"
  exit 0
fi

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

info "Fetching latest version..."
LATEST=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

if [ -z "$LATEST" ]; then
  error "Could not determine latest version. Check your internet connection."
fi

info "Installing cua $LATEST to $INSTALL_DIR..."

DOWNLOAD_URL="https://github.com/$REPO/releases/download/$LATEST/$ASSET"

# Download and extract
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

info "Downloading $DOWNLOAD_URL..."
curl -fsSL --progress-bar "$DOWNLOAD_URL" -o "$TMPDIR/$ASSET"

info "Extracting..."
tar xzf "$TMPDIR/$ASSET" -C "$TMPDIR"

# Install binaries
install -m 755 "$TMPDIR/cua"  "$INSTALL_DIR/cua"
install -m 755 "$TMPDIR/cuad" "$INSTALL_DIR/cuad"

success "Installed cua $LATEST to $INSTALL_DIR"

# PATH check — suggest shell config update
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    echo ""
    info "Add $INSTALL_DIR to your PATH:"

    # Detect current shell
    SHELL_NAME=$(basename "${SHELL:-sh}")
    case "$SHELL_NAME" in
      zsh)
        echo "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.zshrc"
        echo "  source ~/.zshrc"
        ;;
      bash)
        echo "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.bashrc"
        echo "  source ~/.bashrc"
        ;;
      fish)
        echo "  fish_add_path $INSTALL_DIR"
        ;;
      *)
        echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
        ;;
    esac
    echo ""
    ;;
esac

echo ""
info "Next steps:"
echo "  cua daemon start    # start the daemon"
echo "  cua list            # see running apps"
echo ""
echo "Grant Accessibility permission when prompted."
echo "For Safari: enable Develop → Allow JavaScript from Apple Events."
echo ""
echo "Run \`cua update\` anytime to get the latest version."
