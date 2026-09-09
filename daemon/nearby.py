"""Nearby search: what is worth hearing from where the user actually is.

Two datasets, both reachable without an API key (see AGENTS.md, "Nearby
search", for why these two and what was ruled out):

- **OurAirports**, public domain, for VHF airband. Tower, ground, ATIS and the
  rest for 80,000 airports worldwide. This is the half that reliably has
  something on it, and the half with no licence question.
- **hearham.com** for analogue FM amateur repeaters. Frequencies and offsets
  arrive as integer hertz already, which is this project's rule anyway.

Neither is redistributed. The daemon downloads them on first use, derives a
compact index, and caches that under ~/.cache/omasdr; the raw downloads are
never kept. A stale cache is a fine cache: the search works offline against
whatever was last fetched, because everything else in OmaSDR works offline and
this is the first thing that would not.

Digital-only repeaters (DMR, D-STAR, YSF, P25) are dropped at build time.
OmaSDR demodulates none of them, so listing them would only waste the user's
time.
"""

from __future__ import annotations

import csv
import io
import json
import math
import os
import re
import time
import urllib.parse
import urllib.request
from pathlib import Path

CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "omasdr"
AIRBAND_CACHE = CACHE_DIR / "nearby-airband.json"
REPEATER_CACHE = CACHE_DIR / "nearby-repeaters.json"

OURAIRPORTS = "https://davidmegginson.github.io/ourairports-data/"
HEARHAM = "https://hearham.com/api/repeaters/v1"
NOMINATIM = "https://nominatim.openstreetmap.org/search"

# A week. The data moves slowly and nobody should pay for a download to see
# the airport down the road, which has been on the same frequency for decades.
MAX_AGE = 7 * 24 * 3600
TIMEOUT = 90

AIRBAND_LOW = 118_000_000
AIRBAND_HIGH = 137_000_000

KINDS = ("airband", "repeaters")

# Nominatim and OurAirports both ask for a User-Agent that identifies the
# application; a generic default is grounds for being blocked.
USER_AGENT = "OmaSDR (+https://github.com/brytorres/omasdr)"

# Label and rank for each frequency type. One airport contributes a dozen
# entries at the same distance, so rank decides which of them the user sees
# first: the ones actually worth sitting on.
ROLES = {
    "TWR": ("Tower", 0), "ATIS": ("ATIS", 1), "GND": ("Ground", 2),
    "APP": ("Approach", 3), "DEP": ("Departure", 4), "CTAF": ("CTAF", 5),
    "UNIC": ("UNICOM", 6), "CLD": ("Clearance", 7), "CNTR": ("Centre", 8),
    "A/D": ("Arrival/Departure", 9), "AWOS": ("AWOS", 10), "ASOS": ("ASOS", 11),
    "AFIS": ("AFIS", 12), "INFO": ("Information", 13), "RDO": ("Radio", 14),
    "FSS": ("Flight Service", 15), "OPS": ("Operations", 16),
    "EMER": ("Emergency", 17), "APRON": ("Apron", 18), "RMP": ("Ramp", 19),
    "MISC": ("Other", 20),
}

DIGITAL_HINT = "digital-only repeaters (DMR, D-STAR, YSF, P25) are not listed"


def set_version(version: str):
    """Called once by the daemon so the User-Agent names a build."""
    global USER_AGENT
    USER_AGENT = "OmaSDR/%s (+https://github.com/brytorres/omasdr)" % version


# ------------------------------------------------------------------ transport

def _request(url: str, timeout: int = TIMEOUT):
    return urllib.request.urlopen(
        urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"}),
        timeout=timeout,
    )


def _fetch(url: str, timeout: int = TIMEOUT) -> bytes:
    with _request(url, timeout) as resp:
        return resp.read()


def _fetch_csv(url: str):
    """Stream a CSV row by row. airports.csv is 12 MB and there is no reason
    to hold it in memory when three columns of it are wanted."""
    with _request(url) as resp:
        yield from csv.DictReader(io.TextIOWrapper(resp, encoding="utf-8", errors="replace"))


# -------------------------------------------------------------------- geometry

