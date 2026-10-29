#!/usr/bin/env bash
set -euo pipefail

GUI=false
case "${1:-}" in
  --gui) GUI=true ;;
  "") ;;
  *)
    printf 'Usage: %s [--gui]\n' "$0" >&2
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
local_proxy_pid=""
local_handshake=""
local_url=""

LAUNCHER_SIGNING_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILvj4ZhAL+Jve263cPzibOBvqrSHLf20FqJ5nev1l/dq"
UPDATE_BASE_URL="${SILK_CHAT_UPDATE_BASE_URL:-https://github.com/patrickkkim/silk-chat-launcher/releases/download/launcher-latest}"
UPDATE_CHECK_FILE="${SILK_CHAT_UPDATE_CHECK_FILE:-$HOME/.config/silk-chat/last-launcher-check}"
UPDATE_VERSION_FILE="${SILK_CHAT_UPDATE_VERSION_FILE:-$HOME/.config/silk-chat/launcher-version}"
UPDATE_LOG="${SILK_CHAT_UPDATE_LOG:-$HOME/Library/Logs/Silk Chat/updater.log}"
SESSION_FILE="${SILK_CHAT_SESSION_FILE:-$HOME/.config/silk-chat/session}"
PENDING_RESOURCES="${SILK_CHAT_PENDING_RESOURCES:-$HOME/.config/silk-chat/pending-resources}"
ROLLBACK_RESOURCES="${SILK_CHAT_ROLLBACK_RESOURCES:-$HOME/.config/silk-chat/rollback-resources}"
UPDATE_INTERVAL=86400

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

launch_browser() {
  if [ "$(uname -m)" = "arm64" ] && [ -x /usr/bin/arch ] &&
    /usr/bin/lipo -archs "$browser" 2>/dev/null | tr ' ' '\n' | grep -qx arm64; then
    exec /usr/bin/arch -arm64 "$browser" "$@"
  fi
  exec "$browser" "$@"
}

browser_running() {
  pgrep -f "^${TOR_PROCESS_PATTERN}" >/dev/null 2>&1
}

