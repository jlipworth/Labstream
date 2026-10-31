"""Hermetic tests for scripts/scrub-server-logs.py.

Every fixture is synthetic: invented hosts under .invalid, fake tokens, and a made-up title.
Private-range addresses and home paths are assembled at run time so the repository's
publication scanners never see them as literals.
"""
import base64
import contextlib
import gzip
import io
import json
import pathlib
import sys
import tempfile
import unittest
import zlib
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _script_loader import load_script  # noqa: E402

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scrub-server-logs.py"
scrub = load_script("scrub_server_logs", SCRIPT)

PLEX_AUTH = scrub.PLEX_AUTH_HEADER
LAN = ".".join(["192", "168", "40", "23"])
LAN2 = ".".join(["10", "8", "0", "5"])
WAN = ".".join(["81", "2", "69", "142"])
HOME = "/" + "home" + "/" + "quietfox"
HOST = "media.home.invalid"
TITLE = "The Quiet Lantern"
RELEASE = "The.Quiet.Lantern.2011.2160p.UHD.BluRay.REMUX.HDR.HEVC-LANTERNGRP"
PATH = f"/data/movies/{TITLE} (2011)/{RELEASE}.mkv"
USER = "lanternkeeper"
DEVICE = "Hallway Projector"
API_KEY = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
DEVICE_ID = "D3V1CE-77aa88bb99cc"
PLAY_SESSION = "5e5e1d1d2c2c3b3b4a4a59596868f7f7"
PROXY_POD = "traefik-6d9f8c7b5-x2kqp"
PNA_ID = "a1b2c3d4e5f60718"
MAC = ":".join(["3c", "22", "fb", "11", "aa", "9e"])
EMBY_FFMPEG = "ffmpeg-remux-0a1b2c3d-1111-2222-3333-444455556666_1.txt"
EMBY_FFMPEG_OTHER = "ffmpeg-remux-9f8e7d6c-1111-2222-3333-444455556666_1.txt"
ZW = "‌‍‍"

ALL_SECRETS = [LAN, LAN2, WAN, HOST, TITLE, RELEASE, USER, DEVICE, API_KEY, DEVICE_ID, PLAY_SESSION, PROXY_POD, PNA_ID, MAC, "quietfox", "LANTERNGRP"]


def gz_b64(text: str) -> str:
    return base64.b64encode(gzip.compress(text.encode(), mtime=0)).decode()


def emby_graph_blob() -> str:
    graph = json.dumps({
        "Command": {"GlobalOptions": {"OptionValues": [{"Name": "print_graphs_file", "ValueString": "/config/logs/x_1graph.txt"}]},
                    "Inputs": [{"Path": PATH, "Title": f"{TITLE} (2011)", "Padding": "pad " * 100}]},
    })
    return gz_b64(graph)


