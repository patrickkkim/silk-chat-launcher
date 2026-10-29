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
KIOSK_FLAG="${SILK_CHAT_KIOSK_FLAG--kiosk}"
TOR_APP_ALT="$HOME/Applications/Tor Browser.app"

LAUNCHER_SIGNING_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILvj4ZhAL+Jve263cPzibOBvqrSHLf20FqJ5nev1l/dq"
UPDATE_BASE_URL="${SILK_CHAT_UPDATE_BASE_URL:-https://github.com/patrickkkim/silk-chat-launcher/releases/download/launcher-latest}"
UPDATE_CHECK_FILE="${SILK_CHAT_UPDATE_CHECK_FILE:-$HOME/.config/silk-chat/last-launcher-check}"
UPDATE_VERSION_FILE="${SILK_CHAT_UPDATE_VERSION_FILE:-$HOME/.config/silk-chat/launcher-version}"
UPDATE_LOG="${SILK_CHAT_UPDATE_LOG:-$HOME/Library/Logs/Silk Chat/updater.log}"
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
  pgrep -f "$TOR_PROCESS_PATTERN" >/dev/null 2>&1
}

tor_running() {
  pgrep -f "$TOR_TOR_PATTERN" >/dev/null 2>&1
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

log_update() {
  mkdir -p "$(dirname "$UPDATE_LOG")" 2>/dev/null || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$UPDATE_LOG" 2>/dev/null || true
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
  log_update "checking for launcher updates"

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
    curl -fsSL --socks5-hostname 127.0.0.1:9150 --connect-timeout 15 --max-time 45 --retry 2 \
      "$UPDATE_BASE_URL/launch.command" -o "$work/launch.command" || {
      log_update "launcher download failed"
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
    case "$version" in
      ''|*[!0-9]*) log_update "manifest version is invalid"; exit 0 ;;
    esac
    case "$sha" in
      ''|*[!0-9a-f]*) log_update "manifest hash is invalid"; exit 0 ;;
    esac
    if [ "${#sha}" -ne 64 ]; then
      log_update "manifest hash is invalid"
      exit 0
    fi

    actual="$(shasum -a 256 "$work/launch.command" | awk '{print $1}')"
    if [ "$actual" != "$sha" ]; then
      log_update "launcher hash does not match the manifest"
      exit 0
    fi

    current=0
    if [ -f "$UPDATE_VERSION_FILE" ]; then
      current="$(cat "$UPDATE_VERSION_FILE" 2>/dev/null || echo 0)"
      case "$current" in
        ''|*[!0-9]*) current=0 ;;
      esac
    fi
    if [ "$version" -le "$current" ]; then
      log_update "launcher is up to date at version $current"
      exit 0
    fi

    if ! /bin/bash -n "$work/launch.command" >/dev/null 2>&1; then
      log_update "downloaded launcher failed the syntax check"
      exit 0
    fi

    staged="$resources_dir/.launch.command.new.$$"
    cp "$work/launch.command" "$staged" || exit 0
    chmod 755 "$staged"
    if ! mv "$staged" "$resources_dir/launch.command"; then
      rm -f "$staged"
      log_update "could not replace the launcher"
      exit 0
    fi

    mkdir -p "$(dirname "$UPDATE_VERSION_FILE")" 2>/dev/null || true
    printf '%s\n' "$version" > "$UPDATE_VERSION_FILE.tmp.$$"
    chmod 600 "$UPDATE_VERSION_FILE.tmp.$$"
    mv "$UPDATE_VERSION_FILE.tmp.$$" "$UPDATE_VERSION_FILE" 2>/dev/null || true
    log_update "launcher updated to version $version"
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
TOR_PROCESS_PATTERN="$browser"
TOR_TOR_PATTERN="$(dirname "$browser")/Tor/tor"

if [ -n "$KIOSK_FLAG" ] && { browser_running || tor_running; }; then
  stop_tor_browser || {
    say_error "Tor Browser is still running. Quit it and open Silk Chat again."
    exit 1
  }
fi

if [ "${SILK_CHAT_DISABLE_UPDATE:-}" != "1" ]; then
  mkdir -p "$(dirname "$UPDATE_LOG")" 2>/dev/null || true
  update_launcher >> "$UPDATE_LOG" 2>&1 &
fi

if [ -n "$KIOSK_FLAG" ]; then
  launch_browser -profile "$TOR_PROFILE" "$KIOSK_FLAG" "http://$onion"
else
  launch_browser -profile "$TOR_PROFILE" "http://$onion"
fi
