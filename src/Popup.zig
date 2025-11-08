const std = @import("std");
const Allocator = std.mem.Allocator;
const Terminal = @import("Terminal.zig");

const Self = @This();

// FIXME: Use this to determine borders colors etc.
const Config = struct {
    max_width: usize,
};

config: Config,
/// This ptr is created on the heap, and is managed via some allocator.
terminal: *Terminal,

pub fn init(alloc: Allocator) !Self {
    const terminal = try alloc.create(Terminal);
    errdefer alloc.destroy(terminal);

    terminal.* = try Terminal.init();
    try terminal.enableRawMode();

    return Self{
        .config = Config{
            .max_width = 30,
        },
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

/// Returns the word to the left of the cursor (if any) and the "current" word.
///
/// Semantics:
/// - If the cursor is *inside* or just after a word, that word is `current`.
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
        // Cursor is inside or just after a word → that is the current word.
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

pub fn display(self: *const Self, content: [][]const u8) !void {
    var width: usize = 0;
    for (content) |line| {
        if (line.len > width and line.len <= self.config.max_width) {
            width = line.len;
        }
    }

    const cursor = try self.terminal.getCursor();
    const bg = Terminal.Color{ .r = 0x18, .g = 0x18, .b = 0x18 };
    try self.terminal.drawRect(cursor.row + 1, cursor.col, width, content.len, bg);

    for (content, 1..) |line, idx| {
        const row = cursor.row + idx;
        const len = @min(line.len, self.config.max_width);
        try self.terminal.printAtBg(row, cursor.col, line[0..len], bg);
    }
}