def haversine(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance in kilometres."""
    r1, r2 = math.radians(lat1), math.radians(lat2)
    dlat, dlon = r2 - r1, math.radians(lon2 - lon1)
    a = math.sin(dlat / 2) ** 2 + math.cos(r1) * math.cos(r2) * math.sin(dlon / 2) ** 2
    return 6371.0088 * 2 * math.asin(min(1.0, math.sqrt(a)))


GRID_RE = re.compile(r"^[A-R]{2}[0-9]{2}(?:[A-X]{2})?$", re.IGNORECASE)
LATLON_RE = re.compile(r"^\s*(-?\d+(?:\.\d+)?)\s*[,; ]\s*(-?\d+(?:\.\d+)?)\s*$")


def parse_grid(text: str):
    """Maidenhead locator to the centre of its square. Four or six characters;
    hams know theirs, and it needs no network at all."""
    s = text.strip().replace(" ", "").upper()
    if not GRID_RE.match(s):
        return None
    lon = (ord(s[0]) - 65) * 20 - 180 + int(s[2]) * 2
    lat = (ord(s[1]) - 65) * 10 - 90 + int(s[3])
    if len(s) == 6:
        lon += (ord(s[4]) - 65) * 5 / 60 + 2.5 / 60
        lat += (ord(s[5]) - 65) * 2.5 / 60 + 1.25 / 60
    else:
        lon += 1
        lat += 0.5
    return lat, lon


def parse_latlon(text: str):
    m = LATLON_RE.match(text or "")
    if not m:
        return None
    lat, lon = float(m.group(1)), float(m.group(2))
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return None
    return lat, lon


_last_geocode = 0.0


def geocode(place: str) -> dict:
    """A grid square, a coordinate pair, or anything Nominatim understands.

    Nominatim needs no key but its usage policy binds us: identify the
    application, and no more than one request a second. The daemon throttles
    itself here rather than trusting that a user cannot click quickly."""
    global _last_geocode
    place = (place or "").strip()
    if not place:
        raise LookupError("No place given")

    grid = parse_grid(place)
    if grid:
        return {"name": place.upper(), "latitude": grid[0], "longitude": grid[1], "source": "grid square"}
    coords = parse_latlon(place)
    if coords:
        return {"name": "%.4f, %.4f" % coords, "latitude": coords[0], "longitude": coords[1],
                "source": "coordinates"}

    wait = 1.0 - (time.monotonic() - _last_geocode)
    if wait > 0:
        time.sleep(wait)
    _last_geocode = time.monotonic()
    url = NOMINATIM + "?" + urllib.parse.urlencode({"q": place, "format": "jsonv2", "limit": 1})
    hits = json.loads(_fetch(url, timeout=25).decode("utf-8", "replace"))
    if not hits:
        raise LookupError("Nowhere called %r" % place)
    hit = hits[0]
    return {"name": hit.get("display_name") or place, "latitude": float(hit["lat"]),
            "longitude": float(hit["lon"]), "source": "OpenStreetMap"}


# ----------------------------------------------------------------- index build

def _repair(text: str) -> str:
    """Some hearham city strings are double-encoded at the source
    (`VÃ¤stra GÃ¶taland`). Undo it when it round-trips cleanly, leave it alone
    when it does not."""
    if not text or text.isascii():
        return text
    try:
        return text.encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return text


def _tokens(text: str) -> set:
    return {t for t in re.split(r"[^A-Za-z0-9]+", (text or "").upper()) if t}


def _tone(value) -> str:
    try:
        hz = float(value)
    except (TypeError, ValueError):
        return ""
    return "" if hz <= 0 else ("%.1f" % hz)


def build_airband() -> dict:
    """VHF airband frequencies joined to their airport's position. Only the
    airports that actually carry an airband frequency are kept."""
    rows = []
    wanted: dict[str, tuple | None] = {}
    for row in _fetch_csv(OURAIRPORTS + "airport-frequencies.csv"):
        try:
            hz = int(round(float(row["frequency_mhz"]) * 1e6))
        except (KeyError, TypeError, ValueError):
            continue
        if not AIRBAND_LOW <= hz <= AIRBAND_HIGH:
            continue
        ref = row.get("airport_ref") or ""
        rows.append((ref, (row.get("type") or "").strip(), (row.get("description") or "").strip(), hz))
        wanted.setdefault(ref, None)

    for row in _fetch_csv(OURAIRPORTS + "airports.csv"):
        if row.get("id") not in wanted:
            continue
        try:
            lat, lon = float(row["latitude_deg"]), float(row["longitude_deg"])
        except (KeyError, TypeError, ValueError):
            continue
        wanted[row["id"]] = ((row.get("name") or "").strip(),
                             (row.get("ident") or "").strip(), lat, lon)

    items = []
    for ref, code, description, hz in rows:
        port = wanted.get(ref)
        if not port:
            continue
        name, ident, lat, lon = port
        role, rank = ROLES.get(code.upper(), (code or "Radio", 21))
        items.append({"name": ("%s %s" % (ident, role)).strip(), "freq": hz, "lat": lat, "lon": lon,
                      "at": name, "role": role, "rank": rank,
                      "note": description if description and description.upper() != code.upper() else ""})
    return {"built": int(time.time()), "count": len(items),
            "source": "OurAirports", "note": "public domain", "items": items}


def build_repeaters() -> dict:
    """Analogue FM repeaters with a position, from hearham's open listing."""
    data = json.loads(_fetch(HEARHAM).decode("utf-8", "replace"))
    items = []
    skipped_digital = 0
    for r in data:
        try:
            if int(r.get("operational") or 0) != 1:
                continue
            if "FM" not in _tokens(r.get("mode")):
                skipped_digital += 1
                continue
            lat, lon, hz = float(r["latitude"]), float(r["longitude"]), int(r["frequency"])
        except (KeyError, TypeError, ValueError):
            continue
        if hz <= 0 or (lat == 0 and lon == 0):
            continue
        items.append({"name": (str(r.get("callsign") or "").strip() or "%.4f MHz" % (hz / 1e6)),
                      "freq": hz, "lat": lat, "lon": lon,
                      "at": _repair(str(r.get("city") or "").strip()),
                      "offset": int(r.get("offset") or 0),
                      "tone": _tone(r.get("encode"))})
    return {"built": int(time.time()), "count": len(items), "skipped_digital": skipped_digital,
            "source": "hearham.com", "note": "free to use, credited", "items": items}


BUILDERS = {"airband": (AIRBAND_CACHE, build_airband), "repeaters": (REPEATER_CACHE, build_repeaters)}


def _index(kind: str, refresh: bool) -> tuple[dict, str]:
    """The cached index for one kind, rebuilding when it is missing, older
    than MAX_AGE, or explicitly refreshed. A build failure over a cache that
    already exists is not an error: the old data is returned with a note."""
    path, build = BUILDERS[kind]
    cached = None
    try:
        cached = json.loads(path.read_text())
    except (OSError, ValueError):
        cached = None

    fresh = cached and (time.time() - int(cached.get("built") or 0)) < MAX_AGE
    if cached and fresh and not refresh:
        return cached, ""

    try:
        built = build()
    except Exception as exc:                                    # noqa: BLE001
        if cached:
            return cached, "%s unreachable, using the cached copy" % kind
        raise
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(built))
    tmp.replace(path)
    return built, ""


