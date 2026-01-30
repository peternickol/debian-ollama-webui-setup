#!/usr/bin/env bash
set -Eeuo pipefail

# Debian 13 (Trixie) local LLM setup helper:
# - NVIDIA driver + CUDA toolkit (Debian packages)
# - Ollama (systemd) bound to localhost by default
# - Open WebUI (systemd) installed WITHOUT Docker
# - Python 3.12 via uv (user-space), venv seeded with pip
# - Downloads a curated set of models BY DEFAULT (opt-out supported)
#
# Run as root (no sudo required):
#   su -
#   bash setup-ollama-openwebui.sh <username>
#
# Dry-run (prints actions, does not change system):
#   su -
#   bash setup-ollama-openwebui.sh --dry-run <username>
#
# Opt-out of model downloads:
#   su -
#   SKIP_MODEL_PULLS=1 bash setup-ollama-openwebui.sh <username>
#
# Change model list:
#   su -
#   MODEL_LIST="llama3.2 qwen2.5:7b phi3:mini" bash setup-ollama-openwebui.sh <username>

########################################
# CONFIG (override via environment)
########################################
: "${LOG_FILE:=/var/log/ollama-openwebui-setup.log}"

: "${OLLAMA_BIND:=127.0.0.1}"
: "${OLLAMA_PORT:=11434}"
: "${OLLAMA_KEEP_ALIVE:=24h}"

: "${WEBUI_BIND:=0.0.0.0}"
: "${WEBUI_PORT:=8080}"

: "${OPENWEBUI_OPT_DIR:=/opt/open-webui}"
: "${OPENWEBUI_DATA_DIR:=/var/lib/open-webui}"

# Firewall controls
: "${UFW_ENABLE:=0}"        # 0 = don't enable; 1 = enable ufw
: "${UFW_ALLOW_WEBUI:=1}"   # 1 = add allow rule for WEBUI_PORT
: "${SSH_ALLOW:=1}"         # 1 = ALWAYS allow SSH before enabling ufw
: "${SSH_PORT:=}"           # Optional: set if SSH runs on a non-standard port

# Model pulls (DEFAULT ON; opt-out available)
: "${PULL_MODELS:=1}"           # 1 = pull models by default
: "${SKIP_MODEL_PULLS:=0}"      # 1 = skip model pulls (opt-out)
: "${MODEL_LIST:=llama3.2 qwen2.5:7b qwen2.5-coder:7b deepseek-r1:7b phi3:mini llava}"

# Startup waits (avoid race conditions)
: "${OLLAMA_READY_TIMEOUT:=60}"   # seconds to wait for Ollama API after restart
: "${WEBUI_READY_TIMEOUT:=60}"    # seconds to wait for Open WebUI HTTP (best-effort)

########################################
# Exit codes
########################################
readonly E_USAGE=10
readonly E_NOT_ROOT=11
readonly E_USER_NOT_FOUND=12

readonly E_APT=20
readonly E_REPO=21
readonly E_NET=22

readonly E_UV=30
readonly E_PYTHON=31
readonly E_PIP=32

readonly E_SYSTEMD=40
readonly E_SERVICE=41
readonly E_HTTP=42

readonly E_FS=50
readonly E_UFW=60
readonly E_MODELS=70

########################################
# Logging
########################################
timestamp() { date -Is; }
log() { echo "[$(timestamp)] $*"; }
warn() { echo "[$(timestamp)] WARN: $*" >&2; }
die() { local code="$1"; shift; echo "[$(timestamp)] ERROR: $*" >&2; exit "$code"; }

########################################
# Dry-run runner
########################################
DRY_RUN=0
run() {
  if (( DRY_RUN )); then
    log "DRY-RUN: $*"
    return 0
  fi
  log "RUN: $*"
  "$@"
}

########################################
# Trap for unexpected failures
########################################
on_err() {
  local code=$?
  warn "Script aborted unexpectedly (exit=$code) at line $BASH_LINENO: ${BASH_COMMAND:-?}"
  warn "See log: $LOG_FILE"
  exit "$code"
}
trap on_err ERR

