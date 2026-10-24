#!/usr/bin/env python3
"""Tests for the judges' own logic: probe/judge_gopher.py and probe/judge_clock.py.

The judges decide what counts as "the same answer", and they have been wrong in
ways that passed: a Unix-time normalizer that could not see the Eastern
wall-clock text the session pages render, so the story passed only when both
servers ran in the same minute; and a raw-socket helper that crashed on a
refused connection instead of reporting it. A judge that is wrong is a gate
that lies, so its rules are tested here, on the host, before any kernel boots.

    python3 probe/test_judges.py
"""
import http.server
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import ast
import textwrap
import inspect
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import judge_gopher as G  # noqa: E402
import judge_ladder as L  # noqa: E402


class Normalize(unittest.TestCase):
    W = (1789600000, 1789600090)

    def test_a_unix_time_inside_the_window_is_now(self):
        self.assertEqual(G.normalize(b"created_at: 1789600050\n", self.W), b"created_at: <NOW>\n")

    def test_a_unix_time_outside_the_window_is_left_alone(self):
        # This is what makes a wrong kernel clock a DIFFERENCE.
        for t in (1789599000, 1789603650, 1758000000):
            with self.subTest(t=t):
                data = f"created_at: {t}\n".encode()
                self.assertEqual(G.normalize(data, self.W), data)

    def test_the_window_edges_are_inclusive(self):
        self.assertEqual(G.normalize(b"1789600000 1789600090", self.W), b"<NOW> <NOW>")

    def test_a_number_that_is_not_a_time_is_left_alone(self):
        for data in (b"session_id: 1789600050123", b"x21789600050", b"size 26751"):
            with self.subTest(data=data):
                self.assertEqual(G.normalize(data, self.W), data)

    def test_eastern_text_inside_the_window_is_now(self):
        text = G.eastern(1789600065)
        self.assertEqual(G.normalize(b"<td>" + text + b"</td>", self.W), b"<td><NOW-EASTERN></td>")

    def test_eastern_text_in_the_last_minute_the_window_touches(self):
        # Mid-minute: that minute's text still counts.
        w = (1789600000, 1789600110)
        self.assertEqual(G.normalize(G.eastern(1789600105), w), b"<NOW-EASTERN>")
        # And the edge an off-by-one misses: a window that ends EXACTLY on a
        # minute, with the request stamped in that very second.
        assert 1789600020 % 60 == 0
        w = (1789600000, 1789600020)
        self.assertEqual(G.normalize(G.eastern(1789600020), w), b"<NOW-EASTERN>")

    def test_eastern_text_outside_the_window_is_left_alone(self):
        staged = G.eastern(1758000000)
        self.assertEqual(G.normalize(staged, self.W), staged)
        an_hour_off = G.eastern(1789600050 + 3600)
        self.assertEqual(G.normalize(an_hour_off, self.W), an_hour_off)

    def test_a_codex_chat_stamp_in_a_minute_the_window_touches_is_now(self):
        # The window runs 23:06:40 to 23:08:10 UTC.
        for hhmm in (b"23:06", b"23:08"):
            with self.subTest(hhmm=hhmm):
                self.assertEqual(G.normalize(b'{"time-0":"' + hhmm + b'"}', self.W), b'{"time-0":"<NOW-HHMM>"}')
        self.assertEqual(G.normalize(b'{"id":1,"time":"23:07"}', self.W), b'{"id":1,"time":"<NOW-HHMM>"}')

    def test_a_codex_chat_stamp_outside_the_window_is_left_alone(self):
        for data in (b'{"time-0":"23:09"}', b'{"time":"22:07"}', b'{"other":"23:07"}'):
            with self.subTest(data=data):
                self.assertEqual(G.normalize(data, self.W), data)

    def test_a_codex_chat_token_is_named_for_its_holder(self):
        tokens = {"ann": "5a05516c60cef1f8"}
        data = b'{"name":"ann","token":"5a05516c60cef1f8"}'
        self.assertEqual(G.normalize(data, self.W, tokens), b'{"name":"ann","token":"<TOKEN ann>"}')
        self.assertEqual(G.normalize(data, self.W), data)


class MoreNormalize(unittest.TestCase):
    W = (1789600000, 1789600090)

    def test_rfc3339_inside_the_window_is_now(self):
        # 1789600050 is 2026-09-16T23:07:30Z.
        self.assertEqual(G.normalize(b"at 2026-09-16T23:07:30Z.", self.W), b"at <NOW-RFC3339>.")

    def test_rfc3339_outside_the_window_is_left_alone(self):
        data = b"at 2026-09-16T22:07:30Z and 2025-09-16T05:20:00Z"
        self.assertEqual(G.normalize(data, self.W), data)

    def test_a_session_minted_in_the_window_loses_its_time_and_mac(self):
        cookie = G.mint_session("1", 1789600050).encode()
        self.assertEqual(G.normalize(cookie, self.W), b"__Host-gopher_auth=MQ.<NOW>.<MAC>")

    def test_a_session_minted_outside_the_window_keeps_both(self):
        cookie = G.mint_session("1", 1758000000).encode()
        self.assertEqual(G.normalize(cookie, self.W), cookie)


class Sessions(unittest.TestCase):
    def test_the_minted_format_is_signsessions(self):
        # Checked once against users.signSession itself, for this secret.
        self.assertEqual(G.mint_session("1", 1789600000),
                         "__Host-gopher_auth=MQ.1789600000.b89_jCbiAAoR-wSNNVBb2hogDPNxtibiP_8VnsWvtUs")

    def test_a_forgery_claims_one_id_with_anothers_mac(self):
        real2 = G.mint_session("2", 1789600000)
        forged = G.forge_session("1", "2", 1789600000)
        self.assertTrue(forged.startswith("__Host-gopher_auth=MQ."))
        self.assertEqual(forged.split(".", 1)[1], real2.split(".", 1)[1])
        self.assertNotEqual(forged, G.mint_session("1", 1789600000))


class Jar(unittest.TestCase):
    def test_every_cookie_is_kept(self):
        a = {"headers": {"set-cookie": "gopher_uid=1; Path=/\ngopher_auth=MQ.1.x; Path=/"}}
        self.assertEqual(G.update_jar(a, {}), {"gopher_uid": "1", "gopher_auth": "MQ.1.x"})

    def test_max_age_zero_removes(self):
        a = {"headers": {"set-cookie": "gopher_uid=; Path=/; Max-Age=0\ngopher_auth=; Path=/; Max-Age=0"}}
        self.assertEqual(G.update_jar(a, {"gopher_uid": "1", "gopher_auth": "x", "other": "y"}), {"other": "y"})

    def test_the_jar_becomes_one_cookie_header(self):
        s = G.step("x", "GET", "/", G.JAR)
        c = G.with_jar(s, {"gopher_uid": "1", "gopher_auth": "MQ.1.x"})["cookie"]
        self.assertEqual(c, "gopher_uid=1; gopher_auth=MQ.1.x")
        self.assertIsNone(G.with_jar(s, {})["cookie"])

    def test_minted_placeholders_resolve_on_both_sides(self):
        s = G.step("x", "GET", "/", G.FRESH)
        self.assertEqual(G.with_jar(s, {}, {G.FRESH: "gopher_auth=abc"})["cookie"], "gopher_auth=abc")


class Eastern(unittest.TestCase):
    """judge_gopher restates angry-gopher's formatEastern with zoneinfo. These
    are the cases that format has to get right. Each expected string was worked
    out by hand from a UTC time whose Unix value calendar.timegm confirms —
    EDT is UTC-4, EST is UTC-5, and in 2026 the change is on 8 March."""

    def test_daylight_time(self):
        self.assertEqual(G.eastern(1758000000), "Sep 16, 2025 · 1:20 AM EDT".encode())

    def test_standard_time(self):
        # 2026-01-15 17:00 UTC is noon in New York, in winter.
        self.assertEqual(G.eastern(1768496400), "Jan 15, 2026 · 12:00 PM EST".encode())

    def test_midnight_is_twelve_am(self):
        # 2026-01-15 05:00 UTC is midnight EST.
        self.assertEqual(G.eastern(1768453200), "Jan 15, 2026 · 12:00 AM EST".encode())

    def test_the_spring_change(self):
        # 2026-03-08: 06:59 UTC is 1:59 AM EST; 07:00 UTC is 3:00 AM EDT.
        self.assertEqual(G.eastern(1772953140), "Mar 8, 2026 · 1:59 AM EST".encode())
        self.assertEqual(G.eastern(1772953200), "Mar 8, 2026 · 3:00 AM EDT".encode())


