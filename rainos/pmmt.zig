const std = @import("std");
const posix = std.posix;

pub const BackendKind = enum {
    apt,
    flatpak,
    snap,
    unknown,
};

pub const Backend = struct {
    path: []const u8,
    kind: BackendKind,
};

pub const SearchResult = struct {
    backend: Backend,
    id: []u8,          // package id / name / flatpak id
    display_name: []u8,
    description: []u8,
};

fn writeOut(s: []const u8) void {
    _ = posix.write(posix.STDOUT_FILENO, s) catch {};
}

fn writeErr(s: []const u8) void {
    _ = posix.write(posix.STDERR_FILENO, s) catch {};
}

fn Vec(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        items: []T,
        len: usize,

        fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .allocator = allocator,
                .items = &[_]T{},
                .len = 0,
            };
        }

        fn deinit(self: *@This()) void {
            if (self.items.len > 0) {
                self.allocator.free(self.items);
            }
        }

        fn append(self: *@This(), value: T) !void {
            if (self.len == self.items.len) {
                const new_cap: usize = if (self.items.len == 0) 4 else self.items.len * 2;
                var new = try self.allocator.alloc(T, new_cap);
                if (self.items.len > 0) {
                    var i: usize = 0;
                    while (i < self.len) : (i += 1) {
                        new[i] = self.items[i];
                    }
                    self.allocator.free(self.items);
                }
                self.items = new;
            }
            self.items[self.len] = value;
            self.len += 1;
        }

        fn appendSlice(self: *@This(), slice: []const T) !void {
            var i: usize = 0;
            while (i < slice.len) : (i += 1) {
                try self.append(slice[i]);
            }
        }

        fn toOwnedSlice(self: *@This()) ![]T {
            const out = try self.allocator.alloc(T, self.len);
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                out[i] = self.items[i];
            }
            self.deinit();
            return out;
        }
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const subcmd = args[1];

    if (std.mem.eql(u8, subcmd, "install")) {
        try cmdInstall(allocator, args[2..]);
    } else {
        writeErr("pmmt: unknown command '");
        writeErr(subcmd);
        writeErr("'\n");
        printUsage();
    }
}

fn printUsage() void {
    writeOut(
        \\Usage:
        \\  pmmt install [--that] [--auto] <package>
        \\
        \\Options:
        \\  --that   Use backend's native UI (raw output)
        \\  --auto   No UI, non-interactive
        \\
    );
}

fn cmdInstall(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    if (args.len == 0) {
        writeErr("pmmt install: missing package name\n");
        return;
    }

    var use_that = false;
    var use_auto = false;
    var pkg_name: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--that")) {
            use_that = true;
        } else if (std.mem.eql(u8, arg, "--auto")) {
            use_auto = true;
        } else if (pkg_name == null) {
            pkg_name = arg;
        } else {
            writeErr("pmmt install: unexpected argument '");
            writeErr(arg);
            writeErr("'\n");
            return;
        }
    }

    if (pkg_name == null) {
        writeErr("pmmt install: missing package name\n");
        return;
    }

    const backends = try loadBackends(allocator);
    defer {
        for (backends) |b| {
            allocator.free(b.path);
        }
        allocator.free(backends);
    }

    if (backends.len == 0) {
        writeErr("pmmt: no package managers configured in PM.list\n");
        return;
    }

    if (!use_auto) {
        writeOut("🌧️  Searching for \"");
        writeOut(pkg_name.?);
        writeOut("\"…\n");
    }

    const results = try searchAllBackends(allocator, backends, pkg_name.?);
    defer {
        for (results) |r| {
            allocator.free(r.id);
            allocator.free(r.display_name);
            allocator.free(r.description);
        }
        allocator.free(results);
    }

    if (results.len == 0) {
        writeOut("pmmt: No results found for '");
        writeOut(pkg_name.?);
        writeOut("' in any configured package manager.\n");
        return;
    }

    var chosen_index: usize = 0;

    if (results.len == 1 or use_auto) {
        chosen_index = 0;
        if (!use_auto) {
            var buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(
                &buf,
                "🔍  Found in {s}: {s}\n",
                .{ backendName(results[0].backend.kind), results[0].id },
            ) catch "";
            writeOut(line);
        }
    } else {
        chosen_index = try selectResultInteractive(results);
    }

    const chosen = results[chosen_index];

    if (!use_auto) {
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "⬇️  Installing from {s}…\n",
            .{backendName(chosen.backend.kind)},
        ) catch "";
        writeOut(line);
    }

    try installPackage(allocator, chosen, use_that, use_auto);

    if (!use_auto) {
        writeOut("✨  Done!\n");
    }
}

fn backendName(kind: BackendKind) []const u8 {
    return switch (kind) {
        .apt => "APT",
        .flatpak => "Flatpak",
        .snap => "Snap",
        .unknown => "Unknown",
    };
}

