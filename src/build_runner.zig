const std = @import("std");
const builtin = @import("builtin");

pub const root = @import("@build");
pub const dependencies = @import("@dependencies");

pub const std_options: std.Options = .{
    .side_channels_mitigations = .none,
    .http_disable_tls = true,
};

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try init.args.toSlice(arena);
    var arg_idx: usize = 1;

    const zig_exe = nextArg(args, &arg_idx) orelse return error.MissingZigExe;
    const zig_lib_dir = nextArg(args, &arg_idx) orelse return error.MissingZigLibDir;
    const build_root = nextArg(args, &arg_idx) orelse return error.MissingBuildRoot;
    const cache_root = nextArg(args, &arg_idx) orelse return error.MissingCacheRoot;
    const global_cache_root = nextArg(args, &arg_idx) orelse return error.MissingGlobalCacheRoot;

    const cwd: std.Io.Dir = .cwd();
    const zig_lib_directory: std.Build.Cache.Directory = .{
        .path = zig_lib_dir,
        .handle = try cwd.openDir(io, zig_lib_dir, .{}),
    };
    const build_root_directory: std.Build.Cache.Directory = .{
        .path = build_root,
        .handle = try cwd.openDir(io, build_root, .{}),
    };
    const local_cache_directory: std.Build.Cache.Directory = .{
        .path = cache_root,
        .handle = try cwd.createDirPathOpen(io, cache_root, .{}),
    };
    const global_cache_directory: std.Build.Cache.Directory = .{
        .path = global_cache_root,
        .handle = try cwd.createDirPathOpen(io, global_cache_root, .{}),
    };

    var graph: std.Build.Graph = .{
        .io = io,
        .arena = arena,
        .cache = .{
            .io = io,
            .gpa = gpa,
            .manifest_dir = try local_cache_directory.handle.createDirPathOpen(io, "h", .{}),
            .cwd = try std.process.currentPathAlloc(io, arena),
        },
        .zig_exe = zig_exe,
        .environ_map = try init.environ.createMap(arena),
        .global_cache_root = global_cache_directory,
        .zig_lib_directory = zig_lib_directory,
        .host = .{
            .query = .{},
            .result = try std.zig.system.resolveTargetQuery(io, .{}),
        },
        .time_report = false,
    };

    graph.cache.addPrefix(.{ .path = null, .handle = cwd });
    graph.cache.addPrefix(build_root_directory);
    graph.cache.addPrefix(local_cache_directory);
    graph.cache.addPrefix(global_cache_directory);
    graph.cache.hash.addBytes(builtin.zig_version_string);

    const builder = try std.Build.create(
        &graph,
        build_root_directory,
        local_cache_directory,
        dependencies.root_deps,
    );
    builder.resolveInstallPrefix(null, .{});
    try builder.runBuild(root);

    var modules: std.StringArrayHashMapUnmanaged(*std.Build.Module) = .empty;
    var global_iter = builder.modules.iterator();
    while (global_iter.next()) |entry| {
        try modules.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    }

    var visited_steps: std.AutoArrayHashMapUnmanaged(*std.Build.Step, void) = .empty;
    var step_iter = builder.top_level_steps.iterator();
    while (step_iter.next()) |entry| {
        const top_level_step = entry.value_ptr.*;
        try collectStepModules(arena, &modules, &top_level_step.step, &visited_steps);
    }

    var output: std.Io.Writer.Allocating = .init(arena);
    var json: std.json.Stringify = .{
        .writer = &output.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try writeModulesJson(&json, &modules);
    try output.writer.writeByte('\n');
    try std.Io.File.stdout().writeStreamingAll(io, output.written());
}

fn nextArg(args: []const [:0]const u8, idx: *usize) ?[:0]const u8 {
    if (idx.* >= args.len) return null;
    defer idx.* += 1;
    return args[idx.*];
}

fn collectStepModules(
    allocator: std.mem.Allocator,
    modules: *std.StringArrayHashMapUnmanaged(*std.Build.Module),
    step: *std.Build.Step,
    visited: *std.AutoArrayHashMapUnmanaged(*std.Build.Step, void),
) !void {
    if (visited.contains(step)) return;
    try visited.put(allocator, step, {});

    if (step.cast(std.Build.Step.Compile)) |compile_step| {
        var imports = compile_step.root_module.import_table.iterator();
        while (imports.next()) |entry| {
            try modules.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    for (step.dependencies.items) |dep_step| {
        try collectStepModules(allocator, modules, dep_step, visited);
    }
}

fn writeModulesJson(
    json: *std.json.Stringify,
    modules: *std.StringArrayHashMapUnmanaged(*std.Build.Module),
) !void {
    try json.beginObject();
    try json.objectField("modules");
    try json.beginObject();

    for (modules.keys(), modules.values()) |name, module| {
        const root_source = moduleRootPath(module) orelse continue;

        try json.objectField(name);
        try json.beginObject();
        try json.objectField("root");
        try json.write(root_source);

        if (module.import_table.count() > 0) {
            try json.objectField("imports");
            try json.beginObject();
            for (module.import_table.keys(), module.import_table.values()) |import_name, import_module| {
                const import_root = moduleRootPath(import_module) orelse continue;
                try json.objectField(import_name);
                try json.write(import_root);
            }
            try json.endObject();
        }

        try json.endObject();
    }

    try json.endObject();
    try json.endObject();
}

fn moduleRootPath(module: *std.Build.Module) ?[]const u8 {
    const root_source_file = module.root_source_file orelse return null;
    if (root_source_file == .generated) return null;
    return root_source_file.getPath2(module.owner, null);
}
