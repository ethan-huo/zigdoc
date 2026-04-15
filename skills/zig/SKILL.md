---
name: zig
description: Up-to-date Zig programming language patterns for version 0.16.x. Use when writing, reviewing, or debugging Zig code, working with build.zig and build.zig.zon files, or using comptime metaprogramming. Critical for avoiding outdated patterns from training data - especially the std.Io interface (all I/O requires Io parameter), "Juicy Main" (std.process.Init), structured concurrency (io.async/io.concurrent/Group/Queue/Select/Batch with error.Canceled), @Type replacement (@Int/@Struct/@Union/@Enum), @cImport deprecation (use addTranslateC), fs.Dir/File migration to std.Io.Dir/File, process API redesign (spawn/run/replace), sync primitives migration (Thread.Mutex→Io.Mutex etc), mem.indexOf→find, container initialization (.empty/.init), fuzzer Smith interface, and removed features (async/await, usingnamespace, @intFromFloat, Thread.Pool, std.once, fs.getAppDataDir, posix mid-level wrappers).
---

# Zig Language Reference (v0.16.0)

Zig evolves rapidly. Training data contains outdated patterns that cause compilation errors. This skill documents breaking changes and correct modern patterns.

See **[Upgrade Guide: 0.15 → 0.16](references/upgrade-0.15-to-0.16.md)** for comprehensive migration steps.

## Critical: std.Io Interface (0.16.0)

**ALL I/O now requires an `Io` parameter.** This is the single biggest change in 0.16.

### "Juicy Main" — New Entry Point

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;       // pre-initialized allocator
    const io = init.io;         // I/O instance
    const arena = init.arena;   // permanent arena allocator

    try std.Io.File.stdout().writeStreamingAll(io, "Hello\n");

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    std.log.info("{d} env vars", .{init.environ_map.count()});
}
```

Three valid `main` signatures:
- `pub fn main() !void` — no args/env access
- `pub fn main(init: std.process.Init.Minimal) !void` — raw argv + environ
- `pub fn main(init: std.process.Init) !void` — full: gpa, io, arena, environ_map

### Getting Io Without Juicy Main

```zig
var threaded: std.Io.Threaded = .init_single_threaded;
const io = threaded.io();
```

For tests: use `std.testing.io`.

### Structured Concurrency

- `io.async(fn, args)` — create async task (portable, infallible; may run sequentially on single-threaded)
- `io.concurrent(fn, args)` — **require** true concurrency (can fail with `error.ConcurrencyUnavailable`)
- Both return `Future(T)` with `.await(io)` and `.cancel(io)` methods

```zig
// Future — async function call (correct defer pattern for resource cleanup)
var task = io.async(doWork, .{args});
defer if (task.cancel(io)) |resource| resource.deinit() else |_| {};
const result = try task.await(io);

