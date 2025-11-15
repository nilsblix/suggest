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

    term.orig_termios = null;

    return term;
}

/// Restore raw mode (if set) and close /dev/tty
pub fn deinit(self: *Self) void {
    // Our best effort is to ignore errors on shutdown.
    self.disableRawMode() catch {};
    self.tty_file.close();
}

pub fn goto(self: *Self, row: usize, col: usize) !void {
    try self.tty_writer.interface.print("\x1b[{d};{d}H", .{ row, col });
}

pub fn saveCursor(self: *Self) !void {
    try self.tty_writer.interface.writeAll("\x1b[s");
}

pub fn restoreCursor(self: *Self) !void {
    try self.tty_writer.interface.writeAll("\x1b[u");
}

pub fn hideCursor(self: *Self) !void {
    try self.tty_writer.interface.writeAll("\x1b[?251");
}

pub fn showCursor(self: *Self) !void {
    try self.tty_writer.interface.writeAll("\x1b[?25h");
}

fn setBgColor(self: *Self, color: Color) !void {
    try self.tty_writer.interface.print("\x1b[48;2;{d};{d};{d}m", .{ color.r, color.g, color.b });
}

fn setFgColor(self: *Self, color: Color) !void {
    try self.tty_writer.interface.print("\x1b[38;2;{d};{d};{d}m", .{ color.r, color.g, color.b });
}

fn setBold(self: *Self) !void {
    try self.tty_writer.interface.writeAll("\x1b[1m");
}

pub const TextStyle = struct {
    bg: ?Color = null,
    fg: ?Color = null,
    bold: bool = false,
};

/// `defer resetSgr` after this.
fn setStyle(self: *Self, style: TextStyle) !void {
    if (style.bg) |bg| {
        try setBgColor(self, bg);
    }
    if (style.fg) |fg| {
        try setFgColor(self, fg);
    }
    if (style.bold) {
        try setBold(self);
    }
}

fn resetSgr(self: *Self) !void {
    try self.tty_writer.interface.writeAll("\x1b[0m");
}

pub fn clearLine(self: *Self) !void {
    try self.tty_writer.interface.writeAll("\x1b[K");
}

/// FIXME: This currently only works when the command is a single row. Make it
/// work with multiple rows.
fn getCommandStart(self: *Self, cursor_idx: usize) !Cursor {
    if (cursor_idx == 0) {
        return try self.getCursor();
    }

    try self.saveCursor();

    const len = cursor_idx;
    try self.tty_writer.interface.print("\x1b[{d}D", .{len});
    const ret = try self.getCursor();

    try self.restoreCursor();
    return ret;
}

/// Same limitations as `getCommandStart`, which is that commands that span
/// several rows are not supported.
pub fn clearCommand(self: *Self, cursor_idx: usize, cmd_start: ?Cursor) !void {
    const start = if (cmd_start) |p| p else try self.getCommandStart(cursor_idx);

    try self.goto(start.row, start.col);
    // Clear from there to end of screen.
    try self.tty_writer.interface.writeAll("\x1b[J");
    try self.tty_writer.interface.flush();
}

/// Clear everything after the current prompt, and render `command`. Calculates
/// the new rows, and cols based on `cursor_idx` and puts the cursor there
/// after rendering.
pub fn clearAndRenderLine(
    self: *Self,
    command: []const u8,
    prev_cursor_idx: usize,
    new_cursor_idx: usize,
) !void {
    // Move to the logical start of the command line based on where the cursor
    // was before this update (`prev_cursor_idx` characters into the command).
    const cmd_start = try self.getCommandStart(prev_cursor_idx);

    // Clear the previously rendered command (and anything after it).
    try self.clearCommand(prev_cursor_idx, cmd_start);

    // Render the updated command starting from the command start.
    try self.tty_writer.interface.writeAll(command);
    try self.tty_writer.interface.flush();

    // Finally, position the cursor at the new logical cursor index within the
    // command. Multi-row commands are not yet supported.
    try self.goto(cmd_start.row, cmd_start.col + new_cursor_idx);
}

/// Renders a rectangle to tty_writer.interface. If border is not null, then it
/// will print out a rectangle with that border. Width and height then becomes
/// inner-width, and inner-height.
pub fn drawRectFlushless(
    self: *Self,
    row: usize,
    col: usize,
    width: usize,
    height: usize,
    style: TextStyle,
    border: ?[8][]const u8,
) !void {
    try saveCursor(self);
    defer restoreCursor(self) catch {};
    defer resetSgr(self) catch {};

    const use_border = border != null;

    const outer_width = if (use_border) width + 2 else width;
    const outer_height = if (use_border) height + 2 else height;

    var dy: usize = 0;
    while (dy < outer_height) : (dy += 1) {
        var dx: usize = 0;
        while (dx < outer_width) : (dx += 1) {
            try printFlushless(self, row + dy, col + dx, " ", style);
        }
    }

    if (border) |b| {
        const bottom_right = Cursor{
            .row = row + 1 + height,
            .col = col + 1 + width,
        };

        // Top-left
        try printFlushless(self, row, col, b[0], style);
        // Top horizontal
        for (col + 1..bottom_right.col) |current_col| {
            try printFlushless(self, row, current_col, b[1], style);
        }
        // Top-right
        try printFlushless(self, row, bottom_right.col, b[2], style);

        // Left and right vertical
        for (row + 1..bottom_right.row) |current_row| {
            try printFlushless(self, current_row, col, b[7], style);
            try printFlushless(self, current_row, bottom_right.col, b[3], style);
        }

        // Bottom-left
        try printFlushless(self, bottom_right.row, col, b[6], style);
        // Bottom horizontal
        for (col + 1..bottom_right.col) |current_col| {
            try printFlushless(self, bottom_right.row, current_col, b[5], style);
        }
        // Bottom-right
        try printFlushless(self, bottom_right.row, bottom_right.col, b[4], style);
    }
}

pub const Cursor = struct {
    row: usize,
    col: usize,
};

pub const Size = struct {
    rows: usize,
    cols: usize,
};

/// We ask the terminal for the cursor position via
/// `ESC [ 6 n`,
/// which the terminal will respond on tty_reader.interface with
/// `ESC [ {row} ; {col} R`.
pub fn getCursor(self: *Self) !Cursor {
    // 1. Ask the terminal for cursor position: ESC [ 6 n
    try self.tty_writer.interface.writeAll("\x1b[6n");
    try self.tty_writer.interface.flush();

    var buf: [32]u8 = undefined;
    var got: usize = 0;

    // 2. Read until we see "R" or run out of buffer.
    while (got < buf.len) {
        const n = try self.tty_reader.interface.readSliceShort(buf[got .. got + 1]);
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

/// Query terminal size (rows, cols) by moving to bottom-right and reading
/// clamped cursor position. Uses save/restore to avoid disturbing the user
/// cursor.
pub fn getSize(self: *Self) !Size {
    try saveCursor(self);
    defer restoreCursor(self) catch {};

    // Jump to an exaggerated bottom-right; terminal clamps to visible area.
    try goto(self, 9999, 9999);

    const pos = try getCursor(self);

    return .{ .rows = pos.row, .cols = pos.col };
}

/// Remember to flush the result.
pub fn printFlushless(self: *Self, row: usize, col: usize, text: []const u8, style: TextStyle) !void {
    try saveCursor(self);
    defer restoreCursor(self) catch {};
    defer resetSgr(self) catch {};

    try setStyle(self, style);

    try goto(self, row, col);
    try self.tty_writer.interface.writeAll(text);
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
