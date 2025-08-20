#!/usr/bin/env bash
set -euo pipefail

# --- Helpers ---------------------------------------------------------------
append_once() {
  local line="$1" file="$2"
  grep -Fqx "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}
ensure_zshrc() { : "${ZDOTDIR:=$HOME}"; local f="$ZDOTDIR/.zshrc"; touch "$f"; echo "$f"; }
detect_os() {
  case "$(uname -s)" in
    Darwin) echo "mac";;
    Linux)  echo "linux";;
    *)      echo "unsupported";;
  esac
}

OS="$(detect_os)"
ZSHRC="$(ensure_zshrc)"
echo "Detected OS: $OS"
echo "Using zsh config: $ZSHRC"

# --- macOS: CLT ------------------------------------------------------------
if [[ "$OS" == "mac" ]]; then
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "Installing Xcode Command Line Tools..."
    xcode-select --install || true
    for _ in {1..300}; do xcode-select -p >/dev/null 2>&1 && break || sleep 2; done
  fi
  sudo xcode-select -s /Library/Developer/CommandLineTools || true
fi

# --- Homebrew (macOS) ------------------------------------------------------
if [[ "$OS" == "mac" ]]; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  if [[ -d /opt/homebrew/bin ]]; then
    append_once 'eval "$(/opt/homebrew/bin/brew shellenv)"' "$ZSHRC"
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -d /usr/local/bin ]]; then
    append_once 'eval "$(/usr/local/bin/brew shellenv)"' "$ZSHRC"
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  echo "Updating Homebrew and installing build deps..."
  brew update
  brew install git libyaml openssl@3 readline zlib gdbm gmp coreutils pkg-config
fi

# --- Linux prereqs ---------------------------------------------------------
if [[ "$OS" == "linux" ]]; then
  echo "Installing Linux build deps..."
  sudo apt update
  sudo apt install -y \
    build-essential libssl-dev libreadline-dev zlib1g-dev libsqlite3-dev \
    libffi-dev libyaml-dev libgdbm-dev libdb-dev uuid-dev git curl zip unzip \
    ca-certificates gnupg pkg-config
fi

# --- rbenv (Ruby) ----------------------------------------------------------
if [[ ! -d "$HOME/.rbenv" ]]; then
  echo "Installing rbenv..."
  git clone https://github.com/rbenv/rbenv.git "$HOME/.rbenv"
fi
append_once 'export PATH="$HOME/.rbenv/bin:$PATH"' "$ZSHRC"
append_once 'eval "$(rbenv init - zsh)"' "$ZSHRC"
export PATH="$HOME/.rbenv/bin:$PATH"
eval "$(rbenv init - zsh)"

# ruby-build plugin
if [[ ! -d "$HOME/.rbenv/plugins/ruby-build" ]]; then
  echo "Installing ruby-build..."
  git clone https://github.com/rbenv/ruby-build.git "$HOME/.rbenv/plugins/ruby-build"
else
  (cd "$HOME/.rbenv/plugins/ruby-build" && git pull --ff-only)
fi

# rbenv-default-gems plugin (auto-installs listed gems for each Ruby)
if [[ ! -d "$HOME/.rbenv/plugins/rbenv-default-gems" ]]; then
  echo "Installing rbenv-default-gems..."
  git clone https://github.com/rbenv/rbenv-default-gems "$HOME/.rbenv/plugins/rbenv-default-gems"
else
  (cd "$HOME/.rbenv/plugins/rbenv-default-gems" && git pull --ff-only)
fi
# Ensure default gems list includes bundler (idempotent)
mkdir -p "$HOME/.rbenv"
DEFAULT_GEMS_FILE="$HOME/.rbenv/default-gems"
touch "$DEFAULT_GEMS_FILE"
grep -qx 'bundler' "$DEFAULT_GEMS_FILE" || echo 'bundler' >> "$DEFAULT_GEMS_FILE"

# macOS compile flags so psych/openssl/readline are found
if [[ "$OS" == "mac" ]]; then
  export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
  OPENSSL_DIR="$(brew --prefix openssl@3 2>/dev/null || true)"
  READLINE_DIR="$(brew --prefix readline 2>/dev/null || true)"
  LIBYAML_DIR="$(brew --prefix libyaml 2>/dev/null || true)"
  export RUBY_CONFIGURE_OPTS="${RUBY_CONFIGURE_OPTS:-} ${OPENSSL_DIR:+--with-openssl-dir=$OPENSSL_DIR} ${READLINE_DIR:+--with-readline-dir=$READLINE_DIR}"
  export PKG_CONFIG_PATH="${LIBYAML_DIR:+$LIBYAML_DIR/lib/pkgconfig}:\
${OPENSSL_DIR:+$OPENSSL_DIR/lib/pkgconfig}:\
${READLINE_DIR:+$READLINE_DIR/lib/pkgconfig}:\
${PKG_CONFIG_PATH:-}"
fi

