#!/usr/bin/env bash
set -euo pipefail

mask_argv_arg() {
  local arg="$1"
  if [[ "$arg" =~ ^([^=]+)=.*$ ]]; then
    local key="${BASH_REMATCH[1]}"
    if [[ "$key" =~ (?i)(token|pass(word)?|secret|key|auth|credential) ]]; then
      printf '%s=***' "$key"
      return
    fi
  fi
  if [[ "$arg" =~ (?i)(token|pass(word)?|secret|key|auth|credential) ]]; then
    printf '***'
    return
  fi
  printf '%s' "$arg"
}

print_argv_banner() {
  local masked=()
  local arg
  for arg in "$@"; do
    masked+=("$(mask_argv_arg "$arg")")
  done
  echo "[argv] $0 ${masked[*]}"
}

log_info() { printf '[*] %s\n' "$*"; }
log_warn() { printf '[!] %s\n' "$*"; }
log_success() { printf '[+] %s\n' "$*"; }
log_error() { printf '[-] %s\n' "$*" >&2; }

usage() {
  cat <<'USAGE'
Nutzung:
  ./client/install.sh [--version <vX.Y.Z|latest>] [--install-dir <pfad>] [--repo <owner/repo>] [--dry-run]

Optionen:
  --version <wert>      Release-Version; Default: latest mit Manifest-Fallback.
  --install-dir <pfad>  Installationsziel; Default: ~/.local/bin.
  --repo <owner/repo>   GitHub Repository; alternativ YHSMCTL_REPO.
  --dry-run             Aktionen nur anzeigen; nichts herunterladen oder installieren.
  -h, --help            Diese Hilfe anzeigen.
USAGE
}

print_argv_banner "$@"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/manifest.json"
VERSION="latest"
INSTALL_DIR="${HOME}/.local/bin"
REPO="${YHSMCTL_REPO:-}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unbekannte Option: $1"; usage >&2; exit 2 ;;
  esac
done

json_value() {
  local key="$1"
  python3 - <<'PY' "$MANIFEST" "$key"
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
print(data.get(sys.argv[2], ''))
PY
}

asset_for_platform() {
  local os_name="$1" arch="$2"
  python3 - <<'PY' "$MANIFEST" "$os_name" "$arch"
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
for platform in data.get('supported_platforms', []):
    if platform.get('os') == sys.argv[2] and platform.get('arch') == sys.argv[3]:
        print(platform.get('asset', ''))
        sys.exit(0)
sys.exit(1)
PY
}

render_template() {
  local template="$1" version="$2" asset="$3" repo="$4"
  template="${template//\{version\}/$version}"
  template="${template//\{asset\}/$asset}"
  template="${template//\{repository\}/$repo}"
  printf '%s' "$template"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log_error "Benötigtes Werkzeug fehlt: $1"; exit 1; }
}

[[ -f "$MANIFEST" ]] || { log_error "Manifest fehlt: $MANIFEST"; exit 1; }
require_cmd python3
require_cmd curl
require_cmd sha256sum

if [[ -z "$REPO" ]]; then
  REPO="$(json_value repository)"
fi
if [[ -z "$REPO" || "$REPO" == "OWNER/REPO" ]]; then
  log_error "GitHub Repository ist nicht konfiguriert. Bitte --repo <owner/repo> oder YHSMCTL_REPO setzen."
  exit 2
fi

os_name="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$os_name" in linux) os_name="linux" ;; *) log_error "Nicht unterstütztes Betriebssystem: $os_name"; exit 2 ;; esac
arch="$(uname -m)"
case "$arch" in x86_64|amd64) arch="amd64" ;; *) log_error "Nicht unterstützte Architektur: $arch"; exit 2 ;; esac

asset="$(asset_for_platform "$os_name" "$arch")" || { log_error "Keine Asset-Zuordnung für $os_name-$arch im Manifest."; exit 2; }

if [[ "$VERSION" == "latest" ]]; then
  latest_api="https://api.github.com/repos/${REPO}/releases/latest"
  if latest_json="$(curl -fsSL "$latest_api" 2>/dev/null)"; then
    VERSION="$(python3 - <<'PY' "$latest_json"
import json, sys
print(json.loads(sys.argv[1]).get('tag_name', ''))
PY
)"
  fi
  if [[ -z "$VERSION" || "$VERSION" == "latest" ]]; then
    VERSION="$(json_value current_release_version)"
    log_warn "Latest Release konnte nicht über GitHub API ermittelt werden; nutze Manifest-Version $VERSION."
  fi
fi

release_template="$(json_value release_url_template)"
checksum_template="$(json_value checksum_url_template)"
asset_url="$(render_template "$release_template" "$VERSION" "$asset" "$REPO")"
checksum_url="$(render_template "$checksum_template" "$VERSION" "$asset" "$REPO")"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log_info "(dry-run) geplant/nicht ausgeführt: Download $asset_url"
  log_info "(dry-run) geplant/nicht ausgeführt: Download $checksum_url"
  log_info "(dry-run) geplant/nicht ausgeführt: SHA256 prüfen und nach $INSTALL_DIR/yhsmctl installieren"
  exit 0
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
curl -fsSL "$asset_url" -o "$tmp_dir/$asset"
curl -fsSL "$checksum_url" -o "$tmp_dir/$asset.sha256"
(
  cd "$tmp_dir"
  sha256sum -c "$asset.sha256"
)
mkdir -p "$INSTALL_DIR"
install -m 0755 "$tmp_dir/$asset" "$INSTALL_DIR/yhsmctl"
log_success "yhsmctl installiert: $INSTALL_DIR/yhsmctl"
