#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TARGET_REPO="skk-sec/yhsm-customer-pilot"
DEFAULT_TARGET_BRANCH="main"
DEFAULT_WORKDIR="${HOME}/git"
GH_KEYRING_URL="https://cli.github.com/packages/githubcli-archive-keyring.gpg"
GH_KEYRING_SHA256="6084d5d7bd8e288441e0e94fc6275570895da18e6751f70f057485dc2d1a811b"

TARGET_REPO="$DEFAULT_TARGET_REPO"
TARGET_BRANCH="$DEFAULT_TARGET_BRANCH"
WORKDIR="$DEFAULT_WORKDIR"
TARGET_VISIBILITY="private"
DRY_RUN=0

log_info() { printf '[*] %s\n' "$*"; }
log_warn() { printf '[!] %s\n' "$*"; }
log_ok() { printf '[+] %s\n' "$*"; }
log_error() { printf '[-] %s\n' "$*" >&2; }

usage() {
  cat <<'USAGE'
Customer YubiHSM Stage-0 Bootstrap

Usage:
  ./client/bootstrap.sh [options]

Options:
  --target-repo <owner/repo>   Repository cloned after bootstrap.
                               Default: skk-sec/yhsm-customer-pilot
  --target-branch <branch>     Branch to clone. Default: main
  --workdir <path>             Parent directory for the clone. Default: ~/git
  --public-target              Target repository is public; GitHub login is not required.
  --private-target             Target repository is private; install/authenticate gh. Default.
  --dry-run                    Print the plan only; no package install, auth or clone.
  -h, --help                   Show this help.

Stage-0 scope:
  - Debian/Ubuntu apt-based hosts only.
  - Installs only baseline client-access tools (ca-certificates, curl, git and, for private targets, gh).
  - Uses the official GitHub CLI Debian repository and verifies its keyring SHA-256 before installation.
  - Uses GitHub device/web authentication for private targets; no token is accepted in argv.
  - Clones the selected customer repository and prints a readback.
  - Performs no DNS, Connector, HSM, AD, PKI or other target-system mutation.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-repo)
      TARGET_REPO="${2:-}"
      shift 2
      ;;
    --target-branch)
      TARGET_BRANCH="${2:-}"
      shift 2
      ;;
    --workdir)
      WORKDIR="${2:-}"
      shift 2
      ;;
    --public-target)
      TARGET_VISIBILITY="public"
      shift
      ;;
    --private-target)
      TARGET_VISIBILITY="private"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "Unknown option (value redacted)."
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$TARGET_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { log_error "Invalid --target-repo."; exit 2; }
[[ "$TARGET_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || { log_error "Invalid --target-branch."; exit 2; }
[[ "$TARGET_VISIBILITY" == "public" || "$TARGET_VISIBILITY" == "private" ]] || { log_error "Invalid target visibility."; exit 2; }
[[ -n "$WORKDIR" ]] || { log_error "--workdir must not be empty."; exit 2; }

if [[ ! -r /etc/os-release ]]; then
  log_error "Unsupported host: /etc/os-release is missing."
  exit 1
fi
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in
  debian:*|ubuntu:*|*:debian*|*:ubuntu*) ;;
  *)
    log_error "Stage-0 currently supports Debian/Ubuntu apt-based hosts only."
    exit 1
    ;;
esac

for cmd in bash curl sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || { log_error "Required Stage-0 tool missing: $cmd"; exit 1; }
done
command -v apt-get >/dev/null 2>&1 || { log_error "Required package manager missing: apt-get"; exit 1; }
command -v dpkg >/dev/null 2>&1 || { log_error "Required package tool missing: dpkg"; exit 1; }

if [[ "$EUID" -eq 0 ]]; then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || { log_error "sudo is required for package installation."; exit 1; }
  SUDO=(sudo)
fi

clone_url="https://github.com/${TARGET_REPO}.git"
dest_name="${TARGET_REPO##*/}"
dest_path="${WORKDIR%/}/${dest_name}"

log_info "Stage=0"
log_info "TargetRepository=$TARGET_REPO"
log_info "TargetBranch=$TARGET_BRANCH"
log_info "TargetVisibility=$TARGET_VISIBILITY"
log_info "Workdir=<local-path>"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log_info "(dry-run) install ca-certificates and git if missing"
  if [[ "$TARGET_VISIBILITY" == "private" ]]; then
    log_info "(dry-run) install GitHub CLI from the official signed Debian repository if missing"
    log_info "(dry-run) authenticate with GitHub device/web flow if not already authenticated"
    log_info "(dry-run) configure gh as the Git credential helper"
  fi
  log_info "(dry-run) clone exact branch '$TARGET_BRANCH' from $TARGET_REPO"
  log_info "(dry-run) print repository/branch/head readback"
  log_ok "Stage-0 dry-run complete; no changes performed."
  exit 0
