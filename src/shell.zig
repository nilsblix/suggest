const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn printInitScript(shell: []const u8) !void {
    var stdout_wrapper = std.fs.File.stdout().writer(&.{});
    var stdout = &stdout_wrapper.interface;

    if (std.mem.eql(u8, shell, "zsh")) {
        try stdout.writeAll(ZSH_INIT_SCRIPT);
        return;
    }

    if (std.mem.eql(u8, shell, "bash")) {
        try stdout.writeAll(BASH_INIT_SCRIPT);
        return;
    }

    try stdout.print("Found no init-script for shell: {s}\n", .{shell});
}

pub const ZSH_INIT_SCRIPT =
    \\ suggest-widget() {
    \\   local line="$LBUFFER$RBUFFER"
    \\   local cursor_index=${#LBUFFER}
    \\   local old_rbuffer="$RBUFFER"
    \\
    \\   # FIXME: Use $PATH and name the program `suggest`
    \\   # to now have to use this path.
    \\   local new_command=$(
    \\     ~/Code/suggest/zig-out/bin/suggest \
    \\       --file ~/.zsh_history \
    \\       --command="$line" \
    \\       --mode=interactive \
    \\       --cursor-idx="$cursor_index" \
    \\       --max-height=15 \
    \\       --max-width=40 \
    \\       --bigram-weight=900
    \\   ) || return
    \\
    \\   # If nothing returned, do nothing
    \\   [[ -z "$new_command" ]] && return
    \\
    \\   # Replace the entire command with the program's description of command.
    \\   BUFFER="$new_command"
    \\
    \\   local new_len=${#BUFFER}
    \\   local rlen=${#old_rbuffer}
    \\   CURSOR=$(( new_len - rlen ))
    \\
    \\   zle redisplay
    \\ }
    \\
    \\ zle -N suggest-widget
    \\ bindkey '^g' suggest-widget
;

pub const BASH_INIT_SCRIPT =
    \\ __suggest_widget() {
    \\   local line=$READLINE_LINE
    \\   local cursor_index=$READLINE_POINT
    \\   local old_rbuffer=${line:cursor_index}
    \\ 
    \\   local new_command=$(
    \\     ~/Code/suggest/zig-out/bin/suggest \
    \\       --file "$HOME/.bash_history" \
    \\       --command="$line" \
    \\       --mode=interactive \
    \\       --cursor-idx="$cursor_index" \
    \\       --max-height=15 \
    \\       --max-width=40 \
    \\       --bigram-weight=400
    \\   ) || return
    \\ 
    \\   [[ -z "$new_command" ]] && return
    \\ 
    \\   READLINE_LINE=$new_command
    \\ 
    \\   local new_len=${#READLINE_LINE}
    \\   local rlen=${#old_rbuffer}
    \\   READLINE_POINT=$(( new_len - rlen ))
    \\ }
    \\ 
    \\ bind -x '"\C-g":__suggest_widget'
;
