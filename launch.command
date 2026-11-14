#!/usr/bin/env bash
set -euo pipefail

GUI=false
UPDATE_ONLY=false
PLAN_UPDATE=false
AGENT=false
AGENT_ATTACH=false
case "${1:-}" in
  --gui) GUI=true ;;
  --update-only) UPDATE_ONLY=true ;;
  --plan-update) PLAN_UPDATE=true ;;
  --agent) AGENT=true ;;
  --agent-attach) AGENT_ATTACH=true ;;
  "") ;;
  *)
    printf 'Usage: %s [--gui|--update-only|--plan-update|--agent|--agent-attach]\n' "$0" >&2
    exit 2
    ;;
esac

ONION_FILE="${SILK_CHAT_ONION_FILE:-$HOME/.config/silk-chat/onion}"
TOR_APP_FILE="${SILK_CHAT_TOR_APP_FILE:-$HOME/.config/silk-chat/tor-browser-app}"
TOR_PROFILE="${SILK_CHAT_TOR_PROFILE:-$HOME/.config/silk-chat/tor-profile}"
KIOSK_FLAG="${SILK_CHAT_KIOSK_FLAG-}"
TOR_APP_ALT="$HOME/Applications/Tor Browser.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROXY_BIN="${SILK_CHAT_PROXY_BIN:-$SCRIPT_DIR/silk-chat-proxy}"
WEBUI_DIR="${SILK_CHAT_WEBUI_DIR:-$SCRIPT_DIR/webui}"
TOR_BINARY="${SILK_CHAT_TOR_BINARY:-}"
TOR_GEOIP_DIR="${SILK_CHAT_TOR_GEOIP_DIR:-}"
TOR_DATA="${SILK_CHAT_TOR_DATA:-$HOME/.config/silk-chat/tor}"
# The resident proxy: a LaunchAgent (install.command) runs this script with
# --agent from login, so the proxy and its Tor are already connected when the
# app is opened. It leaves its port and access token here for the launcher.
AGENT_LABEL="${SILK_CHAT_AGENT_LABEL:-local.silk-chat.agent}"
AGENT_HANDSHAKE="${SILK_CHAT_AGENT_HANDSHAKE:-$HOME/.config/silk-chat/agent-handshake}"
# What the resident proxy was started from (the proxy's and this script's
# SHA-256), so a launch restarts it only when an update changed either one.
AGENT_STAMP="${SILK_CHAT_AGENT_STAMP:-$AGENT_HANDSHAKE.build}"
local_proxy_pid=""
local_handshake=""
local_url=""
browser_pid=""
open_pid=""

LAUNCHER_SIGNING_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILvj4ZhAL+Jve263cPzibOBvqrSHLf20FqJ5nev1l/dq"
# Updates come from the public GitHub release over the normal internet, not
# Tor (docs/security.md, "App updates"). The files are public, the manifest is
# signed and every file is checked against it, and no request carries a
# cookie, token, account or onion address.
UPDATE_BASE_URL="${SILK_CHAT_UPDATE_BASE_URL:-https://github.com/patrickkkim/silk-chat-launcher/releases/download/launcher-latest}"
UPDATE_CHECK_FILE="${SILK_CHAT_UPDATE_CHECK_FILE:-$HOME/.config/silk-chat/last-launcher-check}"
UPDATE_VERSION_FILE="${SILK_CHAT_UPDATE_VERSION_FILE:-$HOME/.config/silk-chat/launcher-version}"
UPDATE_LOG="${SILK_CHAT_UPDATE_LOG:-$HOME/Library/Logs/Silk Chat/updater.log}"
PROXY_LOG="${SILK_CHAT_PROXY_LOG:-$HOME/Library/Logs/Silk Chat/proxy.log}"
SESSION_FILE="${SILK_CHAT_SESSION_FILE:-$HOME/.config/silk-chat/session}"
PENDING_RESOURCES="${SILK_CHAT_PENDING_RESOURCES:-$HOME/.config/silk-chat/pending-resources}"
ROLLBACK_RESOURCES="${SILK_CHAT_ROLLBACK_RESOURCES:-$HOME/.config/silk-chat/rollback-resources}"
STATUS_FILE="${SILK_CHAT_STATUS_FILE:-$HOME/.config/silk-chat/status}"
UPDATE_INTERVAL=0

say_error() {
  local message="$1"
  if [ "$GUI" = true ]; then
    osascript - "$message" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display dialog (item 1 of argv) with title "Silk Chat" buttons {"OK"} default button "OK" with icon stop
end run
APPLESCRIPT
  else
    printf 'Silk Chat: %s\n' "$message" >&2
  fi
}

normalize_onion() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

valid_onion() {
  [[ "$1" =~ ^[a-z2-7]{56}\.onion$ ]]
}

find_tor_browser() {
  local app
  for app in \
    "${SILK_CHAT_TOR_BROWSER_APP:-}" \
    "$(head -1 "$TOR_APP_FILE" 2>/dev/null || true)" \
    "/Applications/Tor Browser.app" \
    "$TOR_APP_ALT"; do
    if [ -n "$app" ] && [ -x "$app/Contents/MacOS/firefox" ]; then
      printf '%s\n' "$app/Contents/MacOS/firefox"
      return 0
    fi
  done
  return 1
}

browser_pid_for_profile() {
  local pid command binary
  [ -n "${browser:-}" ] || return 1
  binary="${browser_real:-$browser}"
  while read -r pid command; do
    case "$command" in
      "$binary "*|"$browser "*) ;;
      *) continue ;;
    esac
    case " $command " in
      *" -profile $TOR_PROFILE "*) printf '%s\n' "$pid"; return 0 ;;
    esac
  done < <(/bin/ps -axo pid=,command=)
  return 1
}

wait_for_browser_pid() {
  local attempts="${1:-150}" attempt pid
  for ((attempt = 0; attempt < attempts; attempt++)); do
    if pid="$(browser_pid_for_profile)"; then
      printf '%s\n' "$pid"
      return 0
    fi
    if [ -n "${open_pid:-}" ] && ! kill -0 "$open_pid" 2>/dev/null; then
      local status=0
      wait "$open_pid" 2>/dev/null || status=$?
      [ "$status" -eq 0 ] || return 1
    fi
    sleep 0.2
  done
  return 1
}

launch_browser() {
  local args=(-no-remote -profile "$TOR_PROFILE")
  if [ -n "$KIOSK_FLAG" ]; then
    args+=("$KIOSK_FLAG")
  fi
  # LaunchServices makes Tor Browser, not this unsigned wrapper, responsible
  # for its own app-bundle writes under macOS App Management.
  /usr/bin/open -W -n -a "$browser_app" --args "${args[@]}" "$@" &
  open_pid=$!
}

monitor_browser() {
  local pid missing=0
  while :; do
    if pid="$(browser_pid_for_profile)"; then
      missing=0
      if [ "$pid" != "$browser_pid" ]; then
        browser_pid="$pid"
        write_session_file "$browser_pid" "$browser_app" "$browser_url"
      fi
    else
      missing=$((missing + 1))
      if [ "$missing" -eq 10 ]; then
        # Keep the local proxy and its Tor process warm while the app is
        # resident. Closing the window does not stop them; Cmd+Q stops a
        # proxy this launcher started (the resident one runs until logout).
        log_proxy "launch: browser closed; keeping the local proxy and Tor warm"
        write_session_file 0 "$browser_app" "$browser_url"
      fi
    fi
    sleep 1
  done
}