class Cookies(unittest.TestCase):
    def test_a_set_cookie_replaces_the_jar(self):
        a = {"headers": {"set-cookie": "__Host-gopher_uid=p1; Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax"}}
        self.assertEqual(G.cookie_from(a, None), "__Host-gopher_uid=p1")
        self.assertEqual(G.cookie_from(a, "gopher_uid=9"), "__Host-gopher_uid=p1")

    def test_a_legacy_one_cleared_beside_the_new_is_not_kept(self):
        # The move of a legacy cookie (angry-gopher, metal-vmm QUEUE 170.8):
        # the new one set, the legacy one cleared, in either order.
        for sc in ("__Host-gopher_uid=p1.1.m; Path=/\ngopher_uid=; Path=/; Max-Age=0",
                   "gopher_uid=; Path=/; Max-Age=0\n__Host-gopher_uid=p1.1.m; Path=/"):
            self.assertEqual(G.cookie_from({"headers": {"set-cookie": sc}}, "gopher_uid=p1"), "__Host-gopher_uid=p1.1.m")

    def test_a_signed_uid_is_kept_whole(self):
        a = {"headers": {"set-cookie": "__Host-gopher_uid=p1.1790000000.ab-c_d; Path=/; HttpOnly"}}
        self.assertEqual(G.cookie_from(a, None), "__Host-gopher_uid=p1.1790000000.ab-c_d")

    def test_mint_uid_is_uid_cookie_zigs_format(self):
        # uid_cookie.zig's frozen vector: the judge's mint and the server's
        # sign must agree, or every minted cookie would be refused alike.
        self.assertEqual(G.mint_uid("p3", 1790000000, b"a secret of thirty-two bytes or more, for tests"),
                         "__Host-gopher_uid=p3.1790000000.BTTIGQI3slTgQ_iFwX0DSWx8EhfbUkaIsSuUFfQayP4")

    def test_a_signed_uid_normalizes_like_a_session(self):
        w = (1790000000, 1790000001)
        one = G.normalize(G.mint_uid("p1", 1790000000).encode(), w)
        two = G.normalize(G.mint_uid("p1", 1790000001).encode(), w)
        self.assertEqual(one, two)
        self.assertEqual(one, b"__Host-gopher_uid=p1.<NOW>.<MAC>")

    def test_no_set_cookie_keeps_the_jar(self):
        self.assertEqual(G.cookie_from({"headers": {}}, "gopher_uid=p2"), "gopher_uid=p2")
        self.assertIsNone(G.cookie_from({"error": "refused"}, None))

    def test_a_different_cookie_is_not_the_identity(self):
        a = {"headers": {"set-cookie": "__Host-gopher_auth=abc; Path=/"}}
        self.assertEqual(G.cookie_from(a, "gopher_uid=p1"), "gopher_uid=p1")

    def test_with_jar_only_touches_the_placeholder(self):
        s = G.step("x", "GET", "/", G.JAR)
        self.assertEqual(G.with_jar(s, "gopher_uid=p1")["cookie"], "gopher_uid=p1")
        fixed = G.step("x", "GET", "/", G.P1)
        self.assertIs(G.with_jar(fixed, "gopher_uid=p1"), fixed)


