const std = @import("std");
const Allocator = std.mem.Allocator;
const Terminal = @import("Terminal.zig");

const Self = @This();

const Config = struct {
    max_width: usize,
    bg: Terminal.Color,
    selected_bg: Terminal.Color,
    // FIXME: Foreground and border.
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
    try self.terminal.drawRect(cursor.row + 1, cursor.col, width, content.len, self.config.bg);

    for (content, 1..) |line, idx| {
        const row = cursor.row + idx;

        var bg = self.config.bg;
        if (idx - 1 == selected) {
            // We want to draw the entire line with the selected background, as
            // without it only the text-covered part of the line becomes
            // highlighted.
            bg = self.config.selected_bg;
            try self.terminal.drawRect(row, cursor.col, width, 1, bg);
        }

        if (line.len > self.config.max_width) {
            if (self.config.max_width <= 3) {
                // Degenerate case. Not enough room for ellipsis + content.
                // Just hard cut to max_width.
                const slice = line[0..self.config.max_width];
                try self.terminal.printAtBg(row, cursor.col, slice, bg);
            } else {
                const visible_len = self.config.max_width - 1;

                // Print the visible section.
                try self.terminal.printAtBg(row, cursor.col, line[0..visible_len], bg);

                // Print the dots after the visible section.
                const dots_char = "\u{2026}";
                const dots_col = cursor.col + visible_len;
                try self.terminal.printAtBg(row, dots_col, dots_char, bg);
            }
        } else {
            // Nothing special. Simply print the content.
            try self.terminal.printAtBg(row, cursor.col, line, bg);
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

    const start_row = cursor.row + 1;

    var dy: usize = 0;
    while (dy < content.len) : (dy += 1) {
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
                selected = (selected - 1) % suggestions.len;
            },
            else => {
                return .{ .pass_through_byte = b };
            },
        }
    }
}
