#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TARGET_BRANCH="main"
DEFAULT_WORKDIR="${HOME}/git"
GH_KEYRING_URL="https://cli.github.com/packages/githubcli-archive-keyring.gpg"
GH_KEYRING_SHA256="6084d5d7bd8e288441e0e94fc6275570895da18e6751f70f057485dc2d1a811b"
ACCOUNT_CHANNEL_MAP="/etc/yhsm/stage0-account-channels"

TARGET_REPO=""
RELEASE_CHANNEL=""
LAB_MODE=""
TARGET_RESOLUTION=""
TARGET_BRANCH="$DEFAULT_TARGET_BRANCH"
WORKDIR="$DEFAULT_WORKDIR"
TARGET_VISIBILITY="private"
DRY_RUN=0
ISSUE_SMOKE_TEST=0
SMOKE_ISSUE_REPO=""
SMOKE_ISSUE_NUMBER=""
SESSION_AUTH_ACTIVE=0
SESSION_ROOT=""
SESSION_PARENT=""
SESSION_HANDOFF_FILE=""
SESSION_HANDOFF_ACTIVE=0
HANDOFF_REAPER_PID=""
HANDOFF_PUBLISHING=0
# Compatibility markers for the Stage-0 handoff candidate contract.
STAGE0_HANDOFF_CANDIDATE_FILE=""
STAGE0_HANDOFF_CANDIDATE_ROOT=""
CLEANUP_ACTIVE=0
ORIGINAL_HOME=""
ORIGINAL_XDG_CONFIG_HOME_SET=0
ORIGINAL_XDG_CONFIG_HOME=""
ORIGINAL_GH_CONFIG_DIR_SET=0
ORIGINAL_GH_CONFIG_DIR=""
NORMAL_GH_CONFIG_FILE=""
NORMAL_GH_CONFIG_EXISTED=0
NORMAL_GH_CONFIG_SHA256=""
NORMAL_GIT_CONFIG_FILE=""
NORMAL_GIT_CONFIG_EXISTED=0
NORMAL_GIT_CONFIG_SHA256=""
NORMAL_XDG_GIT_CONFIG_FILE=""
NORMAL_XDG_GIT_CONFIG_EXISTED=0
NORMAL_XDG_GIT_CONFIG_SHA256=""
ACTIVE_CHILD_PID=""
PENDING_SIGNAL_STATUS=0
PENDING_SIGNAL_NAME=""
SIGNAL_DEFER_EXIT=0
ACTIVE_CHILD_SIGNAL_DEFER=0
ACTIVE_CHILD_SIGNAL_GROUP=0
IGNORED_PATHS_RECORD=""

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

valid_target_repo() {
  local repo="$1" owner name
  [[ "$repo" == */* && "$repo" != */*/* ]] || return 1
  owner="${repo%%/*}"
  name="${repo##*/}"
  [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,38}$ ]] || return 1
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]] || return 1
  [[ "$owner" != *..* && "$name" != *..* ]] || return 1
}

canonical_target_repo() {
  local repo="$1" require_canonical_url="${2:-0}"
  if [[ "$repo" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9.-]{0,38})/([A-Za-z0-9][A-Za-z0-9._-]{0,99})$ ]]; then
    repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  elif [[ "$require_canonical_url" -eq 1 ]]; then
    return 1
  fi
  valid_target_repo "$repo" || return 1
  printf '%s\n' "$repo"
}
valid_release_channel() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

parse_channel_binding() {
  local payload="$1" expected_account="${2:-}" require_canonical_url="${3:-0}" token key value
  local repo="" release_channel="" lab_mode="" account="" seen_keys=""
  local semicolon_mode=0
  local -a tokens=()

  [[ -n "$payload" && "$payload" != *$'\n'* && "$payload" != *$'\r'* ]] || return 1
  if [[ "$payload" == *';'* ]]; then
    semicolon_mode=1
    [[ "$payload" == *';' ]] || return 1
    payload="${payload%;}"
    [[ -n "$payload" && "$payload" != *';;'* ]] || return 1
    IFS=';' read -r -a tokens <<<"$payload"
  else
    read -r -a tokens <<<"$payload"
  fi
  [[ "${#tokens[@]}" -ge 3 ]] || return 1
  for token in "${tokens[@]}"; do
    [[ "$token" == *=* ]] || return 1
    if [[ "$semicolon_mode" -eq 1 ]]; then
      [[ "$token" != *[[:space:]]* ]] || return 1
    fi
    key="${token%%=*}"
    value="${token#*=}"
    [[ -n "$value" && "$value" != *=* && "$value" != *';'* ]] || return 1
    case " $seen_keys " in
      *" $key "*) return 1 ;;
    esac
    seen_keys+=" $key"
    case "$key" in
      schema)
        [[ "$semicolon_mode" -eq 1 && "$value" == 1 ]] || return 1
        ;;
      base|tenant|connector|ad_publish_host|ca_uca|ca_mca|ca_sca|secrets_backend)
        [[ "$semicolon_mode" -eq 1 ]] || return 1
        ;;
      repo)
        repo="$(canonical_target_repo "$value" "$require_canonical_url")" || return 1
        ;;
      release_channel)
        release_channel="$value"
        ;;
      lab_mode)
        lab_mode="$value"
        ;;
      account)
        [[ -n "$expected_account" ]] || return 1
        account="$value"
        ;;
      *) return 1 ;;
    esac
  done
  if [[ "$semicolon_mode" -eq 1 ]]; then
    [[ " $seen_keys " == *" schema "* ]] || return 1
  fi
  [[ -n "$repo" && -n "$release_channel" && -n "$lab_mode" ]] || return 1
  if [[ -n "$expected_account" ]]; then
    [[ -n "$account" && "$account" == "$expected_account" ]] || return 1
  else
    [[ -z "$account" ]] || return 1
  fi
  valid_target_repo "$repo" || return 1
  valid_release_channel "$release_channel" || return 1
  [[ "$lab_mode" == 0 || "$lab_mode" == 1 ]] || return 1
  printf '%s\t%s\t%s\n' "$repo" "$release_channel" "$lab_mode"
}
resolve_dns_search_domain() {
  local resolv_conf="$1" line domain="" candidate
  [[ -r "$resolv_conf" ]] || return 1
  while IFS= read -r line; do
    line="${line%%#*}"
    read -r -a fields <<<"$line"
    [[ "${#fields[@]}" -gt 0 ]] || continue
    case "${fields[0]}" in
      search)
        [[ "${#fields[@]}" -eq 2 ]] || return 1
        candidate="${fields[1]%.}"
        if [[ -n "$domain" && "$candidate" != "$domain" ]]; then return 1; fi
        domain="$candidate"
        ;;
      domain)
        [[ "${#fields[@]}" -eq 2 ]] || return 1
        candidate="${fields[1]%.}"
        if [[ -n "$domain" && "$candidate" != "$domain" ]]; then return 1; fi
        domain="$candidate"
        ;;
    esac
  done <"$resolv_conf"
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] || return 1
  printf '%s\n' "${domain,,}"
}

