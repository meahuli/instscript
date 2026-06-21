#!/usr/bin/env bash
# ============================================================
# dl.sh — download a single URL with aria2c.
#
# Usage:   ./dl.sh <URL> [destination-folder]
#
# - Installs aria2c if missing (apt/dnf/yum/apk/brew).
# - Resumable, 8 connections, retries.
# - Picks the filename from the server's Content-Disposition header, so URLs
#   whose path is just an ID (e.g. Civitai .../api/download/models/12345) save
#   as the real model filename instead of "12345".
# - Optional tokens for gated files: HF_TOKEN (huggingface.co), CIVITAI_TOKEN (civitai.com).
# - destination-folder is optional (default: current dir); created if missing.
# ============================================================
set -eo pipefail

URL="${1:-}"; DEST="${2:-.}"
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || [ -z "$URL" ]; then
  echo "Usage: $0 <URL> [destination-folder]" >&2
  exit 1
fi
mkdir -p "$DEST"

# ---- Prerequisite: aria2c ----
if ! command -v aria2c >/dev/null 2>&1; then
  echo "==> aria2c not found — installing..."
  SUDO=""; if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi
  if   command -v apt-get >/dev/null 2>&1; then $SUDO apt-get update -qq && $SUDO apt-get install -y -qq aria2
  elif command -v dnf     >/dev/null 2>&1; then $SUDO dnf install -y aria2
  elif command -v yum     >/dev/null 2>&1; then $SUDO yum install -y aria2
  elif command -v apk     >/dev/null 2>&1; then $SUDO apk add --no-cache aria2
  elif command -v brew    >/dev/null 2>&1; then brew install aria2
  else echo "ERROR: no supported package manager — install aria2 manually." >&2; exit 1; fi
fi

# ---- Optional per-host auth for gated files ----
TOKEN=""
case "$URL" in
  *huggingface.co*) TOKEN="${HF_TOKEN:-}" ;;
  *civitai.com*)    TOKEN="${CIVITAI_TOKEN:-}" ;;
esac
CURL_AUTH=(); ARIA_AUTH=()
if [ -n "$TOKEN" ]; then
  CURL_AUTH=(-H "Authorization: Bearer $TOKEN")
  ARIA_AUTH=("--header=Authorization: Bearer $TOKEN")
fi

# ---- Resolve the real filename from Content-Disposition (fixes ID-only URLs) ----
OUT=""
CD=$(curl -sIL "${CURL_AUTH[@]}" --max-time 30 "$URL" 2>/dev/null | tr -d '\r' | grep -i '^content-disposition:' | tail -1) || true
if [ -n "$CD" ]; then
  OUT=$(printf '%s' "$CD" | grep -oiE "filename\*?=[^;]*" | tail -1 | sed -E "s/^filename\*?=//I; s/^UTF-8''//I" | tr -d '"') || true
fi
OUTARG=(); if [ -n "$OUT" ]; then OUTARG=(--out="$OUT"); fi

# ---- Download ----
echo "==> Downloading: $URL"
if [ -n "$OUT" ]; then echo "    filename (from Content-Disposition): $OUT"; fi
echo "    -> $(cd "$DEST" && pwd)"
ARIA_OPTS="--continue=true --max-connection-per-server=8 --split=8 --min-split-size=8M --max-tries=5 --retry-wait=5 --auto-file-renaming=false --remote-time=true --content-disposition-default-utf8=true --console-log-level=warn --summary-interval=5"
aria2c $ARIA_OPTS "${ARIA_AUTH[@]}" --dir="$DEST" "${OUTARG[@]}" "$URL"

echo "==> Done. Saved in: $(cd "$DEST" && pwd)${OUT:+/$OUT}"
