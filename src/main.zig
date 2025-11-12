const std = @import("std");
const Allocator = std.mem.Allocator;
const clap = @import("clap");

const backend = @import("backend.zig");
const shell = @import("shell.zig");
const Popup = @import("Popup.zig");

const Program = struct {
    const Variant = enum {
        general,
        file,

        fn fromSlice(s: []const u8) !Variant {
            inline for (@typeInfo(Variant).@"enum".fields) |field| {
                if (std.mem.eql(u8, s, field.name)) {
                    return @enumFromInt(field.value);
                }
            }
            return error.NoMatch;
        }
    };

    const Mode = enum {
        single,
        interactive,
        @"one-shot",

        fn fromSlice(s: []const u8) !Mode {
            inline for (@typeInfo(Mode).@"enum".fields) |field| {
                if (std.mem.eql(u8, s, field.name)) {
                    return @enumFromInt(field.value);
                }
            }
            return error.NoMatch;
        }
    };

    // Program's default values are referred to here. Any field in the
    // corresponding Config struct that doesn't have a default field is
    // considered to be required (non-optional).
    variant: Variant = .general,
    mode: Mode = .single,

    command: []const u8 = "",
    cursor_idx: usize = 0,
};

const HistoryFile = struct {
    path: []const u8,
};

const Config = struct {
    program: Program,
    file: HistoryFile,
    max_popup_width: usize = 20,
    max_popup_height: usize = 8,
    /// This value should be quite high as otherwise commonly used commands,
    /// such as `cd` or `ls` trumps all other commands due to how the Markov
    /// score is currently calculated. This could be a good reason to think of
    /// another metric to calculate the score.
    markov_bigram_weight: f64 = 120.0,

    /// Args is initialized via clap.
    fn init(args: anytype) !Config {
        var config = Config{
            .program = .{},
            .file = .{ .path = undefined },
        };

        // \\-h, --help                    Display this help and exit.
        // \\--init <str>                  Print the init script for the specified shell.
        // \\--variant <str>               Which variant of the program to perform.
        // \\--mode <str>                  The way that suggestions are given.
        // \\--line <str>                  The current, unfinished command.
        // \\--cursor-idx <usize>          The 0-based cursor index of the current, unfinished command.
        // \\-p, --path <str>              The path to the history file, such as ~/.zsh_history or ~/.bash_history.
        // \\-w, --max-width <usize>       The maximum amount of suggestions to be outputed.
        // \\-h, --max-height <usize>      The maximum amount of suggestions to be outputed.
        // \\-b, --bigram-weight <f64>     A multiple of how much the frequency in relation to the previous word should matter compared to the overall frequency of the word.

        if (args.file) |f| {
            config.file.path = f;
        } else return error.NoHistoryFilePath;

        if (args.variant) |v| {
            config.program.variant = try .fromSlice(v);
        }

        if (args.mode) |v| {
            config.program.mode = try .fromSlice(v);
        }

        if (args.command) |c| {
            config.program.command = c;
        }

        if (args.@"cursor-idx") |i| {
            config.program.cursor_idx = i;
        }

        if (args.@"max-width") |w| {
            config.max_popup_width = w;
        }

        if (args.@"max-height") |h| {
            config.max_popup_height = h;
        }

        if (args.@"bigram-weight") |w| {
            config.markov_bigram_weight = w;
        }

        return config;
    }

    fn run(self: Config, alloc: Allocator) !void {
        const file = try std.fs.openFileAbsolute(self.file.path, .{});

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
            .normal = .{},
            .selected = .{
                .bg = .{ .r = 0x87, .g = 0xAF, .b = 0xD7 },
                .fg = .{ .r = 0x00, .g = 0x00, .b = 0x00 },
            },
            .border = .rounded,
        });
        defer popup.deinit(alloc);

        const last_two = Popup.getLastTwoWords(self.program.command, self.program.cursor_idx);

        var suggestions = try alloc.alloc([]const u8, self.max_popup_height);
        defer alloc.free(suggestions);

        const mbw = self.markov_bigram_weight;
        const count = try markov.suggest(alloc, suggestions[0..], last_two.prev, last_two.curr, mbw);
        if (count == 0) return;

        // Only display the returned suggestions. We previously supplied
        // `suggestions[0..]`, which lead to segfault as the display tried to
        // iterate through unintialized memory.
        const ret = try popup.handleInput(suggestions[0..count]);
        // Clear the popup before we proceed.
        try popup.clear(suggestions[0..]);
        switch (ret) {
            .quit => return,
            .selected_index => |idx| {
                const item = suggestions[idx];

                // We need to replace the current word with item. Ex:
                // `git br# -> git branch`
                // where # represents the cursor.
                const left = Popup.getLineExcludeLastWord(self.program.command, self.program.cursor_idx);
                const right = self.program.command[self.program.cursor_idx..];
                const slice = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ left, item, right });

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
                const left = self.program.command[0..self.program.cursor_idx];
                const right = self.program.command[self.program.cursor_idx..];
                const slice = try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{ left, b, right });

                var out_buf: [16]u8 = undefined;
                var out_file_writer = std.fs.File.stdout().writer(&out_buf);
                const out: *std.io.Writer = &out_file_writer.interface;

                try out.writeAll(slice);
                try out.flush();
            },
        }
        // Clear the popup when the program terminates.
        try popup.clear(suggestions[0..]);
    }
};

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                    Display this help and exit.
        \\--init <str>                  Print the init script for the specified shell.
        \\--variant <str>               Which variant of the program to perform.
        \\--mode <str>                  The way that suggestions are given.
        \\--file <str>                  The path to the history file, such as ~/.zsh_history or ~/.bash_history.
        \\--command <str>               The current, unfinished command.
        \\--cursor-idx <usize>          The 0-based cursor index of the current, unfinished command.
        \\-w, --max-width <usize>       The maximum amount of suggestions to be outputed.
        \\-h, --max-height <usize>      The maximum amount of suggestions to be outputed.
        \\-b, --bigram-weight <f64>     A multiple of how much the frequency in relation to the previous word should matter compared to the overall frequency of the word.
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

    if (res.args.init) |init| {
        try shell.printInitScript(init);
        return;
    }

    const config = try Config.init(res.args);
    try config.run(alloc);
}