query_dns_txt() {
  local fqdn="$1" raw header dns_status line
  command -v dig >/dev/null 2>&1 || return 3
  raw="$(dig +time=3 +tries=1 +noquestion +nostats +noauthority +noadditional TXT "$fqdn")" || return 3
  header="$(awk '/^;; ->>HEADER<<-/{print; exit}' <<<"$raw")"
  [[ -n "$header" ]] || return 3
  dns_status="$(sed -n 's/.*status: \([^, ]*\).*/\1/p' <<<"$header")"
  case "$dns_status" in
    NOERROR|NXDOMAIN) ;;
    *) return 3 ;;
  esac
  [[ "$dns_status" == NOERROR ]] || return 0
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \;* ]] && continue
    if [[ "$line" =~ ^[^[:space:]]+[[:space:]]+[0-9]+[[:space:]]+IN[[:space:]]+TXT[[:space:]]+(.+)$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    fi
  done <<<"$raw"
}

decode_dns_txt_line() {
  local line="$1" chunk payload=""
  while [[ -n "$line" ]]; do
    [[ "$line" =~ ^\"([A-Za-z0-9._/:=[:space:];+_-]*)\"(.*)$ ]] || return 1
    chunk="${BASH_REMATCH[1]}"
    line="${BASH_REMATCH[2]}"
    payload+="$chunk"
    if [[ -n "$line" ]]; then
      [[ "$line" == ' '* ]] || return 1
      line="${line# }"
      [[ -n "$line" ]] || return 1
    fi
  done
  [[ -n "$payload" ]] || return 1
  printf '%s\n' "$payload"
}

resolve_dns_channel_binding() {
  local domain records line payload binding
  local -a lines=()
  domain="$(resolve_dns_search_domain /etc/resolv.conf)" || return 2
  records="$(query_dns_txt "_pki.$domain")" || return $?
  while IFS= read -r line; do
    [[ -n "$line" ]] && lines+=("$line")
  done <<<"$records"
  [[ "${#lines[@]}" -gt 0 ]] || return 4
  [[ "${#lines[@]}" -eq 1 ]] || return 2
  line="${lines[0]}"
  payload="$(decode_dns_txt_line "$line")" || return 2
  binding="$(parse_channel_binding "$payload" "" 1)" || return 2
  printf '%s\n' "$binding"
}

resolve_account_channel_binding() {
  local map_path="$1" account line binding mode owner
  local -a matches=()
  [[ -e "$map_path" ]] || return 4
  [[ -f "$map_path" && ! -L "$map_path" ]] || return 2
  owner="$(stat -c '%u' -- "$map_path")" || return 2
  mode="$(stat -c '%a' -- "$map_path")" || return 2
  [[ "$owner" == 0 || "$owner" == "$EUID" ]] || return 2
  [[ "$mode" =~ ^[0-7][0-5][0-5]$ ]] || return 2
  account="$(id -un)" || return 2
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ -n "${line//[[:space:]]/}" ]] || continue
    if binding="$(parse_channel_binding "$line" "$account" 2>/dev/null)"; then
      matches+=("$binding")
    elif [[ "$line" == *"account=$account"* ]]; then
      return 2
    fi
  done <"$map_path"
  [[ "${#matches[@]}" -eq 1 ]] || return 2
  printf '%s\n' "${matches[0]}"
}

apply_channel_binding() {
  local binding="$1"
  IFS=$'\t' read -r TARGET_REPO RELEASE_CHANNEL LAB_MODE <<<"$binding"
  [[ -n "$TARGET_REPO" && -n "$RELEASE_CHANNEL" && -n "$LAB_MODE" ]]
}

require_lab_mode_one() {
  [[ "$LAB_MODE" == 1 ]] || {
    log_error "HARD_FAIL_STAGE0_LAB_MODE_REQUIRED: channel binding must declare lab_mode=1."
    return 1
  }
}

resolve_target_repository() {
  local binding dns_status
  if [[ -n "$TARGET_REPO" ]]; then
    TARGET_RESOLUTION="target-repo-recovery-override"
    RELEASE_CHANNEL="recovery-override"
    LAB_MODE="unknown"
    return 0
  fi
  if binding="$(resolve_dns_channel_binding)"; then
    apply_channel_binding "$binding" || return 1
    require_lab_mode_one || return 1
    TARGET_RESOLUTION="dns"
    return 0
  else
    dns_status=$?
  fi
  if [[ "$dns_status" -ne 4 ]]; then
    log_error "HARD_FAIL_TARGET_REPOSITORY_UNRESOLVED: DNS channel binding is missing, malformed, ambiguous, or unavailable; no account mapping fallback is permitted."
    log_error "Use --target-repo owner/repository only as an explicit recovery override."
    return 1
  fi
  if binding="$(resolve_account_channel_binding "$ACCOUNT_CHANNEL_MAP")"; then
    apply_channel_binding "$binding" || return 1
    require_lab_mode_one || return 1
    TARGET_RESOLUTION="explicit-account-map"
    return 0
  fi
  log_error "HARD_FAIL_TARGET_REPOSITORY_UNRESOLVED: no valid DNS binding or explicit unique account-to-channel mapping is available."
  log_error "Use --target-repo owner/repository only as an explicit recovery override."
  return 1
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
  bash ./bootstrap.sh [options]
  bash ./bootstrap.sh --target-repo <owner/repo> [options]

Examples:
  bash ./bootstrap.sh --dry-run
  bash ./bootstrap.sh
  bash ./bootstrap.sh --private-target --target-repo example-org/pilot-repository

Options:
  --target-repo <owner/repo>   Recovery-only repository override.
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
  - Prefers a working secure system credential store; headless hosts may use a verified RAM-backed session-only GitHub configuration.
  - Uses GitHub device/web authentication without launching a browser on the server; token-bearing GitHub auth environment variables are rejected.
  - Verifies private repository and issue read access, clones the selected branch and prints readback.
  - Optional issue smoke test is explicit and writes only a sanitized temporary GitHub issue.
  - Reads the local DNS search domain and _pki.<domain> TXT binding before GitHub authentication.
  - DNS selects only the customer channel; GitHub Device/Web verifies access to that exact target.
  - Performs no DNS, Connector, HSM, AD, PKI or release mutation.
  - Never enumerates repositories from the authenticated GitHub account.
USAGE
}

print_argv_banner "$@"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-repo)
      [[ $# -ge 2 && "${2:-}" != -* ]] || { log_error "--target-repo requires a repository operand."; exit 2; }
      [[ -z "$TARGET_REPO" ]] || { log_error "Target repository may be specified only once."; exit 2; }
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
    --*)
      log_error "Unknown option (value redacted)."
      usage >&2
      exit 2
      ;;
    *)
      log_error "Unexpected positional operand; use --target-repo owner/repository only for recovery."
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "$TARGET_REPO" ]]; then
  valid_target_repo "$TARGET_REPO" || { log_error "Invalid --target-repo."; exit 2; }
  if sensitive_argv_value "$TARGET_REPO" || sensitive_argv_value "${TARGET_REPO%%/*}" || sensitive_argv_value "${TARGET_REPO##*/}"; then
    log_error "--target-repo contains a sensitive-shaped value and is rejected."
    exit 2
  fi
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

canonical_directory() {
  local path="$1"
  [[ -d "$path" && ! -L "$path" ]] || return 1
  (cd -P -- "$path" 2>/dev/null && pwd -P)
}

read_single_path_record() {
  local path="$1"
  local -a records=()
  [[ -f "$path" && ! -L "$path" ]] || return 1
  mapfile -t records <"$path" || return 1
  [[ "${#records[@]}" -eq 1 && -n "${records[0]}" ]] || return 1
  printf '%s\n' "${records[0]}"
}

