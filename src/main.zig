const std = @import("std");
const builtin = @import("builtin");
const Walk = @import("Walk.zig");
const log = std.log.scoped(.zigdoc);

const build_runner_0_14 = @embedFile("build_runner_0.14.zig");
const build_runner_0_15 = @embedFile("build_runner_0.15.zig");

const template_build_zig = @embedFile("templates/build.zig.template");
const template_main_zig = @embedFile("templates/main.zig.template");
const template_build_zig_zon = @embedFile("templates/build.zig.zon.template");
const template_agents_md = @embedFile("templates/AGENTS.md.template");
const template_gitignore = @embedFile("templates/.gitignore.template");

const CliOptions = struct {
    symbols: std.ArrayList([]const u8) = .empty,
};

const QueryParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize = 0,

    fn parse(allocator: std.mem.Allocator, input: []const u8, out: *std.ArrayList([]const u8)) anyerror!void {
        var parser: QueryParser = .{
            .allocator = allocator,
            .input = input,
        };
        try parser.parseList("", out, false);
        parser.skipSpace();
        if (parser.pos != parser.input.len) return error.InvalidQuery;
    }

    fn parseList(
        parser: *QueryParser,
        prefix: []const u8,
        out: *std.ArrayList([]const u8),
        expect_close: bool,
    ) anyerror!void {
        var need_item = true;
        while (parser.pos < parser.input.len) {
            parser.skipSpace();
            if (expect_close and parser.peek() == ')') {
                if (need_item) return error.InvalidQuery;
                parser.pos += 1;
                return;
            }

            try parser.parseItem(prefix, out);
            need_item = false;
            parser.skipSpace();

            switch (parser.peek()) {
                ',' => {
                    parser.pos += 1;
                    need_item = true;
                },
                ')' => {
                    if (!expect_close) return error.InvalidQuery;
                    parser.pos += 1;
                    return;
                },
                0 => {
                    if (expect_close) return error.InvalidQuery;
                    return;
                },
                else => return error.InvalidQuery,
            }
        }

        if (expect_close) return error.InvalidQuery;
        if (need_item) return error.InvalidQuery;
    }

    fn parseItem(
        parser: *QueryParser,
        prefix: []const u8,
        out: *std.ArrayList([]const u8),
    ) anyerror!void {
        parser.skipSpace();
        const start = parser.pos;
        while (parser.pos < parser.input.len) : (parser.pos += 1) {
            switch (parser.input[parser.pos]) {
                '(', ')', ',' => break,
                else => {},
            }
        }

        var part = std.mem.trim(u8, parser.input[start..parser.pos], &std.ascii.whitespace);
        if (part.len == 0) return error.InvalidQuery;

        if (parser.peek() == '(') {
            if (!std.mem.endsWith(u8, part, ".")) return error.InvalidQuery;
            part = part[0 .. part.len - 1];
            const next_prefix = try joinSymbol(parser.allocator, prefix, part);
            defer parser.allocator.free(next_prefix);
            parser.pos += 1;
            try parser.parseList(next_prefix, out, true);
            return;
        }

        const symbol = try joinSymbol(parser.allocator, prefix, part);
        try out.append(parser.allocator, symbol);
    }

    fn peek(parser: *const QueryParser) u8 {
        if (parser.pos >= parser.input.len) return 0;
        return parser.input[parser.pos];
    }

    fn skipSpace(parser: *QueryParser) void {
        while (parser.pos < parser.input.len and std.ascii.isWhitespace(parser.input[parser.pos])) {
            parser.pos += 1;
        }
    }
};

const SymbolDoc = struct {
    query: []const u8,
    parent_symbol: []const u8,
    member_name: []const u8,
    decl_index: Walk.Decl.Index,
    target_index: Walk.Decl.Index,
    category: Walk.Category,
    file_path: []const u8,
    line: usize,
    signature: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.skip(); // skip program name

    const options = try parseCli(arena.allocator(), io, &args);
    if (options.symbols.items.len == 0) {
        try printUsage(io);
        return;
    }

    Walk.init(arena.allocator());
    Walk.Decl.init(arena.allocator());

    const std_dir_path = try getStdDir(&arena, io);

    var needs_std = false;
    var needs_build = false;
    for (options.symbols.items) |symbol| {
        if (isStdSymbol(symbol)) {
            needs_std = true;
        } else {
            needs_build = true;
        }
    }

    if (needs_std) {
        try walkStdLib(&arena, io, std_dir_path);

        // Register std/std.zig as the "std" module for @import("std")
        const std_file_index = Walk.files.getIndex("std/std.zig") orelse return error.StdNotFound;
        try Walk.modules.put(arena.allocator(), "std", @enumFromInt(std_file_index));
    }

    if (needs_build) {
        try processBuildZig(&arena, io);
    }

    try printDocs(arena.allocator(), options.symbols.items, std_dir_path);
}

fn parseCli(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !CliOptions {
    var options: CliOptions = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(io);
            std.process.exit(0);
        }

        if (std.mem.eql(u8, arg, "--dump-imports")) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            try dumpImports(&arena, io);
            std.process.exit(0);
        }

        if (std.mem.eql(u8, arg, "@init")) {
            try initProject(allocator, io);
            std.process.exit(0);
        }

        if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            std.process.exit(1);
        }

        try QueryParser.parse(allocator, arg, &options.symbols);
    }
    return options;
}

