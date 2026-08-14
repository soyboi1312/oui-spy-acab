#!/usr/bin/env python3
"""Print content-derived provenance for a Git working tree."""

import argparse
from pathlib import Path
import sys

from release_tools import ReleaseToolError, dirty_tree_digest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repo", nargs="?", default=".")
    parser.add_argument("--short", type=int, default=0)
    args = parser.parse_args()
    try:
        value = dirty_tree_digest(Path(args.repo))
    except ReleaseToolError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    if value is None:
        print("clean")
    elif args.short:
        if args.short < 4 or args.short > len(value):
            print("error: --short must be between 4 and 64", file=sys.stderr)
            return 2
        print(value[:args.short])
    else:
        print(value)
    return 0


if __name__ == "__main__":
    sys.exit(main())
