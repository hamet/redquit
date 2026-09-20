#!/bin/bash
# Build (via build.sh), install to /usr/local/bin and (re)load the LaunchAgent.
NAME=redquit
LABEL=com.user.redquit
BIN=/usr/local/bin/$NAME
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

cd "$(dirname "$0")" || exit 1

./build.sh || exit 1

echo "==> install"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
sudo mkdir -p /usr/local/bin
sudo cp "$NAME" "$BIN" || { echo "copy failed"; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents"
cp "$LABEL.plist" "$AGENT"
launchctl bootstrap "gui/$(id -u)" "$AGENT" || { echo "launchctl bootstrap failed"; exit 1; }

echo "done. Grant Accessibility to $BIN, log: tail -f /tmp/redquit.log"
