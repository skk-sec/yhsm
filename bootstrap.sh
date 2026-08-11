#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TARGET_BRANCH="main"
DEFAULT_WORKDIR="${HOME}/git"
GH_KEYRING_URL="https://cli.github.com/packages/githubcli-archive-keyring.gpg"
GH_KEYRING_SHA256="6084d5d7bd8e288441e0e94fc6275570895da18e6751f70f057485dc2d1a811b"

TARGET_REPO=""
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
  [[ "$key" =~ (token|pass(word)?|secret|key|auth|credential|cookie|pin) ]]
}

is_contract_status() {
  case "$1" in
    PASS|WARN|BLOCKED|UNKNOWN) return 0 ;;
    *) return 1 ;;
  esac
}

valid_target_branch() {
  local branch="$1"
  [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ && "$branch" != -* ]] || return 1
  [[ "$branch" != HEAD ]] || return 1
  [[ "$branch" != /* && "$branch" != */ && "$branch" != *//* && "$branch" != *..* ]] || return 1
  [[ "$branch" != .* && "$branch" != */.* ]] || return 1
  [[ "$branch" != *. && "$branch" != *./* ]] || return 1
  [[ "$branch" != *.lock && "$branch" != *.lock/* ]] || return 1
  return 0
}

authorization_scheme_marker() {
  local lower="${1,,}"
  [[ "$lower" =~ ^[[:space:]]*(basic|bearer|digest|negotiate|ntlm)[[:space:]]*$ || "$lower" =~ ^[[:space:]]*(proxy-)?authorization:[[:space:]]*(basic|bearer|digest|negotiate|ntlm)[[:space:]]*$ ]]
}

stage0_value_option() {
  case "${1,,}" in
    --target-repo|--target-branch|--workdir) return 0 ;;
    *) return 1 ;;
  esac
}

mask_argv_arg() {
  local arg="$1" key value
  if [[ "$arg" == *=* ]]; then
    key="${arg%%=*}"
    value="${arg#*=}"
    if sensitive_argv_key "$key" || sensitive_argv_value "$value"; then
      printf '%s=***' "$key"
      return
    fi
  fi
  if sensitive_argv_value "$arg"; then
    printf '%s' '***'
    return
  fi
  printf '%s' "$arg"
}

sensitive_argv_value() {
  local value="$1"
  local lower="${value,,}"
  [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]] && return 0
  [[ "$value" =~ ^[[:space:]]*[A-Za-z][A-Za-z0-9+.-]*://[^/@]+@ ]] && return 0
  is_contract_status "$value" && return 1
  if [[ "$value" =~ ^([^=[:space:]]+)=(.*)$ ]] && sensitive_argv_key "${BASH_REMATCH[1]}"; then
    return 0
  fi
  [[ "$value" =~ (^|[^A-Za-z0-9_])gh[pousr]_[A-Za-z0-9_]{8,}($|[^A-Za-z0-9_]) ]] && return 0
  [[ "$value" =~ (^|[^A-Za-z0-9_])github_pat_[A-Za-z0-9_]{8,}($|[^A-Za-z0-9_]) ]] && return 0
  [[ "$value" =~ (^|[^A-Za-z0-9-])xox[a-z]-[A-Za-z0-9-]{8,}($|[^A-Za-z0-9-]) ]] && return 0
  [[ "$value" =~ (^|[^A-Za-z0-9-])xapp-[0-9]+-[A-Za-z0-9]+-[A-Za-z0-9-]{8,}($|[^A-Za-z0-9-]) ]] && return 0
  [[ "$value" =~ (^|[^A-Za-z0-9_-])eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*($|[^A-Za-z0-9_-]) ]] && return 0
  [[ "$lower" =~ ^(proxy-)?authorization:[[:space:]]*.+$ ]] && return 0
  [[ "$lower" =~ ^(basic|bearer|digest|negotiate|ntlm)[[:space:]]+.+$ ]] && return 0
  return 1
}

print_argv_banner() {
  local masked=() arg lower value
  local mask_next=0
  local authorization_next=0
  for arg in "$@"; do
    lower="${arg,,}"
    case "$lower" in
      --target-repo|--target-branch|--workdir)
        masked+=("$arg")
        mask_next=1
        continue
        ;;
      --target-repo=*|--target-branch=*|--workdir=*)
        masked+=("${arg%%=*}=***")
        continue
        ;;
    esac
    if [[ "$mask_next" -eq 1 ]]; then
      masked+=("***")
      if authorization_scheme_marker "$arg" || stage0_value_option "$arg" || { [[ "$arg" == -* ]] && sensitive_argv_key "$arg"; }; then
        mask_next=1
      else
        mask_next=0
      fi
      continue
    fi
    if [[ "$authorization_next" -eq 1 ]]; then
      case "$lower" in
        basic|bearer|digest|negotiate|ntlm)
          masked+=("$arg")
          mask_next=1
          ;;
        *)
          masked+=("***")
          ;;
      esac
      authorization_next=0
      continue
    fi
    if [[ "$lower" =~ ^(proxy-)?authorization:[[:space:]]*(basic|bearer|digest|negotiate|ntlm)$ ]]; then
      masked+=("$arg")
      mask_next=1
      continue
    fi
    case "$lower" in
      authorization:|proxy-authorization:)
        masked+=("$arg")
        authorization_next=1
        continue
        ;;
      basic|bearer|digest|negotiate|ntlm)
        masked+=("$arg")
        mask_next=1
        continue
        ;;
    esac
    if [[ "$arg" == *=* ]] && { sensitive_argv_key "${arg%%=*}" || sensitive_argv_value "${arg#*=}"; }; then
      value="${arg#*=}"
      masked+=("$(mask_argv_arg "$arg")")
      if authorization_scheme_marker "$value"; then
        mask_next=1
      fi
      continue
    fi
    if [[ "$arg" == -* ]] && sensitive_argv_key "$arg"; then
      masked+=("$arg")
      mask_next=1
      continue
    fi
    if sensitive_argv_value "$arg"; then
      masked+=("***")
      continue
    fi
    case "$lower" in
      --private-target|--public-target|--issue-smoke-test|--dry-run|-h|--help)
        masked+=("$arg")
        ;;
      *)
        # Unknown operands have not passed option validation yet. Never copy
        # them verbatim into the startup banner.
        masked+=("***")
        ;;
    esac
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
  bash ./bootstrap.sh --target-repo <owner/repo> [options]

Examples:
  bash ./bootstrap.sh --private-target --target-repo example-org/pilot-repository

Options:
  --target-repo <owner/repo>   Required customer repository cloned after bootstrap.
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
  - Requires a working system credential store and refuses gh plaintext token storage.
  - Uses GitHub device/web authentication; token-bearing GitHub auth environment variables are rejected.
  - Verifies private repository and issue read access, clones the selected branch and prints readback.
  - Optional issue smoke test is explicit and writes only a sanitized temporary GitHub issue.
  - Performs no DNS, Connector, HSM, AD, PKI or release mutation.
  - The public Stage-0 repository contains no implicit private customer default; the customer channel is always explicit.
USAGE
}

print_argv_banner "$@"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-repo)
      [[ $# -ge 2 && "${2:-}" != -* ]] || { log_error "--target-repo requires a repository operand."; exit 2; }
      TARGET_REPO="$2"
      shift 2
      ;;
    --target-branch)
      [[ $# -ge 2 && "${2:-}" != -* ]] || { log_error "--target-branch requires a branch operand."; exit 2; }
      TARGET_BRANCH="$2"
      shift 2
      ;;
    --workdir)
      [[ $# -ge 2 && "${2:-}" != -* ]] || { log_error "--workdir requires a path operand."; exit 2; }
      WORKDIR="$2"
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

[[ -n "$TARGET_REPO" ]] || {
  log_error "--target-repo is required; use the customer-specific private channel provided by the operator."
  exit 2
}
[[ "$TARGET_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { log_error "Invalid --target-repo."; exit 2; }
if sensitive_argv_value "$TARGET_REPO" || sensitive_argv_value "${TARGET_REPO%%/*}" || sensitive_argv_value "${TARGET_REPO##*/}"; then
  log_error "--target-repo contains a sensitive-shaped value and is rejected."
  exit 2
fi
valid_target_branch "$TARGET_BRANCH" || { log_error "Invalid --target-branch."; exit 2; }
if sensitive_argv_value "$TARGET_BRANCH"; then
  log_error "--target-branch contains a sensitive-shaped value and is rejected."
  exit 2
fi
[[ "$TARGET_VISIBILITY" == "public" || "$TARGET_VISIBILITY" == "private" ]] || { log_error "Invalid target visibility."; exit 2; }
[[ -n "$WORKDIR" ]] || { log_error "--workdir must not be empty."; exit 2; }
[[ "$WORKDIR" != -* ]] || { log_error "Invalid --workdir."; exit 2; }
if sensitive_argv_value "$WORKDIR"; then
  log_error "--workdir contains a sensitive-shaped value and is rejected."
  exit 2
fi
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

reject_git_repository_environment() {
  local name
  for name in \
    GIT_DIR \
    GIT_WORK_TREE \
    GIT_COMMON_DIR \
    GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_INDEX_FILE \
    GIT_GRAFT_FILE \
    GIT_SHALLOW_FILE \
    GIT_IMPLICIT_WORK_TREE \
    GIT_NAMESPACE \
    GIT_NO_REPLACE_OBJECTS \
    GIT_REPLACE_REF_BASE \
    GIT_PREFIX \
    GIT_INTERNAL_SUPER_PREFIX \
    GIT_CONFIG \
    GIT_CONFIG_SYSTEM \
    GIT_CONFIG_GLOBAL \
    GIT_CONFIG_NOSYSTEM \
    GIT_CONFIG_PARAMETERS \
    GIT_CONFIG_COUNT; do
    if [[ -v "$name" ]]; then
      log_error "$name is set; Stage-0 refuses repository-local Git environment overrides. Unset the variable and retry."
      return 1
    fi
  done
  while IFS= read -r name; do
    case "$name" in
      GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*)
        log_error "$name is set; Stage-0 refuses repository-local Git environment overrides. Unset the variable and retry."
        return 1
        ;;
    esac
  done < <(compgen -A variable)
}

reject_git_repository_environment || exit 1

reject_git_config_matches() {
  local description="$1"
  shift
  local config_output config_rc
  if config_output="$(git "$@" 2>&1)"; then
    if [[ -n "$config_output" ]]; then
      log_error "$description"
      return 1
    fi
    return 0
  else
    config_rc=$?
  fi
  if [[ "$config_rc" -eq 1 && -z "$config_output" ]]; then
    return 0
  fi
  log_error "Unable to inspect Git execution configuration; refusing Stage-0 onboarding."
  return 1
}

reject_existing_clone_execution_config() {
  local repo_path="$1"
  reject_git_config_matches \
    "Existing clone has executable Git filter configuration; refusing to inspect or update its worktree." \
    -C "$repo_path" config --local --get-regexp '^filter\..*\.(clean|smudge|process)$' || return 1
  reject_git_config_matches \
    "Existing clone has a repository-local Git credential helper; refusing authenticated fetch." \
    -C "$repo_path" config --local --get-all credential.helper
}

if [[ ! -r /etc/os-release ]]; then
  log_error "Unsupported host: /etc/os-release is missing."
  exit 1
fi
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in
  debian:*|ubuntu:*|*:debian*|*:ubuntu*) ;;
  *) log_error "Stage-0 currently supports Debian/Ubuntu apt-based hosts only."; exit 1 ;;
