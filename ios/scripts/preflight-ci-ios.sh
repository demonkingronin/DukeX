#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$SOURCE_DIR"

# These checks do not build the emulator or install any dependencies.
for required in \
  ios/vcpkg.json \
  ios/vcpkg-triplets/arm64-ios.cmake \
  ios/vcpkg-triplets/meson-ios-cross.txt \
  ios/DukeX/DukeX.xcodeproj/project.pbxproj \
  ios/scripts/build-core-ios.sh \
  ios/scripts/embed-core-ios.sh; do
  if [[ ! -f "$required" ]]; then
    echo "::error::Missing required iOS build input: $required" >&2
    exit 1
  fi
done

for script in ios/scripts/*.sh; do
  bash -n "$script"
done

python3 - <<'PY'
import configparser
import json
from pathlib import Path
import re

root = Path.cwd()
manifest = json.loads((root / 'ios/vcpkg.json').read_text())
baseline = manifest.get('builtin-baseline', '')
if not re.fullmatch(r'[0-9a-f]{40}', baseline):
    raise SystemExit('Invalid or missing pinned vcpkg baseline')

for overlay in (root / 'ios/vcpkg-overlays').glob('*/vcpkg.json'):
    json.loads(overlay.read_text())

triplet = (root / 'ios/vcpkg-triplets/arm64-ios.cmake').read_text()
required_triplet = 'set(VCPKG_MESON_CROSS_FILE "${CMAKE_CURRENT_LIST_DIR}/meson-ios-cross.txt")'
if required_triplet not in triplet:
    raise SystemExit('iOS triplet does not register the Meson cross file')

cross = configparser.ConfigParser()
if not cross.read(root / 'ios/vcpkg-triplets/meson-ios-cross.txt'):
    raise SystemExit('Missing Meson cross file')
if not cross.has_section('properties') or not cross.getboolean('properties', 'needs_exe_wrapper', fallback=False):
    raise SystemExit('iOS Meson cross file must set needs_exe_wrapper=true')

workflow = (root / '.github/workflows/ios-unsigned-ipa.yml').read_text()
if f'git -C "$VCPKG_ROOT" checkout {baseline}' not in workflow:
    raise SystemExit('Workflow vcpkg revision differs from ios/vcpkg.json')
print('Pinned vcpkg baseline, overlay manifests and iOS cross configuration: OK')
PY

if [[ "${DUKEX_PREFLIGHT_STATIC_ONLY:-0}" == "1" ]]; then
  echo "Static iOS preflight checks passed (Xcode checks skipped)."
  exit 0
fi

# Fail before expensive dependency installation if the runner lacks an SDK,
# a usable project, a parsable Swift source file, or an iPhoneOS compiler.
xcodebuild -list -project ios/DukeX/DukeX.xcodeproj >/dev/null
if ! find ios/DukeX/DukeX -name '*.swift' -type f -print -quit | grep -q .; then
  echo '::error::No Swift sources found in DukeX app' >&2
  exit 1
fi
find ios/DukeX/DukeX -name '*.swift' -type f -print0 | xargs -0 xcrun swiftc -frontend -parse

sdkroot="$(xcrun --sdk iphoneos --show-sdk-path)"
test -d "$sdkroot"
smoke_object="${RUNNER_TEMP:-/tmp}/dukex-ios-target-smoke.$$.o"
trap 'rm -f "$smoke_object"' EXIT
printf 'int dukex_ios_smoke(void) { return 0; }\n' | \
  xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 \
    -isysroot "$sdkroot" -x c -c -o "$smoke_object" -
xcrun lipo -verify_arch arm64 "$smoke_object"
echo 'DukeX iOS preflight passed: Swift parsed, Xcode project and iPhoneOS target available.'
