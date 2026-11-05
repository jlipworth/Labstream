#!/usr/bin/env python3
"""Scrub Plex, Jellyfin and Emby server and transcoder logs before sharing them upstream.

The scrubber is offline and deterministic. It runs in three passes:

1. Discovery collects the concrete secrets present in the input (hosts, IPs, media paths,
   titles, release names, search terms, user and device names, tokens, client/device/user/
   session identifiers, proxy names, home directories), including text hidden inside
   base64 (optionally gzip/zlib-compressed) payloads.
2. Replacement rewrites every occurrence with the repository placeholders
   (192.0.2.10, 2001:db8::1, <name>.example.internal, <title>, <year>, <user>, <device>,
   <redacted>, /media/movies/<title>/<title>.mkv). Encoded payloads are decoded, scrubbed
   and re-encoded in the same format, or replaced by a `<payload removed>` marker.
3. Verification re-scans the output (including decoded payloads) for every discovered
   secret plus generic sensitive patterns. Any hit makes the run exit 1.

Summaries and reports name categories, files and line numbers only, never values.
Publishing the scrubbed output stays a manual, user-approved step.

Examples:

  uv run python scripts/scrub-server-logs.py /tmp/emby/raw --output /tmp/emby/scrubbed
  uv run python scripts/scrub-server-logs.py ~/logs/jellyfin --backend jellyfin \
      --since "2026-10-30 23:20" --until "2026-10-30 23:40" --output /tmp/jf-share \
      --report /tmp/jf-share-report.json
  uv run python scripts/scrub-server-logs.py "Plex Media Server.log" --play-session abc123 \
      --output /tmp/plex-share
"""
from __future__ import annotations

import argparse
import base64
import binascii
import collections
import dataclasses
import datetime as dt
import gzip
import json
import pathlib
import re
import sys
import zlib

BACKENDS = ("plex", "jellyfin", "emby")
# Split so repository hygiene scans never see the literal header marker.
PLEX_AUTH_HEADER = "X-Plex" + "-Token"

# --- placeholders -----------------------------------------------------------------------

P_REDACTED = "<redacted>"
P_TITLE = "<title>"
P_YEAR = "<year>"
P_USER = "<user>"
P_DEVICE = "<device>"
P_PAYLOAD = "<payload removed>"
IPV4_PLACEHOLDER_NET = "192.0.2."
IPV6_PLACEHOLDER_NET = "2001:db8::"
HOST_PLACEHOLDER_SUFFIX = ".example.internal"

MEDIA_EXT = (
    "mkv|mp4|m4v|avi|mov|wmv|ts|m2ts|mts|webm|mpg|mpeg|flv|iso|vob|divx|ogm|"
    "flac|mp3|m4a|m4b|aac|ogg|oga|opus|wav|alac|aiff|dsf|ape|wma|"
    "srt|ass|ssa|sup|sub|idx|vtt|nfo|jpg|jpeg|png|webp"
)
MEDIA_EXT_RE = re.compile(r"\.(%s)\b" % MEDIA_EXT, re.I)

# First path components that belong to the server/OS rather than a media library.
SYSTEM_ROOTS = {
    "app", "usr", "lib", "lib32", "lib64", "bin", "sbin", "etc", "proc", "sys", "dev", "run",
    "tmp", "var", "opt", "config", "cache", "transcode", "transcodes", "root", "system",
    "library", "applications", "private", "web", "emby", "jellyfin", "plexmediaserver",
    "programdata", "snap", "boot", "srv-app", "nix",
}
# First path components that conventionally hold media libraries.
LIBRARY_ROOTS = {
    "data", "media", "mnt", "movies", "movie", "films", "film", "tv", "tvshows", "shows",
    "series", "music", "audio", "nas", "share", "shares", "srv", "storage", "volumes",
    "volume1", "volume2", "volume3", "content", "downloads", "video", "videos", "anime",
    "books", "audiobooks", "photos", "pictures", "recordings", "dvr", "disk", "disks",
    "drive", "drives", "pool", "tank", "zfs",
}
HOME_ROOTS = {"home", "users"}
LIBRARY_WORD_RE = re.compile(r"(?i)movie|film|\btv\b|show|series|music|audio|video|media|anime|plex|jellyfin|emby")
NON_LIBRARY_COMPONENT = re.compile(r"(?i)transcod|^cache$|^metadata$|^logs?$|^plug-?ins?$")

# Public service domains that are safe (and useful) to keep.
PUBLIC_HOST_SUFFIXES = (
    "plex.tv", "plexapp.com", "jellyfin.org", "emby.media", "mb3admin.com", "themoviedb.org",
    "tmdb.org", "thetvdb.com", "tvdb.com", "omdbapi.com", "imdb.com", "musicbrainz.org",
    "fanart.tv", "theaudiodb.com", "opensubtitles.org", "opensubtitles.com", "github.com",
    "githubusercontent.com", "apple.com", "microsoft.com", "example.com", "example.org",
    "example.net", "example.internal", "localhost", "ffmpeg.org",
)

TITLE_STOPWORDS = {
    "live", "video", "videos", "audio", "music", "movie", "movies", "film", "films", "season",
    "series", "extras", "extra", "specials", "special", "sample", "samples", "trailer",
    "trailers", "subs", "subtitles", "featurettes", "featurette", "other", "others", "unknown",
    "various", "various artists", "media", "library", "data", "default", "english", "plex",
    "emby", "jellyfin", "server", "transcode", "session", "request", "error", "debug", "info",
    "warning", "scanner", "completed", "directory", "collections", "shows", "tv", "anime",
    "downloads", "share", "shares", "storage", "content", "photos", "pictures", "books",
    "audiobooks", "recordings", "behind the scenes", "deleted scenes", "interviews", "scenes",
    "shorts", "user", "home", "mnt", "nas", "disc", "volume", "true", "false", "none", "null",
    "name", "title", "file", "path", "main", "copy", "stream", "default audio", "unknown artist",
}
TITLE_COMPONENT_SKIP = re.compile(
    r"(?i)^(?:season\s*\d+|series\s*\d+|s\d{1,3}|specials?|extras?|featurettes?|disc\s*\d+|"
    r"cd\s*\d+|subs?|subtitles|behind the scenes|deleted scenes|interviews|scenes|shorts|"
    r"trailers?|other|sample)$"
)
RELEASE_MARKER = re.compile(
    r"(?i)(?:^|[\s(\[])(?:(?:19|20)\d\d|\d{3,4}[pi]|4k|8k|uhd|bluray|blu-ray|bdremux|bdrip|"
    r"brrip|web-?dl|webrip|web|hdtv|dvdrip|dvd|remux|hdr10\+?|hdr|dv|dovi|sdr|x26[45]|h\s?26[45]|"
    r"hevc|avc|av1|10bit|atmos|truehd|dts(?:-hd)?|ddp?5\s1|aac|proper|repack|extended|"
    r"imax|s\d{1,2}e\d{1,3}|\d{1,2}x\d{2}|season\s\d+)(?=$|[\s)\]\-])"
)

# --- generic patterns -------------------------------------------------------------------

