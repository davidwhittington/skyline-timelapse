# Skyline Timelapse Pipeline — Design Spec

**Status:** ready for build · **Target runtime:** LXC on Proxmox · **Author handoff:** Claude Code

## 1. Objective

Publish a daily, silent, auto-generated timelapse of the downtown skyline (and later the coffee plant) **without exposing the camera system**. The public only ever touches a finished artifact on Cloudflare R2. Nothing inbound to the LAN; the pipeline pulls RTSP locally and pushes the rendered MP4 outward.

## 2. Threat model / non-negotiables

- **Push, don't pull.** No port-forward, no inbound exposure. The box reaches the camera over the LAN and pushes results to R2.
- **Derived artifact only.** Public sees `latest.mp4` + an archive on R2. Protect, the NVR, and every other camera stay unreachable.
- **After-the-fact.** A timelapse destroys real-time pattern-of-life by design — published only after dusk.
- **No audio.** Mic disabled at source; output is silent regardless.
- **No secrets in repo or logs.** R2 credentials live only in an rclone config / env file with `0600` perms, outside the repo. Never echoed, never committed, never printed to logs.
- **Source isolation.** Rooftop camera should sit on its own VLAN with no route to the rest of the fleet; the pipeline host only needs to reach that one camera's RTSP endpoint + the internet for R2.

## 3. Architecture

```
[Rooftop cam] --RTSP(LAN)--> [LXC: capture.sh every 60s, daylight-gated]
                                      |
                              frames/*.jpg (timestamped)
                                      |
                          [assemble-publish.sh @ 22:00 local]
                                      |
                          ffmpeg stitch -> YYYY-MM-DD.mp4
                                      |
                              rclone --> R2 bucket
                                   /archive/YYYY-MM-DD.mp4  (rolling, pruned)
                                   /latest.mp4              (stable URL, short cache)
                                   /index.html             (tiny <video> page)
                                      |
                              [Public] <-- R2 public domain only
```

## 4. Host / runtime

- Debian LXC on Proxmox (`nuc14pro` or `pve-02`), **not** the NVR.
- Packages: `ffmpeg`, `rclone`, `python3`, `python3-astral` (daylight calc), `cron` or systemd timers (prefer systemd timers).
- Unprivileged container is fine. CPU is trivial; one libx264 encode/day.

## 5. Configuration (`timelapse.env`, no secrets)

| Var | Default | Notes |
|---|---|---|
| `RTSP_URL` | — | Per-camera Protect RTSP, e.g. `rtsp://<protect-host>:7447/<streamId>`. Start against current rooftop cam / 360; swap to DSLR later — no code change. |
| `CAPTURE_INTERVAL_SEC` | `60` | ~60s gives ≈30–35s clip at 24fps in summer. |
| `OUTPUT_FPS` | `24` | Playback framerate of the rendered clip. |
| `LAT` / `LON` | `29.749` / `-95.34` | Houston (EaDo). Drives daylight gate. |
| `DAWN_BUFFER_MIN` | `15` | Start capturing this many min before sunrise. |
| `DUSK_BUFFER_MIN` | `30` | Keep capturing past sunset to catch blue hour. |
| `RETAIN_DAYS` | `30` | Rolling archive depth on R2. |
| `R2_REMOTE` | `r2` | rclone remote name (S3 provider → R2 endpoint). |
| `R2_BUCKET` | — | Target bucket. |
| `FRAME_DIR` / `OUT_DIR` | `/var/lib/timelapse/...` | Working dirs; frames cleared after successful publish. |

Secrets (R2 access key/secret, endpoint) live **only** in `~/.config/rclone/rclone.conf` (`0600`). Never in `timelapse.env`, never in the repo.

## 6. Components

### 6a. Daylight gate — `is_daylight.py`
Uses `astral` with `LAT/LON` to compute today's sunrise/sunset. Exits `0` if `now` is within `[sunrise - DAWN_BUFFER, sunset + DUSK_BUFFER]`, else non-zero. `capture.sh` runs this first and bails on non-zero — so the capture timer can fire every minute year-round and self-gates to daylight + blue hour.

