const std = @import("std");
const Allocator = std.mem.Allocator;
const clap = @import("clap");

const parsing = @import("parsing.zig");
const General = @import("General.zig");
const shell = @import("shell.zig");
const Menu = @import("Menu.zig");

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
    max_menu_width: usize = 20,
    max_menu_height: usize = 8,
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
            config.max_menu_width = w;
        }

        if (args.@"max-height") |h| {
            config.max_menu_height = h;
        }

        if (args.@"bigram-weight") |w| {
            config.markov_bigram_weight = w;
        }

        return config;
    }

    fn run(self: Config, alloc: Allocator) !void {
        var data = try parsing.Data.init(alloc, self.file.path);
        defer data.deinit(alloc);

        var general = try General.init(alloc, data.*);
        defer general.deinit();

        var menu = try Menu.init(alloc, .{
            .max_width = self.max_menu_width,
            .normal = .{},
            .selected = .{
                .bg = .{ .r = 0x87, .g = 0xAF, .b = 0xD7 },
                .fg = .{ .r = 0x00, .g = 0x00, .b = 0x00 },
            },
            .border = .rounded,
        });
        defer menu.deinit(alloc);

        const current_command_slice = self.program.command[0..];
        var current_command = try parsing.Command.fromSlice(alloc, current_command_slice);
        defer current_command.deinit(alloc);

        const pair = parsing.getRelevantBigram(current_command_slice, @max(0, self.program.cursor_idx - 1));

        var suggestions = try alloc.alloc([]const u8, self.max_menu_height);
        defer alloc.free(suggestions);

        const mbw = self.markov_bigram_weight;
        const count = try general.suggest(alloc, suggestions[0..], pair.fst, pair.snd, mbw);
        if (count == 0) return;

        // Only display the returned suggestions. We previously supplied
        // `suggestions[0..]`, which lead to segfault as the display tried to
        // iterate through unintialized memory.
        const ret = try menu.handleInput(suggestions[0..count]);
        // Clear the menu before we proceed.
        try menu.clear(suggestions[0..]);
        switch (ret) {
            .quit => return,
            .selected_index => |idx| {
                const item = suggestions[idx];

                // We need to replace the current word with item. Ex:
                // `git br# -> git branch`
                // where # represents the cursor.
                const left = parsing.popLeftTokenOfIdx(self.program.command, self.program.cursor_idx);
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
// [x] Restructure the backend, and make it possible to add new Models.
// [ ] Read through the entire codebase, and check that the comments are up to
//     date.
// [x] Split up/refactor Menu.display. Check that all comments make sense, and
//     remove unecessary ones. Maybe rename it to Menu.render.
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
//     Ex: When typing, have the Menu window follow the cursor and sample and
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
