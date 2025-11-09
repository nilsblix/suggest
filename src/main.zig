const std = @import("std");
const Allocator = std.mem.Allocator;
const clap = @import("clap");

const backend = @import("backend.zig");
const shell = @import("shell.zig");
const Popup = @import("Popup.zig");

const Config = struct {
    history_file_path: []const u8,
    max_popup_width: usize = 20,
    max_popup_height: usize = 8,
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

        if (args.@"max-width") |w| config.max_popup_width = w;
        if (args.@"max-height") |h| config.max_popup_height = h;
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

        var popup = try Popup.init(alloc, .{
            .max_width = self.max_popup_width,
            .normal = .{
                .bg = .{ .r = 0x28, .g = 0x28, .b = 0x28 },
                .fg = .{ .r = 0xaa, .g = 0xaa, .b = 0xaa },
            },
            .selected = .{
                .bg = .{ .r = 0x87, .g = 0xAF, .b = 0xD7 },
                .fg = .{ .r = 0x00, .g = 0x00, .b = 0x00 },
            },
            .border = .{
                .double = .{
                    .bg = .{ .r = 0x28, .g = 0x28, .b = 0x28 },
                    .fg = .{ .r = 0xaa, .g = 0xaa, .b = 0xaa },
                },
            },
        });
        defer popup.deinit(alloc);

        const last_two = Popup.getLastTwoWords(self.line, self.cursor_idx);

        var suggestions = try alloc.alloc([]const u8, self.max_popup_height);
        defer alloc.free(suggestions);

        const mbw = self.markov_bigram_weight;
        const count = try markov.suggest(alloc, suggestions[0..], last_two.prev, last_two.curr, mbw);
        if (count == 0) return;

        // Only display the returned suggestions. We previously supplied
        // `suggestions[0..]`, which lead to segfault as the display tried to
        // iterate through unintialized memory.
        const ret = try popup.handleInput(suggestions[0..count]);
        try popup.clear(suggestions[0..count]);
        switch (ret) {
            .quit => return,
            .selected_index => |idx| {
                const item = suggestions[idx];

                // We need to replace the current word with item. Ex:
                // `git br# -> git branch`
                // where # represents the cursor.
                const left = Popup.getLineExcludeLastWord(self.line, self.cursor_idx);
                const right = self.line[self.cursor_idx..];
                const slice = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{left, item, right});

                var out_buf: [1024]u8 = undefined;
                var out_file_writer = std.fs.File.stdout().writer(&out_buf);
                const out: *std.io.Writer = &out_file_writer.interface;

                try out.writeAll(slice);
                try out.flush();
            },
            .pass_through_byte => |b| {
                // This programs returns the entire new line via stdout, which
                // means we simply need to append this byte at cursor_idx in
                // the line.
                const left = self.line[0..self.cursor_idx];
                const right = self.line[self.cursor_idx..];
                const slice = try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{left, b, right});

                var out_buf: [16]u8 = undefined;
                var out_file_writer = std.fs.File.stdout().writer(&out_buf);
                const out: *std.io.Writer = &out_file_writer.interface;

                try out.writeAll(slice);
                try out.flush();
            }
        }
    }
};

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    const params = comptime clap.parseParamsComptime(
        // FIXME: Make sure that all of these make sense.
        \\-h, --help                    Display this help and exit.
        \\-p, --path <str>              The path to the history file, such as ~/.zsh_history or ~/.bash_history.
        \\-w, --max-width <usize>       The maximum amount of suggestions to be outputed.
        \\-h, --max-height <usize>      The maximum amount of suggestions to be outputed.
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
        try stdout.writeAll(shell.ZSH_INIT_SCRIPT);
        return;
    }

    const config = try Config.init(res.args);
    try config.run(alloc);
}