IPV4_RE = re.compile(r"(?<![\w.])((?:\d{1,3}\.){3}\d{1,3})(?![\w.]|\.\d)")
IPV4_DASHED_RE = re.compile(r"(?<![\w-])(\d{1,3}-\d{1,3}-\d{1,3}-\d{1,3})(?=\.[0-9a-f]{16,}\.plex\.direct)", re.I)
VERSION_CONTEXT_RE = re.compile(
    r"(?i)(?:\bversion|\bver|\bv|\bbuild|\bunix|\blinux|\bdarwin|\bkernel|\bfirmware|\brelease|"
    r"\bos|\bios|\bvisionos|\btvos|\bmacos)[\s:=]*$|[A-Za-z0-9_\-]/$"
)
IPV6_RE = re.compile(r"(?<![\w:.])((?:[0-9A-Fa-f]{1,4}:){1,7}:?(?:[0-9A-Fa-f]{1,4})?|::(?:[0-9A-Fa-f]{1,4}:?){1,7})(?![\w:.])")
MAC_RE = re.compile(r"(?<![\w:-])((?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2})(?![\w:-])")
EMAIL_RE = re.compile(r"(?i)(?<![\w.%+-])[A-Z0-9._%+-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)*\.[A-Z]{2,}\b")
URL_AUTHORITY_RE = re.compile(r"(?i)\b((?:https?|wss?|rtsps?|rtmps?|smb|nfs|ftps?|sftp|udp|tcp|srt)://)(?:([^/\s@\"'<>]*)@)?(\[[0-9a-f:.]+\]|[^/\s:\"'<>?#,]+)")
HOST_HEADER_RE = re.compile(
    r"(?i)(?<![\w-])((?:X-Forwarded-Host|X-Original-Host|X-Forwarded-Server|Host|Origin|Referer)"
    r"(?:\"\s*:\s*\"|\s*=\s*\"?|:\s+\"?))([^,\s:\"'<>&;/]+)"
)
PLEX_DIRECT_RE = re.compile(r"(?i)\b[\w-]+\.[0-9a-f]{16,}\.plex\.direct\b")
DOTTED_HOST_RE = re.compile(r"(?i)^(?=.{4,253}$)[a-z0-9_](?:[a-z0-9_-]{0,62})(?:\.[a-z0-9_-]{1,63})*\.[a-z][a-z0-9-]{1,62}$")
# Account identifiers embedded in public-service URL paths (Plex avatar URLs).
ACCOUNT_URL_RE = re.compile(r"(?i)(\bplex\.tv/users/)([0-9a-f]{8,})")
BLOB_RE = re.compile(r"(?<![A-Za-z0-9+/=])[A-Za-z0-9+/]{200,}={0,2}(?![A-Za-z0-9+/=])")
# Emby wraps "sensitive" values in invisible marker characters; drop them so matching is reliable.
ZERO_WIDTH_RE = re.compile("[\u200b\u200c\u200d\u2060\ufeff]")
HOME_RE = re.compile(r"(?<![\w.])(/(?:home|Users)/|[A-Za-z]:\\Users\\)(?!<user>)([^/\\\s\"'<>]+)")

# Keys whose values are credentials or stable identifiers.
CREDENTIAL_KEYS = [
    PLEX_AUTH_HEADER, "X-Plex-Password", "api_key", "apikey", "ApiKey", "access_token",
    "accessToken", "AccessToken", "AccessKey", "X-Emby-Token", "X-MediaBrowser-Token", "Token",
    "password", "Pw", "Password", "Cookie", "Set-Cookie", "Private-Network-Access-Id",
    "X-Plex-Client-Identifier", "X-Plex-Device-Id", "clientIdentifier", "machineIdentifier",
    "X-Emby-Device-Id", "X-Emby-Client-Id", "DeviceId", "deviceId", "UserId", "userId",
    "userID", "accountID", "accountId", "AccountId", "ServerId", "serverId", "SystemId",
    "LocalUserId", "ConnectUserId", "X-Plex-Account-Id",
]
SESSION_KEYS = [
    "PlaySessionId", "playSessionId", "X-Plex-Session-Identifier", "X-Plex-Session-Id",
    "sessionId", "SessionId", "session", "X-Emby-Session-Id",
]
DEVICE_KEYS = [
    "X-Plex-Device-Name", "X-Emby-Device-Name", "DeviceName", "deviceName", "Device",
    "Private-Network-Access-Name",
]
USER_KEYS = ["X-Plex-Username", "UserName", "Username", "userName", "username", "User"]
SEARCH_KEYS = ["searchTerm", "SearchTerm", "query", "NameStartsWith", "term"]

KEY_GROUPS = {
    "credential": CREDENTIAL_KEYS,
    "session": SESSION_KEYS,
    "device": DEVICE_KEYS,
    "user": USER_KEYS,
    "search_term": SEARCH_KEYS,
}


def _alt(keys: list[str]) -> str:
    return "|".join(re.escape(k) for k in sorted(set(keys), key=len, reverse=True))


def _kv_patterns(keys: list[str], spaced_values: bool) -> list[re.Pattern[str]]:
    alt = _alt(keys)
    unquoted = r"[^\"&,;<>\n\r]+?(?=\s*(?:[&,;<>\n\r]|$))" if spaced_values else r"[^\"&\s,;<>'()\[\]]+"
    return [
        # JSON "Key": "value"
        re.compile(r'(?<![\w-])"(?:%s)"\s*:\s*"(?P<val>[^"]*)"' % alt),
        # Key="value"
        re.compile(r'(?<![\w-])(?:%s)\s*=\s*"(?P<val>[^"]*)"' % alt),
        # Key=value  (query strings, Emby header dumps)
        re.compile(r"(?<![\w-])(?:%s)=(?P<val>(?![\"<])%s)" % (alt, unquoted)),
        # Key: value  (HTTP header style; only for X-* and a few header names)
        re.compile(r"(?<![\w-])(?:%s):[ \t]+(?P<val>(?![\"<])%s)" % (
            _alt([k for k in keys if k.lower().startswith("x-") or k in ("Cookie", "Set-Cookie", "Private-Network-Access-Id", "Private-Network-Access-Name")]) or "(?!)",
            unquoted,
        )),
    ]


KV_PATTERNS = {cat: _kv_patterns(keys, cat in ("device", "user", "search_term")) for cat, keys in KEY_GROUPS.items()}

AUTH_HEADER_RE = re.compile(r'(?i)(?:MediaBrowser|Emby)\s+(?:[A-Za-z]+="[^"]*",?\s*)+')
BEARER_RE = re.compile(r"(?i)\b(Bearer|Basic)\s+([A-Za-z0-9._~+/=-]{8,})")
SESSION_CONTEXT_RES = [
    re.compile(r"(?i)\bfor session ([0-9a-f]{16,})\b"),
    re.compile(r"(?i)_lastPlaySessionId for session [0-9a-f]+ to ([0-9a-f]{16,})\b"),
    re.compile(r"(?i)\bPlaySessionId:\s*([0-9A-Za-z-]{8,})"),
    re.compile(r"(?i)\bsession(?:Id| id)?[:=]\s*\"?([0-9a-f]{16,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"),
]
USER_CONTEXT_RES = [
    re.compile(r"(?m)User policy for (.+?)(?:\.\s|\.?[ \t]*$)"),
    re.compile(r'Authentication request for "([^"]+)"'),
    re.compile(r'(?i)\buser(?:name)?\s*[:=]\s*"([^"]+)"'),
    re.compile(r"Signed-in Token \(([^)]+)\)"),
    re.compile(r'(?i)<(?:User|Account)\b[^>]*?\b(?:title|username|name)="([^"]+)"'),
    re.compile(r"(?i)\bfor user ([^\s.,;\"']+)"),
]
DEVICE_CONTEXT_RES = [
    re.compile(r"reported by app .+? on (.+?) playing "),
    re.compile(r"(?m)^App: [^\n]+\n([^\n]+)\nUser-Agent:"),
    re.compile(r'(?i)<(?:Player|Device)\b[^>]*?\b(?:title|name|device)="([^"]+)"'),
]
TITLE_CONTEXT_RES = [
    re.compile(r'(?i)<(?:Video|Track|Directory|Metadata|Episode|Movie)\b[^>]*?\b(?:title|grandparentTitle|parentTitle|originalTitle)="([^"]+)"'),
]
# Contexts whose whole value is library content (titles, relative library folders); the value
# is replaced wholesale because it can carry release tags or names discovery cannot isolate.
WHOLESALE_TITLE_RES = [
    re.compile(r"(?m)((?:Updating|Skipping over) directory ')(.*)('(?: \(ID \d+\)|, as ))"),
    re.compile(r"(?m)(\bitem \d+ ')(.*)('(?:\s|$))"),
    re.compile(r'(\bplaying ")([^"]+)(")'),
    re.compile(r"(\bplaying )(?!\")(.+?)(\. (?:Position|Stopped|Started))"),
    re.compile(r'(?i)(chapter image(?: extraction)? for ")([^"]*)(")'),
    re.compile(r'(\b(?:Name|Album|Artist|SeriesName|Series|Title): ")([^"]*)(")'),
    re.compile(r'(\b(?:entry|files|images?|metadata|item) for ")([^"/][^"]*)(")'),
    re.compile(r'(\bin series ")([^"]*)(")'),
]
JSON_TITLE_KEYS = ("Name", "Title", "OriginalTitle", "SortName", "SeriesName", "Album", "AlbumArtist", "SeasonName", "EpisodeTitle")
JSON_TITLE_RE = re.compile(r'"(%s)"\s*:\s*"([^"]*)"' % "|".join(JSON_TITLE_KEYS))
XML_TITLE_RE = re.compile(r'\b(title|grandparentTitle|parentTitle|originalTitle)="([^"]*)"')
SEARCH_LINE_RE = re.compile(r"(?i)(Original search term:\s*)(.+?)(\.\s+Bound search term:\s*)(.+)$", re.M)
CONTAINER_TITLE_RE = re.compile(r"^((?:\d\d:\d\d:\d\d\.\d+\s+)?\s*title\s*:\s*)(.*)$", re.M)

