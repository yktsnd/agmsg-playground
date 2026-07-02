"""Core text statistics: tokenization and aggregation."""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field

_WORD_RE = re.compile(r"[A-Za-z0-9']+")


@dataclass
class TextStats:
    """Aggregated statistics for a piece of text."""

    lines: int = 0
    words: int = 0
    chars: int = 0
    frequencies: Counter = field(default_factory=Counter)

    def top(self, n: int = 10) -> list[tuple[str, int]]:
        """Return the n most frequent words. Ties are broken alphabetically
        so the output is deterministic."""
        if n <= 0:
            return []
        ranked = sorted(self.frequencies.items(), key=lambda kv: (-kv[1], kv[0]))
        return ranked[:n]


def tokenize(text: str) -> list[str]:
    """Split text into lowercase word tokens.

    A word is a run of ASCII letters, digits, or apostrophes; everything
    else is a separator.
    """
    return [m.group(0).lower() for m in _WORD_RE.finditer(text)]


def analyze(text: str) -> TextStats:
    """Compute line/word/character counts and word frequencies for text."""
    words = tokenize(text)
    # splitlines() counts a trailing newline as ending a line, not starting
    # an empty one, which matches what people expect from `wc -l`-ish output.
    lines = len(text.splitlines())
    return TextStats(
        lines=lines,
        words=len(words),
        chars=len(text),
        frequencies=Counter(words),
    )