fn loadBackends(allocator: std.mem.Allocator) ![]Backend {
    var list = Vec(Backend).init(allocator);

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    if (home) |h| {
        defer allocator.free(h);

        var buf = Vec(u8).init(allocator);
        defer buf.deinit();

        // build path: "$HOME/.rainoscli/PM.list"
        try buf.appendSlice(h);
        try buf.append('/');

        try buf.append('.');
        try buf.append('r');
        try buf.append('a');
        try buf.append('i');
        try buf.append('n');
        try buf.append('o');
        try buf.append('s');
        try buf.append('c');
        try buf.append('l');
        try buf.append('i');
        try buf.append('/');

        try buf.append('P');
        try buf.append('M');
        try buf.append('.');
        try buf.append('l');
        try buf.append('i');
        try buf.append('s');
        try buf.append('t');

        const path = buf.items[0..buf.len];

        loadBackendsFromFile(allocator, path, &list) catch {};
    }

    loadBackendsFromFile(allocator, "/etc/rainoscli/PM.list", &list) catch {};

    return list.toOwnedSlice();
}

fn loadBackendsFromFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    list: *Vec(Backend),
) !void {
    var file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    var reader = file.deprecatedReader();

    while (true) {
        const line_opt = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 4096);
        if (line_opt == null) break;
        const line = line_opt.?;
        defer allocator.free(line);

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.fs.openFileAbsolute(trimmed, .{})) |f| {
            f.close();
        } else |_| {
            continue;
        }

        const kind = detectBackendKind(trimmed);

        const copy_path = try allocator.dupe(u8, trimmed);
        try list.append(.{
            .path = copy_path,
            .kind = kind,
        });
    }
}

fn detectBackendKind(path: []const u8) BackendKind {
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "apt") or std.mem.eql(u8, base, "apt-get")) return .apt;
    if (std.mem.eql(u8, base, "flatpak")) return .flatpak;
    if (std.mem.eql(u8, base, "snap")) return .snap;
    return .unknown;
}

fn searchAllBackends(
    allocator: std.mem.Allocator,
    backends: []Backend,
    pkg: []const u8,
) ![]SearchResult {
    var list = Vec(SearchResult).init(allocator);

    for (backends) |b| {
        const results = searchBackend(allocator, b, pkg) catch {
            continue;
        };
        defer {
            for (results) |r| {
                allocator.free(r.id);
                allocator.free(r.display_name);
                allocator.free(r.description);
            }
            allocator.free(results);
        }
        var i: usize = 0;
        while (i < results.len) : (i += 1) {
            const r = results[i];
            try list.append(.{
                .backend = b,
                .id = try allocator.dupe(u8, r.id),
                .display_name = try allocator.dupe(u8, r.display_name),
                .description = try allocator.dupe(u8, r.description),
            });
        }
    }

    return list.toOwnedSlice();
}

fn searchBackend(
    allocator: std.mem.Allocator,
    backend: Backend,
    pkg: []const u8,
) ![]SearchResult {
    return switch (backend.kind) {
        .apt => searchApt(allocator, backend, pkg),
        .flatpak => searchFlatpak(allocator, backend, pkg),
        .snap => searchSnap(allocator, backend, pkg),
        .unknown => allocator.alloc(SearchResult, 0),
    };
}

fn spawnCapture(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const stdout_file = child.stdout.?;
    defer stdout_file.close();

    var buf = Vec(u8).init(allocator);
    defer buf.deinit();

    var reader = stdout_file.deprecatedReader();
    var tmp: [1024]u8 = undefined;

    while (true) {
        const n = reader.read(&tmp) catch break;
        if (n == 0) break;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try buf.append(tmp[i]);
        }
    }

    _ = try child.wait();

    const out = try allocator.alloc(u8, buf.len);
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        out[i] = buf.items[i];
    }
    return out;
}

fn searchApt(
    allocator: std.mem.Allocator,
    backend: Backend,
    pkg: []const u8,
) ![]SearchResult {
    var argv = [_][]const u8{
        backend.path,
        "search",
        pkg,
    };

    const output = try spawnCapture(allocator, &argv);
    defer allocator.free(output);

    var list = Vec(SearchResult).init(allocator);

    var it = std.mem.tokenizeScalar(u8, output, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const idx = std.mem.indexOfScalar(u8, trimmed, ' ') orelse continue;
        const pkg_name = std.mem.trim(u8, trimmed[0..idx], " \t");
        const rest = std.mem.trim(u8, trimmed[idx..], " \t-");

        const id = try allocator.dupe(u8, pkg_name);
        const disp = try allocator.dupe(u8, pkg_name);
        const desc = try allocator.dupe(u8, rest);

        try list.append(.{
            .backend = backend,
            .id = id,
            .display_name = disp,
            .description = desc,
        });
    }

    return list.toOwnedSlice();
}

