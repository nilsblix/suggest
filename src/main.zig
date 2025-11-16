const std = @import("std");
const Allocator = std.mem.Allocator;
const clap = @import("clap");

const shell = @import("shell.zig");
const program = @import("program.zig");
const Config = program.Config;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

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

    var config = try Config.init(res.args);
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
// [x] Optimize:
//     Why does the program only work when run in -Doptimize=Debug?
//     Solution:
//     Terminal kept stdout and stdin as pointers, which were kept only in
//     Terminal.init. In debug mode this is "fine" (not really) as in Debug
//     mode dangling pointers are left for a while longer. Release* modes are
//     less merciful.
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