fn joinSymbol(allocator: std.mem.Allocator, prefix: []const u8, part: []const u8) ![]const u8 {
    if (prefix.len == 0) return allocator.dupe(u8, part);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, part });
}

fn isStdSymbol(symbol: []const u8) bool {
    return std.mem.eql(u8, symbol, "std") or std.mem.startsWith(u8, symbol, "std.");
}

fn printUsage(io: std.Io) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout_writer.interface.writeAll(
        \\Usage: zigdoc [options] <symbol>
        \\
        \\Show documentation for Zig standard library symbols and imported modules.
        \\
        \\zigdoc can access any module imported in your build.zig file, making it easy
        \\to view documentation for third-party dependencies alongside the standard library.
        \\
        \\Examples:
        \\  zigdoc std.ArrayList
        \\  zigdoc std.mem.Allocator
        \\  zigdoc std.http.Server
        \\  zigdoc 'std.multi_array_list.MultiArrayList.(insertBounded, appendAssumeCapacity, Slice.(get, set))'
        \\  zigdoc vaxis.Window
        \\  zigdoc zeit.timezone.Posix
        \\
        \\Options:
        \\  -h, --help        Show this help message
        \\  --dump-imports    Dump module imports from build.zig as JSON
        \\
        \\Commands:
        \\  @init             Initialize a new Zig project with AGENTS.md
        \\
    );
    try stdout_writer.interface.flush();
}

fn initProject(allocator: std.mem.Allocator, io: std.Io) !void {
    const cwd = std.Io.Dir.cwd();

    // Check if project already exists
    if (cwd.access(io, "build.zig", .{})) |_| {
        std.debug.print("Error: build.zig already exists\n", .{});
        return error.ProjectExists;
    } else |_| {}

    // Get project name from current directory
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_path_len = try cwd.realPath(io, &path_buf);
    const cwd_path = path_buf[0..cwd_path_len];
    const name = std.fs.path.basename(cwd_path);

    // Create src directory
    try cwd.createDir(io, "src", .default_dir);

    // Write files with substitutions
    try cwd.writeFile(io, .{
        .sub_path = "build.zig",
        .data = try substitute(allocator, template_build_zig, name),
    });
    try cwd.writeFile(io, .{
        .sub_path = "build.zig.zon",
        .data = try substitute(allocator, template_build_zig_zon, name),
    });
    try cwd.writeFile(io, .{ .sub_path = "src/main.zig", .data = template_main_zig });
    try cwd.writeFile(io, .{ .sub_path = "AGENTS.md", .data = template_agents_md });
    try cwd.writeFile(io, .{ .sub_path = ".gitignore", .data = template_gitignore });

    // Run zig build to get suggested fingerprint from error message
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "zig", "build" },
    }) catch {
        std.debug.print("Initialized Zig project '{s}' (run 'zig build' to generate fingerprint)\n", .{name});
        return;
    };

    // Parse fingerprint from error: "suggested value: 0x..."
    if (std.mem.indexOf(u8, result.stderr, "suggested value: ")) |start| {
        const fp_start = start + "suggested value: ".len;
        const fp_end = std.mem.indexOfPos(u8, result.stderr, fp_start, "\n") orelse result.stderr.len;
        const fingerprint = result.stderr[fp_start..fp_end];

        // Read current build.zig.zon and insert fingerprint
        const zon_content = try cwd.readFileAlloc(io, "build.zig.zon", allocator, .limited(64 * 1024));
        const new_zon = try std.mem.replaceOwned(
            u8,
            allocator,
            zon_content,
            ".version = \"0.0.0\",",
            try std.fmt.allocPrint(allocator, ".version = \"0.0.0\",\n    .fingerprint = {s},", .{fingerprint}),
        );
        try cwd.writeFile(io, .{ .sub_path = "build.zig.zon", .data = new_zon });
    }

    std.debug.print("Initialized Zig project '{s}'\n", .{name});
}

fn substitute(allocator: std.mem.Allocator, template: []const u8, name: []const u8) ![]const u8 {
    const sanitized = try std.mem.replaceOwned(u8, allocator, name, "-", "_");
    return std.mem.replaceOwned(u8, allocator, template, "{{name}}", sanitized);
}

fn dumpImports(arena: *std.heap.ArenaAllocator, io: std.Io) !void {
    // Check if build.zig exists
    std.Io.Dir.cwd().access(io, "build.zig", .{}) catch {
        std.debug.print("No build.zig found in current directory\n", .{});
        return error.NoBuildZig;
    };

    // Setup the build runner
    try setupBuildRunner(arena, io);

    // Run zig build with our custom runner
    const result = try std.process.run(arena.allocator(), io, .{
        .argv = &[_][]const u8{
            "zig",
            "build",
            "--build-runner",
            ".zig-cache/zigdoc_build_runner.zig",
        },
    });

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("Error running build runner:\n{s}\n", .{result.stderr});
        return error.BuildRunnerFailed;
    }

    // Print the JSON output directly
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout_writer.interface.writeAll(result.stdout);
    try stdout_writer.interface.flush();
}

const ZigEnv = struct {
    std_dir: []const u8,
};

fn getZigVersion(arena: *std.heap.ArenaAllocator, io: std.Io) !std.SemanticVersion {
    const version_result = try std.process.run(arena.allocator(), io, .{
        .argv = &[_][]const u8{ "zig", "version" },
    });

    if (version_result.term != .exited or version_result.term.exited != 0) {
        return error.ZigVersionFailed;
    }

    const version_str = std.mem.trim(u8, version_result.stdout, &std.ascii.whitespace);
    return std.SemanticVersion.parse(version_str);
}

