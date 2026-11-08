#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
BUILD_DIR="${XEMU_IOS_BUILD_DIR:-${SOURCE_DIR}/build-ios-arm64}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-16.0}"
SDK_NAME="${SDK_NAME:-iphoneos}"
VCPKG_PREFIX="${XEMU_IOS_VCPKG_PREFIX:-${VCPKG_ROOT:-}/installed/arm64-ios}"
MOLTENVK_ROOT="${MOLTENVK_ROOT:-}"
XEMU_IOS_COROUTINE_BACKEND="${XEMU_IOS_COROUTINE_BACKEND:-sigaltstack}"

for path in "${SOURCE_DIR}" "${BUILD_DIR}"; do
  case "${path}" in
    *[[:space:]:]*)
      printf 'xemu configure rejects spaces or colons in source/build paths.\n' >&2
      printf 'Source: %s\nBuild:  %s\n' "${SOURCE_DIR}" "${BUILD_DIR}" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${VCPKG_PREFIX}" || ! -d "${VCPKG_PREFIX}" ]]; then
  printf 'Missing arm64-ios vcpkg prefix. Set XEMU_IOS_VCPKG_PREFIX or VCPKG_ROOT.\n' >&2
  exit 1
fi

if [[ -z "${MOLTENVK_ROOT}" || ! -f "${MOLTENVK_ROOT}/include/vulkan/vulkan.h" ]]; then
  printf 'Missing MoltenVK iOS headers. Set MOLTENVK_ROOT.\n' >&2
  printf 'Expected: %s\n' "${MOLTENVK_ROOT:-<unset>}/include/vulkan/vulkan.h" >&2
  exit 1
fi

SDKROOT="$(xcrun --sdk "${SDK_NAME}" --show-sdk-path)"
CLANG="$(xcrun --sdk "${SDK_NAME}" --find clang)"
CLANGXX="$(xcrun --sdk "${SDK_NAME}" --find clang++)"
AR="$(xcrun --sdk "${SDK_NAME}" --find ar)"
RANLIB="$(xcrun --sdk "${SDK_NAME}" --find ranlib)"
NM="$(xcrun --sdk "${SDK_NAME}" --find nm)"
STRIP="$(xcrun --sdk "${SDK_NAME}" --find strip)"
PKG_CONFIG="${PKG_CONFIG:-pkg-config}"
# CMake-backed Meson subprojects (SDL3, volk and glslang) must use a host
# executable, not one inferred as an iOS target tool.
if ! command -v cmake >/dev/null 2>&1; then
  printf '::error::Host CMake is required for DukeX iOS subprojects.\n' >&2
  exit 1
fi
DUKEX_IOS_CMAKE="$(command -v cmake)"
"$DUKEX_IOS_CMAKE" --version
export DUKEX_IOS_CMAKE
TARGET="arm64-apple-ios${IOS_DEPLOYMENT_TARGET}"
COMMON_FLAGS=(
  "-target" "${TARGET}"
  "-isysroot" "${SDKROOT}"
  "-miphoneos-version-min=${IOS_DEPLOYMENT_TARGET}"
  "-I${MOLTENVK_ROOT}/include"
  "-DVK_ENABLE_BETA_EXTENSIONS=1"
  "-DVK_USE_PLATFORM_METAL_EXT=1"
  "-DXBOX"
)
COMMON_LDFLAGS=(
  "${COMMON_FLAGS[@]}"
  "-framework" "CoreFoundation"
)
EXTRA_CONFIGURE_ARGS=()
if [[ -n "${XEMU_IOS_CONFIGURE_ARGS:-}" ]]; then
  read -r -a EXTRA_CONFIGURE_ARGS <<< "${XEMU_IOS_CONFIGURE_ARGS}"
fi
read -r -a NINJA_TARGETS <<< "${XEMU_IOS_NINJA_TARGETS:-qemu-system-i386 libxemu-ios-core.dylib}"

VULKAN_PKG_CONFIG_DIR="${BUILD_DIR}/ios-pkgconfig"
mkdir -p "${VULKAN_PKG_CONFIG_DIR}"
cat > "${VULKAN_PKG_CONFIG_DIR}/vulkan.pc" <<EOF
prefix=${MOLTENVK_ROOT}
includedir=\${prefix}/include

Name: vulkan
Description: MoltenVK headers for iOS runtime loading through volk
Version: 1.3.0
Libs:
Cflags: -I\${includedir} -DVK_ENABLE_BETA_EXTENSIONS=1 -DVK_USE_PLATFORM_METAL_EXT=1
EOF

export PKG_CONFIG_LIBDIR="${VULKAN_PKG_CONFIG_DIR}:${VCPKG_PREFIX}/lib/pkgconfig:${VCPKG_PREFIX}/debug/lib/pkgconfig"
export PKG_CONFIG_PATH="${PKG_CONFIG_LIBDIR}"
export PKG_CONFIG_SYSROOT_DIR="/"
export AR RANLIB NM STRIP PKG_CONFIG

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

"${SOURCE_DIR}/configure" \
  --cross-prefix= \
  --cc="${CLANG}" \
  --cxx="${CLANGXX}" \
  --objcc="${CLANG}" \
  --host-cc=cc \
  --target-list=i386-softmmu \
  --enable-system \
  --enable-tcg \
  --disable-tcg-interpreter \
  --disable-rust \
  --disable-docs \
  --disable-tools \
  --disable-guest-agent \
  --disable-plugins \
  --disable-bsd-user \
  --disable-linux-user \
  --disable-werror \
  --enable-slirp \
  --disable-slirp-smbd \
  --disable-capstone \
  --disable-coreaudio \
  --disable-sdl-image \
  --enable-fdt=internal \
  --enable-sdl \
  --enable-opengl \
  --enable-pixman \
  --audio-drv-list= \
  --with-coroutine="${XEMU_IOS_COROUTINE_BACKEND}" \
  --extra-cflags="${COMMON_FLAGS[*]}" \
  --extra-cxxflags="${COMMON_FLAGS[*]}" \
  --extra-objcflags="${COMMON_FLAGS[*]}" \
  --extra-ldflags="${COMMON_LDFLAGS[*]}" \
  "${EXTRA_CONFIGURE_ARGS[@]+"${EXTRA_CONFIGURE_ARGS[@]}"}"

# Fail before compilation if QEMU did not produce an iOS CMake machine
# file. Otherwise SDL3 silently configures macOS/Cocoa and fails during
# device compilation because desktop OpenGL types are unavailable.
if ! grep -Fq "CMAKE_SYSTEM_NAME = 'iOS'" "${BUILD_DIR}/config-meson.cross"; then
  printf '::error::Meson cross file is missing CMAKE_SYSTEM_NAME=iOS.\n' >&2
  exit 1
fi

# configure creates a fresh QEMU pyvenv. Install PyYAML into that same
# interpreter before Ninja invokes subprojects/genconfig/gen_config.py.
VENV_PYTHON="${BUILD_DIR}/pyvenv/bin/python3"
if [[ ! -x "${VENV_PYTHON}" ]]; then
  printf '::error::QEMU did not create the expected Python virtual environment.\n' >&2
  exit 1
fi
"${VENV_PYTHON}" "${SOURCE_DIR}/python/scripts/mkvenv.py" ensuregroup --online \
  "${SOURCE_DIR}/pythondeps.toml" ios-build
"${VENV_PYTHON}" -c 'import yaml; print("DukeX iOS PyYAML available:", yaml.__version__)'

ninja -C "${BUILD_DIR}" "${NINJA_TARGETS[@]}" "$@"
