"""Smoke tests for the store-split heuristic."""
import unittest

from simmersmith_shopping.splitter import Candidate, split


class SplitterSmoke(unittest.TestCase):
    def test_single_store_when_one_dominates(self):
        # Aldi is cheapest on every item, total $50 — clears the $35 minimum.
        items = [
            [Candidate("aldi", 20, True), Candidate("walmart", 25, True)],
            [Candidate("aldi", 30, True), Candidate("walmart", 35, True)],
        ]
        result = split(items, minimums={"aldi": 35, "walmart": 35})
        self.assertEqual(set(a.store for a in result.assignments), {"aldi"})
        self.assertEqual(result.total, 50.0)

    def test_two_store_when_under_minimum(self):
        # Aldi cheaper but only $20 total — under minimum. Should fall
        # back to whichever single-store option meets the $35 floor.
        items = [
            [Candidate("aldi", 10, True), Candidate("walmart", 18, True)],
            [Candidate("aldi", 10, True), Candidate("walmart", 20, True)],
        ]
        result = split(items, minimums={"aldi": 35, "walmart": 35}, max_stops=1)
        self.assertEqual(result.unassigned_indices, [])
        # We don't care which store wins; just that ONE store is used
        # and the result is well-formed (greedy fallback when no
        # combination meets minimums).
        self.assertEqual(len(result.assignments), 2)

    def test_does_not_pick_a_cheaper_incomplete_split(self):
        # greedy uses 3 stores (> max_stops=2), forcing the combination
        # search. A 1-store {aldi} combo would strand items 0 and 2 yet
        # look cheap (total counts only assigned items). The fix must keep
        # the complete 2-store split instead of dropping items.
        items = [
            [Candidate("walmart", 8, True)],                       # only walmart
            [Candidate("aldi", 3, True)],                          # only aldi
            [Candidate("sams_club", 2, True), Candidate("walmart", 10, True)],
        ]
        result = split(items, minimums={}, max_stops=2, stop_penalty=5.0)
        self.assertEqual(result.unassigned_indices, [])
        self.assertEqual(len(result.assignments), 3)


if __name__ == "__main__":
    unittest.main()