stop_browser() {
  local pid="${browser_pid:-}"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    pid="$(browser_pid_for_profile 2>/dev/null || true)"
  fi
  [ -n "$pid" ] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  for _ in {1..12}; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.2
  done
  kill -KILL "$pid" 2>/dev/null || true
  return 0
}

browser_running() {
  pgrep -f "^${TOR_PROCESS_PATTERN}" >/dev/null 2>&1
}

# Tor Browser's own tor processes. The proxy runs the same binary for its Tor
# (started with -f <its data directory>/torrc); that one is not Tor Browser's
# and must be left alone.
browser_tor_pids() {
  local pid command
  while read -r pid command; do
    case "$command" in
      "$TOR_TOR_PATTERN "*|"$TOR_TOR_PATTERN") ;;
      *) continue ;;
    esac
    case "$command " in
      *" -f $TOR_DATA/torrc "*) continue ;;
    esac
    printf '%s\n' "$pid"
  done < <(/bin/ps -axo pid=,command=)
}

tor_running() {
  [ -n "$(browser_tor_pids)" ]
}

stop_tor_browser() {
  if browser_running; then
    osascript -e 'tell application "Tor Browser" to quit' >/dev/null 2>&1 || true
    for _ in {1..30}; do
      browser_running || break
      sleep 1
    done
    if browser_running; then
      return 1
    fi
  fi

  for _ in {1..5}; do
    tor_running || return 0
    sleep 1
  done

  local pid
  for pid in $(browser_tor_pids); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for _ in {1..10}; do
    tor_running || return 0
    sleep 1
  done
  return 1
}

stop_local_proxy() {
  if [ -n "${local_proxy_pid:-}" ]; then
    kill "$local_proxy_pid" 2>/dev/null || true
    wait "$local_proxy_pid" 2>/dev/null || true
    local_proxy_pid=""
  fi
  if [ -n "${local_handshake:-}" ]; then
    rm -f "$local_handshake"
    local_handshake=""
  fi
}

write_session_file() {
  local pid="$1" app="$2" url="$3" tmp
  if [ -z "${SESSION_FILE:-}" ] || [ -z "$pid" ] || [ -z "$app" ] || [ -z "$url" ]; then
    return 0
  fi

  tmp="$SESSION_FILE.tmp.$$"
  mkdir -p "$(dirname "$SESSION_FILE")" 2>/dev/null || return 0
  (umask 077 && printf '%s\n%s\n%s\n%s\n' "$$" "$pid" "$app" "$url" > "$tmp") || {
    rm -f "$tmp"
    return 0
  }
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$SESSION_FILE" 2>/dev/null || rm -f "$tmp"
}

clear_session_file() {
  local owner
  if [ -z "${SESSION_FILE:-}" ] || [ ! -f "$SESSION_FILE" ]; then
    return 0
  fi
  owner="$(sed -n '1p' "$SESSION_FILE" 2>/dev/null || true)"
  if [ "$owner" != "$$" ]; then
    return 0
  fi
  rm -f "$SESSION_FILE"
}

set_session_homepage() {
  local url="$1"
  local user_js="$TOR_PROFILE/user.js"
  local tmp="$TOR_PROFILE/user.js.tmp.$$"

  [ -f "$user_js" ] || return 0
  awk -v url="$url" '
    $0 == "// BEGIN SILK CHAT HOMEPAGE" { skip = 1; next }
    $0 == "// END SILK CHAT HOMEPAGE" { skip = 0; next }
    skip { next }
    { print }
    END {
      print "// BEGIN SILK CHAT HOMEPAGE"
      printf "user_pref(\"browser.startup.page\", 1);\n"
      printf "user_pref(\"browser.startup.homepage\", \"%s\");\n", url
      print "// END SILK CHAT HOMEPAGE"
    }
  ' "$user_js" > "$tmp" 2>/dev/null || {
    rm -f "$tmp"
    return 0
  }
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$user_js" 2>/dev/null || rm -f "$tmp"
}

configure_runtime_profile() {
  local user_js="$TOR_PROFILE/user.js"
  local tmp="$TOR_PROFILE/user.js.tmp.$$"

  [ -f "$user_js" ] || return 0
  grep -v -E 'network\.http\.max-persistent-connections-per-server|network\.http\.max-connections-per-server' \
    "$user_js" > "$tmp" 2>/dev/null || true
  cat >> "$tmp" <<'EOF'
user_pref("network.http.max-persistent-connections-per-server", 24);
user_pref("network.http.max-connections-per-server", 24);
EOF
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$user_js" 2>/dev/null || rm -f "$tmp"
}

cleanup() {
  status_hide
  stop_browser
  stop_local_proxy
  clear_session_file
}

# Give a new owned Tor what Tor Browser's has already learned, each only when
# the owned Tor has none of its own:
#   - the network directory, so it does not download it again;
#   - the state file: Tor Browser's entry guards, so no further relays learn
#     this address, and its measured circuit build times, so Tor replaces a
#     stuck circuit in seconds from the first launch instead of after a minute.
seed_owned_tor() {
  local source="${SILK_CHAT_TOR_SEED_DIR:-$HOME/Library/Application Support/TorBrowser-Data/Tor}"
  local copied=0 file

  [ -d "$source" ] || return 0
  mkdir -p "$TOR_DATA" 2>/dev/null || return 0
  chmod 700 "$TOR_DATA" 2>/dev/null || true
  if [ ! -f "$TOR_DATA/cached-microdesc-consensus" ]; then
    for file in cached-certs cached-microdesc-consensus cached-microdescs cached-microdescs.new; do
      if [ -f "$source/$file" ]; then
        if cp -p "$source/$file" "$TOR_DATA/$file" 2>/dev/null; then
          chmod 600 "$TOR_DATA/$file" 2>/dev/null || true
          copied=1
        fi
      fi
    done
    if [ "$copied" = 1 ]; then
      log_proxy "launch: seeded the owned Tor cache from Tor Browser"
    fi
  fi
  if [ ! -f "$TOR_DATA/state" ] && [ -f "$source/state" ]; then
    if cp -p "$source/state" "$TOR_DATA/state" 2>/dev/null; then
      chmod 600 "$TOR_DATA/state" 2>/dev/null || true
      log_proxy "launch: seeded the owned Tor guards and circuit timings from Tor Browser"
    fi
  fi
}

agent_loaded() {
  /bin/launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1
}

