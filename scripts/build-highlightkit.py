#!/usr/bin/env python3
"""Build HighlightKit.xcframework: tree-sitter, the grammars and their highlight queries.

Everything is pinned in HighlightKit/grammars.json: tree-sitter itself, nvim-treesitter (whose
queries we use, and whose parsers.lua pins each grammar at the revision its queries are written
for) and each grammar. The grammars' parser.c files are big (SQL's and C++'s take a while to
compile), so this runs once and both apps link the result, like GhosttyKit.

    python3 scripts/build-highlightkit.py            # fetch what's missing, build
    python3 scripts/build-highlightkit.py --clean    # fetch and build everything again

Sources go to build/highlightkit/src, the framework to build/highlightkit/HighlightKit.xcframework
(Frameworks/HighlightKit.xcframework links there). The queries are compiled in as C strings,
with Neovim's `; inherits:` resolved (the inherited files first, so the language's own patterns
come later and win), so a grammar and its query can't get out of step.
"""

import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KIT = os.path.join(ROOT, "HighlightKit")
OUT = os.path.join(ROOT, "build", "highlightkit")
SRC = os.path.join(OUT, "src")

# The slices the apps need: the phone, the simulator on Apple silicon, and the Mac's two
# architectures (Release builds both)
SLICES = {
    "ios-arm64": ("iphoneos", ["arm64"], "-mios-version-min=17.0"),
    "ios-arm64-simulator": ("iphonesimulator", ["arm64"], "-mios-simulator-version-min=17.0"),
    "macos-arm64_x86_64": ("macosx", ["arm64", "x86_64"], "-mmacosx-version-min=14.0"),
}


def run(cmd, cwd=None, quiet=True):
    result = subprocess.run(cmd, cwd=cwd, capture_output=quiet, text=True)
    if result.returncode != 0:
        if quiet:
            sys.stderr.write(result.stdout + result.stderr)
        raise SystemExit(f"failed: {' '.join(cmd)}")
    return result.stdout if quiet else ""


def fetch(name, url, revision, sparse=None):
    """A repository at one revision (a commit or a tag), fetched once"""
    path = os.path.join(SRC, name)
    stamp = os.path.join(path, ".highlightkit-revision")
    if os.path.exists(stamp) and open(stamp).read() == revision:
        return path
    shutil.rmtree(path, ignore_errors=True)
    os.makedirs(path)
    run(["git", "init", "-q"], cwd=path)
    run(["git", "remote", "add", "origin", url], cwd=path)
    if sparse:
        run(["git", "config", "core.sparseCheckout", "true"], cwd=path)
        with open(os.path.join(path, ".git", "info", "sparse-checkout"), "w") as f:
            f.write("\n".join(sparse) + "\n")
    run(["git", "fetch", "-q", "--depth", "1", "origin", revision], cwd=path)
    run(["git", "checkout", "-q", "FETCH_HEAD"], cwd=path)
    with open(stamp, "w") as f:
        f.write(revision)
    return path


def query(queries, language, kind, seen=()):
    """A language's query file with Neovim's `; inherits: a,b` resolved: those first"""
    path = os.path.join(queries, "runtime", "queries", language, f"{kind}.scm")
    if not os.path.exists(path):
        return ""
    text = open(path).read()
    match = re.search(r"^;+ *inherits *: *(.*)$", text, re.M)
    parts = []
    if match:
        for parent in match.group(1).split(","):
            parent = parent.strip()
            if parent and parent not in seen:
                parts.append(query(queries, parent, kind, seen + (language,)))
    parts.append(text)
    return "\n".join(p for p in parts if p)


def c_string(text):
    """A C string literal, split into lines so the generated file stays readable"""
    lines = text.split("\n")
    out = []
    for i, line in enumerate(lines):
        escaped = line.replace("\\", "\\\\").replace('"', '\\"').replace("?", "\\?")
        out.append('"' + escaped + ("\\n" if i < len(lines) - 1 else "") + '"')
    return "\n    ".join(out)