esac

for cmd in bash sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || { log_error "Required Stage-0 tool missing: $cmd"; exit 1; }
done
command -v apt-get >/dev/null 2>&1 || { log_error "Required package manager missing: apt-get"; exit 1; }
command -v dpkg >/dev/null 2>&1 || { log_error "Required package tool missing: dpkg"; exit 1; }

SUDO=()

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
    log_info "(dry-run) require and verify a secure system credential store"
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
  if [[ "$EUID" -eq 0 ]]; then SUDO=(); return; fi
  command -v sudo >/dev/null 2>&1 || { log_error "sudo is required because package installation is needed."; return 1; }
  SUDO=(sudo)
  if sudo -n true 2>/dev/null; then log_ok "sudo authorization already active."; return; fi
  log_info "Local sudo authentication is required for package installation."
  log_info "Enter only the local password at the sudo prompt; do not paste further commands until the shell prompt returns."
  sudo -v || { log_error "sudo authentication failed; no package installation was started."; return 1; }
  sudo -n true 2>/dev/null || { log_error "sudo authorization did not become non-interactive after authentication."; return 1; }
  log_ok "sudo authorization verified."
}

missing_packages=()
command -v git >/dev/null 2>&1 || missing_packages+=(git)
if ! dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -Fq 'install ok installed'; then missing_packages+=(ca-certificates); fi
if [[ "$TARGET_VISIBILITY" == "private" ]] && ! command -v gh >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then missing_packages+=(curl); fi
if [[ "$TARGET_VISIBILITY" == "private" ]] && ! command -v secret-tool >/dev/null 2>&1; then missing_packages+=(libsecret-tools); fi
if [[ "${#missing_packages[@]}" -gt 0 ]]; then
  ensure_sudo_auth
  log_info "Installing missing client-access packages."
  "${SUDO[@]}" apt-get update
  "${SUDO[@]}" apt-get install -y --no-install-recommends "${missing_packages[@]}"
