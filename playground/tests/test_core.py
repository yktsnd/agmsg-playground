import unittest

from wordstats.core import analyze, tokenize


class TokenizeTests(unittest.TestCase):
    def test_lowercases_and_splits_on_punctuation(self):
        self.assertEqual(tokenize("Hello, World!"), ["hello", "world"])

    def test_keeps_apostrophes_and_digits(self):
        self.assertEqual(tokenize("don't stop 42 times"), ["don't", "stop", "42", "times"])

    def test_empty_text(self):
        self.assertEqual(tokenize(""), [])


class AnalyzeTests(unittest.TestCase):
    def test_counts(self):
        stats = analyze("one two two\nthree\n")
        self.assertEqual(stats.lines, 2)
        self.assertEqual(stats.words, 4)
        self.assertEqual(stats.chars, len("one two two\nthree\n"))
        self.assertEqual(stats.frequencies["two"], 2)

    def test_trailing_newline_does_not_add_a_line(self):
        self.assertEqual(analyze("a\nb").lines, 2)
        self.assertEqual(analyze("a\nb\n").lines, 2)

    def test_empty_text(self):
        stats = analyze("")
        self.assertEqual((stats.lines, stats.words, stats.chars), (0, 0, 0))
        self.assertEqual(stats.top(), [])


class TopTests(unittest.TestCase):
    def test_orders_by_count_then_alphabetically(self):
        stats = analyze("b b a a c")
        self.assertEqual(stats.top(3), [("a", 2), ("b", 2), ("c", 1)])

    def test_limits_to_n(self):
        stats = analyze("a b c d e")
        self.assertEqual(len(stats.top(2)), 2)

    def test_nonpositive_n_returns_empty(self):
        stats = analyze("a b c")
        self.assertEqual(stats.top(0), [])
        self.assertEqual(stats.top(-1), [])


if __name__ == "__main__":
    unittest.main()
