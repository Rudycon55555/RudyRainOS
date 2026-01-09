const std = @import("std");
const posix = std.posix;

const ExecError = error{
    NoCommand,
    NotAllowed,
    UserNotFound,
    InsecureConfig,
    LogFailure,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Identity & Environment Scrubbing
    const uid = posix.getuid();
    const is_root = (uid == 0);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    env_map.clear();
    try env_map.put("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
    try env_map.put("TERM", "xterm-256color");

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: execas [-usr=<user>] <command> [args...]\n", .{});
        return;
    }

    var target_user: []const u8 = "root";
    var cmd_idx: usize = 0;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.startsWith(u8, args[i], "-usr=")) {
            target_user = args[i]["-usr=".len..];
        } else {
            cmd_idx = i;
            break;
        }
    }
    if (cmd_idx == 0) return ExecError.NoCommand;

    // 2. Authorization Logic
    const caller_name = try getCurrentUsername(allocator);
    defer allocator.free(caller_name);

    var allowed = is_root; // Root is always allowed
    if (!allowed) {
        allowed = checkPermissions(allocator, caller_name, target_user) catch |err| {
            try logEvent(caller_name, target_user, args[cmd_idx], .error_cfg);
            return err;
        };
    }

    // 3. Logging & Execution
    if (allowed) {
        try logEvent(caller_name, target_user, args[cmd_idx], .success);
        try runSudo(allocator, target_user, args[cmd_idx..], &env_map);
    } else {
        try logEvent(caller_name, target_user, args[cmd_idx], .denied);
        std.debug.print("execas: {s} is not in the execasers file.\n", .{caller_name});
        posix.exit(1);
    }
}

const LogStatus = enum { success, denied, error_cfg };

fn logEvent(caller: []const u8, target: []const u8, cmd: []const u8, status: LogStatus) !void {
    const log_path = "/var/log/execas.log";
    const file = std.fs.cwd().openFile(log_path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => try std.fs.cwd().createFile(log_path, .{}),
        else => return err,
    };
    defer file.close();
    try file.seekFromEnd(0);

    const ts = std.time.timestamp();
    const status_str = @tagName(status);
    
    var buf: [1024]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "[{d}] {s}: {s} -> {s} (cmd: {s})\n", .{ ts, status_str, caller, target, cmd });
    _ = try file.write(msg);
}

fn checkPermissions(allocator: std.mem.Allocator, caller: []const u8, target: []const u8) !bool {
    const path = "/etc/execasers";
    
    // Validate File Security
    const stat = posix.stat(path) catch return false;
    if (stat.uid != 0 or (stat.mode & 0o022 != 0)) return ExecError.InsecureConfig;

    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();

    var br = std.io.bufferedReader(file.reader());
    var reader = br.reader();
    
    while (true) {
        const line = reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 4096) catch break orelse break;
        defer allocator.free(line);

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (trimmed[0] == '!') {
            var it = std.mem.tokenizeAny(u8, trimmed[1..], " \t(),");
            const entry_user = it.next() orelse continue;

            if (std.mem.eql(u8, entry_user, caller)) {
                while (it.next()) |allowed| {
                    if (std.mem.eql(u8, allowed, "all") or std.mem.eql(u8, allowed, target)) return true;
                }
            }
        }
    }
    return false;
}

fn runSudo(allocator: std.mem.Allocator, target: []const u8, cmd: []const []const u8, env: *std.process.EnvMap) !void {
    var argv = try allocator.alloc([]const u8, 3 + cmd.len);
    defer allocator.free(argv);

    argv[0] = "sudo";
    argv[1] = "-u";
    argv[2] = target;
    for (cmd, 0..) |c, i| argv[3 + i] = c;

    var child = std.process.Child.init(argv, allocator);
    child.envp = env; // Secure Env
    _ = try child.spawnAndWait();
}

fn getCurrentUsername(allocator: std.mem.Allocator) ![]u8 {
    const uid = posix.getuid();
    var buf: [1024]u8 = undefined;
    var pwd: posix.passwd = undefined;
    var result: ?*posix.passwd = null;
    if (posix.getpwuid_r(uid, &pwd, &buf, &result) != 0 or result == null) return error.UserNotFound;
    return try allocator.dupe(u8, std.mem.span(pwd.pw_name));
}