fn setupBuildRunner(arena: *std.heap.ArenaAllocator, io: std.Io) !void {
    const version = try getZigVersion(arena, io);

    const runner_src = switch (version.minor) {
        14 => build_runner_0_14,
        15 => build_runner_0_15,
        else => return error.UnsupportedZigVersion,
    };

    std.Io.Dir.cwd().createDir(io, ".zig-cache", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const runner_path = ".zig-cache/zigdoc_build_runner.zig";
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = runner_path,
        .data = runner_src,
    });
}

fn processBuildZig(arena: *std.heap.ArenaAllocator, io: std.Io) !void {
    // Check if build.zig exists
    std.Io.Dir.cwd().access(io, "build.zig", .{}) catch {
        // No build.zig, nothing to do
        return;
    };

    // Setup the build runner
    try setupBuildRunner(arena, io);

    // Run zig build with our custom runner
    const result = try std.process.run(arena.allocator(), io, .{
        .argv = &[_][]const u8{
            "zig",
            "build",
            "--build-runner",
            ".zig-cache/zigdoc_build_runner.zig",
        },
    });

    if (result.term != .exited or result.term.exited != 0) {
        log.err("Failed to analyze build.zig", .{});
        return;
    }

    // Parse the output to extract module information
    try parseBuildOutput(arena.allocator(), io, result.stdout);
}

fn parseBuildOutput(allocator: std.mem.Allocator, io: std.Io, output: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();

    const root_obj = parsed.value.object;
    const modules_obj = root_obj.get("modules") orelse return;

    var modules_iter = modules_obj.object.iterator();
    while (modules_iter.next()) |entry| {
        const module_name = entry.key_ptr.*;
        const module_data = entry.value_ptr.*.object;

        const root_path = module_data.get("root").?.string;

        // Skip non-Zig files (fonts, images, etc.)
        if (!std.mem.endsWith(u8, root_path, ".zig")) continue;

        // Read and add the module file
        const file_content = std.Io.Dir.cwd().readFileAlloc(
            io,
            root_path,
            allocator,
            .limited(10 * 1024 * 1024),
        ) catch |err| {
            std.debug.print("Failed to read module {s}: {}\n", .{ module_name, err });
            continue;
        };

        const file_index = try Walk.addFile(root_path, file_content);
        try Walk.modules.put(allocator, module_name, file_index);

        // Handle imports if present
        if (module_data.get("imports")) |imports_obj| {
            var imports_iter = imports_obj.object.iterator();
            while (imports_iter.next()) |import_entry| {
                const import_name = import_entry.key_ptr.*;
                const import_path = import_entry.value_ptr.*.string;

                // Skip non-Zig files (fonts, images, etc.)
                if (!std.mem.endsWith(u8, import_path, ".zig")) continue;

                // Read and add the imported file
                const import_content = std.Io.Dir.cwd().readFileAlloc(
                    io,
                    import_path,
                    allocator,
                    .limited(10 * 1024 * 1024),
                ) catch |err| {
                    std.debug.print("Failed to read import {s}: {}\n", .{ import_name, err });
                    continue;
                };

                const import_file_index = try Walk.addFile(import_path, import_content);
                try Walk.modules.put(allocator, import_name, import_file_index);
            }
        }
    }
}

fn getStdDir(arena: *std.heap.ArenaAllocator, io: std.Io) ![]const u8 {
    const version = try getZigVersion(arena, io);

    const is_pre_0_15 = version.order(.{ .major = 0, .minor = 15, .patch = 0 }) == .lt;

    const result = try std.process.run(arena.allocator(), io, .{
        .argv = &[_][]const u8{ "zig", "env" },
    });

    if (result.term != .exited or result.term.exited != 0) {
        return error.ZigEnvFailed;
    }

    const stdout = try arena.allocator().dupeZ(u8, result.stdout);

    if (is_pre_0_15) {
        const parsed = try std.json.parseFromSlice(
            ZigEnv,
            arena.allocator(),
            stdout,
            .{ .ignore_unknown_fields = true },
        );
        return parsed.value.std_dir;
    } else {
        const parsed = try std.zon.parse.fromSliceAlloc(
            ZigEnv,
            arena.allocator(),
            stdout,
            null,
            .{ .ignore_unknown_fields = true },
        );
        return parsed.std_dir;
    }
}

fn walkStdLib(arena: *std.heap.ArenaAllocator, io: std.Io, std_dir_path: []const u8) !void {
    const allocator = arena.allocator();
    var dir = try std.Io.Dir.openDirAbsolute(io, std_dir_path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.endsWith(u8, entry.basename, "test.zig")) continue;

        const file_content = try entry.dir.readFileAlloc(
            io,
            entry.basename,
            allocator,
            .limited(10 * 1024 * 1024),
        );

        const file_name = try std.fmt.allocPrint(allocator, "std/{s}", .{entry.path});

        _ = try Walk.addFile(file_name, file_content);
    }
}

