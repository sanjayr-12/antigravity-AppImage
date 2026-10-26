#!/usr/bin/env bash
# scripts/build-appimage.sh
# Packages Google Antigravity into an AppImage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ARCH="x86_64"
VERSION=""
DOWNLOAD_URL=""
TAR_FILE=""
DIST_DIR="${ROOT_DIR}/dist"
BUILD_DIR="${ROOT_DIR}/build"
KEEP_BUILD="false"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --version <ver>      Version string (e.g., 2.25.0). If omitted, inferred from app.asar or API.
  --url <url>          Direct download URL for Antigravity.tar.gz.
  --file <path>        Path to an existing Antigravity.tar.gz archive.
  --arch <arch>        Target architecture: x86_64 (default) or aarch64.
  --dist-dir <path>    Output directory for AppImage (default: ./dist).
  --keep-build         Do not delete intermediate build files after packaging.
  -h, --help           Show this help message.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="$2"
            shift 2
            ;;
        --url)
            DOWNLOAD_URL="$2"
            shift 2
            ;;
        --file)
            TAR_FILE="$2"
            shift 2
            ;;
        --arch)
            ARCH="$2"
            shift 2
            ;;
        --dist-dir)
            DIST_DIR="$2"
            shift 2
            ;;
        --keep-build)
            KEEP_BUILD="true"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

mkdir -p "$DIST_DIR"
mkdir -p "$BUILD_DIR"

# Standardize ARCH names
case "$ARCH" in
    x86_64|amd64|x64)
        APP_ARCH="x86_64"
        UPSTREAM_ARCH="linux-x64"
        ;;
    aarch64|arm64)
        APP_ARCH="aarch64"
        UPSTREAM_ARCH="linux-arm"
        ;;
    *)
        echo "Error: Unsupported architecture '$ARCH'. Supported: x86_64, aarch64" >&2
        exit 1
        ;;
esac

# 1. Resolve source tarball
TAR_PATH=""
if [[ -n "$TAR_FILE" ]]; then
    if [[ ! -f "$TAR_FILE" ]]; then
        echo "Error: Specified tar file does not exist: $TAR_FILE" >&2
        exit 1
    fi
    TAR_PATH="$(readlink -f "$TAR_FILE")"
    echo "==> Using local tarball: $TAR_PATH"
