# Allocator Selection & Naming Guide

Use `zigdoc std.heap` and `zigdoc std.mem.Allocator` for API details. This reference covers **which allocator to choose** and **how to name them** for clarity.

## Quick Reference

| Allocator | Use Case | Thread-Safe |
|-----------|----------|-------------|
| `std.testing.allocator` | Unit tests (leak detection) | No |
| `std.heap.FixedBufferAllocator` | Stack-based, bounded size known | Optional |
| `std.heap.ArenaAllocator` | Batch free, CLI apps, request handlers | Yes (lock-free since 0.16) |
| `std.heap.page_allocator` | Backing for other allocators | Yes |
| `std.heap.c_allocator` | Linking libc, interop | Yes |
| `std.heap.raw_c_allocator` | Libc arena backing (no alignment overhead) | Yes |
| `std.heap.DebugAllocator` | Debug builds, leak/corruption detection | Configurable |
| `std.heap.smp_allocator` | ReleaseFast production multithreaded | Yes |
| `std.heap.MemoryPool(T)` | High-frequency same-type alloc/free | No |
| `std.heap.StackFallbackAllocator` | Stack buffer with heap fallback | Depends |
| `std.heap.wasm_allocator` | WebAssembly targets | Yes |

**Removed in 0.16:** `ThreadSafeAllocator` — ArenaAllocator is now thread-safe by default.

## Decision Flow

1. **Library code?** Accept `Allocator` parameter — let caller decide
2. **Unit test?** `std.testing.allocator` (has leak detection)
3. **Size known at comptime?** `FixedBufferAllocator` with stack buffer
4. **Stack with heap fallback?** `stackFallback(N, backing_allocator)`
5. **CLI app / one-shot?** `ArenaAllocator` wrapping `page_allocator`
6. **Request loop (web/game)?** `ArenaAllocator`, reset per iteration
7. **Many same-type objects?** `MemoryPool(T)`
8. **Debug build?** `DebugAllocator`
9. **ReleaseFast production?** `smp_allocator`
10. **Linking libc?** `c_allocator` or `raw_c_allocator` (as arena backing)

## Naming Conventions

A generic `allocator` name hides ownership contracts. Name allocators by their **memory contract**:

| Name | Contract | Can Return Data? |
|------|----------|------------------|
| `gpa` | Caller **must** free | Yes |
| `arena` | Bulk-deallocated at system boundary | Yes |
| `scratch` | Function-private temporary space | **Never** |

### Bad — "allocator" says nothing about ownership

```zig
fn process(allocator: Allocator) ![]u8 {
    const temp = try allocator.alloc(u8, 100);  // Who frees this?
    const result = try allocator.dupe(u8, temp); // Who owns this?
    allocator.free(temp);
    return result;
}
```

### Good — names communicate contracts

```zig
fn process(
    gpa: Allocator,      // General-purpose: caller must free returned data
    scratch: Allocator,  // Temporary: never return data allocated here
) ![]u8 {
    const temp = try scratch.alloc(u8, 100);
    defer scratch.free(temp);
    return try gpa.dupe(u8, computeResult(temp));
}
```

### Full Example

```zig
fn handleRequest(
    request: *Request,
    arena: Allocator,   // Response lifetime — bulk freed after response sent
    gpa: Allocator,     // Long-lived data — cache, shared state
    scratch: Allocator, // This function only — intermediate computation
) !Response {
    const parsed = try parseBody(request.body, scratch);
    try updateCache(gpa, parsed.cache_key, parsed.value);
    const response_body = try formatResponse(arena, parsed);
    return Response{ .body = response_body };
}
```

## Common Compositions

```zig
// CLI app: arena for everything
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();

// Debug wrapper: DebugAllocator → ArenaAllocator
var gpa: std.heap.DebugAllocator(.{}) = .init;
defer _ = gpa.deinit();
var arena = std.heap.ArenaAllocator.init(gpa.allocator());

// Libc-backed arena (more efficient)
var arena = std.heap.ArenaAllocator.init(std.heap.raw_c_allocator);

// Hot loop: reset arena per iteration
while (running) {
    _ = arena.reset(.retain_capacity);
    try handleRequest(arena.allocator());
}
```

See **[Memory Management Patterns](memory-management.md)** for ownership rules, lifetime pitfalls, and arena anti-patterns.