// Group — many tasks, shared lifetime, O(1) overhead
var group: std.Io.Group = .init;
defer group.cancel(io);
for (items) |item| group.async(io, processItem, .{ io, item });
try group.await(io);
```

Also: `Queue(T)` (MPMC thread-safe), `Select` (wait for first completion), `Batch` (low-level operation concurrency).

**Cancelation** is a first-class concept: `error.Canceled` is in all I/O error sets. Use `task.cancel(io)` / `group.cancel(io)`. For long CPU-bound work: `io.checkCancel()`. To protect critical sections: `io.swapCancelProtection()`.

### Key Migrations

| 0.15 | 0.16 |
|------|------|
| `std.io` | `std.Io` (capital I) |
| `std.fs.Dir` / `std.fs.File` | `std.Io.Dir` / `std.Io.File` |
| `std.fs.cwd()` | `std.Io.Dir.cwd()` |
| `file.close()` | `file.close(io)` |
| `std.crypto.random` | `io.random(&buf)` / `io.randomSecure(&buf)` |
| `std.time.Instant` / `Timer` | `std.Io.Timestamp` |
| `std.Thread.Pool` | Removed — use `std.Io.Group` / `io.async` |
| `std.Thread.Mutex` | `std.Io.Mutex` |
| `std.Thread.Condition` | `std.Io.Condition` |
| `std.Thread.Semaphore` | `std.Io.Semaphore` |
| `std.Thread.RwLock` | `std.Io.RwLock` |
| `std.Thread.ResetEvent` | `std.Io.Event` |
| `std.Thread.WaitGroup` | `std.Io.Group` |
| `std.Thread.Futex` | `std.Io.Futex` |
| `std.once` | Removed — avoid globals or hand-roll |
| `std.os.environ` | `init.environ_map` from main |
| `std.process.getCwd` | `std.process.currentPath(io, buf)` |
| `std.process.Child.init` + `.spawn()` | `std.process.spawn(io, .{...})` |
| `std.process.Child.run` | `std.process.run(allocator, io, .{...})` |
| `std.process.execv` | `std.process.replace(io, .{...})` |
| `std.http.Client{.allocator=a}` | `std.http.Client{.allocator=a, .io=io}` |
| `std.mem.indexOf` | `std.mem.find` |
| `std.posix.*` (mid-level wrappers) | Removed — use `std.Io` or `std.posix.system` |
| `fs.getAppDataDir` | Removed — use [known-folders](https://github.com/ziglibs/known-folders) |
| `fs.File.Mode` | `std.Io.File.Permissions` |
| `fs.Dir.makeDir` | `std.Io.Dir.createDir` |
| `fs.Dir.atomicFile` | `std.Io.Dir.createFileAtomic` |
| `fs.openSelfExe` | `std.process.openExecutable` |
| Fuzz `[]const u8` param | `*std.testing.Smith` |

## Critical: Removed & Deprecated Features

### `usingnamespace` - REMOVED (0.15+)
```zig
// WRONG — use explicit re-exports
const other = @import("other.zig");
pub const foo = other.foo;
```

### `async`/`await` - REMOVED (0.15+)
Keywords removed. Concurrency now via `std.Io` (Future, Group, Batch).

### `@Type` - REMOVED (0.16.0)
Replaced with individual builtins:
```zig
// WRONG
@Type(.{ .int = .{ .signedness = .unsigned, .bits = 10 } })

