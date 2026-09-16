"""YuE's lyric sheet: what upstream's off-by-one is fed.

Covers M45 / 10-B2. Upstream renders `prompt_texts[1:run_n_segments]` and
skips entry 0, so the LAST tagged section is always dropped — a one-section
sheet rendered nothing at all, and the job died hours later, after both
checkpoints had loaded, on "produced no mixed audio file".
"""

import sys
import unittest

from adapter_yue.adapter import _TAG, _lyric_sheet


def sections(sheet: str) -> list[str]:
    return _TAG.findall(sheet)


class LyricSheetTests(unittest.TestCase):
    def test_one_section_lyric_sheet_still_renders(self):
        """M45/10-B2: exactly one `[verse]` must survive the off-by-one.

        The sheet handed upstream therefore carries two tagged sections: the
        user's, and the sentinel that gets eaten.
        """
        sheet, written = _lyric_sheet("[verse]\nthe only thing I wrote")
        self.assertEqual(written, 1)
        self.assertEqual(sections(sheet), ["verse", "outro"])
        self.assertIn("the only thing I wrote", sheet)

    def test_empty_lyrics_fallback_is_a_renderable_section_list(self):
        """M45/10-B2: the adapter's own fallback hit the same off-by-one."""
        sheet, written = _lyric_sheet("")
        self.assertEqual(written, 1)
        self.assertEqual(sections(sheet), ["verse", "outro"])
        self.assertIn("la la la", sheet)

    def test_lyrics_that_are_only_whitespace_take_the_fallback(self):
        sheet, written = _lyric_sheet("   \n\t\n ")
        self.assertEqual(written, 1)
        self.assertIn("la la la", sheet)

    def test_none_takes_the_fallback(self):
        sheet, written = _lyric_sheet(None)
        self.assertEqual(written, 1)
        self.assertIn("la la la", sheet)

    def test_untagged_lyrics_gain_a_verse_tag(self):
        """10-B2: untagged text made upstream's `split_lyrics()` return []
        and the stage-1 loop never ran its body at all."""
        sheet, written = _lyric_sheet("just some words\nand some more")
        self.assertEqual(written, 1)
        self.assertTrue(sheet.startswith("[verse]\n"), sheet)
        self.assertIn("just some words", sheet)

    def test_every_section_the_user_wrote_is_counted(self):
        sheet, written = _lyric_sheet(
            "[verse]\na\n\n[chorus]\nb\n\n[verse]\nc")
        self.assertEqual(written, 3)
        self.assertEqual(sections(sheet),
                         ["verse", "chorus", "verse", "outro"])

    def test_the_sentinel_is_always_the_last_section(self):
        """It exists to be eaten, so nothing the user wrote may follow it."""
        for lyrics in ("", "[chorus]\nhey", "no tags at all"):
            with self.subTest(lyrics=lyrics):
                sheet, _written = _lyric_sheet(lyrics)
                self.assertEqual(sections(sheet)[-1], "outro")
                self.assertEqual(sections(sheet).count("outro"), 1)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(unittest.main())
