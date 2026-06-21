#!/usr/bin/env bash
# ============================================================
# dl.sh — download a single URL with aria2c.
#
# Usage:   ./dl.sh <URL> [destination-folder]
#
# - Installs aria2c if it's missing (apt / dnf / yum / apk / brew).
# - Resumable, 8 parallel connections, retries on flaky networks.
# - Filename comes from the URL or the server's Content-Disposition header.
# - destination-folder is optional (default: current directory); created if
#   missing. e.g.:
#       ./dl.sh <URL> /workspace/runpod-slim/ComfyUI/models/diffusion_models
# - For gated HuggingFace files, export HF_TOKEN first (optional).
# ============================================================
set -euo pipefail

URL="${1:-}"
DEST="${2:-.}"
if [ -z "$URL" ] || [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 <URL> [destination-folder]" >&2
  exit 1
fi
mkdir -p "$DEST"

# ---- Prerequisite: aria2c (install if missing) ----
if ! command -v aria2c >/dev/null 2>&1; then
  echo "==> aria2c not found — installing..."
  SUDO=""
  [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"
  if   command -v apt-get >/dev/null 2>&1; then $SUDO apt-get update -qq && $SUDO apt-get install -y -qq aria2
  elif command -v dnf     >/dev/null 2>&1; then $SUDO dnf install -y aria2
  elif command -v yum     >/dev/null 2>&1; then $SUDO yum install -y aria2
  elif command -v apk     >/dev/null 2>&1; then $SUDO apk add --no-cache aria2
  elif command -v brew    >/dev/null 2>&1; then brew install aria2
  else
    echo "ERROR: no supported package manager found — install aria2 manually." >&2
    exit 1
  fi
fi

# ---- Optional HuggingFace auth for gated files ----
HDR=()
[ -n "${HF_TOKEN:-}" ] && HDR=(--header="Authorization: Bearer $HF_TOKEN")

# ---- Download ----
echo "==> Downloading: $URL"
echo "    -> $(cd "$DEST" && pwd)"
aria2c \
  --dir="$DEST" \
  --continue=true \
  --max-connection-per-server=8 \
  --split=8 \
  --min-split-size=8M \
  --max-tries=5 \
  --retry-wait=5 \
  --auto-file-renaming=false \
  --remote-time=true \
  --content-disposition-default-utf8=true \
  --console-log-level=warn \
  --summary-interval=5 \
  "${HDR[@]}" \
  "$URL"

echo "==> Done. Saved in: $(cd "$DEST" && pwd)"