resolve_direct_git_config_paths() {
  local repo_path="$1" marker git_dir_record git_dir common_dir_record common_dir
  marker="$repo_path/.git"
  if [[ -d "$marker" && ! -L "$marker" ]]; then
    git_dir="$(canonical_directory "$marker")" || return 1
  elif [[ -f "$marker" && ! -L "$marker" ]]; then
    git_dir_record="$(read_single_path_record "$marker")" || return 1
    [[ "$git_dir_record" == 'gitdir: '* ]] || return 1
    git_dir_record="${git_dir_record#gitdir: }"
    [[ -n "$git_dir_record" && "$git_dir_record" != *$'\n'* ]] || return 1
    if [[ "$git_dir_record" != /* ]]; then git_dir_record="$repo_path/$git_dir_record"; fi
    git_dir="$(canonical_directory "$git_dir_record")" || return 1
  else
    return 1
  fi

  common_dir="$git_dir"
  if [[ -e "$git_dir/commondir" ]]; then
    common_dir_record="$(read_single_path_record "$git_dir/commondir")" || return 1
    [[ -n "$common_dir_record" && "$common_dir_record" != *$'\n'* ]] || return 1
    if [[ "$common_dir_record" != /* ]]; then common_dir_record="$git_dir/$common_dir_record"; fi
    common_dir="$(canonical_directory "$common_dir_record")" || return 1
  fi
  [[ "$common_dir/config" != *$'\n'* && "$git_dir/config.worktree" != *$'\n'* ]] || return 1
  printf '%s\n%s\n' "$common_dir/config" "$git_dir/config.worktree"
}

make_cleanup_scoped_tempfile() {
  if [[ "$SESSION_AUTH_ACTIVE" -eq 1 ]]; then
    [[ -n "$SESSION_ROOT" && -d "$SESSION_ROOT" && ! -L "$SESSION_ROOT" ]] || return 1
    mktemp "$SESSION_ROOT/stage0-inspection.XXXXXX"
    return
  fi
  mktemp
}

reject_direct_include_file() {
  local config_path="$1" required="$2" records errors rc
  if [[ ! -e "$config_path" && "$required" -eq 0 ]]; then return 0; fi
  [[ -f "$config_path" && ! -L "$config_path" ]] || return 1
  records="$(make_cleanup_scoped_tempfile)" || return 1
  errors="$(make_cleanup_scoped_tempfile)" || { rm -f -- "$records"; return 1; }
  if run_git_child_or_propagate_signal config --file "$config_path" --no-includes --null --name-only --get-regexp '^(include\.path|includeif\..*\.path)$' >"$records" 2>"$errors"; then rc=0; else rc=$?; fi
  if [[ "$rc" -eq 0 ]]; then
    rm -f -- "$records" "$errors"
    return 2
  fi
  if [[ "$rc" -ne 1 || -s "$records" || -s "$errors" ]]; then
    rm -f -- "$records" "$errors"
    return 1
  fi
  rm -f -- "$records" "$errors"
}

reject_direct_repo_includes() {
  local repo_path="$1" worktree_enabled rc
  local -a paths=()
  mapfile -t paths < <(resolve_direct_git_config_paths "$repo_path") || return 1
  [[ "${#paths[@]}" -eq 2 ]] || return 1
  local config_path="${paths[0]}" worktree_config="${paths[1]}"

  reject_direct_include_file "$config_path" 1
  rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  worktree_enabled=''
  if capture_git_child_or_propagate_signal worktree_enabled config --file "$config_path" --no-includes --type=bool --get extensions.worktreeConfig 2>/dev/null; then
    [[ "$worktree_enabled" == true || "$worktree_enabled" == false ]] || return 1
  else
    rc=$?
    [[ "$rc" -eq 1 ]] || return 1
    worktree_enabled=false
  fi
  if [[ "$worktree_enabled" == true ]]; then
    reject_direct_include_file "$worktree_config" 0 || return $?
  fi
}

reject_direct_submodule_includes() {
  local repo_path="$1" modules_file records errors rc entry submodule_path nested_repo repo_root nested_root records_fd
  modules_file="$repo_path/.gitmodules"
  [[ -e "$modules_file" ]] || return 0
  [[ -f "$modules_file" && ! -L "$modules_file" ]] || return 1
  records="$(make_cleanup_scoped_tempfile)" || return 1
  errors="$(make_cleanup_scoped_tempfile)" || { rm -f -- "$records"; return 1; }
  if run_git_child_or_propagate_signal config --file "$modules_file" --no-includes --null --get-regexp '^submodule\..*\.path$' >"$records" 2>"$errors"; then rc=0; else rc=$?; fi
  if [[ "$rc" -ne 0 && ( "$rc" -ne 1 || -s "$records" || -s "$errors" ) ]]; then
    rm -f -- "$records" "$errors"
    return 1
  fi
  repo_root="$(canonical_directory "$repo_path")" || { rm -f -- "$records" "$errors"; return 1; }
  if [[ "$rc" -eq 0 ]]; then
    exec {records_fd}<"$records" || { rm -f -- "$records" "$errors"; return 1; }
    while IFS= read -r -d '' entry <&"$records_fd"; do
      [[ "$entry" == *$'\n'* ]] || { exec {records_fd}<&-; rm -f -- "$records" "$errors"; return 1; }
      submodule_path="${entry#*$'\n'}"
      case "$submodule_path" in
        ''|/*|..|../*|*/..|*/../*|*$'\n'*) exec {records_fd}<&-; rm -f -- "$records" "$errors"; return 1 ;;
      esac
      nested_repo="$repo_path/$submodule_path"
      if [[ -L "$nested_repo" ]]; then
        exec {records_fd}<&-
        rm -f -- "$records" "$errors"
        return 3
      fi
      [[ -e "$nested_repo/.git" ]] || continue
      nested_root="$(canonical_directory "$nested_repo")" || { exec {records_fd}<&-; rm -f -- "$records" "$errors"; return 1; }
      if [[ "$nested_root" == "$repo_root" ]]; then
        exec {records_fd}<&-
        rm -f -- "$records" "$errors"
        return 1
      fi
      case "$nested_root/" in "$repo_root/"*) ;; *) exec {records_fd}<&-; rm -f -- "$records" "$errors"; return 1 ;; esac
      reject_direct_repo_includes "$nested_root" || { rc=$?; exec {records_fd}<&-; rm -f -- "$records" "$errors"; return "$rc"; }
      reject_direct_submodule_includes "$nested_root" || { rc=$?; exec {records_fd}<&-; rm -f -- "$records" "$errors"; return "$rc"; }
    done
    exec {records_fd}<&-
  fi
  rm -f -- "$records" "$errors"
}

reject_existing_clone_execution_config() {
  local repo_path="$1" neutral_config config_records config_errors config_rc scope entry submodule_output direct_rc submodule_inspection_root

  neutral_config="$(make_cleanup_scoped_tempfile)" || return 1
  if run_git_child_or_propagate_signal config --file "$neutral_config" --no-includes --show-scope --get-regexp '^$' >/dev/null 2>&1; then
    rm -f -- "$neutral_config"
    log_error "Unable to probe Git configuration capability safely; refusing Stage-0 onboarding."
    return 1
  else
    config_rc=$?
  fi
  rm -f -- "$neutral_config"
  if [[ "$config_rc" -ne 1 ]]; then
    log_error "Git 2.26 or newer is required to inspect an existing clone safely; upgrade Git or use a fresh workdir."
    return 1
  fi

  reject_direct_repo_includes "$repo_path"
  direct_rc=$?
  if [[ "$direct_rc" -ne 0 ]]; then
    if [[ "$direct_rc" -eq 2 ]]; then
      log_error "Existing clone has repository-local or worktree Git include configuration; refusing conditional execution configuration before trust."
    else
      log_error "Unable to inspect Git include configuration directly; refusing Stage-0 onboarding."
    fi
    return 1
  fi
  reject_direct_submodule_includes "$repo_path"
  direct_rc=$?
  if [[ "$direct_rc" -ne 0 ]]; then
    if [[ "$direct_rc" -eq 2 ]]; then
      log_error "An initialized submodule has repository-local or worktree Git include configuration; refusing conditional execution configuration before trust."
    elif [[ "$direct_rc" -eq 3 ]]; then
      log_error "A registered submodule root is a symbolic link; refusing repository-context submodule inspection before trust."
    else
      log_error "Unable to inspect initialized-submodule Git include configuration directly; refusing Stage-0 onboarding."
    fi
    return 1
  fi

  config_records="$(make_cleanup_scoped_tempfile)" || return 1
  config_errors="$(make_cleanup_scoped_tempfile)" || { rm -f -- "$config_records"; return 1; }
  if run_git_child_or_propagate_signal -C "$repo_path" config --null --show-scope --includes --get-regexp '^(filter\..*\.(clean|smudge|process)|credential(\..*)?\.helper|core\.worktree|http\..*|remote\..*\.(proxy|proxyAuthMethod))$' >"$config_records" 2>"$config_errors"; then
    config_rc=0
  else
    config_rc=$?
  fi
  if [[ "$config_rc" -ne 0 && ( "$config_rc" -ne 1 || -s "$config_records" || -s "$config_errors" ) ]]; then
    rm -f -- "$config_records" "$config_errors"
    log_error "Unable to inspect Git execution configuration; refusing Stage-0 onboarding."
    return 1
  fi
  if [[ "$config_rc" -eq 0 ]]; then
    exec 3<"$config_records"
    while true; do
      scope=''
      if IFS= read -r -d '' scope <&3; then
        :
      elif [[ -n "$scope" ]]; then
        exec 3<&-
        rm -f -- "$config_records" "$config_errors"
        log_error "Unable to parse Git execution configuration; refusing Stage-0 onboarding."
        return 1
      else
        break
      fi
      entry=''
      if ! IFS= read -r -d '' entry <&3 || [[ "$entry" != *$'\n'* ]]; then
        exec 3<&-
        rm -f -- "$config_records" "$config_errors"
        log_error "Unable to parse Git execution configuration; refusing Stage-0 onboarding."
        return 1
      fi
      if [[ "$scope" == 'local' || "$scope" == 'worktree' ]]; then
        exec 3<&-
        rm -f -- "$config_records" "$config_errors"
        log_error "Existing clone has repository-local or worktree Git execution configuration or HTTP proxy/TLS override (filter, credential helper, worktree redirection, or transport override); refusing to inspect, authenticate, or update it."
        return 1
      fi
    done
    exec 3<&-
  fi
  rm -f -- "$config_records" "$config_errors"

  submodule_inspection_root=''
  if [[ "$SESSION_AUTH_ACTIVE" -eq 1 ]]; then
    if [[ -z "$SESSION_ROOT" || ! -d "$SESSION_ROOT" || -L "$SESSION_ROOT" ]]; then
      log_error "Unable to bind initialized-submodule inspection files to the protected session root; refusing Stage-0 onboarding."
      return 1
    fi
    submodule_inspection_root="$SESSION_ROOT"
  fi
  STAGE0_SUBMODULE_INSPECTION_ROOT="$submodule_inspection_root"
  export STAGE0_SUBMODULE_INSPECTION_ROOT

  # Nested submodule commands are intentionally literal until executed in the submodule context.
  # shellcheck disable=SC2016
  if ! capture_git_process_group_child_combined_or_propagate_signal submodule_output -c core.hooksPath=/dev/null -C "$repo_path" submodule foreach --quiet --recursive '
      bash -c '\''
        if [[ -n "${STAGE0_SUBMODULE_INSPECTION_ROOT:-}" ]]; then
          if [[ ! -d "$STAGE0_SUBMODULE_INSPECTION_ROOT" || -L "$STAGE0_SUBMODULE_INSPECTION_ROOT" ]]; then
            printf "%s\\n" STAGE0_SUBMODULE_EXECUTION_CONFIG_INSPECTION_FAILED
            exit 93
          fi
          records="$(mktemp "$STAGE0_SUBMODULE_INSPECTION_ROOT/stage0-submodule-inspection.XXXXXX")" || exit 93
          errors="$(mktemp "$STAGE0_SUBMODULE_INSPECTION_ROOT/stage0-submodule-inspection.XXXXXX")" || { rm -f -- "$records"; exit 93; }
        else
          records="$(mktemp)" || exit 93
          errors="$(mktemp)" || { rm -f -- "$records"; exit 93; }
        fi
        if git config --null --show-scope --includes --get-regexp "^(filter\\..*\\.(clean|smudge|process)|credential(\\..*)?\\.helper|core\\.worktree|http\\..*|remote\\..*\\.(proxy|proxyAuthMethod))$" >"$records" 2>"$errors"; then
          rc=0
        else
          rc=$?
        fi
        if [[ "$rc" -ne 0 && ( "$rc" -ne 1 || -s "$records" || -s "$errors" ) ]]; then
          rm -f -- "$records" "$errors"
          printf "%s\\n" STAGE0_SUBMODULE_EXECUTION_CONFIG_INSPECTION_FAILED
          exit 93
        fi
        if [[ "$rc" -eq 0 ]]; then
          exec 3<"$records"
          while true; do
            scope=""
            if IFS= read -r -d "" scope <&3; then
              :
            elif [[ -n "$scope" ]]; then
              exec 3<&-
              rm -f -- "$records" "$errors"
              printf "%s\\n" STAGE0_SUBMODULE_EXECUTION_CONFIG_INSPECTION_FAILED
              exit 93
            else
              break
            fi
            entry=""
            if ! IFS= read -r -d "" entry <&3 || [[ "$entry" != *$'\''\\n'\''* ]]; then
              exec 3<&-
              rm -f -- "$records" "$errors"
              printf "%s\\n" STAGE0_SUBMODULE_EXECUTION_CONFIG_INSPECTION_FAILED
              exit 93
            fi
            if [[ "$scope" == local || "$scope" == worktree ]]; then
              exec 3<&-
              rm -f -- "$records" "$errors"
              printf "%s\\n" STAGE0_SUBMODULE_EXECUTION_CONFIG
              exit 95
            fi
          done
          exec 3<&-
        fi
        rm -f -- "$records" "$errors"
      '\''
    '; then
    unset STAGE0_SUBMODULE_INSPECTION_ROOT
    if [[ "$submodule_output" == *"STAGE0_SUBMODULE_EXECUTION_CONFIG_INSPECTION_FAILED"* ]]; then
      log_error "Unable to inspect initialized-submodule Git execution configuration; refusing Stage-0 onboarding."
    elif [[ "$submodule_output" == *"STAGE0_SUBMODULE_EXECUTION_CONFIG"* ]]; then
      log_error "An initialized submodule has repository-local or worktree Git execution configuration or HTTP transport override; refusing parent worktree inspection or authenticated fetch."
    else
      log_error "Unable to inspect initialized-submodule Git execution configuration; refusing Stage-0 onboarding."
    fi
    return 1
  fi
  unset STAGE0_SUBMODULE_INSPECTION_ROOT
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

log_info "Stage=0"
log_info "TargetRepository=$TARGET_REPO"
log_info "TargetResolution=$TARGET_RESOLUTION"
log_info "ReleaseChannel=$RELEASE_CHANNEL"
log_info "LabMode=$LAB_MODE"
log_info "TargetBranch=$TARGET_BRANCH"
log_info "TargetVisibility=$TARGET_VISIBILITY"
log_info "IssueSmokeTest=$([[ "$ISSUE_SMOKE_TEST" -eq 1 ]] && echo enabled || echo disabled)"
log_info "Workdir=<local-path>"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log_info "(dry-run) install ca-certificates, dnsutils and git if missing"
  if [[ "$TARGET_VISIBILITY" == "private" ]]; then
    log_info "(dry-run) install GitHub CLI from the official signed Debian repository if missing"
    log_info "(dry-run) prefer and verify a secure system credential store; otherwise use verified RAM-backed session-only auth"
    log_info "(dry-run) authenticate with GitHub device/web flow without opening a local browser; enter the one-time code at https://github.com/login/device from a workstation browser"
    log_info "(dry-run) configure gh as the Git credential helper only for the selected persistent or session-only context"
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
if [[ -z "$TARGET_REPO" ]] && ! command -v dig >/dev/null 2>&1; then missing_packages+=(dnsutils); fi
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

resolve_target_repository || exit 2
valid_target_repo "$TARGET_REPO" || { log_error "Invalid --target-repo."; exit 2; }
if sensitive_argv_value "$TARGET_REPO" || sensitive_argv_value "${TARGET_REPO%%/*}" || sensitive_argv_value "${TARGET_REPO##*/}"; then
  log_error "--target-repo contains a sensitive-shaped value and is rejected."
  exit 2
fi

clone_url="https://github.com/${TARGET_REPO}.git"
dest_name="${TARGET_REPO##*/}"
dest_path="${WORKDIR%/}/${dest_name}"

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
  command -v secret-tool >/dev/null 2>&1 || return 1
  probe_service="yhsm-stage0-probe-${EUID}-$$"
  if ! printf '%s' "$probe_value" | secret-tool store --label='YHSM Stage-0 credential-backend probe' service "$probe_service" account probe >/dev/null 2>&1; then
    return 1
  fi
  probe_readback="$(secret-tool lookup service "$probe_service" account probe 2>/dev/null || true)"
  secret-tool clear service "$probe_service" account probe >/dev/null 2>&1 || true
  [[ "$probe_readback" == "$probe_value" ]] || return 1
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

make_headless_gh_browser_helper() {
  local root="$1" helper mode
  [[ -n "$root" && -d "$root" && ! -L "$root" ]] || {
    log_error "Headless GitHub browser-helper root is not a safe directory."
    return 1
  }
  helper="$(mktemp "$root/yhsm-stage0-gh-browser.XXXXXX")" || return 1
  cat >"$helper" <<'EOF'
#!/usr/bin/env bash
set -eu
expected='https://github.com/login/device'
url="${1:-}"
case "$url" in
  "$expected"|"$expected/") ;;
  *)
    printf '%s\n' '[-] GitHub CLI requested an unexpected browser URL; refusing local browser handoff.' >&2
    exit 64
    ;;
esac
printf '%s\n' '[*] No browser was opened on this server.'
printf '%s\n' '[*] Open https://github.com/login/device in a normal browser on your workstation and enter the one-time code shown by GitHub CLI.'
EOF
  chmod 0700 "$helper" || { rm -f -- "$helper"; return 1; }
  mode="$(stat -c '%a' -- "$helper" 2>/dev/null || true)"
  [[ "$mode" == '700' && -f "$helper" && ! -L "$helper" ]] || {
    rm -f -- "$helper"
    log_error "Headless GitHub browser helper failed its file-permission contract."
    return 1
  }
  printf '%s\n' "$helper"
}