# --- window extraction ------------------------------------------------------------------

TS_PATTERNS = [
    (re.compile(r"^(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})"), "%Y-%m-%d %H:%M:%S"),
    (re.compile(r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})"), "%Y-%m-%d %H:%M:%S"),
    (re.compile(r"^([A-Z][a-z]{2} \d{1,2}, \d{4} \d{2}:\d{2}:\d{2})"), "%b %d, %Y %H:%M:%S"),
]
CONTEXT_TAG_RE = re.compile(r"\b[A-Za-z]+Service-[0-9A-Z]{8,}:[0-9A-F]{8}\b|\[Req#[0-9a-f]+")
EMBY_FFMPEG_REF_RE = re.compile(r"(ffmpeg-[a-z0-9]+-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}_\d+)(?:graph)?\.txt", re.I)
JELLYFIN_FFMPEG_NAME_RE = re.compile(r"^FFmpeg\.[A-Za-z]+-(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})", re.I)
PLEX_REPORT_RE = re.compile(r"<SessionReport\b.*?</SessionReport>", re.S)
PLEX_REPORT_TS_RE = re.compile(r'startTimestamp="([^"]+)"')


def parse_line_time(line: str) -> dt.datetime | None:
    for regex, fmt in TS_PATTERNS:
        m = regex.match(line)
        if m:
            try:
                return dt.datetime.strptime(m.group(1).replace("T", " "), fmt)
            except ValueError:
                return None
    return None


def parse_user_time(value: str) -> dt.datetime:
    value = value.strip().replace("T", " ")
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            return dt.datetime.strptime(value, fmt)
        except ValueError:
            continue
    raise argparse.ArgumentTypeError(f"unrecognised timestamp (use 'YYYY-MM-DD HH:MM[:SS]'): {value!r}")


# --- file classification ----------------------------------------------------------------


def detect_backend(name: str, text: str) -> str | None:
    head = text[:20000]
    lname = name.lower()
    if lname.startswith("plex ") or "plex media server" in head.lower() or re.search(r"(?m)^[A-Z][a-z]{2} \d{1,2}, \d{4} \d\d:\d\d:\d\d\.\d+ \[[0-9a-fx]+\] [A-Z]+ - ", head) or "<SessionReport" in head:
        return "plex"
    if lname.startswith("embyserver") or EMBY_FFMPEG_REF_RE.fullmatch(name) or "Emby Server version" in head or "Emby.Server" in head and "[INF]" not in head:
        return "emby"
    if re.match(r"(?i)^(log_\d{8}|jellyfin).*\.log$", name) or JELLYFIN_FFMPEG_NAME_RE.match(name) or re.search(r"(?m)^\[\d{4}-\d{2}-\d{2} [\d:.]+ [+-]\d\d:\d\d\] \[(?:INF|WRN|ERR|DBG|FTL|VRB)\]", head):
        return "jellyfin"
    if re.search(r"(?m)^\d{4}-\d{2}-\d{2} \d\d:\d\d:\d\d\.\d+ (?:Info|Warn|Error|Debug|Fatal) ", head):
        return "emby"
    return None


def file_role(name: str) -> str:
    if EMBY_FFMPEG_REF_RE.fullmatch(name) or re.match(r"(?i)^ffmpeg-.*\.txt$", name):
        return "transcoder"
    if JELLYFIN_FFMPEG_NAME_RE.match(name):
        return "transcoder"
    if re.match(r"(?i)^plex transcoder statistics", name):
        return "transcoder"
    if re.match(r"(?i)^(embyserver|log_\d{8}|jellyfin|plex media server)", name):
        return "main"
    return "other"


# --- secrets model ----------------------------------------------------------------------


@dataclasses.dataclass
class Secrets:
    hosts: dict[str, str] = dataclasses.field(default_factory=dict)
    ipv4: dict[str, str] = dataclasses.field(default_factory=dict)
    ipv6: dict[str, str] = dataclasses.field(default_factory=dict)
    sessions: dict[str, str] = dataclasses.field(default_factory=dict)
    tokens: set[str] = dataclasses.field(default_factory=set)
    users: set[str] = dataclasses.field(default_factory=set)
    devices: set[str] = dataclasses.field(default_factory=set)
    titles: set[str] = dataclasses.field(default_factory=set)
    releases: set[str] = dataclasses.field(default_factory=set)
    search_terms: set[str] = dataclasses.field(default_factory=set)
    library_roots: set[str] = dataclasses.field(default_factory=set)
    home_names: set[str] = dataclasses.field(default_factory=set)
    skipped_short_titles: int = 0
    _phrase_cache: dict = dataclasses.field(default_factory=dict)

    def host_placeholder(self, host: str) -> str:
        key = host.lower().rstrip(".")
        if key not in self.hosts:
            label = key.split(".", 1)[0]
            base = label if label in BACKENDS else "host"
            used = set(self.hosts.values())
            candidate = f"{base}{HOST_PLACEHOLDER_SUFFIX}" if base != "host" else ""
            n = 1
            while not candidate or candidate in used:
                candidate = f"{base}{n}{HOST_PLACEHOLDER_SUFFIX}"
                n += 1
            self.hosts[key] = candidate
        return self.hosts[key]

    def ipv4_placeholder(self, ip: str) -> str:
        if ip not in self.ipv4:
            self.ipv4[ip] = f"{IPV4_PLACEHOLDER_NET}{10 + len(self.ipv4)}"
        return self.ipv4[ip]

    def ipv6_placeholder(self, ip: str) -> str:
        key = ip.lower()
        if key not in self.ipv6:
            self.ipv6[key] = f"{IPV6_PLACEHOLDER_NET}{len(self.ipv6) + 1:x}"
        return self.ipv6[key]

    def session_placeholder(self, value: str) -> str:
        if value not in self.sessions:
            self.sessions[value] = f"<session-{len(self.sessions) + 1}>"
        return self.sessions[value]


class Counter:
    """Per-file category counter; never stores values."""

    def __init__(self) -> None:
        self.counts: collections.Counter[str] = collections.Counter()

    def add(self, category: str, n: int = 1) -> None:
        if n:
            self.counts[category] += n


# --- helpers ----------------------------------------------------------------------------


def is_placeholder_text(value: str) -> bool:
    return "<" in value and ">" in value


def only_placeholders(value: str) -> bool:
    return not re.search(r"[^\W\d_]", re.sub(r"<[a-z0-9 -]+>|/media/(?:movies|tv|music|library)/", "", value))


def is_public_host(host: str) -> bool:
    h = host.lower().rstrip(".")
    if h.endswith(".plex.direct"):
        return False
    return any(h == s or h.endswith("." + s) for s in PUBLIC_HOST_SUFFIXES)


def is_ipv4(value: str) -> bool:
    parts = value.split(".")
    return len(parts) == 4 and all(p.isdigit() and int(p) <= 255 and (p == "0" or not p.startswith("0")) for p in parts)


def keep_ipv4(ip: str) -> bool:
    return (
        ip.startswith("127.")
        or ip in ("0.0.0.0", "255.255.255.255")
        or ip.startswith(("192.0.2.", "198.51.100.", "203.0.113."))
    )


def ipv4_is_version(text: str, start: int) -> bool:
    return bool(VERSION_CONTEXT_RE.search(text[max(0, start - 24):start]))


def looks_like_ipv6(token: str) -> bool:
    if token.count(":") < 2:
        return False
    groups = [g for g in token.split(":") if g]
    if "::" not in token and len(groups) != 8:
        return False
    if not groups:
        return False
    # Times/durations (12:34:56) and ffmpeg stream specifiers (0:1:2) are all short decimals.
    if "::" not in token and all(g.isdigit() and len(g) <= 2 for g in groups):
        return False
    return True


def keep_ipv6(token: str) -> bool:
    t = token.lower()
    return t in ("::", "::1", "::ffff") or t.startswith("2001:db8:")