fn resolveHierarchical(allocator: std.mem.Allocator, symbol: []const u8) !?Walk.Decl.Index {
    var parts = std.mem.splitScalar(u8, symbol, '.');
    const first_part = parts.next() orelse return null;

    // Find the root declaration
    var current_decl: ?Walk.Decl.Index = null;
    for (Walk.decls.items, 0..) |*decl, i| {
        const info = decl.extraInfo();
        if (!info.is_pub) continue;

        var fqn_buf: std.ArrayList(u8) = .empty;
        defer fqn_buf.deinit(allocator);
        try decl.fqn(&fqn_buf);

        if (std.mem.eql(u8, fqn_buf.items, first_part)) {
            current_decl = @enumFromInt(i);
            break;
        }
    }

    if (current_decl == null) return null;

    // Walk through the remaining parts
    while (parts.next()) |part| {
        // Follow aliases with circular reference protection
        var search_decl = current_decl.?;
        var category = search_decl.get().categorize();
        var hop_count: usize = 0;
        while (category == .alias) {
            hop_count += 1;
            if (hop_count >= 64) {
                log.err("Circular alias detected resolving '{s}'", .{symbol});
                return error.CircularAlias;
            }
            search_decl = category.alias;
            category = search_decl.get().categorize();
        }

        // Find child with matching name
        var found = false;
        for (Walk.decls.items, 0..) |*candidate, i| {
            if (candidate.parent != .none and @intFromEnum(candidate.parent) == @intFromEnum(search_decl)) {
                const member_info = candidate.extraInfo();
                if (!member_info.is_pub) continue;
                if (std.mem.eql(u8, member_info.name, part)) {
                    current_decl = @enumFromInt(i);
                    found = true;
                    break;
                }
            }
        }

        if (!found) return null;
    }

    return current_decl;
}

fn printDocs(allocator: std.mem.Allocator, symbols: []const []const u8, std_dir_path: []const u8) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var docs: std.ArrayList(SymbolDoc) = .empty;
    defer docs.deinit(allocator);

    for (symbols) |symbol| {
        const decl_index = try findSymbol(allocator, symbol) orelse {
            try printNotFound(allocator, stdout, symbol);
            try stdout.flush();
            std.process.exit(1);
        };
        try docs.append(allocator, try buildSymbolDoc(allocator, symbol, decl_index));
    }

    if (docs.items.len == 1) {
        try renderSingleDoc(allocator, stdout, docs.items[0], std_dir_path);
    } else {
        try renderGroupedDocs(allocator, stdout, docs.items, std_dir_path);
    }

    try stdout.flush();
}

fn findSymbol(allocator: std.mem.Allocator, symbol: []const u8) !?Walk.Decl.Index {
    if (std.mem.indexOf(u8, symbol, ".")) |_| {
        if (try resolveHierarchical(allocator, symbol)) |decl_index| return decl_index;
    }

    for (Walk.decls.items, 0..) |*decl, i| {
        const file_path = decl.file.path();
        if (file_path.len == 0) continue;

        const ast = decl.file.getAst();
        if (ast.source.len == 0) continue;

        const info = decl.extraInfo();
        if (!info.is_pub) continue;

        var fqn_buf: std.ArrayList(u8) = .empty;
        defer fqn_buf.deinit(allocator);
        try decl.fqn(&fqn_buf);

        if (std.mem.eql(u8, fqn_buf.items, symbol)) return @enumFromInt(i);
    }

    return null;
}

fn buildSymbolDoc(allocator: std.mem.Allocator, symbol: []const u8, decl_index: Walk.Decl.Index) !SymbolDoc {
    const target_index, const category = try resolveAliasTarget(decl_index);
    const target_decl = target_index.get();
    return .{
        .query = symbol,
        .parent_symbol = try parentSymbol(allocator, symbol),
        .member_name = memberName(symbol),
        .decl_index = decl_index,
        .target_index = target_index,
        .category = category,
        .file_path = target_decl.file.path(),
        .line = declLine(target_decl),
        .signature = try formatSignature(allocator, target_decl.file.getAst(), target_decl, category),
    };
}

fn resolveAliasTarget(decl_index: Walk.Decl.Index) !struct { Walk.Decl.Index, Walk.Category } {
    var target_index = decl_index;
    var category = target_index.get().categorize();
    var hop_count: usize = 0;
    while (category == .alias) {
        hop_count += 1;
        if (hop_count >= 64) return error.CircularAlias;
        target_index = category.alias;
        category = target_index.get().categorize();
    }
    return .{ target_index, category };
}

fn parentSymbol(allocator: std.mem.Allocator, symbol: []const u8) ![]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, symbol, '.') orelse return allocator.dupe(u8, symbol);
    return allocator.dupe(u8, symbol[0..dot]);
}

fn memberName(symbol: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, symbol, '.') orelse return symbol;
    return symbol[dot + 1 ..];
}

fn declLine(decl: *const Walk.Decl) usize {
    const ast = decl.file.getAst();
    const token_starts = ast.tokens.items(.start);
    const main_token = ast.nodeMainToken(decl.ast_node);
    const byte_offset = token_starts[main_token];
    const loc = std.zig.findLineColumn(ast.source, byte_offset);
    return loc.line + 1;
}

