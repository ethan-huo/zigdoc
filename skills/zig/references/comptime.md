# Comptime Reference

Zig's comptime system enables metaprogramming through partial evaluation and type reflection. This reference covers comptime fundamentals, type reflection, and common techniques.

## Table of Contents

- [Fundamentals](#fundamentals)
- [Type Reflection](#type-reflection)
- [Loop Variants](#loop-variants)
- [Branch Elimination](#branch-elimination)
- [Type Generation](#type-generation)
- [0.16 Behavior Changes](#016-behavior-changes)
- [Limitations](#limitations)

---

## Fundamentals

### Comptime Parameters

Values that must be known at compile time. Types are always comptime.

```zig
fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}

const result = max(i32, 5, 10);  // T=i32 known at compile time
```

A `comptime` parameter means:
- At the callsite, the value must be known at compile time
- In the function definition, the value is comptime-known

### Comptime Variables

Variables whose loads/stores happen at compile time.

```zig
comptime var i: usize = 0;
inline while (i < 3) : (i += 1) {
    // i is comptime-known each iteration
}
```

### Comptime Blocks

Force expression evaluation at compile time.

```zig
const primes = comptime blk: {
    var result: [10]u32 = undefined;
    // ... compute primes ...
    break :blk result;
};

comptime {
    // All code here runs at compile time
    if (@sizeOf(MyStruct) > 64) @compileError("too large");
}
```

### Container-Level Comptime

Top-level declarations are implicitly comptime.

```zig
// These are computed at compile time automatically
const lookup_table = generateTable();
const config = parseConfig(@embedFile("config.json"));
```

---

## Type Reflection

### Builtins

| Builtin | Purpose |
|---------|---------|
| `@typeInfo(T)` | Get type metadata as `std.builtin.Type` |
| `@TypeOf(expr)` | Get type of expression |
| `@typeName(T)` | Get type name as `[:0]const u8` |
| `@hasDecl(T, name)` | Check if type has declaration |
| `@hasField(T, name)` | Check if type has field |
| `@field(value, name)` | Access field by comptime-known name |

### Type Reification Builtins (0.16+)

`@Type` was removed in 0.16. Use dedicated builtins instead:

| Builtin | Creates |
|---------|---------|
| `@Int(.signed, bits)` | Integer type (replaces `std.meta.Int`) |
| `@Int(.unsigned, bits)` | Unsigned integer type |
| `@Struct(fields, decls, is_tuple, layout)` | Struct type |
| `@Union(layout, tag_type, fields, decls)` | Union type |
| `@Enum(tag_type, fields, is_exhaustive)` | Enum type |
| `@Pointer(info)` | Pointer type |
| `@Fn(info)` | Function type |
| `@Tuple(&.{ T1, T2, ... })` | Tuple type (replaces `std.meta.Tuple`) |
| `@EnumLiteral()` | Enum literal type |

Error sets **cannot be reified**—use `error{ Foo, Bar }` syntax directly.

```zig
// Old (0.15 and earlier — no longer compiles):
// const U8 = @Type(.{ .int = .{ .signedness = .unsigned, .bits = 8 } });

// New (0.16+):
const U8 = @Int(.unsigned, 8);
const Fields = @Tuple(&.{ u32, []const u8 });

// Integer type from a runtime-unknown bit width (still comptime-known value):
fn intN(comptime bits: u16) type {
    return @Int(.unsigned, bits);
}
```

### Accessing Type Info for Keywords

Use `@"keyword"` syntax because `union`, `struct`, `enum` are reserved:

```zig
const union_info = @typeInfo(MyUnion).@"union";
const struct_info = @typeInfo(MyStruct).@"struct";
const enum_info = @typeInfo(MyEnum).@"enum";
const fn_info = @typeInfo(@TypeOf(myFn)).@"fn";
```

### Common Type Info Fields

**Struct:**
```zig
const info = @typeInfo(MyStruct).@"struct";
// info.fields: []const StructField
// info.decls: []const Declaration
// info.is_tuple: bool
```

**Union:**
```zig
const info = @typeInfo(MyUnion).@"union";
// info.tag_type: ?type (null if untagged)
// info.fields: []const UnionField
// info.layout: .auto, .@"extern", .@"packed"
```

**Enum:**
```zig
const info = @typeInfo(MyEnum).@"enum";
// info.tag_type: type (backing integer)
// info.fields: []const EnumField
// info.is_exhaustive: bool
```

### Creating Union Values with Comptime Tag

Use `@unionInit` when the tag is comptime-known:

```zig
const Action = union(enum) {
    move: struct { x: i32, y: i32 },
    jump,
    attack: u32,
};

// Create union with comptime-known field name
const action = @unionInit(Action, "move", .{ .x = 10, .y = 20 });
```

---

## Loop Variants

### comptime for

Full compile-time evaluation. Can use `break` to return values. Cannot reference runtime values.

```zig
// Return value from comptime loop
fn hasField(comptime T: type, comptime name: []const u8) bool {
    const fields = @typeInfo(T).@"struct".fields;
    return comptime for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) break true;
    } else false;
}

// Computation in comptime block
fn sumComptime(comptime values: []const i32) i32 {
    comptime {
        var sum: i32 = 0;
        for (values) |v| sum += v;
        return sum;
    }
}
```

**Verified in stdlib:** `std/Build.zig:1953`

### inline for

Loop unrolling with code generation. Body is duplicated per iteration. Can reference runtime values. Cannot use `break` to return values.

```zig
fn printFields(value: anytype) void {
    const T = @TypeOf(value);
    const fields = @typeInfo(T).@"struct".fields;

    // Each iteration generates separate code
    inline for (fields) |field| {
        const field_value = @field(value, field.name);
        std.debug.print("{s} = {any}\n", .{ field.name, field_value });
    }
}

// Runtime comparison via unrolling
fn eqlAny(comptime T: type, a: T, b: T) bool {
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |field| {
        if (@field(a, field.name) != @field(b, field.name)) {
            return false;  // Runtime return
        }
    }
    return true;
}
```

**Verified in stdlib:** `std/meta.zig:27`, `compiler_rt/fmax.zig:63`

### Decision Table

| Need | Use | Reason |
|------|-----|--------|
| Return value from loop | `comptime for` | Only comptime allows `break` with value |
| Access runtime values in body | `inline for` | Comptime can't see runtime |
| Type-level computation only | `comptime for` | Clearer intent, no code gen |
| Generate code per iteration | `inline for` | Each iteration = separate code |
| Normal runtime iteration | regular `for` | No unrolling needed |

---

## Branch Elimination

Comptime-known conditions eliminate dead branches entirely—no runtime cost.

### Basic Elimination

```zig
fn process(comptime T: type, value: T) T {
    if (T == bool) {
        return !value;  // Only exists for bool
    } else {
        return value + 1;  // Only exists for integers
    }
}
```

### Platform-Specific Code

```zig
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

pub fn readIntBig(comptime T: type, bytes: []const u8) T {
    const value: T = @bitCast(bytes[0..@sizeOf(T)].*);
    if (comptime native_endian == .big) {
        return value;
    } else {
        return @byteSwap(value);
    }
}
```

### Propagating Across Functions

Use `inline fn` to propagate comptime conditions to call sites:

```zig
// WITHOUT inline: branch exists at runtime
fn maybeLog(comptime enabled: bool, msg: []const u8) void {
    if (enabled) std.debug.print("{s}\n", .{msg});
}

// WITH inline: branch eliminated at each call site
inline fn maybeLogInline(comptime enabled: bool, msg: []const u8) void {
    if (comptime enabled) std.debug.print("{s}\n", .{msg});
}

pub fn example() void {
    maybeLogInline(false, "debug");  // Entire call eliminated
    maybeLogInline(true, "important");  // Only this generates code
}
```

**Verified in stdlib:** `std/math.zig:708`, `std/log.zig:122`

---

## Type Generation

### Returning Types from Functions

```zig
fn Pair(comptime A: type, comptime B: type) type {
    return struct {
        first: A,
        second: B,

        const Self = @This();

        pub fn swap(self: Self) Pair(B, A) {
            return .{ .first = self.second, .second = self.first };
        }
    };
}

const IntStr = Pair(i32, []const u8);
var p: IntStr = .{ .first = 42, .second = "hello" };
```

### Generating Union Subsets

Generate a subset union type from a larger union:

```zig
pub fn Subset(comptime T: type, comptime fields: []const std.meta.FieldEnum(T)) type {
    const source_info = @typeInfo(T).@"union";
    var new_fields: [fields.len]std.builtin.Type.UnionField = undefined;

    for (fields, 0..) |field_enum, i| {
        const field_name = @tagName(field_enum);
        for (source_info.fields) |source_field| {
            if (std.mem.eql(u8, source_field.name, field_name)) {
                new_fields[i] = source_field;
                break;
            }
        }
    }

    // Build an untagged union first to derive its FieldEnum for the tag.
    // @Union replaces @Type(.{ .@"union" = ... }) in 0.16.
    const UntaggedSubset = @Union(source_info.layout, null, &new_fields, &.{});
    return @Union(
        source_info.layout,
        std.meta.FieldEnum(UntaggedSubset),
        &new_fields,
        &.{},
    );
}
```

### Converting Between Union Types

Use `inline else` to capture tag at comptime:

```zig
/// Convert subset to full union type.
pub fn toFull(comptime Full: type, subset: anytype) Full {
    return switch (subset) {
        inline else => |payload, tag| @unionInit(Full, @tagName(tag), payload),
    };
}

/// Try to narrow full union to subset type.
pub fn toSubset(comptime Subset: type, full: anytype) ?Subset {
    const subset_fields = @typeInfo(Subset).@"union".fields;
    return switch (full) {
        inline else => |payload, tag| {
            inline for (subset_fields) |sf| {
                if (std.mem.eql(u8, sf.name, @tagName(tag))) {
                    return @unionInit(Subset, sf.name, payload);
                }
            }
            return null;
        },
    };
}
```

**Verified in stdlib:** `std/meta.zig`, `std/json/static.zig:299-302`

---

## 0.16 Behavior Changes

### Lazy Field Analysis

Struct fields are only resolved when their size or type is actually needed. This means a struct containing a forward-referenced or yet-unknown type can compile as long as you never query its layout:

```zig
// Previously could cause premature "type not yet resolved" errors.
// In 0.16, fields are evaluated lazily — the compiler only materializes
// field types when @sizeOf, @offsetOf, or field access requires it.
```

This matters for recursive or mutually-dependent generic types.

### Pointers to Comptime-Only Types Are No Longer Comptime-Only

In 0.15, `*comptime_int` was itself a comptime-only type. In 0.16, such a pointer **can exist at runtime**—it just cannot be dereferenced at runtime (the pointed-to value is still comptime-only).

```zig
// 0.16: valid as a runtime value; dereferencing is still a compile error
var p: *const comptime_int = &42;
_ = p;  // ok — pointer itself is runtime
// _ = p.*;  // error: cannot dereference pointer to comptime-only type at runtime
```

### Zero-Bit Tuple Fields No Longer Implicitly Comptime

Previously, a zero-bit field in a tuple (e.g., `type`, `comptime_int`) was automatically treated as comptime. In 0.16 this implicit promotion is removed — you must declare such fields `comptime` explicitly if needed:

```zig
// Explicit comptime field annotation is now required:
const Meta = struct { comptime kind: type = u32, value: u32 };
```

### Error Sets Cannot Be Reified

Error sets must be written as literals. There is no `@Error(...)` builtin, and attempting to construct one via the old `@Type` interface is a compile error.

```zig
// The ONLY way to define an error set:
const MyError = error{ NotFound, InvalidInput };
```

---

## Limitations

Zig's comptime is deliberately constrained for cross-compilation safety and code clarity.

### No Host Architecture Detection

```zig
// This reflects TARGET, not host
const is_64bit = comptime @sizeOf(usize) == 8;

// Use build.zig for host detection
// build.zig runs as a program and can query host
```

### No String-to-Code Evaluation

```zig
// NOT POSSIBLE
const code = "x + y";
const result = @eval(code);  // No such builtin

// Alternative: Parse strings to data structures at comptime
const query = comptime sql.parse("SELECT * FROM users");
```

### No Runtime Type Information

```zig
// This works - type known at comptime
fn getTypeName(value: anytype) []const u8 {
    return @typeName(@TypeOf(value));
}

// NOT POSSIBLE - can't turn runtime string into type
fn typeFromName(name: []const u8) type { ... }
```

### No I/O at Comptime

```zig
// NOT POSSIBLE
const config = comptime std.fs.cwd().readFile("config.json");

// Alternatives:
const config = @embedFile("config.json");  // Static embedding
// Or use build.zig which runs as a normal program
```

### No Dynamic Method Injection

```zig
// This works - methods defined in type
fn Pair(comptime A: type, comptime B: type) type {
    return struct {
        first: A,
        second: B,
        pub fn swap(self: @This()) Pair(B, A) { ... }
    };
}

// NOT POSSIBLE - can't add methods to existing types
fn addMethod(comptime T: type, comptime name: []const u8, impl: anytype) type { ... }
```

### Summary Table

| Want to do | Comptime? | Alternative / Builtin |
|------------|-----------|-------------|
| Type reflection | Yes | `@typeInfo`, `@TypeOf` |
| Create integer type | Yes | `@Int(.unsigned, bits)` |
| Create tuple type | Yes | `@Tuple(&.{ T1, T2 })` |
| Create struct type | Yes | `@Struct(fields, decls, is_tuple, layout)` |
| Create union type | Yes | `@Union(layout, tag, fields, decls)` |
| Create enum type | Yes | `@Enum(tag_type, fields, is_exhaustive)` |
| Create error set | Yes | `error{ Foo, Bar }` literal — no builtin |
| Return types from functions | Yes | Return struct from function |
| Add methods to types | No | Define in type definition |
| Read files | No | `@embedFile` or build.zig |
| Syscalls | No | build.zig runs as program |
| Parse strings to code | No | Parse to data structures |
| Host detection | No | Build system queries |

### Design Rationale

These constraints ensure:
1. **Cross-compilation works** - comptime sees target, not host
2. **Code is readable** - no hidden code generation
3. **Builds are reproducible** - no I/O side effects
4. **All API is visible** - no dynamic method injection