class Differences(unittest.TestCase):
    def answer(self, **kw):
        base = {"status": 200, "headers": {"content-type": "text/html"}, "body": b"hi",
                "guest_exit": 1, "window": (0, 0), "serial": ""}
        base.update(kw)
        return base

    def test_equal_answers_agree(self):
        c = G.case("x", "GET", "/")
        self.assertEqual(G.differences(c, self.answer(), self.answer()), [])

    def test_each_kind_of_difference_is_reported(self):
        c = G.case("x", "GET", "/")
        cases = [
            (dict(status=404), "status"),
            (dict(headers={"content-type": "text/plain"}), "content-type"),
            (dict(headers={"content-type": "text/html", "location": "/play"}), "location"),
            (dict(body=b"ho"), "body differs"),
            (dict(guest_exit=3, serial="FAIL: x"), "the guest exited 3"),
        ]
        for change, want in cases:
            with self.subTest(want=want):
                diffs = G.differences(c, self.answer(**change), self.answer())
                self.assertTrue(any(want in d for d in diffs), diffs)

    def test_a_server_that_did_not_answer_is_named(self):
        c = G.case("x", "GET", "/")
        self.assertIn("kernel", G.differences(c, {"error": "x"}, self.answer())[0])
        self.assertIn("LINUX", G.differences(c, self.answer(), {"error": "x"})[0])

    def test_the_first_difference_is_located(self):
        self.assertIn("byte 3", G.first_difference(b"abcdef", b"abcXef"))
        self.assertIn("byte 3", G.first_difference(b"abc", b"abcdef"))

    def test_version_is_compared_field_by_field(self):
        saved = G.EXPECTED_COMMIT
        G.EXPECTED_COMMIT = "be16d282"
        try:
            m = b'{"result":"success","version":"0.1-zig","commit":"be16d282","rejects":{},"mem":{"live_bytes":1}}'
            l = b'{"result":"success","version":"0.1-zig","commit":"dev","rejects":{},"mem":{"live_bytes":9}}'
            self.assertEqual(G.version_differences(m, l), [])
            # Metal must name the checkout it was built from, not whatever it likes.
            wrong = m.replace(b"be16d282", b"dev")
            self.assertTrue(G.version_differences(wrong, l))
            self.assertTrue(G.version_differences(m, l.replace(b'"rejects":{}', b'"rejects":{"x":1}')))
        finally:
            G.EXPECTED_COMMIT = saved

    def test_the_host_page_is_compared_by_shape(self):
        app = b"<h2>The application</h2><table><tr><td>version</td><td>0.1</td></tr></table><h2>The host</h2>"
        # A whole volume row, as metalFacts writes one: the judge now reads
        # the free-space figure (REVIEW-admin-host.md finding 1).
        m = app + (b"<tr><td>host</td><td>zig-metal-unikernel, with no operating system</td></tr>"
                   b"<tr><td>the boot disk (the site)</td><td>FAT16, serial 92DE-8831: 30 MB free of 62 MB</td></tr>"
                   + self.METAL_LOG)
        l = app + b"<tr><td>host</td><td>Linux, zig-server, pid 7</td></tr>" + self.LINUX_LOG
        self.assertEqual(G.host_page_differences(m, l), [])
        self.assertTrue(G.host_page_differences(l, l))
        self.assertTrue(G.host_page_differences(m.replace(b"<h2>The host</h2>", b""), l))
        extra = app.replace(b"</table>", b"<tr><td>commit</td><td>x</td></tr></table>")
        self.assertTrue(G.host_page_differences(extra + m[len(app):], l))

    HOST_APP = b"<h2>The application</h2><table><tr><td>version</td><td>0.1</td></tr></table><h2>The host</h2>"
    METAL_LOG = b'<h2>The log</h2>\n<p class="muted">The newest 60 lines.</p>\n<pre class="log">  disk check, the boot disk: 3 files\n  GET /chat 200</pre>\n'
    LINUX_LOG = b'<h2>The log</h2>\n<p class="muted">This host keeps no log of its own to show here.</p>\n'
    LINUX = HOST_APP + b"<table><tr><td>host</td><td>Linux, zig-server, pid 7</td></tr></table>" + LINUX_LOG

    def metal_page(self, *rows, log=None):
        cells = b"".join(b"<tr><td>%s</td><td>%s</td></tr>" % r for r in rows)
        return (self.HOST_APP + b"<table><tr><td>host</td><td>zig-metal-unikernel, with no operating system</td></tr>" + cells
                + b"</table>" + (self.METAL_LOG if log is None else log))

    def test_the_log_section_is_checked_for_its_shape_and_for_secrets(self):
        good = (b"the boot disk (the site)", b"FAT16, serial 92DE-8831: 30 MB free of 62 MB")
        self.assertEqual(G.host_page_differences(self.metal_page(good), self.LINUX), [])
        # Missing on either host, or empty on metal.
        self.assertTrue(G.host_page_differences(self.metal_page(good, log=b""), self.LINUX))
        self.assertTrue(G.host_page_differences(self.metal_page(good), self.LINUX.replace(self.LINUX_LOG, b"")))
        empty = b'<h2>The log</h2>\n<pre class="log">  \n</pre>'
        self.assertTrue(G.host_page_differences(self.metal_page(good, log=empty), self.LINUX))
        # A secret the ring should have taken out.
        for leak in (b"cookie: gopher_auth=MQ.1758000000.abc", b"hash $2a$10$abcdefghijk"):
            log = b'<h2>The log</h2>\n<pre class="log">GET /chat\n' + leak + b"</pre>"
            got = G.host_page_differences(self.metal_page(good, log=log), self.LINUX)
            self.assertTrue(any("cookie or a password hash" in g for g in got), got)
        # Linux may show a log too, once it keeps one.
        self.assertEqual(G.host_page_differences(self.metal_page(good), self.LINUX.replace(self.LINUX_LOG, self.METAL_LOG)), [])

    # **THE TEXT VIEW** (metal-vmm QUEUE 189.3, 189.7): /admin/log.
    LOG_HEAD = (b"# The host's log, for agents (metal-vmm QUEUE 189.3): lines beginning \"# \" are\n"
                b"# this header; the rest is the log as written, its secrets taken out then.\n"
                b"# the application: commit abc\n# requests since boot: 9 requests: 9 2xx\n")
    METAL_VIEW = (LOG_HEAD + b"# the host: commit def\n# this boot: 400 bytes in 4 lines held, of 1310720 kept at most; 0 written before them and no longer held; the oldest timed line 2026-10-13T14:01:59.900Z; 3 lines below\n"
                  b"  2026-10-13T14:01:59.900Z request 11: GET /chat -> ok, 200 in 3.0 ms (base: 1)\n"
                  b"  2026-10-13T14:02:07.123Z request 12: POST /chat/c/1_2/general/send -> ok, 200 in 4.1 ms (base: 2)\n"
                  b"    body: 37 bytes, arrived in 0 ms\n")
    LINUX_VIEW = LOG_HEAD + b"# This host keeps no log of its own to show here.\n"

    def test_the_log_view_is_checked_for_its_shape_its_filter_and_secrets(self):
        ok = lambda body: {"status": 200, "headers": {"content-type": "text/plain; charset=utf-8"}, "body": body}
        whole = {"path": "/admin/log"}
        chat = {"path": "/admin/log?path=/chat&boot=this"}
        self.assertEqual(G.log_view_differences(whole, ok(self.METAL_VIEW), ok(self.LINUX_VIEW)), [])
        self.assertEqual(G.log_view_differences(chat, ok(self.METAL_VIEW), ok(self.LINUX_VIEW)), [])
        # Not text, or without its header, on either host.
        html = {"status": 200, "headers": {"content-type": "text/html"}, "body": self.METAL_VIEW}
        self.assertTrue(G.log_view_differences(whole, html, ok(self.LINUX_VIEW)))
        self.assertTrue(G.log_view_differences(whole, ok(self.METAL_VIEW[len(self.LOG_HEAD):]), ok(self.LINUX_VIEW)))
        # Metal holding no lines of this boot; Linux claiming a log it has not.
        self.assertTrue(G.log_view_differences(whole, ok(self.LOG_HEAD), ok(self.LINUX_VIEW)))
        self.assertTrue(G.log_view_differences(whole, ok(self.METAL_VIEW), ok(self.LOG_HEAD)))
        # A filter by path that let another path through.
        stray = self.METAL_VIEW + b"  2026-10-13T14:03:00.000Z request 13: GET /admin/host -> ok, 200 in 9.1 ms (base: 3)\n"
        got = G.log_view_differences(chat, ok(stray), ok(self.LINUX_VIEW))
        self.assertTrue(any("/admin/host" in g for g in got), got)
        # Every secret the story sends, and every message's words.
        for leak in (b"cookie: __Host-gopher_auth=MQ.1758000000.abc", b"hash $2b$12$abcdefghijk", b"password=hunter2",
                     b"correct horse battery staple", G.SESSION_SECRET, b"text: hello from bare metal"):
            got = G.log_view_differences(whole, ok(self.METAL_VIEW + b"  " + leak + b"\n"), ok(self.LINUX_VIEW))
            self.assertTrue(any("secret" in g or "message" in g for g in got), (leak, got))

    def test_the_host_page_s_disk_figures_must_be_sane(self):
        good = (b"the boot disk (the site)", b"FAT16, serial 92DE-8831: 30 MB free of 62 MB")
        self.assertEqual(G.host_page_differences(self.metal_page(good), self.LINUX), [])
        unreadable = (b"the volume (chat&#39;s data)", b"FAT16, serial 1234-5678: free space unreadable (ReadFailed)")
        self.assertTrue(G.host_page_differences(self.metal_page(good, unreadable), self.LINUX))
        more_free_than_all = (b"the boot disk (the site)", b"FAT16, serial 92DE-8831: 70 MB free of 62 MB")
        self.assertTrue(G.host_page_differences(self.metal_page(more_free_than_all), self.LINUX))
        empty = (b"the boot disk (the site)", b"FAT16, serial 92DE-8831: 0 MB free of 0 MB")
        self.assertTrue(G.host_page_differences(self.metal_page(empty), self.LINUX))
        # No figure at all is a failure too, though the serial is named.
        self.assertTrue(G.host_page_differences(self.metal_page((b"x", b"serial 92DE-8831")), self.LINUX))

    def test_a_failed_host_report_is_named_as_one(self):
        failed = self.metal_page((b"the host&#39;s report", b"OutOfMemory"),
                                 (b"the boot disk (the site)", b"FAT16, serial 92DE-8831: 30 MB free of 62 MB"))
        got = G.host_page_differences(failed, self.LINUX)
        self.assertTrue(any("report failed: OutOfMemory" in d for d in got), got)

    @unittest.skipUnless(shutil.which("mkfs.vfat"), "needs mkfs.vfat (dosfstools) to make a volume")
    def test_the_boot_disk_s_figures_are_checked_against_the_oracle(self):
        with tempfile.TemporaryDirectory() as d:
            img = os.path.join(d, "v.img")
            subprocess.run(["mkfs.vfat", "-F", "16", "-S", "512", "-s", "4", "-C", img, str(64 * 1024)],
                           check=True, capture_output=True)
            sys.path.insert(0, G.TOOLS_DIR)
            import fat16_read
            with open(img, "rb") as f:
                v = fat16_read.Volume(f.read())
            total = ((v.max_cluster - 1) * v.cluster_bytes) >> 20
            free = (sum(1 for c in range(2, v.max_cluster + 1) if v.fat(c) == 0) * v.cluster_bytes) >> 20
            row = lambda f, t: (b"the boot disk (the site)", b"FAT16, serial 92DE-8831: %d MB free of %d MB" % (f, t))
            self.assertEqual(G.host_page_differences(self.metal_page(row(free, total)), self.LINUX, img), [])
            self.assertEqual(G.host_page_differences(self.metal_page(row(free - 2, total)), self.LINUX, img), [])
            self.assertTrue(G.host_page_differences(self.metal_page(row(free - 3, total)), self.LINUX, img))
            self.assertTrue(G.host_page_differences(self.metal_page(row(free, total - 1)), self.LINUX, img))

    @unittest.skipUnless(shutil.which("mkfs.vfat") and shutil.which("sgdisk"), "needs mkfs.vfat and sgdisk")
    def test_on_the_droplet_machine_each_row_is_checked_against_its_own_disk(self):
        # There the judge's image is chat's data volume, and the boot disk is
        # the site, on partition 2 of the disk the kernel booted from. Sizes
        # that differ, so a row read against the wrong disk is caught.
        with tempfile.TemporaryDirectory() as d:
            volume = os.path.join(d, "v.img")
            subprocess.run(["mkfs.vfat", "-F", "16", "-S", "512", "-s", "4", "-C", volume, str(64 * 1024)],
                           check=True, capture_output=True)
            boot = os.path.join(d, "droplet.img")
            with open(boot, "wb") as f:
                f.truncate(40 << 20)
            subprocess.run(["sgdisk", "-o", "-n", "1:2048:4095", "-n", "2:4096:0", boot],
                           check=True, capture_output=True)
            base = G.gpt_partition_base(boot, 2)
            self.assertEqual(base, 4096 * 512)
            blocks = ((40 << 20) - base - 34 * 512) // 1024
            subprocess.run(["mkfs.vfat", "-F", "16", "-S", "512", "--offset", "4096", boot, str(blocks)],
                           check=True, capture_output=True)
            site_free, site_total = G.oracle_megabytes(boot, base)
            vol_free, vol_total = G.oracle_megabytes(volume)
            self.assertNotEqual(site_total, vol_total)
            site = lambda f, t: (b"the boot disk (the site)", b"FAT16, serial 92DE-8831: %d MB free of %d MB" % (f, t))
            vol = lambda f, t: (b"the volume (chat&#39;s data)", b"FAT16, serial 1234-5678: %d MB free of %d MB" % (f, t))
            ok = self.metal_page(site(site_free, site_total), vol(vol_free, vol_total))
            self.assertEqual(G.host_page_differences(ok, self.LINUX, volume, boot), [])
            swapped = self.metal_page(site(vol_free, vol_total), vol(site_free, site_total))
            got = G.host_page_differences(swapped, self.LINUX, volume, boot)
            self.assertTrue(any(g.startswith("/admin/host on metal: the boot disk is") for g in got), got)
            self.assertTrue(any(g.startswith("/admin/host on metal: the volume is") for g in got), got)
            # The failure the droplet judge reported: the site's row against
            # the volume, as on microvm.
            self.assertTrue(G.host_page_differences(ok, self.LINUX, volume))
            no_volume = self.metal_page(site(site_free, site_total))
            got = G.host_page_differences(no_volume, self.LINUX, volume, boot)
            self.assertTrue(any("no free space for the volume" in g for g in got), got)

    def test_the_checkout_commit_reads_as_build_zig_writes_it(self):
        here = os.path.dirname(os.path.abspath(__file__))
        got = G.checkout_commit(here)
        self.assertRegex(got, r"^[0-9a-f]{7,}(\+dirty)?$")
        self.assertEqual(G.checkout_commit("/nonexistent"), "unknown")


