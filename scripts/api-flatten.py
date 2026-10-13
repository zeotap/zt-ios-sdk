#!/usr/bin/env python3
"""Flatten a `swift-api-digester -dump-sdk` JSON into a reviewable API baseline.

The raw dump is ~390 KB of nested JSON. Committed as-is it is a file nobody reads,
which defeats the purpose: an API baseline earns its keep at REVIEW time, when a
diff has to make "you removed a public method" obvious to a human. Android's
`api/sdk.api` (binary-compatibility-validator) is one line per declaration for
exactly that reason, and this produces the same shape for Swift.

One line per public declaration:

    <declKind>\t<dotted path>\t<printedName>

sorted, so the diff of two runs is the API change and nothing else. `printedName`
is the digester's own rendering of the full signature, so a changed parameter
label or type shows up as a modified line rather than silently passing.

Excluded deliberately:
  * `Import` nodes — build-order noise, not API.
  * anything whose `moduleName` is not the module under test (conformances the
    digester attributes to Swift/Foundation).
  * `Constructor`/`Var` children of a node already printed are NOT excluded — a
    removed initializer or property is a breaking change.

Usage: api-flatten.py <dump.json> <module>
"""
import json
import sys


def walk(node, path, module, out):
    kind = node.get("declKind") or node.get("kind")
    name = node.get("name", "")
    if kind == "Import":
        return

    here = path
    if node.get("kind") != "Root":
        here = f"{path}.{name}" if path else name
        # `moduleName` marks who OWNS the declaration. Retroactive conformances
        # and stdlib members reachable through our types carry another module's
        # name and are not ours to freeze.
        if node.get("moduleName") == module:
            out.append(f"{kind}\t{here}\t{node.get('printedName', '')}")

    for child in node.get("children", []):
        walk(child, here, module, out)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    dump_path, module = sys.argv[1], sys.argv[2]
    with open(dump_path, encoding="utf-8") as handle:
        root = json.load(handle)["ABIRoot"]

    lines: list[str] = []
    walk(root, "", module, lines)
    if not lines:
        print(f"error: no declarations owned by module {module!r} — wrong module name?", file=sys.stderr)
        return 1

    # Sorted and de-duplicated: the digester can emit a declaration twice when it
    # is reachable by two paths, and an order that depends on traversal would make
    # every diff unreadable.
    for line in sorted(set(lines)):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