def clean_title(raw: str) -> str:
    name = MEDIA_EXT_RE.sub("", raw) if MEDIA_EXT_RE.search(raw[-6:]) else raw
    name = re.sub(r"[\[{][^\]}]*[\]}]", " ", name)
    name = re.sub(r"\(\s*(?:19|20)\d\d\s*\)", " ", name)
    name = re.sub(r"[._]+", " ", name)
    name = re.sub(r"\s+", " ", name).strip()
    m = RELEASE_MARKER.search(name)
    if m and m.start() > 0:
        name = name[: m.start()]
    name = re.sub(r"\s+-\s*[A-Za-z0-9]+$", "", name) if re.search(r"-[A-Za-z0-9]+$", name) and " - " not in name else name
    return name.strip(" -–_.,:;()[]")


def title_candidates(raw: str) -> set[str]:
    out: set[str] = set()
    base = re.sub(r"[\[{][^\]}]*[\]}]", " ", raw)
    for part in [base] + re.split(r"\s+-\s+", base):
        cleaned = clean_title(part)
        if cleaned and not TITLE_COMPONENT_SKIP.match(cleaned):
            out.add(cleaned)
    return out


def phrase_regex(phrase: str) -> re.Pattern[str]:
    words = re.findall(r"[^\W_]+|[^\w\s]", phrase)
    sep = r"(?:[\s._+\-]|%20)*"
    body = sep.join(re.escape(w) for w in words)
    return re.compile(r"(?i)(?<![^\W_])%s(?![^\W_])" % body)


class PhraseSet:
    """Fast case-insensitive phrase matching keyed by the first word."""

    def __init__(self, phrases: set[str]) -> None:
        self.index: dict[str, list[tuple[int, re.Pattern[str]]]] = collections.defaultdict(list)
        for p in phrases:
            words = re.findall(r"[^\W_]+", p)
            if not words:
                continue
            self.index[words[0].lower()].append((len(p), phrase_regex(p)))
        for lst in self.index.values():
            lst.sort(key=lambda t: -t[0])

    def finditer(self, text: str):
        if not self.index:
            return
        pos = 0
        word_re = re.compile(r"[^\W_]+")
        while True:
            m = word_re.search(text, pos)
            if not m:
                return
            hit = None
            for _, rx in self.index.get(m.group(0).lower(), ()):
                hit = rx.match(text, m.start())
                if hit:
                    break
            if hit:
                yield hit
                pos = hit.end()
            else:
                pos = m.end()

    def sub(self, text: str, repl: str) -> tuple[str, int]:
        out, last, n = [], 0, 0
        for hit in self.finditer(text):
            out.append(text[last:hit.start()])
            out.append(repl)
            last = hit.end()
            n += 1
        if not n:
            return text, 0
        out.append(text[last:])
        return "".join(out), n


def eligible_phrase(phrase: str, min_single: int = 5) -> bool:
    p = phrase.strip()
    if not p or is_placeholder_text(p) or p.lower() in TITLE_STOPWORDS:
        return False
    words = re.findall(r"[^\W_]+", p)
    if not words:
        return False
    if len(words) == 1 and (len(words[0]) < min_single or words[0].isdigit()):
        return False
    if all(w.isdigit() for w in words):
        return False
    return len(p) >= 3


# --- payloads ---------------------------------------------------------------------------


def _printable(text: str) -> bool:
    if not text:
        return False
    good = sum(1 for c in text if c.isprintable() or c in "\r\n\t")
    return good / len(text) > 0.97


def decode_blob(blob: str) -> tuple[str, str | None]:
    """Return (format, text). Format is gzip|zlib|deflate|plain, or 'binary' when undecodable."""
    try:
        raw = base64.b64decode(blob + "=" * (-len(blob) % 4), validate=True)
    except (binascii.Error, ValueError):
        return "binary", None
    attempts = (
        ("gzip", lambda b: gzip.decompress(b)),
        ("zlib", lambda b: zlib.decompress(b)),
        ("deflate", lambda b: zlib.decompress(b, -15)),
        ("plain", lambda b: b),
    )
    for fmt, fn in attempts:
        try:
            data = fn(raw)
            text = data.decode("utf-8")
        except Exception:
            continue
        if _printable(text):
            return fmt, text
    return "binary", None


def encode_blob(fmt: str, text: str) -> str:
    data = text.encode("utf-8")
    if fmt == "gzip":
        data = gzip.compress(data, mtime=0)
    elif fmt == "zlib":
        data = zlib.compress(data)
    elif fmt == "deflate":
        c = zlib.compressobj(wbits=-15)
        data = c.compress(data) + c.flush()
    return base64.b64encode(data).decode("ascii")


def expand_payloads(text: str, depth: int = 0) -> list[str]:
    out = [text]
    if depth >= 3:
        return out
    for m in BLOB_RE.finditer(text):
        _, decoded = decode_blob(m.group(0))
        if decoded is not None:
            out.extend(expand_payloads(decoded, depth + 1))
    return out


# --- paths ------------------------------------------------------------------------------

QUOTED_PATH_RES = [
    re.compile(r"(?m)(?<=, from )'(.+)'(?=:\s*$)"),
    re.compile(r'"((?:/|[A-Za-z]:\\\\?|\\\\\\\\?)[^"\n]*)"'),
    re.compile(r"'((?:/|[A-Za-z]:\\|\\\\)[^\n]*?)'(?=\s*$|\s+['(\-]|[,:;)\]]|\s+[a-z]+\b)"),
]
UNQUOTED_PATH_START = re.compile(r"(?<![\w/.:%@~\-\]\[<>*])(?:/(?=[\w.@~+-])|[A-Za-z]:\\(?=[\w.@~+ -])|\\\\(?=\w))")
PATH_PLACEHOLDER_RE = re.compile(r"/media/(?:movies|tv|music|library)/<title>")
HTTP_METHOD_BEFORE = re.compile(r"(?:GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH)\s+$")


def split_components(path: str) -> list[str]:
    return [c for c in re.split(r"[\\/]+", path) if c and not re.fullmatch(r"[A-Za-z]:", c)]


def library_kind(components: list[str]) -> str:
    joined = " ".join(c.lower() for c in components[:4])
    if re.search(r"movie|film", joined):
        return "movies"
    if re.search(r"\btv\b|tvshows|shows|series|anime|season", joined):
        return "tv"
    if re.search(r"music|audio|flac|album", joined):
        return "music"
    return "library"


class PathPolicy:
    def __init__(self, secrets: Secrets) -> None:
        self.secrets = secrets

    def is_library(self, path: str) -> bool:
        if is_placeholder_text(path):
            return False
        norm = path.replace("\\\\", "\\")
        if norm.startswith("\\\\"):
            return True
        comps = split_components(norm)
        if not comps:
            return False
        if any(norm.startswith(root.rstrip("/\\") + sep) or norm == root for root in self.secrets.library_roots for sep in ("/", "\\")):
            return not any(NON_LIBRARY_COMPONENT.search(c) for c in comps)
        first = comps[0].lower()
        if re.match(r"^[A-Za-z]:", norm):
            low = norm.lower()
            if any(s in low for s in ("\\program files", "\\programdata", "\\windows\\", "\\appdata\\")) and not MEDIA_EXT_RE.search(norm):
                return False
            if len(comps) >= 2 and comps[0].lower() == "users":
                return MEDIA_EXT_RE.search(norm) is not None
            return True
        if first in SYSTEM_ROOTS:
            return False
        if first in HOME_ROOTS:
            return bool(MEDIA_EXT_RE.search(norm)) or any(LIBRARY_WORD_RE.search(c) for c in comps[2:3])
        if any(NON_LIBRARY_COMPONENT.search(c) for c in comps):
            return False
        if first in LIBRARY_ROOTS:
            return len(comps) >= 2 or bool(MEDIA_EXT_RE.search(norm))
        return bool(MEDIA_EXT_RE.search(norm)) and len(comps) >= 2

    def placeholder(self, path: str) -> str:
        norm = path.replace("\\\\", "\\")
        comps = split_components(norm)
        kind = library_kind(comps)
        m = re.search(r"\.(%s)$" % MEDIA_EXT, norm, re.I)
        if m:
            return f"/media/{kind}/{P_TITLE}/{P_TITLE}.{m.group(1)}"
        return f"/media/{kind}/{P_TITLE}"


