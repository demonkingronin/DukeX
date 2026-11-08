#!/usr/bin/env bash
set -euo pipefail

# Bootstrap the pinned vcpkg tool on a macOS CI host. If its prebuilt binary
# is temporarily unavailable, build the same tagged tool release from an
# upstream SHA-512-verified source archive instead of using an unpinned tool.
VCPKG_ROOT="${1:?Usage: bootstrap-vcpkg-ios.sh /path/to/pinned/vcpkg}"
if [[ ! -f "$VCPKG_ROOT/scripts/vcpkg-tool-metadata.txt" ]]; then
  echo '::error::Pinned vcpkg tool metadata was not found.' >&2
  exit 1
fi

log="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dukex-vcpkg-bootstrap.log"
for attempt in 1 2 3 4; do
  echo "Bootstrapping pinned vcpkg binary (attempt $attempt/4)"
  if "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics 2>&1 | tee "$log"; then
    "$VCPKG_ROOT/vcpkg" version --disable-metrics
    exit 0
  fi
  if ! grep -Eiq 'curl: \((18|28|52|56)\)|returned error: (429|500|502|503|504)|HTTP[ /]+(429|500|502|503|504)|timed out|connection reset' "$log"; then
    echo '::error::vcpkg bootstrap failed for a non-network reason; not retrying.' >&2
    exit 1
  fi
  if [[ "$attempt" -lt 4 ]]; then
    delay=$((10 * (1 << (attempt - 1))))
    echo "::warning::Transient vcpkg download failure; retrying in $delay seconds."
    sleep "$delay"
  fi
done

# vcpkg's upstream bootstrap.sh uses these exact metadata fields for its
# source fallback on platforms without a prebuilt binary.
# shellcheck source=/dev/null
source "$VCPKG_ROOT/scripts/vcpkg-tool-metadata.txt"
if [[ ! "${VCPKG_TOOL_RELEASE_TAG:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
   [[ ! "${VCPKG_TOOL_SOURCE_SHA:-}" =~ ^[0-9a-fA-F]{128}$ ]]; then
  echo '::error::Missing or invalid vcpkg source release tag/SHA-512.' >&2
  exit 1
fi

echo "::warning::Pinned vcpkg executable download is unavailable; compiling vcpkg-tool ${VCPKG_TOOL_RELEASE_TAG} from verified source."
downloads="$VCPKG_ROOT/downloads"
mkdir -p "$downloads"
archive="$downloads/vcpkg-tool-${VCPKG_TOOL_RELEASE_TAG}.zip"
archive_part="${archive}.part"
rm -f "$archive_part"

# Both URLs serve the identical upstream tag archive. The archive must match
# vcpkg's own pinned SHA-512 before extraction, regardless of download host.
source_urls=(
  "https://codeload.github.com/microsoft/vcpkg-tool/zip/refs/tags/${VCPKG_TOOL_RELEASE_TAG}"
  "https://github.com/microsoft/vcpkg-tool/archive/${VCPKG_TOOL_RELEASE_TAG}.zip"
)
if [[ -f "$archive" ]]; then
  printf '%s  %s\n' "$VCPKG_TOOL_SOURCE_SHA" "$archive" | shasum -a 512 -c -
else
  downloaded=false
  for url in "${source_urls[@]}"; do
    rm -f "$archive_part"
    echo "Downloading pinned vcpkg-tool source archive from $url"
    if curl --fail --location --retry 2 --retry-delay 3 \
       --connect-timeout 20 --max-time 180 --output "$archive_part" "$url"; then
      # A checksum mismatch is a hard failure, not a reason to try another URL.
      printf '%s  %s\n' "$VCPKG_TOOL_SOURCE_SHA" "$archive_part" | shasum -a 512 -c -
      mv "$archive_part" "$archive"
      downloaded=true
      break
    fi
  done
  if [[ "$downloaded" != true ]]; then
    echo '::error::Both pinned vcpkg-tool source download URLs failed.' >&2
    exit 1
  fi
fi

src_base="$VCPKG_ROOT/buildtrees/_vcpkg/src"
source_dir="$src_base/vcpkg-tool-${VCPKG_TOOL_RELEASE_TAG}"
build_dir="$VCPKG_ROOT/buildtrees/_vcpkg/build"
mkdir -p "$src_base"
unzip -q "$archive" -d "$src_base"
if [[ ! -f "$source_dir/CMakeLists.txt" ]]; then
  echo '::error::Pinned vcpkg-tool source archive has an unexpected layout.' >&2
  exit 1
fi

# Build a *host* macOS tool, not an iOS binary. These codeload endpoints
# retain the exact SHA-512 validations in upstream Findfmt/FindCMakeRC.
cmake -S "$source_dir" -B "$build_dir" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DVCPKG_DEVELOPMENT_WARNINGS=OFF \
  -DBUILD_TESTING=OFF \
  -DVCPKG_FMT_URL=https://codeload.github.com/fmtlib/fmt/tar.gz/refs/tags/12.1.0 \
  -DVCPKG_CMAKERC_URL=https://codeload.github.com/vector-of-bool/cmrc/tar.gz/refs/tags/2.0.1
cmake --build "$build_dir" --target vcpkg --parallel "${VCPKG_BOOTSTRAP_JOBS:-3}"
if [[ ! -f "$build_dir/vcpkg" ]]; then
  echo '::error::Source build did not produce the vcpkg executable.' >&2
  exit 1
fi
install -m 0755 "$build_dir/vcpkg" "$VCPKG_ROOT/vcpkg"
touch "$VCPKG_ROOT/vcpkg.disable-metrics"
"$VCPKG_ROOT/vcpkg" version --disable-metrics