else
  log_ok "Baseline client-access packages already present."
fi

effective_clone_url="$(git ls-remote --get-url "$clone_url" 2>/dev/null)" || {
  log_error "Git could not resolve the requested GitHub clone URL without contacting the target repository."
  exit 1
}
[[ "$effective_clone_url" == "$clone_url" ]] || {
  log_error "Git URL rewriting is active for the requested GitHub repository; refusing clone or fetch from a substituted remote."
  exit 1
}

install_gh() {
  if command -v gh >/dev/null 2>&1; then log_ok "GitHub CLI already present."; return; fi
  command -v curl >/dev/null 2>&1 || { log_error "curl installation did not produce curl before GitHub CLI bootstrap."; return 1; }
  ensure_sudo_auth
  local tmp
  tmp="$(mktemp)"
  log_info "Downloading official GitHub CLI repository keyring."
  if ! curl --proto '=https' --tlsv1.2 --fail --silent --show-error "$GH_KEYRING_URL" -o "$tmp"; then
    rm -f "$tmp"; log_error "GitHub CLI keyring download failed."; return 1
  fi
  if ! printf '%s  %s\n' "$GH_KEYRING_SHA256" "$tmp" | sha256sum -c - >/dev/null; then
    rm -f "$tmp"; log_error "GitHub CLI keyring SHA-256 verification failed."; return 1
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

reject_plaintext_gh_credentials() {
  local config_file="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}/hosts.yml"
  if [[ -f "$config_file" ]] && awk '
      function value_position(line, pos, n) {
        while (pos <= n && substr(line, pos, 1) ~ /[[:space:]]/) pos++
        return pos
      }
      function percent_decode(value, out, i, c, high, low) {
        out=""
        for (i=1; i<=length(value); i++) {
          c=substr(value, i, 1)
          if (c == "%" && i + 2 <= length(value)) {
            high=hex_digit(substr(value, i + 1, 1))
            low=hex_digit(substr(value, i + 2, 1))
            if (high >= 0 && low >= 0) {
              out=out sprintf("%c", high * 16 + low)
              i+=2
              continue
            }
          }
          out=out c
        }
        return out
      }
      function tag_is_string(tag, second, handle, suffix, expanded) {
        if (substr(tag, 1, 2) == "!<" && substr(tag, length(tag), 1) == ">") {
          expanded=substr(tag, 3, length(tag) - 3)
          return percent_decode(expanded) == "tag:yaml.org,2002:str"
        }
        if (substr(tag, 1, 1) != "!") return 0
        second=index(substr(tag, 2), "!")
        if (second) {
          second++
          handle=substr(tag, 1, second)
          suffix=substr(tag, second + 1)
        } else {
          handle="!"
          suffix=substr(tag, 2)
        }
        if (!(handle in tag_handle_prefix)) return 0
        expanded=tag_handle_prefix[handle] suffix
        return percent_decode(expanded) == "tag:yaml.org,2002:str"
      }
      function value_node_position(line, pos, n, c, start, tag) {
        value_node_explicit_string=0
        pos=value_position(line, pos, n)
        while (pos <= n && (substr(line, pos, 1) == "!" || substr(line, pos, 1) == "&")) {
          start=pos
          if (substr(line, pos, 1) == "&") {
            pos++
            while (pos <= n && substr(line, pos, 1) !~ /[[:space:]{}\[\],]/) pos++
          } else {
            pos++
            if (substr(line, pos, 1) == "<") {
              pos++
              while (pos <= n && substr(line, pos, 1) != ">") pos++
              if (pos <= n) pos++
            } else {
              while (pos <= n && substr(line, pos, 1) !~ /[[:space:]{}\[\],]/) pos++
            }
            tag=substr(line, start, pos - start)
            if (tag_is_string(tag)) value_node_explicit_string=1
          }
          pos=value_position(line, pos, n)
        }
        return pos
      }
      function value_tag_only(line, pos, n, resolved) {
        pos=value_position(line, pos, n)
        if (substr(line, pos, 1) != "!" && substr(line, pos, 1) != "&") {
          value_tag_only_explicit_string=0
          return 0
        }
        resolved=value_node_position(line, pos, n)
        value_tag_only_explicit_string=value_node_explicit_string
        return resolved > n || substr(line, resolved, 1) == "#"
      }
      function empty_value_tail(line, pos, n, c) {
        if (pos > n) return 1
        c=substr(line, pos, 1)
        if (c ~ /[[:space:]]/) {
          pos=value_position(line, pos, n)
          if (pos > n) return 1
          c=substr(line, pos, 1)
          return c == "#" || c == "," || c == "}"
        }
        return c == "," || c == "}"
      }
      function value_present(line, pos, n, force_string, c, j, word, explicit_string) {
        pos=value_node_position(line, pos, n)
        explicit_string=force_string || value_node_explicit_string
        if (pos > n) return 0
        c=substr(line, pos, 1)
        if (c == "}" || c == "," || c == "#" || block_scalar_value(line, pos, n)) return 0
        if (!explicit_string && c == "~" && empty_value_tail(line, pos + 1, n)) return 0
        word=tolower(substr(line, pos, 4))
        if (!explicit_string && word == "null" && empty_value_tail(line, pos + 4, n)) return 0
        if ((c == "\"" || c == sq) && substr(line, pos + 1, 1) == c && empty_value_tail(line, pos + 2, n)) return 0
        if (c == "{" || c == "[") {
          j=value_position(line, pos + 1, n)
          if (((c == "{" && substr(line, j, 1) == "}") || (c == "[" && substr(line, j, 1) == "]")) && empty_value_tail(line, j + 1, n)) return 0
        }
        return 1
      }
      function value_deferred(line, pos, n, c) {
        pos=value_node_position(line, pos, n)
        return pos > n || substr(line, pos, 1) == "#" || block_scalar_value(line, pos, n)
      }
      function block_scalar_value(line, pos, n, c) {
        pos=value_node_position(line, pos, n)
        c=substr(line, pos, 1)
        if (c != "|" && c != ">") return 0
        pos++
        while (pos <= n && substr(line, pos, 1) ~ /[1-9+-]/) pos++
        pos=value_position(line, pos, n)
        return pos > n || substr(line, pos, 1) == "#"
      }
      function block_scalar_keeps_blank(line, pos, n, c) {
        pos=value_node_position(line, pos, n) + 1
        while (pos <= n) {
          c=substr(line, pos, 1)
          if (c == "+") return 1
          if (c == "-") return 0
          if (c ~ /[[:space:]]/ || c == "#") break
          pos++
        }
        return 0
      }
      function empty_quoted_value_continues(line, pos, n) {
        pos=value_node_position(line, pos, n)
        return substr(line, pos, 1) == "\"" && substr(line, pos + 1, 1) == "\\" && pos + 1 == n
      }
      function hex_digit(c, p) {
        p=index("0123456789abcdef", tolower(c))
        return p ? p - 1 : -1
      }
      function decode_ascii_hex(value, width, i, digit, number) {
        if (length(value) != width) return invalid_escape
        number=0
        for (i=1; i<=width; i++) {
          digit=hex_digit(substr(value, i, 1))
          if (digit < 0) return invalid_escape
          number=number * 16 + digit
        }
        return number <= 127 ? sprintf("%c", number) : invalid_escape
      }
      function decode_simple_yaml_escape(c) {
        if (c == "\"" || c == "/" || c == "\\") return c
        return invalid_escape
      }
      function leading_spaces(line, i) {
        i=1
        while (substr(line, i, 1) == " ") i++
        return i - 1
      }
      BEGIN {
        sq=sprintf("%c", 39)
        invalid_escape=sprintf("%c", 1)
        tag_handle_prefix["!!"]="tag:yaml.org,2002:"
        in_block_scalar=0
        block_indent=-1
        pending_oauth_value=0
        pending_oauth_indent=-1
        pending_oauth_block_scalar=0
        pending_oauth_block_preserves_blank=0
        pending_oauth_flow_value=0
        pending_oauth_empty_quoted_value=0
        pending_oauth_value_tag_only=0
        pending_oauth_value_explicit_string=0
        pending_explicit_oauth_key=0
        pending_explicit_oauth_indent=-1
        pending_explicit_key_node=0
        pending_explicit_key_indent=-1
        in_explicit_key_scalar=0
        explicit_key_scalar_parent_indent=-1
        explicit_key_scalar_mapping_indent=-1
        explicit_key_scalar_content_indent=-1
        explicit_key_scalar_indent_indicator=0
        explicit_key_scalar_chomp=""
        explicit_key_scalar_seen=0
        explicit_key_scalar_exact=1
        in_explicit_quoted_key=0
        explicit_quoted_key_token=""
        explicit_quoted_key_mapping_indent=-1
        flow_depth=0
      }
      {
        line=$0
        sub(/\r$/, "", line)
        n=length(line)
        indent=leading_spaces(line)
        if (line ~ /^%TAG[[:space:]]+/) {
          directive_count=split(line, directive_fields, /[[:space:]]+/)
          if (directive_count >= 3) tag_handle_prefix[directive_fields[2]]=directive_fields[3]
          next
        }
        if (pending_oauth_empty_quoted_value) {
          pos=value_position(line, 1, n)
          if (substr(line, pos, 1) == "\\" && pos == n) next
          if (substr(line, pos, 1) == "\"" && empty_value_tail(line, pos + 1, n)) {
            pending_oauth_empty_quoted_value=0
            next
          }
          found=1
          next
        }
        if (pending_oauth_value) {
          if (line ~ /^[[:space:]]*$/) {
            if (pending_oauth_block_scalar && pending_oauth_block_preserves_blank) found=1
            next
          }
          if (!pending_oauth_block_scalar && line ~ /^[[:space:]]*#/) next
          if (pending_oauth_value_tag_only && (indent > pending_oauth_indent || pending_oauth_flow_value)) {
            if (value_tag_only(line, 1, n)) {
              if (value_tag_only_explicit_string) pending_oauth_value_explicit_string=1
              next
            }
            if (empty_quoted_value_continues(line, 1, n)) {
              pending_oauth_empty_quoted_value=1
              pending_oauth_value=0
              next
            }
            if (value_present(line, 1, n, pending_oauth_value_explicit_string)) {
              found=1
              next
            }
            pending_oauth_value=0
            pending_oauth_value_tag_only=0
            pending_oauth_value_explicit_string=0
            next
          } else if (pending_oauth_flow_value) {
            pos=value_position(line, 1, n)
            if (value_present(line, pos, n)) {
              found=1
              next
            }
          } else if (indent > pending_oauth_indent) {
            found=1
            next
          }
          pending_oauth_value=0
          pending_oauth_block_scalar=0
          pending_oauth_block_preserves_blank=0
          pending_oauth_flow_value=0
          pending_oauth_value_tag_only=0
          pending_oauth_value_explicit_string=0
        }
        if (in_explicit_quoted_key) {
          pos=value_position(line, 1, n)
          while (pos <= n) {
            c=substr(line, pos, 1)
            if (c == "\\") {
              escape=substr(line, pos + 1, 1)
              if (escape == "u") {
                explicit_quoted_key_token=explicit_quoted_key_token decode_ascii_hex(substr(line, pos + 2, 4), 4)
                pos+=6
                continue
              }
              if (escape == "x") {
                explicit_quoted_key_token=explicit_quoted_key_token decode_ascii_hex(substr(line, pos + 2, 2), 2)
                pos+=4
                continue
              }
              if (escape == "U") {
                explicit_quoted_key_token=explicit_quoted_key_token decode_ascii_hex(substr(line, pos + 2, 8), 8)
                pos+=10
                continue
              }
              if (pos < n) {
                explicit_quoted_key_token=explicit_quoted_key_token decode_simple_yaml_escape(escape)
                pos+=2
                continue
              }
              pos=n + 1
              break
            }
            if (c == "\"") {
              in_explicit_quoted_key=0
              pos++
              break
            }
            explicit_quoted_key_token=explicit_quoted_key_token c
            pos++
          }
          if (in_explicit_quoted_key) next
          j=pos
          while (j <= n && substr(line, j, 1) ~ /[[:space:]]/) j++
          if (explicit_quoted_key_token == "oauth_token" && substr(line, j, 1) == ":") {
            if (empty_quoted_value_continues(line, j + 1, n)) {
              pending_oauth_empty_quoted_value=1
              next
            }
            if (value_present(line, j + 1, n)) {
              found=1
              next
            }
            pending_oauth_value=1
            pending_oauth_indent=explicit_quoted_key_mapping_indent
            pending_oauth_flow_value=flow_depth > 0
            pending_oauth_value_tag_only=value_tag_only(line, j + 1, n)
            pending_oauth_value_explicit_string=value_tag_only_explicit_string
            pending_oauth_block_scalar=block_scalar_value(line, j + 1, n)
            pending_oauth_block_preserves_blank=pending_oauth_block_scalar && block_scalar_keeps_blank(line, j + 1, n)
            next
          }
          if (explicit_quoted_key_token == "oauth_token" && (j > n || substr(line, j, 1) == "#")) {
            pending_explicit_oauth_key=1
            pending_explicit_oauth_indent=explicit_quoted_key_mapping_indent
          }
          next
        }
        if (in_explicit_key_scalar) {
          if (line ~ /^[[:space:]]*$/) {
            if (!explicit_key_scalar_seen) explicit_key_scalar_exact=0
            next
          }
          if (indent > explicit_key_scalar_parent_indent) {
            if (explicit_key_scalar_content_indent < 0) {
              if (explicit_key_scalar_indent_indicator > 0) {
                explicit_key_scalar_content_indent=explicit_key_scalar_parent_indent + explicit_key_scalar_indent_indicator
              } else {
                explicit_key_scalar_content_indent=indent
              }
            }
            if (indent < explicit_key_scalar_content_indent) {
              explicit_key_scalar_exact=0
              next
            }
            scalar_line=substr(line, explicit_key_scalar_content_indent + 1)
            if (!explicit_key_scalar_seen) {
              explicit_key_scalar_seen=1
              if (scalar_line != "oauth_token") explicit_key_scalar_exact=0
            } else {
              explicit_key_scalar_exact=0
            }
            next
          }
          in_explicit_key_scalar=0
          if (explicit_key_scalar_chomp == "-" && explicit_key_scalar_seen && explicit_key_scalar_exact) {
            pending_explicit_oauth_key=1
            pending_explicit_oauth_indent=explicit_key_scalar_mapping_indent
          }
        }
        if (in_block_scalar) {
          if (line ~ /^[[:space:]]*$/) next
          if (indent > block_indent) next
          in_block_scalar=0
        }
        if (pending_explicit_oauth_key) {
          if (line ~ /^[[:space:]]*$/ || line ~ /^[[:space:]]*#/) next
          pos=value_position(line, 1, n)
          if (indent == pending_explicit_oauth_indent && substr(line, pos, 1) == ":") {
            if (value_present(line, pos + 1, n)) {
              found=1
              next
            }
            if (value_deferred(line, pos + 1, n)) {
              pending_oauth_value=1
              pending_oauth_indent=indent
              pending_oauth_flow_value=flow_depth > 0
              pending_oauth_value_tag_only=value_tag_only(line, pos + 1, n)
              pending_oauth_value_explicit_string=value_tag_only_explicit_string
              pending_oauth_block_scalar=block_scalar_value(line, pos + 1, n)
              pending_oauth_block_preserves_blank=pending_oauth_block_scalar && block_scalar_keeps_blank(line, pos + 1, n)
              next
            }
          }
          pending_explicit_oauth_key=0
        }
        explicit_key=0
        explicit_key_indent=indent
        if (pending_explicit_key_node) {
          if (line ~ /^[[:space:]]*$/ || line ~ /^[[:space:]]*#/) next
          if (indent > pending_explicit_key_indent || (flow_depth > 0 && indent == pending_explicit_key_indent)) {
            explicit_key=1
            explicit_key_indent=pending_explicit_key_indent
          }
          pending_explicit_key_node=0
        }
        i=1
        previous=""
        while (i <= n) {
          c=substr(line, i, 1)
          if (c ~ /[[:space:]]/) { i++; continue }
          if (c == "#") break
          if (c == "{" || c == "[" || c == ",") {
            if (c == "{" || c == "[") flow_depth++
            previous=c
            explicit_key=0
            i++
            continue
          }
          if (c == "}" || c == "]") {
            if (flow_depth > 0) flow_depth--
            previous=c
            explicit_key=0
            i++
            continue
          }
          entry=(previous == "" || previous == "{" || previous == "[" || previous == ",")
          if (entry && c == "?") {
            explicit_key=1
            explicit_key_indent=indent
            j=i + 1
            while (j <= n && substr(line, j, 1) ~ /[[:space:]]/) j++
            if (j > n || substr(line, j, 1) == "#") {
              pending_explicit_key_node=1
              pending_explicit_key_indent=indent
              break
            }
            i++
            continue
          }
          if (entry && c == "!") {
            i++
            if (substr(line, i, 1) == "<") {
              i++
              while (i <= n && substr(line, i, 1) != ">") i++
              if (i <= n) i++
            } else {
              while (i <= n && substr(line, i, 1) !~ /[[:space:]{}\[\],]/) i++
            }
            j=i
            while (j <= n && substr(line, j, 1) ~ /[[:space:]]/) j++
            if (explicit_key && (j > n || substr(line, j, 1) == "#")) {
              pending_explicit_key_node=1
              pending_explicit_key_indent=explicit_key_indent
              break
            }
            i=j
            continue
          }
          if (entry && c == "&") {
            i++
            while (i <= n && substr(line, i, 1) !~ /[[:space:]{}\[\],]/) i++
            j=i
            while (j <= n && substr(line, j, 1) ~ /[[:space:]]/) j++
            if (explicit_key && (j > n || substr(line, j, 1) == "#")) {
              pending_explicit_key_node=1
              pending_explicit_key_indent=explicit_key_indent
              break
            }
            i=j
            continue
          }
          if (entry && c == "-") {
            j=i + 1
            while (j <= n && substr(line, j, 1) ~ /[[:space:]]/) j++
            if (block_scalar_value(line, j, n)) {
              in_block_scalar=1
              block_indent=indent
              break
            }
          }
          if (entry && !explicit_key && block_scalar_value(line, i, n)) {
            in_block_scalar=1
            block_indent=indent
            break
          }
          if (entry && explicit_key && block_scalar_value(line, i, n)) {
            in_explicit_key_scalar=1
            explicit_key_scalar_parent_indent=indent
            explicit_key_scalar_mapping_indent=explicit_key_indent
            explicit_key_scalar_content_indent=-1
            explicit_key_scalar_indent_indicator=0
            explicit_key_scalar_chomp=""
            explicit_key_scalar_seen=0
            explicit_key_scalar_exact=1
            k=i + 1
            while (k <= n) {
              header_char=substr(line, k, 1)
              if (header_char == "+" || header_char == "-") {
                explicit_key_scalar_chomp=header_char
              } else if (header_char ~ /[1-9]/) {
                explicit_key_scalar_indent_indicator=header_char + 0
              } else if (header_char ~ /[[:space:]]/ || header_char == "#") {
                break
              }
              k++
            }
            break
          }
          token=""
          if (c == "\"" || c == sq) {
            quote=c
            i++
            while (i <= n) {
              c=substr(line, i, 1)
              if (quote == "\"" && c == "\\") {
                escape=substr(line, i + 1, 1)
                if (escape == "u") {
                  token=token decode_ascii_hex(substr(line, i + 2, 4), 4)
                  i+=6
                  continue
                }
                if (escape == "x") {
                  token=token decode_ascii_hex(substr(line, i + 2, 2), 2)
                  i+=4
                  continue
                }
                if (escape == "U") {
                  token=token decode_ascii_hex(substr(line, i + 2, 8), 8)
                  i+=10
                  continue
                }
                if (i < n) { token=token decode_simple_yaml_escape(escape); i+=2; continue }
                if (entry && explicit_key) {
                  in_explicit_quoted_key=1
                  explicit_quoted_key_token=token
                  explicit_quoted_key_mapping_indent=explicit_key_indent
                  i=n + 1
                  break
                }
              }
              if (c == quote) {
                if (quote == sq && substr(line, i + 1, 1) == sq) {
                  token=token sq
                  i+=2
                  continue
                }
                i++
                break
              }
              token=token c
              i++
            }
            if (in_explicit_quoted_key) break
            j=i
            while (j <= n && substr(line, j, 1) ~ /[[:space:]]/) j++
            if (entry && token == "oauth_token" && substr(line, j, 1) == ":") {
              if (empty_quoted_value_continues(line, j + 1, n)) {
                pending_oauth_empty_quoted_value=1
                break
              }
              if (value_present(line, j + 1, n)) {
                found=1
                break
              }
              if (value_deferred(line, j + 1, n)) {
                pending_oauth_value=1
                pending_oauth_indent=indent
                pending_oauth_flow_value=flow_depth > 0
                pending_oauth_value_tag_only=value_tag_only(line, j + 1, n)
                pending_oauth_value_explicit_string=value_tag_only_explicit_string
                pending_oauth_block_scalar=block_scalar_value(line, j + 1, n)
                pending_oauth_block_preserves_blank=pending_oauth_block_scalar && block_scalar_keeps_blank(line, j + 1, n)
                break
              }
            }
            if (entry && explicit_key && token == "oauth_token" && (j > n || substr(line, j, 1) == "#")) {
              pending_explicit_oauth_key=1
              pending_explicit_oauth_indent=explicit_key_indent
              break
            }
            if (substr(line, j, 1) == ":") {
              if (block_scalar_value(line, j + 1, n)) {
                in_block_scalar=1
                block_indent=indent
                break
              }
              previous=":"
              i=j + 1
            } else {
              i=j
            }
            continue
          }
          if (entry && c ~ /[A-Za-z0-9_.-]/) {
            start=i
            while (i <= n && substr(line, i, 1) ~ /[A-Za-z0-9_.-]/) i++
            token=substr(line, start, i - start)
            j=i
            while (j <= n && substr(line, j, 1) ~ /[[:space:]]/) j++
            if (token == "oauth_token" && substr(line, j, 1) == ":") {
              if (empty_quoted_value_continues(line, j + 1, n)) {
                pending_oauth_empty_quoted_value=1
                break
              }
              if (value_present(line, j + 1, n)) {
                found=1
                break
              }
              if (value_deferred(line, j + 1, n)) {
                pending_oauth_value=1
                pending_oauth_indent=indent
                pending_oauth_flow_value=flow_depth > 0
                pending_oauth_value_tag_only=value_tag_only(line, j + 1, n)
                pending_oauth_value_explicit_string=value_tag_only_explicit_string
                pending_oauth_block_scalar=block_scalar_value(line, j + 1, n)
                pending_oauth_block_preserves_blank=pending_oauth_block_scalar && block_scalar_keeps_blank(line, j + 1, n)
                break
              }
            }
            if (entry && explicit_key && token == "oauth_token" && (j > n || substr(line, j, 1) == "#")) {
              pending_explicit_oauth_key=1
              pending_explicit_oauth_indent=explicit_key_indent
              break
            }
            if (substr(line, j, 1) == ":") {
              if (block_scalar_value(line, j + 1, n)) {
                in_block_scalar=1
                block_indent=indent
                break
              }
              previous=":"
              i=j + 1
            } else {
              previous="x"
              i=j
            }
            continue
          }
          i++
        }
      }
      END { exit(found ? 0 : 1) }
    ' "$config_file"; then
    log_error "GitHub CLI has a plaintext token in its configuration. Remove it with gh auth logout and configure a secure OS credential backend before retrying."
    return 1
  fi
}

verify_secure_gh_credential_backend() {
  local probe_service probe_value='stage0-credential-backend-probe' probe_readback
  command -v secret-tool >/dev/null 2>&1 || { log_error "Secure credential backend probe requires secret-tool."; return 1; }
  probe_service="yhsm-stage0-probe-${EUID}-$$"
  if ! printf '%s' "$probe_value" | secret-tool store --label='YHSM Stage-0 credential-backend probe' service "$probe_service" account probe >/dev/null 2>&1; then
    log_error "No usable system credential store is available; GitHub authentication is blocked to prevent plaintext-token fallback."
    return 1
  fi
  probe_readback="$(secret-tool lookup service "$probe_service" account probe 2>/dev/null || true)"
  secret-tool clear service "$probe_service" account probe >/dev/null 2>&1 || true
  [[ "$probe_readback" == "$probe_value" ]] || {
    log_error "System credential store failed its write/read/clear probe; GitHub authentication is blocked."
    return 1
  }
  log_ok "Secure GitHub credential-backend contract verified."
}

restore_gh_config_snapshot() {
  local config_file="$1" backup_file="$2" existed="$3"
  if [[ "$existed" -eq 1 ]]; then
    mkdir -p "$(dirname -- "$config_file")"
    install -m 0600 "$backup_file" "$config_file"
  else
    rm -f -- "$config_file"
  fi
}

run_gh_device_login_fail_closed() {
  local config_file config_dir snapshot_dir backup_file existed=0
  config_file="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}/hosts.yml"
  config_dir="$(dirname -- "$config_file")"
  snapshot_dir="$(mktemp -d)"
  chmod 0700 "$snapshot_dir"
  backup_file="$snapshot_dir/hosts.yml.before"
  if [[ -f "$config_file" ]]; then
    cp -- "$config_file" "$backup_file"
    chmod 0600 "$backup_file"
    existed=1
  fi
  mkdir -p "$config_dir"
  if ! gh auth login --hostname github.com --git-protocol https --web; then
    restore_gh_config_snapshot "$config_file" "$backup_file" "$existed"
    rm -rf -- "$snapshot_dir"
    log_error "GitHub device/web authentication failed; the previous gh configuration was restored."
    return 1
  fi
  if ! reject_plaintext_gh_credentials; then
    restore_gh_config_snapshot "$config_file" "$backup_file" "$existed"
    rm -rf -- "$snapshot_dir"
    log_error "GitHub CLI plaintext fallback was removed and the previous gh configuration was restored."
    return 1
  fi
  rm -rf -- "$snapshot_dir"
}

if [[ "$TARGET_VISIBILITY" == "private" ]]; then
  install_gh
  verify_secure_gh_credential_backend
  reject_plaintext_gh_credentials
  if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    log_info "GitHub authentication required for the private customer repository."
    log_info "Complete the one-time device/web flow shown by GitHub CLI."
    run_gh_device_login_fail_closed
  else
    log_ok "GitHub authentication already present."
  fi
  reject_plaintext_gh_credentials
  gh auth setup-git --hostname github.com
  gh repo view "$TARGET_REPO" --json nameWithOwner,visibility,defaultBranchRef >/dev/null || {
    log_error "Authenticated GitHub account cannot access the target repository."; exit 1
  }
  gh issue list --repo "$TARGET_REPO" --limit 1 >/dev/null || {
    log_error "Authenticated GitHub account cannot read issues in the target repository."; exit 1
  }
  log_ok "Private repository and issue read access verified."
fi

validate_initialized_submodules() {
  local repo_path="$1" submodule_output
  if ! submodule_output="$(
    git -c core.hooksPath=/dev/null -C "$repo_path" submodule foreach --quiet --recursive '
      submodule_replace_refs="$(git for-each-ref --format="%(refname)" refs/replace/)" || {
        printf "%s\n" STAGE0_SUBMODULE_INSPECTION_FAILED
        exit 93
      }
      if test -n "$submodule_replace_refs"; then
        printf "%s\n" STAGE0_SUBMODULE_REPLACE_REF
        exit 94
      fi
      submodule_index="$(git -c core.fsmonitor=false ls-files -v)" || {
        printf "%s\n" STAGE0_SUBMODULE_INSPECTION_FAILED
        exit 93
      }
      printf "%s\n" "$submodule_index" | grep -Eq "^[a-zS]"
      grep_rc=$?
      if test "$grep_rc" -eq 0; then
        printf "%s\n" STAGE0_SUBMODULE_HIDDEN_INDEX
        exit 91
      elif test "$grep_rc" -ne 1; then
        printf "%s\n" STAGE0_SUBMODULE_INSPECTION_FAILED
        exit 93
      fi
      submodule_status="$(git -c core.fsmonitor=false status --porcelain --untracked-files=all --ignore-submodules=none)" || {
        printf "%s\n" STAGE0_SUBMODULE_INSPECTION_FAILED
        exit 93
      }
      if test -n "$submodule_status"; then
        printf "%s\n" STAGE0_SUBMODULE_DIRTY
        exit 92
      fi
    ' 2>&1
  )"; then
    if [[ "$submodule_output" == *"STAGE0_SUBMODULE_REPLACE_REF"* ]]; then
      log_error "An initialized submodule has Git replacement refs; refusing canonical onboarding readback."
    elif [[ "$submodule_output" == *"STAGE0_SUBMODULE_HIDDEN_INDEX"* ]]; then
      log_error "An initialized submodule has hidden index flags; refusing canonical onboarding readback."
    elif [[ "$submodule_output" == *"STAGE0_SUBMODULE_DIRTY"* ]]; then
      log_error "An initialized submodule is not clean; refusing canonical onboarding readback."
    elif [[ "$submodule_output" == *"STAGE0_SUBMODULE_INSPECTION_FAILED"* ]]; then
      log_error "Unable to inspect an initialized submodule; refusing canonical onboarding readback."
    else
      log_error "Unable to verify initialized submodule state; refusing canonical onboarding readback."
    fi
    return 1
  fi
}

mkdir -p "$WORKDIR"
if [[ -e "$dest_path" && ! -d "$dest_path/.git" ]]; then
  log_error "Clone destination exists but is not a Git repository."; exit 1
fi

remote_ref="refs/remotes/origin/$TARGET_BRANCH"

if [[ -d "$dest_path/.git" ]]; then
  actual_remote="$(git -C "$dest_path" remote get-url origin 2>/dev/null || true)"
  case "$actual_remote" in
    "$clone_url"|"https://github.com/$TARGET_REPO") ;;
    *) log_error "Existing clone has an unexpected origin remote."; exit 1 ;;
  esac
  reject_existing_clone_execution_config "$dest_path" || exit 1
  if [[ -n "$(git -C "$dest_path" for-each-ref --format='%(refname)' refs/replace/)" ]]; then
    log_error "Existing clone has Git replacement refs; refusing canonical onboarding readback."
    exit 1
  fi
  if git -c core.fsmonitor=false -C "$dest_path" ls-files -v | grep -Eq '^[a-zS]'; then
    log_error "Existing clone has hidden index flags (assume-unchanged or skip-worktree); refusing canonical onboarding readback."
    exit 1
  fi
  if ! repository_status="$(git -c core.fsmonitor=false -C "$dest_path" status --porcelain --untracked-files=all --ignore-submodules=none)"; then
    log_error "Unable to inspect existing clone cleanliness; refusing to modify or report it as canonical."
    exit 1
  fi
  if [[ -n "$repository_status" ]]; then
    log_error "Existing clone is not clean; refusing to modify or report it as canonical."
    exit 1
  fi
  validate_initialized_submodules "$dest_path" || exit 1
  log_info "Existing clean clone found; fetching exact remote branch."
  git -C "$dest_path" fetch origin "+refs/heads/$TARGET_BRANCH:refs/remotes/origin/$TARGET_BRANCH" --quiet
  remote_head="$(git -C "$dest_path" rev-parse "$remote_ref")"
  ignored_collision=0
  while IFS= read -r -d '' ignored_path; do
    if git -C "$dest_path" cat-file -e "$remote_head:$ignored_path" 2>/dev/null; then
      ignored_collision=1
      break
    fi
  done < <(git -c core.fsmonitor=false -C "$dest_path" ls-files --others --ignored --exclude-standard -z)
  if [[ "$ignored_collision" -eq 1 ]]; then
    log_error "Existing clone has an ignored local file that collides with the selected remote branch; refusing to overwrite local state."
    exit 1
  fi
  if git -C "$dest_path" show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
    git -c core.hooksPath=/dev/null -C "$dest_path" checkout --no-overwrite-ignore "$TARGET_BRANCH" --quiet
  else
    git -c core.hooksPath=/dev/null -C "$dest_path" checkout --no-overwrite-ignore -b "$TARGET_BRANCH" "$remote_head" --quiet
    git -C "$dest_path" config "branch.$TARGET_BRANCH.remote" origin
    git -C "$dest_path" config "branch.$TARGET_BRANCH.merge" "refs/heads/$TARGET_BRANCH"
  fi
  local_head="$(git -C "$dest_path" rev-parse HEAD)"
  if [[ "$local_head" != "$remote_head" ]]; then
    if git -C "$dest_path" merge-base --is-ancestor "$local_head" "$remote_head"; then
      git -c core.hooksPath=/dev/null -C "$dest_path" merge --ff-only "$remote_head" --quiet
    else
      log_error "Existing clone does not exactly match origin/$TARGET_BRANCH and cannot be safely fast-forwarded."
      exit 1
    fi
  fi
  [[ "$(git -C "$dest_path" rev-parse HEAD)" == "$(git -C "$dest_path" rev-parse "$remote_ref")" ]] || {
    log_error "Existing clone is not exact to the fetched remote branch."
    exit 1
  }
  if ! repository_status="$(git -c core.fsmonitor=false -C "$dest_path" status --porcelain --untracked-files=all --ignore-submodules=none)"; then
    log_error "Unable to inspect clone cleanliness after branch synchronization; refusing canonical onboarding readback."
    exit 1
  fi
  if [[ -n "$repository_status" ]]; then
    log_error "Existing clone became dirty while switching to the selected remote branch; refusing canonical onboarding readback."
    exit 1
  fi
  validate_initialized_submodules "$dest_path" || exit 1
else
  log_info "Cloning customer repository."
  git -c core.hooksPath=/dev/null clone --branch "$TARGET_BRANCH" --single-branch "$clone_url" "$dest_path"
fi

if git -c core.fsmonitor=false -C "$dest_path" ls-files -v | grep -Eq '^[a-zS]'; then
  log_error "Clone has hidden index flags (assume-unchanged or skip-worktree); refusing canonical onboarding readback."
  exit 1
fi
if [[ -n "$(git -C "$dest_path" for-each-ref --format='%(refname)' refs/replace/)" ]]; then
  log_error "Clone has Git replacement refs; refusing canonical onboarding readback."
  exit 1
fi
if ! repository_status="$(git -c core.fsmonitor=false -C "$dest_path" status --porcelain --untracked-files=all --ignore-submodules=none)"; then
  log_error "Unable to inspect final clone cleanliness; refusing canonical onboarding readback."
  exit 1
fi
if [[ -n "$repository_status" ]]; then
  log_error "Clone is dirty after checkout; refusing canonical onboarding readback."
  exit 1
fi
validate_initialized_submodules "$dest_path" || exit 1

git -C "$dest_path" show-ref --verify --quiet "$remote_ref" || {
  log_error "Clone did not produce the requested remote branch; tags cannot satisfy --target-branch."
  exit 1
}
repo_head="$(git -C "$dest_path" rev-parse HEAD)"
repo_branch="$(git -C "$dest_path" branch --show-current)"
remote_head="$(git -C "$dest_path" rev-parse "$remote_ref")"
[[ "$repo_branch" == "$TARGET_BRANCH" ]] || {
  log_error "Clone is not checked out on the requested branch."
  exit 1
}
[[ "$repo_head" == "$remote_head" ]] || {
  log_error "Clone head is not exact to the requested remote branch."
  exit 1
}
repo_remote="$(git -C "$dest_path" remote get-url origin)"
case "$repo_remote" in
  "$clone_url"|"https://github.com/$TARGET_REPO") ;;
  *) log_error "Clone origin changed during checkout; refusing canonical onboarding readback."; exit 1 ;;