fn renderSingleDoc(
    allocator: std.mem.Allocator,
    writer: anytype,
    doc: SymbolDoc,
    std_dir_path: []const u8,
) !void {
    _ = std_dir_path;
    try writer.print("{s} at {s}:{d}\n", .{ doc.query, doc.file_path, doc.line });
    try renderDocBlock(writer, doc, 2);

    if (doc.target_index != doc.decl_index) {
        var target_fqn: std.ArrayList(u8) = .empty;
        defer target_fqn.deinit(allocator);
        try doc.target_index.get().fqn(&target_fqn);
        try writer.print("  alias target: {s}\n", .{target_fqn.items});
    }

    const has_members = try printMembers(allocator, writer, doc.target_index.get(), doc.category);
    if (doc.category == .type_function and !has_members) {
        try writer.writeAll("\nSource:\n");
        try printSource(writer, doc.target_index.get().file.getAst(), doc.target_index.get().ast_node);
    }

    try writer.writeAll("\nhint: use cx with the shown file and line to inspect source\n");
}

fn renderGroupedDocs(
    allocator: std.mem.Allocator,
    writer: anytype,
    docs: []const SymbolDoc,
    std_dir_path: []const u8,
) !void {
    _ = std_dir_path;

    var first_group = true;
    for (docs) |doc| {
        if (hasEarlierParent(docs, doc.parent_symbol, doc.query)) continue;
        if (!first_group) try writer.writeAll("\n");
        first_group = false;

        try renderGroupHeader(allocator, writer, doc.parent_symbol);
        for (docs) |member_doc| {
            if (!std.mem.eql(u8, member_doc.parent_symbol, doc.parent_symbol)) continue;
            try writer.writeByte('\n');
            try writer.print("{s} (ln:{d}):\n", .{ member_doc.member_name, member_doc.line });
            try renderDocBlock(writer, member_doc, 2);
        }
    }

    try writer.writeAll("\nhint: use cx with the shown file and line to inspect source\n");
}

fn renderDocBlock(writer: anytype, doc: SymbolDoc, indent: usize) !void {
    if (doc.signature.len > 0) {
        try writeIndent(writer, indent);
        const label = switch (doc.category) {
            .function, .type_function => "sig",
            .global_const, .global_variable => "decl",
            .container, .namespace => "type",
            else => "info",
        };
        try writer.print("{s}: {s}\n", .{ label, doc.signature });
    }

    if (hasDocComment(doc)) {
        try writeIndent(writer, indent);
        try writer.writeAll("docs:\n");
        try renderIndentedDocComments(writer, doc, indent + 2);
    }
}

fn renderGroupHeader(allocator: std.mem.Allocator, writer: anytype, parent_symbol: []const u8) !void {
    if (try findSymbol(allocator, parent_symbol)) |parent_index| {
        const target_index, _ = try resolveAliasTarget(parent_index);
        const target = target_index.get();
        try writer.print("{s} at {s}:{d}\n", .{ parent_symbol, target.file.path(), declLine(target) });
    } else {
        try writer.print("{s}\n", .{parent_symbol});
    }
}

fn hasEarlierParent(docs: []const SymbolDoc, parent: []const u8, query: []const u8) bool {
    for (docs) |doc| {
        if (std.mem.eql(u8, doc.query, query)) return false;
        if (std.mem.eql(u8, doc.parent_symbol, parent)) return true;
    }
    return false;
}

fn printNotFound(allocator: std.mem.Allocator, writer: anytype, symbol: []const u8) !void {
    try writer.writeAll("Symbol not found: ");
    try writer.print("'{s}'\n\n", .{symbol});

    var parts = std.mem.splitScalar(u8, symbol, '.');
    const first_part = parts.next() orelse {
        try writer.writeAll("Tip: Specify a symbol like 'std.ArrayList' or 'moduleName.Symbol'\n");
        return;
    };

    const module_exists = blk: {
        for (Walk.decls.items) |*decl| {
            var fqn_buf: std.ArrayList(u8) = .empty;
            defer fqn_buf.deinit(allocator);
            try decl.fqn(&fqn_buf);
            if (std.mem.eql(u8, fqn_buf.items, first_part)) break :blk true;
        }
        break :blk false;
    };

    if (!module_exists) {
        try writer.print("Module '{s}' not found.\n", .{first_part});
        if (Walk.modules.count() > 0) {
            try writer.writeAll("\nAvailable modules:\n");
            var iter = Walk.modules.iterator();
            while (iter.next()) |entry| {
                try writer.print("  {s}\n", .{entry.key_ptr.*});
            }
        }
    } else {
        try writer.print("Module '{s}' found, but could not find symbol '{s}'.\n", .{ first_part, symbol });
        try writer.writeAll("Possible reasons:\n");
        try writer.writeAll("  - The symbol is private (not marked with 'pub')\n");
        try writer.writeAll("  - The symbol name is misspelled\n");
        try writer.writeAll("  - The symbol is nested deeper than specified\n");
    }
}