fn searchFlatpak(
    allocator: std.mem.Allocator,
    backend: Backend,
    pkg: []const u8,
) ![]SearchResult {
    var argv = [_][]const u8{
        backend.path,
        "search",
        pkg,
    };

    const output = try spawnCapture(allocator, &argv);
    defer allocator.free(output);

    var list = Vec(SearchResult).init(allocator);

    var it = std.mem.tokenizeScalar(u8, output, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "Ref")) continue; // header

        const id_end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse continue;
        const id_slice = std.mem.trim(u8, trimmed[0..id_end], " \t");
        const rest = std.mem.trim(u8, trimmed[id_end..], " \t");

        const id = try allocator.dupe(u8, id_slice);
        const disp = try allocator.dupe(u8, id_slice);
        const desc = try allocator.dupe(u8, rest);

        try list.append(.{
            .backend = backend,
            .id = id,
            .display_name = disp,
            .description = desc,
        });
    }

    return list.toOwnedSlice();
}

fn searchSnap(
    allocator: std.mem.Allocator,
    backend: Backend,
    pkg: []const u8,
) ![]SearchResult {
    var argv = [_][]const u8{
        backend.path,
        "find",
        pkg,
    };

    const output = try spawnCapture(allocator, &argv);
    defer allocator.free(output);

    var list = Vec(SearchResult).init(allocator);

    var it = std.mem.tokenizeScalar(u8, output, '\n');
    var first = true;
    while (it.next()) |line| {
        if (first) {
            first = false;
            continue; // skip header
        }
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        var tok = std.mem.tokenizeScalar(u8, trimmed, ' ');
        const name_tok = tok.next() orelse continue;
        const name = std.mem.trim(u8, name_tok, " \t");

        const summary_idx = std.mem.indexOfScalar(u8, trimmed, ' ') orelse continue;
        const summary = std.mem.trim(u8, trimmed[summary_idx..], " \t");

        const id = try allocator.dupe(u8, name);
        const disp = try allocator.dupe(u8, name);
        const desc = try allocator.dupe(u8, summary);

        try list.append(.{
            .backend = backend,
            .id = id,
            .display_name = disp,
            .description = desc,
        });
    }

    return list.toOwnedSlice();
}

fn selectResultInteractive(results: []SearchResult) !usize {
    writeOut("Multiple matches found:\n\n");

    var idx: usize = 0;
    var buf: [512]u8 = undefined;
    while (idx < results.len) : (idx += 1) {
        const line = std.fmt.bufPrint(
            &buf,
            "{d}) [{s}] {s} – {s}\n",
            .{
                idx + 1,
                backendName(results[idx].backend.kind),
                results[idx].display_name,
                results[idx].description,
            },
        ) catch "";
        writeOut(line);
    }

    writeOut("\nEnter choice (number): ");

    var in_buf: [32]u8 = undefined;
    const n = posix.read(posix.STDIN_FILENO, &in_buf) catch 0;
    if (n == 0) return 0;

    const trimmed = std.mem.trim(u8, in_buf[0..n], " \t\r\n");
    const choice = std.fmt.parseInt(usize, trimmed, 10) catch return 0;

    if (choice == 0 or choice > results.len) return 0;

    return choice - 1;
}

fn installPackage(
    allocator: std.mem.Allocator,
    res: SearchResult,
    use_that: bool,
    use_auto: bool,
) !void {
    switch (res.backend.kind) {
        .apt => try installApt(allocator, res, use_that, use_auto),
        .flatpak => try installFlatpak(allocator, res, use_that, use_auto),
        .snap => try installSnap(allocator, res, use_that, use_auto),
        .unknown => {
            writeErr("pmmt: Unknown backend for '");
            writeErr(res.id);
            writeErr("'\n");
        },
    }
}

fn spawnBackend(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    use_that: bool,
    use_auto: bool,
) !void {
    var child = std.process.Child.init(argv, allocator);

    if (use_auto) {
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
    } else if (use_that) {
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
    } else {
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
    }

    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                var buf: [128]u8 = undefined;
                const line = std.fmt.bufPrint(
                    &buf,
                    "pmmt: backend exited with status {d}\n",
                    .{code},
                ) catch "";
                writeErr(line);
            }
        },
        else => {
            writeErr("pmmt: backend terminated abnormally\n");
        },
    }
}

fn installApt(
    allocator: std.mem.Allocator,
    res: SearchResult,
    use_that: bool,
    use_auto: bool,
) !void {
    var argv = [_][]const u8{
        "execas",
        "-usr=root",
        res.backend.path,
        "install",
        res.id,
    };
    try spawnBackend(allocator, &argv, use_that, use_auto);
}

fn installFlatpak(
    allocator: std.mem.Allocator,
    res: SearchResult,
    use_that: bool,
    use_auto: bool,
) !void {
    var argv = [_][]const u8{
        res.backend.path,
        "install",
        res.id,
    };
    try spawnBackend(allocator, &argv, use_that, use_auto);
}

fn installSnap(
    allocator: std.mem.Allocator,
    res: SearchResult,
    use_that: bool,
    use_auto: bool,
) !void {
    var argv = [_][]const u8{
        "execas",
        "-usr=root",
        res.backend.path,
        "install",
        res.id,
    };
    try spawnBackend(allocator, &argv, use_that, use_auto);
}