file_sha() {
  /usr/bin/shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

# Records what the resident proxy is about to run (see AGENT_STAMP).
write_agent_stamp() {
  local tmp="$AGENT_STAMP.tmp.$$"
  if printf 'proxy_sha256=%s\nlauncher_sha256=%s\n' "$(file_sha "$PROXY_BIN")" "$(file_sha "$0")" \
    > "$tmp" 2>/dev/null; then
    mv "$tmp" "$AGENT_STAMP" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# True when the resident proxy runs another proxy or launcher than the ones
# installed now. Compared by content: the updater used to rewrite files whose
# build number rose with every push even when nothing in them changed, and a
# timestamp check then restarted the proxy, and its Tor, cold on every open.
agent_outdated() {
  [ -f "$AGENT_HANDSHAKE" ] || return 1
  if [ ! -f "$AGENT_STAMP" ]; then
    # Started by an older launcher, which recorded nothing: timestamps, once.
    [ "$PROXY_BIN" -nt "$AGENT_HANDSHAKE" ] || [ "$0" -nt "$AGENT_HANDSHAKE" ]
    return
  fi
  [ "$(sed -n 's/^proxy_sha256=//p' "$AGENT_STAMP" | head -1)" != "$(file_sha "$PROXY_BIN")" ] ||
    [ "$(sed -n 's/^launcher_sha256=//p' "$AGENT_STAMP" | head -1)" != "$(file_sha "$0")" ]
}

# Running proxies of this app bundle that use the device vault: "agent" lists
# the resident one, "app" the ones a launcher started itself. The vault's
# device token rotates on every exchange, and a token another proxy rotated
# away signs the user out, so the two kinds must never run at the same time.
# (A proxy with its own --auth-session-file does not share the vault.)
silk_proxy_pids() {
  local kind="$1" pid command
  while read -r pid command; do
    case "$command" in
      "$PROXY_BIN "*) ;;
      *) continue ;;
    esac
    case "$command " in
      *" --static-dir "*) ;;
      *) continue ;;
    esac
    case "$command " in
      *" --auth-session-file "*) continue ;;
    esac
    case "$command " in
      *" --handshake $AGENT_HANDSHAKE "*) [ "$kind" = agent ] || continue ;;
      *) [ "$kind" = app ] || continue ;;
    esac
    printf '%s\n' "$pid"
  done < <(/bin/ps -axo pid=,command=)
}

# Stops the resident proxy so a launcher can start its own instead. It stays
# stopped until the next launch, login or install.
stop_agent_proxy() {
  /bin/launchctl kill SIGTERM "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1 || true
  for _ in {1..100}; do
    [ -z "$(silk_proxy_pids agent)" ] && return 0
    sleep 0.1
  done
  return 1
}

# Reads the resident proxy's handshake and asks it to warm its connections.
# Succeeds only if a proxy answers with that token, and sets local_url.
agent_proxy_answers() {
  local port token code
  [ -s "$AGENT_HANDSHAKE" ] || return 1
  read -r port token < "$AGENT_HANDSHAKE" || return 1
  [[ "$port" =~ ^[0-9]+$ && "$token" =~ ^[0-9a-f]{64}$ ]] || return 1
  code="$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 2 \
    -b "silk_local_access=$token" "http://127.0.0.1:$port/__silk__/warm" 2>/dev/null || true)"
  [ "$code" = "200" ] || return 1
  local_url="http://127.0.0.1:$port/__silk__/$token"
  return 0
}

# Uses the resident proxy when there is one. The warm-up call in
# agent_proxy_answers lets it rebuild its connections while the browser
# starts.
attach_agent_proxy() {
  local_url=""
  [ "${SILK_CHAT_DISABLE_LOCAL_UI:-}" != "1" ] || return 1
  [ "${SILK_CHAT_DISABLE_AGENT:-}" != "1" ] || return 1
  agent_loaded || return 1

  if agent_outdated; then
    # An update changed the proxy or this script after the agent started.
    log_proxy "launch: restarting the resident proxy after an update"
    rm -f "$AGENT_HANDSHAKE" "$AGENT_STAMP"
    /bin/launchctl kickstart -k "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1 || true
  elif ! agent_proxy_answers; then
    /bin/launchctl kickstart "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1 || true
  else
    return 0
  fi
  for _ in {1..50}; do
    if agent_proxy_answers; then
      return 0
    fi
    sleep 0.1
  done
  # Never leave it running next to the proxy this launch starts instead.
  log_proxy "launch: the resident proxy did not answer; stopping it"
  stop_agent_proxy || log_proxy "launch: the resident proxy did not stop"
  return 1
}

# The LaunchAgent's entry point: become the proxy. launchd restarts it if it
# crashes; a clean exit (not set up, nothing to run) is left alone.
run_agent() {
  local onion_value browser_bin browser_dir app_dir
  onion_value="$(normalize_onion "$(cat "$ONION_FILE" 2>/dev/null || true)")"
  if ! valid_onion "$onion_value"; then
    log_proxy "agent: Silk Chat is not set up; not starting"
    exit 0
  fi
  if [ ! -x "$PROXY_BIN" ] || [ ! -f "$WEBUI_DIR/index.html" ]; then
    log_proxy "agent: the proxy or the frontend is missing; not starting"
    exit 0
  fi
  if [ ! -x "$TOR_BINARY" ]; then
    browser_bin="$(find_tor_browser)" || {
      log_proxy "agent: Tor Browser is not installed; not starting"
      exit 0
    }
    app_dir="$(cd "$(dirname "$browser_bin")/../.." && pwd)"
    browser_dir="$(cd "$(dirname "$browser_bin")" && pwd -P)"
    TOR_BINARY="$browser_dir/Tor/tor"
    TOR_GEOIP_DIR="${TOR_GEOIP_DIR:-$app_dir/Contents/Resources/TorBrowser/Tor}"
  fi
  if [ ! -x "$TOR_BINARY" ]; then
    # Without its own Tor there is nothing to keep connected.
    log_proxy "agent: Tor Browser's tor is missing; not starting"
    exit 0
  fi

  # An app started before the agent (for example, open while installing)
  # runs its own proxy on the same device vault; wait for it to quit.
  local waited=false
  while [ -n "$(silk_proxy_pids app)" ]; do
    if [ "$waited" = false ]; then
      log_proxy "agent: Silk Chat's own proxy is running; starting when it exits"
      waited=true
    fi
    sleep "${SILK_CHAT_AGENT_WAIT_INTERVAL:-2}"
  done

  mkdir -p "$TOR_DATA" "$(dirname "$AGENT_HANDSHAKE")" 2>/dev/null || true
  chmod 700 "$TOR_DATA" 2>/dev/null || true
  seed_owned_tor
  rm -f "$AGENT_HANDSHAKE"
  local proxy_args=(
    --static-dir "$WEBUI_DIR"
    --onion-file "$ONION_FILE"
    --handshake "$AGENT_HANDSHAKE"
    --tor-binary "$TOR_BINARY"
    --tor-data "$TOR_DATA"
    --tor-socks-timeout 20s
  )
  if [ -d "$TOR_GEOIP_DIR" ]; then
    proxy_args+=(--tor-geoip-dir "$TOR_GEOIP_DIR")
  fi
  log_proxy "agent: starting the resident proxy"
  write_agent_stamp
  export SILK_CHAT_PROXY_LOG="$PROXY_LOG"
  exec "$PROXY_BIN" "${proxy_args[@]}" >/dev/null 2>&1
}

