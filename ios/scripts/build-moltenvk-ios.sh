#!/usr/bin/env bash
set -euo pipefail

# Build the iOS device runtime from official MoltenVK source, not from an
# unrelated DukeX IPA release download.
MOLTENVK_TAG="v1.4.2"
MOLTENVK_COMMIT="db66022459ffb663aa2b50f6b018bc2e124f5edf"
CACHE_DIR="$RUNNER_TEMP/dukex-moltenvk-ios-framework"
FRAMEWORK="$CACHE_DIR/MoltenVK.framework"
REVISION_FILE="$CACHE_DIR/source-revision"

verify_framework() {
  test -f "$FRAMEWORK/MoltenVK"
  test -f "$FRAMEWORK/Info.plist"
  xcrun lipo "$FRAMEWORK/MoltenVK" -verify_arch arm64
  python3 - "$FRAMEWORK/Info.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as f:
    info = plistlib.load(f)
if "iPhoneOS" not in info.get("CFBundleSupportedPlatforms", []):
    raise SystemExit("MoltenVK.framework is not an iOS-device framework")
if info.get("CFBundleExecutable") != "MoltenVK":
    raise SystemExit("MoltenVK.framework has the wrong executable")
PY
}

if [[ -f "$REVISION_FILE" ]] && \
   [[ "$(cat "$REVISION_FILE")" == "$MOLTENVK_COMMIT" ]] && \
   verify_framework; then
  echo "Using cached pinned MoltenVK $MOLTENVK_TAG iOS framework"
else
  rm -rf "$CACHE_DIR"
  mkdir -p "$CACHE_DIR"
  SOURCE_DIR="$RUNNER_TEMP/dukex-moltenvk-source"
  rm -rf "$SOURCE_DIR"
  echo "Cloning upstream MoltenVK $MOLTENVK_TAG at pinned commit $MOLTENVK_COMMIT"
  git clone --filter=blob:none --no-checkout https://github.com/KhronosGroup/MoltenVK.git "$SOURCE_DIR"
  git -C "$SOURCE_DIR" checkout --detach "$MOLTENVK_COMMIT"
  if [[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" != "$MOLTENVK_COMMIT" ]]; then
    echo "::error::MoltenVK source checkout did not match pinned commit" >&2
    exit 1
  fi

  (
    cd "$SOURCE_DIR"
    echo "Fetching pinned upstream MoltenVK dependencies for iOS only"
    ./fetchDependencies --ios 2>&1 | tee "$RUNNER_TEMP/dukex-moltenvk-deps.log"
    echo "Building MoltenVK iOS device framework in Release configuration"
    make ios 2>&1 | tee "$RUNNER_TEMP/dukex-moltenvk-build.log"
  )

  XCFRAMEWORK="$SOURCE_DIR/Package/Release/MoltenVK/dynamic/MoltenVK.xcframework"
  test -f "$XCFRAMEWORK/Info.plist"
  # Select the device slice from the XCFramework metadata, not by guessing
  # a directory name or accidentally embedding the simulator framework.
  SOURCE_FRAMEWORK="$(python3 - "$XCFRAMEWORK" <<'PY'
import os
import plistlib
import sys
root = sys.argv[1]
with open(os.path.join(root, "Info.plist"), "rb") as f:
    metadata = plistlib.load(f)
matches = [
    item for item in metadata.get("AvailableLibraries", [])
    if item.get("SupportedPlatform") == "ios"
    and not item.get("SupportedPlatformVariant")
    and "arm64" in item.get("SupportedArchitectures", [])
]
if len(matches) != 1:
    raise SystemExit(f"Expected one arm64 iOS device MoltenVK slice; found {len(matches)}")
item = matches[0]
framework = os.path.join(root, item["LibraryIdentifier"], item["LibraryPath"])
if not os.path.isfile(os.path.join(framework, "MoltenVK")):
    raise SystemExit("iOS device MoltenVK.framework binary not found in XCFramework")
print(framework)
PY
  )"
  /usr/bin/ditto "$SOURCE_FRAMEWORK" "$FRAMEWORK"
  verify_framework
  printf '%s\n' "$MOLTENVK_COMMIT" > "$REVISION_FILE"
  echo "Verified pinned MoltenVK iOS framework from source."
fi

echo "MOLTENVK_FRAMEWORK=$FRAMEWORK" >> "$GITHUB_ENV"
