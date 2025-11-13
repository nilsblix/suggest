const std = @import("std");
const Allocator = std.mem.Allocator;

const MAX_FILE_SIZE = 200 * 1024;

pub const Token = struct {
    value: []const u8,
    /// Start index (inclusive) in the unparsed command slice.
    start: usize,
    /// End index (exclusive) in the unparsed command slice.
    end: usize,

    fn length(self: Token) usize {
        return self.end - self.start + 1;
    }
};

const SEPARATORS = " \t";

fn isTokenSeparator(b: u8) bool {
    for (SEPARATORS) |sep| {
        if (b == sep) return true;
    }
    return false;
}

pub const Command = struct {
    tokens: std.ArrayList(Token),

    pub fn init(alloc: Allocator) !Command {
        return Command{
            .tokens = try .initCapacity(alloc, 0),
        };
    }

    pub fn deinit(self: *Command, alloc: Allocator) void {
        self.tokens.deinit(alloc);
    }

    pub fn fromSlice(alloc: Allocator, slice: []const u8) !Command {
        var cmd = try Command.init(alloc);
        errdefer cmd.deinit(alloc);

        var token_iter = std.mem.tokenizeAny(u8, slice, SEPARATORS);
        while (token_iter.next()) |tok_slice| {
            const start = @intFromPtr(tok_slice.ptr) - @intFromPtr(slice.ptr);
            const end = start + tok_slice.len;

            const token = Token{
                .value = tok_slice,
                .start = start,
                .end = end,
            };

            try cmd.tokens.append(alloc, token);
        }

        return cmd;
    }
};

pub const Data = struct {
    // For simplicity's sake we use a small buffer for now. We should expand
    // this later on to support better completion.
    //
    // FIXME: Using 200kb memory and rebuilding the Markov struct each time
    // the program is run is very inefficient. The markov could maybe be
    // serialized on update, and deserialized when ran to minimize latency.
    //
    // Note: We probably even want to read from the file backwards.
    buf: [MAX_FILE_SIZE]u8,
    num_bytes: usize,
    commands: std.ArrayList(Command),

    pub fn init(alloc: Allocator, file_path: []const u8) !*Data {
        const file = try std.fs.openFileAbsolute(file_path, .{});
        defer file.close();

        var data = try alloc.create(Data);
        // `data.buf` gets initialized by `file.readAll`
        data.num_bytes = try file.readAll(data.buf[0..]);
        data.commands = try .initCapacity(alloc, 0);

        const slice = data.buf[0..data.num_bytes];

        var cmd_iter = std.mem.tokenizeAny(u8, slice, "\n");
        while (cmd_iter.next()) |cmd_slice| {
            var cmd = try Command.fromSlice(alloc, cmd_slice);

            if (cmd.tokens.items.len != 0) {
                try data.commands.append(alloc, cmd);
            } else {
                cmd.deinit(alloc);
            }
        }
        return data;
    }

    pub fn deinit(self: *Data, alloc: Allocator) void {
        for (self.commands.items) |*cmd| {
            cmd.deinit(alloc);
        }
        self.commands.deinit(alloc);
        alloc.destroy(self);
    }
};

/// Determines whether `prefix` is a prefix to the `s` string.
pub fn isPrefix(s: []const u8, prefix: []const u8) bool {
    if (prefix.len > s.len) return false;
    return std.mem.eql(u8, s[0..prefix.len], prefix);
}

pub const Pair = struct {
    fst: []const u8,
    snd: []const u8,

    pub const empty = @This(){
        .fst = "",
        .snd = "",
    };

    /// From the Zig HashMap docs:
    /// ```
    /// Context must be a struct type with two member functions:
    ///     hash(self, K) u64
    ///     eql(self, K, K) bool
    /// ```
    pub const Context = struct {
        pub fn hash(_: Context, pair: Pair) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(pair.fst);
            hasher.update(&[_]u8{0xff});
            hasher.update(pair.snd);

            return hasher.final();
        }

        pub fn eql(_: Context, a: Pair, b: Pair) bool {
            return std.mem.eql(u8, a.fst, b.fst) and std.mem.eql(u8, a.snd, b.snd);
        }
    };

    pub fn eql(a: Pair, b: Pair) bool {
        return Context.eql(undefined, a, b);
    }
};

pub fn popLeftTokenOfIdx(command: []const u8, idx: usize) []const u8 {
    var i = @min(command.len - 1, idx);
    while (true) {
        if (i == 0) {
            return "";
        }

        if (isTokenSeparator(command[i])) {
            return command[0 .. i + 1];
        }

        i -= 1;
    }
}