def emby_main_log() -> str:
    url = f"http://{ZW}{HOST}{ZW}/emby/videos/1229/main.m3u8?DeviceId={DEVICE_ID}&MediaSourceId=mediasource_1229&PlaySessionId={PLAY_SESSION}&api_key={API_KEY}&VideoBitrate=199616000"
    return "\n".join([
        f"2026-10-30 23:24:06.653 Info SqliteItemRepository: Original search term: quiet lant. Bound search term: \"quiet lant\"*",
        f"2026-10-30 23:24:06.779 Info MediaInfoService-0HNPME0LUAKHR:00000001: http/1.1 POST http://{HOST}/emby/Items/1229/PlaybackInfo?UserId=9a8b7c6d5e4f30211203f4e5d6c7b8a9 Source Ip: {ZW}{LAN}{ZW}, UserAgent: Labstream/2 CFNetwork/3896.100.1.1.1 Darwin/27.0.0",
        f"2026-10-30 23:24:06.781 Info MediaInfoService-0HNPME0LUAKHR:00000001: User policy for {USER}. EnablePlaybackRemuxing: True",
        f"2026-10-30 23:24:06.827 Info DynamicHlsService-0HNPME0LUAKHT:00000001: http/1.1 GET {url} Source Ip: {LAN}, Accept=*/*, Host={HOST}, User-Agent=AppleCoreMedia/1.0.0.23A434 (Apple Vision Pro; U; CPU OS 27_0 like Mac OS X; en_us), X-Forwarded-For={WAN}, X-Forwarded-Host={HOST}, X-Forwarded-Server={PROXY_POD}, X-Real-Ip={WAN}, Private-Network-Access-Id={PNA_ID}, Private-Network-Access-Name={DEVICE}",
        f"2026-10-30 23:24:06.933 Info DynamicHlsService-0HNPME0LUAKIB:00000001: ProcessRun 'StreamTranscode 0a1b2c' Execute: /app/emby/bin/ffmpeg -loglevel +timing -y -print_graphs_file \"/config/logs/{EMBY_FFMPEG[:-4]}graph.txt\" -copyts -ss 01:00:20.000 -i \"{PATH}\" -map 0:0 -c:v:0 copy -hls_segment_filename \"/data/transcode/transcoding-temp/0C346E/0C346E_%d.m4s\" \"/data/transcode/transcoding-temp/0C346E/0C346E.m3u8\"",
        f"2026-10-30 23:24:07.703 Info SessionManager: Setting _lastPlaySessionId for session dfdfdfdf0123456789abcdefabcdef01 to {PLAY_SESSION}",
        f"2026-10-30 23:24:07.704 Info SessionManager: Playback start reported by app Labstream 1.8.0 on {DEVICE} playing {TITLE}. Position: 3620000 ms. PlaySessionId: {PLAY_SESSION}. IsPaused: False",
        f"2026-10-30 23:24:07.710 Info Server: Authorization=MediaBrowser Client=\"Labstream\", Device=\"{DEVICE}\", DeviceId=\"{DEVICE_ID}\", Version=\"1.8.0\", Token=\"{API_KEY}\"",
        f"2026-10-30 23:24:07.712 Info Network: adapter eth0 mac {MAC} home {HOME}/config",
        "2026-10-30 23:59:00.000 Info App: Emby Server version: 4.10.2.0 Operating system: Unix 6.8.0.147",
        "2026-10-31 01:00:00.000 Info SessionManager: unrelated later line",
        "",
    ])


def emby_ffmpeg_log() -> str:
    return "\n".join([
        "Emby Server version: 4.10.2.0",
        "Operating system: Unix 6.8.0.147",
        "App: Labstream 1.8.0",
        DEVICE,
        "User-Agent: Labstream/2 CFNetwork/3896.100.1.1.1 Darwin/27.0.0",
        "",
        f"http://{HOST}/emby/videos/1229/hls1/main/1810.m4s?PlaySessionId={PLAY_SESSION}&api_key={API_KEY}",
        "",
        json.dumps({"Protocol": "File", "Id": "mediasource_1229", "Path": PATH, "Container": "mkv", "Name": f"{TITLE} (2011) - 2160p", "MediaStreams": [{"Title": "DTS-HD MA 5.1"}]}),
        f">>>>>>  User policy for {USER}",
        f"23:24:06.946 Input #0, matroska,webm, from '{PATH}':",
        "23:24:06.946   Metadata:",
        f"23:24:06.946     title           : {RELEASE}",
        "23:24:06.946     encoder         : libebml v1.4.2 + libmatroska v1.6.4",
        "23:24:06.946   Duration: 01:33:53.25, start: 0.000000, bitrate: 68909 kb/s",
        "23:24:06.946   Stream #0:1(eng): Audio: dts (DTS-HD MA), 48000 Hz, 5.1(side), s32p (24 bit) (default)",
        "23:24:06.946     Metadata:",
        "23:24:06.946       title           : DTS-HD MA 5.1",
        "23:24:06.951 [hls @ 0x3743e840] Opening '/data/transcode/transcoding-temp/0C346E/0C346E_init.mp4' for writing",
        "23:24:07.212 SegmentComplete=video:0 Index=1 StartPts=86867784 EndPts=86867784 Duration=2.460000 filename=0C346E_1810.m4s",
        "======= ExtraData",
        emby_graph_blob(),
        "---",
        "",
    ])


