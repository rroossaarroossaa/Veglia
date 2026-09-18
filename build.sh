#!/bin/sh
# Builds Veglia.app without an Xcode project: swiftc + a hand-made bundle + icons rendered
# from SVG by headless Chrome. The result goes to ~/Applications/Veglia.app and is launched.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Veglia.app"
ICON_SRC="$HERE/icons/app-icon.html"
BUILD="$HERE/build"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

mkdir -p "$BUILD"

# 1. App icon: SVG → 1024 px PNG with a transparent background → iconset → .icns
if [ ! -f "$BUILD/Veglia.icns" ] || [ "$ICON_SRC" -nt "$BUILD/Veglia.icns" ]; then
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=1024,1024 \
    --default-background-color=00000000 --screenshot="$BUILD/icon-1024.png" \
    "file://$ICON_SRC" 2>/dev/null
  rm -rf "$BUILD/Veglia.iconset"; mkdir "$BUILD/Veglia.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD/icon-1024.png" --out "$BUILD/Veglia.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s*2))
    sips -z $d $d "$BUILD/icon-1024.png" --out "$BUILD/Veglia.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$BUILD/Veglia.iconset" -o "$BUILD/Veglia.icns"
fi

# 1b. Menu bar icons: template PNGs at 1x and 2x from icons/menubar-candle.html
for st in on off; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=20,20 --force-device-scale-factor=2 \
    --default-background-color=00000000 --screenshot="$BUILD/candle-$st@2x.png" \
    "file://$HERE/icons/menubar-candle.html?state=$st" 2>/dev/null
  sips -z 20 20 "$BUILD/candle-$st@2x.png" --out "$BUILD/candle-$st.png" >/dev/null
done

# 2. Binary
swiftc -O "$HERE"/Sources/*.swift -o "$BUILD/Veglia" \
  -framework Cocoa -framework IOKit -framework ServiceManagement

# 3. Bundle
pkill -x Veglia 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Veglia" "$APP/Contents/MacOS/Veglia"
cp "$BUILD/Veglia.icns" "$APP/Contents/Resources/Veglia.icns"
cp "$BUILD"/candle-*.png "$APP/Contents/Resources/"
cp "$HERE/lid/install-helper.sh" "$APP/Contents/Resources/install-helper.sh"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Veglia</string>
  <key>CFBundleDisplayName</key><string>Veglia</string>
  <key>CFBundleIdentifier</key><string>com.rosathings.veglia</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>CFBundleShortVersionString</key><string>0.4</string>
  <key>CFBundleExecutable</key><string>Veglia</string>
  <key>CFBundleIconFile</key><string>Veglia</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>
    <string>en</string><string>ru</string><string>it</string><string>es</string><string>pt</string>
    <string>fr</string><string>de</string><string>nl</string><string>pl</string><string>uk</string>
    <string>tr</string><string>ar</string><string>hi</string><string>zh-Hans</string><string>zh-Hant</string>
    <string>ja</string><string>ko</string><string>id</string><string>vi</string><string>th</string>
  </array>
  <key>NSHumanReadableCopyright</key><string>Rosa Things</string>
</dict></plist>
EOF
# Ad-hoc signature: without it "Launch at login" (SMAppService) refuses to register.
codesign --force --sign - "$APP" >/dev/null 2>&1
open "$APP"
echo "built and launched: $APP"
