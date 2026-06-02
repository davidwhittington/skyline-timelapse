# skyline-timelapse

A small, push-only pipeline that turns an RTSP camera into a daily, silent
timelapse and publishes it to a public Cloudflare R2 bucket. The camera, the
NVR, and the rest of the LAN never face the internet. Viewers only ever touch
a finished MP4.

> **Status:** ready for build. Reference deployment is a Debian LXC on
> Proxmox, capturing one downtown skyline. Same scripts work for any RTSP
> source.

## Why it's shaped this way

Most "share a camera" setups invert the trust boundary — they expose the
camera, or the NVR, or a streaming endpoint, and then try to harden it. This
project does the opposite: nothing inbound, ever. The pipeline pulls RTSP
locally and pushes a derived artifact out. The public sees yesterday's
daylight, not today's pattern of life.

The four rules that drove every design decision:

1. **Push, don't pull.** No port-forward. No inbound exposure.
2. **Derived artifact only.** Public reaches `latest.mp4`, nothing else.
3. **After-the-fact.** Publish only after dusk.
4. **No audio.** Mic disabled at source; output is silent.

## How it works

```
[Camera] --RTSP/LAN--> [LXC: capture.sh every 60s, daylight-gated]
                                  |
                          frames/*.jpg
                                  |
                    [assemble-publish.sh @ 22:00 local]
                                  |
                      ffmpeg --> YYYY-MM-DD.mp4
                                  |
                      rclone --> R2 bucket
                                  |  archive/YYYY-MM-DD.mp4 (pruned)
                                  |  latest.mp4             (stable URL)
                                  |  index.html             (tiny <video> page)
                                  v
                              [Public]
```

`capture.sh` runs every minute year-round. `is_daylight.py` is the gate — it
exits non-zero when the sun is down (with configurable dawn/dusk buffers to
catch blue hour), so the timer self-throttles without conditional cron logic.
At 22:00 local, `assemble-publish.sh` stitches the day's frames at 24 fps,
pushes both a dated archive copy and `latest.mp4` to R2, then prunes anything
older than `RETAIN_DAYS`.

## Repo layout

