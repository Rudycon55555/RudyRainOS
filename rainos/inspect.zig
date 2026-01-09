const std = @import("std");
const posix = std.posix;

const InspectError = error{
    NoTarget,
    NotFound,
    InvalidLiveValue,
};

const ProcessInfo = struct {
    pid: i32,
    name: []u8,
    cmdline: []u8,
    user: []u8,
    cpu_time_ticks: u64,
    rss_kb: u64,
    state: u8,
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

    var human = false;
    var live_ms: ?u64 = null;
    var control = false;
    var target: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--human")) {
            human = true;
        } else if (std.mem.startsWith(u8, arg, "--live=")) {
            const val = arg["--live=".len..];
            live_ms = try std.fmt.parseInt(u64, val, 10) catch {
                try std.io.getStdErr().writer().print("inspect: invalid --live value\n", .{});
                return InspectError.InvalidLiveValue;
            };
        } else if (std.mem.eql(u8, arg, "--control")) {
            control = true;
        } else if (target == null) {
            target = arg;
        } else {
            try std.io.getStdErr().writer().print("inspect: unexpected argument: {s}\n", .{arg});
            return;
        }
    }

    if (target == null) {
        try printUsage();
        return InspectError.NoTarget;
    }

    const pid = try resolveTargetToPid(allocator, target.?);
    var info = try readProcessInfo(allocator, pid);
    defer allocator.free(info.name);
    defer allocator.free(info.cmdline);
    defer allocator.free(info.user);

    if (live_ms) |duration_ms| {
        try liveInspect(allocator, pid, human, duration_ms);
    } else {
        if (human) {
            try printHumanInfo(&info);
        } else {
            try printRawInfo(&info);
        }
    }

    if (control) {
        try controlProcess(allocator, pid);
    }
}

fn printUsage() !void {
    const w = std.io.getStdOut().writer();
    try w.print(
        \\Usage: inspect [--human] [--live=MS] [--control] <pid|name>
        \\
        \\  --human       Show human-friendly interpretation
        \\  --live=MS     Refresh every MS milliseconds for a short period
        \\  --control     Interactively control (kill/stop/cont/term/renice)
        \\
    , .{});
}

fn resolveTargetToPid(allocator: std.mem.Allocator, target: []const u8) !i32 {
    // If numeric, treat as PID
    if (std.fmt.parseInt(i32, target, 10)) |pid| {
        return pid;
    } else |_| {}

    // Otherwise, search /proc by name
    var dir = try std.fs.openDirAbsolute("/proc", .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (!isAllDigits(entry.name)) continue;

        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;

        const name = readProcComm(allocator, pid) catch continue;
        defer allocator.free(name);

        if (std.mem.indexOf(u8, name, target) != null) {
            return pid;
        }
    }

    try std.io.getStdErr().writer().print("inspect: no process found matching '{s}'\n", .{target});
    return InspectError.NotFound;
}

fn isAllDigits(s: []const u8) bool {
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn readProcComm(allocator: std.mem.Allocator, pid: i32) ![]u8 {
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/proc/{d}/comm", .{pid});
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 64);
}

fn readProcessInfo(allocator: std.mem.Allocator, pid: i32) !ProcessInfo {
    var name = try readProcComm(allocator, pid);
    stripNewline(name);

    var cmdline = try readProcCmdline(allocator, pid);
    var user = try getProcessUser(allocator, pid);
    const stat = try readProcStat(pid);

    return ProcessInfo{
        .pid = pid,
        .name = name,
        .cmdline = cmdline,
        .user = user,
        .cpu_time_ticks = stat.cpu_ticks,
        .rss_kb = stat.rss_kb,
        .state = stat.state,
    };
}

fn stripNewline(buf: []u8) void {
    if (buf.len == 0) return;
    if (buf[buf.len - 1] == '\n') buf[buf.len - 1] = 0;
}

fn readProcCmdline(allocator: std.mem.Allocator, pid: i32) ![]u8 {
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/proc/{d}/cmdline", .{pid});
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    var raw = try file.readToEndAlloc(allocator, 4096);
    // Replace NULs with spaces
    for (raw) |*b| {
        if (b.* == 0) b.* = ' ';
    }
    return raw;
}