def main():
    pins = json.load(open(os.path.join(KIT, "grammars.json")))
    if "--clean" in sys.argv:
        shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(SRC, exist_ok=True)

    print("Fetching tree-sitter, the queries and the grammars...")
    core = fetch("tree-sitter", pins["tree_sitter"]["url"], pins["tree_sitter"]["revision"], ["lib/"])
    queries = fetch("nvim-treesitter", pins["queries"]["url"], pins["queries"]["revision"], ["runtime/queries/"])
    languages = pins["languages"]
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        repos = list(pool.map(lambda l: fetch("grammar-" + l["name"], l["url"], l["revision"]), languages))

    # The grammar table, with each language's queries compiled in
    gen = os.path.join(OUT, "generated")
    os.makedirs(gen, exist_ok=True)
    table = ['#include "HighlightKit.h"', ""]
    for lang in languages:
        table.append(f"const TSLanguage *tree_sitter_{lang['name']}(void);")
    table.append("")
    for lang in languages:
        name = lang["name"]
        for kind in ("highlights", "injections"):
            text = query(queries, name, kind)
            table.append(f"static const char {name}_{kind}[] =\n    {c_string(text)};\n")
    table.append("static const HKGrammar hk_grammars[] = {")
    for lang in languages:
        name = lang["name"]
        extensions = " ".join(lang.get("extensions", []))
        filenames = " ".join(lang.get("filenames", []))
        table.append(f'    {{ "{name}", tree_sitter_{name}, {name}_highlights, {name}_injections, "{extensions}", "{filenames}" }},')
    table.append("};")
    table.append(f"const unsigned hk_grammar_count = {len(languages)};")
    table.append("const HKGrammar *hk_grammar(unsigned index) { return &hk_grammars[index]; }")
    with open(os.path.join(gen, "hk_grammars.c"), "w") as f:
        f.write("\n".join(table) + "\n")

    # What to compile: tree-sitter, each grammar's parser and scanner, the table
    units = [(os.path.join(core, "lib", "src", "lib.c"), [os.path.join(core, "lib", "include"), os.path.join(core, "lib", "src")])]
    for lang, repo in zip(languages, repos):
        src = os.path.join(repo, lang.get("location", ""), "src")
        for name in ("parser.c", "scanner.c"):
            if os.path.exists(os.path.join(src, name)):
                units.append((os.path.join(src, name), [src]))
    units.append((os.path.join(gen, "hk_grammars.c"), [os.path.join(KIT, "include"), os.path.join(core, "lib", "include")]))

    # In a folder of their own: Xcode copies every static xcframework's headers into one
    # include directory, where GhosttyKit's module.modulemap is already
    headers = os.path.join(OUT, "headers")
    shutil.rmtree(headers, ignore_errors=True)
    own = os.path.join(headers, "HighlightKit")
    os.makedirs(os.path.join(own, "tree_sitter"))
    shutil.copy(os.path.join(core, "lib", "include", "tree_sitter", "api.h"), os.path.join(own, "tree_sitter"))
    shutil.copy(os.path.join(KIT, "include", "HighlightKit.h"), own)
    shutil.copy(os.path.join(KIT, "include", "module.modulemap"), own)

    libraries = []
    for slice_name, (sdk, archs, min_version) in SLICES.items():
        thin = []
        for arch in archs:
            print(f"Compiling {len(units)} files for {slice_name} ({arch})...")
            obj_dir = os.path.join(OUT, "obj", slice_name, arch)
            os.makedirs(obj_dir, exist_ok=True)

            def compile_unit(unit, i):
                path, includes = unit
                obj = os.path.join(obj_dir, f"{i:03d}-{os.path.basename(os.path.dirname(os.path.dirname(path)))}-{os.path.basename(path)}.o")
                if os.path.exists(obj) and os.path.getmtime(obj) > os.path.getmtime(path):
                    return obj
                cmd = ["xcrun", "-sdk", sdk, "clang", "-c", "-O2", "-std=c11", "-arch", arch, min_version,
                       "-w", "-fno-common", "-o", obj, path]
                for inc in includes:
                    cmd += ["-I", inc]
                run(cmd)
                return obj

            with concurrent.futures.ThreadPoolExecutor(os.cpu_count()) as pool:
                objects = list(pool.map(compile_unit, units, range(len(units))))
            lib = os.path.join(OUT, "lib", slice_name, arch, "libHighlightKit.a")
            os.makedirs(os.path.dirname(lib), exist_ok=True)
            if os.path.exists(lib):
                os.remove(lib)
            run(["xcrun", "libtool", "-static", "-o", lib] + objects)
            thin.append(lib)
        lib = os.path.join(OUT, "lib", slice_name, "libHighlightKit.a")
        if len(thin) > 1:
            run(["xcrun", "lipo", "-create", "-output", lib] + thin)
        else:
            shutil.copy(thin[0], lib)
        libraries.append(lib)

    framework = os.path.join(OUT, "HighlightKit.xcframework")
    shutil.rmtree(framework, ignore_errors=True)
    cmd = ["xcodebuild", "-create-xcframework", "-output", framework]
    for lib in libraries:
        cmd += ["-library", lib, "-headers", headers]
    run(cmd)
    print(f"Built {framework}")


if __name__ == "__main__":
    main()
