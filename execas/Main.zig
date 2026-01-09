const std = @import("std");
const posix = std.posix;

const ExecError = error{
    NoCommand,
    NoPassword,
    AuthFailed,
    TerminalError,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: execas [-usr=<user>] <command> [args...]\n", .{});
        return;
    }

    var target_user: []const u8 = "root";
    var first_cmd_index: usize = 1;

    // Parse Args
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.startsWith(u8, args[i], "-usr=")) {
            target_user = args[i]["-usr=".len..];
        } else {
            first_cmd_index = i;
            break;
        }
    }

    if (first_cmd_index >= args.len) return ExecError.NoCommand;

    // Get Password securely
    var pw_buf: [256]u8 = undefined;
    const password = try getSecurePassword(&pw_buf, target_user);
    // Ensure we wipe this buffer no matter how the function exits
    defer std.crypto.utils.secureZero(u8, &pw_buf);

    // Verify and Run
    if (try verifyAndRun(allocator, target_user, password, args[first_cmd_index..])) {
        return;
    } else {
        return ExecError.AuthFailed;
    }
}

fn getSecurePassword(buf: [256]u8, user: []const u8) ![]const u8 {
    const stdin_fd = std.io.getStdIn().handle();
    
    // 1. Get current terminal state
    const original_termios = try posix.tcgetattr(stdin_fd);
    var no_echo = original_termios;
    
    // 2. Disable ECHO bit
    no_echo.lflag.ECHO = false;
    try posix.tcsetattr(stdin_fd, .NOW, no_echo);
    
    // 3. Prompt and Read
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Password for {s}: ", .{user});
    
    const stdin = std.io.getStdIn().reader();
    const line = try stdin.readUntilDelimiterOrEof(buf, '\n') orelse return ExecError.NoPassword;
    
    // 4. Restore terminal and print newline
    try posix.tcsetattr(stdin_fd, .NOW, original_termios);
    try stdout.print("\n", .{});

    return std.mem.trimRight(u8, line, "\r");
}

fn verifyAndRun(
    allocator: std.mem.Allocator,
    user: []const u8,
    password: []const u8,
    cmd: []const []const u8,
) !bool {
    // Construct: sudo -S -k -u [user] [cmd...]
    // -S: Read password from stdin
    // -k: Ignore cached sudo credentials (force check)
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    try argv.appendSlice(&.{ "sudo", "-S", "-k", "-u", user });
    try argv.appendSlice(cmd);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Pipe;

    try child.spawn();

    if (child.stdin) |in| {
        try in.writer().print("{s}\n", .{password});
        in.close();
    }

    const term = try child.wait();
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}
