#!/usr/bin/env bash
# Stitch the day's frames, publish to R2 (dated + latest), prune archive, clear frames.

set -euo pipefail

ENV_FILE="${TIMELAPSE_ENV:-/etc/timelapse/timelapse.env}"
if [[ -r "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
fi

: "${FRAME_DIR:=/var/lib/timelapse/frames}"
: "${OUT_DIR:=/var/lib/timelapse/out}"
: "${OUTPUT_FPS:=24}"
: "${R2_REMOTE:=r2}"
: "${R2_BUCKET:?R2_BUCKET not set}"
: "${RETAIN_DAYS:=30}"

mkdir -p "$OUT_DIR"

DATE="$(date +%Y-%m-%d)"
MP4="$OUT_DIR/$DATE.mp4"

shopt -s nullglob
FRAMES=("$FRAME_DIR"/*.jpg)
if (( ${#FRAMES[@]} == 0 )); then
  echo "no frames for $DATE; nothing to publish" >&2
  exit 0
fi

ffmpeg -y -loglevel error \
  -framerate "$OUTPUT_FPS" -pattern_type glob -i "$FRAME_DIR/*.jpg" \
  -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart \
  "$MP4"

rclone copyto "$MP4" "$R2_REMOTE:$R2_BUCKET/archive/$DATE.mp4"
rclone copyto "$MP4" "$R2_REMOTE:$R2_BUCKET/latest.mp4" \
  --header-upload "Cache-Control: public, max-age=300"

rclone delete "$R2_REMOTE:$R2_BUCKET/archive/" --min-age "${RETAIN_DAYS}d" || true

rm -f "$FRAME_DIR"/*.jpg
rm -f "$MP4"