// CORRECT
@Int(.unsigned, 10)
```

| Old | New |
|-----|-----|
| `@Type(.{ .int = ... })` | `@Int(signedness, bits)` |
| `@Type(.enum_literal)` | `@EnumLiteral()` |
| `@Type(.{ .@"struct" = ... })` | `@Struct(layout, BackingInt, names, types, attrs)` |
| `@Type(.{ .@"union" = ... })` | `@Union(layout, TagType, names, types, attrs)` |
| `@Type(.{ .@"enum" = ... })` | `@Enum(TagInt, mode, names, values)` |
| `@Type(.{ .pointer = ... })` | `@Pointer(size, attrs, Element, sentinel)` |
| `@Type(.{ .@"fn" = ... })` | `@Fn(param_types, param_attrs, ReturnType, attrs)` |
| `std.meta.Tuple` | `@Tuple(&.{ T1, T2 })` |

No `@Float`, `@Array`, `@Opaque`, `@Optional`, `@ErrorUnion`, `@ErrorSet` — use literal syntax.
Error sets can **no longer be reified** — use `error{ ... }` syntax.

### `@intFromFloat` - DEPRECATED (0.16.0)
Use `@trunc` instead. `@floor`/`@ceil`/`@round`/`@trunc` now convert float → int directly:
```zig
const x: u8 = @trunc(value);   // truncate toward zero
const y: u8 = @round(value);   // round to nearest
```

### `@cImport` - DEPRECATED (0.16.0)
Move to build system:
```zig
// build.zig
const translate_c = b.addTranslateC(.{
    .root_source_file = b.path("src/c.h"),
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("c", translate_c.createModule());

// source
const c = @import("c");
```

### `GenericReader`/`AnyReader`/`FixedBufferStream` - REMOVED (0.16.0)
```zig
// Use std.Io.Reader / std.Io.Writer directly
var r: std.Io.Reader = .fixed(data);
var w: std.Io.Writer = .fixed(buffer);
```

### `std.Thread.Pool` - REMOVED (0.16.0)
Use `std.Io.Group` / `io.async` instead.

### `std.heap.ThreadSafe` - REMOVED (0.16.0)
ArenaAllocator is now thread-safe and lock-free by default.

## Critical: I/O Reader/Writer API

`std.Io.Writer` and `std.Io.Reader` are **non-generic** with buffer in the interface.

### Writing to stdout
```zig
try std.Io.File.stdout().writeStreamingAll(io, "Hello\n");
```

### Buffered file writing
```zig
var buf: [4096]u8 = undefined;
var file_writer = file.writer(io, &buf);
try file_writer.interface.print("value: {d}\n", .{42});
try file_writer.flush();
```

### Reading from file
```zig
var buf: [4096]u8 = undefined;
var file_reader = file.reader(io, &buf);
const r = &file_reader.interface;

while (try r.takeDelimiter('\n')) |line| {
    // process line
}
```

### Fixed Buffer (no file)
```zig
var buf: [256]u8 = undefined;
var w: std.Io.Writer = .fixed(&buf);
try w.print("Hello {s}", .{"world"});
const result = w.buffered();

var r: std.Io.Reader = .fixed("hello\nworld");
const line = (try r.takeDelimiter('\n')).?;
```

## Critical: Build System

### Module-based builds (0.15+)
```zig
b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

### C translation (0.16.0)
```zig
const translate_c = b.addTranslateC(.{
    .root_source_file = b.path("src/c.h"),
    .target = target,
    .optimize = optimize,
});
translate_c.linkSystemLibrary("mylib", .{});
exe.root_module.addImport("c", translate_c.createModule());
```

### Package management changes (0.16.0)
- Packages fetched to **project-local `zig-pkg/`** (not global cache)
- `build.zig.zon` **fingerprint field required**
- `zig build --fork=[path]` for local package overrides
- `--test-timeout 500ms` for unit test timeouts
- `--error-style minimal` replaces `--prominent-compile-errors`

See **[std.Build reference](references/std-build.md)** for complete build system documentation.

## Critical: Container Initialization

**Never use `.{}` for containers.** Use `.empty` or `.init`:

```zig
var list: std.ArrayList(u32) = .empty;
var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
var gpa: std.heap.DebugAllocator(.{}) = .init;
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
```

### Naming Changes (0.15+)
- **`std.ArrayListUnmanaged` → `std.ArrayList`** (Unmanaged is now default)
- **`std.heap.GeneralPurposeAllocator` → `std.heap.DebugAllocator`**

### Container Renames (0.16.0)
- `ArrayHashMap`/`AutoArrayHashMap`/`StringArrayHashMap` — **removed**
- `AutoArrayHashMapUnmanaged` → `array_hash_map.Auto`
- `StringArrayHashMapUnmanaged` → `array_hash_map.String`
- PriorityQueue/PriorityDequeue: `init` → `.empty`, `add` → `push`, `remove` → `pop`

## Critical: Format Strings

`{f}` required to call format methods:
```zig
std.debug.print("{f}", .{std.zig.fmtId("x")});
```

Format method signature:
```zig
pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void
```

## Language Features

### Packed Type Changes (0.16.0)
- **Pointers forbidden** in packed structs/unions — use `usize` + `@ptrFromInt`
- **Unused bits forbidden** in packed unions — all fields must have same `@bitSizeOf`
- **Explicit backing type required** in extern contexts — `enum(u8)`, `packed struct(u8)`
- Explicit backing integers now allowed on packed unions — `packed union(u16)`

### Small Int → Float Coercion (0.16.0)
```zig
var x: u24 = 123;
var f: f32 = x;  // OK — u24 fits in f32 significand; u25+ still needs @floatFromInt
```

### Float Builtins Forward Result Type (0.16.0)
```zig
const x: f64 = @sqrt(@floatFromInt(N));  // f64 forwarded through @sqrt
```

### Local Address Returns — Compile Error (0.16.0)
```zig
fn foo() *i32 {
    var x: i32 = 1234;
    return &x;  // error: returning address of expired local variable
}
```

### Runtime Vector Indexes Forbidden (0.16.0)
Coerce vector to array before indexing with runtime values.

### Decl Literals (0.14.0+)
```zig
const a: S = .default;      // S.default
const b: S = .init(42);     // S.init(42)
```

### Labeled Switch (0.14.0+)
```zig
state: switch (initial) {
    .idle => continue :state .running,
    .running => if (done) break :state result else continue :state .running,
    .error => return error.Failed,
}
```

### Other 0.14.0+ Changes
- `@branchHint(.cold)` replaces `@setCold(true)`
- `@export(&foo, .{ .name = "bar" })` — takes pointer
- `@fence` removed — use stronger atomic orderings
- Inline asm clobbers are typed: `.{ .rcx = true, .r11 = true }`

## Quick Fixes

| Error | Fix |
|-------|-----|
| `no field 'root_source_file'` | Use `root_module = b.createModule(.{...})` |
| `returning address of expired local variable` | Heap-allocate or accept caller buffer |
| `@Type` deprecated / removed | Use `@Int`, `@Struct`, `@Union`, `@Enum`, `@Pointer`, `@Fn`, `@Tuple` |
| `@intFromFloat` deprecated | Use `@trunc` (or `@round`, `@floor`, `@ceil`) |
| `@cImport` deprecated | Move to `b.addTranslateC()` in build.zig |
| `ambiguous format string` | Use `{f}` for format methods |
| `use of undefined value` | Arithmetic on `undefined` is now illegal |
| `unable to export type` (implicit backing) | Add explicit backing type: `enum(u8)`, `packed struct(u8)` |
| `pointers not allowed in packed struct` | Use `usize` + `@ptrFromInt`/`@intFromPtr` |
| `std.Thread.Pool` not found | Use `std.Io.Group` / `io.async` |
| `std.fs.Dir` / `std.fs.File` | Use `std.Io.Dir` / `std.Io.File` |
| `std.io.getStdOut` | Use `std.Io.File.stdout()` |
| `std.process.getCwd` | Use `std.process.currentPath(io, buf)` |
| `std.process.Child.init` | Use `std.process.spawn(io, .{...})` |
| `std.process.execv` | Use `std.process.replace(io, .{...})` |
| `std.mem.indexOf` | Use `std.mem.find` |
| `fs.getAppDataDir` | Removed — use `known-folders` package |
| `std.crypto.random` | Use `io.random(&buf)` or `std.Random.IoSource` |
| `std.once` | Removed — hand-roll or avoid globals |
| `builtin.subsystem` | Removed — determine at runtime if needed |
| `sanitize_c = true` | Use `.full`, `.trap`, or `.off` |
| `std.fmt.Formatter` | Renamed to `std.fmt.Alt` |
| `FileTooBig` from readFileAlloc | Now `StreamTooLong`; param order changed |

## New APIs in 0.16 (Not in Training Data)

These APIs **did not exist before 0.16** — agents cannot know about them from training data.

| API | Purpose |
|-----|---------|
| `std.Io` | All I/O now goes through this interface — see above |
| `std.process.Init` | "Juicy Main" — pre-initialized gpa, io, arena, environ_map |
| `io.async` / `io.concurrent` | Structured concurrency (replaces async/await keywords) |
| `std.Io.Group` | Manage many concurrent tasks with shared lifetime |
| `std.Io.Queue(T)` | MPMC thread-safe queue with suspend/resume |
| `std.Io.Select` | Wait for first of multiple tasks to complete |
| `std.Io.Batch` | Low-level operation concurrency (FileRead/WriteStreaming, NetReceive) |
| `std.Io.Dir.walkSelectively` | Filtered recursive walk — skip directories without open/close overhead |
| `std.Io.Dir.createFileAtomic` | Atomic file writes (O_TMPFILE on Linux) with `.replace(io)` or `.link(io)` |
| `std.Io.File.MemoryMap` | Memory-mapped file I/O with explicit sync points |
| `std.Random.IoSource` | RNG via Io: `.{ .io = io }` then `.interface()` |
| `io.randomSecure(&buf)` | Crypto-secure entropy (always syscall, no process state) |
| `std.process.spawn(io, .{})` | New child process API (replaces `Child.init` + `.spawn()`) |
| `std.process.replace(io, .{})` | Replace process image (replaces `execv`) |
| `std.compress.flate` | Deflate **compression** added (was decompression-only) |
| `std.testing.Smith` | Fuzzer input interface: `.value(T)`, `.eos()`, `.bytes()`, `.slice()` |
| `std.mem.cut*` | `cut`, `cutPrefix`, `cutSuffix`, `cutScalar`, `cutLast`, `cutLastScalar` |
| `std.debug.captureCurrentStackTrace` | Reworked debug API with `StackUnwindOptions` |
| `std.Io.Dir.hardLink` | Hard link creation; `File.NLink` for link count |
| `std.process.lockMemory` | Memory locking with type-safe flags (was `posix.mlock`) |
| `std.crypto` | AES-SIV, AES-GCM-SIV (nonce-reuse resistant), Ascon family (NIST SP 800-232) |
| `std.Io.Clock` / `Duration` / `Timeout` | Type-safe time units |

### Io Implementations

| Implementation | Status | Use |
|----------------|--------|-----|
| `Io.Threaded` | **Production-ready** | Thread-based; chosen by Juicy Main |
| `Io.Evented` | Experimental WIP | M:N threading / green threads / stackful coroutines |
| `Io.Uring` | Proof-of-concept | Linux io_uring backend |
| `Io.Kqueue` | Proof-of-concept | BSD/macOS kqueue backend |
| `Io.Dispatch` | Proof-of-concept | macOS Grand Central Dispatch backend |
| `Io.failing` | Complete | Simulates system with no I/O — for testing |

## Standard Library: Use `zigdoc`

**For standard library API details, use `zigdoc <symbol>` instead of loading references.** It provides up-to-date documentation for any std symbol and imported modules:

```
zigdoc std.ArrayList
zigdoc std.mem.Allocator
zigdoc std.Io.Dir
zigdoc std.heap.ArenaAllocator
```

The references below cover what zigdoc cannot: language semantics, patterns, pitfalls, and migration guidance.

## References

### Language
- **[Language Basics](references/language.md)** — types, control flow, error handling, optionals, structs, enums, unions, pointers, slices, comptime
- **[Built-in Functions](references/builtins.md)** — all `@` builtins including type creators (`@Int`, `@Struct`, `@Union`, `@Enum`, `@Pointer`, `@Fn`, `@Tuple`)
- **[Comptime](references/comptime.md)** — type reflection, type creation (0.16: `@Type` removed), loop variants, branch elimination
- **[Style Guide](references/style-guide.md)** — naming conventions, `zig fmt`, doc comments

### Patterns & Review
- **[Zig Patterns](references/patterns.md)** — **Load when writing new code.** Idioms for memory, I/O, closures, generics, polymorphism, safety, performance
- **[Code Review](references/code-review.md)** — **Load when reviewing code.** Confidence-ranked checklist: always-flag vs suggest. Includes 0.14/0.15/0.16 migration examples
- **[Memory Management](references/memory-management.md)** — ownership rules, arena patterns, dangling pointer pitfalls, iterator invalidation, defer/errdefer, HashMap memory, C FFI boundaries, leak detection
- **[Allocator Selection](references/std-allocators.md)** — which allocator to choose, naming conventions (gpa/arena/scratch), common compositions

### Build & Interop
- **[std.Build](references/std-build.md)** — build.zig, modules, dependencies, build.zig.zon, steps, options, C/C++ integration
- **[C Interop](references/c-interop.md)** — `export fn`, static/dynamic libs, headers, XCFramework. In 0.16: `@cImport` deprecated → `addTranslateC`

### Migration
- **[Upgrade 0.15 → 0.16](references/upgrade-0.15-to-0.16.md)** — **Load when upgrading.** std.Io interface, Juicy Main, concurrency/cancelation, fs→Io migration, process API, container renames, @Type→builtins, fuzzer Smith, build system changes, full checklist
