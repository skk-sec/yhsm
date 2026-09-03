#!/usr/bin/env bash
set -euo pipefail

bootstrap="${1:-$(cd "$(dirname "$0")/.." && pwd)/bootstrap.sh}"
tmp="$(mktemp -d)"
original_path="$PATH"
trap 'rm -rf -- "$tmp"' EXIT

# Load only the resolver/routing functions. The public entrypoint itself is never run.
sed -n '/^valid_dns_domain()/,/^authorization_scheme_marker()/p' "$bootstrap" | sed '$d' >"$tmp/functions.sh"
# shellcheck source=/dev/null
source "$tmp/functions.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
expect_status() {
  local expected="$1"
  shift
  set +e
  "$@"
  local actual=$?
  set -e
  [[ "$actual" -eq "$expected" ]] || fail "expected status $expected, got $actual"
}

mkdir -p "$tmp/bin"
cat >"$tmp/bin/resolvectl" <<'SH'
#!/bin/sh
[ "$1" = domain ] || exit 1
printf '%s\n' 'Global: grundvers.prod'
SH
chmod 0755 "$tmp/bin/resolvectl"

printf '%s\n' 'nameserver 192.0.2.53' >"$tmp/resolv.conf"
PATH="$tmp/bin:$PATH"
[[ "$(resolve_dns_search_domain "$tmp/resolv.conf")" == "grundvers.prod" ]] ||
  fail "resolvectl fallback did not resolve one local domain"

printf '%s\n' 'search invalid' >"$tmp/malformed.conf"
expect_status 2 resolve_dns_search_domain "$tmp/malformed.conf"

PATH="$tmp/empty"
expect_status 4 resolve_dns_search_domain "$tmp/resolv.conf"

PATH="$original_path"
log_error() { :; }
TARGET_REPO=""
TARGET_RESOLUTION=""
RELEASE_CHANNEL=""
LAB_MODE=""
ACCOUNT_CHANNEL_MAP="$tmp/account-map"
resolve_dns_channel_binding() { return 6; }
resolve_account_channel_binding() { printf 'example-owner/customer-channel\tv2.1.0-rc.4\t1\n'; }
resolve_target_repository
[[ "$TARGET_RESOLUTION" == "explicit-account-map" ]] ||
  fail "missing-domain status did not use the explicit account map"
[[ "$TARGET_REPO" == "example-owner/customer-channel" ]] ||
  fail "account map did not retain its exact customer target"

printf '%s\n' 'PASS: Stage-0 resolver contract'