run_gh_headless_device_login() {
  local helper_root="$1" browser_helper child_rc=0 cleanup_rc=0
  shift
  browser_helper="$(make_headless_gh_browser_helper "$helper_root")" || return 1

  log_info "Headless GitHub Device authentication: no browser will be opened on this server."
  log_info "Copy the one-time code shown by GitHub CLI, then open https://github.com/login/device in a normal browser on your workstation and enter the code there."
  log_info "If GitHub CLI asks to press Enter to open a browser, press Enter; Stage-0 intercepts that handoff and keeps the server headless."

  if run_interruptible_child env "GH_BROWSER=$browser_helper" "BROWSER=$browser_helper" gh auth login --hostname github.com --git-protocol https --web "$@"; then
    child_rc=0
  else
    child_rc=$?
  fi

  rm -f -- "$browser_helper" || cleanup_rc=1
  if [[ "$PENDING_SIGNAL_STATUS" -ne 0 ]]; then
    return "$PENDING_SIGNAL_STATUS"
  fi
  if [[ "$child_rc" -ne 0 ]]; then
    return "$child_rc"
  fi
  if [[ "$cleanup_rc" -ne 0 ]]; then
    log_error "Unable to remove temporary headless GitHub browser helper."
    return 1
  fi
  return 0
}

run_gh_device_login_fail_closed() {
  local config_file config_dir snapshot_dir backup_file existed=0 login_rc=0 result_rc=0
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

  SIGNAL_DEFER_EXIT=1
  if run_gh_headless_device_login "$snapshot_dir"; then
    login_rc=0
  else
    login_rc=$?
  fi

  if [[ "$login_rc" -ne 0 || "$PENDING_SIGNAL_STATUS" -ne 0 ]]; then
    result_rc="$login_rc"
    [[ "$PENDING_SIGNAL_STATUS" -eq 0 ]] || result_rc="$PENDING_SIGNAL_STATUS"
    restore_gh_config_snapshot "$config_file" "$backup_file" "$existed"
    rm -rf -- "$snapshot_dir"
    [[ "$PENDING_SIGNAL_STATUS" -eq 0 ]] || result_rc="$PENDING_SIGNAL_STATUS"
    SIGNAL_DEFER_EXIT=0
    log_error "GitHub device/web authentication failed or was interrupted; the previous gh configuration was restored."
    return "$result_rc"
  fi

  if ! reject_plaintext_gh_credentials; then
    result_rc=1
    restore_gh_config_snapshot "$config_file" "$backup_file" "$existed"
    rm -rf -- "$snapshot_dir"
    [[ "$PENDING_SIGNAL_STATUS" -eq 0 ]] || result_rc="$PENDING_SIGNAL_STATUS"
    SIGNAL_DEFER_EXIT=0
    log_error "GitHub CLI plaintext fallback was removed and the previous gh configuration was restored."
    return "$result_rc"
  fi

  rm -rf -- "$snapshot_dir"
  [[ "$PENDING_SIGNAL_STATUS" -eq 0 ]] || result_rc="$PENDING_SIGNAL_STATUS"
  SIGNAL_DEFER_EXIT=0
  [[ "$result_rc" -eq 0 ]] || return "$result_rc"
}

capture_file_state() {
  local path="$1" existed_name="$2" hash_name="$3" hash_value=""
  if [[ -f "$path" && ! -L "$path" ]]; then
    printf -v "$existed_name" '%s' 1
    hash_value="$(sha256sum -- "$path" | awk '{print $1}')" || return 1
    printf -v "$hash_name" '%s' "$hash_value"
  elif [[ -e "$path" || -L "$path" ]]; then
    return 1
  else
    printf -v "$existed_name" '%s' 0
    printf -v "$hash_name" '%s' ''
  fi
}

verify_file_state_unchanged() {
  local path="$1" existed="$2" expected_hash="$3" actual_hash
  if [[ "$existed" -eq 1 ]]; then
    [[ -f "$path" && ! -L "$path" ]] || return 1
    actual_hash="$(sha256sum -- "$path" | awk '{print $1}')" || return 1
    [[ "$actual_hash" == "$expected_hash" ]]
  else
    [[ ! -e "$path" && ! -L "$path" ]]
  fi
}

capture_normal_auth_state() {
  ORIGINAL_HOME="$HOME"
  if [[ -v XDG_CONFIG_HOME ]]; then
    ORIGINAL_XDG_CONFIG_HOME_SET=1
    ORIGINAL_XDG_CONFIG_HOME="$XDG_CONFIG_HOME"
  else
    ORIGINAL_XDG_CONFIG_HOME_SET=0
    ORIGINAL_XDG_CONFIG_HOME=""
  fi
  if [[ -v GH_CONFIG_DIR ]]; then
    ORIGINAL_GH_CONFIG_DIR_SET=1
    ORIGINAL_GH_CONFIG_DIR="$GH_CONFIG_DIR"
  else
    ORIGINAL_GH_CONFIG_DIR_SET=0
    ORIGINAL_GH_CONFIG_DIR=""
  fi
  NORMAL_GH_CONFIG_FILE="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}/hosts.yml"
  NORMAL_GIT_CONFIG_FILE="$HOME/.gitconfig"
  NORMAL_XDG_GIT_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/git/config"
  capture_file_state "$NORMAL_GH_CONFIG_FILE" NORMAL_GH_CONFIG_EXISTED NORMAL_GH_CONFIG_SHA256 || return 1
  capture_file_state "$NORMAL_GIT_CONFIG_FILE" NORMAL_GIT_CONFIG_EXISTED NORMAL_GIT_CONFIG_SHA256 || return 1
  if [[ "$NORMAL_XDG_GIT_CONFIG_FILE" != "$NORMAL_GIT_CONFIG_FILE" ]]; then
    capture_file_state "$NORMAL_XDG_GIT_CONFIG_FILE" NORMAL_XDG_GIT_CONFIG_EXISTED NORMAL_XDG_GIT_CONFIG_SHA256 || return 1
  fi
}

verify_normal_auth_state_unchanged() {
  verify_file_state_unchanged "$NORMAL_GH_CONFIG_FILE" "$NORMAL_GH_CONFIG_EXISTED" "$NORMAL_GH_CONFIG_SHA256" || return 1
  verify_file_state_unchanged "$NORMAL_GIT_CONFIG_FILE" "$NORMAL_GIT_CONFIG_EXISTED" "$NORMAL_GIT_CONFIG_SHA256" || return 1
  if [[ "$NORMAL_XDG_GIT_CONFIG_FILE" != "$NORMAL_GIT_CONFIG_FILE" ]]; then
    verify_file_state_unchanged "$NORMAL_XDG_GIT_CONFIG_FILE" "$NORMAL_XDG_GIT_CONFIG_EXISTED" "$NORMAL_XDG_GIT_CONFIG_SHA256" || return 1
  fi
}

safe_tmpfs_parent() {
  local run_user="/run/user/$EUID"
  if [[ -d "$run_user" && ! -L "$run_user" ]] &&
     [[ "$(stat -c '%u' -- "$run_user" 2>/dev/null || true)" == "$EUID" ]] &&
     [[ "$(stat -f -c '%T' -- "$run_user" 2>/dev/null || true)" == "tmpfs" ]]; then
    printf '%s\n' "$run_user"
    return 0
  fi
  if [[ -d /dev/shm && ! -L /dev/shm ]] &&
     [[ "$(stat -f -c '%T' -- /dev/shm 2>/dev/null || true)" == "tmpfs" ]]; then
    printf '%s\n' /dev/shm
    return 0
  fi
  return 1
}

start_session_auth() {
  local mode
  capture_normal_auth_state || { log_error "Unable to snapshot normal GitHub/Git configuration before session-only authentication."; return 1; }
  SESSION_PARENT="$(safe_tmpfs_parent)" || {
    log_error "No verified tmpfs is available for session-only GitHub authentication; refusing plaintext fallback."
    return 1
  }
  SESSION_ROOT="$(mktemp -d "$SESSION_PARENT/yhsm-stage0-session.XXXXXX")" || return 1
  chmod 0700 "$SESSION_ROOT" || { rm -rf -- "$SESSION_ROOT"; SESSION_ROOT=""; return 1; }
  [[ ! -L "$SESSION_ROOT" && "$(stat -c '%u' -- "$SESSION_ROOT")" == "$EUID" ]] || { rm -rf -- "$SESSION_ROOT"; SESSION_ROOT=""; return 1; }
  mode="$(stat -c '%a' -- "$SESSION_ROOT")" || { rm -rf -- "$SESSION_ROOT"; SESSION_ROOT=""; return 1; }
  [[ "$mode" == "700" ]] || { rm -rf -- "$SESSION_ROOT"; SESSION_ROOT=""; return 1; }
  mkdir -p "$SESSION_ROOT/home" "$SESSION_ROOT/xdg" "$SESSION_ROOT/gh"
  chmod 0700 "$SESSION_ROOT/home" "$SESSION_ROOT/xdg" "$SESSION_ROOT/gh"
  printf "yhsm-stage0-session-v1\\n" >"$SESSION_ROOT/.yhsm-stage0-session"
  chmod 0600 "$SESSION_ROOT/.yhsm-stage0-session"
  export HOME="$SESSION_ROOT/home"
  export XDG_CONFIG_HOME="$SESSION_ROOT/xdg"
  export GH_CONFIG_DIR="$SESSION_ROOT/gh"
  SESSION_AUTH_ACTIVE=1
  log_info "Secure OS credential store unavailable; using verified RAM-backed session-only GitHub authentication."
}

