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
  ios/scripts/bootstrap-vcpkg-ios.sh \
  ios/scripts/build-moltenvk-ios.sh \
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
import os
from pathlib import Path
import re

root = Path.cwd()
configure = (root / 'configure').read_text()
meson = (root / 'meson.build').read_text()
for cmake_option in ("'CMAKE_SYSTEM_NAME': 'iOS'", "'CMAKE_OSX_SYSROOT': 'iphoneos'", "'CMAKE_OSX_ARCHITECTURES': 'arm64'"):
    if cmake_option not in meson:
        raise SystemExit(f'SDL3 iOS CMake target setting missing: {cmake_option}')
# SPIRV-Reflect's optional command-line executables have no iOS bundle
# install destination; only its static library is needed by DukeX.
spirv_options = meson.split("  spirv_reflect_opts = cmake.subproject_options()", 1)[1].split("  spirv_reflect_subproj =", 1)[0]
for required_option in ("'SPIRV_REFLECT_STATIC_LIB': 'ON'", "'SPIRV_REFLECT_EXECUTABLE': 'OFF'", "'SPIRV_REFLECT_INSTALL': 'OFF'"):
    if required_option not in spirv_options:
        raise SystemExit(f'SPIRV-Reflect iOS CMake option missing: {required_option}')
if 'if host_is_ios' not in spirv_options:
    raise SystemExit('SPIRV-Reflect tool exclusions must remain iOS-only')
# The Meson-generated CMake toolchain overrides command-line platform options.
# Check the cross-file override before installing expensive native dependencies.
for cmake_machine_setting in ("CMAKE_SYSTEM_NAME = 'iOS'", "CMAKE_OSX_SYSROOT = 'iphoneos'", "CMAKE_OSX_ARCHITECTURES = 'arm64'"):
    if f'echo "{cmake_machine_setting}" >> $cross' not in configure:
        raise SystemExit(f'Meson CMake cross-file iOS setting missing: {cmake_machine_setting}')
if 'echo "[cmake]" >> $cross' not in configure:
    raise SystemExit('Meson CMake cross-file section missing')
core_build = (root / 'ios/scripts/build-core-ios.sh').read_text()
# Guard against SDL3's missing CMake-to-Meson framework linkage on iOS.
frameworks_match = re.search(r'IOS_APPLE_FRAMEWORKS=\((.*?)\)', core_build, re.S)
if not frameworks_match:
    raise SystemExit('Missing explicit Apple framework link list for iOS SDL3')
frameworks = set(frameworks_match.group(1).split())
for required_framework in ('AudioToolbox', 'AVFoundation', 'CoreAudio', 'CoreBluetooth', 'CoreGraphics', 'CoreHaptics', 'CoreMotion', 'CoreVideo', 'Foundation', 'GameController', 'Metal', 'QuartzCore', 'UIKit'):
    if required_framework not in frameworks:
        raise SystemExit(f'Missing SDL3 Apple framework: {required_framework}')
if 'COMMON_LDFLAGS+=("-framework" "${framework}")' not in core_build:
    raise SystemExit('SDL3 Apple framework list must feed iOS linker flags')
# iOS core relaunch regression guards: QEMU option tables and settings may be
# used again after a previous game exits inside the same iOS process.
qemu_config = (root / 'util/qemu-config.c').read_text()
qemu_init = (root / 'system/vl.c').read_text()
xemu_entry = (root / 'ui/xemu.c').read_text()
xemu_settings = (root / 'ui/xemu-settings.cc').read_text()
for required in (
    'qemu_config_prepare_for_relaunch(void)',
    'qemu_opts_reset(vm_config_groups[i]);',
    'qemu_opts_reset(drive_config_groups[i]);',
    'drive_config_groups[i] == list',
    'vm_config_groups[i] == list',
):
    if required not in qemu_config:
        raise SystemExit(f'iOS relaunch QEMU config guard missing: {required}')
if qemu_init.index('qemu_config_prepare_for_relaunch();') > qemu_init.index('qemu_add_opts(&qemu_drive_opts);'):
    raise SystemExit('QEMU options must reset before registration in each session')
if 'qatomic_set(&qemu_exiting, false);' not in xemu_entry:
    raise SystemExit('iOS core must clear its previous session exit flag')
if 'config_tree.free_allocations(&g_config);' not in xemu_settings or 'xemu_ios_reset_config_node(config_tree);' not in xemu_settings:
    raise SystemExit('iOS per-game config must clear previous values before reload')