pub fn getLeftmostToken(slice: []const u8, idx: usize) []const u8 {
    var i = @min(slice.len - 1, idx);

    // Find the first non-separating character.
    while (true) {
        if (!isTokenSeparator(slice[i])) {
            break;
        }

        if (i == 0) {
            return "";
        }

        i -= 1;
    }

    const end_idx_exclusive = i + 1;

    while (true) {
        const byte = slice[i];
        const is_sep = isTokenSeparator(byte);

        if (i == 0) {
            if (is_sep) {
                return slice[1..end_idx_exclusive];
            }
            return slice[0..end_idx_exclusive];
        }

        if (is_sep) {
            return slice[i + 1 .. end_idx_exclusive];
        }

        i -= 1;
    }
}

/// Gets the two tokens to the left of `cursor_idx`, with `cursor_idx` being inclusive.
pub fn getRelevantBigram(unparsed: []const u8, cursor_idx: usize) Pair {
    const len = unparsed.len;
    if (len == 0) return Pair.empty;

    const cursor = @min(len, cursor_idx);

    const on_separator = isTokenSeparator(unparsed[@min(len - 1, cursor)]);
    const snd = getLeftmostToken(unparsed, cursor);

    if (on_separator) {
        return .{
            .fst = snd,
            .snd = "",
        };
    }

    if (snd.len == 0) {
        if (cursor == 0) {
            // Nothing before cursor.
            return Pair.empty;
        }
        // Previous full word to the left of cursor.
        const fst = getLeftmostToken(unparsed, cursor - 1);
        return .{
            .fst = fst,
            .snd = "",
        };
    }

    if (cursor < snd.len + 1) {
        return .{
            .fst = "",
            .snd = snd,
        };
    }

    const fst = getLeftmostToken(unparsed, cursor - snd.len - 1);

    return .{
        .fst = fst,
        .snd = snd,
    };
}

