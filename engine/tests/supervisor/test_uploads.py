"""`POST /v1/uploads` and the id→path resolver (audit 01-B7).

The refusal that matters is the cheap one: a declared `Content-Length` over
the cap must be answered before a byte of the body is read, or a 400 MB
upload costs the transfer twice over. `AsgiResponse.receives` counts how
many times the handler pulled from `receive`, which is the only way to say
"before the body" out loud.
"""

from __future__ import annotations

import os
import tempfile
import types
import unittest

from _fixtures import FakeState, call_asgi

from supervisor.api import build_app
from supervisor.api.uploads import MAX_UPLOAD_BYTES, resolve_upload


class UploadCapTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.uploads = os.path.join(self.tmp.name, "uploads")
        self.state = FakeState(settings=types.SimpleNamespace(
            auth_token="test-token", uploads_dir=self.uploads))
        self.app = build_app(self.state)

    def test_an_oversized_content_length_is_refused_before_the_body(self) -> None:
        """01-B7: the whole point of reading the header — the bytes must not
        have to arrive for the refusal to happen."""
        res = call_asgi(self.app, "POST", "/v1/uploads",
                        headers={"content-length": str(MAX_UPLOAD_BYTES + 1)},
                        body=b"")
        self.assertEqual(res.status, 422, res.body)
        self.assertEqual(res.error()["code"], "VALIDATION")
        self.assertEqual(res.receives, 0, "the body was read anyway")

    def test_the_refusal_says_the_cap_in_megabytes(self) -> None:
        res = call_asgi(self.app, "POST", "/v1/uploads",
                        headers={"content-length": str(MAX_UPLOAD_BYTES * 2)})
        self.assertIn(str(MAX_UPLOAD_BYTES // (1 << 20)),
                      res.error()["message"])

    def test_an_oversized_upload_leaves_nothing_on_disk(self) -> None:
        call_asgi(self.app, "POST", "/v1/uploads",
                  headers={"content-length": str(MAX_UPLOAD_BYTES + 1)})
        self.assertFalse(os.path.isdir(self.uploads))

    def test_a_content_length_exactly_at_the_cap_is_not_refused_early(self) -> None:
        """`>` not `>=`: an upload of exactly the cap is legal, and it is the
        streamed count that decides."""
        res = call_asgi(self.app, "POST", "/v1/uploads",
                        headers={"content-length": str(MAX_UPLOAD_BYTES)},
                        body=b"RIFFsmall")
        self.assertEqual(res.status, 201, res.body)

    def test_a_non_numeric_content_length_falls_through_to_the_stream(self) -> None:
        """A chunked upload declares no length at all; the read-and-drop path
        is what makes its 422 deliverable, so this must not short-circuit."""
        res = call_asgi(self.app, "POST", "/v1/uploads",
                        headers={"content-length": "not-a-number"},
                        body=b"RIFFsmall")
        self.assertEqual(res.status, 201, res.body)

    def test_a_normal_upload_lands_and_reports_its_size(self) -> None:
        payload = b"RIFF" + b"\x00" * 100
        res = call_asgi(self.app, "POST", "/v1/uploads",
                        body=[payload[:40], payload[40:]])
        self.assertEqual(res.status, 201, res.body)
        body = res.json()
        self.assertEqual(body["bytes"], len(payload))
        self.assertTrue(body["upload_id"].startswith("up_"))
        path = resolve_upload(self.uploads, body["upload_id"])
        self.assertIsNotNone(path)
        with open(path, "rb") as f:
            self.assertEqual(f.read(), payload)

    def test_an_empty_body_is_refused_and_leaves_no_directory(self) -> None:
        res = call_asgi(self.app, "POST", "/v1/uploads", body=b"")
        self.assertEqual(res.status, 422, res.body)
        self.assertEqual(res.error()["code"], "VALIDATION")
        self.assertEqual(os.listdir(self.uploads) if
                         os.path.isdir(self.uploads) else [], [])

    def test_the_filename_is_taken_as_a_basename_only(self) -> None:
        """A `filename` of `../../evil` must not write outside the upload."""
        res = call_asgi(self.app, "POST", "/v1/uploads", body=b"data",
                        query="filename=../../evil.wav")
        self.assertEqual(res.status, 201, res.body)
        self.assertEqual(res.json()["filename"], "evil.wav")
        listing = os.listdir(os.path.join(self.uploads,
                                          res.json()["upload_id"]))
        self.assertEqual(listing, ["evil.wav"])


class ResolveUploadTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.uploads = os.path.join(self.tmp.name, "uploads")
        os.makedirs(os.path.join(self.uploads, "up_abc123"))
        self.file = os.path.join(self.uploads, "up_abc123", "audio.wav")
        with open(self.file, "wb") as f:
            f.write(b"RIFF")

    def test_a_known_id_resolves_to_its_single_file(self) -> None:
        self.assertEqual(resolve_upload(self.uploads, "up_abc123"), self.file)

    def test_an_unknown_id_is_none(self) -> None:
        self.assertIsNone(resolve_upload(self.uploads, "up_nothing"))

    def test_a_traversing_id_is_refused_rather_than_walked(self) -> None:
        """`submit` feeds user-supplied ids straight in; anything with a path
        separator must never become a path."""
        for evil in ("../up_abc123", "/etc", "a/b", "up_abc123/audio.wav",
                     "/"):
            self.assertIsNone(resolve_upload(self.uploads, evil), evil)

    def test_the_degenerate_ids_are_refused_too(self) -> None:
        """They were not, until 2026-09-16.

        `os.path.basename` is the identity on `"."`, `".."` and `""`, so all
        three slip past the `basename(upload_id) != upload_id` guard and
        become a listdir of a directory the uploads root does not own.
        Observed 2026-09-16 with a data dir at `<tmp>/data`:

            resolve_upload(uploads, "..") ->
                '<tmp>/data/uploads/../installed'
            resolve_upload(uploads, ".")  ->
                '<tmp>/data/uploads/./up_abc123'
            resolve_upload(uploads, "")   ->
                '<tmp>/data/uploads/up_abc123'

        `JobQueue.submit` passes the request's value straight in for every
        `audio`/`midi` param, so `{"params": {"src_audio": ".."}}` hands a
        worker the first entry of the *data* directory as its input path.
        """
        for evil in ("..", ".", ""):
            self.assertIsNone(resolve_upload(self.uploads, evil), evil)

    def test_a_non_string_id_is_refused(self) -> None:
        for evil in (None, 7, [], {}):
            self.assertIsNone(resolve_upload(self.uploads, evil))

    def test_an_empty_upload_directory_is_none(self) -> None:
        os.makedirs(os.path.join(self.uploads, "up_empty"))
        self.assertIsNone(resolve_upload(self.uploads, "up_empty"))


if __name__ == "__main__":
    unittest.main()
