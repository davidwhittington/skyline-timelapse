#!/usr/bin/env bash
# Grab a single timestamped frame from RTSP. Self-gated to daylight via is_daylight.py.
# Never crash the timer: missing frames are acceptable.

set -u
set -o pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${TIMELAPSE_ENV:-/etc/timelapse/timelapse.env}"

if [[ -r "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
fi

: "${RTSP_URL:?RTSP_URL not set}"
: "${FRAME_DIR:=/var/lib/timelapse/frames}"
: "${LOCK_FILE:=/var/lock/timelapse-capture.lock}"

mkdir -p "$FRAME_DIR"

# Daylight gate
if ! "$SELF_DIR/is_daylight.py"; then
  exit 0
fi

# Single-instance lock; bail if another capture is still running
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "capture already running; skipping" >&2
  exit 0
fi

TS="$(date '+%Y-%m-%d %H:%M')"
OUT="$FRAME_DIR/$(date +%Y%m%d_%H%M%S).jpg"

# Single-frame grab over TCP, with timestamp burned bottom-right.
# Note: timeout wrapping protects against an RTSP hang.
if ! timeout 25 ffmpeg -nostdin -loglevel error \
      -rtsp_transport tcp -y -i "$RTSP_URL" -frames:v 1 \
      -vf "drawtext=text='${TS}':x=w-tw-20:y=h-th-20:fontsize=36:fontcolor=white:box=1:boxcolor=black@0.4:boxborderw=8" \
      "$OUT"; then
  echo "capture failed at $TS (camera unreachable?)" >&2
  rm -f "$OUT"
  exit 0
fi
