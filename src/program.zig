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
    command_buffer: ?[]u8 = null,
    cursor_idx: usize = 0,
    max_menu_width: usize = 20,
    max_menu_height: usize = 8,
    /// This value should be quite high as otherwise commonly used commands,
    /// such as `cd` or `ls` trumps all other commands due to how the Markov
    /// score is currently calculated. This could be a good reason to think of
    /// another metric to calculate the score.
    markov_bigram_weight: f64 = 120.0,
    /// Some keybindings that probably exist on the heap somewhere. NOTE: This
    /// could be a pointer to where that ArrayList is located. This note sortof
    /// ties in with the FIXME below.
    /// FIXME: Some way to determine these. Probably connected to the config
    /// file sourcing.
    keybindings: []const Menu.InternalAction.Keybind = Menu.InternalAction.default_keybinds[0..],

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

    pub fn deinit(self: *Config, alloc: Allocator) void {
        if (self.command_buffer) |buf| {
            alloc.free(buf);
            self.command_buffer = null;
        }
    }

    const NextFrame = enum {
        quit,
        @"continue",
    };

    fn nextFrameFromMode(self: *Config) NextFrame {
        return switch (self.program.mode) {
            .single, .@"one-shot" => .quit,
            .interactive => .@"continue",
        };
    }

    fn accept(self: *Config, alloc: Allocator, out: *std.io.Writer, menu: *const Menu, item: []const u8) !NextFrame {
        // We need to replace the current word with item. Ex:
        // `git br# -> git branch`
        // where # represents the cursor.
        const left = parsing.popLeftTokenOfIdx(self.command, self.cursor_idx);
        const right = self.command[self.cursor_idx..];

        const new_left = try std.fmt.allocPrint(alloc, "{s}{s}", .{ left, item });
        defer alloc.free(new_left);
        const start = try menu.terminal.getCommandStart(self.cursor_idx);

        const slice = try std.fmt.allocPrint(alloc, "{s}{s}", .{ new_left, right });
        defer alloc.free(slice);

        try out.writeAll(slice);
        try out.flush();

        // FIXME: Yet here we assume that the new command is only on a single
        // row.
        try menu.terminal.goto(start.row, start.col + new_left.len);
        return .quit;
    }

    fn setCommand(self: *Config, alloc: Allocator, new: []u8) void {
        if (self.command_buffer) |buf| {
            alloc.free(buf);
        }
        self.command_buffer = new;
        self.command = new;
    }

    fn passThroughByte(self: *Config, alloc: Allocator, out: *std.io.Writer, byte: u8) !NextFrame {
        // This programs returns the entire new line via stdout, which
        // means we simply need to append this byte at cursor_idx in
        // the line.
        const left = self.command[0..self.cursor_idx];
        const right = self.command[self.cursor_idx..];
        const slice = try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{ left, byte, right });

        // The slice should only have appended a single character.
        std.debug.assert(self.command.len + 1 == slice.len);
        // Update the command and cursor_index, in case we want to continue.
        self.setCommand(alloc, slice);
        self.cursor_idx += 1;

        switch (self.program.mode) {
            .single => {
                try out.writeAll(slice);
                try out.flush();
                return .quit;
            },
            .interactive => return .@"continue",
            .@"one-shot" => unreachable,
        }
    }

    fn manipulateText(self: *Config, alloc: Allocator, edit: Menu.TextManipulation) !NextFrame {
        switch (edit) {
            .left_delete_one_char => {
                if (self.command.len == 0 or self.cursor_idx == 0) {
                    return self.nextFrameFromMode();
                }

                const delete_idx = @min(self.command.len - 1, self.cursor_idx - 1);

                const left = self.command[0..delete_idx];
                const right = self.command[delete_idx + 1 ..];
                const new = try std.fmt.allocPrint(alloc, "{s}{s}", .{ left, right });
                self.setCommand(alloc, new);
                self.cursor_idx -= 1;

                return self.nextFrameFromMode();
            },
            .right_delete_one_char => {
                if (self.command.len == 0) {
                    return self.nextFrameFromMode();
                }

                const delete_idx = @min(self.command.len - 1, self.cursor_idx);

                const left = self.command[0..delete_idx];
                const right = self.command[delete_idx + 1 ..];
                const new = try std.fmt.allocPrint(alloc, "{s}{s}", .{ left, right });
                self.setCommand(alloc, new);

                return self.nextFrameFromMode();
            },
            .move_to_start => {
                self.cursor_idx = 0;
                return self.nextFrameFromMode();
            },
            .move_to_end => {
                self.cursor_idx = self.command.len;
                return self.nextFrameFromMode();
            },
            .move_left_one_char => {
                if (self.cursor_idx == 0) return self.nextFrameFromMode();
                self.cursor_idx -= 1;
                return self.nextFrameFromMode();
            },
            .move_right_one_char => {
                self.cursor_idx = @min(self.command.len, self.cursor_idx + 1);
                return self.nextFrameFromMode();
            },
        }
    }

    fn processAction(self: *Config, alloc: Allocator, out: *std.io.Writer, menu: *Menu, suggestions: [][]const u8) !NextFrame {
        if (suggestions.len == 0) return switch (self.program.mode) {
            .interactive => .@"continue",
            .single, .@"one-shot" => .quit,
        };

        // Clear the menu before we proceed.
        // FIXME: Do we need this?
        try menu.clear(suggestions);

        if (self.program.mode == .@"one-shot") {
            // Choose the most-appropriate suggestion. We are allowed to get
            // the first element, as the case with no elements is handled up
            // top.
            const item = suggestions[0];

            const left = parsing.popLeftTokenOfIdx(self.command, self.cursor_idx);
            const right = self.command[self.cursor_idx..];
            const slice = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ left, item, right });
            defer alloc.free(slice);

            try out.writeAll(slice);
            try out.flush();

            return .quit;
        }

        const req = try menu.getAction(self.keybindings, suggestions);

        return switch (req) {
            .quit => .quit,
            .accept => |idx| {
                const item = suggestions[idx];
                return try self.accept(alloc, out, @constCast(menu), item);
            },
            .pass_through_byte => |byte| {
                return try self.passThroughByte(alloc, out, byte);
            },
            .edit => |ed| {
                return try self.manipulateText(alloc, ed);
            },
        };
    }

    pub fn run(self: *Config, alloc: Allocator) !void {
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

        var suggestions = try alloc.alloc([]const u8, self.max_menu_height);
        defer alloc.free(suggestions);
        const mbw = self.markov_bigram_weight;

        var count: usize = 0;

        var out_buf: [1024]u8 = undefined;
        var out_file_writer = std.fs.File.stdout().writer(&out_buf);
        const out: *std.io.Writer = &out_file_writer.interface;

        loop: while (true) {
            const prev_cursor_idx = self.cursor_idx;

            const current_command_slice = self.command[0..];
            var current_command = try parsing.Command.fromSlice(alloc, current_command_slice);
            defer current_command.deinit(alloc);

            const pair = pair: {
                const cursor_idx = if (self.cursor_idx < 1) 0 else self.cursor_idx - 1;
                break :pair parsing.getRelevantBigram(current_command_slice, cursor_idx);
            };

            count = try general.suggest(alloc, suggestions[0..], pair.fst, pair.snd, mbw);
            if (count == 0) {
                try out.writeAll(self.command);
                try out.flush();
                break :loop;
            }

            // Only display the returned suggestions. We previously supplied
            // `suggestions[0..]`, which lead to segfault as the display tried to
            // iterate through unintialized memory.
            const slice = suggestions[0..count];
            const p = try self.processAction(alloc, out, @constCast(&menu), slice);

            // We need to rerender the prompt with the current state.
            try menu.terminal.clearAndRenderLine(self.command, prev_cursor_idx, self.cursor_idx);
            try menu.clear(slice);

            switch (p) {
                .quit => break :loop,
                .@"continue" => {
                    continue :loop;
                },
            }
        }

        try menu.terminal.clearCommand(self.cursor_idx, null);
    }
};