test "relevant bigram" {
    {
        const s = "nix fl";
        const i = s.len;
        const ret = getRelevantBigram(s, i);
        const exp: Pair = .{
            .fst = "nix",
            .snd = "fl",
        };
        std.debug.print("Expected: ('{s}', '{s}')\n", .{ exp.fst, exp.snd });
        std.debug.print("Got     : ('{s}', '{s}')\n", .{ ret.fst, ret.snd });
        try std.testing.expect(Pair.eql(exp, ret));
        std.debug.print("----------------------------\n", .{});
    }

    {
        const s = "nix flake";
        const i = 5;
        const ret = getRelevantBigram(s, i);
        const exp: Pair = .{
            .fst = "nix",
            .snd = "fl",
        };
        std.debug.print("Expected: ('{s}', '{s}')\n", .{ exp.fst, exp.snd });
        std.debug.print("Got     : ('{s}', '{s}')\n", .{ ret.fst, ret.snd });
        try std.testing.expect(Pair.eql(exp, ret));
        std.debug.print("----------------------------\n", .{});
    }

    {
        const s = "hello git bisect world";
        const i = 11;
        const ret = getRelevantBigram(s, i);
        const exp: Pair = .{
            .fst = "git",
            .snd = "bi",
        };
        std.debug.print("Expected: ('{s}', '{s}')\n", .{ exp.fst, exp.snd });
        std.debug.print("Got     : ('{s}', '{s}')\n", .{ ret.fst, ret.snd });
        try std.testing.expect(Pair.eql(exp, ret));
        std.debug.print("----------------------------\n", .{});
    }

    {
        const s = "";
        const i = 0;
        const ret = getRelevantBigram(s, i);
        const exp: Pair = .{
            .fst = "",
            .snd = "",
        };
        std.debug.print("Expected: ('{s}', '{s}')\n", .{ exp.fst, exp.snd });
        std.debug.print("Got     : ('{s}', '{s}')\n", .{ ret.fst, ret.snd });
        try std.testing.expect(Pair.eql(exp, ret));
        std.debug.print("----------------------------\n", .{});
    }

    {
        const s = " Hello, world!";
        const i = s.len;
        const ret = getRelevantBigram(s, i);
        const exp: Pair = .{
            .fst = "Hello,",
            .snd = "world!",
        };
        std.debug.print("Expected: ('{s}', '{s}')\n", .{ exp.fst, exp.snd });
        std.debug.print("Got     : ('{s}', '{s}')\n", .{ ret.fst, ret.snd });
        try std.testing.expect(Pair.eql(exp, ret));
        std.debug.print("----------------------------\n", .{});
    }

    {
        const s = "nix ";
        const i = s.len;
        const ret = getRelevantBigram(s, i);
        const exp: Pair = .{
            .fst = "nix",
            .snd = "",
        };
        std.debug.print("Expected: ('{s}', '{s}')\n", .{ exp.fst, exp.snd });
        std.debug.print("Got     : ('{s}', '{s}')\n", .{ ret.fst, ret.snd });
        try std.testing.expect(Pair.eql(exp, ret));
        std.debug.print("----------------------------\n", .{});
    }

    {
        const s = "    HELLO WORLD THIS ARE SOME TESTS       ";
        const i = s.len;
        const ret = getRelevantBigram(s, i);
        const exp: Pair = .{
            .fst = "TESTS",
            .snd = "",
        };
        std.debug.print("Expected: ('{s}', '{s}')\n", .{ exp.fst, exp.snd });
        std.debug.print("Got     : ('{s}', '{s}')\n", .{ ret.fst, ret.snd });
        try std.testing.expect(Pair.eql(exp, ret));
        std.debug.print("----------------------------\n", .{});
    }

    {
        const s = "    HE#8882#€%&(€(#%)(()LLO WORLD THIS ARE SOME TESTS       ";
        const i = s.len;
        const ret = getRelevantBigram(s, i);
        const exp: Pair = .{
            .fst = "TESTS",
            .snd = "",
        };
        std.debug.print("Expected: ('{s}', '{s}')\n", .{ exp.fst, exp.snd });
        std.debug.print("Got     : ('{s}', '{s}')\n", .{ ret.fst, ret.snd });
        try std.testing.expect(Pair.eql(exp, ret));
        std.debug.print("----------------------------\n", .{});
    }

    {
        const s = "nix ";
        const cursor: usize = s.len;
        const ret = getRelevantBigram(s, cursor);
        const exp: Pair = .{
            .fst = "nix",
            .snd = "",
        };
        std.debug.print("Expected: ('{s}', '{s}')\n", .{ exp.fst, exp.snd });
        std.debug.print("Got     : ('{s}', '{s}')\n", .{ ret.fst, ret.snd });
        try std.testing.expect(Pair.eql(exp, ret));
        std.debug.print("----------------------------\n", .{});
    }

    {
        const s = "  ";
        const cursor: usize = s.len;
        const ret = getRelevantBigram(s, cursor);
        const exp: Pair = .{
            .fst = "",
            .snd = "",
        };
        std.debug.print("Expected: ('{s}', '{s}')\n", .{ exp.fst, exp.snd });
        std.debug.print("Got     : ('{s}', '{s}')\n", .{ ret.fst, ret.snd });
        try std.testing.expect(Pair.eql(exp, ret));
        std.debug.print("----------------------------\n", .{});
    }

    {
        const s = "hello world";
        const cursor: usize = 1;
        const ret = getRelevantBigram(s, cursor);
        const exp: Pair = .{
            .fst = "",
            .snd = "he",
        };
        std.debug.print("Expected: ('{s}', '{s}')\n", .{ exp.fst, exp.snd });
        std.debug.print("Got     : ('{s}', '{s}')\n", .{ ret.fst, ret.snd });
        try std.testing.expect(Pair.eql(exp, ret));
        std.debug.print("----------------------------\n", .{});
    }

    {
        const s = "nix flake";
        const cursor: usize = s.len + 10;
        const ret = getRelevantBigram(s, cursor);
        const exp: Pair = .{
            .fst = "nix",
            .snd = "flake",
        };
        std.debug.print("Expected: ('{s}', '{s}')\n", .{ exp.fst, exp.snd });
        std.debug.print("Got     : ('{s}', '{s}')\n", .{ ret.fst, ret.snd });
        try std.testing.expect(Pair.eql(exp, ret));
        std.debug.print("----------------------------\n", .{});
    }

    {
        const s = "hello";
        const cursor: usize = 2;
        const ret = getRelevantBigram(s, cursor);
        const exp: Pair = .{
            .fst = "",
            .snd = "hel",
        };
        std.debug.print("Expected: ('{s}', '{s}')\n", .{ exp.fst, exp.snd });
        std.debug.print("Got     : ('{s}', '{s}')\n", .{ ret.fst, ret.snd });
        try std.testing.expect(Pair.eql(exp, ret));
        std.debug.print("----------------------------\n", .{});
    }
}