else
    # If no URL provided, query upstream check script
    if [[ -z "$DOWNLOAD_URL" ]]; then
        echo "==> Querying upstream API for download URL..."
        read -r LATEST_VERSION EXECUTION_ID < <(python3 -c '
import urllib.request, json
try:
    req = urllib.request.Request("https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/releases", headers={"User-Agent": "curl/7.68.0"})
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        latest = data[0]
        print(f"{latest.get(\"version\", \"\")} {latest.get(\"execution_id\", \"\").rstrip(\"/\")}")
except Exception as e:
    import sys; print(f"Error: {e}", file=sys.stderr); sys.exit(1)
')
        if [[ -z "$VERSION" ]]; then
            VERSION="$LATEST_VERSION"
        fi
        DOWNLOAD_URL="https://storage.googleapis.com/antigravity-public/antigravity-hub/${LATEST_VERSION}-${EXECUTION_ID}/${UPSTREAM_ARCH}/Antigravity.tar.gz"
    fi

    DOWNLOAD_DEST="${BUILD_DIR}/Antigravity-${UPSTREAM_ARCH}.tar.gz"
    echo "==> Downloading Antigravity from: $DOWNLOAD_URL"
    curl -fL --retry 3 --connect-timeout 15 -o "$DOWNLOAD_DEST" "$DOWNLOAD_URL"
    TAR_PATH="$DOWNLOAD_DEST"
fi

# 2. Extract tarball
EXTRACT_DIR="${BUILD_DIR}/extracted_${APP_ARCH}"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

echo "==> Extracting $TAR_PATH..."
tar -xzf "$TAR_PATH" -C "$EXTRACT_DIR"

# Locate extracted app directory (typically Antigravity-x64 or similar)
APP_SOURCE_DIR=$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
if [[ -z "$APP_SOURCE_DIR" || ! -f "$APP_SOURCE_DIR/antigravity" ]]; then
    if [[ -f "$EXTRACT_DIR/antigravity" ]]; then
        APP_SOURCE_DIR="$EXTRACT_DIR"
    else
        echo "Error: Could not locate 'antigravity' executable inside extracted archive." >&2
        exit 1
    fi
fi

# 3. Assemble AppDir
APPDIR="${BUILD_DIR}/Antigravity.AppDir"
rm -rf "$APPDIR"
mkdir -p "${APPDIR}/usr/bin"
mkdir -p "${APPDIR}/usr/lib/antigravity"
mkdir -p "${APPDIR}/usr/share/applications"
mkdir -p "${APPDIR}/usr/share/metainfo"
mkdir -p "${APPDIR}/usr/share/icons/hicolor/512x512/apps"

echo "==> Assembling AppDir structure..."
cp -a "$APP_SOURCE_DIR"/* "${APPDIR}/usr/lib/antigravity/"

# Symlink main binary in usr/bin
ln -sf "../lib/antigravity/antigravity" "${APPDIR}/usr/bin/antigravity"

# Copy AppRun
cp "${ROOT_DIR}/scripts/AppRun" "${APPDIR}/AppRun"
chmod +x "${APPDIR}/AppRun"

# Copy Desktop entry and AppStream metadata
cp "${ROOT_DIR}/assets/antigravity.desktop" "${APPDIR}/antigravity.desktop"
cp "${ROOT_DIR}/assets/antigravity.desktop" "${APPDIR}/usr/share/applications/antigravity.desktop"
if [[ -f "${ROOT_DIR}/assets/antigravity.appdata.xml" ]]; then
    cp "${ROOT_DIR}/assets/antigravity.appdata.xml" "${APPDIR}/usr/share/metainfo/antigravity.appdata.xml"
    cp "${ROOT_DIR}/assets/antigravity.appdata.xml" "${APPDIR}/usr/share/metainfo/com.google.antigravity.appdata.xml"
fi

# Extract high-res icon from app.asar, or fall back to bundled asset
ICON_DEST="${APPDIR}/antigravity.png"
ICON_EXTRACTED="false"

ASAR_FILE="${APPDIR}/usr/lib/antigravity/resources/app.asar"
if [[ -f "$ASAR_FILE" ]]; then
    python3 -c '
import sys, struct, json

asar_path = sys.argv[1]
out_path = sys.argv[2]
try:
    with open(asar_path, "rb") as f:
        magic, header_size, header_size2, json_len = struct.unpack("<IIII", f.read(16))
        header_json = json.loads(f.read(json_len).decode("utf-8"))
        base_offset = 8 + header_size
        files = header_json.get("files", {})
        if "icon.png" in files:
            pinfo = files["icon.png"]
            f.seek(base_offset + int(pinfo["offset"]))
            with open(out_path, "wb") as out:
                out.write(f.read(int(pinfo["size"])))
            sys.exit(0)
except Exception as e:
    pass
sys.exit(1)
' "$ASAR_FILE" "$ICON_DEST" && ICON_EXTRACTED="true" || true
fi

if [[ "$ICON_EXTRACTED" != "true" || ! -f "$ICON_DEST" ]]; then
    echo "==> Using fallback icon from assets/antigravity.png"
    cp "${ROOT_DIR}/assets/antigravity.png" "$ICON_DEST"
else
    echo "==> Extracted high-resolution 512x512 icon from app.asar"
fi

cp "$ICON_DEST" "${APPDIR}/.DirIcon"
cp "$ICON_DEST" "${APPDIR}/usr/share/icons/hicolor/512x512/apps/antigravity.png"

# Inspect version from package.json if not set
if [[ -z "$VERSION" && -f "$ASAR_FILE" ]]; then
    VERSION=$(python3 -c '
import sys, struct, json
asar_path = sys.argv[1]
try:
    with open(asar_path, "rb") as f:
        magic, header_size, header_size2, json_len = struct.unpack("<IIII", f.read(16))
        header_json = json.loads(f.read(json_len).decode("utf-8"))
        base_offset = 8 + header_size
        files = header_json.get("files", {})
        if "package.json" in files:
            pinfo = files["package.json"]
            f.seek(base_offset + int(pinfo["offset"]))
            pkg = json.loads(f.read(int(pinfo["size"])).decode("utf-8"))
            print(pkg.get("version", "").strip())
except Exception:
    pass
' "$ASAR_FILE")
fi

VERSION="${VERSION:-unknown}"
echo "==> Packaging Antigravity version: $VERSION ($APP_ARCH)"

# Fix file permissions for AppImage standards
chmod 0755 "${APPDIR}/usr/lib/antigravity/antigravity"
if [[ -f "${APPDIR}/usr/lib/antigravity/chrome-sandbox" ]]; then
    chmod 4755 "${APPDIR}/usr/lib/antigravity/chrome-sandbox" 2>/dev/null || chmod 0755 "${APPDIR}/usr/lib/antigravity/chrome-sandbox"
fi

# 4. Obtain appimagetool
APPIMAGETOOL="${BUILD_DIR}/appimagetool"
if command -v appimagetool >/dev/null 2>&1; then
    APPIMAGETOOL="$(command -v appimagetool)"
elif [[ ! -x "$APPIMAGETOOL" ]]; then
    echo "==> Downloading appimagetool for ${APP_ARCH}..."
    TOOL_URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${APP_ARCH}.AppImage"
    curl -fsSL --retry 3 -o "$APPIMAGETOOL" "$TOOL_URL"
    chmod +x "$APPIMAGETOOL"
fi

# 5. Build the AppImage
OUTPUT_APPIMAGE="${DIST_DIR}/Antigravity-${VERSION}-${APP_ARCH}.AppImage"
rm -f "$OUTPUT_APPIMAGE" "${OUTPUT_APPIMAGE}.zsync" "$(basename "$OUTPUT_APPIMAGE").zsync"

UPDATE_INFO_ARGS=()
if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    REPO_OWNER="${GITHUB_REPOSITORY%/*}"
    REPO_NAME="${GITHUB_REPOSITORY#*/}"
    UPDATE_INFO="gh-releases-zsync|${REPO_OWNER}|${REPO_NAME}|latest|Antigravity-*${APP_ARCH}.AppImage.zsync"
    echo "==> Embedding AppImage update information: $UPDATE_INFO"
    UPDATE_INFO_ARGS=("-u" "$UPDATE_INFO")
