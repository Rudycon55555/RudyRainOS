const std = @import("std");
const posix = std.posix;

const InspectError = error{
    NoTarget,
    NotFound,
    InvalidLiveValue,
};

fn writeOut(s: []const u8) void {
    _ = posix.write(posix.STDOUT_FILENO, s) catch {};
}

fn writeErr(s: []const u8) void {
    _ = posix.write(posix.STDERR_FILENO, s) catch {};
}

const ProcessInfo = struct {
    pid: i32,
    name: []u8,
    cmdline: []u8,
    user: []u8,
    cpu_time_ticks: u64,
    rss_kb: u64,
    state: u8,

    fn deinit(self: *ProcessInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.cmdline);
        allocator.free(self.user);
    }
};

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
            live_ms = std.fmt.parseInt(u64, val, 10) catch {
                writeErr("inspect: invalid --live value\n");
                return InspectError.InvalidLiveValue;
            };
        } else if (std.mem.eql(u8, arg, "--control")) {
            control = true;
        } else if (target == null) {
            target = arg;
        } else {
            writeErr("inspect: unexpected argument\n");
            return;
        }
    }

    if (target == null) {
        printUsage();
        return InspectError.NoTarget;
    }

    const pid = try resolveTargetToPid(allocator, target.?);

    if (live_ms) |duration_ms| {
        try liveInspect(allocator, pid, human, duration_ms);
    } else {
        var info = try readProcessInfo(allocator, pid);
        defer info.deinit(allocator);
        if (human) {
            printHumanInfo(&info);
        } else {
            printRawInfo(&info);
        }
    }

    if (control) try controlProcess(allocator, pid);
}

fn printUsage() void {
    writeOut("Usage: inspect [--human] [--live=MS] [--control] <pid|name>\n");
}

fn resolveTargetToPid(allocator: std.mem.Allocator, target: []const u8) !i32 {
    const parsed_pid = std.fmt.parseInt(i32, target, 10) catch null;
    if (parsed_pid) |pid| return pid;

    var dir = try std.fs.openDirAbsolute("/proc", .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;

        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;

        const name = readProcComm(allocator, pid) catch continue;
        defer allocator.free(name);

        if (std.mem.indexOf(u8, name, target) != null) return pid;
    }

    writeErr("inspect: no matching process\n");
    return InspectError.NotFound;
}

fn readProcComm(allocator: std.mem.Allocator, pid: i32) ![]u8 {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid});
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var content = try file.readToEndAlloc(allocator, 256);

    var end = content.len;
    while (end > 0) {
        const c = content[end - 1];
        if (c == '\n' or c == '\r' or c == ' ' or c == 0) {
            end -= 1;
        } else break;
    }

    return content[0..end];
}

fn readProcessInfo(allocator: std.mem.Allocator, pid: i32) !ProcessInfo {
    const name = try readProcComm(allocator, pid);
    errdefer allocator.free(name);

    const cmdline = try readProcCmdline(allocator, pid);
    errdefer allocator.free(cmdline);

    const user = try getProcessUser(allocator, pid);
    errdefer allocator.free(user);

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

fn readProcCmdline(allocator: std.mem.Allocator, pid: i32) ![]u8 {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pid});
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var raw = try file.readToEndAlloc(allocator, 4096);

    if (raw.len > 0) {
        if (raw.len > 1) {
            for (raw[0 .. raw.len - 1], 0..) |b, i| {
                if (b == 0) raw[i] = ' ';
            }
        }
        var end = raw.len;
        while (end > 0 and raw[end - 1] == 0) {
            end -= 1;
        }
        return raw[0..end];
    }

    return raw;
}

fn getProcessUser(allocator: std.mem.Allocator, pid: i32) ![]u8 {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid});
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var reader = file.deprecatedReader();

    while (true) {
        const line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 512) orelse break;
        defer allocator.free(line);

        if (std.mem.startsWith(u8, line, "Uid:")) {
            var it = std.mem.tokenizeAny(u8, line, " \t");
            _ = it.next(); // "Uid:"
            if (it.next()) |uid_val| {
                return try allocator.dupe(u8, uid_val);
            }
        }
    }

    return try allocator.dupe(u8, "unknown");
}