fn printMembers(allocator: std.mem.Allocator, writer: anytype, decl: *const Walk.Decl, category: Walk.Category) !bool {
    switch (category) {
        .type_function, .namespace, .container => {
            var functions: std.ArrayList([]const u8) = .empty;
            defer functions.deinit(allocator);
            var type_functions: std.ArrayList([]const u8) = .empty;
            defer type_functions.deinit(allocator);
            var constants: std.ArrayList([]const u8) = .empty;
            defer constants.deinit(allocator);
            var types: std.ArrayList([]const u8) = .empty;
            defer types.deinit(allocator);
            const FieldInfo = struct {
                name: []const u8,
                type_str: []const u8,
                doc_comment: ?std.zig.Ast.TokenIndex,
            };
            var fields: std.ArrayList(FieldInfo) = .empty;
            defer fields.deinit(allocator);

            const ast = decl.file.getAst();

            if (category == .container) {
                const node = category.container;
                var buffer: [2]std.zig.Ast.Node.Index = undefined;
                if (ast.fullContainerDecl(&buffer, node)) |container_decl| {
                    for (container_decl.ast.members) |member| {
                        if (ast.fullContainerField(member)) |field| {
                            const name_token = field.ast.main_token;
                            if (ast.tokenTag(name_token) == .identifier) {
                                const field_name = ast.tokenSlice(name_token);

                                const type_str = if (field.ast.type_expr.unwrap()) |type_expr| blk: {
                                    const start_token = ast.firstToken(type_expr);
                                    const end_token = ast.lastToken(type_expr);
                                    const token_starts = ast.tokens.items(.start);
                                    const start_offset = token_starts[start_token];
                                    const end_offset = if (end_token + 1 < ast.tokens.len)
                                        token_starts[end_token + 1]
                                    else
                                        ast.source.len;
                                    break :blk std.mem.trim(
                                        u8,
                                        ast.source[start_offset..end_offset],
                                        &std.ascii.whitespace,
                                    );
                                } else "";

                                const first_doc = Walk.Decl.findFirstDocComment(ast, field.firstToken());

                                try fields.append(allocator, .{
                                    .name = field_name,
                                    .type_str = type_str,
                                    .doc_comment = first_doc.unwrap(),
                                });
                            }
                        }
                    }
                }
            }

            // Collect public members
            // Note: We iterate by index because calling categorize() can trigger file loading
            // which appends to Walk.decls.items, invalidating slice references
            var i: usize = 0;
            // Find the index of the target decl to avoid pointer comparison issues
            // (pointers can become invalid when Walk.decls.items is reallocated)
            const target_decl_idx: usize = blk: {
                for (Walk.decls.items, 0..) |*d, idx| {
                    if (d == decl) break :blk idx;
                }
                @panic("decl not found in Walk.decls.items");
            };

            var checked: usize = 0;
            var matched_parent: usize = 0;
            while (i < Walk.decls.items.len) : (i += 1) {
                const candidate = &Walk.decls.items[i];
                checked += 1;
                // Validate parent index before using it
                if (candidate.parent != .none) {
                    const pidx = @intFromEnum(candidate.parent);
                    if (pidx >= Walk.decls.items.len) {
                        continue; // Skip invalid parent
                    }
                    // Compare parent index instead of pointer to avoid stale pointer issues
                    if (pidx != target_decl_idx) {
                        continue;
                    }
                    matched_parent += 1;
                } else {
                    continue; // No parent
                }

                const member_info = candidate.extraInfo();
                if (!member_info.is_pub) continue;
                if (member_info.name.len == 0) continue;

                const member_cat = candidate.categorize();
                switch (member_cat) {
                    .function => try functions.append(allocator, member_info.name),
                    .type_function => try type_functions.append(allocator, member_info.name),
                    .namespace, .container => try types.append(allocator, member_info.name),
                    .alias => |alias_index| {
                        // Follow alias chain to get the final category
                        // Guard against invalid alias indices
                        const idx = @intFromEnum(alias_index);
                        if (alias_index == .none or idx >= Walk.decls.items.len) {
                            // Invalid alias, treat as constant
                            try constants.append(allocator, member_info.name);
                            continue;
                        }

                        var resolved_index = alias_index;
                        var hops: usize = 0;
                        var resolved_cat = resolved_index.get().categorize();
                        while (resolved_cat == .alias and hops < 64) : (hops += 1) {
                            const next_index = resolved_cat.alias;
                            const next_idx = @intFromEnum(next_index);
                            if (next_index == .none or next_idx >= Walk.decls.items.len) break;
                            resolved_index = next_index;
                            resolved_cat = resolved_index.get().categorize();
                        }
                        switch (resolved_cat) {
                            .namespace, .container => try types.append(allocator, member_info.name),
                            .function => try functions.append(allocator, member_info.name),
                            .type_function => try type_functions.append(allocator, member_info.name),
                            else => try constants.append(allocator, member_info.name),
                        }
                    },
                    .global_const => try constants.append(allocator, member_info.name),
                    else => {},
                }
            }

            var has_members = false;

            if (fields.items.len > 0) {
                try writer.writeAll("\nFields:\n");
                var prev_had_doc = false;
                for (fields.items) |field| {
                    if (prev_had_doc) try writer.writeAll("\n");
                    if (field.type_str.len > 0) {
                        try writer.print("  {s}: {s}\n", .{ field.name, field.type_str });
                    } else {
                        try writer.print("  {s}\n", .{field.name});
                    }
                    if (field.doc_comment) |first_doc| {
                        var token_idx = first_doc;
                        var has_any_docs = false;
                        while (ast.tokenTag(token_idx) == .doc_comment) : (token_idx += 1) {
                            const comment = ast.tokenSlice(token_idx);
                            try writer.print("      {s}\n", .{comment[3..]});
                            has_any_docs = true;
                        }
                        prev_had_doc = has_any_docs;
                    } else {
                        prev_had_doc = false;
                    }
                }
                has_members = true;
            }

            if (type_functions.items.len > 0) {
                try writer.writeAll("\nType Functions:\n");
                for (type_functions.items) |name| {
                    try writer.print("  {s}\n", .{name});
                }
                has_members = true;
            }

            if (types.items.len > 0) {
                try writer.writeAll("\nTypes:\n");
                for (types.items) |name| {
                    try writer.print("  {s}\n", .{name});
                }
                has_members = true;
            }

            if (functions.items.len > 0) {
                try writer.writeAll("\nFunctions:\n");
                for (functions.items) |name| {
                    try writer.print("  {s}\n", .{name});
                }
                has_members = true;
            }

            if (constants.items.len > 0) {
                try writer.writeAll("\nConstants:\n");
                for (constants.items) |name| {
                    try writer.print("  {s}\n", .{name});
                }
                has_members = true;
            }

            if (has_members) {
                try writer.writeAll("\n");
            }

            return has_members;
        },
        else => return false,
    }
}

