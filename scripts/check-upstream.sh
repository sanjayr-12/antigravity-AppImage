#!/usr/bin/env bash
# scripts/check-upstream.sh
# Checks Google's Antigravity Auto-Updater API for the latest version
# and determines whether a new AppImage release needs to be built.

set -euo pipefail

API_URL="https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/releases"

if [[ -n "${CUSTOM_VERSION:-}" && -n "${CUSTOM_EXECUTION_ID:-}" ]]; then
    echo "==> Using manually specified upstream version: ${CUSTOM_VERSION} (execution_id: ${CUSTOM_EXECUTION_ID})"
    LATEST_VERSION="${CUSTOM_VERSION}"
    EXECUTION_ID="${CUSTOM_EXECUTION_ID}"
else
    echo "==> Fetching latest release info from Antigravity auto-updater..."
    RELEASES_JSON=$(curl -fsSL --retry 3 --connect-timeout 10 "$API_URL")

    if [[ -z "$RELEASES_JSON" || "$RELEASES_JSON" == "[]" ]]; then
        echo "Error: Failed to fetch releases or received empty response from $API_URL" >&2
        exit 1
    fi

    # Extract version and execution_id from the first (latest) release entry using python
    read -r LATEST_VERSION EXECUTION_ID < <(python3 -c '
import sys, json
data = json.loads(sys.stdin.read())
if not data:
    sys.exit(1)
latest = data[0]
version = latest.get("version", "").strip()
exec_id = str(latest.get("execution_id", "")).strip().rstrip("/")
print(f"{version} {exec_id}")
' <<< "$RELEASES_JSON")

    if [[ -z "$LATEST_VERSION" || -z "$EXECUTION_ID" ]]; then
        echo "Error: Unable to parse version or execution_id from upstream API." >&2
        exit 1
    fi
fi

echo "==> Upstream latest version: $LATEST_VERSION (execution_id: $EXECUTION_ID)"

# Upstream publishes one archive per architecture. The linux-arm one is probed
# instead of assumed, so a release that only ships linux-x64 still succeeds.
STORAGE_BASE="https://storage.googleapis.com/antigravity-public/antigravity-hub/${LATEST_VERSION}-${EXECUTION_ID}"
DOWNLOAD_URL="${STORAGE_BASE}/linux-x64/Antigravity.tar.gz"
DOWNLOAD_URL_ARM64="${STORAGE_BASE}/linux-arm/Antigravity.tar.gz"
TAG_NAME="v${LATEST_VERSION}"

echo "==> Upstream x86_64 download URL: $DOWNLOAD_URL"
echo "==> Upstream aarch64 download URL: $DOWNLOAD_URL_ARM64"

ARM64_AVAILABLE="false"
if curl -fsI --retry 2 --connect-timeout 10 -o /dev/null "$DOWNLOAD_URL_ARM64"; then
    ARM64_AVAILABLE="true"
    echo "==> aarch64 archive found."
else
    echo "==> aarch64 archive not found for this release; the aarch64 build will be skipped." >&2
fi

# Check if release already exists in GitHub repository
UPDATE_NEEDED="true"
REPO="${GITHUB_REPOSITORY:-}"

if [[ -n "${FORCE_BUILD:-}" && "${FORCE_BUILD}" == "true" ]]; then
    echo "==> FORCE_BUILD is set to true. Forcing update."
    UPDATE_NEEDED="true"
elif [[ -n "${CUSTOM_VERSION:-}" ]]; then
    echo "==> CUSTOM_VERSION is set. Forcing update."
    UPDATE_NEEDED="true"
elif [[ -n "$REPO" ]]; then
    echo "==> Checking if release tag '$TAG_NAME' already exists in $REPO..."
    # Check using gh CLI if available, else curl GitHub API
    if command -v gh >/dev/null 2>&1; then
        if gh release view "$TAG_NAME" --repo "$REPO" >/dev/null 2>&1; then
            echo "==> Release $TAG_NAME already exists in $REPO. No update needed."
            UPDATE_NEEDED="false"
        else
            echo "==> Release $TAG_NAME does not exist in $REPO. New update needed!"
            UPDATE_NEEDED="true"
        fi
    else
        STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Accept: application/vnd.github+json" \
            ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
            "https://api.github.com/repos/${REPO}/releases/tags/${TAG_NAME}")
        if [[ "$STATUS_CODE" == "200" ]]; then
            echo "==> Release $TAG_NAME already exists on GitHub (HTTP 200). No update needed."
            UPDATE_NEEDED="false"
        else
            echo "==> Release $TAG_NAME not found on GitHub (HTTP $STATUS_CODE). New update needed!"
            UPDATE_NEEDED="true"
        fi
    fi
else
    echo "==> GITHUB_REPOSITORY not set (running locally). Defaulting UPDATE_NEEDED=true."
fi

# Export outputs to GITHUB_OUTPUT if available
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "version=${LATEST_VERSION}" >> "$GITHUB_OUTPUT"
    echo "execution_id=${EXECUTION_ID}" >> "$GITHUB_OUTPUT"
    echo "download_url=${DOWNLOAD_URL}" >> "$GITHUB_OUTPUT"
    echo "download_url_arm64=${DOWNLOAD_URL_ARM64}" >> "$GITHUB_OUTPUT"
    echo "arm64_available=${ARM64_AVAILABLE}" >> "$GITHUB_OUTPUT"
    echo "tag_name=${TAG_NAME}" >> "$GITHUB_OUTPUT"
    echo "update_needed=${UPDATE_NEEDED}" >> "$GITHUB_OUTPUT"
fi

echo "----------------------------------------"
echo "Summary:"
echo "  Version:        $LATEST_VERSION"
echo "  Execution ID:   $EXECUTION_ID"
echo "  Tag:            $TAG_NAME"
echo "  Download URL:   $DOWNLOAD_URL"
echo "  ARM64 URL:      $DOWNLOAD_URL_ARM64 ($ARM64_AVAILABLE)"
echo "  Update Needed:  $UPDATE_NEEDED"
echo "----------------------------------------"