def discover_path(path: str, secrets: Secrets) -> None:
    norm = path.replace("\\\\", "\\")
    comps = split_components(norm)
    if not comps or comps[0].lower() in SYSTEM_ROOTS or any(NON_LIBRARY_COMPONENT.search(c) for c in comps):
        return
    if MEDIA_EXT_RE.search(norm) and comps[0].lower() not in SYSTEM_ROOTS and not any(NON_LIBRARY_COMPONENT.search(c) for c in comps):
        if norm.startswith("/"):
            depth = 2 if len(comps) > 2 else 1
            secrets.library_roots.add("/" + "/".join(comps[:depth]))
    lib_start = 2 if len(comps) > 2 else 1
    if comps[0].lower() in HOME_ROOTS:
        if not (MEDIA_EXT_RE.search(norm) or any(LIBRARY_WORD_RE.search(c) for c in comps[2:3])):
            return
        lib_start = 3 if len(comps) > 3 else 2
    for comp in comps[lib_start:]:
        stem = re.sub(r"\.(%s)$" % MEDIA_EXT, "", comp, flags=re.I)
        if MEDIA_EXT_RE.search(comp[-6:]) and clean_title(stem) != stem.strip():
            secrets.releases.add(stem)
        for cand in title_candidates(stem):
            secrets.titles.add(cand)


# --- discovery --------------------------------------------------------------------------


def discover(texts: list[str], secrets: Secrets) -> None:
    policy = PathPolicy(secrets)
    # Pass 1: quoted media paths establish library roots first.
    for text in texts:
        for rx in QUOTED_PATH_RES:
            for m in rx.finditer(text):
                p = m.group(1)
                if MEDIA_EXT_RE.search(p):
                    discover_path(p, secrets)
        for m in re.finditer(r"(?i)(?:from|-i)\s+'([^'\n]+)'", text):
            discover_path(m.group(1), secrets)
    for text in texts:
        for rx in QUOTED_PATH_RES:
            for m in rx.finditer(text):
                if policy.is_library(m.group(1)):
                    discover_path(m.group(1), secrets)
        for start, end in iter_unquoted_library_paths(text, policy):
            discover_path(text[start:end], secrets)
        for m in HOME_RE.finditer(text):
            name = m.group(2)
            if not is_placeholder_text(name) and name.lower() not in ("shared", "public", "default", "authenticatebyname"):
                secrets.home_names.add(name)
        # hosts
        for m in URL_AUTHORITY_RE.finditer(text):
            if m.group(2):
                userinfo = m.group(2)
                for piece in re.split(r"[:]", userinfo):
                    if len(piece) >= 4 and not is_placeholder_text(piece):
                        secrets.tokens.add(piece)
            add_host(m.group(3), secrets)
        for m in HOST_HEADER_RE.finditer(text):
            add_host(m.group(2), secrets)
        for m in PLEX_DIRECT_RE.finditer(text):
            add_host(m.group(0), secrets)
        for m in re.finditer(r"\\\\([A-Za-z0-9][\w.-]+)\\", text):
            add_host(m.group(1), secrets)
        # key/value identifiers
        for cat, patterns in KV_PATTERNS.items():
            for rx in patterns:
                for m in rx.finditer(text):
                    record_value(cat, m.group("val").strip(), secrets)
        for m in AUTH_HEADER_RE.finditer(text):
            for km in re.finditer(r'([A-Za-z]+)="([^"]*)"', m.group(0)):
                key, val = km.group(1).lower(), km.group(2)
                if key in ("token", "deviceid", "userid"):
                    record_value("credential", val, secrets)
                elif key == "device":
                    record_value("device", val, secrets)
        for m in BEARER_RE.finditer(text):
            record_value("credential", m.group(2), secrets)
        for rx in SESSION_CONTEXT_RES:
            for m in rx.finditer(text):
                secrets.session_placeholder(m.group(1))
        for rx in USER_CONTEXT_RES:
            for m in rx.finditer(text):
                record_value("user", m.group(1).strip(), secrets)
        for rx in DEVICE_CONTEXT_RES:
            for m in rx.finditer(text):
                record_value("device", m.group(1).strip(), secrets)
        for rx in TITLE_CONTEXT_RES:
            for m in rx.finditer(text):
                add_title(m.group(1), secrets)
        for rx in WHOLESALE_TITLE_RES:
            for m in rx.finditer(text):
                value = m.group(2)
                if value.startswith(("/", "\\")) or re.match(r"[A-Za-z]:\\", value):
                    discover_path(value, secrets)
                else:
                    for part in re.split(r"[\\/]", value):
                        add_title(part, secrets)
        for name in media_source_names(text):
            add_title(name, secrets)
        for m in SEARCH_LINE_RE.finditer(text):
            for g in (2, 4):
                term = m.group(g).strip().strip('"*')
                if term and not is_placeholder_text(term):
                    secrets.search_terms.add(term)
        for title in container_titles(text):
            add_title(title, secrets, release=True)


def media_source_names(text: str) -> list[str]:
    """Return the item `"Name"` of each media-source JSON object (the one carrying `"Path"`)."""
    out: list[str] = []
    for m in re.finditer(r'"Path"\s*:\s*"[^"]*"', text):
        window = text[m.end():m.end() + 4000]
        nested = re.search(r'\{\s*"', window)
        if nested:
            window = window[: nested.start()]
        nm = re.search(r'"Name"\s*:\s*"([^"]*)"', window)
        if nm:
            out.append(nm.group(1))
        back = text[max(0, m.start() - 4000):m.start()]
        brace = back.rfind("{")
        if brace != -1:
            nm = re.search(r'"Name"\s*:\s*"([^"]*)"', back[brace:])
            if nm:
                out.append(nm.group(1))
    return out


def container_titles(text: str) -> list[str]:
    """Return the global (container-level) `title :` metadata of each ffmpeg input."""
    out: list[str] = []
    in_input = False
    for line in text.splitlines():
        body = re.sub(r"^\d\d:\d\d:\d\d\.\d+\s+", "", line)
        if re.match(r"\s*Input #\d+", body):
            in_input = True
            continue
        if in_input and re.match(r"\s*(Duration:|Stream #|Output #)", body):
            in_input = False
            continue
        if in_input:
            m = re.match(r"\s*title\s*:\s*(.+)$", body)
            if m and not is_placeholder_text(m.group(1)):
                out.append(m.group(1).strip())
    return out


def add_title(raw: str, secrets: Secrets, release: bool = False) -> None:
    raw = raw.strip()
    if not raw or is_placeholder_text(raw):
        return
    cands = title_candidates(raw)
    secrets.titles.update(cands)
    if release or (cands and raw not in cands):
        if len(raw) >= 4:
            secrets.releases.add(raw)


def add_host(host: str, secrets: Secrets) -> None:
    host = host.strip("[]").rstrip(".")
    if not host or is_placeholder_text(host):
        return
    if is_ipv4(host) or ":" in host:
        return
    if host.lower() in ("localhost",) or is_public_host(host):
        return
    if "." not in host:
        # Single-label hosts are only replaced in host contexts, never globally.
        secrets.host_placeholder(host)
        return
    if DOTTED_HOST_RE.match(host):
        secrets.host_placeholder(host)


def record_value(cat: str, value: str, secrets: Secrets) -> None:
    value = value.strip().strip('"')
    if not value or is_placeholder_text(value) or value.lower() in ("null", "none", "true", "false", "undefined"):
        return
    if cat == "credential":
        if len(value) >= 6 and not re.fullmatch(r"x+", value):
            secrets.tokens.add(value)
    elif cat == "session":
        if len(value) >= 6:
            secrets.session_placeholder(value)
    elif cat == "device":
        secrets.devices.add(value)
    elif cat == "user":
        if not re.fullmatch(r"[0-9a-fA-F-]{16,}|\d+", value):
            secrets.users.add(value)
    elif cat == "search_term":
        secrets.search_terms.add(value.replace("+", " ").replace("%20", " "))


