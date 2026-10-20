#!/usr/bin/env python3
"""gmail.py crawl parsing against a synthetic imaplib FETCH response — no
network, no Keychain. Run: python3 -m unittest moe-home/connectors/tests/test_gmail_crawl.py"""

import base64
import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("moe_gmail", os.path.join(HERE, "..", "gmail.py"))
gmail = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gmail)


def hdr(**fields):
    return "".join("%s: %s\r\n" % (k.replace("_", "-"), v) for k, v in fields.items()).encode() + b"\r\n"


def fetch_response():
    """What imaplib hands back for four messages, in the shape it really
    uses: (meta, literal) tuples, one per literal, the first meta of a
    message opening with its sequence number, and a bare b')' between."""
    long_b64 = base64.b64encode(("Hello from the phone. " * 20).encode()).decode()
    m1 = hdr(From="a@example.com", To="me@example.com", Subject="one", Date="Mon, 3 Aug 2026 10:00:00 +0000",
             Content_Type="text/plain; charset=utf-8", Content_Transfer_Encoding="base64")
    m2 = hdr(From="b@example.com", To="me@example.com", Subject="two", Date="Tue, 4 Aug 2026 10:00:00 +0000",
             Content_Type="text/plain")
    m3 = hdr(From="c@example.com", To="me@example.com", Subject="three", Date="Wed, 5 Aug 2026 10:00:00 +0000",
             Content_Type='multipart/alternative; boundary="B"')
    m3_text = (b"--B\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
               b"Caf=C3=A9 at nine=2C bring the plans\r\n--B\r\nContent-Type: text/html\r\n\r\n<p>Caf&eacute;</p>\r\n--B--\r\n")
    m4 = hdr(From="d@example.com", To="me@example.com", Subject="four", Date="Thu, 6 Aug 2026 10:00:00 +0000",
             Content_Type="text/html; charset=utf-8")
    return [
        (b"1 (BODY[HEADER.FIELDS (FROM TO SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] {%d}" % len(m1), m1),
        (b" BODY[TEXT]<0> {%d}" % 301, long_b64[:301].encode()),     # cut mid-quad by the partial fetch
        b")",
        (b"2 (BODY[HEADER.FIELDS (FROM TO SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] {%d}" % len(m2), m2),
        b' BODY[TEXT]<0> "")',                                        # empty body: no literal at all
        (b"3 (BODY[TEXT]<0> {%d}" % len(m3_text), m3_text),           # server sent TEXT first this time
        (b" BODY[HEADER.FIELDS (FROM TO SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] {%d}" % len(m3), m3),
        b")",
        (b"4 (BODY[HEADER.FIELDS (FROM TO SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] {%d}" % len(m4), m4),
        (b" BODY[TEXT]<0> {%d}" % 40, b"<html><body><b>Bold</b> only</body></html>"),
        b")",
    ]


class FakeConn(object):
    def __init__(self, msgs):
        self.msgs = msgs

    def select(self, folder, readonly=True):
        return "OK", [b"4"]

    def search(self, charset, query):
        return "OK", [b"1 2 3 4"]

    def fetch(self, ids, what):
        assert b"1,2,3,4" == ids, ids
        assert "CONTENT-TRANSFER-ENCODING" in what, what
        return "OK", self.msgs


class ParseFetchTest(unittest.TestCase):
    def test_pairs_on_sequence_number_not_arrival_order(self):
        got = gmail.parse_fetch(fetch_response())
        self.assertEqual([seq for seq, _, _ in got], [b"1", b"2", b"3", b"4"])
        # Message 2 had no TEXT literal; it keeps its own header and gets
        # no body — it is not paired with message 3's text.
        self.assertIn(b"Subject: two", got[1][1])
        self.assertIsNone(got[1][2])
        self.assertIn(b"Subject: three", got[2][1])
        self.assertIn(b"Caf=C3=A9", got[2][2])

    def test_bodies_are_decoded(self):
        blocks = list(gmail.crawl_folder(FakeConn(fetch_response()), "INBOX", 90, 10 ** 6))
        self.assertEqual(len(blocks), 4)
        self.assertIn("Hello from the phone. Hello from the phone.", blocks[0])   # base64, cut, still readable
        self.assertNotIn("SGVsbG8", blocks[0])
        self.assertTrue(blocks[1].startswith("### Tue, 4 Aug 2026 10:00:00 +0000 | two | from b@example.com"))
        self.assertTrue(blocks[1].endswith("| to me@example.com\n\n\n"), repr(blocks[1]))
        self.assertIn("Café at nine, bring the plans", blocks[2])              # the text/plain part, qp-decoded
        self.assertNotIn("Content-Type", blocks[2])
        self.assertNotIn("<p>", blocks[2])
        self.assertIn("Bold only", blocks[3])                                   # html-only: tags stripped
        self.assertNotIn("<b>", blocks[3])

    def test_budget_stops_the_folder(self):
        blocks = list(gmail.crawl_folder(FakeConn(fetch_response()), "INBOX", 90, 350))
        self.assertEqual(len(blocks), 1)


if __name__ == "__main__":
    unittest.main()
