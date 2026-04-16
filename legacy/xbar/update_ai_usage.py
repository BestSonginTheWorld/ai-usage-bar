#!/usr/bin/env python3
from ai_usage_collector import main
import sys


if __name__ == "__main__":
    raise SystemExit(main(["update", *sys.argv[1:]]))