stage0_session_handoff_path() {
  printf '%s/yhsm-stage0-handoff-%s\n' "$SESSION_PARENT" "$EUID"
}

remove_owned_session_root() {
  local root="$1" parent="$2" canonical
  [[ -n "$root" && -n "$parent" ]] || return 1
  [[ "$root" != "$parent" && "$root" != *..* && "$root" != *//* && "$root" != */./* && "$root" != */. ]] || return 1
  canonical="$(realpath -e -- "$root" 2>/dev/null || true)"
  [[ "$canonical" == "$root" && "$canonical" == "$parent/"* ]] || return 1
  [[ -d "$canonical" && ! -L "$canonical" && "$(stat -c '%u' -- "$canonical" 2>/dev/null || true)" == "$EUID" && "$(stat -c '%a' -- "$canonical" 2>/dev/null || true)" == "700" ]] || return 1
  rm -rf -- "$root" || return 1
  [[ ! -e "$root" && ! -L "$root" ]]
}

revoke_session_handoff() {
  local root="$SESSION_ROOT" parent="$SESSION_PARENT" pid="$HANDOFF_REAPER_PID"
  [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] || kill "$pid" 2>/dev/null || true
  HANDOFF_REAPER_PID=""
  [[ -z "$SESSION_HANDOFF_FILE" || ! -e "$SESSION_HANDOFF_FILE" || -L "$SESSION_HANDOFF_FILE" ]] || rm -f -- "$SESSION_HANDOFF_FILE" || true
  remove_owned_session_root "$root" "$parent" || true
  SESSION_HANDOFF_FILE=""
  SESSION_HANDOFF_ACTIVE=0
  SESSION_AUTH_ACTIVE=0
  SESSION_ROOT=""
  SESSION_PARENT=""
}

reclaim_expired_session_handoff() {
  local path="$1" parent="$SESSION_PARENT" root="" expires="" key value now
  [[ -f "$path" && ! -L "$path" ]] || return 1
  [[ "$(stat -c '%u' -- "$path" 2>/dev/null || true)" == "$EUID" && "$(stat -c '%a' -- "$path" 2>/dev/null || true)" == "600" ]] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      root) root="$value" ;;
      expires_epoch) expires="$value" ;;
      version|repository|branch|created_epoch) ;;
      *) return 1 ;;
    esac
  done <"$path"
  [[ -n "$root" && "$expires" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)" || return 1
  if (( now < expires )); then return 1; fi
  remove_owned_session_root "$root" "$parent" || return 1
  rm -f -- "$path" || return 1
  [[ ! -e "$path" && ! -L "$path" ]]
}

start_session_handoff_reaper() {
  local handoff_file="$SESSION_HANDOFF_FILE" parent="$SESSION_PARENT" expected_root="$SESSION_ROOT" expected_expiry="$1"
  (
    trap '' HUP INT TERM
    local now delay root="" expires="" key value
    now="$(date +%s)" || exit 0
    delay=$((expected_expiry - now))
    (( delay > 0 )) && sleep "$delay"
    [[ -f "$handoff_file" && ! -L "$handoff_file" ]] || exit 0
    [[ "$(stat -c '%u' -- "$handoff_file" 2>/dev/null || true)" == "$EUID" && "$(stat -c '%a' -- "$handoff_file" 2>/dev/null || true)" == "600" ]] || exit 0
    while IFS='=' read -r key value; do
      case "$key" in
        root) root="$value" ;;
        expires_epoch) expires="$value" ;;
        version|repository|branch|created_epoch) ;;
        *) exit 0 ;;
      esac
    done <"$handoff_file"
    [[ "$root" == "$expected_root" && "$expires" == "$expected_expiry" ]] || exit 0
    now="$(date +%s)" || exit 0
    (( now >= expires )) || exit 0
    remove_owned_session_root "$root" "$parent" || exit 0
    rm -f -- "$handoff_file" || exit 0
  ) >/dev/null 2>&1 &
  HANDOFF_REAPER_PID="$!"
}

handoff_publish_fail() {
  HANDOFF_PUBLISHING=0
  SIGNAL_DEFER_EXIT=0
  revoke_session_handoff
  return 1
}

publish_session_handoff() {
  local path now expires tmp
  SIGNAL_DEFER_EXIT=1
  HANDOFF_PUBLISHING=1
  [[ "$SESSION_AUTH_ACTIVE" -eq 1 && -n "$SESSION_ROOT" && -n "$SESSION_PARENT" ]] || { handoff_publish_fail; return; }
  path="$(stage0_session_handoff_path)" || { handoff_publish_fail; return; }
  if [[ -e "$path" || -L "$path" ]]; then
    reclaim_expired_session_handoff "$path" || {
      log_error "A previous live or invalid Stage-0 session handoff is still present; refusing overwrite."
      handoff_publish_fail
      return
    }
    [[ ! -e "$path" && ! -L "$path" ]] || { handoff_publish_fail; return; }
  fi
  now="$(date +%s)" || { handoff_publish_fail; return; }
  expires=$((now + 900))
  tmp="$(mktemp "$SESSION_PARENT/.yhsm-stage0-handoff.XXXXXX")" || { handoff_publish_fail; return; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; handoff_publish_fail; return; }
  {
    printf 'version=1\n'
    printf 'root=%s\n' "$SESSION_ROOT"
    printf 'repository=%s\n' "$TARGET_REPO"
    printf 'branch=%s\n' "$TARGET_BRANCH"
    printf 'created_epoch=%s\n' "$now"
    printf 'expires_epoch=%s\n' "$expires"
  } >"$tmp" || { rm -f -- "$tmp"; handoff_publish_fail; return; }
  if ! ln -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    log_error "Unable to publish the RAM-backed Stage-0 session handoff."
    handoff_publish_fail
    return
  fi
  rm -f -- "$tmp" || { handoff_publish_fail; return; }
  SESSION_HANDOFF_FILE="$path"
  SESSION_HANDOFF_ACTIVE=1
  restore_original_auth_environment || { handoff_publish_fail; return; }
  SESSION_AUTH_ACTIVE=0
  start_session_handoff_reaper "$expires"
  HANDOFF_PUBLISHING=0
  SIGNAL_DEFER_EXIT=0
  if [[ "$PENDING_SIGNAL_STATUS" -ne 0 ]]; then
    revoke_session_handoff
    forward_termination_signal "${PENDING_SIGNAL_NAME:-TERM}" "$PENDING_SIGNAL_STATUS"
    return 1
  fi
  log_ok "RAM-backed Stage-0 session handoff published; next customer bootstrap must consume it before expiry."
}

restore_original_auth_environment() {
  export HOME="$ORIGINAL_HOME"
  if [[ "$ORIGINAL_XDG_CONFIG_HOME_SET" -eq 1 ]]; then
    export XDG_CONFIG_HOME="$ORIGINAL_XDG_CONFIG_HOME"
  else
    unset XDG_CONFIG_HOME
  fi
  if [[ "$ORIGINAL_GH_CONFIG_DIR_SET" -eq 1 ]]; then
    export GH_CONFIG_DIR="$ORIGINAL_GH_CONFIG_DIR"
  else
    unset GH_CONFIG_DIR
  fi
}

forward_termination_signal() {
  local signal_name="$1" signal_status="$2" pid="${ACTIVE_CHILD_PID:-}"
  PENDING_SIGNAL_NAME="$signal_name"
  PENDING_SIGNAL_STATUS="$signal_status"

  if [[ -n "$pid" ]]; then
    if [[ "$pid" =~ ^[0-9]+$ && "${ACTIVE_CHILD_SIGNAL_DEFER:-0}" -eq 0 ]]; then
      if [[ "${ACTIVE_CHILD_SIGNAL_GROUP:-0}" -eq 1 ]]; then
        kill -s "$signal_name" -- "-$pid" 2>/dev/null || true
      else
        kill -s "$signal_name" "$pid" 2>/dev/null || true
      fi
    fi
    return 0
  fi

  if [[ "$SIGNAL_DEFER_EXIT" -eq 1 ]]; then
    return 0
  fi

  exit "$signal_status"
}

run_interruptible_child() {
  local rc child_pid

  ACTIVE_CHILD_PID="pending"
  (
    if [[ "${ACTIVE_CHILD_SIGNAL_DEFER:-0}" -eq 1 ]]; then
      # Registration-critical children must also survive HUP/INT/TERM delivered
      # directly to the foreground process group until cleanup registration.
      trap '' HUP INT TERM
    else
      # Non-job-control Bash gives asynchronous children an ignored SIGINT.
      # Reset termination dispositions in the forked shell before exec.
      trap - HUP INT TERM
    fi
    exec "$@"
  ) &
  child_pid=$!
  ACTIVE_CHILD_PID="$child_pid"

  if [[ "$PENDING_SIGNAL_STATUS" -ne 0 && "${ACTIVE_CHILD_SIGNAL_DEFER:-0}" -eq 0 ]]; then
    kill -s "${PENDING_SIGNAL_NAME:-TERM}" "$child_pid" 2>/dev/null || true
  fi

  while true; do
    if wait "$child_pid"; then
      rc=0
      break
    else
      rc=$?
    fi

    if kill -0 "$child_pid" 2>/dev/null; then
      if [[ "$PENDING_SIGNAL_STATUS" -ne 0 && "${ACTIVE_CHILD_SIGNAL_DEFER:-0}" -eq 0 ]]; then
        kill -s "${PENDING_SIGNAL_NAME:-TERM}" "$child_pid" 2>/dev/null || true
      fi
      continue
    fi
    break
  done

  ACTIVE_CHILD_PID=""
  if [[ "$PENDING_SIGNAL_STATUS" -ne 0 ]]; then
    return "$PENDING_SIGNAL_STATUS"
  fi
  return "$rc"
}