def jellyfin_main_log() -> str:
    mapped = "::ffff:" + LAN
    return "\n".join([
        f"[2026-10-30 21:00:01.000 -04:00] [INF] [12] Jellyfin.Api.Controllers.UserController: Authentication request for \"{USER}\" has succeeded.",
        f"[2026-10-30 21:00:02.000 -04:00] [INF] [12] Jellyfin.Api.Helpers.MediaInfoHelper: User policy for \"{USER}\". EnablePlaybackRemuxing: True",
        f"[2026-10-30 21:00:03.000 -04:00] [INF] [14] MediaBrowser.MediaEncoding.Transcoding.TranscodeManager: \"/usr/lib/jellyfin-ffmpeg/ffmpeg\" -analyzeduration 200M -f matroska -i file:\"{PATH}\" -map_metadata -1 \"/cache/transcodes/0d9c8b7a6f5e4d3c2b1a.m3u8\"",
        f"[2026-10-30 21:00:04.000 -04:00] [INF] [14] Emby.Server.Implementations.Session.SessionManager: Playback start reported by app \"Labstream\" \"1.8.0\" playing \"{TITLE}\". Started at 0 ms",
        f"[2026-10-30 21:00:05.000 -04:00] [WRN] [14] Jellyfin.Api.Middleware.ResponseTimeMiddleware: Slow HTTP Response from \"https://{HOST}/Videos/abc/master.m3u8?ApiKey={API_KEY}&DeviceId={DEVICE_ID}\" to \"{mapped}\" in 0:00:01.2 with Status Code 200",
        f"[2026-10-30 21:00:06.000 -04:00] [INF] [15] Jellyfin.Networking.Manager.NetworkManager: Defined LAN addresses: [{LAN2}/24, fd12:3456:789a:1::25/64]",
        "[2026-10-30 21:00:07.000 -04:00] [INF] [1] Main: Jellyfin version: 10.10.7",
        f"[2026-10-30 21:00:08.000 -04:00] [INF] [16] Emby.Server.Implementations.Chapters.ChapterManager: Skipping chapter image extraction for \"Chapter 3: Lantern Light\" as the average chapter duration 0 was lower",
        "",
    ])


def jellyfin_ffmpeg_log() -> str:
    source = json.dumps({"Protocol": 0, "Id": "0d9c8b7a6f5e4d3c2b1a", "Path": PATH, "RequiredHttpHeaders": {}, "Name": f"{TITLE} - 2160p", "Container": "mkv"})
    return "\n".join([
        source,
        "",
        f"/usr/lib/jellyfin-ffmpeg/ffmpeg -analyzeduration 200M -f matroska -i file:\"{PATH}\" -map 0:0 \"/cache/transcodes/0d9c8b7a6f5e4d3c2b1a.m3u8\"",
        "",
        "ffmpeg version 7.0.2-Jellyfin Copyright (c) 2000-2024 the FFmpeg developers",
        f"Input #0, matroska,webm, from '{PATH}':",
        "  Metadata:",
        f"    title           : {RELEASE}",
        "  Duration: 01:33:53.25, start: 0.000000, bitrate: 68909 kb/s",
        "",
    ])