start_local_proxy() {
  local_handshake="${TMPDIR:-/tmp}/silk-chat-proxy.$$"
  local_url=""

  [ "${SILK_CHAT_DISABLE_LOCAL_UI:-}" != "1" ] || return 1
  [ -x "$PROXY_BIN" ] && [ -f "$WEBUI_DIR/index.html" ] || return 1

  rm -f "$local_handshake"
  mkdir -p "$TOR_DATA" 2>/dev/null || true
  chmod 700 "$TOR_DATA" 2>/dev/null || true
  seed_owned_tor
  log_proxy "launch: starting local proxy"
  local proxy_args=(
    --static-dir "$WEBUI_DIR"
    --onion-file "$ONION_FILE"
    --handshake "$local_handshake"
  )
  if [ -x "$TOR_BINARY" ]; then
    log_proxy "launch: using Tor Browser's Tor as the owned transport"
    proxy_args+=(
      --tor-binary "$TOR_BINARY"
      --tor-data "$TOR_DATA"
      --tor-socks-timeout 20s
    )
    if [ -d "$TOR_GEOIP_DIR" ]; then
      proxy_args+=(--tor-geoip-dir "$TOR_GEOIP_DIR")
    fi
  else
    log_proxy "launch: owned Tor unavailable; using Tor Browser's SOCKS"
    proxy_args+=(--tor-socks 127.0.0.1:9150)
  fi
  SILK_CHAT_PROXY_LOG="$PROXY_LOG" "$PROXY_BIN" "${proxy_args[@]}" >/dev/null 2>&1 &
  local_proxy_pid=$!

  for _ in {1..50}; do
    [ -s "$local_handshake" ] && break
    kill -0 "$local_proxy_pid" 2>/dev/null || break
    sleep 0.1
  done

  if [ ! -s "$local_handshake" ]; then
    stop_local_proxy
    return 1
  fi

  local port token
  read -r port token < "$local_handshake"
  rm -f "$local_handshake"
  local_handshake=""
  if ! [[ "$port" =~ ^[0-9]+$ && "$token" =~ ^[0-9a-f]{64}$ ]]; then
    stop_local_proxy
    return 1
  fi
  local_url="http://127.0.0.1:$port/__silk__/$token"
  return 0
}

log_update() {
  mkdir -p "$(dirname "$UPDATE_LOG")" 2>/dev/null || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$UPDATE_LOG" 2>/dev/null || true
}

log_proxy() {
  mkdir -p "$(dirname "$PROXY_LOG")" 2>/dev/null || return 0
  if [ -f "$PROXY_LOG" ] && [ "$(wc -c <"$PROXY_LOG" 2>/dev/null | tr -d ' ')" -gt 1048576 ]; then
    mv -f "$PROXY_LOG" "$PROXY_LOG.1" 2>/dev/null || true
  fi
  (umask 077 && printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$PROXY_LOG") 2>/dev/null || true
  chmod 600 "$PROXY_LOG" 2>/dev/null || true
}

# The native panel (launcher.m) shows title, a progress bar and detail when
# progress= is present: 0-100, or -1 for an animated bar while the size or the
# length of a step is unknown. Panels from before that read only message, so
# message carries the same text on one line.
status_write() {
  local phase="$1" message="$2" visible="$3" title="${4-}" detail="${5-}" progress="${6-}" tmp
  mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null || return 0
  tmp="$STATUS_FILE.$$"
  {
    printf 'phase=%s\n' "$phase"
    printf 'message=%s\n' "$message"
    printf 'visible=%s\n' "$visible"
    if [ -n "$progress" ]; then
      printf 'title=%s\n' "$title"
      printf 'detail=%s\n' "$detail"
      printf 'progress=%s\n' "$progress"
    fi
    printf 'updated=%s\n' "$(date +%s)"
  } > "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || true
    return 0
  }
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$STATUS_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

status_set() {
  status_write "$1" "$2" 1
}

# Every update phase shows a bar and a line of detail.
status_progress() {
  local phase="$1" title="$2" detail="$3" progress="$4" message="$2"
  if [ -n "$detail" ]; then
    message="$title — $detail"
  fi
  status_write "$phase" "$message" 1 "$title" "$detail" "$progress"
}

status_hide() {
  status_write "idle" "" 0
}

status_is_update_phase() {
  local phase
  [ -f "$STATUS_FILE" ] || return 1
  phase="$(sed -n 's/^phase=//p' "$STATUS_FILE" 2>/dev/null | head -1)"
  case "$phase" in
    downloading|installing|downloaded) return 0 ;;
  esac
  return 1
}

status_notice() {
  status_set downloaded "$1"
  sleep 3
  status_hide
}