class Download(unittest.TestCase):
    """A topic's download (QUEUE B27): compared by members, and each bundle
    must hold the transcript and the reactions under their whole names."""
    TOPIC = G.LONG_TOPIC
    PATH = f"/chat/c/1_2/{G.LONG_TOPIC}/download"

    def bundle(self, files, mtime):
        import gzip
        import io
        import tarfile
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as t:
            for name, data in files.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mtime = mtime
                t.addfile(info, io.BytesIO(data))
        return gzip.compress(buf.getvalue())

    def whole(self):
        return {f"{self.TOPIC}/{self.TOPIC}.md": b"a transcript", f"{self.TOPIC}/{self.TOPIC}.reactions.jsonl": b"{}"}

    def test_the_same_members_at_other_times_agree(self):
        self.assertEqual(G.download_differences(self.PATH, self.bundle(self.whole(), 100), self.bundle(self.whole(), 999)), [])

    def test_names_cut_to_one_are_a_difference_even_when_both_hosts_cut_them(self):
        cut = {f"{self.TOPIC}/{self.TOPIC}.md"[:100]: b"{}"}
        got = G.download_differences(self.PATH, self.bundle(cut, 100), self.bundle(cut, 100))
        self.assertTrue(any("has no" in g for g in got), got)

    def test_a_member_that_differs_is_named(self):
        other = dict(self.whole())
        other[f"{self.TOPIC}/{self.TOPIC}.md"] = b"another transcript"
        got = G.download_differences(self.PATH, self.bundle(self.whole(), 1), self.bundle(other, 1))
        self.assertTrue(any("differs" in g for g in got), got)

    def test_not_a_bundle_is_said_so(self):
        got = G.download_differences(self.PATH, b"not gzip", self.bundle(self.whole(), 1))
        self.assertTrue(any("not a whole .tar.gz" in g for g in got), got)


class Backup(unittest.TestCase):
    @staticmethod
    def tar(files, mtime=0, manifest=True):
        """An archive as /admin/backup writes one: the members, then (from
        QUEUE.md item 57) the manifest of every file."""
        import hashlib
        import io
        import tarfile
        buf = io.BytesIO()
        lines, total, n = [], 0, 0
        with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as t:
            for name, data in files.items():
                if data is None:
                    info = tarfile.TarInfo(name)
                    info.type = tarfile.DIRTYPE
                    info.mtime = mtime
                    t.addfile(info)
                    continue
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mtime = mtime
                t.addfile(info, io.BytesIO(data))
                lines.append(f"{hashlib.sha256(data).hexdigest()} {len(data)} {name}")
                total, n = total + len(data), n + 1
            if manifest:
                text = "".join(f"{x}\n" for x in (["gopher-backup manifest 1"] if n else []) + lines
                               + [f"end: {n} files, {total} bytes"]).encode()
                info = tarfile.TarInfo("backup-manifest.txt")
                info.size = len(text)
                t.addfile(info, io.BytesIO(text))
        return buf.getvalue()

    def test_an_archive_cut_short_or_without_its_manifest_is_not_whole(self):
        import tarfile
        import io
        base = {"data": None, "data/a": b"one", "data/b": b"two"}
        whole = self.tar(base)
        last = tarfile.open(fileobj=io.BytesIO(whole)).getmembers()[-1].offset
        for name, broken in (("cut", whole[:last]), ("old", self.tar(base, manifest=False))):
            got = G.backup_differences(whole, broken)
            self.assertTrue(any("on Linux is not whole" in g for g in got), (name, got))

    def test_two_archives_of_the_same_data_agree_though_their_times_differ(self):
        # Each host wrote the message at its own time, inside its own window.
        metal = {"data": None, "data/chat/1_2/sessions/general.md": b"date: 2025-09-16T05:20:01Z\n\nhi",
                 "auth/1/name": b"Steve"}
        linux = dict(metal, **{"data/chat/1_2/sessions/general.md": b"date: 2025-09-16T05:21:41Z\n\nhi"})
        mw, lw = (1757999990, 1758000010), (1758000090, 1758000110)
        self.assertEqual(G.backup_differences(self.tar(metal, 100), self.tar(linux, 999), mw, lw), [])

    def test_a_missing_member_a_size_and_a_content_are_each_named(self):
        base = {"data": None, "data/a": b"one", "data/b": b"two"}
        got = G.backup_differences(self.tar(base), self.tar({"data": None, "data/a": b"one"}))
        self.assertEqual(got, ["/admin/backup: data/b is on metal only"])
        got = G.backup_differences(self.tar(base), self.tar(dict(base, **{"data/b": b"twos"})))
        self.assertTrue(any("4 on Linux" in g for g in got), got)
        got = G.backup_differences(self.tar(base), self.tar(dict(base, **{"data/b": b"TWO"})))
        self.assertTrue(any("data/b differs" in g for g in got), got)
        self.assertTrue(G.backup_differences(self.tar(base)[:700], self.tar(base)))
        self.assertTrue(G.backup_differences(self.tar({}), self.tar({})))


class RawSocket(unittest.TestCase):
    def test_a_refused_connection_is_an_error_not_a_crash(self):
        port = G.free_port()  # nothing listens there
        self.assertIn("error", G.ask_raw(port, b"GET / HTTP/1.1\r\n\r\n"))

    def test_bytes_come_back_until_close(self):
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        port = srv.getsockname()[1]

        import threading

        def serve():
            c, _ = srv.accept()
            c.recv(100)
            c.sendall(b"hello")
            c.close()

        t = threading.Thread(target=serve)
        t.start()
        got = G.ask_raw(port, b"x")
        t.join()
        srv.close()
        self.assertEqual(got["body"], b"hello")


class Traces(unittest.TestCase):
    LOG = ("  request 1: GET / -> ok (base: 70 live bytes, 4096 in pages, peak 8192)\n"
           "    request heap: 58498 bytes\n"
           "  request 2: GET /nope -> ok (base: 72 live bytes, 8192 in pages, peak 12288)\n"
           "    request heap: 1200 bytes\n")

    def test_the_heaps_are_read_from_the_serial_log(self):
        self.assertEqual(G.base_heap_trace(self.LOG), [70, 72])
        self.assertEqual(G.request_heap_trace(self.LOG), [58498, 1200])

    def test_what_is_live_what_is_held_and_the_peak_are_three_numbers(self):
        # The distinction the whole allocator question turns on: 72 bytes live
        # inside 8192 bytes of pages, having at some point held 12288. A peak
        # that climbs while live sits still is memory that cannot be had again.
        self.assertEqual(G.base_heap_taken(self.LOG), [4096, 8192])
        self.assertEqual(G.base_heap_peak(self.LOG), [8192, 12288])

    def test_a_line_in_the_old_format_is_not_silently_half_read(self):
        # The log used to say only the live bytes. Reading that as "taken 0"
        # would report a machine that reclaims everything.
        for old in ("  request 1: GET / -> ok (base: 70 live bytes)\n",
                    "  request 1: GET / -> ok (base: 70 live bytes, 4096 taken)\n"):
            self.assertEqual(G.base_heap_trace(old), [])
            self.assertEqual(G.base_heap_taken(old), [])
            self.assertEqual(G.base_heap_peak(old), [])


