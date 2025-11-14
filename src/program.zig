const std = @import("std");
const Allocator = std.mem.Allocator;

const parsing = @import("parsing.zig");
const General = @import("General.zig");
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
};

const HistoryFile = struct {
    path: []const u8,
};

pub const Config = struct {
    program: Program,
    file: HistoryFile,
    command: []const u8 = "",
    cursor_idx: usize = 0,
    max_menu_width: usize = 20,
    max_menu_height: usize = 8,
    /// This value should be quite high as otherwise commonly used commands,
    /// such as `cd` or `ls` trumps all other commands due to how the Markov
    /// score is currently calculated. This could be a good reason to think of
    /// another metric to calculate the score.
    markov_bigram_weight: f64 = 120.0,

    /// Args is initialized via clap.
    pub fn init(args: anytype) !Config {
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
            config.command = c;
        }

        if (args.@"cursor-idx") |i| {
            config.cursor_idx = i;
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

    pub fn run(self: Config, alloc: Allocator) !void {
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

        const current_command_slice = self.command[0..];
        var current_command = try parsing.Command.fromSlice(alloc, current_command_slice);
        defer current_command.deinit(alloc);

        const pair = pair: {
            const cursor_idx = if (self.cursor_idx < 1) 0 else self.cursor_idx;
            break :pair parsing.getRelevantBigram(current_command_slice, cursor_idx);
        };

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
        try menu.clear(suggestions[0..count]);
        switch (ret) {
            .terminate_program => return,
            .selected_index => |idx| {
                const item = suggestions[idx];

                // We need to replace the current word with item. Ex:
                // `git br# -> git branch`
                // where # represents the cursor.
                const left = parsing.popLeftTokenOfIdx(self.command, self.cursor_idx);
                const right = self.command[self.cursor_idx..];
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
                const left = self.command[0..self.cursor_idx];
                const right = self.command[self.cursor_idx..];
                const slice = try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{ left, b, right });

                var out_buf: [16]u8 = undefined;
                var out_file_writer = std.fs.File.stdout().writer(&out_buf);
                const out: *std.io.Writer = &out_file_writer.interface;

                try out.writeAll(slice);
                try out.flush();
            },
        }
        try menu.clear(suggestions[0..count]);
    }
};
