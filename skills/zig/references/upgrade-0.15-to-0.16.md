# Upgrading from Zig 0.15 to 0.16

Comprehensive migration guide. Zig 0.16.0 is a massive release (244 contributors, 1183 commits) with one paradigm-shifting change: **all I/O now requires an `Io` instance**. Most other changes are mechanical renames.

## Migration Priority

1. **`std.Io` interface** — the biggest change; touches every file that does I/O
2. **"Juicy Main"** — new `main` function signature
3. **`@Type` → individual builtins** — affects comptime metaprogramming
4. **`@cImport` deprecated** — move C translation to build system
5. **Container API renames** — mechanical but widespread
6. **Language tightening** — packed types, vector indexes, local address returns

---

## 1. "Juicy Main" — New Entry Point

`main` now accepts a `std.process.Init` parameter that provides pre-initialized allocator, I/O, arena, env vars:

```zig
// 0.15
const std = @import("std");
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();  // old API
    // ...
}

// 0.16
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;       // pre-initialized allocator
    const io = init.io;         // I/O instance
    const arena = init.arena;   // permanent arena

    try std.Io.File.stdout().writeStreamingAll(io, "Hello\n");
    // ...
}
```

Three valid `main` signatures:
- `pub fn main() !void` — no args/env access
- `pub fn main(init: std.process.Init.Minimal) !void` — raw argv + environ
- `pub fn main(init: std.process.Init) !void` — full: gpa, io, arena, environ_map, preopens

### Getting `Io` Without Juicy Main

If you can't change `main` yet or need `Io` in a library context:

```zig
var threaded: std.Io.Threaded = .init_single_threaded;
const io = threaded.io();
```

For tests: use `std.testing.io` (like `std.testing.allocator`).

---

## 2. std.Io Interface — The Big One

**Every function that does I/O now requires an `Io` parameter.** This is the single largest change — your diff will be large but mechanical.

### Typical Pattern

```zig
// 0.15
file.close();
dir.openFile("foo.txt", .{});
std.fs.cwd();

// 0.16
file.close(io);
dir.openFile(io, "foo.txt", .{});
std.Io.Dir.cwd();
```

### Concurrency Primitives

`std.Io` provides Future, Group, Batch, Queue, and Select for structured concurrency:

- `io.async(fn, args)` — portable async task (may execute sequentially on single-threaded)
- `io.concurrent(fn, args)` — **requires** true concurrency (fails with `error.ConcurrencyUnavailable` if unavailable)
- Both return `Future(T)` with `.await(io)` and `.cancel(io)`

```zig
// Future — correct defer pattern for resource cleanup
var task = io.async(doWork, .{args});
defer if (task.cancel(io)) |resource| resource.deinit() else |_| {};
const result = try task.await(io);

// Group — many tasks, shared lifetime, O(1) overhead
var group: std.Io.Group = .init;
defer group.cancel(io);
for (items) |item| group.async(io, processItem, .{ io, item });
try group.await(io);
```

Also available:
- `Queue(T)` — many producer, many consumer, thread-safe, runtime configurable buffer
- `Select` — execute tasks together, wait for one or more to complete
- `Batch` — low-level operation concurrency (`FileReadStreaming`, `FileWriteStreaming`, `DeviceIoControl`, `NetReceive`)

### Cancelation

`error.Canceled` is in all I/O error sets. Cancelation is idempotent and safe.

Three ways to handle `error.Canceled`:
1. **Propagate it** (most common)
2. `io.recancel()` then don't propagate — rearms for next check
3. `io.swapCancelProtection()` — make it unreachable in critical section

For long CPU-bound tasks: `io.checkCancel()` adds a cancelation checkpoint.

### Sync Primitives Migration

