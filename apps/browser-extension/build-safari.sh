#!/bin/zsh
# Wraps the web extension into a macOS app (required for Safari) and builds it.
# Needs full Xcode (App Store), not just the command line tools.
set -e -o pipefail
cd "$(dirname "$0")"
if ! xcrun --find safari-web-extension-converter >/dev/null 2>&1; then
  echo "Xcode fehlt. Installiere Xcode aus dem App Store, dann:"
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi
rm -rf ../safari-build
xcrun safari-web-extension-converter . \
  --project-location ../safari-build --app-name "TikTok Clip Poster" \
  --bundle-identifier de.cutfortiktok.clipposter --macos-only --copy-resources --no-open --force
cd "../safari-build/TikTok Clip Poster"
# converter names the app "de.cutfortiktok.TikTok-Clip-Poster"; the extension id must be prefixed by the app id
sed -i '' 's/PRODUCT_BUNDLE_IDENTIFIER = "de.cutfortiktok.TikTok-Clip-Poster";/PRODUCT_BUNDLE_IDENTIFIER = de.cutfortiktok.clipposter;/' "TikTok Clip Poster.xcodeproj/project.pbxproj"
xcodebuild -scheme "TikTok Clip Poster" -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build | tail -3
APP=$(find build -name "TikTok Clip Poster.app" -maxdepth 5 | head -1)
rm -rf "/Applications/TikTok Clip Poster.app" && cp -R "$APP" /Applications/
open "/Applications/TikTok Clip Poster.app"
echo "Fertig. Jetzt in Safari aktivieren (siehe README)."
