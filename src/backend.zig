const std = @import("std");
const Allocator = std.mem.Allocator;

/// Lines/words in a file. Used to get each command and each words in that
/// command from history files such as .zsh_history or .bash_history.
const File = struct {
    const Words = std.ArrayList([]const u8);

    lines: std.ArrayList(Words),

    /// Initialize from raw byte-data from a file.
    fn init(alloc: Allocator, data: []const u8) !File {
        var line_it = std.mem.tokenizeAny(u8, data, "\r\n");
        var lines = try std.ArrayList(Words).initCapacity(alloc, 0);

        while (line_it.next()) |line| {
            var words: Words = try .initCapacity(alloc, 0);

            var word_it = std.mem.tokenizeAny(u8, line, " \t");
            while (word_it.next()) |word| {
                try words.append(alloc, word);
            }

            try lines.append(alloc, words);
        }

        return File{ .lines = lines };
    }

    fn deinit(self: *File, alloc: Allocator) void {
        for (self.lines.items) |*words| {
            words.deinit(alloc);
        }
        self.lines.deinit(alloc);
    }
};

pub const Markov = struct {
    const Pair = struct {
        fst: []const u8,
        snd: []const u8,

        /// From the Zig HashMap docs:
        /// ```
        /// Context must be a struct type with two member functions:
        ///     hash(self, K) u64
        ///     eql(self, K, K) bool
        /// ```
        const Context = struct {
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
    };

    /// Count of each word.
    unigram: std.StringHashMap(usize),
    /// Count of transitions (prev_word -> next_word). This is therefore a
    /// first-order Markov Chain.
    bigram: std.HashMap(Pair, usize, Pair.Context, std.hash_map.default_max_load_percentage),

    pub fn init(alloc: Allocator, data: []const u8) !Markov {
        var file = try File.init(alloc, data);
        defer file.deinit(alloc);

        var markov = Markov{
            .unigram = .init(alloc),
            .bigram = .init(alloc),
        };

        for (file.lines.items) |command| {
            try markov.updateFromCommand(command);
        }

        return markov;
    }

    pub fn deinit(self: *Markov) void {
        self.unigram.deinit();
        self.bigram.deinit();
    }

    fn updateFromCommand(self: *Markov, command: File.Words) !void {
        if (command.items.len == 0) {
            return;
        }

        // Update the unigram. Simply increase each count by one, or create it
        // if it doesn't exist.
        for (command.items) |w| {
            const entry = self.unigram.getEntry(w) orelse {
                try self.unigram.put(w, 1);
                continue;
            };
            entry.value_ptr.* += 1;
        }

        // Update the bigram. For each pair in the current command, create the
        // pair or increase it by one if it already exists.
        for (command.items[0 .. command.items.len - 1], 1..) |w, next_idx| {
            const next_w = command.items[next_idx];
            const pair = Pair{ .fst = w, .snd = next_w };
            const entry = self.bigram.getEntry(pair) orelse {
                try self.bigram.put(pair, 1);
                continue;
            };
            entry.value_ptr.* += 1;
        }
    }

    /// Suggest words that start with `prefix`, optionally conditioned on
    /// `prev_word`. Places the suggestions, from most probable to least, in
    /// `buf`. The maximum amount of suggestions are the number of elements in
    /// `buf`.
    ///
    /// Returns the amount of words suggested.
    pub fn suggest(
        self: *const Markov,
        alloc: Allocator,
        buf: [][]const u8,
        prev_word: ?[]const u8,
        prefix: []const u8,
        bigram_weight: f64,
    ) !usize {
        var candidates = std.StringArrayHashMap(f64).init(alloc);
        defer candidates.deinit();

        var unigram_it = self.unigram.iterator();
        while (unigram_it.next()) |entry| {
            const w = entry.key_ptr.*;
            if (!std.mem.eql(u8, prefix, "") and !isPrefix(w, prefix)) {
                continue;
            }

            var score = @as(f64, @floatFromInt(entry.value_ptr.*));

            if (prev_word) |p| {
                // Add bigram weight if this word appears after prev_word
                const pair = Pair{ .fst = p, .snd = w };
                if (self.bigram.getEntry(pair)) |bigram_entry| {
                    const bigram_score = @as(f64, @floatFromInt(bigram_entry.value_ptr.*));
                    score += bigram_weight * bigram_score;
                }
            }

            // NOTE: Here we could add a recency factor etc...

            try candidates.put(w, score);
        }

        // From the Zig docs:
        // `sort_ctx` must have this method:
        // `fn lessThan(ctx: @TypeOf(ctx), a_index: usize, b_index: usize) bool`
        const SortContext = struct {
            map: *std.StringArrayHashMap(f64),

            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                const vals = ctx.map.values();
                const keys = ctx.map.keys();

                const va = vals[a_index];
                const vb = vals[b_index];

                // If scores are equal, tie-break lexicographically by the word
                if (va == vb) {
                    return std.mem.lessThan(u8, keys[a_index], keys[b_index]);
                }

                // We want descending order by score, so `lessThan` returns true
                // when va > vb.
                return va > vb;
            }
        };

        candidates.sort(SortContext{ .map = &candidates });

        // Copy into output buffer
        const keys = candidates.keys();
        var out_index: usize = 0;
        var i: usize = 0;
        while (i < keys.len and out_index < buf.len) : (i += 1) {
            buf[out_index] = keys[i];
            out_index += 1;
        }

        return out_index;
    }
};

/// Determines whether `prefix` is a prefix to the `s` string.
fn isPrefix(s: []const u8, prefix: []const u8) bool {
    if (prefix.len > s.len) return false;
    return std.mem.eql(u8, s[0..prefix.len], prefix);
}
