"""Copy app sources to a staging dir with #Preview blocks removed.

The macro plugin (PreviewsMacros.dylib) has an ABI mismatch with this Mac's
toolchain when driven from the command line, though it works in the Xcode GUI.
Stripping the preview blocks lets `swiftc -typecheck` cover every real source
file; previews contain no shipping logic.
"""
import pathlib
import re
import sys

src_root = pathlib.Path(sys.argv[1])
dst_root = pathlib.Path(sys.argv[2])
dst_root.mkdir(parents=True, exist_ok=True)

count = 0
for path in sorted(src_root.rglob("*.swift")):
    lines = path.read_text().splitlines(True)
    kept: list[str] = []
    i = 0
    while i < len(lines):
        if re.match(r"\s*#Preview", lines[i]):
            depth = 0
            while i < len(lines):
                depth += lines[i].count("{") - lines[i].count("}")
                i += 1
                if depth <= 0:
                    break
            continue
        kept.append(lines[i])
        i += 1
    flat = str(path.relative_to(src_root)).replace("/", "_")
    (dst_root / flat).write_text("".join(kept))
    count += 1

print(f"staged {count} files")