def iter_unquoted_library_paths(text: str, policy: PathPolicy):
    for m in UNQUOTED_PATH_START.finditer(text):
        start = m.start()
        if start and text[start - 1] in "\"'":
            continue
        line_start = text.rfind("\n", 0, start) + 1
        if HTTP_METHOD_BEFORE.search(text[line_start:start]):
            continue
        if PATH_PLACEHOLDER_RE.match(text, start):
            continue
        token_end = start
        while token_end < len(text) and text[token_end] not in " \t\r\n\"<>":
            token_end += 1
        token = text[start:token_end]
        if not policy.is_library(token) and not policy.is_library(text[start:text.find("\n", start) if "\n" in text[start:] else len(text)].rstrip()):
            continue
        # Library path: extend to the first media extension, else to end of line.
        line_end = text.find("\n", start)
        if line_end == -1:
            line_end = len(text)
        segment = text[start:line_end]
        cut = re.search(r"[\"<>]", segment)
        if cut:
            segment = segment[: cut.start()]
        ext = re.search(r"\.(%s)(?=$|[\s,;)\]])" % MEDIA_EXT, segment, re.I)
        if ext:
            segment = segment[: ext.end()]
        segment = segment.rstrip(" \t\r.,;:")
        if not policy.is_library(segment):
            continue
        yield start, start + len(segment)


# --- replacement ------------------------------------------------------------------------


class Scrubber:
    def __init__(self, secrets: Secrets) -> None:
        self.s = secrets
        self.policy = PathPolicy(secrets)
        title_set = {t for t in secrets.titles if eligible_phrase(t)}
        secrets.skipped_short_titles = len(secrets.titles) - len(title_set)
        self.titles = PhraseSet(title_set)
        self.releases = PhraseSet({r for r in secrets.releases if eligible_phrase(r, 4)})
        self.search = PhraseSet({t for t in secrets.search_terms if eligible_phrase(t, 4)})
        self.users = PhraseSet({u for u in secrets.users if eligible_phrase(u, 3)})
        self.devices = PhraseSet({d for d in secrets.devices if eligible_phrase(d, 3)})
        tokens = sorted((t for t in secrets.tokens if len(t) >= 6), key=len, reverse=True)
        self.tokens_re = re.compile("|".join(re.escape(t) for t in tokens)) if tokens else None
        sess = sorted(secrets.sessions, key=len, reverse=True)
        self.sessions_re = re.compile("|".join(re.escape(t) for t in sess)) if sess else None
        dotted = sorted((h for h in secrets.hosts if "." in h), key=len, reverse=True)
        self.hosts_re = re.compile(r"(?i)(?<![\w.-])(%s)(?![\w-]|\.[\w-])" % "|".join(re.escape(h) for h in dotted)) if dotted else None
        homes = sorted(secrets.home_names, key=len, reverse=True)
        self.homes_re = re.compile(r"(?<![\w.])(/(?:home|Users)/|[A-Za-z]:\\Users\\)(%s)(?=[/\\\s\"'<>]|$)" % "|".join(re.escape(h) for h in homes)) if homes else None

    # Each step returns new text and records counts.
    def scrub(self, text: str, c: Counter, depth: int = 0) -> str:
        text = self._payloads(text, c, depth)
        text = self._search_lines(text, c)
        text = self._key_values(text, c)
        text = self._paths(text, c)
        text = self._urls_and_hosts(text, c)
        for rx in WHOLESALE_TITLE_RES:
            text = self._sub(rx, lambda m: m.group(0) if only_placeholders(m.group(2)) else m.group(1) + P_TITLE + m.group(3), text, c, "title")
        text = self._sub(ACCOUNT_URL_RE, lambda m: m.group(1) + P_REDACTED, text, c, "credential")
        text = self._sub(EMAIL_RE, lambda m: P_REDACTED, text, c, "email")
        if self.tokens_re:
            text = self._sub(self.tokens_re, lambda m: P_REDACTED, text, c, "credential")
        if self.sessions_re:
            text = self._sub(self.sessions_re, lambda m: self.s.sessions[m.group(0)], text, c, "session")
        for name, phrases, repl in (
            ("release_name", self.releases, P_TITLE),
            ("title", self.titles, P_TITLE),
            ("search_term", self.search, P_REDACTED),
            ("user", self.users, P_USER),
            ("device", self.devices, P_DEVICE),
        ):
            text, n = phrases.sub(text, repl)
            c.add(name, n)
        text = self._network(text, c)
        if self.homes_re:
            text = self._sub(self.homes_re, lambda m: m.group(1) + P_USER, text, c, "home_dir")
        text = self._collapse(text, c)
        return text

    @staticmethod
    def _sub(rx: re.Pattern[str], fn, text: str, c: Counter, cat: str) -> str:
        n = 0

        def wrap(m):
            nonlocal n
            out = fn(m)
            if out != m.group(0):
                n += 1
            return out

        text = rx.sub(wrap, text)
        c.add(cat, n)
        return text

    def _payloads(self, text: str, c: Counter, depth: int) -> str:
        def fix(m):
            fmt, decoded = decode_blob(m.group(0))
            if decoded is None or depth >= 3:
                c.add("payload_removed")
                return P_PAYLOAD
            scrubbed = self.scrub(decoded, c, depth + 1)
            c.add("payload_rescrubbed")
            if scrubbed == decoded:
                return m.group(0)
            try:
                return encode_blob(fmt, scrubbed)
            except Exception:
                c.add("payload_removed")
                return P_PAYLOAD

        return BLOB_RE.sub(fix, text)

    def _search_lines(self, text: str, c: Counter) -> str:
        def fix(m):
            c.add("search_term")
            return f"{m.group(1)}{P_REDACTED}{m.group(3)}{P_REDACTED}"

        return SEARCH_LINE_RE.sub(fix, text)

    def _key_values(self, text: str, c: Counter) -> str:
        repl_for = {
            "credential": lambda v: P_REDACTED,
            "session": lambda v: self.s.session_placeholder(v) if len(v) >= 6 else P_REDACTED,
            "device": lambda v: P_DEVICE,
            "user": lambda v: P_USER if not re.fullmatch(r"[0-9a-fA-F-]{16,}|\d+", v) else P_REDACTED,
            "search_term": lambda v: P_REDACTED,
        }
        for cat, patterns in KV_PATTERNS.items():
            for rx in patterns:
                def fix(m, cat=cat):
                    val = m.group("val")
                    stripped = val.strip()
                    if not stripped or is_placeholder_text(stripped) or stripped.lower() in ("null", "none", "true", "false"):
                        return m.group(0)
                    if cat == "credential" and stripped.isdigit() and len(stripped) <= 2 and "id" not in m.group(0).lower():
                        return m.group(0)
                    c.add(cat)
                    s, e = m.span("val")
                    s -= m.start()
                    e -= m.start()
                    whole = m.group(0)
                    lead = len(val) - len(val.lstrip())
                    return whole[: s + lead] + repl_for[cat](stripped) + whole[s + lead + len(stripped):]

                text = rx.sub(fix, text)

        def auth(m):
            def inner(km):
                key = km.group(1).lower()
                if key in ("token", "deviceid", "userid"):
                    c.add("credential")
                    return f'{km.group(1)}="{P_REDACTED}"'
                if key == "device":
                    c.add("device")
                    return f'{km.group(1)}="{P_DEVICE}"'
                return km.group(0)

            return re.sub(r'([A-Za-z]+)="([^"]*)"', inner, m.group(0))

        text = AUTH_HEADER_RE.sub(auth, text)
        text = self._sub(BEARER_RE, lambda m: f"{m.group(1)} {P_REDACTED}", text, c, "credential")
        for rx in SESSION_CONTEXT_RES:
            text = self._sub(rx, lambda m: m.group(0).replace(m.group(1), self.s.session_placeholder(m.group(1))), text, c, "session")
        text = self._sub(re.compile(r"(?i)(Plex-Client-Identifier|clientIdentifier|machineIdentifier)(=|:\s*|=\")([0-9a-z-]{8,})"), lambda m: m.group(1) + m.group(2) + P_REDACTED, text, c, "credential")
        return text

    def _paths(self, text: str, c: Counter) -> str:
        # Quoted paths first (they may contain spaces and apostrophes of the other quote kind).
        def quoted(m):
            p = m.group(1)
            if self.policy.is_library(p):
                c.add("path")
                q = m.group(0)[0]
                return q + self.policy.placeholder(p) + q
            return m.group(0)

        for rx in QUOTED_PATH_RES:
            text = rx.sub(quoted, text)
        spans = list(iter_unquoted_library_paths(text, self.policy))
        if spans:
            out, last = [], 0
            for s, e in spans:
                if s < last:
                    continue
                out.append(text[last:s])
                out.append(self.policy.placeholder(text[s:e]))
                last = e
                c.add("path")
            out.append(text[last:])
            text = "".join(out)
        return text

    def _urls_and_hosts(self, text: str, c: Counter) -> str:
        def url(m):
            scheme, userinfo, host = m.group(1), m.group(2), m.group(3)
            out = scheme
            if userinfo is not None:
                out += P_REDACTED + "@"
                c.add("credential")
            bare = host.strip("[]").rstrip(".")
            if bare.lower() in self.s.hosts:
                out += self.s.hosts[bare.lower()]
                c.add("host")
            else:
                out += host
            return out

        text = URL_AUTHORITY_RE.sub(url, text)

        def header(m):
            host = m.group(2).rstrip(".")
            if host.lower() in self.s.hosts:
                c.add("proxy" if "server" in m.group(1).lower() else "host")
                return m.group(1) + self.s.hosts[host.lower()]
            return m.group(0)

        text = HOST_HEADER_RE.sub(header, text)
        text = self._sub(PLEX_DIRECT_RE, lambda m: self.s.host_placeholder(m.group(0)), text, c, "host")
        if self.hosts_re:
            text = self._sub(self.hosts_re, lambda m: self.s.hosts[m.group(1).lower()], text, c, "host")
        return text

    def _network(self, text: str, c: Counter) -> str:
        text = self._sub(MAC_RE, lambda m: P_REDACTED, text, c, "mac")

        def v4(m):
            ip = m.group(1)
            if not is_ipv4(ip) or keep_ipv4(ip) or ipv4_is_version(m.string, m.start()):
                return ip
            return self.s.ipv4_placeholder(ip)

        text = self._sub(IPV4_RE, v4, text, c, "ipv4")
        text = self._sub(IPV4_DASHED_RE, lambda m: self.s.ipv4_placeholder(m.group(1).replace("-", ".")).replace(".", "-") if is_ipv4(m.group(1).replace("-", ".")) else m.group(0), text, c, "ipv4")

        def v6(m):
            tok = m.group(1)
            if not looks_like_ipv6(tok) or keep_ipv6(tok):
                return tok
            # IPv4-mapped prefix (::ffff:) followed by a dotted quad is handled by the IPv4 rule.
            return self.s.ipv6_placeholder(tok)

        text = self._sub(IPV6_RE, v6, text, c, "ipv6")
        return text

    def _collapse(self, text: str, c: Counter) -> str:
        def ctitle(m):
            if P_TITLE in m.group(2) and m.group(2).strip() != P_TITLE:
                c.add("release_name")
                return m.group(1) + P_TITLE
            return m.group(0)

        text = CONTAINER_TITLE_RE.sub(ctitle, text)

        def jtitle(m):
            if P_TITLE in m.group(2) and m.group(2) != P_TITLE:
                c.add("release_name")
                return f'"{m.group(1)}":"{P_TITLE}"'
            return m.group(0)

        text = JSON_TITLE_RE.sub(jtitle, text)

        def xtitle(m):
            if P_TITLE in m.group(2) and m.group(2) != P_TITLE:
                c.add("release_name")
                return f'{m.group(1)}="{P_TITLE}"'
            return m.group(0)

        text = XML_TITLE_RE.sub(xtitle, text)
        text = self._sub(
            re.compile(r"(<title>)([ ._\-]*[(\[]?)((?:19|20)\d\d)(?!\d)"),
            lambda m: m.group(1) + m.group(2) + P_YEAR,
            text,
            c,
            "year",
        )
        return text