valid_sha() {
  case "$1" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

# Both shipped artifacts decide whether a download is needed. The frontend
# version file alone missed proxy-only releases: the launcher updated, said
# "up to date", and left the old proxy running. New installs also record the
# bundle hash; older installs fall back to the version file and index.
resource_needs() {
  local resources_version="$1" webui_sha="$2" proxy_sha="$3" resources_dir="$4"
  local current_version="" current_webui="" current_proxy=""
  RESOURCE_WEBUI_NEEDED=0
  RESOURCE_PROXY_NEEDED=0
  RESOURCE_VERSION_NEEDED=0

  if [ -f "$resources_dir/webui-version.txt" ]; then
    current_version="$(shasum -a 256 "$resources_dir/webui-version.txt" | awk '{print $1}')"
  fi
  if [ -f "$resources_dir/webui/index.html" ] &&
    [ -f "$resources_dir/webui/.silk-bundle-sha256" ]; then
    current_webui="$(cat "$resources_dir/webui/.silk-bundle-sha256" 2>/dev/null || true)"
  fi
  if [ -f "$resources_dir/silk-chat-proxy" ]; then
    current_proxy="$(shasum -a 256 "$resources_dir/silk-chat-proxy" | awk '{print $1}')"
  fi

  [ -n "$resources_version" ] && [ -n "$webui_sha" ] && [ -n "$proxy_sha" ] || return 0

  if [ -z "$current_webui" ] && [ "$current_version" = "$resources_version" ] &&
    [ -f "$resources_dir/webui/index.html" ]; then
    current_webui="$webui_sha"
  fi

  if [ "$current_version" != "$resources_version" ]; then
    RESOURCE_VERSION_NEEDED=1
  fi
  if [ "$current_webui" != "$webui_sha" ]; then
    RESOURCE_WEBUI_NEEDED=1
  fi
  if [ "$current_proxy" != "$proxy_sha" ]; then
    RESOURCE_PROXY_NEEDED=1
  fi
}

resources_are_current() {
  [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || return 1
  resource_needs "$@"
  [ "$RESOURCE_WEBUI_NEEDED" -eq 0 ] &&
    [ "$RESOURCE_PROXY_NEEDED" -eq 0 ] &&
    [ "$RESOURCE_VERSION_NEEDED" -eq 0 ]
}

pending_is_current() {
  local resources_version="$1" webui_sha="$2" proxy_sha="$3" pending="$4"
  [ -n "$resources_version" ] && [ -n "$webui_sha" ] && [ -n "$proxy_sha" ] || return 1
  [ -d "$pending" ] || return 1
  resource_needs "$resources_version" "$webui_sha" "$proxy_sha" "$pending"
  [ "$RESOURCE_WEBUI_NEEDED" -eq 0 ] &&
    [ "$RESOURCE_PROXY_NEEDED" -eq 0 ] &&
    [ "$RESOURCE_VERSION_NEEDED" -eq 0 ]
}

# Support and test entry point: decide from a local manifest without fetching,
# verifying or applying anything.
plan_update() {
  local manifest="${SILK_CHAT_UPDATE_PLAN_MANIFEST:-}"
  local resources_dir resources_version webui_sha proxy_sha
  if [ ! -f "$manifest" ]; then
    printf 'plan: set SILK_CHAT_UPDATE_PLAN_MANIFEST to a manifest file\n' >&2
    return 2
  fi
  resources_dir="$(cd "$(dirname "$0")" && pwd)" || return 2
  resources_version="$(sed -n 's/^resources_version=//p' "$manifest" | head -1)"
  webui_sha="$(sed -n 's/^webui_sha256=//p' "$manifest" | head -1)"
  proxy_sha="$(sed -n 's/^proxy_sha256=//p' "$manifest" | head -1)"
  if resources_are_current "$resources_version" "$webui_sha" "$proxy_sha" "$resources_dir"; then
    printf 'resources_needed=0\n'
  else
    printf 'resources_needed=1\n'
  fi
}

apply_pending_resources() {
  local resources_dir pending rollback
  resources_dir="$(cd "$(dirname "$0")" && pwd)" || return 0
  case "$resources_dir" in
    */Contents/Resources) ;;
    *) return 0 ;;
  esac

  pending="$PENDING_RESOURCES"
  [ -f "$pending/webui/index.html" ] || return 0
  [ -x "$pending/silk-chat-proxy" ] || return 0
  [ -f "$pending/webui-version.txt" ] || return 0

  rollback="$ROLLBACK_RESOURCES"
  rm -rf "$rollback" 2>/dev/null || true
  mkdir -p "$rollback" || {
    log_update "could not create the resource rollback directory"
    return 0
  }

  log_update "applying staged frontend and proxy"
  if ! mv "$resources_dir/webui" "$rollback/webui" 2>/dev/null; then
    log_update "could not stage the current frontend"
    rm -rf "$rollback"
    return 0
  fi
  if ! mv "$resources_dir/silk-chat-proxy" "$rollback/silk-chat-proxy" 2>/dev/null; then
    mv "$rollback/webui" "$resources_dir/webui" 2>/dev/null || true
    log_update "could not stage the current proxy"
    rm -rf "$rollback"
    return 0
  fi
  if [ -f "$resources_dir/webui-version.txt" ]; then
    mv "$resources_dir/webui-version.txt" "$rollback/webui-version.txt" 2>/dev/null || true
  fi

  if ! mv "$pending/webui" "$resources_dir/webui" 2>/dev/null; then
    mv "$rollback/webui" "$resources_dir/webui" 2>/dev/null || true
    mv "$rollback/silk-chat-proxy" "$resources_dir/silk-chat-proxy" 2>/dev/null || true
    if [ -f "$rollback/webui-version.txt" ]; then
      mv "$rollback/webui-version.txt" "$resources_dir/webui-version.txt" 2>/dev/null || true
    fi
    log_update "could not apply the staged frontend"
    return 0
  fi
  if ! mv "$pending/silk-chat-proxy" "$resources_dir/silk-chat-proxy" 2>/dev/null; then
    rm -rf "$resources_dir/webui" 2>/dev/null || true
    mv "$rollback/webui" "$resources_dir/webui" 2>/dev/null || true
    mv "$rollback/silk-chat-proxy" "$resources_dir/silk-chat-proxy" 2>/dev/null || true
    if [ -f "$rollback/webui-version.txt" ]; then
      mv "$rollback/webui-version.txt" "$resources_dir/webui-version.txt" 2>/dev/null || true
    fi
    log_update "could not apply the staged proxy"
    return 0
  fi
  chmod 755 "$resources_dir/silk-chat-proxy" 2>/dev/null || true
  mv "$pending/webui-version.txt" "$resources_dir/webui-version.txt" 2>/dev/null || true
  rm -rf "$pending"

  log_update "frontend and proxy updated from staged release"
}

record_launcher_version() {
  mkdir -p "$(dirname "$UPDATE_VERSION_FILE")" 2>/dev/null || true
  printf '%s\n' "$1" > "$UPDATE_VERSION_FILE.tmp.$$" 2>/dev/null || return 0
  chmod 600 "$UPDATE_VERSION_FILE.tmp.$$" 2>/dev/null || true
  mv "$UPDATE_VERSION_FILE.tmp.$$" "$UPDATE_VERSION_FILE" 2>/dev/null || true
}

self_update_due() {
  local now last=0
  now="$(date +%s)"
  if [ "${SILK_CHAT_FORCE_UPDATE:-}" != "1" ]; then
    if [ -f "$UPDATE_CHECK_FILE" ]; then
      last="$(cat "$UPDATE_CHECK_FILE" 2>/dev/null || echo 0)"
      case "$last" in
        ''|*[!0-9]*) last=0 ;;
      esac
    fi
    if [ $((now - last)) -lt "$UPDATE_INTERVAL" ]; then
      return 1
    fi
  fi
  mkdir -p "$(dirname "$UPDATE_CHECK_FILE")" 2>/dev/null || true
  printf '%s\n' "$now" > "$UPDATE_CHECK_FILE" 2>/dev/null || true
  return 0
}