fn getProcessUser(allocator: std.mem.Allocator, pid: i32) ![]u8 {
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/proc/{d}/status", .{pid});
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var reader = file.reader();
    var line_buf = std.ArrayList(u8).init(allocator);
    defer line_buf.deinit();

    while (true) {
        line_buf.clearRetainingCapacity();
        const line_opt = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 256);
        if (line_opt == null) break;
        const line = line_opt.?;
        defer allocator.free(line);

        if (std.mem.startsWith(u8, line, "Uid:")) {
            var it = std.mem.tokenizeScalar(u8, line[4..], '\t');
            const uid_str = it.next() orelse continue;
            const uid = std.fmt.parseInt(u32, std.mem.trim(u8, uid_str, " \t"), 10) catch continue;
            return try uidToName(allocator, uid);
        }
    }

    return allocator.dupe(u8, "unknown");
}

fn uidToName(allocator: std.mem.Allocator, uid: u32) ![]u8 {
    var buf: [std.posix._SC_GETPW_R_SIZE_MAX]u8 = undefined;
    var pwd: posix.passwd = undefined;
    var result: ?*posix.passwd = null;

    const rc = posix.getpwuid_r(@intCast(uid), &pwd, &buf, &result);
    if (rc != 0 or result == null) return allocator.dupe(u8, "unknown");
    return allocator.dupe(u8, std.mem.span(pwd.pw_name));
}

const StatInfo = struct {
    cpu_ticks: u64,
    rss_kb: u64,
    state: u8,
};

fn readProcStat(pid: i32) !StatInfo {
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/proc/{d}/stat", .{pid});
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var data = try file.readToEndAlloc(std.heap.page_allocator, 512);
    defer std.heap.page_allocator.free(data);

    var it = std.mem.tokenizeScalar(u8, data, ' ');
    var idx: usize = 0;
    var state: u8 = ' ';
    var utime: u64 = 0;
    var stime: u64 = 0;
    var rss_pages: i64 = 0;

    while (it.next()) |tok| : (idx += 1) {
        switch (idx) {
            2 => state = tok[0],
            13 => utime = std.fmt.parseInt(u64, tok, 10) catch 0,
            14 => stime = std.fmt.parseInt(u64, tok, 10) catch 0,
            23 => rss_pages = std.fmt.parseInt(i64, tok, 10) catch 0,
            else => {},
        }
    }

    const page_size = std.mem.page_size;
    const rss_kb: u64 = if (rss_pages > 0) @intCast(@as(u64, @intCast(rss_pages)) * (page_size / 1024)) else 0;

    return StatInfo{
        .cpu_ticks = utime + stime,
        .rss_kb = rss_kb,
        .state = state,
    };
}

fn printRawInfo(info: *const ProcessInfo) !void {
    const w = std.io.getStdOut().writer();
    try w.print("PID: {d}\n", .{info.pid});
    try w.print("User: {s}\n", .{info.user});
    try w.print("Name: {s}\n", .{info.name});
    try w.print("Cmd: {s}\n", .{info.cmdline});
    try w.print("CPU ticks: {d}\n", .{info.cpu_time_ticks});
    try w.print("RSS: {d} KB\n", .{info.rss_kb});
    try w.print("State: {c}\n", .{info.state});
}

fn printHumanInfo(info: *const ProcessInfo) !void {
    const w = std.io.getStdOut().writer();
    try w.print("Process {s} (PID {d})\n", .{info.name, info.pid});
    try w.print("  Owner: {s}\n", .{info.user});
    try w.print("  Command: {s}\n", .{info.cmdline});
    try w.print("  Memory: {d} KB ({s})\n", .{
        info.rss_kb,
        classifyMemory(info.rss_kb),
    });
    try w.print("  CPU time (ticks): {d}\n", .{info.cpu_time_ticks});
    try w.print("  State: {s}\n", .{describeState(info.state)});
}

fn classifyMemory(rss_kb: u64) []const u8 {
    if (rss_kb < 50_000) return "very light";
    if (rss_kb < 200_000) return "normal";
    if (rss_kb < 500_000) return "heavy";
    return "very heavy";
}

fn describeState(state: u8) []const u8 {
    return switch (state) {
        'R' => "Running",
        'S' => "Sleeping",
        'D' => "Uninterruptible sleep",
        'Z' => "Zombie",
        'T' => "Stopped",
        't' => "Tracing stop",
        'X', 'x' => "Dead",
        else => "Unknown",
    };
}