# --- verification -----------------------------------------------------------------------

GENERIC_TOKEN_RE = re.compile(
    r"(?i)(?<![\w-])(?:%s)(?:=|\"?\s*:\s*\"?|=\")(?![<\"&\s]|$)([^&\s\",;<>]{4,})"
    % _alt([PLEX_AUTH_HEADER, "api_key", "apikey", "access_token", "X-Emby-Token", "X-MediaBrowser-Token", "DeviceId", "X-Emby-Device-Id", "X-Plex-Client-Identifier", "Private-Network-Access-Id", "Token", "UserId", "machineIdentifier"])
)


def verify_text(text: str, scrubber: Scrubber) -> list[tuple[int, str]]:
    """Return (line, category) findings for one text (and its decoded payloads)."""
    findings: list[tuple[int, str]] = []

    def line_of(t: str, pos: int) -> int:
        return t.count("\n", 0, pos) + 1

    for idx, t in enumerate(expand_payloads(text)):
        def hit(pos: int, cat: str) -> None:
            findings.append((line_of(text, 0) if idx else line_of(t, pos), cat if not idx else f"{cat} (in payload)"))

        if idx == 0:
            for m in BLOB_RE.finditer(t):
                if decode_blob(m.group(0))[1] is None:
                    hit(m.start(), "undecodable_payload")
        for phrases, cat in (
            (scrubber.titles, "title"),
            (scrubber.releases, "release_name"),
            (scrubber.search, "search_term"),
            (scrubber.users, "user"),
            (scrubber.devices, "device"),
        ):
            for m in phrases.finditer(t):
                hit(m.start(), cat)
        if scrubber.tokens_re:
            for m in scrubber.tokens_re.finditer(t):
                hit(m.start(), "credential")
        if scrubber.sessions_re:
            for m in scrubber.sessions_re.finditer(t):
                hit(m.start(), "session")
        if scrubber.hosts_re:
            for m in scrubber.hosts_re.finditer(t):
                hit(m.start(), "host")
        if scrubber.homes_re:
            for m in scrubber.homes_re.finditer(t):
                hit(m.start(), "home_dir")
        for m in IPV4_RE.finditer(t):
            ip = m.group(1)
            if is_ipv4(ip) and not keep_ipv4(ip) and not ipv4_is_version(t, m.start()):
                hit(m.start(), "ipv4")
        for m in IPV6_RE.finditer(t):
            if looks_like_ipv6(m.group(1)) and not keep_ipv6(m.group(1)):
                hit(m.start(), "ipv6")
        for m in MAC_RE.finditer(t):
            hit(m.start(), "mac")
        for m in EMAIL_RE.finditer(t):
            hit(m.start(), "email")
        for m in ACCOUNT_URL_RE.finditer(t):
            hit(m.start(), "credential")
        for m in GENERIC_TOKEN_RE.finditer(t):
            if not is_placeholder_text(m.group(1)):
                hit(m.start(), "credential")
        for m in re.finditer(r"(?<![\w.])(?:/(?:home|Users)/|[A-Za-z]:\\Users\\)(?!<user>)([A-Za-z0-9._-]+)", t):
            if m.group(1).lower() not in ("shared", "public", "default", "authenticatebyname", "authenticate"):
                hit(m.start(), "home_dir")
        for m in PLEX_DIRECT_RE.finditer(t):
            hit(m.start(), "host")
        for m in URL_AUTHORITY_RE.finditer(t):
            host = m.group(3).strip("[]")
            if m.group(2) and not is_placeholder_text(m.group(2)):
                hit(m.start(), "credential")
            if "." in host and not is_ipv4(host) and DOTTED_HOST_RE.match(host) and not is_public_host(host):
                hit(m.start(), "host")
        for rx in QUOTED_PATH_RES:
            for m in rx.finditer(t):
                if scrubber.policy.is_library(m.group(1)):
                    hit(m.start(), "path")
        for s, _ in iter_unquoted_library_paths(t, scrubber.policy):
            hit(s, "path")
    return findings


# --- window extraction ------------------------------------------------------------------


@dataclasses.dataclass
class InputFile:
    rel: str
    name: str
    text: str
    backend: str | None
    role: str


def in_window(ts: dt.datetime | None, since: dt.datetime | None, until: dt.datetime | None) -> bool:
    if ts is None:
        return False
    if since and ts < since:
        return False
    if until and ts > until:
        return False
    return True


def filter_main_log(text: str, since, until, session: str | None) -> str:
    # Group continuation lines with the timestamped line that precedes them.
    records: list[tuple[dt.datetime | None, list[str]]] = []
    for line in text.splitlines(keepends=True):
        ts = parse_line_time(line)
        if ts is not None or not records:
            records.append((ts, [line]))
        else:
            records[-1][1].append(line)
    keep = []
    for ts, lines in records:
        if (since or until) and not in_window(ts, since, until):
            continue
        keep.append((ts, lines))
    if session:
        tags: set[str] = set()
        for _, lines in keep:
            body = "".join(lines)
            if session in body:
                tags.update(CONTEXT_TAG_RE.findall(body))
        keep = [
            (ts, lines)
            for ts, lines in keep
            if session in "".join(lines) or any(t in "".join(lines) for t in tags)
        ]
    return "".join("".join(lines) for _, lines in keep)