wait_for_socks() {
  for _ in {1..60}; do
    if /usr/bin/nc -z 127.0.0.1 9150 >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Update requests: HTTPS only (redirects too), straight to GitHub without any
# proxy, and no ~/.curlrc (-q must come first), so nothing can add a cookie,
# header or proxy to them.
update_curl() {
  curl -q -fsSL --proto '=https' --proto-redir '=https' --noproxy '*' \
    --connect-timeout 15 "$@"
}

# "740 KB", "12.3 MB": decimal units, as Finder shows sizes.
format_size() {
  local bytes="$1"
  if [ "$bytes" -lt 1000000 ]; then
    printf '%d KB' "$(((bytes + 999) / 1000))"
  else
    printf '%d.%d MB' "$((bytes / 1000000))" "$(((bytes % 1000000) / 100000))"
  fi
}

format_time_left() {
  local seconds="$1"
  if [ "$seconds" -lt 1 ]; then
    seconds=1
  fi
  if [ "$seconds" -lt 60 ]; then
    printf 'about %d s left' "$seconds"
  else
    printf 'about %d min left' "$(((seconds + 59) / 60))"
  fi
}

manifest_number() {
  local value
  value="$(sed -n "s/^$1=//p" "$2" | head -1)"
  case "$value" in
    ''|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$value" ;;
  esac
}

# Downloads one release file while the status panel shows its bar, size, speed
# and time left. A stall (under 4 KB/s for a minute) fails an attempt instead of
# a fixed deadline, so a slow but moving download still finishes. expected is
# the size from the signed manifest; without it the bar animates.
fetch_update_file() {
  local name="$1" out="$2" title="$3" expected="${4:-0}"
  local pid size previous=0 previous_at now sample rate=0 progress=-1 detail
  case "$expected" in
    ''|*[!0-9]*) expected=0 ;;
  esac
  if [ "$expected" -gt 0 ]; then
    progress=0
  fi
  rm -f "$out"
  status_progress downloading "$title" "Connecting to GitHub…" "$progress"
  update_curl --speed-limit 4096 --speed-time 60 --max-time 3600 --retry 2 \
    "$UPDATE_BASE_URL/$name" -o "$out" &
  pid=$!
  previous_at="$(date +%s)"
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.5
    size=0
    if [ -f "$out" ]; then
      size="$(wc -c < "$out" 2>/dev/null | tr -d ' ')"
    fi
    case "$size" in
      ''|*[!0-9]*) size=0 ;;
    esac
    now="$(date +%s)"
    if [ "$now" -gt "$previous_at" ]; then
      # A retry starts the file again; count that second as no progress.
      sample=$(((size - previous) / (now - previous_at)))
      if [ "$sample" -lt 0 ]; then
        sample=0
      fi
      if [ "$rate" -eq 0 ]; then
        rate="$sample"
      else
        rate=$(((rate * 2 + sample) / 3))
      fi
      previous="$size"
      previous_at="$now"
    fi
    detail="$(format_size "$size")"
    if [ "$expected" -gt 0 ]; then
      progress=$((size * 100 / expected))
      if [ "$progress" -gt 100 ]; then
        progress=100
      fi
      detail="$detail of $(format_size "$expected")"
    fi
    if [ "$rate" -gt 0 ]; then
      detail="$detail · $(format_size "$rate")/s"
      if [ "$expected" -gt "$size" ]; then
        detail="$detail · $(format_time_left $(((expected - size + rate - 1) / rate)))"
      fi
    fi
    status_progress downloading "$title" "$detail" "$progress"
  done
  wait "$pid"
}

# The native app (Contents/MacOS/silk-chat) draws the status panel, so it is
# updated too. A replacement must be the manifest's universal binary. It goes
# in by rename, which leaves the running copy alone, and takes effect the next
# time Silk Chat opens.
wrapper_is_valid() {
  local file="$1" want="$2" kind
  if [ "$(shasum -a 256 "$file" | awk '{print $1}')" != "$want" ]; then
    log_update "app hash does not match the manifest"
    return 1
  fi
  kind="$(/usr/bin/file -b "$file" 2>/dev/null || true)"
  case "$kind" in
    *Mach-O*universal*|*universal*Mach-O*) ;;
    *)
      log_update "downloaded app is not a universal Mach-O binary"
      return 1
      ;;
  esac
  case "$kind" in
    *arm64*) ;;
    *)
      log_update "downloaded app has no arm64 code"
      return 1
      ;;
  esac
  case "$kind" in
    *x86_64*) ;;
    *)
      log_update "downloaded app has no x86_64 code"
      return 1
      ;;
  esac
  return 0
}

install_wrapper_file() {
  local new="$1" target="$2" staged
  staged="$(dirname "$target")/.silk-chat.new.$$"
  if cp "$new" "$staged" && chmod 755 "$staged" && mv -f "$staged" "$target"; then
    return 0
  fi
  rm -f "$staged" 2>/dev/null || true
  return 1
}

