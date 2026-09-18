#!/bin/sh
# Installs the Veglia system helper for the "work with the lid closed" mode.
# Runs once as an administrator (macOS asks for the password itself).
#
# Why a helper: closing the lid puts the Mac to sleep regardless of what apps ask for.
# The only way around it is the `pmset disablesleep` setting, which only root can change.
# Asking for a password at every start and end of a session would be unbearable, so we
# install a tiny launchd daemon that watches a flag file in the user's folder and toggles
# the setting. Veglia creates and removes the flag itself, only while it is actively
# holding the Mac awake.
#
# Argument 1: the flag directory (the user's Application Support folder).
# To remove the helper:
#   sudo launchctl bootout system/com.rosathings.veglia.lid
#   sudo rm /Library/LaunchDaemons/com.rosathings.veglia.lid.plist /Library/PrivilegedHelperTools/veglia-lid.sh
#   sudo pmset -a disablesleep 0
set -e
FLAGDIR="$1"
[ -n "$FLAGDIR" ] || { echo "flag directory required" >&2; exit 1; }
LABEL="com.rosathings.veglia.lid"
SCRIPT="/Library/PrivilegedHelperTools/veglia-lid.sh"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

mkdir -p /Library/PrivilegedHelperTools
cat > "$SCRIPT" <<EOF
#!/bin/sh
# Veglia helper: while the flag file exists the Mac does not sleep, even with the lid closed.
if [ -f "$FLAGDIR/lid-awake" ]; then
  /usr/bin/pmset -a disablesleep 1
else
  /usr/bin/pmset -a disablesleep 0
fi
EOF
chmod 755 "$SCRIPT"; chown root:wheel "$SCRIPT"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>$SCRIPT</string></array>
  <key>WatchPaths</key><array><string>$FLAGDIR</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
chmod 644 "$PLIST"; chown root:wheel "$PLIST"

launchctl bootout system/$LABEL 2>/dev/null || true
launchctl bootstrap system "$PLIST"
echo "ok"
