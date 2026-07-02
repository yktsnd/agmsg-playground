"""CLI entry point: python3 -m wordstats [FILE] [--top N]."""

from __future__ import annotations

import argparse
import sys

from wordstats.core import analyze


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="wordstats",
        description="Print line/word/char counts and the most frequent words.",
    )
    parser.add_argument(
        "file",
        nargs="?",
        help="input text file (reads stdin when omitted)",
    )
    parser.add_argument(
        "--top",
        type=int,
        default=10,
        metavar="N",
        help="number of most-frequent words to show (default: 10)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if args.file:
        try:
            with open(args.file, encoding="utf-8") as fh:
                text = fh.read()
        except OSError as exc:
            print(f"wordstats: cannot read {args.file}: {exc}", file=sys.stderr)
            return 1
    else:
        text = sys.stdin.read()

    stats = analyze(text)
    print(f"lines: {stats.lines}")
    print(f"words: {stats.words}")
    print(f"chars: {stats.chars}")

    top = stats.top(args.top)
    if top:
        print(f"top {len(top)} words:")
        width = max(len(word) for word, _ in top)
        for word, count in top:
            print(f"  {word:<{width}}  {count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