run_interruptible_process_group_child() {
  local rc child_pid attempt group_ready=0

  command -v setsid >/dev/null 2>&1 || return 127
  ACTIVE_CHILD_SIGNAL_GROUP=1
  ACTIVE_CHILD_PID="pending"
  (
    trap - HUP INT TERM
    exec setsid "$@"
  ) &
  child_pid=$!

  for ((attempt = 0; attempt < 100; attempt++)); do
    if kill -0 -- "-$child_pid" 2>/dev/null; then
      group_ready=1
      break
    fi
    kill -0 "$child_pid" 2>/dev/null || break
    sleep 0.01
  done

  if [[ "$group_ready" -ne 1 ]]; then
    if kill -0 "$child_pid" 2>/dev/null; then
      kill -s TERM "$child_pid" 2>/dev/null || true
      wait "$child_pid" 2>/dev/null || true
      rc=127
    elif wait "$child_pid"; then
      rc=0
    else
      rc=$?
    fi
    ACTIVE_CHILD_PID=""
    ACTIVE_CHILD_SIGNAL_GROUP=0
    if [[ "$PENDING_SIGNAL_STATUS" -ne 0 ]]; then
      return "$PENDING_SIGNAL_STATUS"
    fi
    return "$rc"
  fi

  ACTIVE_CHILD_PID="$child_pid"

  if [[ "$PENDING_SIGNAL_STATUS" -ne 0 ]]; then
    kill -s "${PENDING_SIGNAL_NAME:-TERM}" -- "-$child_pid" 2>/dev/null || true
  fi

  while true; do
    if wait "$child_pid"; then
      rc=0
      break
    else
      rc=$?
    fi

    if kill -0 "$child_pid" 2>/dev/null; then
      if [[ "$PENDING_SIGNAL_STATUS" -ne 0 ]]; then
        kill -s "${PENDING_SIGNAL_NAME:-TERM}" -- "-$child_pid" 2>/dev/null || true
      fi
      continue
    fi
    break
  done

  ACTIVE_CHILD_PID=""
  ACTIVE_CHILD_SIGNAL_GROUP=0
  if [[ "$PENDING_SIGNAL_STATUS" -ne 0 ]]; then
    return "$PENDING_SIGNAL_STATUS"
  fi
  return "$rc"
}

capture_interruptible_child() {
  local output_name="$1" capture_root capture_file rc output
  shift

  if [[ "$SESSION_AUTH_ACTIVE" -eq 1 && -n "$SESSION_ROOT" ]]; then
    capture_root="$SESSION_ROOT"
  else
    capture_root="${TMPDIR:-/tmp}"
  fi

  capture_file="$(mktemp "$capture_root/yhsm-stage0-output.XXXXXX")" || return 1
  if run_interruptible_child "$@" >"$capture_file"; then
    rc=0
  else
    rc=$?
  fi

  output="$(cat -- "$capture_file")" || {
    rm -f -- "$capture_file"
    return 1
  }
  printf -v "$output_name" '%s' "$output"

  rm -f -- "$capture_file"
  return "$rc"
}

run_git_child_or_propagate_signal() {
  local rc

  if run_interruptible_child git "$@"; then
    rc=0
  else
    rc=$?
  fi

  if [[ "$PENDING_SIGNAL_STATUS" -ne 0 ]]; then
    forward_termination_signal "${PENDING_SIGNAL_NAME:-TERM}" "$PENDING_SIGNAL_STATUS"
  fi

  return "$rc"
}


capture_git_child_or_propagate_signal() {
  local output_name="$1" rc
  shift

  if capture_interruptible_child "$output_name" git "$@"; then
    rc=0
  else
    rc=$?
  fi

  if [[ "$PENDING_SIGNAL_STATUS" -ne 0 ]]; then
    forward_termination_signal "${PENDING_SIGNAL_NAME:-TERM}" "$PENDING_SIGNAL_STATUS"
  fi

  return "$rc"
}

capture_git_child_combined_or_propagate_signal() {
  local output_name="$1" capture_root capture_file rc output
  shift

  if [[ "$SESSION_AUTH_ACTIVE" -eq 1 && -n "$SESSION_ROOT" ]]; then
    capture_root="$SESSION_ROOT"
  else
    capture_root="${TMPDIR:-/tmp}"
  fi

  capture_file="$(mktemp "$capture_root/yhsm-stage0-git-output.XXXXXX")" || return 1

  if run_interruptible_child git "$@" >"$capture_file" 2>&1; then
    rc=0
  else
    rc=$?
  fi

  output="$(cat -- "$capture_file")" || {
    rm -f -- "$capture_file"
    return 1
  }
  printf -v "$output_name" '%s' "$output"
  rm -f -- "$capture_file"

  if [[ "$PENDING_SIGNAL_STATUS" -ne 0 ]]; then
    forward_termination_signal "${PENDING_SIGNAL_NAME:-TERM}" "$PENDING_SIGNAL_STATUS"
  fi

  return "$rc"
}

capture_git_process_group_child_combined_or_propagate_signal() {
  local output_name="$1" capture_root capture_file rc output
  shift

  if [[ "$SESSION_AUTH_ACTIVE" -eq 1 && -n "$SESSION_ROOT" ]]; then
    capture_root="$SESSION_ROOT"
  else
    capture_root="${TMPDIR:-/tmp}"
  fi

  capture_file="$(mktemp "$capture_root/yhsm-stage0-git-output.XXXXXX")" || return 1

  if run_interruptible_process_group_child git "$@" >"$capture_file" 2>&1; then
    rc=0
  else
    rc=$?
  fi

  output="$(cat -- "$capture_file")" || {
    rm -f -- "$capture_file"
    return 1
  }
  printf -v "$output_name" '%s' "$output"
  rm -f -- "$capture_file"

  if [[ "$PENDING_SIGNAL_STATUS" -ne 0 ]]; then
    forward_termination_signal "${PENDING_SIGNAL_NAME:-TERM}" "$PENDING_SIGNAL_STATUS"
  fi

  return "$rc"
}

cleanup_issue_smoke_test() {
  if [[ -z "$SMOKE_ISSUE_REPO" || -z "$SMOKE_ISSUE_NUMBER" ]]; then return 0; fi
  gh issue close "$SMOKE_ISSUE_NUMBER" --repo "$SMOKE_ISSUE_REPO" --comment 'Stage-0 cleanup closed the temporary smoke-test issue after an interrupted verification.' >/dev/null 2>&1 || true
  SMOKE_ISSUE_REPO=""
  SMOKE_ISSUE_NUMBER=""
}

cleanup_ignored_paths_record() {
  local path="$IGNORED_PATHS_RECORD"
  [[ -n "$path" ]] || return 0
  if [[ -e "$path" || -L "$path" ]]; then
    [[ -f "$path" && ! -L "$path" ]] || return 1
    rm -f -- "$path" || return 1
  fi
  IGNORED_PATHS_RECORD=""
}

cleanup_session_auth_best_effort() {
  local root="$SESSION_ROOT"
  [[ "$SESSION_AUTH_ACTIVE" -eq 1 ]] || return 0
  restore_original_auth_environment || true

  if [[ -n "$root" ]]; then
    rm -rf -- "$root" >/dev/null 2>&1 || return 1
    [[ ! -e "$root" && ! -L "$root" ]] || return 1
  fi

  SESSION_AUTH_ACTIVE=0
  SESSION_ROOT=""
  SESSION_PARENT=""
}

cleanup_stage0() {
  local rc=$?
  if [[ "$CLEANUP_ACTIVE" -eq 1 ]]; then return "$rc"; fi
  CLEANUP_ACTIVE=1
  cleanup_ignored_paths_record || true
  cleanup_issue_smoke_test || true
  cleanup_session_auth_best_effort || true
  CLEANUP_ACTIVE=0
  return "$rc"
}

trap cleanup_stage0 EXIT
trap 'forward_termination_signal HUP 129' HUP
trap 'forward_termination_signal INT 130' INT
trap 'forward_termination_signal TERM 143' TERM

run_gh_session_login() {
  local session_hosts mode child_rc
  start_session_auth || return 1
  log_info "Starting session-only GitHub Device/Web authentication."

  if run_gh_headless_device_login "$SESSION_ROOT" --insecure-storage; then
    :
  else
    child_rc=$?
    log_error "GitHub session-only device/web authentication failed or was interrupted."
    return "$child_rc"
  fi

  session_hosts="$GH_CONFIG_DIR/hosts.yml"
  case "$session_hosts/" in "$SESSION_ROOT/"*) ;; *) log_error "Session GitHub configuration escaped the RAM-backed session root."; return 1 ;; esac
  [[ -f "$session_hosts" && ! -L "$session_hosts" ]] || { log_error "Session GitHub configuration was not created as a regular file."; return 1; }
  [[ "$(stat -c '%u' -- "$session_hosts")" == "$EUID" ]] || { log_error "Session GitHub configuration has an unexpected owner."; return 1; }
  mode="$(stat -c '%a' -- "$session_hosts")" || return 1
  case "$mode" in 600|400) ;; *) log_error "Session GitHub configuration permissions are too broad."; return 1 ;; esac
  grep -Eq '^[[:space:]]*oauth_token[[:space:]]*:' "$session_hosts" || { log_error "Session-only GitHub authentication did not produce the expected isolated credential record."; return 1; }

  if run_interruptible_child gh auth status --hostname github.com >/dev/null 2>&1; then
    :
  else
    child_rc=$?
    log_error "Session-only GitHub authentication could not be verified."
    return "$child_rc"
  fi

  run_interruptible_child gh auth setup-git --hostname github.com || return $?
  log_ok "Session-only GitHub authentication verified in RAM-backed storage."
}

verify_direct_repo_has_no_credential_helper() {
  local repo_path="$1" config_path rc
  local -a paths=()
  mapfile -t paths < <(resolve_direct_git_config_paths "$repo_path") || return 1
  [[ "${#paths[@]}" -eq 2 ]] || return 1
  for config_path in "${paths[@]}"; do
    [[ -e "$config_path" ]] || continue
    if run_git_child_or_propagate_signal config --file "$config_path" --no-includes --get-regexp '^credential(\..*)?\.helper$' >/dev/null 2>&1; then
      return 1
    else
      rc=$?
      [[ "$rc" -eq 1 ]] || return 1
    fi
  done
}

