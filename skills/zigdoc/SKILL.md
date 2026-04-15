---
name: zigdoc
description: >-
  Query current Zig standard library and Zig module documentation with the `zigdoc` CLI before writing or reviewing Zig code. Use when Codex needs Zig API signatures, doc comments, public members, alias targets, source file/line clues, multi-symbol documentation queries, or a bridge from Zig symbol paths to local source navigation with `cx`.
---

## Execution Rules

- `zigdoc` is a **global CLI tool**. Run it directly; do not `cd` into this skill directory.
- Use `zigdoc` before relying on memory for Zig std APIs. Zig changes quickly.
- Quote grouped queries in the shell: `zigdoc 'std.foo.Type.(a, b)'`.
- Treat output paths such as `std/multi_array_list.zig:376` as source clues, not full filesystem paths.
- Do not ask for JSON output. `zigdoc` is a documentation tool; its default output is intended for humans and agents.

## Core Workflow

### 1. Query one symbol

```bash
zigdoc std.multi_array_list.MultiArrayList.insertBounded
```

Expected shape:

```text
std.multi_array_list.MultiArrayList.insertBounded at std/multi_array_list.zig:376
  sig: (self: *Self, index: usize, elem: T) error{OutOfMemory}!void
  docs:
    ...

hint: use cx with the shown file and line to inspect source
```

Use this to answer:

- exact function signatures and return types
- doc comments
- category/type information
- source file and line for follow-up inspection

### 2. Query multiple related members

Use grouped member syntax to keep context compact:

```bash
zigdoc 'std.multi_array_list.MultiArrayList.(insertBounded, appendAssumeCapacity, Slice.(get, set))'
```

Grouped queries expand relative to the prefix:

```text
std.multi_array_list.MultiArrayList.insertBounded
std.multi_array_list.MultiArrayList.appendAssumeCapacity
std.multi_array_list.MultiArrayList.Slice.get
std.multi_array_list.MultiArrayList.Slice.set
```

Each expanded symbol renders as the same result block used by single-symbol
queries:

```text
std.multi_array_list.MultiArrayList.Slice.get at std/multi_array_list.zig:124
  sig: (self: Slice, index: usize) T

std.multi_array_list.MultiArrayList.Slice.set at std/multi_array_list.zig:113
  sig: (self: *Slice, index: usize, elem: T) void
```

Prefer this when comparing APIs, checking bounded/assume-capacity pairs, or drilling into nested types.

### 3. Inspect members of a type

```bash
zigdoc std.multi_array_list.MultiArrayList.Slice
```

Use type/container queries to discover available fields, functions, nested types, and constants before guessing member names.
Function members include line, signature, and doc comments when present:

```text
functions:
  alloc (ln:197):
    sig: (self: Allocator, comptime T: type, n: usize) Error![]T
    docs:
      ...
```

## Combining With cx

Use `zigdoc` for **Zig symbol resolution and docs**; use `cx` for **source body and navigation**.

For a `zigdoc` clue like:

```text
std/multi_array_list.zig:124
```

derive the std source root:

```bash
zig env
```

Then inspect the source with `cx`:

```bash
cx d --root /opt/homebrew/Cellar/zig/0.16.0/lib/zig/std \
  --from /opt/homebrew/Cellar/zig/0.16.0/lib/zig/std/multi_array_list.zig \
  --name get \
  --max-lines 80
```

Current `cx d --name ... --from ...` can return multiple same-named symbols from one file. If that happens, use the line from `zigdoc` to choose the right result, or inspect a narrow source window around that line.

Do not invent `cx --at` or `cx symbol-at` unless that capability exists in the local `cx` help.

## Source Clue Expansion

For std paths:

```text
std/foo/bar.zig:LINE
```

map to:

```text
<std_dir>/foo/bar.zig:LINE
```

where `<std_dir>` comes from `zig env`.

For dependency/module paths, use the path shown by `zigdoc`. Build.zig analysis
tracks the current supported Zig line, currently Zig 0.16.x.

## Failure Handling

- `Symbol not found`: query the parent type/module first, then retry with the discovered member name.
- `UnsupportedZigVersion`: std queries may still work; install the Zig version supported by the current zigdoc release for build.zig dependency discovery.
- Empty docs for a function are acceptable. Rely on `sig` and source inspection.
- Long or ambiguous source lookup: use `zigdoc` for the exact line, then `cx o <file>` or `cx d --name <member> --from <file>` to narrow.

## Good Defaults

- Prefer `zigdoc std.foo.Type.(a, b, Nested.(c, d))` over many separate calls when the symbols share a parent.
- Keep quoted grouped queries in docs and shell examples.
- Preserve the `sig` exactly when citing APIs; Zig error unions and error sets are easy to misstate.
- Use the source line clue when making claims about implementation behavior, not just API shape.
