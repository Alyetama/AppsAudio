#!/bin/bash
# Build AppsAudio.app — a per-app speaker volume mixer for macOS.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="AppsAudio"
BUNDLE_ID="com.fcatus.appsaudio"
BUILD_DIR=".build/release"
APP_DIR="build/${APP_NAME}.app"

echo "▶ Building release binary…"
swift build -c release

echo "▶ Assembling ${APP_NAME}.app…"
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# ---- Icon ---------------------------------------------------------------
echo "▶ Generating app icon…"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
cat > "$(dirname "$ICONSET")/icon.swift" <<'SWIFT'
import AppKit
func makeIcon(_ size: CGFloat) -> NSBitmapImageRep {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let r = CGRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.2237
    let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    let grad = NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.98, alpha: 1),
                                   NSColor(calibratedRed: 0.55, green: 0.28, blue: 0.95, alpha: 1)])!
    path.addClip()
    grad.draw(in: r, angle: -90)
    // Three mixer sliders
    let cols: CGFloat = 3
    let margin = size * 0.24
    let usable = size - margin * 2
    let track = size * 0.03
    let knob = size * 0.11
    let positions: [CGFloat] = [0.62, 0.4, 0.78] // knob height fraction per slider
    for i in 0..<Int(cols) {
        let x = margin + usable * (CGFloat(i) + 0.5) / cols
        let top = size - margin
        let bottom = margin
        // track
        NSColor(white: 1, alpha: 0.35).setFill()
        NSBezierPath(roundedRect: CGRect(x: x - track/2, y: bottom, width: track, height: top - bottom),
                     xRadius: track/2, yRadius: track/2).fill()
        // knob
        let ky = bottom + (top - bottom) * positions[i]
        NSColor.white.setFill()
        NSBezierPath(ovalIn: CGRect(x: x - knob/2, y: ky - knob/2, width: knob, height: knob)).fill()
    }
    img.unlockFocus()
    return NSBitmapImageRep(data: img.tiffRepresentation!)!
}
let sizes = [16,32,64,128,256,512,1024]
let dir = CommandLine.arguments[1]
for s in sizes {
    let rep = makeIcon(CGFloat(s))
    let data = rep.representation(using: .png, properties: [:])!
    let name = s == 1024 ? "icon_512x512@2x.png" :
               "icon_\(s)x\(s).png"
    try! data.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
    if s >= 32 && s <= 512 {
        let rep2 = makeIcon(CGFloat(s*2))
        let d2 = rep2.representation(using: .png, properties: [:])!
        try! d2.write(to: URL(fileURLWithPath: "\(dir)/icon_\(s)x\(s)@2x.png"))
    }
}
SWIFT
swift "$(dirname "$ICONSET")/icon.swift" "$ICONSET" >/dev/null 2>&1 || echo "  (icon generation skipped)"
if [ -d "$ICONSET" ] && ls "$ICONSET"/*.png >/dev/null 2>&1; then
    iconutil -c icns "$ICONSET" -o "${APP_DIR}/Contents/Resources/AppIcon.icns" 2>/dev/null \
        && ICON_LINE='<key>CFBundleIconFile</key><string>AppIcon</string>' \
        || ICON_LINE=''
else
    ICON_LINE=''
fi

# ---- Info.plist ---------------------------------------------------------
VERSION="1.0.0"
cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    ${ICON_LINE}
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>LSUIElement</key><true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>AppsAudio taps each app's audio so it can adjust or mute that app at the speakers without stopping the app from playing or being recorded.</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# ---- Sign (ad-hoc, stable identity so TCC remembers the permission) ------
echo "▶ Signing (ad-hoc)…"
codesign --force --sign - "${APP_DIR}" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "✅ Built ${APP_DIR}"
echo "   Run:     open \"${APP_DIR}\""
echo "   Install: cp -R \"${APP_DIR}\" /Applications/"