fn getFullPath(allocator: std.mem.Allocator, std_dir_path: []const u8, file_path: []const u8) ![]const u8 {
    // If already an absolute path, return as-is
    if (std.fs.path.isAbsolute(file_path)) {
        return allocator.dupe(u8, file_path);
    }

    // For "std/..." paths, prepend std_dir_path
    if (std.mem.startsWith(u8, file_path, "std/")) {
        const relative_path = file_path[4..]; // Remove "std/" prefix
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ std_dir_path, relative_path });
    }

    // Fallback for any other path
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ std_dir_path, file_path });
}

fn formatSignature(
    allocator: std.mem.Allocator,
    ast: *const std.zig.Ast,
    decl: *const Walk.Decl,
    category: Walk.Category,
) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writeSignatureValue(allocator, &writer.writer, ast, decl, category);
    return try writer.toOwnedSlice();
}

fn printSignature(writer: anytype, ast: *const std.zig.Ast, decl: *const Walk.Decl, category: Walk.Category) !void {
    var allocating: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer allocating.deinit();
    try writeSignatureValue(std.heap.page_allocator, &allocating.writer, ast, decl, category);
    const signature = allocating.written();
    switch (category) {
        .function, .type_function => try writer.print("Signature: {s}\n", .{signature}),
        .global_const, .global_variable => try writer.print("Declaration: {s}\n", .{signature}),
        .container, .namespace => try writer.print("Type: {s}\n", .{signature}),
        else => {},
    }
}

fn writeSignatureValue(
    allocator: std.mem.Allocator,
    writer: anytype,
    ast: *const std.zig.Ast,
    _: *const Walk.Decl,
    category: Walk.Category,
) !void {
    switch (category) {
        .function, .type_function => |node| {
            var buf: [1]std.zig.Ast.Node.Index = undefined;
            const fn_proto = ast.fullFnProto(&buf, node) orelse return;

            const start_token = fn_proto.lparen;
            const end_token = if (fn_proto.ast.return_type.unwrap()) |return_type|
                ast.lastToken(return_type)
            else
                findClosingParen(ast, fn_proto.lparen);
            const source = sourceForTokenRange(ast, start_token, end_token);
            try writeCollapsedWhitespace(allocator, writer, source);
        },
        .global_const, .global_variable => |node| {
            const var_decl = ast.fullVarDecl(node) orelse return;
            const start_token = var_decl.firstToken();
            const end_token = ast.lastToken(node);
            const source = sourceForTokenRange(ast, start_token, end_token);
            try writeCollapsedWhitespace(allocator, writer, source);
        },
        .container => |node| {
            if (ast.nodeTag(node) == .root) {
                try writer.writeAll("struct (file root)");
            } else {
                const main_token = ast.nodeMainToken(node);
                const container_kind = ast.tokenSlice(main_token);
                try writer.print("{s}", .{container_kind});
            }
        },
        .namespace => |node| {
            if (ast.nodeTag(node) == .root) {
                try writer.writeAll("namespace (file root)");
            } else {
                try writer.writeAll("namespace (struct)");
            }
        },
        else => {},
    }
}

fn findClosingParen(ast: *const std.zig.Ast, lparen: std.zig.Ast.TokenIndex) std.zig.Ast.TokenIndex {
    var depth: usize = 0;
    var token_idx = lparen;
    while (token_idx < ast.tokens.len) : (token_idx += 1) {
        switch (ast.tokenTag(token_idx)) {
            .l_paren => depth += 1,
            .r_paren => {
                depth -= 1;
                if (depth == 0) return token_idx;
            },
            else => {},
        }
    }
    return lparen;
}

fn sourceForTokenRange(
    ast: *const std.zig.Ast,
    start_token: std.zig.Ast.TokenIndex,
    end_token: std.zig.Ast.TokenIndex,
) []const u8 {
    const token_starts = ast.tokens.items(.start);
    const start_offset = token_starts[start_token];
    const end_offset = if (end_token + 1 < ast.tokens.len)
        token_starts[end_token + 1]
    else
        ast.source.len;
    return std.mem.trim(u8, ast.source[start_offset..end_offset], &std.ascii.whitespace);
}

fn writeCollapsedWhitespace(allocator: std.mem.Allocator, writer: anytype, source: []const u8) !void {
    _ = allocator;
    var previous_space = false;
    for (source) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (!previous_space) try writer.writeByte(' ');
            previous_space = true;
        } else {
            try writer.writeByte(byte);
            previous_space = false;
        }
    }
}

