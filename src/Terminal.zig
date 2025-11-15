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
/// `ESC [ 6 n`, which the terminal will respond to with
/// `ESC [ {row} ; {col} R` on tty_reader.interface.
///
/// When the user is typing quickly, there can already be pending key bytes in
/// the TTY buffer before the DSR response arrives. This implementation
/// therefore streams bytes and searches for a full `ESC [ row ; col R`
/// sequence, ignoring unrelated bytes.
pub fn getCursor(self: *Self) !Cursor {
    // Ask the terminal for cursor position: ESC [ 6 n
    try self.tty_writer.interface.writeAll("\x1b[6n");
    try self.tty_writer.interface.flush();

    const State = enum {
        idle,
        after_esc,
        after_csi,
        row,
        after_semicolon,
        col,
    };

    var state: State = .idle;
    var row: usize = 0;
    var col: usize = 0;
    var have_row = false;
    var have_col = false;

    // Read one byte at a time and look for ESC [ row ; col R.
    var scratch: [1]u8 = undefined;
    var read_count: usize = 0;
    // Arbitrary value for max amount of bytes. This is still plenty for e.g.
    // ESC[9999;9999R plus noise.
    const max_bytes: usize = 64;

    while (read_count < max_bytes) {
        const n = try self.tty_reader.interface.readSliceShort(&scratch);
        if (n == 0) break; // EOF-ish
        read_count += n;

        const b = scratch[0];

        switch (state) {
            .idle => {
                if (b == 0x1b) {
                    state = .after_esc;
                    row = 0;
                    col = 0;
                    have_row = false;
                    have_col = false;
                } else {
                    // Ignore unrelated input (user typing, other control seqs).
                }
            },
            .after_esc => {
                if (b == '[') {
                    state = .after_csi;
                } else {
                    // Not a CSI sequence, therefore reset and possibly treat this as a new ESC.
                    state = .idle;
                    if (b == 0x1b) {
                        state = .after_esc;
                    }
                }
            },
            .after_csi => {
                if (b >= '0' and b <= '9') {
                    state = .row;
                    have_row = true;
                    row = @as(usize, b - '0');
                } else {
                    // Some other CSI sequence, therefore abort this attempt.
                    state = .idle;
                }
            },
            .row => {
                if (b >= '0' and b <= '9') {
                    row = row * 10 + @as(usize, b - '0');
                } else if (b == ';' and have_row) {
                    state = .after_semicolon;
                } else {
                    // Malformed row, therefore start over.
                    state = .idle;
                }
            },
            .after_semicolon => {
                if (b >= '0' and b <= '9') {
                    state = .col;
                    have_col = true;
                    col = @as(usize, b - '0');
                } else {
                    // Malformed, therefore reset.
                    state = .idle;
                }
            },
            .col => {
                if (b >= '0' and b <= '9') {
                    col = col * 10 + @as(usize, b - '0');
                } else if (b == 'R' and have_col) {
                    // Successfully parsed ESC [ row ; col R.
                    return .{ .row = row, .col = col };
                } else {
                    // Not the expected terminator, therefore reset.
                    state = .idle;
                }
            },
        }
    }

    // We failed to observe a valid DSR reply within max_bytes.
    return error.BadResponse;
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