class Timings(unittest.TestCase):
    """The kernel's own account of each request: waiting, answering, and the
    disk's share of the answering."""

    LINE = ("  request 7: GET / -> ok (base: 70 live bytes, 4096 in pages, peak 8192)\n"
            "    waited 94 us, answered in 11600 us, 12 disk requests taking 3400 us\n")

    def test_all_four_numbers_are_read(self):
        self.assertEqual(G.request_timings(self.LINE), [(94, 11600, 12, 3400)])

    def test_a_line_in_an_older_format_is_not_half_read(self):
        # "asked in" was the name when the machine held one connection and
        # the number meant something else; reading it as the new one would
        # mislabel every old log.
        old = "    asked in 94 us, answered in 11600 us, 12 disk requests taking 3400 us\n"
        self.assertEqual(G.request_timings(old), [])


class DiskCheckLines(unittest.TestCase):
    """The disk check's lines in a boot log (QUEUE.md item 13), as gopher.zig's
    diskCheck prints them."""
    CLEAN = ("  the boot disk: FAT16 at LBA 2048, FAT held in memory (128512 bytes)\n"
             "  disk check, the boot disk: 18 files, 17 directories, 52 clusters used, 0 leaked, 0 problems\n"
             "  listening on port 80\n")

    def test_a_clean_line_is_read_and_passes(self):
        self.assertEqual(G.disk_check_lines(self.CLEAN)["the boot disk"],
                         {"files": 18, "directories": 17, "used": 52, "leaked": 0, "problems": 0})
        self.assertEqual(G.disk_check_differences(self.CLEAN), [])

    def test_the_judge_s_image_is_the_volume_only_on_the_droplet_machine(self):
        self.assertEqual(G.image_disk(self.CLEAN), "the boot disk")
        self.assertEqual(G.image_disk("chat's data: the volume, FAT16 at LBA 2048\n"), "the volume")

    def test_a_problem_fails_unless_the_disk_was_damaged_on_purpose(self):
        log = self.CLEAN.replace("0 leaked, 0 problems", "1 leaked, 1 problems") \
            + "    leaked at (the volume), cluster 32168, count 1\n"
        got = G.disk_check_differences(log)
        self.assertTrue(got and "cluster 32168" in got[0], got)
        self.assertEqual(G.disk_check_differences(log, damaged=True), [])

    def test_a_mounted_disk_with_no_line_fails(self):
        log = self.CLEAN.replace("  disk check, the boot disk: 18 files, 17 directories, 52 clusters used, "
                                 "0 leaked, 0 problems\n", "")
        self.assertTrue(G.disk_check_differences(log))
        not_run = log + "  disk check, the boot disk: not run: ReadFailed\n"
        self.assertEqual(G.disk_check_differences(not_run),
                         ["the disk check of the boot disk: not run: ReadFailed"])
        # A boot that never mounted the disk has nothing to say about it.
        self.assertEqual(G.disk_check_differences("FAIL: no disk\n"), [])

    def test_a_fat32_disk_is_held_to_the_same_line(self):
        log = self.CLEAN.replace("FAT16 at LBA", "FAT32 at LBA")
        self.assertEqual(G.disk_check_differences(log), [])
        self.assertTrue(G.disk_check_differences(log.replace("  disk check, the boot disk: 18 files", "  x")))

    def test_the_volume_needs_its_own_line_when_it_serves_chat(self):
        log = self.CLEAN + ("  the volume: FAT16 at LBA 2048, FAT held in memory (1 bytes)\n"
                            "  chat's data: the volume\n")
        self.assertTrue(G.disk_check_differences(log))
        log += "  disk check, the volume: 3 files, 2 directories, 5 clusters used, 0 leaked, 0 problems\n"
        self.assertEqual(G.disk_check_differences(log), [])

    @unittest.skipUnless(shutil.which("mkfs.vfat"), "needs mkfs.vfat (dosfstools) to make a volume")
    def test_leaking_a_cluster_is_what_the_oracle_calls_a_leak(self):
        # On both kinds, and nothing but the leak: on FAT32 a 2-byte write
        # once hit half of another cluster's entry, and FSInfo's count was
        # left wrong, so the damaged gate saw two problems (box, 2026-10-02).
        for fat, kib, spc in (("16", 32 * 1024, None), ("32", 40 * 1024, "1")):
            with tempfile.TemporaryDirectory() as d:
                img = os.path.join(d, "v.img")
                subprocess.run(["mkfs.vfat", "-F", fat, "-S", "512", *(["-s", spc] if spc else []), "-C", img, str(kib)],
                               check=True, capture_output=True)
                sys.path.insert(0, G.TOOLS_DIR)
                import fat16_read
                with open(img, "rb") as f:
                    before = fat16_read.Volume(f.read())
                self.assertEqual(before.kind, "FAT" + fat)
                leaked = G.leak_a_cluster(img)
                with open(img, "rb") as f:
                    v = fat16_read.Volume(f.read())
                problems = v.check()
                self.assertEqual(len(problems), 1, problems)
                self.assertIn("leaked", problems[0])
                self.assertIn(str(leaked), problems[0])
                self.assertEqual(v.free_clusters(), before.free_clusters() - 1)


class FatSerial(unittest.TestCase):
    @unittest.skipUnless(shutil.which("mkfs.vfat") and shutil.which("sgdisk"),
                         "needs mkfs.vfat and sgdisk to make a partitioned volume")
    def test_the_serial_is_read_where_each_kind_keeps_it(self):
        # FAT16 keeps it at 39 and FAT32 at 67; reading 39 on FAT32 named a
        # volume the kernel would refuse as not its own.
        for fat, mib in (("16", 64), ("32", 64)):
            with tempfile.TemporaryDirectory() as d:
                img = os.path.join(d, "v.img")
                with open(img, "wb") as f:
                    f.truncate(mib << 20)
                subprocess.run(["sgdisk", "-o", "-n", f"1:{G.PART_FIRST}:0", img], check=True, capture_output=True)
                blocks = (G.partition_last(img) - G.PART_FIRST + 1) // 2
                subprocess.run(["mkfs.vfat", "-F", fat, "-S", "512", *(["-s", "1"] if fat == "32" else []), "-i", "1234ABCD",
                                "--offset", str(G.PART_FIRST), img, str(blocks)], check=True, capture_output=True)
                self.assertEqual(G.fat_serial(img), "1234-ABCD", f"FAT{fat}")


class ClockJudge(unittest.TestCase):
    # **THE HOST'S RATE IS GIVEN, NOT READ.** These fixtures were recorded on
    # a host whose TSC runs at 2,494.134 MHz. Read from the machine running
    # the tests, the host's rate made every fixture fail on any other CPU, which
    # tested the CPU and not the judge.
    HOST_HZ = "2494134000"

    def verdict(self, text, *args, host_hz=HOST_HZ):
        with tempfile.NamedTemporaryFile("w", suffix=".out", delete=False) as f:
            f.write(text)
        try:
            p = subprocess.run([sys.executable, os.path.join(HERE, "judge_clock.py"), f.name, *args],
                               capture_output=True, text=True,
                               env={**os.environ, "HOST_TSC_HZ": host_hz})
        finally:
            os.remove(f.name)
        return p.returncode, p.stdout

    def test_a_consistent_reading_inside_the_host_window_passes(self):
        code, out = self.verdict("tsc_hz 2494134000\nunix 1789600584\ncivil 2026-9-16 23:16:24\n",
                                 "1789600582", "1789600591")
        self.assertEqual(code, 0, out)
        self.assertIn("same instant", out)
        self.assertIn("within the host's clock", out)
        self.assertNotIn("FAIL civil", out)

    def test_civil_and_unix_that_disagree_fail(self):
        code, out = self.verdict("tsc_hz 2494000000\nunix 1789600584\ncivil 2026-9-16 23:16:25\n",
                                 "1789600582", "1789600591")
        self.assertEqual(code, 1)
        self.assertIn("FAIL civil", out)

    def test_a_reading_outside_the_host_window_fails(self):
        code, out = self.verdict("tsc_hz 2494000000\nunix 1789604184\ncivil 2026-9-17 0:16:24\n",
                                 "1789600582", "1789600591")
        self.assertEqual(code, 1)
        self.assertIn("outside the host's clock", out)

    def test_a_pinned_boot_must_read_just_after_its_base(self):
        ok = "tsc_hz 2494134000\nunix 1583020801\ncivil 2020-3-1 0:0:1\n"
        code, out = self.verdict(ok, "0", "0", "2020-02-29T23:59:59")
        self.assertEqual(code, 0, out)
        self.assertIn("2 s after the pinned", out)
        late = "tsc_hz 2494000000\nunix 1583024400\ncivil 2020-3-1 1:0:0\n"
        code, out = self.verdict(late, "0", "0", "2020-02-29T23:59:59")
        self.assertEqual(code, 1)
        self.assertIn("not just after the pinned", out)

    def test_a_rate_off_the_hosts_by_more_than_half_a_percent_fails(self):
        text = "tsc_hz 2494134000\nunix 1789600584\ncivil 2026-9-16 23:16:24\n"
        code, out = self.verdict(text, "1789600582", "1789600591", host_hz=str(2494134000 * 1.01))
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL tsc_hz", out)
        code, out = self.verdict(text, "1789600582", "1789600591", host_hz=str(2494134000 * 1.004))
        self.assertEqual(code, 0, out)
        self.assertIn("ok   tsc_hz", out)

    def test_a_host_rate_nobody_can_read_is_a_skip_said_aloud(self):
        text = "tsc_hz 2494134000\nunix 1789600584\ncivil 2026-9-16 23:16:24\n"
        code, out = self.verdict(text, "1789600582", "1789600591", host_hz="none")
        self.assertEqual(code, 0, out)
        self.assertIn("SKIP tsc_hz", out)

    def test_a_missing_line_fails(self):
        code, out = self.verdict("tsc_hz 2494000000\n", "0", "0")
        self.assertNotEqual(code, 0)