// Chores:
//
// [ ] Read through the entire codebase, and check that the comments are up to
//     date.
// [ ] Split up/refactor Popup.display. Check that all comments make sense, and
//     remove unecessary ones. Maybe rename it to Popup.render.
//
// Fixes/bugs:
//
// [ ] Optimize:
//     Why does the program only work when run in -Doptimize=Debug?
// [ ] Bash:
//     Why does bash not work, and why does it sort of clear the current
//     command?
//
// Roadmap/Features:
//
// [ ] Source the history file backwards
//     Most shells have the most recent commands at the bottom of the file, which
//     means that if the user wants to have their most recent patterns analyzed
//     then we need to read the history file backwards.
// [ ] Continously suggest new suggestions
//     Ex: When typing, have the Popup window follow the cursor and sample and
//     give new suggestions.
//
//     This would require a new way of outputting stdout to the command, as
//     currently the entire new line gets dumped when the process terminates,
//     which means that outputting and updating the command each time
//     `.pass_through_byte` activates needs to accommodate a new mechanism.
// [ ] A way to store and update the prediction model.
//     That way the program doesn't need to read the entire .<shell>_history file
//     on startup.
//     Maybe run two threads:
//       - One for using the model to predict answers. This thread would also be
//       in charge of rendering.
//       - One for reading the current ~/.<shell>_history file and updating the
//       model's parameters in some json file in ~/.local. If the user quits the
//       program before this was finished updating, then it would simply abandon
//       the update.
// [ ] Optional configuration file somwhere on the system.
//     ~/.config/suggest.yml maybe?
//     This could contain both visual config, Markov bigram-weight and other
//     stuff. <SHELL>_INIT_SCIPT would simply have
//     `$ suggest --init-<shell> --path ... --line ... --cursor-idx ...`
// [ ] More suggestion pickers.
//     - File picker (such as fzf ctrl-t).
//     - Command picker (such as ctrl-r).
