const std = @import("std");
const Allocator = std.mem.Allocator;
const clap = @import("clap");

const backend = @import("backend.zig");
const Popup = @import("Popup.zig");

const ZSH_INIT_SCRIPT =
    \\ suggest-widget() {
    \\   local line cursor_index word
    \\
    \\   line="$LBUFFER$RBUFFER"
    \\   cursor_index=${#LBUFFER}
    \\
    \\   # FIXME: What is this path?
    \\   ~/Code/suggest/zig-out/bin/suggest --path ~/.zsh_history --line="$line" --cursor-idx="$cursor_index"
    \\ }
    \\
    \\ zle -N suggest-widget
    \\ bindkey '^f' suggest-widget
    ;

const Config = struct {
    history_file_path: []const u8,
    max_suggestions: usize = 8,
    /// This value should be quite high as otherwise commonly used commands,
    /// such as `cd` or `ls` trumps all other commands due to how the Markov
    /// score is currently calculated. This could be a good reason to think of
    /// another metric to calculate the score.
    markov_bigram_weight: f64 = 120.0,
    /// The current, or unfinished line.
    line: []const u8 = "",
    /// The cursor index in that unfinished line.
    cursor_idx: usize = 0,

    /// Args is initialized via clap.
    fn init(args: anytype) !Config {
        var config = Config{ .history_file_path = undefined };

        if (args.path) |p| {
            config.history_file_path = p;
        } else return error.NoPath;

        if (args.line) |l| {
            config.line = l;
        } else return error.NoLine;

        if (args.@"cursor-idx") |i| {
            config.cursor_idx = i;
        } else return error.NoCursorIdx;

        if (args.@"max-suggestions") |n| config.max_suggestions = n;
        if (args.@"bigram-weight") |w| config.markov_bigram_weight = w;

        return config;
    }

    fn run(self: Config, alloc: Allocator) !void {
        const file = try std.fs.openFileAbsolute(self.history_file_path, .{});

        // For simplicity's sake we use a small buffer for now. We should expand
        // this later on to support better completion.
        //
        // TODO: Using 200kb memory and rebuilding the Markov struct each time
        // the program is run is very inefficient. The markov could maybe be
        // serialized on update, and deserialized when ran to minimize latency.
        //
        // Note: We probably even want to read from the file backwards.
        var buf: [200 * 1024]u8 = undefined;

        const n = try file.readAll(buf[0..]);
        const data: []const u8 = buf[0..n];

        var markov = try backend.Markov.init(alloc, data);
        defer markov.deinit();

        var popup = try Popup.init(alloc);
        defer popup.deinit(alloc);

        const last_two = Popup.getLastTwoWords(self.line, self.cursor_idx);

        // FIXME: Remove the +1.
        var suggestions = try alloc.alloc([]const u8, self.max_suggestions + 1);
        defer alloc.free(suggestions);

        const mbw = self.markov_bigram_weight;
        const count = try markov.suggest(alloc, suggestions[1..], last_two.prev, last_two.curr, mbw);
        if (count == 0) return;

        const content = blk: {
            const prev = if (last_two.prev == null) "NULL" else last_two.prev.?;
            const ret = try std.fmt.allocPrint(alloc, "Parsed: [{s}] [{s}]", .{prev, last_two.curr});
            break :blk ret;
        };
        suggestions[0] = content;
        try popup.display(suggestions[0..]);
    }
};

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                    Display this help and exit.
        \\-p, --path <str>              The path to the history file, such as ~/.zsh_history or ~/.bash_history.
        \\-n, --max-suggestions <usize> The maximum amount of suggestions to be outputed.
        \\-b, --bigram-weight <f64>     A multiple of how much the frequency in relation to the previous word should matter compared to the overall frequency of the word.
        \\--init                        FIXME
        \\--line <str>                  FIXME
        \\--cursor-idx <usize>          FIXME
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = alloc,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(.stderr(), clap.Help, &params, .{});
    }

    if (res.args.init != 0) {
        var stdout_wrapper = std.fs.File.stdout().writer(&.{});
        var stdout = &stdout_wrapper.interface;
        try stdout.writeAll(ZSH_INIT_SCRIPT);
        return;
    }

    const config = try Config.init(res.args);
    try config.run(alloc);
}