echo "Installing Ruby versions (3.3.4, 3.2.5, 3.1.6)..."
rbenv install -s 3.3.4
rbenv install -s 3.2.5
rbenv install -s 3.1.6
rbenv global 3.3.4
rbenv rehash

# Sanity: make sure bundler exists for the active Ruby (covers pre-existing installs)
if ! command -v bundle >/dev/null 2>&1; then
  echo "Installing bundler for current Ruby..."
  gem install bundler || true
fi

# ===================== SDKMAN! (Java) =====================
append_once 'export SDKMAN_DIR="$HOME/.sdkman"' "$ZSHRC"
append_once '[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"' "$ZSHRC"
export SDKMAN_DIR="$HOME/.sdkman"

# Install with bash (SDKMAN requires bash)
if [[ ! -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]]; then
  echo "Installing SDKMAN!..."
  /bin/bash -c 'curl -s "https://get.sdkman.io" | bash'
fi

# Seed safe defaults to avoid unbound vars when set -u is on
: "${ZSH_VERSION:=}"
: "${SDKMAN_OFFLINE_MODE:=false}"
: "${SDKMAN_CANDIDATES_DIR:=$HOME/.sdkman/candidates}"

# Source the init (nounset OFF while sourcing)
set +u
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"
set -u

# Ensure sdk function exists
if ! type sdk >/dev/null 2>&1; then
  echo "ERROR: SDKMAN didn't load 'sdk'. Check $SDKMAN_DIR/bin/sdkman-init.sh"
  echo "Tip: open a new shell or run: source \"$SDKMAN_DIR/bin/sdkman-init.sh\""
  exit 1
fi

# Safe wrapper for sdk commands under set -u
sdk_safe() { set +u; sdk "$@"; local rc=$?; set -u; return $rc; }

echo "Installing Java JDKs (Temurin 21, 17, 11)..."
sdk_safe install java 21.0.4-tem || sdk_safe install java 21.0.3-tem || true
sdk_safe install java 17.0.12-tem || sdk_safe install java 17.0.11-tem || true
sdk_safe install java 11.0.25-tem || sdk_safe install java 11.0.24-tem || true

DEFAULT_JAVA="$(sdk_safe list java | awk '/installed/ && /21\./ && /tem/ {print $NF}' | tail -n1 || true)"
[[ -n "${DEFAULT_JAVA:-}" ]] && sdk_safe default java "$DEFAULT_JAVA"

# ===================== nvm (Node + npm) =====================
append_once 'export NVM_DIR="$HOME/.nvm"' "$ZSHRC"
append_once '[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"' "$ZSHRC"
append_once '[[ -s "$NVM_DIR/bash_completion" ]] && source "$NVM_DIR/bash_completion"' "$ZSHRC"
export NVM_DIR="$HOME/.nvm"

# Install with bash (nvm requires bash)
if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
  echo "Installing nvm..."
  /bin/bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'
fi

# Source nvm (nounset OFF while sourcing)
set +u
[[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"
[[ -s "$NVM_DIR/bash_completion" ]] && . "$NVM_DIR/bash_completion"
set -u

# Ensure nvm function exists
if ! type nvm >/dev/null 2>&1; then
  echo "ERROR: nvm didn't load. Check $NVM_DIR/nvm.sh"
  echo "Tip: open a new shell or run: source \"$NVM_DIR/nvm.sh\""
  exit 1
fi

# Safe wrapper for nvm under set -u
nvm_safe() { set +u; nvm "$@"; local rc=$?; set -u; return $rc; }

echo "Installing latest LTS Node (includes npm)..."
nvm_safe install --lts
nvm_safe alias default 'lts/*'

# Enable corepack so yarn/pnpm shims are ready
if command -v corepack >/dev/null 2>&1; then
  set +u; corepack enable || true; set -u
fi

# --- Final info ------------------------------------------------------------
cat <<'EOF'

✅ Setup complete for zsh.

• Ruby (rbenv):
  - Installed: 3.3.4 (global), 3.2.5, 3.1.6
  - Default gems: bundler (auto-installs on future Ruby installs)
  - Use: rbenv global <version> | rbenv local <version>

• Java (SDKMAN!):
  - Installed: Temurin 21, 17, 11
  - Use: sdk use java <version> | sdk default java <version>

• Node & npm (nvm):
  - Installed: latest LTS
  - Corepack: enabled (yarn/pnpm shims available)
  - Use: nvm use --lts | nvm install <version>

Open a NEW zsh session or run:
  source "$HOME/.zshrc"

Verify:
  ruby -v && rbenv versions && bundler -v
  java -version && sdk list java | grep -E 'installed|local only'
  node -v && npm -v && corepack -v
EOF
