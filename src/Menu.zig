const std = @import("std");
const Allocator = std.mem.Allocator;
const Terminal = @import("Terminal.zig");

const Self = @This();

const Border = union(enum) {
    none,
    rounded,
    square,
    double,
    simple,

    /// Returns optional border chars in this order:
    /// `1 2 3
    /// 8   4
    /// 7 6 5`
    pub fn sides(self: Border) ?[8][]const u8 {
        switch (self) {
            .none => return null,
            .rounded => return .{
                "\u{256D}",
                "\u{2500}",
                "\u{256E}",
                "\u{2502}",
                "\u{256F}",
                "\u{2500}",
                "\u{2570}",
                "\u{2502}",
            },
            .square => return .{
                "\u{250C}",
                "\u{2500}",
                "\u{2510}",
                "\u{2502}",
                "\u{2518}",
                "\u{2500}",
                "\u{2514}",
                "\u{2502}",
            },
            .double => return .{
                "\u{2554}",
                "\u{2550}",
                "\u{2557}",
                "\u{2551}",
                "\u{255D}",
                "\u{2550}",
                "\u{255A}",
                "\u{2551}",
            },
            .simple => return .{
                "+",
                "-",
                "+",
                "|",
                "+",
                "-",
                "+",
                "|",
            },
        }
    }
};

const Config = struct {
    max_width: usize,
    /// Normal text for suggestions.
    normal: Terminal.TextStyle,
    /// The style of the current selected option.
    selected: Terminal.TextStyle,
    border: Border = .none,
};

config: Config,
/// This ptr is created on the heap, and is managed via some allocator.
terminal: *Terminal,

pub fn init(alloc: Allocator, config: Config) !Self {
    const terminal = try alloc.create(Terminal);
    errdefer alloc.destroy(terminal);

    terminal.* = try Terminal.init();
    errdefer terminal.deinit();
    try terminal.enableRawMode();

    return Self{
        .config = config,
        .terminal = terminal,
    };
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    // This disables raw-mode, so we are fine here. The user simply needs to
    // call `menu.deinit`, and the entire structure will be cleaned up.
    self.terminal.deinit();
    alloc.destroy(self.terminal);
}

fn requestedNewlines(cursor: Terminal.Cursor, want_below: usize, term_size: Terminal.Size) usize {
    const lines_left = term_size.rows - cursor.row; // rows strictly below cursor
    return if (lines_left >= want_below) 0 else want_below - lines_left;
}

fn appendNewlines(self: *const Self, need: usize, cursor: *Terminal.Cursor, term_size: Terminal.Size) !void {
    if (need == 0) return;

    try self.terminal.goto(term_size.rows, 1);
    for (0..need) |_| {
        try self.terminal.tty_writer.interface.writeAll("\n");
        try self.terminal.tty_writer.interface.flush();
    }

    // Prompt visually moved up by `need` rows.
    cursor.row = if (cursor.row > need) cursor.row - need else 1;
    try self.terminal.goto(cursor.row, cursor.col);
}

fn getContentWidth(self: *const Self, content: [][]const u8) usize {
    var width: usize = 0;
    for (content) |line| {
        const candidate = @min(line.len, self.config.max_width);
        if (candidate > width) width = candidate;
    }
    return width;
}

fn getOuterDims(self: *const Self, inner_width: usize, inner_height: usize) struct { usize, usize } {
    const use_border = self.config.border != .none;

    const padding = blk: {
        const with_padding: usize = 2;
        const no_padding: usize = 0;
        break :blk if (use_border) with_padding else no_padding;
    };

    const outer_width = inner_width + padding;
    const outer_height = inner_height + padding;
    return .{ outer_width, outer_height };
}

pub fn render(self: *const Self, content: [][]const u8, selected: usize) !void {
    if (content.len == 0) {
        return;
    }

    try self.terminal.hideCursor();

    const inner_width = @max(self.getContentWidth(content), 1);
    const inner_height = content.len;

    var cursor = try self.terminal.getCursor();
    const term_size = try self.terminal.getSize();

    const outer = self.getOuterDims(inner_width, inner_height);
    const want_below = outer.@"1";
    const use_border = self.config.border != .none;

    const need = requestedNewlines(cursor, want_below, term_size);
    try self.appendNewlines(need, &cursor, term_size);

    try self.terminal.drawRectFlushless(
        cursor.row + 1,
        cursor.col,
        inner_width,
        inner_height,
        self.config.normal,
        self.config.border.sides(),
    );

    const text_pos = Terminal.Cursor{
        .row = if (use_border) cursor.row + 2 else cursor.row + 1,
        .col = if (use_border) cursor.col + 1 else cursor.col,
    };

    for (content, 0..) |suggestion, idx| {
        const row = text_pos.row + idx;

        const style = if (idx == selected) self.config.selected else self.config.normal;
        if (suggestion.len > inner_width) {
            if (inner_width == 1) {
                // There is only room for a single character, so draw an ellipsis.
                try self.terminal.printFlushless(row, text_pos.col, "\u{2026}", style);
            } else {
                const visible_len = inner_width - 1;
                // Print the visible part first.
                try self.terminal.printFlushless(row, text_pos.col, suggestion[0..visible_len], style);
                const dots_char = "\u{2026}";
                const dots_col = text_pos.col + visible_len;
                // Print the ellipsis (due to content.len > width).
                try self.terminal.printFlushless(row, dots_col, dots_char, style);
            }
        } else {
            // We can draw the full line.
            try self.terminal.printFlushless(row, text_pos.col, suggestion, style);
        }
    }
    try self.terminal.showCursor();
    try self.terminal.tty_writer.interface.flush();
}