esac
server_ref="refs/heads/$TARGET_BRANCH"
server_ref_line="$(git ls-remote --exit-code "$clone_url" "$server_ref")" || {
  log_error "Unable to query the selected branch from the GitHub server for final canonical readback."
  exit 1
}
if [[ "$server_ref_line" == *$'\n'* ]]; then
  log_error "GitHub server returned an ambiguous branch ref during final canonical readback."
  exit 1
fi
IFS=$'\t' read -r server_head server_ref_name <<< "$server_ref_line"
[[ -n "$server_head" && "$server_ref_name" == "$server_ref" && "$repo_head" == "$server_head" ]] || {
  log_error "Clone head is not exact to the freshly queried GitHub server branch."
  exit 1
}

printf '%s\n' '--- STAGE-0 READBACK ---'
printf 'repository=%s\n' "$TARGET_REPO"
printf 'branch=%s\n' "$repo_branch"
printf 'head=%s\n' "$repo_head"
printf 'remote=%s\n' "$repo_remote"
printf 'path=%s\n' "$dest_path"

if [[ -f "$dest_path/client/README.md" ]]; then log_ok "Customer client package found."; else log_warn "Target repository has no client/README.md; verify the selected channel."; fi

cleanup_issue_smoke_test() {
  if [[ -z "$SMOKE_ISSUE_REPO" || -z "$SMOKE_ISSUE_NUMBER" ]]; then return 0; fi
  gh issue close "$SMOKE_ISSUE_NUMBER" --repo "$SMOKE_ISSUE_REPO" --comment 'Stage-0 cleanup closed the temporary smoke-test issue after an interrupted verification.' >/dev/null 2>&1 || true
}

