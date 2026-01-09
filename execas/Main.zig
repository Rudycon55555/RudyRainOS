const std = @import("std");

const ExecError = error{
    NoCommand,
    NoPassword,
    NoTargetUser,
    NotAllowed,
    UserNotFound,
    AuthFailed,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try std.io.getStdErr().writer().print(
            "Usage: execas [-usr=<user>] [-passwd=<password>] <command> [args...]\n",
            .{},
        );
        return;
    }

    var target_user: []const u8 = "root";
    var password: ?[]const u8 = null;
    var first_cmd_index: usize = 1;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "-usr=")) {
            target_user = arg["-usr=".len..];
        } else if (std.mem.startsWith(u8, arg, "-passwd=")) {
            password = arg["-passwd=".len..];
        } else {
            first_cmd_index = i;
            break;
        }
    }

    if (first_cmd_index >= args.len) {
        return fail("execas: no command specified\n", ExecError.NoCommand);
    }

    const caller_name = try getCurrentUsername(allocator);
    defer allocator.free(caller_name);

    if (!try userExists(target_user)) {
        return fail("execas: target user does not exist\n", ExecError.UserNotFound);
    }

    if (!try isAllowed(allocator, caller_name, target_user)) {
        return fail("execas: not allowed by /etc/execasers\n", ExecError.NotAllowed);
    }

    var pw_buf: [256]u8 = undefined;
    if (password == null) {
        password = try promptPassword(&pw_buf, target_user);
    }

    if (!try verifyPasswordWithSudo(allocator, target_user, password.?)) {
        return fail("execas: authentication failed\n", ExecError.AuthFailed);
    }

    try runCommandWithSudo(allocator, target_user, password.?, args[first_cmd_index..]);
}

fn fail(msg: []const u8, err: anyerror) !void {
    try std.io.getStdErr().writer().print("{s}", .{msg});
    return err;
}

fn getCurrentUsername(allocator: std.mem.Allocator) ![]u8 {
    const uid = std.os.getuid();
    var buf: [std.posix._SC_GETPW_R_SIZE_MAX]u8 = undefined;
    var pwd: std.posix.passwd = undefined;
    var result: ?*std.posix.passwd = null;

    const rc = std.posix.getpwuid_r(uid, &pwd, &buf, &result);
    if (rc != 0 or result == null) {
        return error.Unexpected;
    }

    return std.mem.dupe(allocator, u8, std.mem.span(pwd.pw_name));
}

fn userExists(name: []const u8) !bool {
    var buf: [std.posix._SC_GETPW_R_SIZE_MAX]u8 = undefined;
    var pwd: std.posix.passwd = undefined;
    var result: ?*std.posix.passwd = null;

    const rc = std.posix.getpwnam_r(name, &pwd, &buf, &result);
    if (rc != 0) return error.Unexpected;
    return result != null;
}

fn promptPassword(buf: []u8, target_user: []const u8) ![]const u8 {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Password for {s}: ", .{target_user});
    const stdin = std.io.getStdIn().reader();
    const len_opt = try stdin.readUntilDelimiterOrEof(buf, '\n');
    if (len_opt) |len| {
        if (len == 0) return ExecError.NoPassword;
        return buf[0..len];
    }
    return ExecError.NoPassword;
}

fn isAllowed(allocator: std.mem.Allocator, caller: []const u8, target: []const u8) !bool {
    if (std.mem.eql(u8, caller, "root")) return true;

    const path = "/etc/execasers";
    var file = std.fs.cwd().openFile(path, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    defer file.close();

    var reader = file.reader();
    var line_buf = std.ArrayList(u8).init(allocator);
    defer line_buf.deinit();

    var in_comment_block = false;

    while (true) {
        line_buf.clearRetainingCapacity();
        const line_opt = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024);
        if (line_opt == null) break;
        const line = line_opt.?;
        defer allocator.free(line);

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (in_comment_block) {
            if (std.mem.eql(u8, trimmed, ")")) {
                in_comment_block = false;
            }
            continue;
        }

        if (trimmed[0] == '*') {
            if (!std.mem.containsAtLeast(u8, trimmed, 1, ")")) {
                in_comment_block = true;
            }
            continue;
        }

        if (trimmed[0] == '!') {
            const rest = trimmed[1..];
            const open_paren = std.mem.indexOfScalar(u8, rest, '(') orelse continue;
            const close_paren = std.mem.lastIndexOfScalar(u8, rest, ')') orelse continue;

            const user_name = std.mem.trim(u8, rest[0..open_paren], " \t");
            const list = std.mem.trim(u8, rest[open_paren + 1 .. close_paren], " \t");

            if (!std.mem.eql(u8, user_name, caller)) continue;

            if (std.mem.eql(u8, list, "all")) return true;

            var it = std.mem.tokenizeScalar(u8, list, ',');
            while (it.next()) |tok| {
                const t = std.mem.trim(u8, tok, " \t");
                if (t.len == 0) continue;
                if (std.mem.eql(u8, t, target)) return true;
            }
        }
    }

    return false;
}

fn verifyPasswordWithSudo(
    allocator: std.mem.Allocator,
    target_user: []const u8,
    password: []const u8,
) !bool {
    var argv = try allocator.alloc([]const u8, 5);
    defer allocator.free(argv);

    argv[0] = "sudo";
    argv[1] = "-S";
    argv[2] = "-u";
    argv[3] = target_user;
    argv[4] = "true";

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    if (child.stdin) |stdin| {
        var w = stdin.writer();
        try w.print("{s}\n", .{password});
        _ = stdin.close();
    }

    const term = try child.wait();
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn runCommandWithSudo(
    allocator: std.mem.Allocator,
    target_user: []const u8,
    password: []const u8,
    cmd_args: []const []const u8,
) !void {
    const total = 4 + cmd_args.len;
    var argv = try allocator.alloc([]const u8, total);
    defer allocator.free(argv);

    argv[0] = "sudo";
    argv[1] = "-S";
    argv[2] = "-u";
    argv[3] = target_user;

    var i: usize = 0;
    while (i < cmd_args.len) : (i += 1) {
        argv[4 + i] = cmd_args[i];
    }

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    if (child.stdin) |stdin| {
        var w = stdin.writer();
        try w.print("{s}\n", .{password});
        _ = stdin.close();
    }

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                try std.io.getStdErr().writer().print(
                    "execas: command exited with status {d}\n",
                    .{code},
                );
            }
        },
        else => {
            try std.io.getStdErr().writer().print(
                "execas: command terminated abnormally\n",
                .{},
            );
        },
    }
}
