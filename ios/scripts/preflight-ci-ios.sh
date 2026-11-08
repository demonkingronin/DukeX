#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$SOURCE_DIR"

# These checks do not build the emulator or install any dependencies.
for required in \
  ios/vcpkg.json \
  ios/vcpkg-triplets/arm64-ios.cmake \
  ios/vcpkg-triplets/meson-ios-cross.txt \
  ios/vcpkg-overlays/libpcap/portfile.cmake \
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
configure = (root / 'configure').read_text()
meson = (root / 'meson.build').read_text()
for cmake_option in ("'CMAKE_SYSTEM_NAME': 'iOS'", "'CMAKE_OSX_SYSROOT': 'iphoneos'", "'CMAKE_OSX_ARCHITECTURES': 'arm64'"):
    if cmake_option not in meson:
        raise SystemExit(f'SDL3 iOS CMake target setting missing: {cmake_option}')
# The Meson-generated CMake toolchain overrides command-line platform options.
# Check the cross-file override before installing expensive native dependencies.
for cmake_machine_setting in ("CMAKE_SYSTEM_NAME = 'iOS'", "CMAKE_OSX_SYSROOT = 'iphoneos'", "CMAKE_OSX_ARCHITECTURES = 'arm64'"):
    if f'echo "{cmake_machine_setting}" >> $cross' not in configure:
        raise SystemExit(f'Meson CMake cross-file iOS setting missing: {cmake_machine_setting}')
if 'echo "[cmake]" >> $cross' not in configure:
    raise SystemExit('Meson CMake cross-file section missing')
core_build = (root / 'ios/scripts/build-core-ios.sh').read_text()
requirements = (root / 'pythondeps.toml').read_text()
if '[ios-build]' not in requirements or 'PyYAML' not in requirements:
    raise SystemExit('PyYAML must be declared for iOS QEMU venv')
if 'mkvenv.py" ensuregroup --online' not in core_build or "-c 'import yaml;" not in core_build:
    raise SystemExit('iOS core build must install and verify PyYAML in the QEMU virtual environment')
if 'ensuregroup --online ' + chr(92) + '\n' not in core_build:
    raise SystemExit('iOS PyYAML install command must have a single shell continuation')
if configure.count('cmake = [$(meson_quote "$DUKEX_IOS_CMAKE")]') != 2:
    raise SystemExit('QEMU configure must pass host CMake in both Meson machine files')
if 'export DUKEX_IOS_CMAKE' not in core_build:
    raise SystemExit('iOS core build must export the host CMake executable')
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
if 'set(VCPKG_LINKER_FLAGS "-framework CoreFoundation")' not in triplet:
    raise SystemExit('iOS vcpkg triplet must link CoreFoundation (required by libintl)')

cross = configparser.ConfigParser()
if not cross.read(root / 'ios/vcpkg-triplets/meson-ios-cross.txt'):
    raise SystemExit('Missing Meson cross file')
if not cross.has_section('properties') or not cross.getboolean('properties', 'needs_exe_wrapper', fallback=False):
    raise SystemExit('iOS Meson cross file must set needs_exe_wrapper=true')

libpcap_port = (root / 'ios/vcpkg-overlays/libpcap/portfile.cmake').read_text()
if 'if(VCPKG_TARGET_IS_IOS)' not in libpcap_port or '"-DPCAP_TYPE=null"' not in libpcap_port:
    raise SystemExit('iOS libpcap overlay must use the supported null capture backend')

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
smoke_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/dukex-ios-smoke.XXXXXX")"
smoke_object="$smoke_dir/target.o"
smoke_library="$smoke_dir/corefoundation.dylib"
trap 'rm -rf "$smoke_dir"' EXIT
printf 'int dukex_ios_smoke(void) { return 0; }\n' | \
  xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 \
    -isysroot "$sdkroot" -x c -c -o "$smoke_object" -
xcrun lipo "$smoke_object" -verify_arch arm64
# Validate that Apple's device SDK can link a CoreFoundation consumer.
printf '#include <CoreFoundation/CoreFoundation.h>\nvoid dukex_ios_cf_smoke(CFTypeRef ref) { CFRelease(ref); }\n' | \
  xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 \
    -isysroot "$sdkroot" -dynamiclib -framework CoreFoundation \
    -x c -o "$smoke_library" -
xcrun lipo "$smoke_library" -verify_arch arm64
echo 'DukeX iOS preflight passed: Swift parsed, Xcode project, and CoreFoundation iPhoneOS linkage available.'