pub fn clear(self: *const Self, content: [][]const u8) !void {
    if (content.len == 0) return;

    try self.terminal.hideCursor();
    try self.terminal.saveCursor();

    const inner_width = @max(self.getContentWidth(content), 1);
    const inner_height = content.len;

    const cursor = try self.terminal.getCursor();

    const outer = self.getOuterDims(inner_width, inner_height);

    for (cursor.row + 1..cursor.row + 2 + outer.@"0") |row| {
        try self.terminal.goto(row, cursor.col);
        try self.terminal.clearLine();
    }

    try self.terminal.restoreCursor();
    try self.terminal.showCursor();
}

/// All keybindings are stored with ascii-codes, to be able to compare with
/// bytes from Menu.zig.
///
/// FIXME: Space should disable/terminate the program when run in interactive.
pub const Keybindings = struct {
    left_delete_one_char: u8 = 0x08, // Backspace or Ctrl-h.
    right_delete_one_char: u8 = 0x04, // Ctrl-d.
    move_to_start: u8 = 0x01, // Ctrl-a
    move_to_end: u8 = 0x05, // Ctrl-e
    move_left_one_char: u8 = 0x02,
    move_right_one_char: u8 = 0x06,
    quit: u8 = 0x03, // Ctrl-c.
    accept_suggestion: u8 = 0x19, // Ctrl-y.
    next_suggestion: u8 = 0x0E, // Ctrl-n.
    prev_suggestion: u8 = 0x10, // Ctrl-p.

    /// Be careful as the fields of the tagged values are initialized as
    /// undefined.
    fn toRequest(self: Keybindings, byte: u8) ?UserRequest {
        // Since Zig can only switch on compile-known objects, then we have to
        // have some sort of "large if-chain" for the mapping from a keybind to
        // a UserRequest.
        if (self.left_delete_one_char == byte) return .left_delete_one_char;
        if (self.right_delete_one_char == byte) return .right_delete_one_char;
        if (self.move_to_start == byte) return .move_to_start;
        if (self.move_to_end == byte) return .move_to_end;
        if (self.move_left_one_char == byte) return .move_left_one_char;
        if (self.move_right_one_char == byte) return .move_right_one_char;
        if (self.quit == byte) return .quit;
        if (self.accept_suggestion == byte) return .{ .accept_suggestion = undefined };
        if (self.next_suggestion == byte) return .{ .internal = .next_suggestion };
        if (self.prev_suggestion == byte) return .{ .internal = .prev_suggestion };
        return null;
    }
};

const Internal = union(enum) {
    next_suggestion,
    prev_suggestion,
};

/// FIXME: Have some sort of system in place which can syncronize/check/map
/// basically every request to a keybind.
pub const UserRequest = union(enum) {
    // These requests each map to a keybind.
    left_delete_one_char,
    right_delete_one_char,
    move_to_start,
    move_to_end,
    move_left_one_char,
    move_right_one_char,
    quit,
    /// The index of the accepted suggestion.
    accept_suggestion: usize,
    internal: Internal,

    // These do not map to a keybind.
    pass_through_byte: u8,
};

/// Displays the menu and lets the user navigate.
/// Returns the selected index (0-based), `pass_through_byte` if the user
/// keeps writing or quit if the user wants to `quit` viewing suggestions.
pub fn getFinalUserRequest(self: *Self, kb: Keybindings, suggestions: [][]const u8) !UserRequest {
    if (suggestions.len == 0) return .quit;

    var selected: usize = 0;

    // Input buffer for reading key sequences.
    var buf: [8]u8 = undefined;

    while (true) {
        try self.render(suggestions, selected);
        // Read one byte at a time (which is possible due to raw-mode).
        const n = try self.terminal.tty_file.read(&buf);
        if (n == 0) continue;

        const b = buf[0];

        const request = kb.toRequest(b);

        if (request) |req| switch (req) {
            .internal => |i| switch (i) {
                .next_suggestion => {
                    selected = (selected + 1) % suggestions.len;
                    continue;
                },
                .prev_suggestion => {
                    selected = if (selected == 0) suggestions.len - 1 else (selected - 1) % suggestions.len;
                    continue;
                },
            },
            .accept_suggestion => |_| return .{ .accept_suggestion = selected },
            else => |r| return r,
        };

        // The byte did not correspond to a keybind, therefore we can safely
        // pass this byte through.
        return .{ .pass_through_byte = b };
    }
}