fn liveInspect(allocator: std.mem.Allocator, pid: i32, human: bool, duration_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (true) {
        var info = readProcessInfo(allocator, pid) catch |e| {
            try std.io.getStdErr().writer().print("inspect: failed to read process: {s}\n", .{@errorName(e)});
            return;
        };
        defer allocator.free(info.name);
        defer allocator.free(info.cmdline);
        defer allocator.free(info.user);

        std.io.getStdOut().writer().print("\x1b[2J\x1b[H", .{}) catch {};
        if (human) {
            try printHumanInfo(&info);
        } else {
            try printRawInfo(&info);
        }

        const now = std.time.milliTimestamp();
        if (now - start >= duration_ms) break;
        std.time.sleep(100 * std.time.millisecond);
    }
}

fn controlProcess(allocator: std.mem.Allocator, pid: i32) !void {
    const w = std.io.getStdOut().writer();
    try w.print(
        \\Control options:
        \\  k - kill (SIGKILL)
        \\  t - terminate (SIGTERM)
        \\  s - stop (SIGSTOP)
        \\  c - continue (SIGCONT)
        \\  n - renice
        \\Choose action: 
    , .{});

    var buf: [8]u8 = undefined;
    const r = std.io.getStdIn().reader();
    const len_opt = try r.readUntilDelimiterOrEof(&buf, '\n');
    if (len_opt == null or len_opt.? == 0) return;
    const choice = buf[0];

    switch (choice) {
        'k' => try sendSignal(allocator, pid, posix.SIGKILL),
        't' => try sendSignal(allocator, pid, posix.SIGTERM),
        's' => try sendSignal(allocator, pid, posix.SIGSTOP),
        'c' => try sendSignal(allocator, pid, posix.SIGCONT),
        'n' => try reniceProcess(allocator, pid),
        else => {},
    }
}

fn sendSignal(allocator: std.mem.Allocator, pid: i32, sig: i32) !void {
    const uid = posix.getuid();
    if (uid == 0) {
        _ = posix.kill(pid, sig);
        return;
    }

    // Use execas to send signal as root
    var argv = [_][]const u8{
        "execas",
        "-usr=root",
        "kill",
        "-s",
        undefined,
        undefined,
    };

    var sig_buf: [8]u8 = undefined;
    const sig_str = switch (sig) {
        posix.SIGKILL => "KILL",
        posix.SIGTERM => "TERM",
        posix.SIGSTOP => "STOP",
        posix.SIGCONT => "CONT",
        else => "TERM",
    };
    argv[4] = sig_str;

    const pid_str = try std.fmt.bufPrint(&sig_buf, "{d}", .{pid});
    argv[5] = pid_str;

    var child = std.process.Child.init(&argv, allocator);
    _ = try child.spawnAndWait();
}

fn reniceProcess(allocator: std.mem.Allocator, pid: i32) !void {
    const w = std.io.getStdOut().writer();
    try w.print("New nice value (-20 to 19): ", .{});

    var buf: [16]u8 = undefined;
    const r = std.io.getStdIn().reader();
    const len_opt = try r.readUntilDelimiterOrEof(&buf, '\n');
    if (len_opt == null or len_opt.? == 0) return;

    const trimmed = std.mem.trim(u8, buf[0..len_opt.?], " \t\r\n");
    const nice_val = std.fmt.parseInt(i32, trimmed, 10) catch {
        try w.print("Invalid nice value.\n", .{});
        return;
    };

    const uid = posix.getuid();
    if (uid == 0) {
        _ = posix.setpriority(posix.PRIO_PROCESS, pid, nice_val);
        return;
    }

    var argv = [_][]const u8{
        "execas",
        "-usr=root",
        "renice",
        undefined,
        "-p",
        undefined,
    };

    var nice_buf: [8]u8 = undefined;
    const nice_str = try std.fmt.bufPrint(&nice_buf, "{d}", .{nice_val});
    argv[3] = nice_str;

    var pid_buf: [8]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "{d}", .{pid});
    argv[5] = pid_str;

    var child = std.process.Child.init(&argv, allocator);
    _ = try child.spawnAndWait();
}
