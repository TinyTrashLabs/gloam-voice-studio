#!/usr/bin/env python3
"""Print the resource id of the first `asc ... --output json` row whose
attribute matches.

Usage: _asc_pick.py <attribute> <value>

Reads the listing on stdin. Exists as a file rather than `python3 -c` inline
because quoting a script through zsh inside a command substitution is how
`GID=` -- one of zsh's own special parameters -- silently became a setgid
attempt reported as "bad floating point constant".
"""
import json
import sys


def main():
    if len(sys.argv) != 3:
        return 2
    attribute, wanted = sys.argv[1], sys.argv[2]
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    rows = payload if isinstance(payload, list) else \
        payload.get("data", payload.get("results", []))
    for row in rows:
        if row.get("attributes", row).get(attribute) == wanted:
            print(row.get("id"))
            return 0
    # "Not found" is a normal answer here -- the group may not exist yet, and a
    # non-zero exit inside a `set -e` command substitution kills the caller
    # silently. Callers test for an empty string instead.
    return 0


if __name__ == "__main__":
    sys.exit(main())
