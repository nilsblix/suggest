const std = @import("std");
const posix = std.posix;

/// All drawing and input goes to /dev/tty
tty_file: std.fs.File,

/// Internal buffers for the /dev/tty reader/writer
out_buf: [1024]u8 = undefined,
in_buf: [1024]u8 = undefined,

/// Concrete File.Reader/Writer for /dev/tty
tty_writer: std.fs.File.Writer,
tty_reader: std.fs.File.Reader,

/// Public interfaces for reading/writing.
stdout: *std.io.Writer,
stdin: *std.io.Reader,

/// Original terminal settings (if raw mode was enabled)
orig_termios: ?posix.termios = null,

const Self = @This();

pub const Color = struct { r: u8, g: u8, b: u8 };

/// Construct a Terminal that talks to /dev/tty
pub fn init() !Self {
    var term: Self = undefined;

    term.tty_file = try std.fs.cwd().openFile(
        "/dev/tty",
        .{ .mode = .read_write },
    );

    term.out_buf = undefined;
    term.in_buf = undefined;

    term.tty_writer = term.tty_file.writer(&term.out_buf);
    term.tty_reader = term.tty_file.reader(&term.in_buf);

    term.stdout = &term.tty_writer.interface;
    term.stdin = &term.tty_reader.interface;

    term.orig_termios = null;

    return term;
}

/// Restore raw mode (if set) and close /dev/tty
pub fn deinit(self: *Self) void {
    // Our best effort is to ignore errors on shutdown.
    self.disableRawMode() catch {};
    self.tty_file.close();
}

pub fn goto(self: Self, row: usize, col: usize) !void {
    try self.stdout.print("\x1b[{d};{d}H", .{ row, col });
}

pub fn saveCursor(self: Self) !void {
    try self.stdout.writeAll("\x1b[s");
}

pub fn restoreCursor(self: Self) !void {
    try self.stdout.writeAll("\x1b[u");
}

fn setBgColor(self: Self, color: Color) !void {
    try self.stdout.print("\x1b[48;2;{d};{d};{d}m", .{ color.r, color.g, color.b });
}

fn resetSgr(self: Self) !void {
    try self.stdout.writeAll("\x1b[0m");
}

pub fn clearLine(self: Self) !void {
    try self.stdout.writeAll("\x1b[K");
}

/// TODO: Add borders.
pub fn drawRect(
    self: Self,
    row: usize,
    col: usize,
    width: usize,
    height: usize,
    color: Color,
) !void {
    // Ensure we leave the cursor where we found it and reset any SGR.
    try saveCursor(self);
    errdefer restoreCursor(self) catch {};
    errdefer resetSgr(self) catch {};

    var dy: usize = 0;
    while (dy < height) : (dy += 1) {
        // 1. Move to start of the current line of the rectangle
        try goto(self, row + dy, col);

        // 2. Set background color for the row
        try setBgColor(self, color);

        // 3. Erase width characters from the cursor position without moving
        // the cursor and without causing wrap/scroll (CSI Ps X)
        try self.stdout.print("\x1b[{d}X", .{width});

        // 4. Reset attributes before next iteration to avoid leaking SGR
        try resetSgr(self);
    }

    // Restore cursor to original position and flush
    try restoreCursor(self);
    try self.stdout.flush();
}

pub const Cursor = struct {
    row: usize,
    col: usize,
};

/// We ask the terminal for the cursor position via
/// `ESC [ 6 n`,
/// which the terminal will respond on stdin with
/// `ESC [ {row} ; {col} R`.
pub fn getCursor(self: Self) !Cursor {
    // 1. Ask the terminal for cursor position: ESC [ 6 n
    try self.stdout.writeAll("\x1b[6n");
    try self.stdout.flush();

    var buf: [32]u8 = undefined;
    var got: usize = 0;

    // 2. Read until we see "R" or run out of buffer.
    while (got < buf.len) {
        const n = try self.stdin.readSliceShort(buf[got .. got + 1]);
        if (n == 0) break; // EOF-ish
        got += n;
        if (buf[got - 1] == 'R') break;
    }

    // 3. Check that the format of the cursor position is correct.
    if (got < 2 or buf[0] != 0x1b or buf[1] != '[') {
        return error.BadResponse;
    }

    // 4. Extract the row information.
    var i: usize = 2;
    var row: usize = 0;
    while (i < got and buf[i] >= '0' and buf[i] <= '9') : (i += 1) {
        row = row * 10 + @as(usize, buf[i] - '0');
    }

    // 5. Check that the next information is the column information.
    if (i >= got or buf[i] != ';') {
        return error.BadResponse;
    }

    // 6. Skip the ';' byte.
    i += 1;

    // 7. Extract the col information, similar to how we got row
    // information.
    var col: usize = 0;
    while (i < got and buf[i] >= '0' and buf[i] <= '9') : (i += 1) {
        col = col * 10 + @as(usize, buf[i] - '0');
    }

    // 8. The expected last byte is 'R', which we used as a sentinel
    // earlier.
    if (i >= got or buf[i] != 'R') {
        return error.BadResponse;
    }

    return .{ .row = row, .col = col };
}

pub fn printAt(self: Self, row: usize, col: usize, text: []const u8) !void {
    // Save and restore cursor so we don't affect surrounding state
    try saveCursor(self);
    errdefer restoreCursor(self) catch {};

    try goto(self, row, col);
    try self.stdout.writeAll(text);

    try restoreCursor(self);
    try self.stdout.flush();
}

pub fn printAtBg(self: Self, row: usize, col: usize, text: []const u8, bg: Color) !void {
    // Print text with a specific background color, without changing
    // surrounding cursor position or lingering attributes.
    try saveCursor(self);
    errdefer restoreCursor(self) catch {};
    errdefer resetSgr(self) catch {};

    try goto(self, row, col);
    try setBgColor(self, bg);
    try self.stdout.writeAll(text);
    try resetSgr(self);

    try restoreCursor(self);
    try self.stdout.flush();
}

pub fn enableRawMode(self: *Self) !void {
    const fd = self.tty_file.handle;

    // Fail nicely if for some reason /dev/tty isn't a TTY. I got some weird
    // errors when I tried to bind this program's executable to a zsh-keybind,
    // which was due to zsh creating some pseudo-terminal with weird
    // permissions/acceses. This is merely a fail-safe.
    if (!posix.isatty(fd)) {
        return error.NotATerminal;
    }

    const orig = try posix.tcgetattr(fd);
    self.orig_termios = orig;

    var raw = orig;

    // Disable canonical mode & echo:
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;

    // Make reads return after at least 1 byte
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    try posix.tcsetattr(fd, posix.TCSA.FLUSH, raw);
}

pub fn disableRawMode(self: *Self) !void {
    if (self.orig_termios) |orig| {
        const fd = self.tty_file.handle;
        try posix.tcsetattr(fd, posix.TCSA.FLUSH, orig);
        self.orig_termios = null;
    }
}