########################################
# Redirect all output to log (and console)
########################################
mkdir -p "$(dirname "$LOG_FILE")" || die "$E_FS" "Cannot create log directory"
exec > >(tee -a "$LOG_FILE") 2>&1

########################################
# Args
########################################
if [[ $# -lt 1 ]]; then
  die "$E_USAGE" "Usage: $0 [--dry-run] <username>"
fi
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi
if [[ $# -lt 1 ]]; then
  die "$E_USAGE" "Usage: $0 [--dry-run] <username>"
fi
USERNAME="$1"

########################################
# Preconditions
########################################
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "$E_NOT_ROOT" "Run as root (use: su -)."
fi

USERHOME="$(getent passwd "$USERNAME" | cut -d: -f6 || true)"
if [[ -z "${USERHOME:-}" || ! -d "$USERHOME" ]]; then
  die "$E_USER_NOT_FOUND" "User '$USERNAME' not found or home directory missing."
fi

# Opt-out takes precedence
if (( SKIP_MODEL_PULLS )); then
  PULL_MODELS=0
fi

log "==> Starting setup"
log "==> Config: OLLAMA=${OLLAMA_BIND}:${OLLAMA_PORT}, WEBUI=${WEBUI_BIND}:${WEBUI_PORT}"
log "==> Models: PULL_MODELS=${PULL_MODELS} (SKIP_MODEL_PULLS=${SKIP_MODEL_PULLS}), MODEL_LIST='${MODEL_LIST}'"
log "==> Firewall: UFW_ENABLE=${UFW_ENABLE}, SSH_ALLOW=${SSH_ALLOW}, SSH_PORT=${SSH_PORT:-"(auto/OpenSSH)"}"
log "==> Paths: OPT=${OPENWEBUI_OPT_DIR}, DATA=${OPENWEBUI_DATA_DIR}"
log "==> Log: $LOG_FILE"
if (( DRY_RUN )); then log "==> DRY-RUN enabled: commands will not execute."; fi

run_as_user() {
  local cmd="$*"
  run runuser -l "$USERNAME" -c "export PATH=\"\$HOME/.local/bin:\$PATH\"; $cmd"
}

########################################
# Helpers
########################################
pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }
svc_active() { systemctl is-active --quiet "$1"; }

wait_for_http() {
  # wait_for_http <url> <timeout_seconds>
  local url="$1"
  local timeout="${2:-30}"
  local start now elapsed
  start="$(date +%s)"
  while true; do
    if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
      return 0
    fi
    now="$(date +%s)"
    elapsed=$(( now - start ))
    if (( elapsed >= timeout )); then
      return 1
    fi
    sleep 2
  done
}

########################################
# Step 1: System updates + base packages
########################################
log "==> 1) System updates + base packages"
run apt update || die "$E_APT" "apt update failed"
run bash -lc 'DEBIAN_FRONTEND=noninteractive apt upgrade -y' || die "$E_APT" "apt upgrade failed"

BASE_PKGS=(curl ca-certificates gnupg pciutils nano lsb-release)
to_install=()
for p in "${BASE_PKGS[@]}"; do pkg_installed "$p" || to_install+=("$p"); done
if (( ${#to_install[@]} )); then
  run bash -lc "DEBIAN_FRONTEND=noninteractive apt install -y ${to_install[*]}" || die "$E_APT" "Failed installing base packages"
else
  log "Base packages already installed."
fi

########################################
# Step 2: Ensure contrib/non-free repos (non-destructive)
########################################
log "==> 2) Ensure contrib/non-free/non-free-firmware repos (non-destructive)"
REPO_FILE="/etc/apt/sources.list.d/llm-nonfree.list"
REPO_CONTENT=$(cat <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF
)

if [[ -f "$REPO_FILE" ]]; then
  log "Repo file exists: $REPO_FILE (leaving as-is)"
else
  if (( DRY_RUN )); then
    log "DRY-RUN: would create $REPO_FILE"
  else
    printf "%s\n" "$REPO_CONTENT" > "$REPO_FILE" || die "$E_REPO" "Failed writing $REPO_FILE"
  fi
fi

run apt update || die "$E_APT" "apt update failed after repo setup"

########################################
# Step 3: NVIDIA driver + CUDA toolkit
########################################
log "==> 3) Install NVIDIA driver + CUDA toolkit (Debian packages)"
NVIDIA_PKGS=( "linux-headers-$(uname -r)" build-essential nvidia-driver nvidia-cuda-toolkit )
to_install=()
for p in "${NVIDIA_PKGS[@]}"; do pkg_installed "$p" || to_install+=("$p"); done

if (( ${#to_install[@]} )); then
  run bash -lc "DEBIAN_FRONTEND=noninteractive apt install -y ${to_install[*]}" || die "$E_APT" "Failed installing NVIDIA packages"
  warn "NVIDIA packages installed/updated. A reboot may be required before GPU is usable."
else
  log "NVIDIA packages already installed."
fi

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi >/dev/null 2>&1 && log "GPU check: nvidia-smi OK" || warn "GPU check: nvidia-smi failed (reboot usually fixes; Secure Boot can block modules)."
else
  warn "nvidia-smi not found yet (may require reboot or driver install)."
fi

########################################
# Step 4: Install Ollama
########################################
log "==> 4) Install Ollama (idempotent) + enable service"
if command -v ollama >/dev/null 2>&1; then
  log "Ollama already installed."
else
  run curl -fsSL https://ollama.com/install.sh -o /tmp/ollama-install.sh || die "$E_NET" "Failed to download Ollama installer"
  run bash /tmp/ollama-install.sh || die "$E_APT" "Ollama installer failed"
fi

run systemctl enable --now ollama || die "$E_SYSTEMD" "Failed enabling/starting ollama.service"

########################################
# Step 5: Configure Ollama override + wait for API
########################################
log "==> 5) Configure Ollama override (bind + keep-alive)"
run mkdir -p /etc/systemd/system/ollama.service.d || die "$E_FS" "Cannot create systemd override dir for Ollama"

OVR_OLLAMA="/etc/systemd/system/ollama.service.d/override.conf"
OVR_OLLAMA_CONTENT=$(cat <<EOF
[Service]
Environment="OLLAMA_HOST=${OLLAMA_BIND}:${OLLAMA_PORT}"
Environment="OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}"
EOF
)

need_write=1
if [[ -f "$OVR_OLLAMA" ]] \
  && grep -Fqx "Environment=\"OLLAMA_HOST=${OLLAMA_BIND}:${OLLAMA_PORT}\"" "$OVR_OLLAMA" \
  && grep -Fqx "Environment=\"OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}\"" "$OVR_OLLAMA"; then
  need_write=0
  log "Ollama override already up-to-date."
fi

if (( need_write )); then
  if (( DRY_RUN )); then
    log "DRY-RUN: would write $OVR_OLLAMA"
  else
    printf "%s\n" "$OVR_OLLAMA_CONTENT" > "$OVR_OLLAMA" || die "$E_FS" "Failed writing $OVR_OLLAMA"
  fi
  run systemctl daemon-reload || die "$E_SYSTEMD" "systemctl daemon-reload failed"
fi

run systemctl restart ollama || die "$E_SERVICE" "Failed restarting ollama.service"

if (( ! DRY_RUN )); then
  svc_active ollama || die "$E_SERVICE" "ollama.service is not active"

  log "Waiting for Ollama API to respond (timeout=${OLLAMA_READY_TIMEOUT}s)..."
  if ! wait_for_http "http://${OLLAMA_BIND}:${OLLAMA_PORT}/api/tags" "$OLLAMA_READY_TIMEOUT"; then
    die "$E_HTTP" "Ollama API not responding at http://${OLLAMA_BIND}:${OLLAMA_PORT}/api/tags"
  fi
  log "Ollama health: service active and API responding."
fi

########################################
# Step 6: Install uv + PATH fix for target user
########################################
log "==> 6) Install uv for target user + PATH fix"
BASHRC="${USERHOME}/.bashrc"
run touch "$BASHRC" || die "$E_FS" "Cannot touch $BASHRC"
run chown "$USERNAME:$USERNAME" "$BASHRC" || die "$E_FS" "Cannot chown $BASHRC"

if ! grep -Fqx 'export PATH="$HOME/.local/bin:$PATH"' "$BASHRC" 2>/dev/null; then
  if (( DRY_RUN )); then
    log "DRY-RUN: would append PATH export to $BASHRC"
  else
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$BASHRC"
    chown "$USERNAME:$USERNAME" "$BASHRC"
  fi
else
  log "PATH export already present in $BASHRC"
fi

if run_as_user 'command -v uv >/dev/null 2>&1'; then
  log "uv already installed for target user."
else
  run_as_user 'curl -LsSf https://astral.sh/uv/install.sh | sh' || die "$E_UV" "Failed installing uv"
fi

run_as_user 'uv --version' || die "$E_UV" "uv not runnable after install"

########################################
# Step 7: Create Open WebUI dirs
########################################
log "==> 7) Create Open WebUI directories"
run mkdir -p "$OPENWEBUI_OPT_DIR" "$OPENWEBUI_DATA_DIR" || die "$E_FS" "Failed creating Open WebUI dirs"
run chown -R "$USERNAME:$USERNAME" "$OPENWEBUI_OPT_DIR" "$OPENWEBUI_DATA_DIR" || die "$E_FS" "Failed chown Open WebUI dirs"

########################################
# Step 8: Python 3.12 via uv + venv + Open WebUI
########################################
log "==> 8) Install Python 3.12 via uv + venv (seeded) + Open WebUI"
VENV_DIR="${OPENWEBUI_OPT_DIR}/venv"

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  run_as_user "cd '$OPENWEBUI_OPT_DIR' && uv python install 3.12" || die "$E_PYTHON" "uv python install 3.12 failed"
  run_as_user "uv venv --python 3.12 --seed '$VENV_DIR'" || die "$E_PYTHON" "uv venv creation failed"
else
  log "Venv already exists: $VENV_DIR (reusing)"
fi

run_as_user "source '$VENV_DIR/bin/activate' && python -m pip install -U pip" || die "$E_PIP" "pip upgrade failed"
run_as_user "source '$VENV_DIR/bin/activate' && python -m pip install -U open-webui" || die "$E_PIP" "open-webui install failed"

########################################
# Step 9: systemd service for Open WebUI
########################################
log "==> 9) Create/Update systemd service for Open WebUI"
SERVICE_FILE="/etc/systemd/system/open-webui.service"
SERVICE_CONTENT=$(cat <<EOF
[Unit]
Description=Open WebUI
After=network.target ollama.service
Wants=ollama.service

[Service]
Type=simple
Environment=DATA_DIR=${OPENWEBUI_DATA_DIR}
Environment=OLLAMA_BASE_URL=http://${OLLAMA_BIND}:${OLLAMA_PORT}
ExecStart=${VENV_DIR}/bin/open-webui serve --host ${WEBUI_BIND} --port ${WEBUI_PORT}
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
)

need_write=1
if [[ -f "$SERVICE_FILE" ]] && diff -q <(printf "%s\n" "$SERVICE_CONTENT") "$SERVICE_FILE" >/dev/null 2>&1; then
  need_write=0
  log "Open WebUI service already up-to-date."
fi

if (( need_write )); then
  if (( DRY_RUN )); then
    log "DRY-RUN: would write $SERVICE_FILE"
  else
    printf "%s\n" "$SERVICE_CONTENT" > "$SERVICE_FILE" || die "$E_FS" "Failed writing $SERVICE_FILE"
  fi
fi

run systemctl daemon-reload || die "$E_SYSTEMD" "systemctl daemon-reload failed"
run systemctl enable --now open-webui || die "$E_SERVICE" "Failed enabling/starting open-webui.service"

if (( ! DRY_RUN )); then
  log "Waiting for Open WebUI HTTP to respond (best-effort, timeout=${WEBUI_READY_TIMEOUT}s)..."
  if wait_for_http "http://127.0.0.1:${WEBUI_PORT}/" "$WEBUI_READY_TIMEOUT"; then
    log "Open WebUI HTTP is responding on 127.0.0.1:${WEBUI_PORT}"
  else
    warn "Open WebUI did not respond within ${WEBUI_READY_TIMEOUT}s. It may still be starting."
    warn "Check logs: journalctl -u open-webui -n 200 --no-pager"
  fi
fi

########################################
# Step 10: Firewall (SSH-safe)
########################################
log "==> 10) Firewall (SSH-safe)"
if (( UFW_ALLOW_WEBUI || UFW_ENABLE )); then
  if ! command -v ufw >/dev/null 2>&1; then
    run bash -lc 'DEBIAN_FRONTEND=noninteractive apt install -y ufw' || die "$E_APT" "Failed installing ufw"
  else
    log "ufw already installed."
  fi

  # Allow SSH BEFORE enabling UFW
  if (( SSH_ALLOW )); then
    if ufw app list 2>/dev/null | grep -q '^OpenSSH$'; then
      run ufw allow OpenSSH || die "$E_UFW" "Failed to allow OpenSSH in UFW"
    else
      sshp="${SSH_PORT:-22}"
      run ufw allow "${sshp}/tcp" || die "$E_UFW" "Failed to allow SSH port ${sshp}/tcp in UFW"
    fi
  fi

  # Allow WebUI port
  if (( UFW_ALLOW_WEBUI )); then
    run ufw allow "${WEBUI_PORT}/tcp" || die "$E_UFW" "Failed to allow WebUI port ${WEBUI_PORT}/tcp in UFW"
  fi

  # Enable firewall if requested
  if (( UFW_ENABLE )); then
    if (( SSH_ALLOW )) && ! ufw status | grep -Eq 'OpenSSH|(^|\s)22/tcp|'"${SSH_PORT:-}"'/tcp'; then
      die "$E_UFW" "Refusing to enable UFW: SSH does not appear allowed."
    fi
    run ufw --force enable || die "$E_UFW" "Failed to enable UFW"
  else
    log "UFW_ENABLE=0, not enabling firewall automatically."
  fi

  run ufw status verbose || true
else
  log "Firewall step skipped (UFW_ALLOW_WEBUI=0 and UFW_ENABLE=0)."
fi

########################################
# Step 11: Pull models (DEFAULT ON; opt-out supported)
########################################
log "==> 11) Download models"
if (( PULL_MODELS )); then
  log "Model downloads enabled by default. To skip: SKIP_MODEL_PULLS=1"
  if ! command -v ollama >/dev/null 2>&1; then
    die "$E_MODELS" "ollama not found; cannot pull models"
  fi

  installed_models=""
  if (( ! DRY_RUN )); then
    installed_models="$(ollama list 2>/dev/null | awk 'NR>1 {print $1}' || true)"
  fi

  for model in $MODEL_LIST; do
    if (( ! DRY_RUN )) && echo "$installed_models" | grep -Fxq "$model"; then
      log "Model already present: $model (skipping)"
      continue
    fi
    run ollama pull "$model" || die "$E_MODELS" "Failed to pull model: $model"
  done
else
  log "Skipping model downloads (opt-out)."
  log "To pull later: MODEL_LIST=\"...\" PULL_MODELS=1 bash setup-ollama-openwebui.sh <username>"
fi

########################################
# Done
########################################
log "============================================================"
log "DONE."
log "- Ollama API:    http://${OLLAMA_BIND}:${OLLAMA_PORT}/api/tags"
log "- Open WebUI:    http://<server-ip>:${WEBUI_PORT}"
log "- Models:        PULL_MODELS=${PULL_MODELS} (SKIP_MODEL_PULLS=${SKIP_MODEL_PULLS})"
log "- Services:"
log "    systemctl status ollama --no-pager"
log "    systemctl status open-webui --no-pager"
log "- Logs:"
log "    tail -n 200 $LOG_FILE"
log "============================================================"