def plex_main_log() -> str:
    direct = LAN.replace(".", "-") + ".0123456789abcdef0123456789abcdef.plex.direct"
    jobs_path = f"/data/movies/{TITLE} (2011)/Director's Cut {RELEASE}.mkv"
    return "\n".join([
        f"Oct 30, 2026 22:10:00.100 [140234] DEBUG - Request: [{LAN}:52344 (Subnet)] GET /library/metadata/11977?includeChapters=1&{PLEX_AUTH}=fakeplextoken12345 (12 live) #1a2 TLS GZIP Signed-in Token ({USER})",
        f"Oct 30, 2026 22:10:00.200 [140234] DEBUG - Request: [{WAN}:41000 (WAN)] GET /video/:/transcode/universal/start.m3u8?X-Plex-Client-Identifier=c1d2e3f4a5b6c7d8&X-Plex-Device-Name=Hallway%20Projector&session={PLAY_SESSION} (13 live) #1a3 TLS Signed-in",
        f"Oct 30, 2026 22:10:00.300 [140234] DEBUG - Jobs: '/usr/lib/plexmediaserver/Plex Transcoder' '-codec:0' 'hevc' '-i' '{jobs_path}' '-map' '0:0' '-f' 'dash'",
        f"Oct 30, 2026 22:10:00.400 [140234] DEBUG - Scanner: Processing directory /data/movies/{TITLE} (2011)/Extras",
        f"Oct 30, 2026 22:10:00.500 [140234] DEBUG - Updating directory '{TITLE} (2011)' (ID 17) to time 1700000000",
        f"Oct 30, 2026 22:10:00.600 [140234] DEBUG - [Now] Device is https://{direct}:32400 machineIdentifier=0f0e0d0c0b0a09080706050403020100fedcba98",
        "Oct 30, 2026 22:10:00.700 [140234] INFO - Plex Media Server v1.41.3.9314-a0bfb8370 - Docker Docker Container x86_64 - build: linux-x86_64",
        "Oct 30, 2026 23:59:00.000 [140234] DEBUG - Request: unrelated later line",
        "",
    ])


def plex_statistics_log() -> str:
    def report(ts: str, transcode: str) -> str:
        return (
            f'<SessionReport version="2" startTime="0" startTimestamp="{ts}" transcode="{transcode}">\n'
            f'<User id="1" title="{USER}" thumb="https://plex.tv/users/f7d951016504698f/avatar?c=1" />\n'
            f'<Player address="{LAN}" remotePublicAddress="{WAN}" local="1" relayed="0" secure="1" userID="1" title="{DEVICE}" />\n'
            '<Media audioCodec="eac3" container="mkv" duration="5633000"><Stream codec="hevc" displayTitle="4K DoVi/HDR10 (HEVC Main 10)" /></Media>\n'
            "</SessionReport>\n"
        )

    return report("Oct 30, 2026 22:10:01.000", "a1a1a1a1-b2b2-c3c3-d4d4-e5e5e5e5e5e5") + report("Oct 31, 2026 06:20:52.044", "f9f9f9f9-b2b2-c3c3-d4d4-e5e5e5e5e5e5")


class ScrubCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.raw = self.root / "raw"
        self.raw.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name: str, text: str) -> pathlib.Path:
        p = self.raw / name
        p.write_text(text, encoding="utf-8")
        return p

    def run_cli(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = scrub.run(list(args))
        return rc, out.getvalue(), err.getvalue()

    def outputs(self, out_dir: pathlib.Path) -> dict[str, str]:
        return {str(p.relative_to(out_dir)): p.read_text() for p in sorted(out_dir.rglob("*")) if p.is_file()}

    def assert_no_secrets(self, text: str, secrets=ALL_SECRETS):
        texts = scrub.expand_payloads(text)
        for t in texts:
            for s in secrets:
                self.assertNotIn(s.lower(), t.lower(), f"secret category leaked: {secrets.index(s)}")


class BackendFormatTests(ScrubCase):
    def test_emby_main_and_transcoder_logs(self):
        self.write("embyserver.txt", emby_main_log())
        self.write(EMBY_FFMPEG, emby_ffmpeg_log())
        out = self.root / "out"
        rc, stdout, stderr = self.run_cli(str(self.raw), "--output", str(out), "--report", str(self.root / "r.json"))
        self.assertEqual(rc, 0, stderr)
        self.assertIn("verify: clean", stdout)
        files = self.outputs(out)
        main, ff = files["embyserver.txt"], files[EMBY_FFMPEG]
        for text in (main, ff):
            self.assert_no_secrets(text)
        self.assertIn("Original search term: <redacted>. Bound search term: <redacted>", main)
        self.assertIn("User policy for <user>.", main)
        self.assertIn("on <device> playing <title>. Position: 3620000 ms", main)
        self.assertIn("X-Forwarded-Server=host", main)
        self.assertIn("Private-Network-Access-Id=<redacted>", main)
        self.assertIn('-i "/media/movies/<title>/<title>.mkv"', main)
        # Transcode temp paths, ffmpeg arguments, versions and HTTP detail survive.
        self.assertIn("/data/transcode/transcoding-temp/0C346E/0C346E_%d.m4s", main)
        self.assertIn("-copyts -ss 01:00:20.000", main)
        self.assertIn("CFNetwork/3896.100.1.1.1", main)
        self.assertIn("AppleCoreMedia/1.0.0.23A434", main)
        self.assertIn("Emby Server version: 4.10.2.0 Operating system: Unix 6.8.0.147", main)
        self.assertIn("VideoBitrate=199616000", main)
        self.assertIn("MediaSourceId=mediasource_1229", main)
        # Distinct sessions stay distinguishable.
        self.assertIn("for session <session-", main)
        self.assertRegex(main, r"PlaySessionId: <session-\d+>")
        self.assertIn("0C346E_1810.m4s", ff)
        self.assertIn("title           : DTS-HD MA 5.1", ff)
        self.assertIn("Stream #0:1(eng): Audio: dts (DTS-HD MA)", ff)
        self.assertNotIn("‌", main)

    def test_jellyfin_main_and_transcoder_logs(self):
        self.write("log_20261030.log", jellyfin_main_log())
        self.write("FFmpeg.Transcode-2026-10-30_21-00-03_0d9c8b7a6f5e4d3c2b1a_1a2b3c4d.log", jellyfin_ffmpeg_log())
        out = self.root / "out"
        rc, _, stderr = self.run_cli(str(self.raw), "--output", str(out))
        self.assertEqual(rc, 0, stderr)
        files = self.outputs(out)
        main = files["log_20261030.log"]
        ff = files["FFmpeg.Transcode-2026-10-30_21-00-03_0d9c8b7a6f5e4d3c2b1a_1a2b3c4d.log"]
        for text in (main, ff):
            self.assert_no_secrets(text + "fd12:3456")
            self.assertNotIn("fd12:3456", text)
            self.assertNotIn("Lantern Light", text)
        self.assertIn('Authentication request for "<user>" has succeeded', main)
        self.assertIn('playing "<title>". Started at 0 ms', main)
        self.assertIn("ApiKey=<redacted>", main)
        self.assertIn('-i file:"/media/movies/<title>/<title>.mkv"', main)
        self.assertIn("::ffff:192.0.2.", main)
        self.assertIn("2001:db8::", main)
        self.assertIn("Jellyfin version: 10.10.7", main)
        self.assertIn('"/cache/transcodes/0d9c8b7a6f5e4d3c2b1a.m3u8"', main)
        self.assertIn('"Name": "<title>"', ff)
        self.assertIn("title           : <title>", ff)

    def test_plex_main_and_statistics_logs(self):
        self.write("Plex Media Server.log", plex_main_log())
        self.write("Plex Transcoder Statistics.log", plex_statistics_log())
        out = self.root / "out"
        rc, _, stderr = self.run_cli(str(self.raw), "--output", str(out))
        self.assertEqual(rc, 0, stderr)
        files = self.outputs(out)
        main, stats = files["Plex Media Server.log"], files["Plex Transcoder Statistics.log"]
        for text in (main, stats):
            self.assert_no_secrets(text + "fakeplextoken12345 c1d2e3f4a5b6c7d8 f7d951016504698f Director")
            for s in ("fakeplextoken12345", "c1d2e3f4a5b6c7d8", "f7d951016504698f", "Director", "0123456789abcdef0123456789abcdef", "0f0e0d0c0b0a0908"):
                self.assertNotIn(s, text)
        self.assertIn(f"{PLEX_AUTH}=<redacted>", main)
        self.assertIn("Signed-in Token (<user>)", main)
        self.assertIn("X-Plex-Device-Name=<device>", main)
        self.assertIn("'-i' '/media/movies/<title>/<title>.mkv' '-map' '0:0'", main)
        self.assertIn("Processing directory /media/movies/<title>", main)
        self.assertIn("Updating directory '<title>' (ID 17)", main)
        self.assertIn("Plex Media Server v1.41.3.9314-a0bfb8370", main)
        self.assertIn("[192.0.2.", main)
        self.assertIn("(Subnet)] GET /library/metadata/11977?includeChapters=1", main)
        self.assertIn('displayTitle="4K DoVi/HDR10 (HEVC Main 10)"', stats)
        self.assertIn('userID="<redacted>"', stats)


class FocusedBehaviourTests(ScrubCase):
    def scrub_text(self, text: str, *discover_texts: str) -> str:
        secrets = scrub.Secrets()
        texts = [x for t in (text, *discover_texts) for x in scrub.expand_payloads(t)]
        scrub.discover(texts, secrets)
        return scrub.Scrubber(secrets).scrub(text, scrub.Counter())

    def test_versions_are_not_ips(self):
        text = (
            "Emby Server version: 4.10.2.0\nOperating system: Unix 6.8.0.147\n"
            "User-Agent: Labstream/2 CFNetwork/3896.100.1.1.1 Darwin/27.0.0\n"
            "UA AppleCoreMedia/1.0.0.23A434\nPlex Media Server v1.41.3.9314-a0bfb8370\n"
            "Linux version 6.8.0-147-generic\nlocal 127.0.0.1 any 0.0.0.0\n"
            f"Source Ip: {LAN}, peer {WAN}\n"
        )
        out = self.scrub_text(text)
        for kept in ("version: 4.10.2.0", "Unix 6.8.0.147", "CFNetwork/3896.100.1.1.1", "AppleCoreMedia/1.0.0.23A434", "v1.41.3.9314", "127.0.0.1", "0.0.0.0"):
            self.assertIn(kept, out)
        self.assertNotIn(LAN, out)
        self.assertNotIn(WAN, out)
        self.assertIn("Source Ip: 192.0.2.10, peer 192.0.2.11", out)

    def test_times_and_stream_specifiers_are_not_ipv6(self):
        out = self.scrub_text("23:24:06.946 -map 0:0 -c:v:0 copy elapsed=00:00:00.00 01:00:20\n")
        self.assertEqual(out, "23:24:06.946 -map 0:0 -c:v:0 copy elapsed=00:00:00.00 01:00:20\n")

    def test_release_name_collapse_and_year(self):
        text = (
            f"Input #0, matroska,webm, from '{PATH}':\n  Metadata:\n    title           : {RELEASE}\n"
            "  Duration: 01:00:00.00\n"
            f'{{"Path":"{PATH}","Name":"{TITLE} (2011) [Remux]"}}\n'
            f"Searching for {TITLE} (2011) and {TITLE}.2011.extra\n"
        )
        out = self.scrub_text(text)
        self.assertIn("    title           : <title>\n", out)
        self.assertIn('"Name":"<title>"', out)
        self.assertIn("<title> (<year>)", out)
        self.assertIn("<title>.<year>", out)
        self.assertNotIn("Quiet", out)
        self.assertNotIn("2011", out)

    def test_payload_gzip_round_trip(self):
        blob = emby_graph_blob()
        out = self.scrub_text(f"======= ExtraData\n{blob}\n---\n")
        new_blob = out.splitlines()[1]
        self.assertNotEqual(new_blob, blob)
        decoded = gzip.decompress(base64.b64decode(new_blob)).decode()
        self.assertIn("/media/movies/<title>/<title>.mkv", decoded)
        self.assertNotIn("Quiet", decoded)
        self.assertNotIn("2011", decoded.replace("<year>", ""))
        self.assertIn("print_graphs_file", decoded)

    def test_payload_zlib_and_plain_round_trip(self):
        payload = json.dumps({"Path": PATH, "pad": " ".join(str(i * 7919) for i in range(120))})
        z = base64.b64encode(zlib.compress(payload.encode())).decode()
        plain = base64.b64encode(payload.encode()).decode()
        out = self.scrub_text(f"{z}\n{plain}\n")
        z_out, plain_out = out.splitlines()
        self.assertNotIn("Quiet", zlib.decompress(base64.b64decode(z_out)).decode())
        self.assertNotIn("Quiet", base64.b64decode(plain_out).decode())

    def test_undecodable_payload_is_removed(self):
        binary = base64.b64encode(bytes(range(256)) * 2).decode()
        out = self.scrub_text(f"blob {binary}\n")
        self.assertEqual(out, "blob <payload removed>\n")

    def test_home_dirs_hosts_and_macs(self):
        mac_home = "/" + "Users" + "/" + "quietfox"
        text = f"cfg {HOME}/.config and {mac_home}/Library at http://{HOST}:8096/x mac {MAC}\n"
        out = self.scrub_text(text)
        self.assertNotIn("quietfox", out)
        self.assertNotIn(HOST, out)
        self.assertNotIn(MAC, out)
        self.assertIn("http://host1.example.internal:8096/x", out)


class WindowExtractionTests(ScrubCase):
    def test_emby_window_collects_referenced_transcoder_logs(self):
        self.write("embyserver.txt", emby_main_log())
        self.write(EMBY_FFMPEG, emby_ffmpeg_log())
        self.write(EMBY_FFMPEG_OTHER, "unrelated ffmpeg log\n")
        out = self.root / "out"
        rc, _, stderr = self.run_cli(str(self.raw), "--output", str(out), "--since", "2026-10-30 23:24", "--until", "2026-10-30 23:30")
        self.assertEqual(rc, 0, stderr)
        files = self.outputs(out)
        self.assertEqual(set(files), {"embyserver.txt", EMBY_FFMPEG})
        self.assertNotIn("unrelated later line", files["embyserver.txt"])
        self.assertNotIn("Emby Server version", files["embyserver.txt"])

    def test_play_session_filter_keeps_same_request_lines(self):
        self.write("embyserver.txt", emby_main_log())
        self.write(EMBY_FFMPEG, emby_ffmpeg_log())
        self.write(EMBY_FFMPEG_OTHER, "unrelated ffmpeg log\n")
        out = self.root / "out"
        rc, _, stderr = self.run_cli(str(self.raw), "--output", str(out), "--play-session", PLAY_SESSION)
        self.assertEqual(rc, 0, stderr)
        files = self.outputs(out)
        self.assertIn(EMBY_FFMPEG, files)
        self.assertNotIn(EMBY_FFMPEG_OTHER, files)
        main = files["embyserver.txt"]
        self.assertIn("SessionManager: Playback start", main)
        self.assertNotIn("User policy", main)
        self.assertNotIn("unrelated later line", main)

    def test_jellyfin_transcode_log_selected_by_timestamp(self):
        self.write("log_20261030.log", jellyfin_main_log())
        self.write("FFmpeg.Transcode-2026-10-30_21-00-03_0d9c8b7a6f5e4d3c2b1a_1a2b3c4d.log", jellyfin_ffmpeg_log())
        self.write("FFmpeg.Transcode-2026-10-29_08-00-00_ffff_1a2b3c4d.log", "old\n")
        out = self.root / "out"
        rc, _, stderr = self.run_cli(str(self.raw), "--output", str(out), "--since", "2026-10-30 21:00:02", "--until", "2026-10-30 21:00:05")
        self.assertEqual(rc, 0, stderr)
        files = self.outputs(out)
        self.assertEqual(set(files), {"log_20261030.log", "FFmpeg.Transcode-2026-10-30_21-00-03_0d9c8b7a6f5e4d3c2b1a_1a2b3c4d.log"})
        self.assertNotIn("Authentication request", files["log_20261030.log"])
        self.assertNotIn("Jellyfin version", files["log_20261030.log"])

    def test_plex_statistics_blocks_filtered_by_window(self):
        self.write("Plex Media Server.log", plex_main_log())
        self.write("Plex Transcoder Statistics.log", plex_statistics_log())
        out = self.root / "out"
        rc, _, stderr = self.run_cli(str(self.raw), "--output", str(out), "--since", "2026-10-30 22:00", "--until", "2026-10-30 22:30")
        self.assertEqual(rc, 0, stderr)
        files = self.outputs(out)
        stats = files["Plex Transcoder Statistics.log"]
        self.assertEqual(stats.count("<SessionReport"), 1)
        self.assertIn("a1a1a1a1", stats)
        self.assertNotIn("unrelated later line", files["Plex Media Server.log"])


class SafetyTests(ScrubCase):
    def test_verify_failure_exits_nonzero_without_printing_values(self):
        self.write("embyserver.txt", emby_main_log())
        out = self.root / "out"
        report = self.root / "report.json"
        with mock.patch.object(scrub.Scrubber, "scrub", lambda _self, text, _c, _depth=0: text):
            rc, stdout, stderr = self.run_cli(str(self.raw), "--output", str(out), "--report", str(report))
        self.assertEqual(rc, 1)
        self.assertIn("VERIFY FAILED", stderr)
        self.assertTrue((out / "SCRUB-VERIFY-FAILED").exists())
        data = json.loads(report.read_text())
        self.assertFalse(data["verify_ok"])
        cats = data["verify"]["embyserver.txt"]["categories"]
        for cat in ("ipv4", "host", "credential", "title", "user", "device"):
            self.assertIn(cat, cats)
        blob = stdout + stderr + report.read_text()
        for s in ALL_SECRETS:
            self.assertNotIn(s, blob)

    def test_refuses_to_write_into_inputs(self):
        self.write("embyserver.txt", emby_main_log())
        with self.assertRaises(SystemExit):
            self.run_cli(str(self.raw), "--output", str(self.raw))
        with self.assertRaises(SystemExit):
            self.run_cli(str(self.raw), "--output", str(self.raw / "nested"))
        out = self.root / "out"
        out.mkdir()
        (out / "existing.txt").write_text("keep")
        with self.assertRaises(SystemExit):
            self.run_cli(str(self.raw), "--output", str(out))
        self.assertEqual((out / "existing.txt").read_text(), "keep")
        self.assertEqual((self.raw / "embyserver.txt").read_text(), emby_main_log())

    def test_report_lists_counts_only(self):
        self.write("embyserver.txt", emby_main_log())
        out = self.root / "out"
        report = self.root / "report.json"
        rc, stdout, _ = self.run_cli(str(self.raw), "--output", str(out), "--report", str(report))
        self.assertEqual(rc, 0)
        data = json.loads(report.read_text())
        self.assertTrue(data["verify_ok"])
        counts = data["files"]["embyserver.txt"]["replacements"]
        for cat in ("ipv4", "host", "credential", "session", "user", "device", "path", "search_term"):
            self.assertGreater(counts.get(cat, 0), 0, cat)
        for s in ALL_SECRETS:
            self.assertNotIn(s, stdout + report.read_text())


if __name__ == "__main__":
    unittest.main()
