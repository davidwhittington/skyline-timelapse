#!/usr/bin/env python3
"""Daylight gate. Exit 0 if now is within [sunrise - DAWN_BUFFER, sunset + DUSK_BUFFER]."""
import os
import sys
from datetime import datetime, timedelta

try:
    from astral import LocationInfo
    from astral.sun import sun
except ImportError:
    sys.stderr.write("astral not installed: apt-get install python3-astral\n")
    sys.exit(2)

try:
    from zoneinfo import ZoneInfo
except ImportError:
    sys.stderr.write("zoneinfo unavailable: requires Python 3.9+\n")
    sys.exit(2)


def env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return float(raw)


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return int(raw)


def main() -> int:
    lat = env_float("LAT", 29.749)
    lon = env_float("LON", -95.34)
    dawn_buf = env_int("DAWN_BUFFER_MIN", 15)
    dusk_buf = env_int("DUSK_BUFFER_MIN", 30)
    tz_name = os.environ.get("TZ", "America/Chicago")

    tz = ZoneInfo(tz_name)
    loc = LocationInfo(latitude=lat, longitude=lon, timezone=tz_name)
    now = datetime.now(tz)
    s = sun(loc.observer, date=now.date(), tzinfo=tz)

    start = s["sunrise"] - timedelta(minutes=dawn_buf)
    end = s["sunset"] + timedelta(minutes=dusk_buf)

    if start <= now <= end:
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
