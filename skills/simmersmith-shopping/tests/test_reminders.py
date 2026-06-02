"""Tests for the osascript output parser. The tab/linefeed shape must
survive reminder names that contain ", " (which the old comma-split
silently desynced)."""
import unittest

from simmersmith_shopping.reminders import _parse_osascript_output


class OsascriptParse(unittest.TestCase):
    def test_handles_comma_in_name(self):
        raw = "chicken, boneless\ttrue\nolive oil\tfalse\n"
        rows = list(_parse_osascript_output(raw))
        self.assertEqual(rows, [("chicken, boneless", True), ("olive oil", False)])

    def test_blank_lines_skipped(self):
        raw = "milk\tfalse\n\neggs\ttrue\n"
        rows = list(_parse_osascript_output(raw))
        self.assertEqual(rows, [("milk", False), ("eggs", True)])

    def test_empty_input(self):
        self.assertEqual(list(_parse_osascript_output("")), [])


if __name__ == "__main__":
    unittest.main()
