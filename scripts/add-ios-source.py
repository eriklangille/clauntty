#!/usr/bin/env python3
"""Add a new Swift file to the iOS app target in Clauntty.xcodeproj.

The iOS project lists its files explicitly (the macOS project picks up new files
in shared folders by itself). The new file goes into the same group and Sources
phase as an existing file in the same folder.

Usage: python3 scripts/add-ios-source.py Clauntty/Core/Session/New.swift Session.swift
       (the new file, then an existing file next to it)
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(ROOT, "Clauntty.xcodeproj", "project.pbxproj")


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    new_path, sibling = sys.argv[1], sys.argv[2]
    name = os.path.basename(new_path)
    if not os.path.exists(os.path.join(ROOT, new_path)):
        raise SystemExit(f"{new_path} doesn't exist")
    if os.path.dirname(new_path) != os.path.dirname(new_path.replace(name, sibling)):
        raise SystemExit("the sibling must be in the same folder")

    s = open(PBXPROJ).read()
    if f"/* {name} */" in s:
        raise SystemExit(f"{name} is already in the project")

    # The sibling's file reference, build file, group entry and Sources entry.
    ref = re.search(rf"\t\t(\w+) /\* {re.escape(sibling)} \*/ = \{{isa = PBXFileReference;[^\n]*\n", s)
    build = re.search(rf"\t\t(\w+) /\* {re.escape(sibling)} in Sources \*/ = \{{isa = PBXBuildFile;[^\n]*\n", s)
    if not ref or not build:
        raise SystemExit(f"{sibling} isn't a source file in the project")
    if len(re.findall(rf"/\* {re.escape(sibling)} \*/ = \{{isa = PBXFileReference", s)) != 1:
        raise SystemExit(f"more than one {sibling}; pick a sibling with a unique name")

    used = set(re.findall(r"\b([0-9A-F]{24}|[0-9A-F]{8})\b", s))
    n = 1
    while f"AC1{n:021X}" in used or f"AC0{n:021X}" in used:
        n += 1
    new_ref, new_build = f"AC1{n:021X}", f"AC0{n:021X}"

    def after(match_text, text):
        nonlocal s
        if s.count(match_text) != 1:
            raise SystemExit(f"expected one {match_text.strip()!r}")
        s = s.replace(match_text, match_text + text)

    after(build.group(0), f"\t\t{new_build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {new_ref} /* {name} */; }};\n")
    after(ref.group(0), f'\t\t{new_ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n')
    after(f"\t\t\t\t{ref.group(1)} /* {sibling} */,\n", f"\t\t\t\t{new_ref} /* {name} */,\n")
    after(f"\t\t\t\t{build.group(1)} /* {sibling} in Sources */,\n", f"\t\t\t\t{new_build} /* {name} in Sources */,\n")

    open(PBXPROJ, "w").write(s)
    print(f"Added {name} next to {sibling}")


if __name__ == "__main__":
    main()