class Marks(unittest.TestCase):
    """missing_marks is the endurance story's own judge: it is the only check
    that does not go through Linux, so it has to be right on its own."""

    def check(self, steps, answers):
        said = []
        n = G.missing_marks(steps, answers, said.append, "endurance")
        return n, said

    def test_a_read_back_holding_every_mark_passes(self):
        steps = [G.step("read", "GET", "/x", expect=[b"mark-0001", b"mark-0002"])]
        n, said = self.check(steps, [{"body": b"...mark-0001...mark-0002..."}])
        self.assertEqual((n, said), (0, []))

    def test_one_lost_mark_is_a_failure_that_names_it(self):
        steps = [G.step("read", "GET", "/x", expect=[b"mark-0001", b"mark-0002"])]
        n, said = self.check(steps, [{"body": b"only mark-0002 survived"}])
        self.assertEqual(n, 1)
        self.assertIn("mark-0001", said[0])
        self.assertIn("1 of 2", said[0])

    def test_a_step_that_never_answered_is_a_failure_not_a_pass(self):
        steps = [G.step("read", "GET", "/x", expect=[b"mark-0001"])]
        n, said = self.check(steps, [{"error": "the kernel had already exited (0)"}])
        self.assertEqual(n, 1)
        self.assertIn("no body", said[0])

    def test_an_empty_body_does_not_read_as_holding_the_marks(self):
        steps = [G.step("read", "GET", "/x", expect=[b"mark-0001"])]
        n, _ = self.check(steps, [{"body": b""}])
        self.assertEqual(n, 1)

    def test_steps_with_nothing_to_expect_are_not_judged(self):
        steps = [G.step("write", "POST", "/x", body="mark-0001")]
        self.assertEqual(self.check(steps, [{"body": None}]), (0, []))


class Endurance(unittest.TestCase):
    """The story's shape: every round writes a mark and then demands it, and
    every earlier one, back."""

    def test_each_read_back_demands_one_more_mark_than_the_last(self):
        expects = [s["expect"] for s in G.ENDURANCE if s["expect"]]
        # One read-back per round: the whole transcript.
        self.assertEqual(len(expects), G.ENDURANCE_ROUNDS)
        for n in range(G.ENDURANCE_ROUNDS):
            self.assertEqual(len(expects[n]), n + 1)
        self.assertEqual(expects[-1][-1], G.mark(G.ENDURANCE_ROUNDS))

    def test_every_mark_written_is_demanded_back(self):
        written = {G.mark(n) for n in range(1, G.ENDURANCE_ROUNDS + 1)}
        demanded = set()
        for s in G.ENDURANCE:
            demanded |= set(s["expect"])
        self.assertEqual(written, demanded)

    def test_it_is_chat_and_nothing_else(self):
        # Lyn Rummy stays on the Linux droplet: nothing here may reach for it.
        paths = {s["path"] for s in G.ENDURANCE}
        self.assertIn("/chat/c/1_2/general/send", paths)
        for p in paths:
            self.assertFalse(p.startswith(("/game", "/puzzles", "/play")), p)

    def test_docs_are_part_of_the_chat_surface_and_are_asked_for(self):
        self.assertIn("/chat/docs", {s["path"] for s in G.ENDURANCE})


class Conf(unittest.TestCase):
    """What the kernel reads off its own volume. The judge writes it, so the
    judge's tests are where a typo in a key name gets caught — the kernel stops
    on an unknown key, which is a failure with no diff to read."""

    # These are microvm's files: JUDGE_DROPLET in the environment is pinned
    # off here, and the droplet's one extra line has a test of its own.
    def setUp(self):
        self.droplet = G.DROPLET
        G.DROPLET = False

    def tearDown(self):
        G.DROPLET = self.droplet

    def test_on_the_droplet_machine_the_private_card_and_the_volume_are_named(self):
        G.DROPLET = True
        real = G.fat_serial
        G.fat_serial = lambda image: "92DE-8831"
        try:
            text = G.request_limit_text("unused.img", 1)
        finally:
            G.fat_serial = real
        # Spelled as probe/gopher.zig's `Card` enum and `parseSerial` spell them.
        self.assertIn("\ncard = private\n", text)
        self.assertIn("\nvolume = 92DE-8831\n", text)

    def test_the_serial_is_read_as_blkid_spells_it(self):
        with tempfile.TemporaryDirectory() as d:
            image = os.path.join(d, "disk.img")
            with open(image, "wb") as f:
                f.seek(G.PART_FIRST * G.SECTOR + 39)
                f.write((0x92DE8831).to_bytes(4, "little"))
            self.assertEqual(G.fat_serial(image), "92DE-8831")

    def test_both_keys_are_written_and_spelled_as_the_kernel_reads_them(self):
        import re as _re
        text = G.request_limit_text("unused.img", 7, idle_timeout_ms=1234)
        self.assertEqual(text, "requests = 7\nidle_timeout_ms = 1234\n")
        # The kernel's parser: `key = value`, one per line, nothing else.
        for line in text.strip().splitlines():
            self.assertRegex(line, _re.compile(r"^(requests|idle_timeout_ms) = \d+$"))

    def test_a_default_timeout_is_written_when_none_is_asked_for(self):
        text = G.request_limit_text("unused.img", 1)
        self.assertIn("idle_timeout_ms = 10000", text)


    def test_the_optional_keys_are_written_as_the_kernel_reads_them(self):
        text = G.request_limit_text("unused.img", 3, streams=2, lose_one_sent_in=7)
        self.assertEqual(text, "requests = 3\nidle_timeout_ms = 10000\nstreams = 2\nlose_one_sent_in = 7\n")


class DiskByMtools(unittest.TestCase):
    """The judge's own way onto and off the kernel's disk (QUEUE.md item 64):
    what it puts there it reads back, a site is moved off whole, and a file
    that is not there reads as None."""

    def test_put_write_read_take_and_move(self):
        import shutil as _sh
        if any(_sh.which(t) is None for t in ("sgdisk", "mkfs.vfat", "mcopy", "mdir", "mdeltree")):
            self.skipTest("mtools, sgdisk or mkfs.vfat is not installed")
        if G.MOUNT:
            self.skipTest("JUDGE_MOUNT=1: these are the mtools path's")
        with tempfile.TemporaryDirectory() as d:
            content = os.path.join(d, "content")
            for rel, body in (("data/chat/1_2/sessions/General.md", b"hi"), ("auth/1/name", b"Steve"),
                              ("pages/home.txt", b"home"), ("zig-metal-unikernel.conf", b"x")):
                os.makedirs(os.path.dirname(os.path.join(content, rel)), exist_ok=True)
                with open(os.path.join(content, rel), "wb") as f:
                    f.write(body)
            os.utime(os.path.join(content, "auth/1/name"), (1758000000, 1758000000))
            image = os.path.join(d, "disk.img")
            G.build_disk(image, content, os.path.join(d, "mnt"), size=16 << 20, fat="16")
            G.set_request_limit(image, 3, os.path.join(d, "mnt"))
            got = G.disk_read(image, "unused", ["data/chat/1_2/sessions/General.md", "zig-metal-unikernel.conf",
                                                "data/missing"])
            self.assertEqual(got["data/chat/1_2/sessions/General.md"], b"hi")
            self.assertEqual(got["zig-metal-unikernel.conf"], G.request_limit_text(image, 3).encode())
            self.assertIsNone(got["data/missing"])
            taken = os.path.join(d, "taken")
            G.disk_take(image, "unused", taken, names=G.DATA_DIRS)
            self.assertEqual(sorted(G.tree(taken)), ["auth/1/name", "data/chat/1_2/sessions/General.md"])
            self.assertEqual(int(os.path.getmtime(os.path.join(taken, "auth/1/name"))), 1758000000)
            fat = G.split_site_off(image, os.path.join(d, "s"))
            self.assertEqual(sorted(G.disk_names(image)), ["auth", "data"])
            self.assertEqual(sorted(G.disk_names(fat, partitioned=False)), ["pages", "zig-metal-unikernel.conf"])