### 6b. Frame capture — `capture.sh`
- `flock` lockfile to prevent overlap.
- Single-frame grab over TCP for reliability, with timestamp burned bottom-right:
  ```
  TS="$(date '+%Y-%m-%d %H:%M')"
  ffmpeg -nostdin -rtsp_transport tcp -y -i "$RTSP_URL" -frames:v 1 \
    -vf "drawtext=text='${TS}':x=w-tw-20:y=h-th-20:fontsize=36:fontcolor=white:box=1:boxcolor=black@0.4:boxborderw=8" \
    "$FRAME_DIR/$(date +%Y%m%d_%H%M%S).jpg"
  ```
- Camera unreachable = log a warning and exit cleanly. Never crash the timer; a missing frame is fine.

### 6c. Daily assembly + publish — `assemble-publish.sh` (22:00 local)
- Stitch the day's frames:
  ```
  DATE="$(date +%Y-%m-%d)"
  ffmpeg -y -framerate "$OUTPUT_FPS" -pattern_type glob -i "$FRAME_DIR/*.jpg" \
    -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart "$OUT_DIR/$DATE.mp4"
  ```
- Publish dated + stable copies; short cache on `latest` so viewers actually refresh:
  ```
  rclone copyto "$OUT_DIR/$DATE.mp4" "$R2_REMOTE:$R2_BUCKET/archive/$DATE.mp4"
  rclone copyto "$OUT_DIR/$DATE.mp4" "$R2_REMOTE:$R2_BUCKET/latest.mp4" \
    --header-upload "Cache-Control: public, max-age=300"
  ```
- Prune archive + clear local frames only **after** successful upload:
  ```
  rclone delete "$R2_REMOTE:$R2_BUCKET/archive/" --min-age "${RETAIN_DAYS}d"
  rm -f "$FRAME_DIR"/*.jpg
  ```
- `22:00` is safely after sunset+blue-hour in Houston year-round (summer dusk ≈ 20:50). If you'd rather, trigger dynamically at sunset+45m instead of a fixed time.

### 6d. Web — `web/index.html`
Minimal static page: a single `<video controls loop>` pointing at `latest.mp4`, muted, dark background. Uploaded once to the bucket root. Public reaches **only** this + the MP4s via the R2 public domain (or a Cloudflare custom domain/Worker in front).

## 7. Scheduling (systemd timers preferred)
- `timelapse-capture.timer` → every `CAPTURE_INTERVAL_SEC` (OnUnitActiveSec), self-gating via `is_daylight.py`.
- `timelapse-publish.timer` → daily at 22:00 local.
- Both `.service` units `Type=oneshot`, run as the unprivileged service user, env from `timelapse.env`.

## 8. Repo layout
```
skyline-timelapse/
  bin/{capture.sh,assemble-publish.sh,is_daylight.py}
  etc/timelapse.env.example     # defaults, NO secrets
  systemd/{timelapse-capture.service,.timer,timelapse-publish.service,.timer}
  web/index.html
  README.md                     # install, rclone R2 setup, source-swap note
```

## 9. Testing plan
1. Point `RTSP_URL` at whatever rooftop/360 RTSP is available now.
2. Run `capture.sh` manually a few times → confirm timestamped frames land in `FRAME_DIR`.
3. Run `assemble-publish.sh` against a handful of frames → confirm MP4 builds, lands in R2 under `archive/` + `latest.mp4`, plays from the public URL.
4. Enable timers; verify daylight gate skips overnight.
5. When the DSLR-LD arrives: change one env var (`RTSP_URL`), nothing else.

## 10. Confirm / override before build
- R2 bucket name + public domain (or Worker) for serving.
- Capture interval (60s default) and clip FPS (24 default).
- Fixed 22:00 publish vs dynamic sunset+45m.
- Retention depth (30 days default).
