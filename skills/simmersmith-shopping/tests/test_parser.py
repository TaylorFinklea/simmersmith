"""Smoke tests for the grocery title parser. Self-contained — no
Playwright, no Reminders, no network. Run with `python -m unittest`.
"""
import unittest

from simmersmith_shopping.parser import parse


class ParserSmoke(unittest.TestCase):
    def test_quantity_unit_name(self):
        line = parse("2 cups flour")
        self.assertEqual(line.quantity, 2.0)
        self.assertEqual(line.unit, "cups")
        self.assertEqual(line.name, "flour")

    def test_no_quantity(self):
        line = parse("paper towels")
        self.assertIsNone(line.quantity)
        self.assertEqual(line.unit, "")
        self.assertEqual(line.name, "paper towels")

    def test_no_unit(self):
        line = parse("3 lemons")
        self.assertEqual(line.quantity, 3.0)
        self.assertEqual(line.unit, "")
        self.assertEqual(line.name, "lemons")

    def test_mixed_fraction(self):
        line = parse("1 1/2 cups sugar")
        self.assertEqual(line.quantity, 1.5)
        self.assertEqual(line.unit, "cups")
        self.assertEqual(line.name, "sugar")

    def test_two_word_unit(self):
        line = parse("8 fl oz heavy cream")
        self.assertEqual(line.quantity, 8.0)
        self.assertEqual(line.unit, "fl oz")
        self.assertEqual(line.name, "heavy cream")

    def test_completed_propagates(self):
        line = parse("milk", completed=True)
        self.assertTrue(line.completed)


if __name__ == "__main__":
    unittest.main()
