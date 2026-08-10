#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  verify-orbstack-isolation.sh \
    --orb-path /absolute/path/to/orb \
    --dev k-ai-dev \
    --runner k-ai-runner

Runs non-destructive isolation probes against the two already-running K-AI
OrbStack machines. It does not intentionally create, start, stop, configure,
or delete a machine. Run it only while no other actor changes guest state:
OrbStack has no atomic no-start execution primitive, so a concurrent stop in
the gap after the running-state check could be reversed by `orb -m`.
Temporary host and guest canaries are removed on exit.
EOF
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

note() {
  printf '%s\n' "$1"
}

ORB_PATH=''
DEV_MACHINE=''
RUNNER_MACHINE=''

while (($# > 0)); do
  case "$1" in
    --orb-path)
      (($# >= 2)) || die '--orb-path requires a value'
      [[ -z "$ORB_PATH" ]] || die '--orb-path was specified more than once'
      ORB_PATH=$2
      shift 2
      ;;
    --dev)
      (($# >= 2)) || die '--dev requires a value'
      [[ -z "$DEV_MACHINE" ]] || die '--dev was specified more than once'
      DEV_MACHINE=$2
      shift 2
      ;;
    --runner)
      (($# >= 2)) || die '--runner requires a value'
      [[ -z "$RUNNER_MACHINE" ]] || die '--runner was specified more than once'
      RUNNER_MACHINE=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$ORB_PATH" ]] || die '--orb-path is required'
[[ -n "$DEV_MACHINE" ]] || die '--dev is required'
[[ -n "$RUNNER_MACHINE" ]] || die '--runner is required'
[[ "$ORB_PATH" == /* ]] || die '--orb-path must be absolute'
[[ -x "$ORB_PATH" ]] || die '--orb-path must point to an executable file'

# These names are deliberately fixed. Accepting an arbitrary machine here would
# turn a verification script into a way to run probes inside unrelated guests.
[[ "$DEV_MACHINE" == 'k-ai-dev' ]] || die '--dev must be k-ai-dev'
[[ "$RUNNER_MACHINE" == 'k-ai-runner' ]] || die '--runner must be k-ai-runner'
[[ "$DEV_MACHINE" != "$RUNNER_MACHINE" ]] || die 'dev and runner must be distinct'

for required_command in python3 curl ssh-agent ssh-add ssh-keygen awk cmp ps; do
  command -v "$required_command" >/dev/null 2>&1 || die "required host command is missing: $required_command"
done

GUI_USER=$(id -un)
[[ "$GUI_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die 'the current GUI user name is not safe to use in a probe path'
[[ -n "${HOME:-}" && "$HOME" == /* && -d "$HOME" ]] || die 'HOME must be an existing absolute directory'
[[ "$GUI_USER" != 'root' ]] || die 'run this script as the OrbStack GUI user, not root'
[[ "$HOME" == "/Users/$GUI_USER" ]] || die 'HOME must be /Users/<current GUI user>'

HOST_TMP_DIR=''
HOST_CANARY_PID=''
HOST_CANARY_PORT=''
AGENT_PID=''
DEV_CANARY_DIR=''
DEV_CANARY_PID=''
DEV_CANARY_PORT=''
RUNNER_CANARY_DIR=''
RUNNER_CANARY_PID=''
RUNNER_CANARY_PORT=''
RUN_ID=''

stop_host_pid() {
  local pid=$1
  local owner_path=$2
  local command_line
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 0
  if kill -0 "$pid" >/dev/null 2>&1; then
    [[ -n "$owner_path" ]] || return 1
    command_line=$(ps -ww -p "$pid" -o command= 2>/dev/null) || return 1
    [[ "$command_line" == *"$owner_path"* ]] || return 1
    kill "$pid" >/dev/null 2>&1 || return 1
  fi
  wait "$pid" >/dev/null 2>&1 || true
}

stop_guest_canary() {
  local machine=$1
  local guest_dir=$2
  local guest_pid=$3

  [[ -n "$guest_dir" ]] || return 0
  # Never use `orb -m` for cleanup if the guest stopped during verification;
  # that command may start it and would mutate pre-existing machine state.
  orb_run_guest "$machine" env \
    "KAI_GUEST_DIR=$guest_dir" \
    "KAI_GUEST_PID=$guest_pid" \
    "KAI_RUN_ID=$RUN_ID" \
    "KAI_MACHINE=$machine" \
    sh <<'GUEST_CLEANUP' >/dev/null 2>&1
set -eu

guest_dir=${KAI_GUEST_DIR:?}
guest_pid=${KAI_GUEST_PID-}
run_id=${KAI_RUN_ID:?}
machine=${KAI_MACHINE:?}

expected_dir="/tmp/kai-orbstack-isolation.${run_id}.${machine}"
[ "$guest_dir" = "$expected_dir" ] || exit 70
[ ! -e "$guest_dir" ] && exit 0

[ -f "$guest_dir/.owner" ] || exit 72
[ "$(cat "$guest_dir/.owner")" = "$run_id" ] || exit 73

if [ -z "$guest_pid" ] && [ -s "$guest_dir/pid" ]; then
  guest_pid=$(cat "$guest_dir/pid")
fi

if [ -n "$guest_pid" ]; then
[ -n "$guest_pid" ] && printf '%s' "$guest_pid" | grep -Eq '^[0-9]+$' || exit 71
  if kill -0 "$guest_pid" >/dev/null 2>&1; then
    [ -r "/proc/$guest_pid/cmdline" ] || exit 74
    tr '\000' '\n' <"/proc/$guest_pid/cmdline" | grep -Fqx -- "$guest_dir" || exit 75
    kill "$guest_pid"
    attempts=0
    while kill -0 "$guest_pid" >/dev/null 2>&1 && [ "$attempts" -lt 30 ]; do
      sleep 0.1
      attempts=$((attempts + 1))
    done
    ! kill -0 "$guest_pid" >/dev/null 2>&1 || exit 76
  fi
fi

rm -rf -- "$guest_dir"
GUEST_CLEANUP
}

cleanup() {
  local original_rc=$?
  local cleanup_failed=0
  trap - EXIT INT TERM HUP
  set +e

  stop_guest_canary "$DEV_MACHINE" "$DEV_CANARY_DIR" "$DEV_CANARY_PID" || {
    printf 'ERROR: failed to remove the dev guest canary\n' >&2
    cleanup_failed=1
  }
  stop_guest_canary "$RUNNER_MACHINE" "$RUNNER_CANARY_DIR" "$RUNNER_CANARY_PID" || {
    printf 'ERROR: failed to remove the runner guest canary\n' >&2
    cleanup_failed=1
  }
  stop_host_pid "$AGENT_PID" "$HOST_TMP_DIR" || {
    printf 'ERROR: failed to stop the disposable ssh-agent\n' >&2
    cleanup_failed=1
  }
  stop_host_pid "$HOST_CANARY_PID" "$HOST_TMP_DIR" || {
    printf 'ERROR: failed to stop the host canary\n' >&2
    cleanup_failed=1
  }

  if [[ -n "$HOST_TMP_DIR" ]]; then
    if [[ "$HOST_TMP_DIR" == "$HOME"/.kai-orbstack-isolation.* ]]; then
      rm -rf -- "$HOST_TMP_DIR" || cleanup_failed=1
    else
      printf 'ERROR: refusing to remove an unexpected host temp path\n' >&2
      cleanup_failed=1
    fi
  fi

  if ((original_rc == 0 && cleanup_failed != 0)); then
    original_rc=1
  fi
  exit "$original_rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

wait_for_file() {
  local file=$1
  local owner_pid=$2
  local attempts=0

  while [[ ! -s "$file" && $attempts -lt 100 ]]; do
    kill -0 "$owner_pid" >/dev/null 2>&1 || return 1
    sleep 0.05
    attempts=$((attempts + 1))
  done
  [[ -s "$file" ]]
}

guest_is_running_readonly() {
  local machine=$1

  # Unknown JSON contracts fail closed instead of being treated as running.
  "$ORB_PATH" info --format json "$machine" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
state = data.get("state") if isinstance(data, dict) else None
if state is None and isinstance(data, dict) and isinstance(data.get("record"), dict):
    state = data["record"].get("state")
if isinstance(state, dict):
    state = state.get("status") or state.get("value") or state.get("name")
if str(state).lower() not in {"running", "started"}:
    raise SystemExit(1)
' >/dev/null 2>&1
}

require_running_guest() {
  local machine=$1

  # This is intentionally read-only and runs before `orb -m`, which may start a
  # stopped machine.
  guest_is_running_readonly "$machine" || die "$machine must already be running"
}

orb_run_guest() {
  local machine=$1
  shift

  # OrbStack's run command may start a stopped machine, so every invocation gets
  # its own immediately-adjacent read-only guard rather than trusting an earlier
  # phase-wide check.
  guest_is_running_readonly "$machine" || return 90
  "$ORB_PATH" -m "$machine" "$@"
}

guest_preflight() {
  local machine=$1
  orb_run_guest "$machine" sh -c 'command -v python3 >/dev/null && command -v ssh-add >/dev/null' \
    >/dev/null 2>&1 || die "$machine is missing python3 or ssh-add"
}

start_guest_canary() {
  local machine=$1
  local receipt guest_dir guest_pid guest_port

  guest_dir="/tmp/kai-orbstack-isolation.${RUN_ID}.${machine}"
  case "$machine" in
    "$DEV_MACHINE") DEV_CANARY_DIR=$guest_dir ;;
    "$RUNNER_MACHINE") RUNNER_CANARY_DIR=$guest_dir ;;
    *) die 'internal error: canary requested on a non-allowlisted machine' ;;
  esac

  receipt=$(orb_run_guest "$machine" env \
    "KAI_RUN_ID=$RUN_ID" \
    "KAI_GUEST_DIR=$guest_dir" \
    sh <<'GUEST_START'
set -eu
umask 077

run_id=${KAI_RUN_ID:?}
guest_dir=${KAI_GUEST_DIR:?}
[ -n "$run_id" ] && printf '%s' "$run_id" | grep -Eq '^[A-Za-z0-9._-]+$' || exit 60
if [ "$guest_dir" != "/tmp/kai-orbstack-isolation.${run_id}.k-ai-dev" ] && \
   [ "$guest_dir" != "/tmp/kai-orbstack-isolation.${run_id}.k-ai-runner" ]; then
  exit 65
fi

guest_pid=''
created=0

cleanup_failed_start() {
  rc=$?
  trap - EXIT INT TERM HUP
  if [ "$rc" -ne 0 ]; then
    if [ -n "$guest_pid" ] && kill -0 "$guest_pid" >/dev/null 2>&1; then
      [ -r "/proc/$guest_pid/cmdline" ] || exit 66
      tr '\000' '\n' <"/proc/$guest_pid/cmdline" | grep -Fqx -- "$guest_dir" || exit 67
      kill "$guest_pid" || exit 68
      attempts=0
      while kill -0 "$guest_pid" >/dev/null 2>&1 && [ "$attempts" -lt 30 ]; do
        sleep 0.1
        attempts=$((attempts + 1))
      done
      ! kill -0 "$guest_pid" >/dev/null 2>&1 || exit 69
      wait "$guest_pid" >/dev/null 2>&1 || true
    fi
    # `created` is set only after this exact mkdir succeeds, so the directory is
    # ours even if interruption lands before the owner marker write.
    if [ "$created" -eq 1 ]; then
      rm -rf -- "$guest_dir"
    fi
  fi
  exit "$rc"
}
trap cleanup_failed_start EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

mkdir -m 0700 -- "$guest_dir"
created=1
printf '%s\n' "$run_id" >"$guest_dir/.owner"
printf 'K-AI sibling isolation canary\n' >"$guest_dir/canary"

python3 - "$guest_dir" "$guest_dir/port" <<'PY' >/dev/null 2>&1 &
import functools
import http.server
import os
import socketserver
import sys

root, port_file = sys.argv[1:]

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, _format, *args):
        pass

handler = functools.partial(QuietHandler, directory=root)
with socketserver.ThreadingTCPServer(("0.0.0.0", 0), handler) as server:
    with open(port_file, "w", encoding="ascii") as output:
        output.write(str(server.server_address[1]))
        output.flush()
        os.fsync(output.fileno())
    server.serve_forever()
PY
guest_pid=$!
printf '%s\n' "$guest_pid" >"$guest_dir/pid"

attempts=0
while [ ! -s "$guest_dir/port" ] && [ "$attempts" -lt 100 ]; do
  kill -0 "$guest_pid" >/dev/null 2>&1 || exit 61
  sleep 0.05
  attempts=$((attempts + 1))
done
[ -s "$guest_dir/port" ] || exit 62

guest_port=$(cat "$guest_dir/port")
[ -n "$guest_port" ] && printf '%s' "$guest_port" | grep -Eq '^[0-9]+$' || exit 63
[ "$guest_port" -ge 1 ] && [ "$guest_port" -le 65535 ] || exit 64

# The listener must work from its own guest before an inter-guest denial counts.
python3 - "$guest_port" <<'PY' >/dev/null 2>&1
import sys
import urllib.request

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with opener.open(
    "http://127.0.0.1:{}/canary".format(sys.argv[1]), timeout=3
) as response:
    if response.read(1) == b"":
        raise SystemExit(1)
PY

trap - EXIT INT TERM HUP
printf '%s\t%s\n' "$guest_pid" "$guest_port"
GUEST_START
  ) || die "failed to start and self-check the $machine sibling canary"

  IFS=$'\t' read -r guest_pid guest_port <<<"$receipt"
  [[ "$guest_pid" =~ ^[0-9]+$ ]] || die "$machine returned an invalid canary PID"
  [[ "$guest_port" =~ ^[0-9]+$ ]] || die "$machine returned an invalid canary port"
  ((guest_port >= 1 && guest_port <= 65535)) || die "$machine returned an out-of-range canary port"

  case "$machine" in
    "$DEV_MACHINE")
      DEV_CANARY_PID=$guest_pid
      DEV_CANARY_PORT=$guest_port
      ;;
    "$RUNNER_MACHINE")
      RUNNER_CANARY_PID=$guest_pid
      RUNNER_CANARY_PORT=$guest_port
      ;;
    *)
      die 'internal error: canary started on a non-allowlisted machine'
      ;;
  esac
}

assert_host_files_and_agent_hidden() {
  local machine=$1
  local host_temp_base=$2

  orb_run_guest "$machine" env \
    "KAI_GUI_USER=$GUI_USER" \
    "KAI_HOST_TEMP_BASE=$host_temp_base" \
    sh <<'GUEST_FILE_CHECK' >/dev/null 2>&1
set -eu

gui_user=${KAI_GUI_USER:?}
host_temp_base=${KAI_HOST_TEMP_BASE:?}

[ -n "$gui_user" ] && printf '%s' "$gui_user" | grep -Eq '^[A-Za-z0-9._-]+$' || exit 30
case "$host_temp_base" in
  .kai-orbstack-isolation.*) ;;
  *) exit 31 ;;
esac

# Isolated machines must not receive OrbStack's Mac filesystem integration.
[ ! -e /mnt/mac ] || exit 32

for host_path in \
  "/Users/$gui_user/$host_temp_base/host-sentinel" \
  "/Users/$gui_user/$host_temp_base/ephemeral-agent.pub" \
  "/mnt/mac/Users/$gui_user/$host_temp_base/host-sentinel" \
  "/mnt/mac/Users/$gui_user/$host_temp_base/ephemeral-agent.pub"
do
  [ ! -r "$host_path" ] || exit 33
done

[ -z "${SSH_AUTH_SOCK:-}" ] || exit 34
if ssh-add -L >/dev/null 2>&1; then
  exit 35
fi
GUEST_FILE_CHECK
}

probe_guest_url() {
  local machine=$1
  local url=$2

  orb_run_guest "$machine" python3 -c '
import sys
import urllib.request

try:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(sys.argv[1], timeout=3) as response:
        response.read(1)
except Exception:
    raise SystemExit(42)
' "$url" >/dev/null 2>&1
}

expect_guest_url_blocked() {
  local machine=$1
  local url=$2
  local label=$3
  local probe_rc

  set +e
  probe_guest_url "$machine" "$url"
  probe_rc=$?
  set -e

  if ((probe_rc == 0)); then
    die "$machine unexpectedly reached the $label canary"
  fi
  if ((probe_rc != 42)); then
    die "$machine could not execute the $label isolation probe"
  fi
}

HOST_TMP_DIR=$(mktemp -d "$HOME/.kai-orbstack-isolation.XXXXXX")
RUN_ID=${HOST_TMP_DIR##*/}
chmod 0755 "$HOST_TMP_DIR"
printf 'K-AI host isolation canary\n' >"$HOST_TMP_DIR/host-sentinel"
chmod 0644 "$HOST_TMP_DIR/host-sentinel"

mkdir "$HOST_TMP_DIR/private"
chmod 0700 "$HOST_TMP_DIR/private"
ssh-keygen -q -t ed25519 -N '' -f "$HOST_TMP_DIR/private/agent-key" >/dev/null 2>&1
ssh-keygen -y -f "$HOST_TMP_DIR/private/agent-key" 2>/dev/null \
  | awk 'NF >= 2 { print $1 " " $2 }' >"$HOST_TMP_DIR/ephemeral-agent.pub"
chmod 0644 "$HOST_TMP_DIR/ephemeral-agent.pub"

AGENT_SOCKET="$HOST_TMP_DIR/private/agent.sock"
ssh-agent -a "$AGENT_SOCKET" -D >/dev/null 2>&1 &
AGENT_PID=$!
attempts=0
while [[ ! -S "$AGENT_SOCKET" && $attempts -lt 100 ]]; do
  kill -0 "$AGENT_PID" >/dev/null 2>&1 || die 'the disposable ssh-agent exited during startup'
  sleep 0.05
  attempts=$((attempts + 1))
done
[[ -S "$AGENT_SOCKET" ]] || die 'the disposable ssh-agent did not create its socket'

export SSH_AUTH_SOCK=$AGENT_SOCKET
ssh-add "$HOST_TMP_DIR/private/agent-key" >/dev/null 2>&1 || die 'failed to load the ephemeral key into the disposable agent'
ssh-add -L 2>/dev/null | awk 'NF >= 2 { print $1 " " $2 }' \
  | cmp -s - "$HOST_TMP_DIR/ephemeral-agent.pub" \
  || die 'the disposable ssh-agent positive control failed'

HOST_CANARY_ROOT="$HOST_TMP_DIR/host-canary"
mkdir "$HOST_CANARY_ROOT"
printf 'K-AI host network isolation canary\n' >"$HOST_CANARY_ROOT/canary"
HOST_CANARY_PORT_FILE="$HOST_TMP_DIR/host-canary.port"

python3 - "$HOST_CANARY_ROOT" "$HOST_CANARY_PORT_FILE" <<'PY' >/dev/null 2>&1 &
import functools
import http.server
import os
import socketserver
import sys

root, port_file = sys.argv[1:]

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, _format, *args):
        pass

handler = functools.partial(QuietHandler, directory=root)
with socketserver.ThreadingTCPServer(("0.0.0.0", 0), handler) as server:
    with open(port_file, "w", encoding="ascii") as output:
        output.write(str(server.server_address[1]))
        output.flush()
        os.fsync(output.fileno())
    server.serve_forever()
PY
HOST_CANARY_PID=$!

wait_for_file "$HOST_CANARY_PORT_FILE" "$HOST_CANARY_PID" || die 'the host canary did not start'
HOST_CANARY_PORT=$(cat "$HOST_CANARY_PORT_FILE")
[[ "$HOST_CANARY_PORT" =~ ^[0-9]+$ ]] || die 'the host canary returned an invalid port'
((HOST_CANARY_PORT >= 1 && HOST_CANARY_PORT <= 65535)) || die 'the host canary returned an out-of-range port'
curl --fail --silent --noproxy '*' --max-time 3 "http://127.0.0.1:$HOST_CANARY_PORT/canary" \
  | cmp -s - "$HOST_CANARY_ROOT/canary" || die 'the host HTTP canary positive control failed'

require_running_guest "$DEV_MACHINE"
require_running_guest "$RUNNER_MACHINE"
guest_preflight "$DEV_MACHINE"
guest_preflight "$RUNNER_MACHINE"

start_guest_canary "$DEV_MACHINE"
start_guest_canary "$RUNNER_MACHINE"
note 'PASS: host and sibling positive controls are live'

HOST_TEMP_BASE=${HOST_TMP_DIR##*/}
assert_host_files_and_agent_hidden "$DEV_MACHINE" "$HOST_TEMP_BASE" \
  || die "$DEV_MACHINE can access a Mac sentinel or forwarded SSH agent"
assert_host_files_and_agent_hidden "$RUNNER_MACHINE" "$HOST_TEMP_BASE" \
  || die "$RUNNER_MACHINE can access a Mac sentinel or forwarded SSH agent"
note 'PASS: Mac files and the disposable SSH agent are unavailable in both guests'

expect_guest_url_blocked "$DEV_MACHINE" "http://host.orb.internal:$HOST_CANARY_PORT/canary" 'Mac host'
expect_guest_url_blocked "$RUNNER_MACHINE" "http://host.orb.internal:$HOST_CANARY_PORT/canary" 'Mac host'
expect_guest_url_blocked "$DEV_MACHINE" "http://$RUNNER_MACHINE.orb.local:$RUNNER_CANARY_PORT/canary" 'sibling guest'
expect_guest_url_blocked "$RUNNER_MACHINE" "http://$DEV_MACHINE.orb.local:$DEV_CANARY_PORT/canary" 'sibling guest'
note 'PASS: host and sibling guest network access is blocked'

probe_guest_url "$DEV_MACHINE" 'https://example.com/' \
  || die "$DEV_MACHINE cannot reach the public HTTPS positive control"
probe_guest_url "$RUNNER_MACHINE" 'https://example.com/' \
  || die "$RUNNER_MACHINE cannot reach the public HTTPS positive control"
note 'PASS: public HTTPS works in both guests'
note 'PASS: OrbStack isolation verification completed'
