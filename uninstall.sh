#!/bin/bash
LABEL=com.user.redquit
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
sudo rm -f /usr/local/bin/redquit
echo "removed (the Accessibility entry can be deleted by hand)"