# ---------------------------------------------------------------------- search

def _offset_label(hz: int) -> str:
    if not hz:
        return "simplex"
    sign = "+" if hz > 0 else "-"
    mag = abs(hz)
    return sign + ("%g MHz" % (mag / 1e6) if mag >= 1_000_000 else "%g kHz" % (mag / 1e3))


def _airband_result(item: dict, km: float) -> dict:
    detail = " · ".join(p for p in (item.get("at"), item.get("note") or item.get("role")) if p)
    return {"kind": "airband", "name": item["name"], "frequency": int(item["freq"]),
            "demod": "am", "distance_km": round(km, 1), "detail": detail,
            "tags": ["airband"]}


def _repeater_result(item: dict, km: float) -> dict:
    bits = [item.get("at") or "", _offset_label(int(item.get("offset") or 0))]
    if item.get("tone"):
        bits.append("CTCSS " + item["tone"])
    return {"kind": "repeater", "name": item["name"], "frequency": int(item["freq"]),
            "demod": "nfm", "distance_km": round(km, 1),
            "detail": " · ".join(b for b in bits if b), "tags": ["repeater"]}


SHAPERS = {"airband": _airband_result, "repeaters": _repeater_result}


def search(latitude: float, longitude: float, kinds=KINDS, limit: int = 12,
           radius_km: float = 80.0, refresh: bool = False) -> dict:
    """Nearest `limit` of each kind within `radius_km`, closest first."""
    results, sources, notes = [], [], []
    for kind in KINDS:
        if kind not in kinds:
            continue
        index, note = _index(kind, refresh)
        if note:
            notes.append(note)
        shape = SHAPERS[kind]
        near = []
        for item in index["items"]:
            km = haversine(latitude, longitude, item["lat"], item["lon"])
            if km <= radius_km:
                near.append((km, item))
        # Distance first, then rank, so one airport's dozen entries arrive
        # tower-first rather than alphabetically.
        near.sort(key=lambda pair: (pair[0], pair[1].get("rank", 0), pair[1]["freq"]))
        results.extend(shape(item, km) for km, item in near[:limit])
        sources.append({"kind": kind, "name": index.get("source", kind),
                        "note": index.get("note", ""), "built": int(index.get("built") or 0),
                        "count": int(index.get("count") or 0)})
    return {"results": results, "sources": sources, "notes": notes, "hint": DIGITAL_HINT}