| 0.15 | 0.16 |
|------|------|
| `std.Thread.ResetEvent` | `std.Io.Event` |
| `std.Thread.WaitGroup` | `std.Io.Group` |
| `std.Thread.Futex` | `std.Io.Futex` |
| `std.Thread.Mutex` | `std.Io.Mutex` |
| `std.Thread.Condition` | `std.Io.Condition` |
| `std.Thread.Semaphore` | `std.Io.Semaphore` |
| `std.Thread.RwLock` | `std.Io.RwLock` |
| `std.once` | Removed — hand-roll or avoid globals |
| `std.Thread.Pool` | Removed — use `std.Io.Group`/`io.async` |

### I/O Type Deletions

| 0.15 (deleted) | 0.16 |
|----------------|------|
| `std.Io.GenericReader` | `std.Io.Reader` |
| `std.Io.AnyReader` | `std.Io.Reader` |
| `std.io.FixedBufferStream` (read) | `var r: std.Io.Reader = .fixed(data)` |
| `std.io.FixedBufferStream` (write) | `var w: std.Io.Writer = .fixed(buf)` |
| `std.leb.readUleb128` | `std.Io.Reader.takeLeb128` |

---

## 3. File System Migration

`std.fs.Dir` → `std.Io.Dir`, `std.fs.File` → `std.Io.File`. Most functions gain an `io` parameter.

### Key Renames

| 0.15 | 0.16 |
|------|------|
| `fs.cwd()` | `std.Io.Dir.cwd()` |
| `fs.Dir` | `std.Io.Dir` |
| `fs.File` | `std.Io.File` |
| `fs.Dir.makeDir` | `std.Io.Dir.createDir` |
| `fs.Dir.makePath` | `std.Io.Dir.createDirPath` |
| `fs.Dir.makeOpenDir` | `std.Io.Dir.createDirPathOpen` |
| `fs.Dir.realpath` | `std.Io.Dir.realPathFile` |
| `fs.Dir.realpathAlloc` | `std.Io.Dir.realPathFileAlloc` |
| `fs.Dir.atomicSymLink` | `std.Io.Dir.symLinkAtomic` |
| `fs.Dir.chmod` | `std.Io.Dir.setPermissions` |
| `fs.Dir.chown` | `std.Io.Dir.setOwner` |
| `fs.makeDirAbsolute` | `std.Io.Dir.createDirAbsolute` |
| `fs.openDirAbsolute` | `std.Io.Dir.openDirAbsolute` |
| `fs.openFileAbsolute` | `std.Io.Dir.openFileAbsolute` |
| `fs.realpath` | `std.Io.Dir.realPathFileAbsolute` |
| `fs.rename` | `std.Io.Dir.rename` |

### File I/O Methods

| 0.15 | 0.16 |
|------|------|
| `file.read` | `file.readStreaming` |
| `file.write` | `file.writeStreaming` |
| `file.writeAll` | `file.writeStreamingAll` |
| `file.pread` | `file.readPositional` |
| `file.pwrite` | `file.writePositional` |
| `file.setEndPos` | `file.setLength` |
| `file.getEndPos` | `file.length` |
| `file.seekTo` | via `file.reader`/`file.writer` `.seekTo` |
| `file.chmod` | `file.setPermissions` |
| `file.chown` | `file.setOwner` |
| `file.updateTimes` | `file.setTimestamps` |
| `fs.File.Mode` | `std.Io.File.Permissions` |

### Self-exe and CWD

| 0.15 | 0.16 |
|------|------|
| `fs.openSelfExe` | `std.process.openExecutable` |
| `fs.selfExePathAlloc` | `std.process.executablePathAlloc` |
| `fs.selfExePath` | `std.process.executablePath` |
| `fs.Dir.setAsCwd` | `std.process.setCurrentDir` |
| `std.process.getCwd` | `std.process.currentPath(io, buf)` |
| `std.process.getCwdAlloc` | `std.process.currentPathAlloc(io, alloc)` |

### readFileAlloc / readToEndAlloc

```zig
// 0.15
const contents = try std.fs.cwd().readFileAlloc(allocator, file_name, 1234);

// 0.16
const contents = try std.Io.Dir.cwd().readFileAlloc(io, file_name, allocator, .limited(1234));
```