update_launcher() {
  local resources_dir
  resources_dir="$(cd "$(dirname "$0")" && pwd)" || return 0
  case "$resources_dir" in
    */Contents/Resources) ;;
    *) return 0 ;;
  esac
  [ -f "$resources_dir/../Info.plist" ] || return 0
  self_update_due || return 0

  if [ -f "$UPDATE_LOG" ] && [ "$(wc -c < "$UPDATE_LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    mv "$UPDATE_LOG" "$UPDATE_LOG.1" 2>/dev/null || true
  fi
  log_update "checking for updates"

  (
    work="$(mktemp -d "${TMPDIR:-/tmp}/silk-chat-update.XXXXXX")" || exit 0
    status_shown=0
    trap 'rm -rf "$work"; if [ "$status_shown" = 1 ]; then status_hide; fi' EXIT

    update_curl --max-time 45 --retry 2 \
      "$UPDATE_BASE_URL/manifest.txt" -o "$work/manifest.txt" || {
      log_update "manifest download failed"
      exit 0
    }
    update_curl --max-time 45 --retry 2 \
      "$UPDATE_BASE_URL/manifest.txt.sig" -o "$work/manifest.txt.sig" || {
      log_update "signature download failed"
      exit 0
    }

    printf 'silk-chat-launcher %s\n' "$LAUNCHER_SIGNING_KEY" > "$work/allowed_signers"
    if ! /usr/bin/ssh-keygen -Y verify \
      -f "$work/allowed_signers" \
      -I silk-chat-launcher \
      -n silk-chat-launcher \
      -s "$work/manifest.txt.sig" < "$work/manifest.txt" >/dev/null 2>&1; then
      log_update "manifest signature verification failed"
      exit 0
    fi

    version="$(sed -n 's/^version=//p' "$work/manifest.txt" | head -1)"
    sha="$(sed -n 's/^sha256=//p' "$work/manifest.txt" | head -1)"
    server_version="$(sed -n 's/^server_version=//p' "$work/manifest.txt" | head -1)"
    resources_version="$(sed -n 's/^resources_version=//p' "$work/manifest.txt" | head -1)"
    webui_sha="$(sed -n 's/^webui_sha256=//p' "$work/manifest.txt" | head -1)"
    proxy_sha="$(sed -n 's/^proxy_sha256=//p' "$work/manifest.txt" | head -1)"
    wrapper_sha="$(sed -n 's/^wrapper_sha256=//p' "$work/manifest.txt" | head -1)"
    launcher_size="$(manifest_number launcher_size "$work/manifest.txt")"
    webui_size="$(manifest_number webui_size "$work/manifest.txt")"
    proxy_size="$(manifest_number proxy_size "$work/manifest.txt")"
    wrapper_size="$(manifest_number wrapper_size "$work/manifest.txt")"

    case "$version" in
      ''|*[!0-9]*) log_update "manifest version is invalid"; exit 0 ;;
    esac
    if ! valid_sha "$sha"; then
      log_update "launcher hash is invalid"
      exit 0
    fi
    if [ -n "$server_version" ]; then
      case "$server_version" in
        ''|*[!0-9.]*|.*|*.) log_update "server version is invalid"; server_version="" ;;
      esac
    fi
    for candidate in "$resources_version" "$webui_sha" "$proxy_sha"; do
      if [ -n "$candidate" ] && ! valid_sha "$candidate"; then
        log_update "resource manifest hash is invalid"
        resources_version=""
        webui_sha=""
        proxy_sha=""
        server_version=""
        break
      fi
    done
    if [ -n "$wrapper_sha" ] && ! valid_sha "$wrapper_sha"; then
      log_update "app manifest hash is invalid"
      wrapper_sha=""
    fi

    current=0
    if [ -f "$UPDATE_VERSION_FILE" ]; then
      current="$(cat "$UPDATE_VERSION_FILE" 2>/dev/null || echo 0)"
      case "$current" in
        ''|*[!0-9]*) current=0 ;;
      esac
    fi
    # The GitHub release goes live after the server deploy, so an install that
    # took this launcher from the onion copy can briefly see an older release.
    # Never move resources backwards to it.
    if [ "$version" -lt "$current" ]; then
      log_update "the published release $version is older than this install ($current); waiting"
      exit 0
    fi
    launcher_needed=0
    if [ "$version" -gt "$current" ]; then
      if [ "$(file_sha "$resources_dir/launch.command")" = "$sha" ]; then
        # Every push to main raises the build number. When the launcher in it
        # is the one installed, note the number and leave the file alone.
        record_launcher_version "$version"
        log_update "launcher unchanged in version $version"
      else
        launcher_needed=1
      fi
    fi

    webui_needed=0
    proxy_needed=0
    version_needed=0
    if [ -n "$resources_version" ] && [ -n "$server_version" ] &&
      [ -n "$webui_sha" ] && [ -n "$proxy_sha" ]; then
      resource_needs "$resources_version" "$webui_sha" "$proxy_sha" "$resources_dir"
      webui_needed="$RESOURCE_WEBUI_NEEDED"
      proxy_needed="$RESOURCE_PROXY_NEEDED"
      version_needed="$RESOURCE_VERSION_NEEDED"
    fi
    resources_needed=0
    if [ "$webui_needed" -eq 1 ] || [ "$proxy_needed" -eq 1 ] || [ "$version_needed" -eq 1 ]; then
      resources_needed=1
    fi

    wrapper_needed=0
    wrapper_path="$resources_dir/../MacOS/silk-chat"
    if [ -n "$wrapper_sha" ] && [ -f "$wrapper_path" ] &&
      [ "$(shasum -a 256 "$wrapper_path" | awk '{print $1}')" != "$wrapper_sha" ]; then
      wrapper_needed=1
    fi

    if [ "$launcher_needed" -eq 0 ] && [ "$resources_needed" -eq 0 ] &&
      [ "$wrapper_needed" -eq 0 ]; then
      log_update "launcher and resources are up to date"
      exit 0
    fi

    status_shown=1
    launcher_updated=0
    reopen_needed=0

    if [ "$launcher_needed" -eq 1 ]; then
      if ! fetch_update_file launch.command "$work/launch.command" \
        "Downloading the Silk Chat launcher" "$launcher_size"; then
        log_update "launcher download failed"
        rm -f "$work/launch.command"
      fi
      if [ -f "$work/launch.command" ]; then
        status_progress downloading "Checking the launcher" "Comparing it with the signed manifest" 100
        actual="$(shasum -a 256 "$work/launch.command" | awk '{print $1}')"
        if [ "$actual" != "$sha" ]; then
          log_update "launcher hash does not match the manifest"
        elif ! /bin/bash -n "$work/launch.command" >/dev/null 2>&1; then
          log_update "downloaded launcher failed the syntax check"
        else
          staged="$resources_dir/.launch.command.new.$$"
          if cp "$work/launch.command" "$staged" && chmod 755 "$staged" &&
            mv "$staged" "$resources_dir/launch.command"; then
            record_launcher_version "$version"
            launcher_updated=1
            reopen_needed=1
            log_update "launcher updated to version $version"
          else
            rm -f "$staged" 2>/dev/null || true
            log_update "could not replace the launcher"
          fi
        fi
      fi
    fi

    if [ "$launcher_updated" -eq 1 ] && [ "${SILK_CHAT_UPDATE_REEXEC:-}" != "1" ]; then
      # This run still has the old gate. Re-enter through the file just
      # installed so the proxy check runs before "up to date" is reported.
      # Run it as a child instead of exec so this shell keeps its EXIT trap
      # and clears the status written above when the check finishes.
      rm -rf "$work" 2>/dev/null || true
      export SILK_CHAT_UPDATE_REEXEC=1
      export SILK_CHAT_FORCE_UPDATE=1
      /bin/bash "$resources_dir/launch.command" --update-only
      exit $?
    fi

    if [ "$wrapper_needed" -eq 1 ]; then
      if ! fetch_update_file silk-chat "$work/silk-chat" \
        "Downloading the Silk Chat app" "$wrapper_size"; then
        log_update "app download failed"
      else
        status_progress downloading "Checking the app" "Comparing it with the signed manifest" 100
        if wrapper_is_valid "$work/silk-chat" "$wrapper_sha"; then
          if install_wrapper_file "$work/silk-chat" "$wrapper_path"; then
            reopen_needed=1
            log_update "app updated"
          else
            log_update "could not replace the app"
          fi
        fi
      fi
    fi

    if [ "$resources_needed" -eq 0 ]; then
      if [ "$reopen_needed" -eq 1 ]; then
        status_progress downloaded "Silk Chat update ready" "Reopen Silk Chat to finish" 100
        sleep 3
      fi
      exit 0
    fi

    if pending_is_current "$resources_version" "$webui_sha" "$proxy_sha" "$PENDING_RESOURCES"; then
      log_update "resources already staged"
      if [ "$reopen_needed" -eq 1 ]; then
        status_progress downloaded "Silk Chat update ready" "Reopen Silk Chat to finish" 100
        sleep 3
      fi
      exit 0
    fi

    # Resources must match the server's Open WebUI version, and only the onion
    # can say which one runs: this request alone still goes through Tor.
    status_progress downloading "Checking the server version" "Asking the Silk Chat server over Tor" -1
    if ! wait_for_socks; then
      log_update "Tor SOCKS did not become ready; resources not staged"
      exit 0
    fi
    config_json="$(curl -fsSL --socks5-hostname 127.0.0.1:9150 --connect-timeout 15 --max-time 30 \
      "http://$onion/api/config" 2>/dev/null || true)"
    current_server="$(printf '%s' "$config_json" |
      sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    if [ -z "$current_server" ]; then
      log_update "could not read the server version; resources not staged"
      exit 0
    fi
    if [ "$current_server" != "$server_version" ]; then
      log_update "server is $current_server but the bundle is for $server_version; resources not staged"
      exit 0
    fi

    log_update "updating resources for $server_version (webui=$webui_needed proxy=$proxy_needed version=$version_needed)"

    if [ "$webui_needed" -eq 1 ]; then
      fetch_update_file webui.tar.gz "$work/webui.tar.gz" \
        "Downloading the Silk Chat frontend" "$webui_size" || {
        log_update "frontend download failed"
        exit 0
      }
      status_progress downloading "Checking the frontend" "Comparing it with the signed manifest" 100
      if [ "$(shasum -a 256 "$work/webui.tar.gz" | awk '{print $1}')" != "$webui_sha" ]; then
        log_update "frontend hash does not match the manifest"
        exit 0
      fi
      status_progress installing "Unpacking the frontend" "Getting it ready for the next launch" -1
      mkdir -p "$work/webui"
      tar -xzf "$work/webui.tar.gz" -C "$work/webui" || {
        log_update "frontend archive could not be extracted"
        exit 0
      }
    else
      if ! cp -R "$resources_dir/webui" "$work/webui"; then
        log_update "could not reuse the current frontend"
        exit 0
      fi
    fi
    [ -f "$work/webui/index.html" ] || {
      log_update "frontend bundle has no index.html"
      exit 0
    }
    printf '%s\n' "$webui_sha" > "$work/webui/.silk-bundle-sha256"

    if [ "$proxy_needed" -eq 1 ]; then
      fetch_update_file silk-chat-proxy "$work/silk-chat-proxy" \
        "Downloading the Silk Chat proxy" "$proxy_size" || {
        log_update "proxy download failed"
        exit 0
      }
      status_progress downloading "Checking the proxy" "Comparing it with the signed manifest" 100
      if [ "$(shasum -a 256 "$work/silk-chat-proxy" | awk '{print $1}')" != "$proxy_sha" ]; then
        log_update "proxy hash does not match the manifest"
        exit 0
      fi
      if ! /usr/bin/file "$work/silk-chat-proxy" | grep -q 'Mach-O'; then
        log_update "downloaded proxy is not a Mach-O binary"
        exit 0
      fi
    else
      if ! cp "$resources_dir/silk-chat-proxy" "$work/silk-chat-proxy"; then
        log_update "could not reuse the current proxy"
        exit 0
      fi
    fi
    chmod 755 "$work/silk-chat-proxy"

    if [ "$version_needed" -eq 1 ]; then
      fetch_update_file webui-version.txt "$work/webui-version.txt" \
        "Downloading the frontend version" 0 || {
        log_update "frontend version download failed"
        exit 0
      }
      if [ "$(shasum -a 256 "$work/webui-version.txt" | awk '{print $1}')" != "$resources_version" ]; then
        log_update "frontend version hash does not match the manifest"
        exit 0
      fi
      if [ "$(sed -n 's/^open-webui //p' "$work/webui-version.txt" | head -1)" != "$server_version" ]; then
        log_update "frontend version does not match the manifest server version"
        exit 0
      fi
    else
      if ! cp "$resources_dir/webui-version.txt" "$work/webui-version.txt"; then
        log_update "could not reuse the current frontend version"
        exit 0
      fi
    fi

    status_progress installing "Staging the update" "Getting it ready for the next launch" -1
    pending_tmp="$PENDING_RESOURCES.$$"
    rm -rf "$pending_tmp"
    if ! mkdir -p "$pending_tmp"; then
      log_update "could not create the pending resource directory"
      exit 0
    fi
    if ! mv "$work/webui" "$pending_tmp/webui" ||
      ! mv "$work/silk-chat-proxy" "$pending_tmp/silk-chat-proxy" ||
      ! cp "$work/webui-version.txt" "$pending_tmp/webui-version.txt"; then
      rm -rf "$pending_tmp"
      log_update "could not stage the resources"
      exit 0
    fi
    chmod 755 "$pending_tmp/silk-chat-proxy"
    rm -rf "$PENDING_RESOURCES"
    if ! mv "$pending_tmp" "$PENDING_RESOURCES"; then
      log_update "could not publish the staged resources"
      exit 0
    fi
    log_update "resources staged for the next launch"
    status_progress downloaded "Silk Chat update ready" "It installs the next time Silk Chat opens" 100
    sleep 3
  )
}

