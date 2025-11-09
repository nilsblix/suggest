const std = @import("std");
const Allocator = std.mem.Allocator;
const Terminal = @import("Terminal.zig");

const Self = @This();

const ColorPair = struct {
    fg: Terminal.Color,
    bg: Terminal.Color,
};

const Border = union(enum) {
    none,
    rounded: ColorPair,
    square: ColorPair,
    double: ColorPair,
    simple: ColorPair,

    /// Returns optional border chars in this order:
    /// `1 2 3
    /// 8   4
    /// 7 6 5`
    pub fn sides(self: Border) ?[8][]const u8 {
        switch (self) {
            .none => return null,
            .rounded => |_| return .{
                "\u{256D}",
                "\u{2500}",
                "\u{256E}",
                "\u{2502}",
                "\u{256F}",
                "\u{2500}",
                "\u{2570}",
                "\u{2502}",
            },
            .square => |_| return .{
                "\u{250C}",
                "\u{2500}",
                "\u{2510}",
                "\u{2502}",
                "\u{2518}",
                "\u{2500}",
                "\u{2514}",
                "\u{2502}",
            },
            .double => |_| return .{
                "\u{2554}",
                "\u{2550}",
                "\u{2557}",
                "\u{2551}",
                "\u{255D}",
                "\u{2550}",
                "\u{255A}",
                "\u{2551}",
            },
            .simple => |_| return .{
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
    normal: ColorPair,
    selected: ColorPair,
    border: Border = .none,
};

config: Config,
/// This ptr is created on the heap, and is managed via some allocator.
terminal: *Terminal,

pub fn init(alloc: Allocator, config: Config) !Self {
    const terminal = try alloc.create(Terminal);
    errdefer alloc.destroy(terminal);

    terminal.* = try Terminal.init();
    try terminal.enableRawMode();

    return Self{
        .config = config,
        .terminal = terminal,
    };
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    // This disables raw-mode, so we are fine here. The user simply needs to
    // call `popup.deinit`, and the entire structure will be cleaned up.
    self.terminal.deinit();
    alloc.destroy(self.terminal);
}

const Word = struct {
    /// Byte offset in the line where the word starts (inclusive).
    start: usize,
    /// Byte offset in the line where the word starts (exclusive).
    end: usize,
};

pub const LastTwoWords = struct {
    /// The word immediately to the left of the current word, or null if none.
    prev: ?[]const u8,
    /// The word under / at the cursor, or "" if the cursor is on/after a separator.
    curr: []const u8,
};

fn isSeparatorByte(b: u8) bool {
    return switch (b) {
        ' ', '\t', '\n', '\r' => true,
        ';', '&', '|', '>', '<', '(', ')', '{', '}', ':' => true,
        else => false,
    };
}

/// Find the word that contains `anchor`, assuming anchor is 0 <= anchor < line.len.
/// Returns null if `anchor` is on a separator.
fn findWordAt(line: []const u8, anchor: usize) ?Word {
    if (line.len == 0 or anchor >= line.len) return null;
    if (isSeparatorByte(line[anchor])) return null;

    // Walk left until we hit the start of the line, or we hit a
    // separator.
    var start = anchor;
    while (start > 0 and !isSeparatorByte(line[start - 1])) {
        start -= 1;
    }

    // Walk right until we hit the end of the line, or we hit a separator.
    var end = anchor + 1;
    while (end < line.len and !isSeparatorByte(line[end])) {
        end += 1;
    }

    return Word{ .start = start, .end = end };
}

/// Find the last word that ends strictly before `idx` (cursor index).
fn findPrevWordBefore(line: []const u8, idx: usize) ?Word {
    if (line.len == 0 or idx == 0) return null;

    var i: usize = idx - 1;

    // Skip separators to the left
    while (true) {
        if (!isSeparatorByte(line[i])) break;
        if (i == 0) return null;
        i -= 1;
    }

    return findWordAt(line, i);
}

/// Returns all chars up to and including the last separator before the current
/// word.
///
/// Example (cursor_idx = '# position'):
/// "git b#r"    -> "git "
/// "nix fl#"    -> "nix "
/// "ni#"        -> ""
pub fn getLineExcludeLastWord(line: []const u8, idx: usize) []const u8 {
    const cursor_idx = @min(line.len, idx);
    if (cursor_idx == 0) return "";

    // We start one char to the left of the cursor (left-prioritized).
    var i = cursor_idx - 1;

    while (true) {
        if (isSeparatorByte(line[i])) {
            return line[0..i + 1];
        }

        if (i == 0) {
            return "";
        }

        i -= 1;
    }
}

/// Returns the word to the left of the cursor (if any) and the "current" word.
///
/// Semantics:
/// - If the cursor is inside or just after a word, that word is `current`.
/// - If the cursor is at the start or just after a separator, `current` is "",
///   and `prev` is the last word before the cursor (if any).
pub fn getLastTwoWords(complete_line: []const u8, cursor_idx: usize) LastTwoWords {
    if (complete_line.len == 0) {
        return .{ .prev = null, .curr = "" };
    }

    var cur = cursor_idx;
    if (cur > complete_line.len) cur = complete_line.len;

    var prev_slice: ?[]const u8 = null;
    var current_slice: []const u8 = "";

    // Are we inside/after a word? Check char to the left if any.
    if (cur > 0 and !isSeparatorByte(complete_line[cur - 1])) {
        // Cursor is inside or just after a word -> that is the current word.
        if (findWordAt(complete_line, cur - 1)) |wcur| {
            current_slice = complete_line[wcur.start..@min(wcur.end, cursor_idx)];

            // Previous word is any word that ends before the start of current.
            if (wcur.start > 0) {
                if (findPrevWordBefore(complete_line, wcur.start)) |wprev| {
                    prev_slice = complete_line[wprev.start..wprev.end];
                }
            }
        }
    } else {
        // Cursor is at beginning or on/after a separator → current word is empty,
        // previous word is the last full word before the cursor (if any).
        if (findPrevWordBefore(complete_line, cur)) |wprev| {
            prev_slice = complete_line[wprev.start..wprev.end];
        }
    }

    return .{ .prev = prev_slice, .curr = current_slice };
}

pub fn display(self: *const Self, content: [][]const u8, selected: usize) !void {
    if (content.len == 0) return;

    var width: usize = 0;
    for (content) |line| {
        const candidate = @min(line.len, self.config.max_width);
        if (candidate > width) width = candidate;
    }
    // We still want to draw something even if all suggestions are empty.
    if (width == 0) width = self.config.max_width;

    const cursor = try self.terminal.getCursor();

    const has_border = self.config.border != .none;
    const padding = blk: {
        const padded: usize = 2;
        const unpadded: usize = 0;
        break :blk if (has_border) padded else unpadded;
    };

    const outer_width: usize = width + padding;
    const outer_height: usize = content.len + padding;
    const start_row = cursor.row + 1;
    const start_col: usize = cursor.col;

    // Background fill for the full drawn area (including border if present).
    try self.terminal.drawRect(start_row, start_col, outer_width, outer_height, self.config.normal.bg);

    // Draw border if configured.
    if (has_border) {
        const sides = self.config.border.sides() orelse return error.ConflictingBorder;

        // Obtain border colors (fall back to regular fg/bg if variant is malformed).
        var border_bg = self.config.normal.bg;
        var border_fg = self.config.normal.fg;
        switch (self.config.border) {
            .none => {},
            .rounded => |cp| {
                border_bg = cp.bg;
                border_fg = cp.fg;
            },
            .square => |cp| {
                border_bg = cp.bg;
                border_fg = cp.fg;
            },
            .double => |cp| {
                border_bg = cp.bg;
                border_fg = cp.fg;
            },
            .simple => |cp| {
                border_bg = cp.bg;
                border_fg = cp.fg;
            },
        }

        const top_row = start_row;
        const bot_row = start_row + outer_height - 1;
        const left_col = start_col;
        const right_col = start_col + outer_width - 1;

        // Corners
        try self.terminal.printAtBgFg(top_row, left_col, sides[0], border_bg, border_fg);   // 1
        try self.terminal.printAtBgFg(top_row, right_col, sides[2], border_bg, border_fg);  // 3
        try self.terminal.printAtBgFg(bot_row, right_col, sides[4], border_bg, border_fg);  // 5
        try self.terminal.printAtBgFg(bot_row, left_col, sides[6], border_bg, border_fg);   // 7

        // Top and bottom horizontal lines
        var dx: usize = 1;
        while (dx < outer_width - 1) : (dx += 1) {
            try self.terminal.printAtBgFg(top_row, start_col + dx, sides[1], border_bg, border_fg); // 2
            try self.terminal.printAtBgFg(bot_row, start_col + dx, sides[5], border_bg, border_fg); // 6
        }

        // Vertical lines
        var dy: usize = 1;
        while (dy < outer_height - 1) : (dy += 1) {
            try self.terminal.printAtBgFg(start_row + dy, left_col, sides[7], border_bg, border_fg);  // 8
            try self.terminal.printAtBgFg(start_row + dy, right_col, sides[3], border_bg, border_fg); // 4
        }
    }

    // Draw content within the inner area (indented by border if present).
    for (content, 0..) |line, iidx| {
        const line_padding = blk: {
            const padded: usize = 1;
            const unpadded: usize = 0;
            break :blk if (has_border) padded else unpadded;
        };
        const row = start_row + line_padding + iidx;
        const text_col = start_col + line_padding;

        var bg = self.config.normal.bg;
        var fg = self.config.normal.fg;
        if (iidx == selected) {
            // We want to draw the entire line with the selected background, as
            // without it only the text-covered part of the line becomes
            // highlighted.
            bg = self.config.selected.bg;
            fg = self.config.selected.fg;
            try self.terminal.drawRect(row, text_col, width, 1, bg);
        }

        if (line.len > width) {
            if (width <= 3) {
                // Degenerate case. Not enough room for ellipsis + content.
                // Just hard cut to max_width.
                const slice = line[0..width];
                try self.terminal.printAtBgFg(row, text_col, slice, bg, fg);
            } else {
                const visible_len = width - 1;

                // Print the visible section.
                try self.terminal.printAtBgFg(row, text_col, line[0..visible_len], bg, fg);

                // Print the dots after the visible section.
                const dots_char = "\u{2026}";
                const dots_col = text_col + visible_len;
                try self.terminal.printAtBgFg(row, dots_col, dots_char, bg, fg);
            }
        } else {
            // Nothing special. Simply print the content.
            try self.terminal.printAtBgFg(row, text_col, line, bg, fg);
        }
    }
}

/// Clears the area which was used to draw in `self.display`. Uses the same
/// `content` to simply get the correct dimensions.
pub fn clear(self: *const Self, content: [][]const u8) !void {
    if (content.len == 0) return;

    // Same calculations as in `display`.
    var width: usize = 0;
    for (content) |line| {
        const candidate = @min(line.len, self.config.max_width);
        if (candidate > width) width = candidate;
    }
    if (width == 0) width = self.config.max_width;

    const cursor = try self.terminal.getCursor();

    try self.terminal.saveCursor();
    errdefer self.terminal.restoreCursor() catch {};

    const has_border = self.config.border != .none;
    const start_row = cursor.row + blk: {
        const pad: usize = 0;
        const unpad: usize = 1;
        break :blk if (has_border) pad else unpad;
    };
    const height = content.len + blk: {
        const pad: usize = 2;
        const unpad: usize = 0;
        break :blk if (has_border) pad else unpad;
    };

    var dy: usize = 0;
    while (dy < height) : (dy += 1) {
        try self.terminal.goto(start_row + dy, cursor.col);
        try self.terminal.clearLine();
    }

    try self.terminal.restoreCursor();
    try self.terminal.stdout.flush();
}

pub const SuggestionReturn = union(enum) {
    selected_index: usize,
    pass_through_byte: u8,
    quit,
};

/// Displays the popup and lets the user navigate.
/// Returns the selected index (0-based), `passed_through_byte` if the user
/// keeps writing or quit if the user wants to `quit` viewing suggestions.
pub fn handleInput(self: *Self, suggestions: [][]const u8) !SuggestionReturn {
    if (suggestions.len == 0) return .quit;

    var selected: usize = 0;

    // Input buffer for reading key sequences.
    var buf: [8]u8 = undefined;

    while (true) {
        try self.display(suggestions, selected);
        // Read one byte at a time (which is possible due to raw-mode).
        const n = try self.terminal.tty_file.read(&buf);
        if (n == 0) continue;

        const b = buf[0];

        switch (b) {
            // Enter or ctrl-y -> Accept.
            '\r', '\n', 25 => return .{ .selected_index = selected },
            // Esc or ctrl-c -> Cancel.
            27, 3 => return .quit,
            // Down-arrow or ctrl-n => Select next suggestion.
            14 => {
                selected = (selected + 1) % suggestions.len;
            },
            // Up-arrow or ctrl-p => Select previous suggestion.
            16 => {
                selected = if (selected == 0) suggestions.len - 1 else (selected - 1) % suggestions.len;
            },
            else => {
                return .{ .pass_through_byte = b };
            },
        }
    }
}