```zig
// 0.15
const contents = try file.readToEndAlloc(allocator, 1234);

// 0.16
var file_reader = file.reader(&.{});
const contents = try file_reader.interface.allocRemaining(allocator, .limited(1234));
```

### Atomic Files

```zig
// 0.15
var atomic_file = try dest_dir.atomicFile(io, dest_path, .{
    .permissions = perms,
    .write_buffer = &buffer,
});
defer atomic_file.deinit();
try atomic_file.flush();
try atomic_file.renameIntoPlace();

// 0.16
var atomic_file = try dest_dir.createFileAtomic(io, dest_path, .{
    .permissions = perms,
    .make_path = true,
    .replace = true,
});
defer atomic_file.deinit(io);
var file_writer = atomic_file.file.writer(io, &buffer);
try file_writer.flush();
try atomic_file.replace(io);
```

### fs.path Changes

- `fs.path` → `std.Io.Dir.path` (deprecated alias remains)
- `fs.path.relative` now pure — requires CWD path + env map parameters
- `fs.getAppDataDir` **removed** — use [known-folders](https://github.com/ziglibs/known-folders) package
- `File.Stat.atime` now optional (nullable) — some filesystems don't report it

---

## 4. Process Management

```zig
// 0.15 — spawning
var child = std.process.Child.init(argv, gpa);
child.stdin_behavior = .Pipe;
try child.spawn(io);

// 0.16
var child = try std.process.spawn(io, .{
    .argv = argv,
    .stdin = .pipe,
});
```

```zig
// 0.15 — run and capture
const result = std.process.Child.run(allocator, io, .{ ... });

// 0.16
const result = std.process.run(allocator, io, .{ ... });
```

```zig
// 0.15 — exec
const err = std.process.execv(arena, argv);

// 0.16
const err = std.process.replace(io, .{ .argv = argv });
```

### Environment Variables — No Longer Global

`std.os.environ` is gone. Env vars are only available via `main`:

```zig
pub fn main(init: std.process.Init) !void {
    // Access env vars through init
    for (init.environ_map.keys(), init.environ_map.values()) |key, value| {
        std.log.info("{s}={s}", .{ key, value });
    }
}
```

Functions needing env vars should accept `*const process.Environ.Map` as a parameter.

---

## 5. Entropy / Random

```zig
// 0.15
std.crypto.random.bytes(&buffer);
const rng = std.crypto.random;

// 0.16
io.random(&buffer);
const rng_impl: std.Random.IoSource = .{ .io = io };
const rng = rng_impl.interface();

// For crypto-secure (always syscall, no cached state):
try io.randomSecure(&buffer);
```

---

## 6. Time

| 0.15 | 0.16 |
|------|------|
| `std.time.Instant` | `std.Io.Timestamp` |
| `std.time.Timer` | `std.Io.Timestamp` |
| `std.time.timestamp` | `std.Io.Timestamp.now` |

---

## 7. Allocator Changes

### ArenaAllocator — Now Thread-Safe and Lock-Free

No code changes needed — it's a transparent upgrade. `heap.ThreadSafe` allocator is **removed** (no longer needed since ArenaAllocator is already thread-safe).

### Memory Locking

```zig
// 0.15
try std.posix.mlock(slice);
std.posix.PROT.READ | std.posix.PROT.WRITE

// 0.16
try std.process.lockMemory(slice, .{});
.{ .READ = true, .WRITE = true }  // type-safe flags
```

---

## 8. Container API Changes

### ArrayHashMap — Managed Variants Removed

| 0.15 | 0.16 |
|------|------|
| `ArrayHashMap` | Removed |
| `AutoArrayHashMap` | Removed |
| `StringArrayHashMap` | Removed |
| `AutoArrayHashMapUnmanaged` | `array_hash_map.Auto` |
| `StringArrayHashMapUnmanaged` | `array_hash_map.String` |
| `ArrayHashMapUnmanaged` | `array_hash_map.Custom` |

### PriorityQueue

| 0.15 | 0.16 |
|------|------|
| `init(...)` | `.empty` or `initContext(...)` |
| `add` | `push` |
| `addSlice` | `pushSlice` |
| `addUnchecked` | `pushUnchecked` |
| `remove` / `removeOrNull` | `pop` |
| `removeIndex` | `popIndex` |

### PriorityDequeue

Same rename pattern: `add` → `push`, `removeMin`/`removeMax` → `popMin`/`popMax`, `init` → `.empty`.

### std.mem Renames

"index of" functions renamed to "find":
- `indexOf` → `find`
- New: `cut`, `cutPrefix`, `cutSuffix`, `cutScalar`, `cutLast`, `cutLastScalar`

---

## 9. Language Changes

### `@cImport` — Deprecated

Move C includes to a `.h` file and use `addTranslateC` in build.zig:

```zig
// 0.15 — c.zig
pub const c = @cImport({ @cInclude("stdio.h"); });
const c = @import("c.zig").c;

// 0.16 — c.h + build.zig
// c.h: #include <stdio.h>
// build.zig:
const translate_c = b.addTranslateC(.{
    .root_source_file = b.path("src/c.h"),
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("c", translate_c.createModule());
// source: const c = @import("c");
```

### `@Type` — Replaced with Individual Builtins

| 0.15 | 0.16 |
|------|------|
| `@Type(.{ .int = .{ .signedness = .unsigned, .bits = 10 } })` | `@Int(.unsigned, 10)` |
| `@Type(.enum_literal)` | `@EnumLiteral()` |
| `@Type(.{ .@"struct" = ... })` | `@Struct(layout, BackingInt, names, types, attrs)` |
| `@Type(.{ .@"union" = ... })` | `@Union(layout, TagType, names, types, attrs)` |
| `@Type(.{ .@"enum" = ... })` | `@Enum(TagInt, mode, names, values)` |
| `@Type(.{ .pointer = ... })` | `@Pointer(size, attrs, Element, sentinel)` |
| `@Type(.{ .@"fn" = ... })` | `@Fn(param_types, param_attrs, ReturnType, attrs)` |
| `std.meta.Int` | `@Int` (builtin replaces helper) |
| `std.meta.Tuple` | `@Tuple(&.{ T1, T2 })` |

No `@Float`, `@Array`, `@Opaque`, `@Optional`, `@ErrorUnion`, `@ErrorSet` builtins — use literal syntax (`?T`, `E!T`, `opaque {}`, `[N]T`, `error{...}`).

Error sets can **no longer be reified** — declare them explicitly with `error{ ... }`.

Struct-of-arrays pattern for `@Struct`/`@Union`/`@Fn`:

```zig
// Default attributes for all fields
@Struct(.auto, null, field_names, field_types, &@splat(.{}))
```

### `@intFromFloat` — Deprecated

Use `@trunc` instead. `@floor`, `@ceil`, `@round`, `@trunc` can now convert float → int directly:

```zig
// 0.15
const x: u8 = @intFromFloat(value);

// 0.16
const x: u8 = @trunc(value);     // truncate toward zero
const y: u8 = @round(value);     // round to nearest
const z: u8 = @floor(value);     // round toward negative infinity
```

### Small Int → Float Coercion

Integers with all values representable by a float type can now coerce implicitly:

```zig
var x: u24 = 123;
var f: f32 = x;  // OK in 0.16 (u24 fits in f32 significand)
// u25 and larger still need @floatFromInt
```

### Float Builtins Forward Result Type

`@sqrt`, `@sin`, `@cos`, `@tan`, `@exp`, `@log`, `@floor`, `@ceil`, `@round`, `@trunc` now forward result types:

```zig
// 0.16: this works now (f64 result type forwarded through @sqrt to @floatFromInt)
const x: f64 = @sqrt(@floatFromInt(N));
```

### Packed Types Tightened

- **Pointers forbidden** in packed structs/unions — use `usize` + `@ptrFromInt`
- **Unused bits forbidden** in packed unions — all fields must have same `@bitSizeOf`
- **Explicit backing type required** in extern contexts — `enum(u8)`, `packed struct(u8)`, `packed union(u8)`
- **Explicit backing integers** now allowed on packed unions — `packed union(u16) { ... }`

### Runtime Vector Indexes Forbidden

```zig
// 0.15
_ = vector[i];  // i is runtime

// 0.16 — coerce to array first
const arr: [vector_type.len]vector_type.child = vector;
for (&arr) |elem| { _ = elem; }
```

### Local Address Returns — Compile Error

```zig
fn foo() *i32 {
    var x: i32 = 1234;
    return &x;  // 0.16: compile error "returning address of expired local variable"
}
```

### Switch Improvements

- `packed struct`/`packed union` as switch prong items
- Decl literals in prong items
- Union tag captures on all prongs (not just `inline`)
- `void` switch no longer requires `else`

---

## 10. Build System Changes

### Package Management

- Packages now fetched to **project-local `zig-pkg/`** directory (not global cache)
- `build.zig.zon` **fingerprint field required** — legacy hash format removed
- New: `zig build --fork=[path]` for local package overrides

### New CLI Flags

| Flag | Purpose |
|------|---------|
| `--test-timeout 500ms` | Kill individual unit tests exceeding timeout |
| `--error-style verbose\|minimal\|verbose_clear\|minimal_clear` | Error formatting (replaces `--prominent-compile-errors`) |
| `--multiline-errors indent\|newline\|none` | Multi-line error alignment |

### Temporary Files

- `Build.RemoveDirTree` step **removed**
- `Build.makeTempPath` **removed**
- New: `b.addTempFiles()` + `WriteFile` API — auto-cleanup on build completion

```zig
// 0.15
const tmp = b.makeTempPath();
// ... use tmp ...
const remove = b.addRemoveDirTree(tmp);

// 0.16
const tmp_files = b.addTempFiles();
const tmp_dir = tmp_files.getDirectory();
// auto-cleaned on build completion
```

### @cImport → Build System

See Language Changes section above. Use `b.addTranslateC()`.

---

## 11. std.posix / std.os.windows Removals

Most medium-level wrappers removed. Choose a direction:
- **Go higher:** use `std.Io`
- **Go lower:** use `std.posix.system` directly

---

## 12. HTTP Client

HTTP client now requires `io` field:

```zig
// 0.15
var client: std.http.Client = .{ .allocator = gpa };

// 0.16
var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
```

---

## 13. Fuzzer — Smith Interface

Fuzz test parameter changed from `[]const u8` to `*std.testing.Smith`:

```zig
// 0.15
fn fuzzTest(_: void, input: []const u8) !void {
    var sum: u64 = 0;
    for (input) |b| sum += b;
    try std.testing.expect(sum != 1234);
}

// 0.16
fn fuzzTest(_: void, smith: *std.testing.Smith) !void {
    var sum: u64 = 0;
    while (!smith.eosWeightedSimple(7, 1)) {
        sum += smith.value(u8);
    }
    try std.testing.expect(sum != 1234);
}
```

Smith methods: `.value(T)`, `.eos()`, `.bytes(&buf)`, `.slice(buf)`. Weighted variants available for probability control. Crash dumps saved to file for reproduction via `FuzzInputOptions.corpus` + `@embedFile`.

---

## 14. New APIs (Did Not Exist Before 0.16)

### Directory Walking

```zig
// Selective walking — skip dirs without overhead
var walker = try dir.walkSelectively(gpa);
defer walker.deinit();
while (try walker.next(io)) |entry| {
    if (shouldProcess(entry)) {
        if (entry.kind == .directory) try walker.enter(io, entry);
    }
}
```

Also: `Walker.Entry.depth()` and `Walker.leave()` for depth control.

### Atomic File Operations

```zig
var atomic = try dir.createFileAtomic(io, path, .{
    .permissions = perms,
    .make_path = true,
    .replace = true,  // false to use .link() instead
});
defer atomic.deinit(io);
var w = atomic.file.writer(io, &buf);
// ... write ...
try w.flush();
try atomic.replace(io);  // atomically replaces target
```

### Debug Information

Stack trace API reworked:

| 0.15 | 0.16 |
|------|------|
| `captureStackTrace` | `captureCurrentStackTrace` |
| `dumpStackTraceFromBase` | `dumpCurrentStackTrace` |
| `walkStackWindows` | `captureCurrentStackTrace` |

`StackUnwindOptions`: `.first_address`, `.context` (signal handler), `.allow_unsafe_unwind`.
`std.debug.SelfInfo` can be overridden via `@import("root").debug.SelfInfo` for custom targets.
`std.debug.StackIterator` is no longer `pub`.

### Other New APIs

- `std.Io.Dir.Reader` — directory entry reader
- `std.Io.Dir.hardLink` — hard link creation
- `std.Io.File.NLink` — hard link count
- `std.Io.Dir.setFilePermissions` / `setFileOwner`
- `std.Io.File.enableAnsiEscapeCodes` (was `getOrEnableAnsiEscapeSupport`)
- `std.compress.flate` — deflate **compression** (was decompression-only), competitive with zlib
- `std.crypto`: AES-SIV, AES-GCM-SIV (nonce-reuse resistant), Ascon family (NIST SP 800-232)
- `std.process.Preopens` — replaces `fs.wasi.Preopens` (or use `init.preopens` from Juicy Main)
- `builtin.subsystem` **removed** — determine at runtime if needed
- `std.Target.SubSystem` → `std.zig.Subsystem`

---

## 15. Miscellaneous

### Toolchain

- LLVM 21, musl 1.2.5, glibc 2.43, Linux 6.19 headers, macOS 26.4 headers

### Lazy Field Analysis

Struct/union/enum fields only resolved when their size or type is needed. Using a type as a namespace no longer pulls in its fields.

### Explicitly-Aligned Pointers

`*u8` and `*align(1) u8` are now distinct types (but still coerce to each other). Rarely affects code.

---

## Quick Upgrade Checklist

- [ ] Update `main` signature to accept `std.process.Init`
- [ ] Add `io` parameter to all I/O calls (`file.close()` → `file.close(io)`)
- [ ] Replace `std.fs.Dir`/`File` with `std.Io.Dir`/`File`
- [ ] Replace `std.crypto.random` with `io.random()`
- [ ] Replace `std.Thread.Pool` with `std.Io.Group`
- [ ] Migrate sync primitives: `Thread.Mutex` → `Io.Mutex`, etc.
- [ ] Replace `@Type(...)` with `@Int`/`@Struct`/`@Union`/`@Enum`/`@Pointer`/`@Fn`/`@Tuple`
- [ ] Replace `@intFromFloat` with `@trunc`
- [ ] Move `@cImport` to `addTranslateC` in build.zig
- [ ] Add explicit backing types to enum/packed types used in extern contexts
- [ ] Remove pointers from packed structs/unions
- [ ] Update `build.zig.zon` with `fingerprint` field
- [ ] Replace `--prominent-compile-errors` with `--error-style minimal`
- [ ] Replace `std.process.getCwd` with `std.process.currentPath(io, buf)`
- [ ] Update env var access to use `init.environ_map` from main
- [ ] Replace `std.process.Child.init`/`.spawn()` with `std.process.spawn(io, ...)`
- [ ] Add `.io = io` to `std.http.Client` initialization
- [ ] Replace `std.mem.indexOf` with `std.mem.find`
- [ ] Update fuzz tests: `[]const u8` → `*std.testing.Smith`
- [ ] Replace `fs.getAppDataDir` with `known-folders` package
