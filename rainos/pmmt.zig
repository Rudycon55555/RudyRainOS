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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const subcmd = args[1];

    if (std.mem.eql(u8, subcmd, "install")) {
        try cmdInstall(allocator, args[2..]);
    } else {
        try std.io.getStdErr().writer().print("pmmt: unknown command '{s}'\n", .{subcmd});
        try printUsage();
    }
}

fn printUsage() !void {
    const w = std.io.getStdOut().writer();
    try w.print(
        \\Usage:
        \\  pmmt install [--that] [--auto] <package>
        \\
        \\Options:
        \\  --that   Use backend's native UI (raw output)
        \\  --auto   No UI, non-interactive
        \\
    , .{});
}

fn cmdInstall(allocator: std.mem.Allocator, args: [][]u8) !void {
    if (args.len == 0) {
        try std.io.getStdErr().writer().print("pmmt install: missing package name\n", .{});
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
            try std.io.getStdErr().writer().print("pmmt install: unexpected argument '{s}'\n", .{arg});
            return;
        }
    }

    if (pkg_name == null) {
        try std.io.getStdErr().writer().print("pmmt install: missing package name\n", .{});
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
        try std.io.getStdErr().writer().print("pmmt: no package managers configured in PM.list\n", .{});
        return;
    }

    if (!use_auto) {
        try std.io.getStdOut().writer().print("🌧️  Searching for \"{s}\"…\n", .{pkg_name.?});
    }

    var results = try searchAllBackends(allocator, backends, pkg_name.?);
    defer {
        for (results) |r| {
            allocator.free(r.id);
            allocator.free(r.display_name);
            allocator.free(r.description);
        }
        allocator.free(results);
    }

    if (results.len == 0) {
        try std.io.getStdOut().writer().print(
            "pmmt: No results found for '{s}' in any configured package manager.\n",
            .{pkg_name.?},
        );
        return;
    }

    var chosen_index: usize = 0;

    if (results.len == 1 or use_auto) {
        chosen_index = 0;
        if (!use_auto) {
            try std.io.getStdOut().writer().print(
                "🔍  Found in {s}: {s}\n",
                .{ backendName(results[0].backend.kind), results[0].id },
            );
        }
    } else {
        chosen_index = try selectResultInteractive(allocator, results);
    }

    const chosen = results[chosen_index];

    if (!use_auto) {
        try std.io.getStdOut().writer().print(
            "⬇️  Installing from {s}…\n",
            .{backendName(chosen.backend.kind)},
        );
    }

    try installPackage(allocator, chosen, use_that, use_auto);

    if (!use_auto) {
        try std.io.getStdOut().writer().print("✨  Done!\n", .{});
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
    var list = std.ArrayList(Backend).init(allocator);

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    if (home) |h| {
        defer allocator.free(h);
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        try buf.writer().print("{s}/.rainoscli/PM.list", .{h});
        const path = buf.items;

        loadBackendsFromFile(allocator, path, &list) catch {};
    }

    loadBackendsFromFile(allocator, "/etc/rainoscli/PM.list", &list) catch {};

    return list.toOwnedSlice();
}

fn loadBackendsFromFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    list: *std.ArrayList(Backend),
) !void {
    var file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    var reader = file.reader();

    while (true) {
        const line_opt = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 4096);
        if (line_opt == null) break;
        const line = line_opt.?;
        defer allocator.free(line);

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // verify executable exists
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
    var list = std.ArrayList(SearchResult).init(allocator);

    for (backends) |b| {
        var results = searchBackend(allocator, b, pkg) catch {
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
        for (results) |r| {
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

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var reader = stdout_file.reader();
    var tmp: [1024]u8 = undefined;

    while (true) {
        const n = try reader.read(&tmp);
        if (n == 0) break;
        try buf.appendSlice(tmp[0..n]);
    }

    _ = try child.wait();

    return buf.toOwnedSlice();
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

    var list = std.ArrayList(SearchResult).init(allocator);

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

    var list = std.ArrayList(SearchResult).init(allocator);

    var it = std.mem.tokenizeScalar(u8, output, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "Ref")) continue; // header

        // naive parse: first column is app id, rest is description
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

    var list = std.ArrayList(SearchResult).init(allocator);

    var it = std.mem.tokenizeScalar(u8, output, '\n');
    var first = true;
    while (it.next()) |line| {
        if (first) {
            first = false;
            continue; // skip header
        }
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // snap find: name  version  publisher  notes  summary
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

fn selectResultInteractive(
    allocator: std.mem.Allocator,
    results: []SearchResult,
) !usize {
    const stdout = std.io.getStdOut().writer();
    const stdin_fd = std.io.getStdIn().handle;

    // Put terminal in raw mode to capture arrows
    var termios = try posix.tcgetattr(stdin_fd);
    const old_termios = termios;
    termios.lflag &= ~@as(posix.tcflag_t, posix.ICANON | posix.ECHO);
    try posix.tcsetattr(stdin_fd, posix.TCSANOW, termios);
    defer {
        _ = posix.tcsetattr(stdin_fd, posix.TCSANOW, old_termios) catch {};
    }

    var selected: usize = 0;

    while (true) {
        // clear screen
        try stdout.print("\x1b[2J\x1b[H", .{});
        try stdout.print("Multiple matches found. Use ↑/↓ and Enter to choose:\n\n", .{});

        var idx: usize = 0;
        while (idx < results.len) : (idx += 1) {
            const prefix = if (idx == selected) "➤" else " ";
            try stdout.print(
                "{s} [{s}] {s} – {s}\n",
                .{
                    prefix,
                    backendName(results[idx].backend.kind),
                    results[idx].display_name,
                    results[idx].description,
                },
            );
        }

        var buf: [3]u8 = undefined;
        const n = try posix.read(stdin_fd, &buf);
        if (n == 0) continue;

        if (buf[0] == '\n' or buf[0] == '\r') {
            break;
        } else if (buf[0] == 0x1b and n >= 3 and buf[1] == '[') {
            if (buf[2] == 'A') {
                if (selected > 0) selected -= 1;
            } else if (buf[2] == 'B') {
                if (selected + 1 < results.len) selected += 1;
            }
        }
    }

    return selected;
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
            try std.io.getStdErr().writer().print(
                "pmmt: Unknown backend for '{s}'\n",
                .{res.id},
            );
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
        // default: inherit stdout/stderr so backend progress is visible,
        // but we can still print our own messages before/after.
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
    }

    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                try std.io.getStdErr().writer().print(
                    "pmmt: backend exited with status {d}\n",
                    .{code},
                );
            }
        },
        else => {
            try std.io.getStdErr().writer().print(
                "pmmt: backend terminated abnormally\n",
                .{},
            );
        },
    }
}

fn installApt(
    allocator: std.mem.Allocator,
    res: SearchResult,
    use_that: bool,
    use_auto: bool,
) !void {
    // apt needs root → use execas
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
    // snap usually requires root → use execas
    var argv = [_][]const u8{
        "execas",
        "-usr=root",
        res.backend.path,
        "install",
        res.id,
    };
    try spawnBackend(allocator, &argv, use_that, use_auto);
}