fn readProcStat(pid: i32) !struct { cpu_ticks: u64, rss_kb: u64, state: u8 } {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid});
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var stat_buf: [1024]u8 = undefined;
    const amt = try file.readAll(&stat_buf);
    const data = stat_buf[0..amt];

    const last_paren = std.mem.lastIndexOfScalar(u8, data, ')') orelse return error.InvalidData;
    const rest = data[last_paren + 1 ..];

    var it = std.mem.tokenizeScalar(u8, rest, ' ');

    const state_tok = it.next() orelse " ";
    const state = state_tok[0];

    var i: usize = 0;
    var utime: u64 = 0;
    var stime: u64 = 0;
    var rss_pages: u64 = 0;

    while (it.next()) |tok| : (i += 1) {
        switch (i) {
            10 => utime = std.fmt.parseInt(u64, tok, 10) catch 0,
            11 => stime = std.fmt.parseInt(u64, tok, 10) catch 0,
            20 => rss_pages = std.fmt.parseInt(u64, tok, 10) catch 0,
            else => {},
        }
    }

    const rss_kb: u64 = rss_pages * 4;

    return .{
        .cpu_ticks = utime + stime,
        .rss_kb = rss_kb,
        .state = state,
    };
}

fn printRawInfo(info: *const ProcessInfo) void {
    var buf: [128]u8 = undefined;
    writeOut("--- PROCESS INFO ---\n");
    writeOut(std.fmt.bufPrint(&buf, "PID: {d}\n", .{info.pid}) catch "");
    writeOut("Name: "); writeOut(info.name); writeOut("\n");
    writeOut("User (UID): "); writeOut(info.user); writeOut("\n");
    writeOut("State: "); writeOut(&[_]u8{info.state}); writeOut("\n");
    writeOut(std.fmt.bufPrint(&buf, "RSS: {d} KB\n", .{info.rss_kb}) catch "");
    writeOut("Cmd: "); writeOut(info.cmdline); writeOut("\n");
}

fn printHumanInfo(info: *const ProcessInfo) void {
    // For now, reuse raw output.
    printRawInfo(info);
}

fn liveInspect(allocator: std.mem.Allocator, pid: i32, human: bool, duration_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (true) {
        var info = try readProcessInfo(allocator, pid);
        defer info.deinit(allocator);

        writeOut("\x1b[2J\x1b[H");
        if (human) {
            printHumanInfo(&info);
        } else {
            printRawInfo(&info);
        }

        const now = std.time.milliTimestamp();
        if (now - start >= duration_ms) break;

        const target = now + 200;
        while (std.time.milliTimestamp() < target) {
            // busy-wait; no portable sleep API in this hybrid stdlib
        }
    }
}

fn controlProcess(allocator: std.mem.Allocator, pid: i32) !void {
    writeOut("\nControl: [k]ill [t]erm [s]top [c]ont [n]ice: ");
    var in_buf: [16]u8 = undefined;
    const n = posix.read(posix.STDIN_FILENO, &in_buf) catch return;
    if (n == 0) return;

    switch (in_buf[0]) {
        'k' => _ = posix.kill(pid, posix.SIG.KILL) catch {},
        't' => _ = posix.kill(pid, posix.SIG.TERM) catch {},
        's' => _ = posix.kill(pid, posix.SIG.STOP) catch {},
        'c' => _ = posix.kill(pid, posix.SIG.CONT) catch {},
        'n' => try reniceProcess(allocator, pid),
        else => writeOut("Invalid option.\n"),
    }
}

fn reniceProcess(allocator: std.mem.Allocator, pid: i32) !void {
    writeOut("New nice value (-20 to 19): ");
    var buf: [16]u8 = undefined;
    const n = posix.read(posix.STDIN_FILENO, &buf) catch return;
    if (n == 0) return;

    const trimmed = std.mem.trim(u8, buf[0..n], " \n\r\t");
    const val = std.fmt.parseInt(i32, trimmed, 10) catch return;

    var pid_str: [16]u8 = undefined;
    var val_str: [16]u8 = undefined;
    const val_s = std.fmt.bufPrint(&val_str, "{d}", .{val}) catch "";
    const pid_s = std.fmt.bufPrint(&pid_str, "{d}", .{pid}) catch "";

    const uid = posix.getuid();

    // If root: run renice directly
    if (uid == 0) {
        const args = &[_][]const u8{ "renice", val_s, "-p", pid_s };
        var child = std.process.Child.init(args, allocator);
        _ = try child.spawnAndWait();
        return;
    }

    // Non-root: go through execas
    const args = &[_][]const u8{ "execas", "-usr=root", "renice", val_s, "-p", pid_s };
    var child = std.process.Child.init(args, allocator);
    _ = try child.spawnAndWait();
}