fi

echo "==> Running appimagetool..."
export ARCH="$APP_ARCH"

# If running in environment without FUSE support, use --appimage-extract-and-run
if ! "$APPIMAGETOOL" --version >/dev/null 2>&1; then
    echo "==> Running appimagetool with --appimage-extract-and-run (no host FUSE)..."
    "$APPIMAGETOOL" --appimage-extract-and-run "${UPDATE_INFO_ARGS[@]}" "$APPDIR" "$OUTPUT_APPIMAGE"
else
    "$APPIMAGETOOL" "${UPDATE_INFO_ARGS[@]}" "$APPDIR" "$OUTPUT_APPIMAGE"
fi

# appimagetool only writes a .zsync when zsyncmake is available. Without it the
# update information is embedded but no delta-update file is produced, so
# AppImageUpdate / Gear Lever silently fail for every user.
#
# It also writes the .zsync into the current working directory (named after the
# output basename) rather than next to the target, so move it into DIST_DIR to
# keep the release assets together.
ZSYNC_PATH="${OUTPUT_APPIMAGE}.zsync"
if [[ ${#UPDATE_INFO_ARGS[@]} -gt 0 ]]; then
    STRAY_ZSYNC="$(basename "$OUTPUT_APPIMAGE").zsync"
    if [[ ! -f "$ZSYNC_PATH" && -f "$STRAY_ZSYNC" ]]; then
        mv "$STRAY_ZSYNC" "$ZSYNC_PATH"
    fi
    if [[ ! -f "$ZSYNC_PATH" ]]; then
        echo "Error: update information was embedded but no .zsync was generated." >&2
        echo "       Install the 'zsync' package (provides zsyncmake) and rebuild." >&2
        exit 1
    fi
fi

echo "==> AppImage built successfully: $OUTPUT_APPIMAGE"

# 6. Generate SHA256 checksums
echo "==> Generating SHA256 checksums..."
SUMS_FILE="${DIST_DIR}/SHA256SUMS.txt"
: > "$SUMS_FILE"
( cd "$DIST_DIR" && sha256sum "$(basename "$OUTPUT_APPIMAGE")" ) >> "$SUMS_FILE"
if [[ -f "$ZSYNC_PATH" ]]; then
    ( cd "$DIST_DIR" && sha256sum "$(basename "$ZSYNC_PATH")" ) >> "$SUMS_FILE"
fi
cat "$SUMS_FILE"

# 7. Cleanup unless requested
if [[ "$KEEP_BUILD" != "true" ]]; then
    echo "==> Cleaning up build directory..."
    rm -rf "$EXTRACT_DIR" "$APPDIR"
fi

echo "==> Done! Release assets are ready in: $DIST_DIR"
