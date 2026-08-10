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
ISSUE_SMOKE_TEST=0
SMOKE_ISSUE_REPO=""
SMOKE_ISSUE_NUMBER=""

sensitive_argv_key() {
  local key="$1"
  key="${key%%=*}"
  key="${key#--}"
  key="${key#-}"
  key="${key,,}"
  [[ "$key" =~ (token|pass(word)?|secret|key|auth|credential) ]]
}

mask_argv_arg() {
  local arg="$1" key
  if [[ "$arg" == *=* ]]; then
    key="${arg%%=*}"
    if sensitive_argv_key "$key"; then
      printf '%s=***' "$key"
      return
    fi
  fi
  printf '%s' "$arg"
}

print_argv_banner() {
  local masked=() arg
  local mask_next=0
  for arg in "$@"; do
    if [[ "$mask_next" -eq 1 ]]; then
      masked+=("***")
      mask_next=0
      continue
    fi
    if [[ "$arg" == *=* ]] && sensitive_argv_key "${arg%%=*}"; then
      masked+=("$(mask_argv_arg "$arg")")
      continue
    fi
    if [[ "$arg" == -* ]] && sensitive_argv_key "$arg"; then
      masked+=("$arg")
      mask_next=1
      continue
    fi
    masked+=("$arg")
  done
  printf '[argv] %s %s\n' "$(basename -- "$0")" "${masked[*]}"
}

log_info() { printf '[*] %s\n' "$*"; }
log_warn() { printf '[!] %s\n' "$*"; }
log_ok() { printf '[+] %s\n' "$*"; }
log_error() { printf '[-] %s\n' "$*" >&2; }

usage() {
  cat <<'USAGE'
Customer YubiHSM Stage-0 Bootstrap

Usage:
  ./bootstrap.sh [options]

Options:
  --target-repo <owner/repo>   Repository cloned after bootstrap.
                               Default: skk-sec/yhsm-customer-pilot
  --target-branch <branch>     Branch to clone. Default: main
  --workdir <path>             Parent directory for the clone. Default: ~/git
  --private-target             Private target: install/authenticate gh. Default.
  --public-target              Public target: GitHub login is not required.
  --issue-smoke-test           After private authentication, create/comment/view/close
                               one sanitized temporary GitHub issue.
  --dry-run                    Print the plan only; no package install, auth, clone or issue write.
  -h, --help                   Show this help.

Stage-0 scope:
  - Debian/Ubuntu apt-based hosts only.
  - Installs baseline repository-access tools only.
  - For private targets installs GitHub CLI from the official signed Debian repository.
  - Uses GitHub device/web authentication; token-bearing GitHub auth environment variables are rejected.
  - Verifies private repository and issue read access, clones main and prints readback.
  - Optional issue smoke test is explicit and writes only a sanitized temporary issue.
  - Performs no DNS, Connector, HSM, AD, PKI or release mutation.
USAGE
}

print_argv_banner "$@"

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
    --private-target)
      TARGET_VISIBILITY="private"
      shift
      ;;
    --public-target)
      TARGET_VISIBILITY="public"
      shift
      ;;
    --issue-smoke-test)
      ISSUE_SMOKE_TEST=1
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
if [[ "$ISSUE_SMOKE_TEST" -eq 1 && "$TARGET_VISIBILITY" != "private" ]]; then
  log_error "--issue-smoke-test requires --private-target in the current pilot contract."
  exit 2
fi

reject_github_token_environment() {
  local name
  [[ "$TARGET_VISIBILITY" == "private" ]] || return 0
  for name in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
    if [[ -v "$name" && -n "${!name}" ]]; then
      log_error "$name is set; private Stage-0 requires GitHub Device/Web authentication. Unset the variable and retry."
      return 1
    fi
  done
}

reject_github_token_environment

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
log_info "IssueSmokeTest=$([[ "$ISSUE_SMOKE_TEST" -eq 1 ]] && echo enabled || echo disabled)"
log_info "Workdir=<local-path>"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log_info "(dry-run) install ca-certificates and git if missing"
  if [[ "$TARGET_VISIBILITY" == "private" ]]; then
    log_info "(dry-run) install GitHub CLI from the official signed Debian repository if missing"
    log_info "(dry-run) authenticate with GitHub device/web flow if not already authenticated"
    log_info "(dry-run) configure gh as the Git credential helper"
    log_info "(dry-run) verify private repository and issue read access"
  fi
  log_info "(dry-run) clone exact branch '$TARGET_BRANCH' from $TARGET_REPO"
  log_info "(dry-run) print repository/branch/head readback"
  if [[ "$ISSUE_SMOKE_TEST" -eq 1 ]]; then
    log_info "(dry-run) create, comment, view and close one sanitized temporary GitHub issue"
  fi
  log_ok "Stage-0 dry-run complete; no changes performed."
  exit 0
