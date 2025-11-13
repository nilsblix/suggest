const std = @import("std");
const Allocator = std.mem.Allocator;

const parsing = @import("parsing.zig");
const Pair = parsing.Pair;
const Data = parsing.Data;
const Command = parsing.Command;

const Self = @This();

/// Count of each word.
unigram_counts: std.StringHashMap(usize),
/// Count of transitions (prev_word -> next_word). This is therefore a
/// first-order Markov Chain.
bigram_counts: std.HashMap(Pair, usize, Pair.Context, std.hash_map.default_max_load_percentage),

pub fn init(alloc: Allocator, data: Data) !Self {
    var self = Self{
        .unigram_counts = .init(alloc),
        .bigram_counts = .init(alloc),
    };

    for (data.commands.items) |command| {
        try self.updateFromCommand(command);
    }

    return self;
}

pub fn deinit(self: *Self) void {
    self.unigram_counts.deinit();
    self.bigram_counts.deinit();
}

fn updateFromCommand(self: *Self, command: Command) !void {
    if (command.tokens.items.len == 0) {
        return;
    }

    // Update the unigarm. Increase each count by one, or create it if it
    // doesn't exist.
    for (command.tokens.items) |tok| {
        const entry = self.unigram_counts.getEntry(tok.value) orelse {
            try self.unigram_counts.put(tok.value, 1);
            continue;
        };
        entry.value_ptr.* += 1;
    }

    // Update the bigram_counts. For each pair in the current command, create the pair
    // or increase it by one if it already exists.
    const n = command.tokens.items.len;
    for (command.tokens.items[0 .. n - 1], 1..) |tok, next_idx| {
        const next_tok = command.tokens.items[next_idx];
        const pair = Pair{ .fst = tok.value, .snd = next_tok.value };
        const entry = self.bigram_counts.getEntry(pair) orelse {
            try self.bigram_counts.put(pair, 1);
            continue;
        };
        entry.value_ptr.* += 1;
    }
}

// From the Zig docs:
// `sort_ctx` must have this method:
// `fn lessThan(ctx: @TypeOf(ctx), a_index: usize, b_index: usize) bool`
const CandidateSortContext = struct {
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

pub fn suggest(
    self: *const Self,
    alloc: Allocator,
    buf: [][]const u8,
    prev_word: ?[]const u8,
    prefix: []const u8,
    bigram_weight: f64,
) !usize {
    var candidates = std.StringArrayHashMap(f64).init(alloc);
    defer candidates.deinit();

    var unigram_it = self.unigram_counts.iterator();
    while (unigram_it.next()) |entry| {
        const w = entry.key_ptr.*;
        if (!std.mem.eql(u8, prefix, "") and !parsing.isPrefix(w, prefix)) {
            continue;
        }

        var score = @as(f64, @floatFromInt(entry.value_ptr.*));

        if (prev_word) |p| {
            // Add bigram weight if this word appears after prev_word
            const pair = Pair{ .fst = p, .snd = w };
            if (self.bigram_counts.getEntry(pair)) |bigram_entry| {
                const bigram_score = @as(f64, @floatFromInt(bigram_entry.value_ptr.*));
                score += bigram_weight * bigram_score;
            }
        }

        // NOTE: Here we could add a recency factor etc...

        try candidates.put(w, score);
    }

    candidates.sort(CandidateSortContext{ .map = &candidates });

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