if [ "$PLAN_UPDATE" = true ]; then
  plan_update
  exit $?
fi

if [ "$AGENT" = true ]; then
  run_agent
fi

if [ "$AGENT_ATTACH" = true ]; then
  # Support and test entry point: reach the resident proxy the way a launch
  # does (starting or restarting it if needed) and say whether it answered.
  # The access token is never printed.
  if agent_loaded; then printf 'agent_loaded=1\n'; else printf 'agent_loaded=0\n'; fi
  if attach_agent_proxy; then
    printf 'attached=1\n'
    exit 0
  fi
  printf 'attached=0\n'
  exit 1
fi

if [ "$UPDATE_ONLY" = true ]; then
  mkdir -p "$(dirname "$UPDATE_LOG")" 2>/dev/null || true
  exec >> "$UPDATE_LOG" 2>&1
  onion="$(normalize_onion "$(cat "$ONION_FILE" 2>/dev/null || true)")"
  update_launcher
  exit 0
fi

status_set starting "Starting Silk Chat…"

onion=""
if [ -s "$ONION_FILE" ]; then
  onion="$(normalize_onion "$(cat "$ONION_FILE" 2>/dev/null || true)")"
fi
if ! valid_onion "$onion"; then
  say_error "Silk Chat is not set up. Run the Silk Chat installer once, then open the app again."
  exit 1
fi

if [ ! -d "$TOR_PROFILE" ] || [ ! -f "$TOR_PROFILE/user.js" ]; then
  say_error "Silk Chat is not set up. Run the Silk Chat installer once, then open the app again."
  exit 1
fi
configure_runtime_profile

browser="$(find_tor_browser)" || {
  say_error "Tor Browser is not installed. Run the Silk Chat installer again."
  exit 1
}
browser_app="$(cd "$(dirname "$browser")/../.." && pwd)"
browser_real="$(cd "$(dirname "$browser")" && pwd -P)/$(basename "$browser")"
TOR_BINARY="${TOR_BINARY:-$(dirname "$browser_real")/Tor/tor}"
TOR_GEOIP_DIR="${TOR_GEOIP_DIR:-$browser_app/Contents/Resources/TorBrowser/Tor}"
TOR_PROCESS_PATTERN="$browser_real"
TOR_TOR_PATTERN="$(dirname "$browser_real")/Tor/tor"

if browser_running || tor_running; then
  stop_tor_browser || {
    say_error "Tor Browser is still running. Quit it and open Silk Chat again."
    exit 1
  }
fi

status_set starting "Starting Silk Chat…"

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -f "$PENDING_RESOURCES/webui/index.html" ] && [ -x "$PENDING_RESOURCES/silk-chat-proxy" ]; then
  status_progress installing "Installing the Silk Chat update" "Replacing the frontend and proxy" -1
fi
apply_pending_resources

status_set opening "Opening Silk Chat…"

if attach_agent_proxy; then
  log_proxy "launch: using the resident proxy"
  browser_url="$local_url"
elif start_local_proxy; then
  log_proxy "launch: local proxy ready"
  browser_url="$local_url"
else
  log_proxy "launch: local proxy unavailable; using the onion UI"
  browser_url="http://$onion"
fi

set_session_homepage "$browser_url"

log_proxy "launch: starting Tor Browser"
launch_browser "$browser_url"
if ! browser_pid="$(wait_for_browser_pid)"; then
  say_error "Tor Browser did not start."
  exit 1
fi
log_proxy "launch: Tor Browser process ready"
write_session_file "$browser_pid" "$browser_app" "$browser_url"

if [ "${SILK_CHAT_DISABLE_UPDATE:-}" != "1" ]; then
  mkdir -p "$(dirname "$UPDATE_LOG")" 2>/dev/null || true
  (
    trap 'status_is_update_phase && status_hide' EXIT
    while kill -0 "$browser_pid" 2>/dev/null; do
      sleep 60
      kill -0 "$browser_pid" 2>/dev/null || exit 0
      update_launcher
      sleep 900
    done
  ) >> "$UPDATE_LOG" 2>&1 &
fi

monitor_browser