class TcpCounts(unittest.TestCase):
    LINE = ("  tcp: 12 timeouts sent something again, 3 window probes, "
            "0 peers given up on, 0 never finished, 3 strays reset, 41 frames lost on purpose\n")

    def test_the_kernels_line_is_read(self):
        self.assertEqual(G.tcp_counts("x\n" + self.LINE),
                         {"retransmits": 12, "probes": 3, "given_up": 0, "lost": 41})

    def test_no_line_is_none_not_zeros(self):
        self.assertIsNone(G.tcp_counts("  connections: at most 3 at once, 0 turned away\n"))


class Bulk(unittest.TestCase):
    def test_each_message_names_itself_first_and_is_about_40_kb(self):
        text = G.bulk_text(3)
        self.assertTrue(text.startswith("bulk-03+"))
        self.assertLess(len(text), 64 * 1024)  # chat's limit on one message
        self.assertGreater(len(text), 35 * 1024)
        self.assertNotIn(" ", text)  # form-encoded: sent as is

    def test_the_transcript_read_expects_every_message(self):
        read = [s for s in G.BULK if s["path"].endswith("/raw")]
        self.assertEqual(len(read), 1)
        self.assertEqual(read[0]["expect"], [G.bulk_name(n) for n in range(1, G.BULK_MESSAGES + 1)])


class Ladder(unittest.TestCase):
    LOG = ("zig-metal-unikernel ladder\n"
           "rung cpu: 500 ops; ns per op by tenth: 900 500 500 510 500 500 505 500 520 530; "
           "disk requests by tenth: 0 0 0 0 0 0 0 0 0 0\n"
           "rung append: 1000 ops; ns per op by tenth: 100 100 100 120 140 160 180 200 220 240; "
           "disk requests by tenth: 300 300 300 300 300 300 300 300 300 300\n")

    def test_every_rung_is_read(self):
        rungs = L.parse(self.LOG)
        self.assertEqual(sorted(rungs), ["append", "cpu"])
        self.assertEqual(rungs["cpu"]["ops"], 500)
        self.assertEqual(rungs["cpu"]["ns"][0], 900)

    def test_a_slow_first_tenth_is_warm_up_not_growth(self):
        flat, ratio, _ = L.verdict(L.parse(self.LOG)["cpu"])
        self.assertTrue(flat)
        self.assertAlmostEqual(ratio, 1.0)

    def test_a_cost_that_doubles_climbs(self):
        flat, ratio, _ = L.verdict(L.parse(self.LOG)["append"])
        self.assertFalse(flat)
        self.assertAlmostEqual(ratio, 2.0)

    def test_a_spike_is_not_growth(self):
        # The alloc rung's own numbers from one run: a spike in the last tenths,
        # with a tenth at the old cost among them.
        r = {"ops": 20000, "ns": [25805, 25620, 29080, 37775, 37176, 39512, 40208, 28940, 59610, 60622],
             "requests": [0] * 10}
        flat, ratio, _ = L.verdict(r)
        self.assertTrue(flat)

    def test_flat_cost_with_climbing_requests_is_not_flat(self):
        r = {"ops": 10, "ns": [5] * 10, "requests": [10, 10, 10, 10, 10, 10, 20, 30, 40, 50]}
        flat, _, climbs = L.verdict(r)
        self.assertTrue(climbs)
        self.assertFalse(flat)

    def test_a_line_the_kernel_prints_is_a_line_the_judge_reads(self):
        # The format string in probe/ladder.zig, restated.
        line = ("rung write_spread: 2000 ops; ns per op by tenth: 1 2 3 4 5 6 7 8 9 10; "
                "disk requests by tenth: 200 200 200 200 200 200 200 200 200 200")
        self.assertIn("write_spread", L.parse(line))


class RawResponse(unittest.TestCase):
    def test_status_headers_and_body(self):
        r = G.parse_raw_response(b"HTTP/1.1 303 See Other\r\nLocation: /x\r\n"
                                 b"Set-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\nbody")
        self.assertEqual(r["status"], 303)
        self.assertEqual(r["headers"]["location"], "/x")
        self.assertEqual(r["headers"]["set-cookie"], "a=1\nb=2")
        self.assertEqual(r["body"], b"body")

    def test_a_response_cut_short_is_an_error_not_a_blank_answer(self):
        self.assertIn("error", G.parse_raw_response(b"HTTP/1.1 200 OK\r\nContent-"))
        self.assertIn("error", G.parse_raw_response(b""))
        self.assertIn("error", G.parse_raw_response(b"garbage\r\n\r\n"))

    def test_the_streams_line_is_read(self):
        m = G.STREAMS_LINE.search("  streams: at most 3 held at once, 2 ended, 0 still subscribed\n")
        self.assertEqual(m.groups(), ("3", "2", "0"))
        # The line without the subscriber count is an older kernel's.
        self.assertIsNone(G.STREAMS_LINE.search("  streams: at most 3 held at once, 2 ended\n"))

    def test_the_final_heap_line_is_read(self):
        m = G.FINAL_HEAP.search("  served 9 request(s); base heap holds 384 live bytes in 7 allocations")
        self.assertEqual(m.groups(), ("384", "7"))

    def test_the_connections_line_is_read(self):
        m = G.CONNECTIONS_LINE.search("  connections: at most 8 at once, 0 turned away for want of a slot")
        self.assertEqual((m.group(1), m.group(2)), ("8", "0"))