run_issue_smoke_test() {
  local issue_url issue_number
  log_info "Creating sanitized temporary support-channel smoke-test issue."
  issue_url="$(gh issue create --repo "$TARGET_REPO" --title '[pilot-smoke] Stage-0 issue channel verification' --body 'Automated Stage-0 support-channel smoke test. No customer evidence, credentials, secrets, keys, tokens or authorization data included.')"
  issue_number="${issue_url##*/}"
  [[ "$issue_number" =~ ^[0-9]+$ ]] || { log_error "Issue smoke test created an unparseable issue reference."; return 1; }
  SMOKE_ISSUE_REPO="$TARGET_REPO"
  SMOKE_ISSUE_NUMBER="$issue_number"
  trap cleanup_issue_smoke_test EXIT
  log_info "IssueSmokeTestIssue=$issue_number"
  gh issue comment "$issue_number" --repo "$TARGET_REPO" --body 'Stage-0 issue comment path verified.' >/dev/null
  gh issue view "$issue_number" --repo "$TARGET_REPO" --json number,state,title >/dev/null
  gh issue close "$issue_number" --repo "$TARGET_REPO" --comment 'Stage-0 issue-channel smoke test completed successfully; no product incident.' >/dev/null
  SMOKE_ISSUE_REPO=""
  SMOKE_ISSUE_NUMBER=""
  trap - EXIT
  log_ok "IssueSmokeTest=PASS issue=$issue_number"
}

if [[ "$ISSUE_SMOKE_TEST" -eq 1 ]]; then run_issue_smoke_test; fi

log_info "Next: read the cloned customer documentation and follow only documented preflight/install steps."
log_ok "Stage-0 onboarding complete."
