import importlib.util
import pathlib
import sys
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "perf-log-summary.py"
spec = importlib.util.spec_from_file_location("perf_log_summary", SCRIPT)
perf = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = perf
spec.loader.exec_module(perf)


class PerfLogSummaryTests(unittest.TestCase):
    def test_parse_plain_text_span(self):
        span = perf.parse_span_line(
            "2026-06-19 perf.span phase=home.load backend=Plex result=success duration_ms=123 hub_count=4"
        )
        self.assertEqual(span.phase, "home.load")
        self.assertEqual(span.backend, "Plex")
        self.assertEqual(span.duration_ms, 123)
        self.assertEqual(span.fields["hub_count"], "4")

    def test_parse_json_event_message(self):
        span = perf.parse_span_line(
            '{"eventMessage":"perf.span phase=playback.startup backend=Jellyfin result=success duration_ms=2500 path_mode=remote_stream"}'
        )
        self.assertEqual(span.phase, "playback.startup")
        self.assertEqual(span.backend, "Jellyfin")
        self.assertEqual(span.fields["path_mode"], "remote_stream")

    def test_summarize_groups_and_failures(self):
        spans = perf.parse_spans([
            "perf.span phase=home.load backend=Plex result=success duration_ms=100",
            "perf.span phase=home.load backend=Plex result=failure duration_ms=300",
            "perf.span phase=home.load backend=Jellyfin result=success duration_ms=200",
        ])
        rows = perf.summarize(spans)
        plex = next(row for row in rows if row["backend"] == "Plex")
        self.assertEqual(plex["count"], 2)
        self.assertEqual(plex["failures"], 1)
        self.assertEqual(plex["p50_ms"], 200)

    def test_summarize_can_group_by_span_fields(self):
        spans = perf.parse_spans([
            "perf.span phase=artwork.load backend=Plex result=success duration_ms=40 width=184 height=276",
            "perf.span phase=artwork.load backend=Plex result=success duration_ms=60 width=184 height=276",
            "perf.span phase=artwork.load backend=Plex result=success duration_ms=20 width=252 height=141",
        ])
        rows = perf.summarize(spans, group_fields=["width", "height"])
        tall = next(row for row in rows if row["group"] == "width=184,height=276")
        wide = next(row for row in rows if row["group"] == "width=252,height=141")
        self.assertEqual(tall["count"], 2)
        self.assertEqual(tall["p50_ms"], 50)
        self.assertEqual(wide["count"], 1)


if __name__ == "__main__":
    unittest.main()
