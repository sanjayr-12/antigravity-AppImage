#!/usr/bin/env bash
# scripts/check-upstream.sh
# Checks Google's Antigravity Auto-Updater API for the latest version
# and determines whether a new AppImage release needs to be built.

set -euo pipefail

API_URL="https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/releases"
ARCH="${1:-x64}" # x64 or arm64

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

echo "==> Upstream latest version: $LATEST_VERSION (execution_id: $EXECUTION_ID)"

# Map arch to upstream directory name
UPSTREAM_ARCH="linux-x64"
if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" || "$ARCH" == "linux-arm" ]]; then
    UPSTREAM_ARCH="linux-arm"
fi

DOWNLOAD_URL="https://storage.googleapis.com/antigravity-public/antigravity-hub/${LATEST_VERSION}-${EXECUTION_ID}/${UPSTREAM_ARCH}/Antigravity.tar.gz"
TAG_NAME="v${LATEST_VERSION}"

echo "==> Upstream download URL: $DOWNLOAD_URL"

# Check if release already exists in GitHub repository
UPDATE_NEEDED="true"
REPO="${GITHUB_REPOSITORY:-}"

if [[ -n "${FORCE_BUILD:-}" && "${FORCE_BUILD}" == "true" ]]; then
    echo "==> FORCE_BUILD is set to true. Forcing update."
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
    echo "tag_name=${TAG_NAME}" >> "$GITHUB_OUTPUT"
    echo "update_needed=${UPDATE_NEEDED}" >> "$GITHUB_OUTPUT"
fi

echo "----------------------------------------"
echo "Summary:"
echo "  Version:       $LATEST_VERSION"
echo "  Execution ID:  $EXECUTION_ID"
echo "  Tag:           $TAG_NAME"
echo "  Download URL:  $DOWNLOAD_URL"
echo "  Update Needed: $UPDATE_NEEDED"
echo "----------------------------------------"