fn hasDocComment(doc: SymbolDoc) bool {
    const decl = doc.decl_index.get();
    const target_decl = doc.target_index.get();
    const target_ast = target_decl.file.getAst();
    const target_info = target_decl.extraInfo();
    if (target_ast.nodeTag(target_decl.ast_node) == .root) {
        return hasDocToken(target_ast, target_info.first_doc_comment.unwrap(), .container_doc_comment);
    }
    return hasDocToken(decl.file.getAst(), decl.extraInfo().first_doc_comment.unwrap(), .doc_comment) or
        hasDocToken(target_ast, target_info.first_doc_comment.unwrap(), .doc_comment);
}

fn hasDocToken(ast: *const std.zig.Ast, maybe_token: ?std.zig.Ast.TokenIndex, tag: std.zig.Token.Tag) bool {
    const token = maybe_token orelse return false;
    return ast.tokenTag(token) == tag;
}

fn renderDocComments(writer: anytype, doc: SymbolDoc) !void {
    if (!hasDocComment(doc)) return;
    try writer.writeAll("\ndoc:\n");
    try renderIndentedDocComments(writer, doc, 2);
}

fn renderIndentedDocComments(writer: anytype, doc: SymbolDoc, indent: usize) !void {
    const decl = doc.decl_index.get();
    const target_decl = doc.target_index.get();
    const ast = decl.file.getAst();
    const target_ast = target_decl.file.getAst();
    const target_info = target_decl.extraInfo();

    if (target_ast.nodeTag(target_decl.ast_node) == .root) {
        if (target_info.first_doc_comment.unwrap()) |target_first_doc| {
            try writeDocLines(writer, target_ast, target_first_doc, .container_doc_comment, indent);
        }
        return;
    }

    if (decl.extraInfo().first_doc_comment.unwrap()) |first_doc_comment| {
        try writeDocLines(writer, ast, first_doc_comment, .doc_comment, indent);
    } else if (target_info.first_doc_comment.unwrap()) |target_first_doc| {
        try writeDocLines(writer, target_ast, target_first_doc, .doc_comment, indent);
    }
}

fn writeDocLines(
    writer: anytype,
    ast: *const std.zig.Ast,
    first_token: std.zig.Ast.TokenIndex,
    tag: std.zig.Token.Tag,
    indent: usize,
) !void {
    var token_index = first_token;
    while (ast.tokenTag(token_index) == tag) : (token_index += 1) {
        const comment = ast.tokenSlice(token_index);
        try writeIndent(writer, indent);
        try writer.print("{s}\n", .{std.mem.trimStart(u8, comment[3..], " ")});
    }
}

fn writeIndent(writer: anytype, indent: usize) !void {
    var i: usize = 0;
    while (i < indent) : (i += 1) try writer.writeByte(' ');
}

fn printDocComments(writer: anytype, ast: *const std.zig.Ast, first_token: std.zig.Ast.TokenIndex) !void {
    var token_index = first_token;
    while (ast.tokenTag(token_index) == .doc_comment) : (token_index += 1) {
        const comment = ast.tokenSlice(token_index);
        try writer.print(" {s}\n", .{comment[3..]});
    }
}

fn printContainerDocComments(writer: anytype, ast: *const std.zig.Ast, first_token: std.zig.Ast.TokenIndex) !void {
    var token_index = first_token;
    while (ast.tokenTag(token_index) == .container_doc_comment) : (token_index += 1) {
        const comment = ast.tokenSlice(token_index);
        try writer.print(" {s}\n", .{comment[3..]});
    }
}

fn printSource(writer: anytype, ast: *const std.zig.Ast, node: std.zig.Ast.Node.Index) !void {
    const token_starts = ast.tokens.items(.start);
    const start_token = ast.firstToken(node);
    const end_token = ast.lastToken(node);

    const start_offset = token_starts[start_token];
    const end_offset = if (end_token + 1 < ast.tokens.len)
        token_starts[end_token + 1]
    else
        ast.source.len;

    const source_text = ast.source[start_offset..end_offset];

    // Print each line with indentation
    var lines = std.mem.splitScalar(u8, source_text, '\n');
    while (lines.next()) |line| {
        try writer.print("  {s}\n", .{line});
    }
}

test "query parser expands nested member groups" {
    const allocator = std.testing.allocator;
    var symbols: std.ArrayList([]const u8) = .empty;
    defer {
        for (symbols.items) |symbol| allocator.free(symbol);
        symbols.deinit(allocator);
    }

    try QueryParser.parse(
        allocator,
        "std.multi_array_list.MultiArrayList.(insertBounded, appendAssumeCapacity, Slice.(get, set))",
        &symbols,
    );

    try std.testing.expectEqual(@as(usize, 4), symbols.items.len);
    try std.testing.expectEqualStrings("std.multi_array_list.MultiArrayList.insertBounded", symbols.items[0]);
    try std.testing.expectEqualStrings("std.multi_array_list.MultiArrayList.appendAssumeCapacity", symbols.items[1]);
    try std.testing.expectEqualStrings("std.multi_array_list.MultiArrayList.Slice.get", symbols.items[2]);
    try std.testing.expectEqualStrings("std.multi_array_list.MultiArrayList.Slice.set", symbols.items[3]);
}

test "query parser rejects unbalanced groups" {
    var symbols: std.ArrayList([]const u8) = .empty;
    defer {
        for (symbols.items) |symbol| std.testing.allocator.free(symbol);
        symbols.deinit(std.testing.allocator);
    }

    try std.testing.expectError(
        error.InvalidQuery,
        QueryParser.parse(std.testing.allocator, "std.ArrayList.(init", &symbols),
    );
}

test {
    _ = @import("test_symbol_resolution.zig");
}