tor_running() {
  pgrep -f "^${TOR_TOR_PATTERN}" >/dev/null 2>&1
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

  pkill -TERM -f "$TOR_TOR_PATTERN" >/dev/null 2>&1 || true
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

cleanup() {
  stop_local_proxy
  clear_session_file
}

start_local_proxy() {
  local_handshake="${TMPDIR:-/tmp}/silk-chat-proxy.$$"
  local_url=""

  [ "${SILK_CHAT_DISABLE_LOCAL_UI:-}" != "1" ] || return 1
  [ -x "$PROXY_BIN" ] && [ -f "$WEBUI_DIR/index.html" ] || return 1

  rm -f "$local_handshake"
  "$PROXY_BIN" \
    --static-dir "$WEBUI_DIR" \
    --onion-file "$ONION_FILE" \
    --handshake "$local_handshake" \
    --tor-socks 127.0.0.1:9150 >/dev/null 2>&1 &
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

valid_sha() {
  case "$1" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
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

self_update_due() {
  local now last=0
  now="$(date +%s)"
  if [ -f "$UPDATE_CHECK_FILE" ]; then
    last="$(cat "$UPDATE_CHECK_FILE" 2>/dev/null || echo 0)"
    case "$last" in
      ''|*[!0-9]*) last=0 ;;
    esac
  fi
  if [ $((now - last)) -lt "$UPDATE_INTERVAL" ]; then
    return 1
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
    trap 'rm -rf "$work"' EXIT

    wait_for_socks || {
      log_update "Tor SOCKS did not become ready"
      exit 0
    }

    curl -fsSL --socks5-hostname 127.0.0.1:9150 --connect-timeout 15 --max-time 45 --retry 2 \
      "$UPDATE_BASE_URL/manifest.txt" -o "$work/manifest.txt" || {
      log_update "manifest download failed"
      exit 0
    }
    curl -fsSL --socks5-hostname 127.0.0.1:9150 --connect-timeout 15 --max-time 45 --retry 2 \
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

    current=0
    if [ -f "$UPDATE_VERSION_FILE" ]; then
      current="$(cat "$UPDATE_VERSION_FILE" 2>/dev/null || echo 0)"
      case "$current" in
        ''|*[!0-9]*) current=0 ;;
      esac
    fi
    launcher_needed=0
    [ "$version" -gt "$current" ] && launcher_needed=1

    resources_needed=0
    if [ -n "$resources_version" ] && [ -n "$server_version" ] &&
      [ -n "$webui_sha" ] && [ -n "$proxy_sha" ]; then
      current_resources=""
      if [ -f "$resources_dir/webui-version.txt" ]; then
        current_resources="$(shasum -a 256 "$resources_dir/webui-version.txt" | awk '{print $1}')"
      fi
      if [ "$current_resources" != "$resources_version" ]; then
        resources_needed=1
      fi
    fi

    if [ "$launcher_needed" -eq 0 ] && [ "$resources_needed" -eq 0 ]; then
      log_update "launcher and resources are up to date"
      exit 0
    fi

    if [ "$launcher_needed" -eq 1 ]; then
      curl -fsSL --socks5-hostname 127.0.0.1:9150 --connect-timeout 15 --max-time 45 --retry 2 \
        "$UPDATE_BASE_URL/launch.command" -o "$work/launch.command" || {
        log_update "launcher download failed"
      }
      if [ -f "$work/launch.command" ]; then
        actual="$(shasum -a 256 "$work/launch.command" | awk '{print $1}')"
        if [ "$actual" != "$sha" ]; then
          log_update "launcher hash does not match the manifest"
        elif ! /bin/bash -n "$work/launch.command" >/dev/null 2>&1; then
          log_update "downloaded launcher failed the syntax check"
        else
          staged="$resources_dir/.launch.command.new.$$"
          if cp "$work/launch.command" "$staged" && chmod 755 "$staged" &&
            mv "$staged" "$resources_dir/launch.command"; then
            mkdir -p "$(dirname "$UPDATE_VERSION_FILE")" 2>/dev/null || true
            printf '%s\n' "$version" > "$UPDATE_VERSION_FILE.tmp.$$"
            chmod 600 "$UPDATE_VERSION_FILE.tmp.$$"
            mv "$UPDATE_VERSION_FILE.tmp.$$" "$UPDATE_VERSION_FILE" 2>/dev/null || true
            log_update "launcher updated to version $version"
          else
            rm -f "$staged" 2>/dev/null || true
            log_update "could not replace the launcher"
          fi
        fi
      fi
    fi

    [ "$resources_needed" -eq 1 ] || exit 0

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

    log_update "downloading frontend and proxy for $server_version"
    curl -fsSL --socks5-hostname 127.0.0.1:9150 --connect-timeout 15 --max-time 600 --retry 2 \
      "$UPDATE_BASE_URL/webui.tar.gz" -o "$work/webui.tar.gz" || {
      log_update "frontend download failed"
      exit 0
    }
    curl -fsSL --socks5-hostname 127.0.0.1:9150 --connect-timeout 15 --max-time 300 --retry 2 \
      "$UPDATE_BASE_URL/silk-chat-proxy" -o "$work/silk-chat-proxy" || {
      log_update "proxy download failed"
      exit 0
    }
    curl -fsSL --socks5-hostname 127.0.0.1:9150 --connect-timeout 15 --max-time 45 --retry 2 \
      "$UPDATE_BASE_URL/webui-version.txt" -o "$work/webui-version.txt" || {
      log_update "frontend version download failed"
      exit 0
    }

    if [ "$(shasum -a 256 "$work/webui.tar.gz" | awk '{print $1}')" != "$webui_sha" ]; then
      log_update "frontend hash does not match the manifest"
      exit 0
    fi
    if [ "$(shasum -a 256 "$work/silk-chat-proxy" | awk '{print $1}')" != "$proxy_sha" ]; then
      log_update "proxy hash does not match the manifest"
      exit 0
    fi
    if [ "$(shasum -a 256 "$work/webui-version.txt" | awk '{print $1}')" != "$resources_version" ]; then
      log_update "frontend version hash does not match the manifest"
      exit 0
    fi
    if [ "$(sed -n 's/^open-webui //p' "$work/webui-version.txt" | head -1)" != "$server_version" ]; then
      log_update "frontend version does not match the manifest server version"
      exit 0
    fi
    if ! /usr/bin/file "$work/silk-chat-proxy" | grep -q 'Mach-O'; then
      log_update "downloaded proxy is not a Mach-O binary"
      exit 0
    fi

    mkdir -p "$work/webui"
    tar -xzf "$work/webui.tar.gz" -C "$work/webui" || {
      log_update "frontend archive could not be extracted"
      exit 0
    }
    [ -f "$work/webui/index.html" ] || {
      log_update "frontend archive has no index.html"
      exit 0
    }
    chmod 755 "$work/silk-chat-proxy"

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
      log_update "could not stage the frontend and proxy"
      exit 0
    fi
    chmod 755 "$pending_tmp/silk-chat-proxy"
    rm -rf "$PENDING_RESOURCES"
    if ! mv "$pending_tmp" "$PENDING_RESOURCES"; then
      log_update "could not publish the staged frontend and proxy"
      exit 0
    fi
    log_update "frontend and proxy staged for the next launch"
  )
}

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

browser="$(find_tor_browser)" || {
  say_error "Tor Browser is not installed. Run the Silk Chat installer again."
  exit 1
}
browser_app="$(cd "$(dirname "$browser")/../.." && pwd)"
TOR_PROCESS_PATTERN="$browser"
TOR_TOR_PATTERN="$(dirname "$browser")/Tor/tor"

if browser_running || tor_running; then
  stop_tor_browser || {
    say_error "Tor Browser is still running. Quit it and open Silk Chat again."
    exit 1
  }
fi

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

apply_pending_resources

if start_local_proxy; then
  browser_url="$local_url"
else
  browser_url="http://$onion"
fi

set_session_homepage "$browser_url"

if [ -n "$KIOSK_FLAG" ]; then
  launch_browser -profile "$TOR_PROFILE" "$KIOSK_FLAG" "$browser_url" &
else
  launch_browser -profile "$TOR_PROFILE" "$browser_url" &
fi
browser_pid=$!
write_session_file "$browser_pid" "$browser_app" "$browser_url"

if [ "${SILK_CHAT_DISABLE_UPDATE:-}" != "1" ]; then
  mkdir -p "$(dirname "$UPDATE_LOG")" 2>/dev/null || true
  (
    sleep 60
    kill -0 "$browser_pid" 2>/dev/null || exit 0
    update_launcher
  ) >> "$UPDATE_LOG" 2>&1 &
fi

wait "$browser_pid"