verify_raw_origin_urls_exact() {
  local repo_path="$1" expected_url_1="$2" expected_url_2="$3"
  local config_output config_path key raw_values url rc saw_fetch=0
  local -a paths=()

  config_output="$(resolve_direct_git_config_paths "$repo_path")" || return 1
  mapfile -t paths <<<"$config_output"
  [[ "${#paths[@]}" -eq 2 ]] || return 1

  for config_path in "${paths[@]}"; do
    [[ -e "$config_path" ]] || continue
    [[ -f "$config_path" && ! -L "$config_path" ]] || return 1

    for key in remote.origin.url remote.origin.pushurl; do
      raw_values=''
      if capture_git_child_or_propagate_signal raw_values config --file "$config_path" --no-includes --get-all "$key" 2>/dev/null; then
        [[ -n "$raw_values" ]] || return 1

        while IFS= read -r url; do
          [[ -n "$url" ]] || return 1

          if [[ "$url" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^/@]+@ ]]; then
            return 1
          fi

          case "$url" in
            "$expected_url_1"|"$expected_url_2") ;;
            *) return 1 ;;
          esac

          if [[ "$key" == "remote.origin.url" ]]; then
            saw_fetch=1
          fi
        done <<<"$raw_values"
      else
        rc=$?
        [[ "$rc" -eq 1 ]] || return 1
      fi
    done
  done

  [[ "$saw_fetch" -eq 1 ]]
}

verify_origin_urls_exact() {
  local repo_path="$1" expected_url_1="$2" expected_url_2="$3" origin_urls url kind

  verify_raw_origin_urls_exact "$repo_path" "$expected_url_1" "$expected_url_2" || return 1

  for kind in fetch push; do
    if [[ "$kind" == "fetch" ]]; then
      origin_urls=''
      capture_git_child_or_propagate_signal origin_urls -C "$repo_path" remote get-url --all origin 2>/dev/null || return 1
    else
      origin_urls=''
      capture_git_child_or_propagate_signal origin_urls -C "$repo_path" remote get-url --push --all origin 2>/dev/null || return 1
    fi

    [[ -n "$origin_urls" ]] || return 1
    while IFS= read -r url; do
      [[ -n "$url" ]] || return 1
      if [[ "$url" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^/@]+@ ]]; then
        return 1
      fi
      case "$url" in
        "$expected_url_1"|"$expected_url_2") ;;
        *) return 1 ;;
      esac
    done <<<"$origin_urls"
  done
}

verify_session_postconditions() {
  local repo_path="$1"
  [[ "$SESSION_AUTH_ACTIVE" -eq 1 ]] || return 0
  verify_normal_auth_state_unchanged || { log_error "Normal GitHub/Git configuration changed during session-only onboarding."; return 1; }
  case "$HOME/" in "$SESSION_ROOT/"*) ;; *) log_error "Session HOME escaped the RAM-backed session root."; return 1 ;; esac
  case "$XDG_CONFIG_HOME/" in "$SESSION_ROOT/"*) ;; *) log_error "Session XDG config escaped the RAM-backed session root."; return 1 ;; esac
  case "$GH_CONFIG_DIR/" in "$SESSION_ROOT/"*) ;; *) log_error "Session GitHub config escaped the RAM-backed session root."; return 1 ;; esac
  verify_direct_repo_has_no_credential_helper "$repo_path" || { log_error "Clone retained a repository-local credential helper after session-only onboarding."; return 1; }
  verify_origin_urls_exact "$repo_path" "$clone_url" "https://github.com/$TARGET_REPO" || {
    log_error "Clone contains an unexpected or credential-bearing origin fetch/push URL; refusing session cleanup readback."
    return 1
  }
  log_ok "Session-only authentication postconditions verified."
}

finish_session_auth() {
  local root="$SESSION_ROOT"
  [[ "$SESSION_AUTH_ACTIVE" -eq 1 ]] || return 0
  restore_original_auth_environment || return 1

  rm -rf -- "$root" || return 1
  [[ ! -e "$root" && ! -L "$root" ]] || return 1

  SESSION_AUTH_ACTIVE=0
  SESSION_ROOT=""
  SESSION_PARENT=""
  log_ok "Session-only GitHub authentication state removed."
}

if [[ "$TARGET_VISIBILITY" == "private" ]]; then
  install_gh
  reject_plaintext_gh_credentials
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    log_ok "GitHub authentication already present."
    gh auth setup-git --hostname github.com
  elif verify_secure_gh_credential_backend; then
    log_info "GitHub authentication required for the private repository."
    run_gh_device_login_fail_closed
    reject_plaintext_gh_credentials
    gh auth setup-git --hostname github.com
  else
    run_gh_session_login
  fi
  if run_interruptible_child gh repo view "$TARGET_REPO" --json nameWithOwner,visibility,defaultBranchRef >/dev/null; then
    :
  else
    stage0_child_rc=$?
    log_error "Authenticated GitHub account cannot access the target repository."
    exit "$stage0_child_rc"
  fi
  if run_interruptible_child gh issue list --repo "$TARGET_REPO" --limit 1 >/dev/null; then
    :
  else
    stage0_child_rc=$?
    log_error "Authenticated GitHub account cannot read issues in the target repository."
    exit "$stage0_child_rc"
  fi
  log_ok "Private repository and issue read access verified."
fi

validate_initialized_submodules() {
  local repo_path="$1" submodule_output
  # Nested submodule commands are intentionally literal until executed in the submodule context.
  # shellcheck disable=SC2016
  if ! capture_git_process_group_child_combined_or_propagate_signal submodule_output -c core.hooksPath=/dev/null -C "$repo_path" submodule foreach --quiet --recursive '
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
    '; then
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
if [[ -e "$dest_path" && ! -e "$dest_path/.git" ]]; then
  log_error "Clone destination exists but is not a Git repository."; exit 1
fi

remote_ref="refs/remotes/origin/$TARGET_BRANCH"
repository_index=''
repository_status=''
repository_replace_refs=''

if [[ -e "$dest_path/.git" ]]; then
  reject_existing_clone_execution_config "$dest_path" || exit 1
  verify_origin_urls_exact "$dest_path" "$clone_url" "https://github.com/$TARGET_REPO" || {
    log_error "Existing clone has an unexpected or credential-bearing origin fetch/push URL."
    exit 1
  }
  repository_replace_refs=''
  if ! capture_git_child_or_propagate_signal repository_replace_refs -C "$dest_path" for-each-ref --format='%(refname)' refs/replace/; then
    log_error "Unable to inspect existing clone replacement refs; refusing canonical onboarding readback."
    exit 1
  fi
  if [[ -n "$repository_replace_refs" ]]; then
    log_error "Existing clone has Git replacement refs; refusing canonical onboarding readback."
    exit 1
  fi
  repository_index=''
  if ! capture_git_child_or_propagate_signal repository_index -c core.fsmonitor=false -C "$dest_path" ls-files -v; then
    log_error "Unable to inspect existing clone index flags; refusing canonical onboarding readback."
    exit 1
  fi
  if grep -Eq '^[a-zS]' <<<"$repository_index"; then
    log_error "Existing clone has hidden index flags (assume-unchanged or skip-worktree); refusing canonical onboarding readback."
    exit 1
  fi
  if ! capture_git_child_or_propagate_signal repository_status -c core.fsmonitor=false -C "$dest_path" status --porcelain --untracked-files=all --ignore-submodules=none; then
    log_error "Unable to inspect existing clone cleanliness; refusing to modify or report it as canonical."
    exit 1
  fi
  if [[ -n "$repository_status" ]]; then
    log_error "Existing clone is not clean; refusing to modify or report it as canonical."
    exit 1
  fi
  validate_initialized_submodules "$dest_path" || exit 1
  log_info "Existing clean clone found; fetching exact remote branch."
  run_git_child_or_propagate_signal -c core.hooksPath=/dev/null -C "$dest_path" fetch origin "+refs/heads/$TARGET_BRANCH:refs/remotes/origin/$TARGET_BRANCH" --quiet
  remote_head=''
  if ! capture_git_child_or_propagate_signal remote_head -C "$dest_path" rev-parse "$remote_ref"; then
    log_error "Unable to resolve the fetched remote branch."
    exit 1
  fi
  ignored_paths_root="${TMPDIR:-/tmp}"
  if [[ "$SESSION_AUTH_ACTIVE" -eq 1 && -n "$SESSION_ROOT" ]]; then
    ignored_paths_root="$SESSION_ROOT"
  fi
  if ! IGNORED_PATHS_RECORD="$(mktemp "$ignored_paths_root/yhsm-stage0-ignored-paths.XXXXXX")"; then
    log_error "Unable to create the ignored-file inspection record."
    exit 1
  fi
  [[ -f "$IGNORED_PATHS_RECORD" && ! -L "$IGNORED_PATHS_RECORD" ]] || {
    log_error "Ignored-file inspection record is not a regular file."
    exit 1
  }
  if ! run_git_child_or_propagate_signal -c core.fsmonitor=false -C "$dest_path" ls-files --others --ignored --exclude-standard -z >"$IGNORED_PATHS_RECORD"; then
    log_error "Unable to inspect ignored files in the existing clone."
    exit 1
  fi
  ignored_collision=0
  while IFS= read -r -d '' ignored_path; do
    ignored_remote_match=''
    if ! capture_git_child_or_propagate_signal ignored_remote_match --literal-pathspecs -C "$dest_path" ls-tree -r --name-only "$remote_head" -- "$ignored_path"; then
      log_error "Unable to inspect an ignored-file collision against the selected remote branch."
      exit 1
    fi
    if [[ -n "$ignored_remote_match" ]]; then
      ignored_collision=1
      break
    fi
  done <"$IGNORED_PATHS_RECORD"
  cleanup_ignored_paths_record || {
    log_error "Unable to remove the ignored-file inspection record."
    exit 1
  }
  if [[ "$ignored_collision" -eq 1 ]]; then
    log_error "Existing clone has an ignored local file that collides with the selected remote branch; refusing to overwrite local state."
    exit 1
  fi
  if run_git_child_or_propagate_signal -C "$dest_path" show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
    run_git_child_or_propagate_signal -c core.hooksPath=/dev/null -C "$dest_path" checkout --no-overwrite-ignore "$TARGET_BRANCH" --quiet
  else
    branch_ref_rc=$?
    [[ "$branch_ref_rc" -eq 1 ]] || {
      log_error "Unable to inspect the selected local branch ref."
      exit 1
    }
    run_git_child_or_propagate_signal -c core.hooksPath=/dev/null -C "$dest_path" checkout --no-overwrite-ignore -b "$TARGET_BRANCH" "$remote_head" --quiet
    run_git_child_or_propagate_signal -C "$dest_path" config "branch.$TARGET_BRANCH.remote" origin || {
      log_error "Unable to configure the selected local branch remote."
      exit 1
    }
    run_git_child_or_propagate_signal -C "$dest_path" config "branch.$TARGET_BRANCH.merge" "refs/heads/$TARGET_BRANCH" || {
      log_error "Unable to configure the selected local branch merge ref."
      exit 1
    }
  fi
  local_head=''
  if ! capture_git_child_or_propagate_signal local_head -C "$dest_path" rev-parse HEAD; then
    log_error "Unable to resolve the existing clone head."
    exit 1
  fi
  if [[ "$local_head" != "$remote_head" ]]; then
    if run_git_child_or_propagate_signal -C "$dest_path" merge-base --is-ancestor "$local_head" "$remote_head"; then
      run_git_child_or_propagate_signal -c core.hooksPath=/dev/null -C "$dest_path" merge --ff-only "$remote_head" --quiet
    else
      merge_base_rc=$?
      [[ "$merge_base_rc" -eq 1 ]] || {
        log_error "Unable to inspect existing-clone ancestry."
        exit 1
      }
      log_error "Existing clone does not exactly match origin/$TARGET_BRANCH and cannot be safely fast-forwarded."
      exit 1
    fi
  fi
  exact_local_head=''
  exact_remote_head=''
  capture_git_child_or_propagate_signal exact_local_head -C "$dest_path" rev-parse HEAD || {
    log_error "Unable to resolve the synchronized clone head."
    exit 1
  }
  capture_git_child_or_propagate_signal exact_remote_head -C "$dest_path" rev-parse "$remote_ref" || {
    log_error "Unable to resolve the synchronized remote branch."
    exit 1
  }
  [[ "$exact_local_head" == "$exact_remote_head" ]] || {
    log_error "Existing clone is not exact to the fetched remote branch."
    exit 1
  }
  if ! capture_git_child_or_propagate_signal repository_status -c core.fsmonitor=false -C "$dest_path" status --porcelain --untracked-files=all --ignore-submodules=none; then
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
  trusted_template_dir="$(mktemp -d)"
  if run_interruptible_child git -c core.hooksPath=/dev/null clone --template="$trusted_template_dir" --branch "$TARGET_BRANCH" --single-branch "$clone_url" "$dest_path"; then
    clone_rc=0
  else
    clone_rc=$?
  fi
  rm -rf -- "$trusted_template_dir"
  if [[ "$PENDING_SIGNAL_STATUS" -ne 0 ]]; then
    forward_termination_signal "${PENDING_SIGNAL_NAME:-TERM}" "$PENDING_SIGNAL_STATUS"
  fi
  if [[ "$clone_rc" -ne 0 ]]; then
    exit "$clone_rc"
  fi
fi

if ! capture_git_child_or_propagate_signal repository_index -c core.fsmonitor=false -C "$dest_path" ls-files -v; then
  log_error "Unable to inspect final clone index flags; refusing canonical onboarding readback."
  exit 1
fi
if grep -Eq '^[a-zS]' <<<"$repository_index"; then
  log_error "Clone has hidden index flags (assume-unchanged or skip-worktree); refusing canonical onboarding readback."
  exit 1
fi
repository_replace_refs=''
if ! capture_git_child_or_propagate_signal repository_replace_refs -C "$dest_path" for-each-ref --format='%(refname)' refs/replace/; then
  log_error "Unable to inspect clone replacement refs; refusing canonical onboarding readback."
  exit 1
fi
if [[ -n "$repository_replace_refs" ]]; then
  log_error "Clone has Git replacement refs; refusing canonical onboarding readback."
  exit 1
fi
if ! capture_git_child_or_propagate_signal repository_status -c core.fsmonitor=false -C "$dest_path" status --porcelain --untracked-files=all --ignore-submodules=none; then
  log_error "Unable to inspect final clone cleanliness; refusing canonical onboarding readback."
  exit 1
fi
if [[ -n "$repository_status" ]]; then
  log_error "Clone is dirty after checkout; refusing canonical onboarding readback."
  exit 1
fi
validate_initialized_submodules "$dest_path" || exit 1

run_git_child_or_propagate_signal -C "$dest_path" show-ref --verify --quiet "$remote_ref" || {
  log_error "Clone did not produce the requested remote branch; tags cannot satisfy --target-branch."
  exit 1
}
repo_head=''
repo_branch=''
remote_head=''
capture_git_child_or_propagate_signal repo_head -C "$dest_path" rev-parse HEAD || {
  log_error "Unable to resolve clone HEAD during final canonical readback."
  exit 1
}
capture_git_child_or_propagate_signal repo_branch -C "$dest_path" branch --show-current || {
  log_error "Unable to resolve the checked-out branch during final canonical readback."
  exit 1
}
capture_git_child_or_propagate_signal remote_head -C "$dest_path" rev-parse "$remote_ref" || {
  log_error "Unable to resolve the remote branch during final canonical readback."
  exit 1
}
[[ "$repo_branch" == "$TARGET_BRANCH" ]] || {
  log_error "Clone is not checked out on the requested branch."
  exit 1
}
[[ "$repo_head" == "$remote_head" ]] || {
  log_error "Clone head is not exact to the requested remote branch."
  exit 1
}
verify_origin_urls_exact "$dest_path" "$clone_url" "https://github.com/$TARGET_REPO" || {
  log_error "Clone origin changed during checkout; fetch/push URL set is unexpected or credential-bearing; refusing canonical onboarding readback."
  exit 1
}
repo_remote=''
capture_git_child_or_propagate_signal repo_remote -C "$dest_path" remote get-url origin || {
  log_error "Unable to resolve clone origin during final canonical readback."
  exit 1
}
case "$repo_remote" in
  "$clone_url"|"https://github.com/$TARGET_REPO") ;;
  *) log_error "Clone origin changed during checkout; refusing canonical onboarding readback."; exit 1 ;;