| Path | What lives there |
|---|---|
| `bin/capture.sh` | Single-frame RTSP grab with burned-in timestamp. Locked, gated, fail-soft. |
| `bin/assemble-publish.sh` | Daily stitch + R2 upload + archive prune. |
| `bin/is_daylight.py` | Sunrise/sunset gate using `astral`. |
| `etc/timelapse.env.example` | Sample config. Demo only; see [Secrets](#secrets). |
| `systemd/` | Two `.service` + `.timer` units. Hardened, run as `timelapse` user. |
| `web/index.html` | Minimal dark `<video>` page. Uploaded once to the bucket root. |
| `skyline-timelapse-spec.md` | Original design spec. Kept for context. |
| `private/` | Git submodule with deployment-specific config. **Not present in public clones.** |

## Install

Tested on Debian 12 in an unprivileged LXC. Requirements are modest — one
libx264 encode per day, CPU is a non-issue.

```bash
# 1. Packages
sudo apt update
sudo apt install -y ffmpeg rclone python3 python3-astral

# 2. Service user + working dirs
sudo useradd --system --home-dir /var/lib/timelapse --shell /usr/sbin/nologin timelapse
sudo install -d -o timelapse -g timelapse /var/lib/timelapse/frames /var/lib/timelapse/out
sudo install -d -m 0750 -o timelapse -g timelapse /etc/timelapse

# 3. Pipeline
sudo install -d /opt/skyline-timelapse
sudo cp -r bin /opt/skyline-timelapse/
sudo chown -R root:root /opt/skyline-timelapse

# 4. Config (see "Secrets" before populating)
sudo install -m 0640 -o root -g timelapse etc/timelapse.env.example /etc/timelapse/timelapse.env
sudo -e /etc/timelapse/timelapse.env

# 5. R2 — configure rclone as the timelapse user (interactive)
sudo -u timelapse rclone config
# Choose: New remote → name "r2" → S3 → provider "Cloudflare R2" → paste
# access key + secret + endpoint. The resulting file lives at
# /var/lib/timelapse/.config/rclone/rclone.conf with mode 0600. Confirm:
sudo -u timelapse stat -c '%a %n' /var/lib/timelapse/.config/rclone/rclone.conf

# 6. Systemd units
sudo cp systemd/*.service systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now timelapse-capture.timer timelapse-publish.timer

# 7. One-shot upload of the web page
sudo -u timelapse rclone copyto web/index.html "r2:$R2_BUCKET/index.html"
```

Verify:

```bash
systemctl list-timers | grep timelapse
sudo -u timelapse /opt/skyline-timelapse/bin/capture.sh   # should drop a frame
ls -la /var/lib/timelapse/frames/                          # should show it
```

## Secrets

The shipped `etc/timelapse.env.example` is **for demo and first-boot bring-up
only**. A flat env file on disk is the simplest thing that works, but it
isn't a durable answer for production-grade secret hygiene.

For real deployments, pull these values from a proper secrets manager:

- HashiCorp Vault / OpenBao
- Doppler / Infisical
- 1Password Connect
- AWS Secrets Manager / GCP Secret Manager / Azure Key Vault
- sops-encrypted files in Git, decrypted at deploy time

Even when an env file is used, **the actually-sensitive material does not
live there**. R2 access key + secret stay in `~/.config/rclone/rclone.conf`
at mode `0600`, owned by the service user. RTSP credentials, if any, stay in
the URL inside the env file — and the env file itself is `0640
root:timelapse`, never world-readable, never committed.

Hard rules:

- Never commit a populated `timelapse.env`. The repo ships the example only.
- Never echo secret values to logs. `ffmpeg` and `rclone` are well-behaved
  here; double-check anything you add.
- Rotate by editing the file or your secrets manager — never paste values
  into a chat transcript or shell history.

## Configuration

All knobs live in `timelapse.env`:

| Var | Default | Notes |
|---|---|---|
| `RTSP_URL` | — | Camera stream. Swap cameras by changing only this. |
| `CAPTURE_INTERVAL_SEC` | `60` | Drives the timer. ~60s gives ≈30–35s of summer clip at 24fps. |
| `OUTPUT_FPS` | `24` | Playback framerate. |
| `LAT` / `LON` | `29.749` / `-95.34` | Drives the daylight gate. Default is Houston. |
| `TZ` | `America/Chicago` | Timezone for the gate. |
| `DAWN_BUFFER_MIN` | `15` | Start this many min before sunrise. |
| `DUSK_BUFFER_MIN` | `30` | Keep capturing past sunset to catch blue hour. |
| `R2_REMOTE` | `r2` | rclone remote name. |
| `R2_BUCKET` | — | Target bucket. |
| `RETAIN_DAYS` | `30` | Rolling archive depth. |
| `FRAME_DIR` / `OUT_DIR` | `/var/lib/timelapse/...` | Working dirs. Frames cleared after successful publish. |

To switch from a fixed 22:00 publish to "sunset + 45 min", change
`OnCalendar=*-*-* 22:00:00` in `timelapse-publish.timer` to a script-driven
`OnActiveSec=` invocation. Houston summer dusk is ≈ 20:50, so the fixed time
holds year-round.

## Source isolation

The pipeline host needs exactly two network paths:

- LAN reach to the RTSP endpoint on the camera (or NVR-fronted stream).
- Outbound HTTPS to the R2 endpoint.

Everything else — other cameras, NVR admin, internal services — should be
unreachable from the LXC. Put the rooftop camera on its own VLAN, and
firewall the LXC to that VLAN + internet. The threat model assumes the LXC
itself may be compromised; nothing about that assumption should let an
attacker pivot.

## Swapping the camera

The whole point of the env-driven `RTSP_URL` is that "different camera" is a
one-line change. New RTSP URL, `systemctl restart timelapse-capture.timer`,
done. No code changes, no rebuild.

## License

MIT. See `LICENSE`.
