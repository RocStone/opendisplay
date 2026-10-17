#!/bin/bash
# Install the OpenDisplay cable relay on a receiver Mac, from the sender Mac,
# or remove it again. See README.md.
#
#   tools/odrelay/install.sh <ssh-host>              build, install, pair, start
#   tools/odrelay/install.sh --uninstall <ssh-host>  stop and remove it there,
#                                                    and the token here
#
# The receiver Mac needs Remote Login (key-based ssh) and nothing else: the
# helper is built here, universal, and runs as a per-user LaunchAgent.
set -euo pipefail

label=com.peetzweg.opensidecar.odrelay
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
local_dir="$HOME/Library/Application Support/OpenDisplayRelay"
token_file="$local_dir/token"

uninstall=0
if [[ "${1:-}" == "--uninstall" ]]; then
  uninstall=1
  shift
fi
host="${1:?usage: install.sh [--uninstall] <ssh-host>}"

if (( uninstall )); then
  ssh "$host" "label=$label bash -s" <<'REMOTE'
set -eu
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist"
rm -rf "$HOME/Library/Application Support/OpenDisplayRelay"
rm -f "$HOME/Library/Logs/OpenDisplayRelay.log"
echo "relay removed from $(scutil --get LocalHostName 2>/dev/null || hostname)"
REMOTE
  rm -f "$token_file"
  rmdir "$local_dir" 2>/dev/null || true
  echo "token removed on this Mac: OpenDisplay stops listening for the relay after a relaunch"
  exit 0
fi

build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
sources=("$here/main.swift" "$here/RelayLink.swift"
         "$root/Mac/CableRelayWire.swift" "$root/Shared/DirectCable.swift")
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos12" "${sources[@]}" -o "$build/odrelay-$arch"
done
lipo -create "$build/odrelay-arm64" "$build/odrelay-x86_64" -output "$build/odrelay"
codesign -s - -f "$build/odrelay" 2>/dev/null

# One token per sender Mac: reinstalling (or pairing a second receiver Mac)
# reuses it.
mkdir -p "$local_dir"
chmod 700 "$local_dir"
if [[ ! -s "$token_file" ]]; then
  (umask 077 && openssl rand -hex 32 > "$token_file")
fi

ssh "$host" 'umask 077 && mkdir -p "$HOME/Library/Application Support/OpenDisplayRelay"'
ssh "$host" 'cat > "$HOME/Library/Application Support/OpenDisplayRelay/odrelay.new"' < "$build/odrelay"
ssh "$host" 'umask 077 && cat > "$HOME/Library/Application Support/OpenDisplayRelay/token"' < "$token_file"
ssh "$host" "label=$label bash -s" <<'REMOTE'
set -eu
dir="$HOME/Library/Application Support/OpenDisplayRelay"
chmod 700 "$dir"
chmod 600 "$dir/token"
chmod 755 "$dir/odrelay.new"
mv -f "$dir/odrelay.new" "$dir/odrelay"
# The Local Network grant: see --prime in main.swift. It takes a moment to
# reach launchd's side.
"$dir/odrelay" --prime
sleep 2
plist="$HOME/Library/LaunchAgents/$label.plist"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$dir/odrelay</string>
        <string>--token-file</string>
        <string>$dir/token</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <!-- It carries the display stream: no background throttling. -->
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/OpenDisplayRelay.log</string>
</dict>
</plist>
PLIST
domain="gui/$(id -u)"
launchctl bootout "$domain/$label" 2>/dev/null || true
# bootout returns before the job is gone; bootstrap fails until it is.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  launchctl bootstrap "$domain" "$plist" 2>/dev/null && break
  sleep 0.5
done
sleep 1
launchctl print "$domain/$label" | grep -E '^\s+(state|pid) =' || true
REMOTE
echo "relay installed; OpenDisplay here listens for it in the Cable connection method"