esac
server_ref="refs/heads/$TARGET_BRANCH"
server_ref_line=""
if capture_interruptible_child server_ref_line git ls-remote --exit-code "$clone_url" "$server_ref"; then
  :
else
  stage0_child_rc=$?
  log_error "Unable to query the selected branch from the GitHub server for final canonical readback."
  exit "$stage0_child_rc"
fi
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

run_issue_smoke_test() {
  local issue_url="" issue_number="" child_rc=0 registration_rc=0
  local previous_signal_defer="$SIGNAL_DEFER_EXIT"
  local previous_child_signal_defer="${ACTIVE_CHILD_SIGNAL_DEFER:-0}"
  log_info "Creating sanitized temporary support-channel smoke-test issue."

  # Issue creation is registration-critical: once the request may have reached
  # GitHub, keep both shell termination and signal forwarding to this specific
  # child deferred until its result can be registered for EXIT cleanup.
  SIGNAL_DEFER_EXIT=1
  ACTIVE_CHILD_SIGNAL_DEFER=1

  if capture_interruptible_child issue_url gh issue create --repo "$TARGET_REPO" --title '[pilot-smoke] Stage-0 issue channel verification' --body 'Automated Stage-0 support-channel smoke test. No customer evidence, credentials, secrets, keys, tokens or authorization data included.'; then
    :
  else
    child_rc=$?
  fi

  if [[ -n "$issue_url" ]]; then
    issue_number="${issue_url##*/}"
    if [[ "$issue_number" =~ ^[0-9]+$ ]]; then
      SMOKE_ISSUE_REPO="$TARGET_REPO"
      SMOKE_ISSUE_NUMBER="$issue_number"
      log_info "IssueSmokeTestIssue=$issue_number"
    elif [[ "$child_rc" -eq 0 ]]; then
      log_error "Issue smoke test created an unparseable issue reference."
      registration_rc=1
    fi
  elif [[ "$child_rc" -eq 0 ]]; then
    log_error "Issue smoke test did not return a usable issue reference."
    registration_rc=1
  fi

  # The cleanup handle is now durable in shell state. Restore the caller's
  # child-forwarding and exit-defer modes before propagating the pending signal.
  ACTIVE_CHILD_SIGNAL_DEFER="$previous_child_signal_defer"
  SIGNAL_DEFER_EXIT="$previous_signal_defer"

  if [[ "$PENDING_SIGNAL_STATUS" -ne 0 ]]; then
    return "$PENDING_SIGNAL_STATUS"
  fi
  if [[ "$child_rc" -ne 0 ]]; then
    return "$child_rc"
  fi
  if [[ "$registration_rc" -ne 0 ]]; then
    return "$registration_rc"
  fi

  [[ -n "$SMOKE_ISSUE_NUMBER" ]] || {
    log_error "Issue smoke test did not return a usable issue reference."
    return 1
  }

  run_interruptible_child gh issue comment "$issue_number" --repo "$TARGET_REPO" --body 'Stage-0 issue comment path verified.' >/dev/null || return $?
  run_interruptible_child gh issue view "$issue_number" --repo "$TARGET_REPO" --json number,state,title >/dev/null || return $?
  run_interruptible_child gh issue close "$issue_number" --repo "$TARGET_REPO" --comment 'Stage-0 issue-channel smoke test completed successfully; no product incident.' >/dev/null || return $?

  SMOKE_ISSUE_REPO=""
  SMOKE_ISSUE_NUMBER=""
  log_ok "IssueSmokeTest=PASS issue=$issue_number"
}

if [[ "$ISSUE_SMOKE_TEST" -eq 1 ]]; then run_issue_smoke_test; fi

if [[ "$SESSION_AUTH_ACTIVE" -eq 1 ]]; then
  verify_session_postconditions "$dest_path" || exit 1
  publish_session_handoff || { log_error "Unable to publish the RAM-backed Stage-0 session handoff."; exit 1; }
fi

if [[ "$DRY_RUN" -eq 0 && -f "$dest_path/client/manifest.json" ]]; then
  [[ -f "$dest_path/run/bootstrap.sh" && -x "$dest_path/run/bootstrap.sh" ]] || {
    log_error "HARD_FAIL_CUSTOMER_BOOTSTRAP_ENTRYPOINT_MISSING: the selected customer repository must provide executable run/bootstrap.sh."
    exit 1
  }
  log_info "Stage-0 handoff verified; starting the cloned customer bootstrap automatically."
  if run_interruptible_child "$dest_path/run/bootstrap.sh"; then
    log_ok "Customer bootstrap completed."
  else
    customer_bootstrap_rc=$?
    log_error "Customer bootstrap failed."
    exit "$customer_bootstrap_rc"
  fi
elif [[ "$DRY_RUN" -eq 0 ]]; then
  log_info "No customer client package detected; no customer bootstrap entrypoint is required."
fi

log_info "Next: read the cloned repository documentation and follow only documented preflight/install steps."
log_ok "Stage-0 onboarding complete."