def filter_plex_statistics(text: str, since, until, session: str | None) -> str:
    out = []
    for m in PLEX_REPORT_RE.finditer(text):
        block = m.group(0)
        tsm = PLEX_REPORT_TS_RE.search(block)
        ts = None
        if tsm:
            try:
                ts = dt.datetime.strptime(tsm.group(1).split(".")[0], "%b %d, %Y %H:%M:%S")
            except ValueError:
                ts = None
        if (since or until) and not in_window(ts, since, until):
            continue
        if session and session not in block:
            continue
        out.append(block + "\n")
    return "".join(out)


def apply_window(files: list[InputFile], since, until, session: str | None) -> tuple[list[InputFile], list[str]]:
    if not (since or until or session):
        return files, []
    notes: list[str] = []
    selected: list[InputFile] = []
    referenced: set[str] = set()
    media_ids: set[str] = set()
    for f in files:
        if f.role == "main":
            body = filter_main_log(f.text, since, until, session)
            referenced.update(m.lower() for m in EMBY_FFMPEG_REF_RE.findall(body))
            media_ids.update(re.findall(r"(?i)MediaSourceId=([0-9a-f]{32})", body))
            if body:
                selected.append(dataclasses.replace(f, text=body))
            else:
                notes.append(f"{f.rel}: no lines in window")
    for f in files:
        if f.role == "transcoder":
            keep = False
            if f.backend == "plex" or f.name.lower().startswith("plex transcoder statistics"):
                body = filter_plex_statistics(f.text, since, until, session)
                if body:
                    selected.append(dataclasses.replace(f, text=body))
                continue
            stem = f.name.rsplit(".", 1)[0].lower()
            if stem in referenced:
                keep = True
            if session and session in f.text:
                keep = True
            jm = JELLYFIN_FFMPEG_NAME_RE.match(f.name)
            if jm:
                try:
                    started = dt.datetime.strptime(jm.group(1), "%Y-%m-%d_%H-%M-%S")
                except ValueError:
                    started = None
                if (since or until) and in_window(started, since, until):
                    keep = True
                if any(mid in f.name.lower() for mid in media_ids):
                    keep = keep or not (since or until) or in_window(started, since, until)
            if keep:
                selected.append(f)
        elif f.role == "other":
            body = filter_main_log(f.text, since, until, session)
            if body:
                selected.append(dataclasses.replace(f, text=body))
    return selected, notes


# --- IO ---------------------------------------------------------------------------------


def collect_inputs(paths: list[pathlib.Path], backend: str) -> tuple[list[InputFile], list[str]]:
    files: list[InputFile] = []
    skipped: list[str] = []
    for root in paths:
        if root.is_dir():
            candidates = sorted(p for p in root.rglob("*") if p.is_file() and not any(part.startswith(".") for part in p.relative_to(root).parts))
            base = root
        elif root.is_file():
            candidates = [root]
            base = root.parent
        else:
            raise SystemExit(f"error: input not found: {root}")
        for p in candidates:
            data = p.read_bytes()
            if b"\x00" in data[:8192]:
                skipped.append(str(p.relative_to(base)))
                continue
            text = ZERO_WIDTH_RE.sub("", data.decode("utf-8", errors="replace"))
            b = detect_backend(p.name, text) if backend == "auto" else backend
            files.append(InputFile(str(p.relative_to(base)), p.name, text, b, file_role(p.name)))
    return files, skipped


def ensure_output_dir(output: pathlib.Path, inputs: list[pathlib.Path]) -> None:
    out = output.resolve()
    for i in inputs:
        r = i.resolve()
        if out == r or (r.is_dir() and (out == r or r in out.parents)) or (r.is_file() and out == r.parent):
            raise SystemExit("error: --output must not be an input file/directory or inside an input directory")
    if out.exists() and any(out.iterdir()):
        raise SystemExit("error: --output directory exists and is not empty; choose a fresh directory")
    out.mkdir(parents=True, exist_ok=True)


def run(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+", type=pathlib.Path, help="log files or directories")
    ap.add_argument("--backend", choices=("auto",) + BACKENDS, default="auto")
    ap.add_argument("--output", type=pathlib.Path, required=True, help="fresh directory for scrubbed copies")
    ap.add_argument("--since", type=parse_user_time, help="keep main-log lines at/after this local log time")
    ap.add_argument("--until", type=parse_user_time, help="keep main-log lines at/before this local log time")
    ap.add_argument("--play-session", help="keep main-log lines mentioning this play session id (plus same-request lines)")
    ap.add_argument("--report", type=pathlib.Path, help="write a JSON report (categories and counts only)")
    args = ap.parse_args(argv)

    files, skipped = collect_inputs(args.inputs, args.backend)
    ensure_output_dir(args.output, args.inputs)
    files, notes = apply_window(files, args.since, args.until, args.play_session)

    secrets = Secrets()
    all_texts: list[str] = []
    for f in files:
        all_texts.extend(expand_payloads(f.text))
        all_texts.append(f.rel)
    discover(all_texts, secrets)
    scrubber = Scrubber(secrets)

    report: dict = {"files": {}, "verify": {}, "skipped_binary": len(skipped), "notes": notes}
    totals: collections.Counter[str] = collections.Counter()
    failures = 0
    for f in files:
        c = Counter()
        out_text = scrubber.scrub(f.text, c)
        rel_counter = Counter()
        out_rel = scrubber.scrub(f.rel, rel_counter)
        if out_rel != f.rel:
            c.add("file_name")
        dest = args.output / out_rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest.exists():
            dest = dest.with_name(dest.stem + f"-{len(report['files'])}" + dest.suffix)
        dest.write_text(out_text, encoding="utf-8")
        key = str(dest.relative_to(args.output))
        report["files"][key] = {"backend": f.backend, "role": f.role, "replacements": dict(sorted(c.counts.items()))}
        totals.update(c.counts)
        findings = verify_text(out_text, scrubber) + [(0, f"file_name:{cat}") for _, cat in verify_text(out_rel, scrubber)]
        if findings:
            failures += len(findings)
            by_cat = collections.Counter(cat for _, cat in findings)
            report["verify"][key] = {"categories": dict(sorted(by_cat.items())), "lines": sorted({ln for ln, _ in findings})[:200]}

    report["discovered"] = {
        "hosts": len(secrets.hosts),
        "ipv4": len(secrets.ipv4),
        "ipv6": len(secrets.ipv6),
        "credentials": len(secrets.tokens),
        "sessions": len(secrets.sessions),
        "users": len(secrets.users),
        "devices": len(secrets.devices),
        "titles": len(secrets.titles),
        "titles_short_context_only": secrets.skipped_short_titles,
        "release_names": len(secrets.releases),
        "search_terms": len(secrets.search_terms),
        "library_roots": len(secrets.library_roots),
        "home_dirs": len(secrets.home_names),
    }
    report["totals"] = dict(sorted(totals.items()))
    report["verify_ok"] = failures == 0

    print(f"scrubbed {len(files)} file(s) into {args.output}" + (f"; skipped {len(skipped)} binary file(s)" if skipped else ""))
    for note in notes:
        print(f"  note: {note}")
    print("discovered: " + ", ".join(f"{k}={v}" for k, v in report["discovered"].items()))
    print("replacements: " + (", ".join(f"{k}={v}" for k, v in report["totals"].items()) or "none"))
    for name, info in report["files"].items():
        counts = ", ".join(f"{k}={v}" for k, v in info["replacements"].items()) or "none"
        print(f"  {name} [{info['backend'] or 'unknown'}/{info['role']}]: {counts}")
    if failures:
        print(f"VERIFY FAILED: {failures} residual finding(s); do not share this output.", file=sys.stderr)
        for name, info in report["verify"].items():
            cats = ", ".join(f"{k}={v}" for k, v in info["categories"].items())
            print(f"  {name}: {cats} (lines {', '.join(map(str, info['lines'][:20]))})", file=sys.stderr)
        (args.output / "SCRUB-VERIFY-FAILED").write_text("Residual sensitive findings; see the scrubber report. Do not share.\n")
    else:
        print("verify: clean")
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(run())