fi

ensure_sudo_auth() {
  if [[ "${#SUDO[@]}" -eq 0 ]]; then
    return
  fi
  if sudo -n true 2>/dev/null; then
    log_ok "sudo authorization already active."
    return
  fi
  log_info "Local sudo authentication is required for package installation."
  log_info "Enter only the local password at the sudo prompt; do not paste further commands until the shell prompt returns."
  sudo -v || {
    log_error "sudo authentication failed; no package installation was started."
    return 1
  }
  sudo -n true 2>/dev/null || {
    log_error "sudo authorization did not become non-interactive after authentication."
    return 1
  }
  log_ok "sudo authorization verified."
}

ensure_sudo_auth

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
  log_info "Downloading official GitHub CLI repository keyring."
  if ! curl --proto '=https' --tlsv1.2 --fail --silent --show-error "$GH_KEYRING_URL" -o "$tmp"; then
    rm -f "$tmp"
    log_error "GitHub CLI keyring download failed."
    return 1
  fi
  if ! printf '%s  %s\n' "$GH_KEYRING_SHA256" "$tmp" | sha256sum -c - >/dev/null; then
    rm -f "$tmp"
    log_error "GitHub CLI keyring SHA-256 verification failed."
    return 1
  fi

  "${SUDO[@]}" mkdir -p -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d
  "${SUDO[@]}" install -m 0644 "$tmp" /etc/apt/keyrings/githubcli-archive-keyring.gpg
  rm -f "$tmp"
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
  gh issue list --repo "$TARGET_REPO" --limit 1 >/dev/null || {
    log_error "Authenticated GitHub account cannot read issues in the target repository."
    exit 1
  }
  log_ok "Private repository and issue read access verified."
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
else
  log_warn "Target repository has no client/README.md; verify the selected channel."
fi

cleanup_issue_smoke_test() {
  if [[ -z "$SMOKE_ISSUE_REPO" || -z "$SMOKE_ISSUE_NUMBER" ]]; then
    return 0
  fi
  gh issue close "$SMOKE_ISSUE_NUMBER" \
    --repo "$SMOKE_ISSUE_REPO" \
    --comment 'Stage-0 cleanup closed the temporary smoke-test issue after an interrupted verification.' \
    >/dev/null 2>&1 || true
}

run_issue_smoke_test() {
  local issue_url issue_number
  log_info "Creating sanitized temporary support-channel smoke-test issue."
  issue_url="$(gh issue create \
    --repo "$TARGET_REPO" \
    --title '[pilot-smoke] Stage-0 issue channel verification' \
    --body 'Automated Stage-0 support-channel smoke test. No customer evidence, credentials, secrets, keys, tokens or authorization data included.')"
  issue_number="${issue_url##*/}"
  [[ "$issue_number" =~ ^[0-9]+$ ]] || {
    log_error "Issue smoke test created an unparseable issue reference."
    return 1
  }
  SMOKE_ISSUE_REPO="$TARGET_REPO"
  SMOKE_ISSUE_NUMBER="$issue_number"
  trap cleanup_issue_smoke_test EXIT
  log_info "IssueSmokeTestIssue=$issue_number"
  gh issue comment "$issue_number" \
    --repo "$TARGET_REPO" \
    --body 'Stage-0 issue comment path verified.' >/dev/null
  gh issue view "$issue_number" \
    --repo "$TARGET_REPO" \
    --json number,state,title >/dev/null
  gh issue close "$issue_number" \
    --repo "$TARGET_REPO" \
    --comment 'Stage-0 issue-channel smoke test completed successfully; no product incident.' >/dev/null
  SMOKE_ISSUE_REPO=""
  SMOKE_ISSUE_NUMBER=""
  trap - EXIT
  log_ok "IssueSmokeTest=PASS issue=$issue_number"
}

if [[ "$ISSUE_SMOKE_TEST" -eq 1 ]]; then
  run_issue_smoke_test
fi

log_info "Next: read the cloned customer documentation and follow only documented preflight/install steps."
log_ok "Stage-0 onboarding complete."