game_options = (root / 'ios/DukeX/DukeX/Runtime/LaunchPlan/XemuLaunchPlan.swift').read_text()
if 'static let allowedValues = [1, 2]' not in game_options:
    raise SystemExit('Display Quality must only offer Low and High')
for required in ('skip_boot_anim', 'surface_scale', 'GameSkipBootConfig'):
    if required not in game_options:
        raise SystemExit(f'Per-game TOML editor missing: {required}')
for view_file in (
    'ios/DukeX/DukeX/Features/Games/Components/GameCoverTile.swift',
    'ios/DukeX/DukeX/Features/Games/Components/GameListRow.swift',
):
    view = (root / view_file).read_text()
    if 'setSkipBoot(enabled)' not in view or 'GameResolutionScaleConfig.title(for: scale)' not in view:
        raise SystemExit(f'Per-game options are missing in {view_file}')

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
if 'bash ios/scripts/bootstrap-vcpkg-ios.sh "$VCPKG_ROOT"' not in workflow:
    raise SystemExit('Workflow must invoke the pinned vcpkg source fallback')
mvk_source = (root / 'ios/scripts/build-moltenvk-ios.sh').read_text()
for required in ('db66022459ffb663aa2b50f6b018bc2e124f5edf',
                 './fetchDependencies --ios', 'make ios',
                 'SupportedPlatform', 'CFBundleSupportedPlatforms', 'verify_framework'):
    if required not in mvk_source:
        raise SystemExit(f'Pinned MoltenVK source build guard missing: {required}')
for required in ('bash ios/scripts/build-moltenvk-ios.sh',
                 'actions/cache/save@v4', 'MOLTENVK_FRAMEWORK'):
    if required not in workflow:
        raise SystemExit(f'MoltenVK build integration is missing: {required}')
if 'ORIGINAL_IPA:' in workflow:
    raise SystemExit('Do not download an unrelated IPA for MoltenVK')
bootstrap = (root / 'ios/scripts/bootstrap-vcpkg-ios.sh').read_text()
for marker in ('VCPKG_TOOL_SOURCE_SHA', 'shasum -a 512 -c -', 'cmake --build "$build_dir" --target vcpkg', 'source_urls=('):
    if marker not in bootstrap:
        raise SystemExit(f'Pinned vcpkg source bootstrap guard missing: {marker}')
# GitHub Actions evaluates the workflow file at the triggering commit. For an
# expressly approved one-shot build, that snapshot temporarily contains a
# narrowly scoped push trigger even after the branch has been restored to
# manual-only. Accept that snapshot ONLY for the matching approved run.
if re.search(r'(?m)^  (push|pull_request|schedule):', workflow):
    approved_branch = 'build/approved-2026-11-07-dukex'
    approved_trigger = '\n  push:\n    branches:\n      - ' + approved_branch + '\n'
    approved_run = (
        workflow.count('\n  push:\n') == 1
        and approved_trigger in workflow
        and not re.search(r'(?m)^  (pull_request|schedule):', workflow)
        and os.environ.get('GITHUB_EVENT_NAME') == 'push'
        and os.environ.get('GITHUB_REF') == 'refs/heads/' + approved_branch
        and os.environ.get('GITHUB_REPOSITORY') == 'demonkingronin/DukeX'
    )
    if not approved_run:
        raise SystemExit('Unexpected automatic iOS workflow trigger; only owner-approved one-shot builds are permitted')
print('Pinned vcpkg baseline, overlay manifests and iOS cross configuration: OK')
PY

# Run Swift TOML editing tests without compiling the native emulator.
python3 ios/scripts/test-game-toml.py

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
# Check every SDL3 Apple framework before the expensive native dependency
# installation and full emulator link.
framework_smoke_library="$smoke_dir/ios-frameworks.dylib"
xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 \
  -isysroot "$sdkroot" -dynamiclib -framework CoreFoundation \
  -framework AudioToolbox \
  -framework AVFoundation \
  -framework CoreAudio \
  -framework CoreBluetooth \
  -framework CoreGraphics \
  -framework CoreHaptics \
  -framework CoreMotion \
  -framework CoreVideo \
  -framework Foundation \
  -framework GameController \
  -framework Metal \
  -framework QuartzCore \
  -framework UIKit \
  -x c -o "$framework_smoke_library" - <<'C'
int dukex_ios_framework_smoke(void) { return 0; }
C
xcrun lipo "$framework_smoke_library" -verify_arch arm64
echo 'DukeX iOS preflight passed: Swift parsed, Xcode project, and iPhoneOS framework linkage available.'