class Patience(unittest.TestCase):
    """How the judge's client waits. A refused connection is a guest still
    coming up, and is tried again until `patience` runs out; a request that was
    sent is never sent again."""

    def test_a_refused_connection_is_tried_until_patience_runs_out(self):
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()  # nothing listens there now
        started = time.time()
        a = G.ask(port, G.step("x", "GET", "/"), "unused", patience=2)
        took = time.time() - started
        self.assertIn("refused", a.get("error", ""))
        self.assertGreaterEqual(took, 1.0)
        self.assertLess(took, 4.0)

    def test_a_request_that_was_sent_is_never_sent_again(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(4)
        port = listener.getsockname()[1]
        accepted = []
        done = threading.Event()

        def serve():
            # Accepts until `ask` has returned: any second sending would have
            # come before that. A short timeout, so the thread stops at once
            # rather than waiting out a long one.
            listener.settimeout(0.05)
            idle_after_done = 0
            while idle_after_done < 4:  # and then whatever is still in the backlog
                try:
                    conn, _ = listener.accept()
                except OSError:
                    if done.is_set():
                        idle_after_done += 1
                    continue
                accepted.append(conn.recv(4096))
                conn.close()  # no answer at all

        t = threading.Thread(target=serve)
        t.start()
        a = G.ask(port, G.step("x", "POST", "/send", None, "a=1"), "unused", patience=30)
        done.set()
        t.join()
        listener.close()
        self.assertIn("error", a)
        self.assertEqual(len(accepted), 1)
        self.assertTrue(accepted[0].startswith(b"POST /send HTTP/1.1"))

    def test_an_answer_keeps_its_status_every_cookie_and_its_body(self):
        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                self.send_response(303)
                self.send_header("Location", "/there")
                self.send_header("Set-Cookie", "a=1")
                self.send_header("Set-Cookie", "b=2")
                reply = b"got " + body + b" with " + self.headers["Cookie"].encode() \
                    + b" and " + self.headers["X-Chat-Async"].encode()
                self.send_header("Content-Length", str(len(reply)))
                self.end_headers()
                self.wfile.write(reply)

            def log_message(self, *a):
                pass

        srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        t = threading.Thread(target=srv.handle_request)
        t.start()
        a = G.ask(srv.server_address[1],
                  G.step("x", "POST", "/go", "k=v", "m=hi", headers=["X-Chat-Async: 1"]),
                  "unused", patience=5)
        t.join()
        srv.server_close()
        self.assertEqual(a["status"], 303)
        self.assertEqual(a["headers"]["location"], "/there")
        self.assertEqual(a["headers"]["set-cookie"], "a=1\nb=2")
        self.assertEqual(a["body"], b"got m=hi with k=v and 1")


class Accelerator(unittest.TestCase):
    """Timing runs ask for KVM; a request that cannot be met must fail loudly,
    never fall back to software emulation under KVM's name."""

    def qemu_args(self, kvm):
        caught = {}
        real = subprocess.Popen

        class Stop(Exception):
            pass

        def fake(cmd, **kw):
            caught["cmd"] = cmd
            raise Stop()

        # These are microvm's arguments; JUDGE_DROPLET in the environment must
        # not turn this into a test of the droplet machine instead.
        droplet = G.DROPLET
        G.DROPLET = False
        subprocess.Popen = fake
        try:
            with tempfile.TemporaryDirectory() as d:
                G.start_kernel("k.elf", "d.img", d, kvm=kvm)
        except Stop:
            pass
        finally:
            subprocess.Popen = real
            G.DROPLET = droplet
        return caught["cmd"]

    def test_correctness_boots_stay_on_software_emulation(self):
        self.assertNotIn("-enable-kvm", self.qemu_args(False))

    @unittest.skipUnless(G.kvm_usable(), "no usable /dev/kvm here")
    def test_a_timing_boot_asks_for_kvm(self):
        self.assertIn("-enable-kvm", self.qemu_args(True))

    def test_kvm_that_is_not_there_is_an_error_not_a_fallback(self):
        real = G.kvm_usable
        G.kvm_usable = lambda: False
        try:
            with self.assertRaises(RuntimeError):
                G.start_kernel("k.elf", "d.img", "/nonexistent", kvm=True)
        finally:
            G.kvm_usable = real


class Resolution(unittest.TestCase):
    """FAT16 stores a modification time in whole EVEN seconds; ext4 stores
    nanoseconds. Wherever a story judges the ORDER of two writes, it has to put
    them further apart than the coarser clock's tick — otherwise the judge is
    demanding that FAT16 be ext4, and the failure it reports is its own."""

    FAT16_TICK = 2.0

    def test_the_second_conversation_is_created_a_tick_later(self):
        by_name = {s["name"]: s for s in G.MEMBER_STORY}
        self.assertGreater(by_name["a new topic"]["settle"], self.FAT16_TICK)

    def test_recent_activity_comes_after_both_conversations_are_written(self):
        # The order it prints is the thing being judged, so it must be asked
        # last of the three.
        names = [s["name"] for s in G.MEMBER_STORY]
        self.assertLess(names.index("a message in it"), names.index("recent activity"))
        self.assertLess(names.index("a new topic"), names.index("a message in it"))

    def test_every_step_carries_the_field_the_runner_reads(self):
        for s in G.MEMBER_STORY:
            self.assertIn("settle", s, s["name"])

    def test_a_story_waits_no_longer_than_it_has_to(self):
        # A settle is dead time on both sides, twice. If this starts climbing,
        # something is being papered over with sleep.
        total = sum(s["settle"] for s in G.MEMBER_STORY)
        self.assertLessEqual(total, 6.0)


class Uploads(unittest.TestCase):
    """The upload gate's own pieces: what it posts, and how big."""

    def test_a_picture_is_exactly_the_size_asked_for(self):
        for n in (16, 1024, 64 << 10):
            self.assertEqual(n, len(G.picture(n)))

    def test_a_picture_sniffs_as_a_png(self):
        # The handler decides the kind from the magic bytes, never the name —
        # so a body that does not start this way is a 415, not an upload.
        self.assertTrue(G.picture(4096).startswith(b"\x89PNG\r\n\x1a\n"))

    def test_the_oversized_upload_is_bigger_than_the_heap_the_machine_keeps(self):
        # The point of that step is to make the request heap grow. If the heap
        # the machine keeps ever passes this, the step stops testing anything.
        keeps = 32 << 20
        self.assertGreater(G.OVERSIZED_UPLOAD, keeps)

    def test_the_multipart_body_carries_the_bytes_between_its_boundaries(self):
        body = G.multipart("shot.png", b"BYTES")
        self.assertIn(b"BYTES", body)
        self.assertTrue(body.startswith(f"--{G.UPLOAD_BOUNDARY}".encode()))
        self.assertTrue(body.endswith(f"--{G.UPLOAD_BOUNDARY}--\r\n".encode()))
        self.assertIn(b'filename="shot.png"', body)

    def test_the_quick_tier_leaves_out_the_big_one(self):
        # Reading 40 MB through the machine is the slowest thing in the gate.
        self.assertIn("if not QUICK", inspect.getsource(G.upload_story))



class OneWebbox(unittest.TestCase):
    """**ONE webbox ON BOTH SIDES.** The kernel's library and the Linux
    zig-server's (its build.zig.zon's path) must be one checkout, or the
    judge compares two libraries."""

    def tree(self, dependency='.webbox = .{ .path = "../../zig-webbox" },'):
        top = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, top)
        gopher = os.path.join(top, "angry-gopher")
        os.makedirs(os.path.join(gopher, "zig-server"))
        os.makedirs(os.path.join(top, "zig-webbox"))
        with open(os.path.join(gopher, "zig-server", "build.zig.zon"), "w") as f:
            f.write(".{\n    .dependencies = .{\n        " + dependency + "\n    },\n}\n")
        return gopher, os.path.join(top, "zig-webbox")

    def test_the_sibling_the_zon_names_is_one_library(self):
        gopher, webbox = self.tree()
        self.assertIsNone(G.two_webboxes(gopher, webbox))

    def test_another_checkout_is_refused(self):
        gopher, _ = self.tree()
        refusal = G.two_webboxes(gopher, tempfile.gettempdir())
        self.assertTrue(refusal.startswith("FAIL webbox |"), refusal)

    def test_a_zon_that_names_no_webbox_is_refused(self):
        gopher, webbox = self.tree(dependency="")
        refusal = G.two_webboxes(gopher, webbox)
        self.assertTrue(refusal.startswith("FAIL webbox |"), refusal)


class Gates(unittest.TestCase):
    """**EVERY GATE IS ASKABLE, AND EVERY GATE IS GUARDED.** A gate that runs
    whatever was asked for costs a QEMU boot that nobody wanted; one that is
    never reachable by name is a gate that cannot be iterated on."""

    def setUp(self):
        self.tree = ast.parse(textwrap.dedent(inspect.getsource(G.main)))

    @staticmethod
    def asks_running(test) -> bool:
        return any(isinstance(n, ast.Call) and getattr(n.func, "id", "") == "running"
                   for n in ast.walk(test))

    def guarded_nodes(self) -> set:
        out = set()
        for node in ast.walk(self.tree):
            if isinstance(node, ast.If) and self.asks_running(node.test):
                out |= {id(n) for n in ast.walk(node)}
        return out

    def named_gates(self) -> set:
        return {n.args[0].value for n in ast.walk(self.tree)
                if isinstance(n, ast.Call) and getattr(n.func, "id", "") == "running"
                and n.args and isinstance(n.args[0], ast.Constant)}

    def test_every_gate_in_the_list_is_asked_for_somewhere(self):
        self.assertEqual(set(G.GATES), self.named_gates())

    def test_the_list_has_no_duplicates(self):
        self.assertEqual(len(G.GATES), len(set(G.GATES)))

    def test_every_check_that_boots_qemu_is_behind_a_gate(self):
        guarded = self.guarded_nodes()
        loose = [n.func.id for n in ast.walk(self.tree)
                 if isinstance(n, ast.Call) and getattr(n.func, "id", "").endswith("_failures")
                 and id(n) not in guarded]
        self.assertEqual([], loose, "these run whatever gate was asked for")

    def test_the_long_boots_are_gates_too(self):
        self.assertTrue(G.LONG <= set(G.GATES))

    def test_a_gate_nobody_named_is_an_error(self):
        # Silently running everything when asked for "uplaods" is the failure
        # mode this exists to prevent.
        self.assertNotIn("uplaods", G.GATES)



if __name__ == "__main__":
    unittest.main(verbosity=1)


class LegacyNamesEnd(unittest.TestCase):
    def test_the_legacy_names_have_not_ended(self):
        # metal-vmm QUEUE 176.2: on 2026-11-15 the hosts stop reading the
        # legacy cookie names, and P1 = "gopher_uid=1", UID_STORY's unsigned
        # steps and the "is no one" checks quietly test nothing.
        import datetime
        if datetime.datetime.now(datetime.timezone.utc) >= datetime.datetime(2026, 11, 15, tzinfo=datetime.timezone.utc):
            self.fail("the legacy cookie names ended on 2026-11-15: delete judge_gopher.py's legacy steps "
                      "(P1, UID_STORY's unsigned cookies and their checks) with the hosts' migration")
