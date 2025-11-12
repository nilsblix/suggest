const std = @import("std");
const Allocator = std.mem.Allocator;
const Terminal = @import("Terminal.zig");

const Self = @This();

// FIXME: REMOve pub
pub const Border = union(enum) {
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
            return line[0 .. i + 1];
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

fn requestedNewlines(cursor: Terminal.Cursor, want_below: usize, term_size: Terminal.Size) usize {
    const lines_left = term_size.rows - cursor.row; // rows strictly below cursor
    return if (lines_left >= want_below) 0 else want_below - lines_left;
}

fn appendNewlines(self: *const Self, need: usize, cursor: *Terminal.Cursor, term_size: Terminal.Size) !void {
    if (need == 0) return;

    try self.terminal.goto(term_size.rows, 1);
    for (0..need) |_| {
        try self.terminal.stdout.writeAll("\n");
        try self.terminal.stdout.flush();
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
    try self.terminal.stdout.flush();
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
        try self.render(suggestions, selected);
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