fi

"${SUDO[@]}" -v

need_base=0
command -v git >/dev/null 2>&1 || need_base=1
if ! dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -Fq 'install ok installed'; then
  need_base=1
fi
if [[ "$need_base" -eq 1 ]]; then
  log_info "Installing baseline client-access packages."
  "${SUDO[@]}" apt-get update
  "${SUDO[@]}" apt-get install -y --no-install-recommends ca-certificates git
else
  log_ok "Baseline client-access packages already present."
fi

install_gh() {
  if command -v gh >/dev/null 2>&1; then
    log_ok "GitHub CLI already present."
    return
  fi

  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  log_info "Downloading official GitHub CLI repository keyring."
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error "$GH_KEYRING_URL" -o "$tmp"
  printf '%s  %s\n' "$GH_KEYRING_SHA256" "$tmp" | sha256sum -c - >/dev/null || {
    log_error "GitHub CLI keyring SHA-256 verification failed."
    return 1
  }

  "${SUDO[@]}" mkdir -p -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d
  "${SUDO[@]}" install -m 0644 "$tmp" /etc/apt/keyrings/githubcli-archive-keyring.gpg
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' "$(dpkg --print-architecture)" |
    "${SUDO[@]}" tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  "${SUDO[@]}" apt-get update
  "${SUDO[@]}" apt-get install -y --no-install-recommends gh
  command -v gh >/dev/null 2>&1 || { log_error "GitHub CLI installation did not produce gh."; return 1; }
  log_ok "GitHub CLI installed."
}

if [[ "$TARGET_VISIBILITY" == "private" ]]; then
  install_gh
  if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    log_info "GitHub authentication required for the private customer repository."
    log_info "Complete the one-time device/web flow shown by GitHub CLI."
    gh auth login --hostname github.com --git-protocol https --web
  else
    log_ok "GitHub authentication already present."
  fi
  gh auth setup-git --hostname github.com
  gh repo view "$TARGET_REPO" --json nameWithOwner,visibility,defaultBranchRef >/dev/null || {
    log_error "Authenticated GitHub account cannot access the target repository."
    exit 1
  }
fi

mkdir -p "$WORKDIR"
if [[ -e "$dest_path" && ! -d "$dest_path/.git" ]]; then
  log_error "Clone destination exists but is not a Git repository."
  exit 1
fi

if [[ -d "$dest_path/.git" ]]; then
  actual_remote="$(git -C "$dest_path" config --get remote.origin.url 2>/dev/null || true)"
  case "$actual_remote" in
    "$clone_url"|"https://github.com/$TARGET_REPO") ;;
    *)
      log_error "Existing clone has an unexpected origin remote."
      exit 1
      ;;
  esac
  log_info "Existing clone found; updating branch with fast-forward only."
  git -C "$dest_path" fetch origin "$TARGET_BRANCH" --quiet
  git -C "$dest_path" checkout "$TARGET_BRANCH" --quiet
  git -C "$dest_path" pull --ff-only origin "$TARGET_BRANCH" --quiet
else
  log_info "Cloning customer repository."
  git clone --branch "$TARGET_BRANCH" --single-branch "$clone_url" "$dest_path"
fi

repo_head="$(git -C "$dest_path" rev-parse HEAD)"
repo_branch="$(git -C "$dest_path" branch --show-current)"
repo_remote="$(git -C "$dest_path" config --get remote.origin.url)"

printf '%s\n' '--- STAGE-0 READBACK ---'
printf 'repository=%s\n' "$TARGET_REPO"
printf 'branch=%s\n' "$repo_branch"
printf 'head=%s\n' "$repo_head"
printf 'remote=%s\n' "$repo_remote"
printf 'path=%s\n' "$dest_path"

if [[ -f "$dest_path/client/README.md" ]]; then
  log_ok "Customer client package found."
  log_info "Next: read client/README.md and run only the documented customer preflight/install steps."
else
  log_warn "Target repository has no client/README.md; stop and verify the selected channel."
fi

log_ok "Stage-0 onboarding complete."
