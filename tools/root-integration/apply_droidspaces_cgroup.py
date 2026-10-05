#!/usr/bin/env python3
"""Apply/verify the compatible DroidSpaces non-GKI cgroup patch for this tree.

This is the style-adjusted equivalent of Droidspaces-OSS commit
50cb2ccbef7d84852f2600bb4d3e69f6bd736561. It adds controller-prefixed links
for cgroup files on CGRP_ROOT_NOPREFIX mounts, as expected by LXC consumers.

Usage:
    python3 tools/root-integration/apply_droidspaces_cgroup.py [--verify] [kernel-tree]
"""

import argparse
from pathlib import Path
import sys


ANCHOR = """\t}

\treturn 0;"""

PATCH = """\tif (cft->ss && (cgrp->root->flags & CGRP_ROOT_NOPREFIX) &&
\t    !(cft->flags & CFTYPE_NO_PREFIX)) {
\t\tsnprintf(name, CGROUP_FILE_NAME_MAX, "%s.%s",
\t\t\t cft->ss->name, cft->name);
\t\tkernfs_create_link(cgrp->kn, name, kn);
\t}

"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true", help="check without modifying files")
    parser.add_argument("tree", nargs="?", default=".", help="kernel source tree (default: .)")
    args = parser.parse_args()

    root = Path(args.tree).resolve()
    path = root / "kernel/cgroup/cgroup.c"
    if not path.is_file():
        print(f"error: missing {path}", file=sys.stderr)
        return 1

    text = path.read_text(encoding="utf-8")
    start = text.find("static int cgroup_add_file(")
    if start < 0:
        print("error: cgroup_add_file() anchor not found", file=sys.stderr)
        return 1
    end = text.find("\n}\n", start)
    if end < 0:
        print("error: cgroup_add_file() body is unterminated", file=sys.stderr)
        return 1
    end += 3
    function = text[start:end]

    if function.count(PATCH) == 1:
        print("DroidSpaces cgroup controller-prefix patch is present")
        return 0
    if "kernfs_create_link(cgrp->kn, name, kn);" in function:
        print("error: cgroup_add_file() contains an unexpected/partial compatibility patch", file=sys.stderr)
        return 1
    if args.verify:
        print("error: DroidSpaces cgroup controller-prefix patch is missing", file=sys.stderr)
        return 1
    if function.count(ANCHOR) != 1:
        print("error: expected cgroup_add_file() insertion anchor exactly once", file=sys.stderr)
        return 1

    patched_function = function.replace(ANCHOR, "	}\n\n" + PATCH + "	return 0;", 1)
    path.write_text(text[:start] + patched_function + text[end:], encoding="utf-8")
    print("Applied DroidSpaces cgroup controller-prefix patch")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
