#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCAN_TMP=$(mktemp -d)
trap 'rm -rf "$SCAN_TMP"' EXIT
CONFIG="$REPO_ROOT/.gitleaks.toml"
EXPECTED_TARGETS="$REPO_ROOT/docs/tasks/macmini03-orbstack-prototype.logs/phase3-secret-scan-targets.txt"

usage() {
  cat <<'EOF'
Usage: verify-secrets.sh \
  --runtime-state <state.json> \
  --runtime-receipt <ui-action.json> \
  --runtime-diagnostics <support-diagnostics.json> \
  --manifest-output <scan-manifest.txt>
EOF
}

RUNTIME_STATE=''
RUNTIME_RECEIPT=''
RUNTIME_DIAGNOSTICS=''
MANIFEST_OUTPUT=''

while (($# > 0)); do
  case "$1" in
    --runtime-state) RUNTIME_STATE=${2-}; shift 2 ;;
    --runtime-receipt) RUNTIME_RECEIPT=${2-}; shift 2 ;;
    --runtime-diagnostics) RUNTIME_DIAGNOSTICS=${2-}; shift 2 ;;
    --manifest-output) MANIFEST_OUTPUT=${2-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

for required_path in "$RUNTIME_STATE" "$RUNTIME_RECEIPT" "$RUNTIME_DIAGNOSTICS" "$MANIFEST_OUTPUT"; do
  if [[ -z "$required_path" ]]; then usage >&2; exit 2; fi
done
if [[ -L "$MANIFEST_OUTPUT" ]]; then
  printf 'refusing symlink manifest output\n' >&2
  exit 1
fi

if ! command -v gitleaks >/dev/null 2>&1; then
  printf 'gitleaks is required\n' >&2
  exit 2
fi
[[ -f "$CONFIG" && -f "$EXPECTED_TARGETS" ]] || {
  printf 'secret scan configuration or target manifest is missing\n' >&2
  exit 2
}

mkdir -p "$SCAN_TMP/leak"/{bws,github,tailscale,private-key} "$SCAN_TMP/safe"
TOKEN_BODY=$(printf 'a%.0s' {1..36})
printf 'token = "ghp_%s"\n' "$TOKEN_BODY" > "$SCAN_TMP/leak/github/fixture.txt"
BWS_BODY=$(printf 'b%.0s' {1..48})
printf 'BWS_ACCESS_TOKEN=0.%s\n' "$BWS_BODY" > "$SCAN_TMP/leak/bws/fixture.txt"
TAILSCALE_BODY=$(printf 'c%.0s' {1..48})
printf 'TAILSCALE_AUTH_KEY=%s%s\n' 'tskey-auth-' "$TAILSCALE_BODY" > "$SCAN_TMP/leak/tailscale/fixture.txt"
{
  printf '%s%s\n' '-----BEGIN ' 'PRIVATE KEY-----'
  printf '%s\n' 'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo='
  printf '%s%s\n' '-----END ' 'PRIVATE KEY-----'
} > "$SCAN_TMP/leak/private-key/fixture.txt"
printf 'status = "safe"\n' > "$SCAN_TMP/safe/fixture.txt"

for fixture in bws github tailscale private-key; do
  if gitleaks detect --config "$CONFIG" --no-banner --no-git --redact \
    --source "$SCAN_TMP/leak/$fixture" >/dev/null 2>&1; then
    printf 'secret scanner positive control did not detect: %s\n' "$fixture" >&2
    exit 1
  fi
done

gitleaks detect --config "$CONFIG" --no-banner --no-git --redact --source "$SCAN_TMP/safe"

OBSERVED_LABELS="$SCAN_TMP/observed-labels.txt"
GENERATED_MANIFEST="$SCAN_TMP/scan-manifest.txt"

scan_target() {
  local label=$1
  local path=$2
  [[ -e "$path" ]] || {
    printf 'scan target missing: %s\n' "$label" >&2
    exit 1
  }
  printf '%s\n' "$label" >> "$OBSERVED_LABELS"
  printf '%s\t%s\n' "$label" "$path" >> "$GENERATED_MANIFEST"
  gitleaks detect --config "$CONFIG" --no-banner --no-git --redact --source "$path"
}

scan_target source-tree "$REPO_ROOT"

APP_BINARY="$REPO_ROOT/dist/K-AI 설치.app/Contents/MacOS/KAIInstaller"
APP_INFO="$REPO_ROOT/dist/K-AI 설치.app/Contents/Info.plist"
APP_RESOURCES="$REPO_ROOT/dist/K-AI 설치.app/Contents/Resources"
[[ -f "$APP_BINARY" ]] || { printf 'app binary is missing\n' >&2; exit 1; }
strings "$APP_BINARY" > "$SCAN_TMP/app-strings.txt"
scan_target app-binary-strings "$SCAN_TMP/app-strings.txt"
scan_target app-info-plist "$APP_INFO"
scan_target app-resources "$APP_RESOURCES"
scan_target runtime-state "$RUNTIME_STATE"
scan_target runtime-receipt "$RUNTIME_RECEIPT"
scan_target runtime-diagnostics "$RUNTIME_DIAGNOSTICS"

LC_ALL=C sort -o "$OBSERVED_LABELS" "$OBSERVED_LABELS"
LC_ALL=C diff -u "$EXPECTED_TARGETS" "$OBSERVED_LABELS"
umask 077
cp "$GENERATED_MANIFEST" "$MANIFEST_OUTPUT"
chmod 0600 "$MANIFEST_OUTPUT"

printf 'Secret scan passed with %s targets\n' "$(wc -l < "$OBSERVED_LABELS" | tr -d ' ')"
