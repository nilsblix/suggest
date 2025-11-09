const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ZSH_INIT_SCRIPT =
\\ suggest-widget() {
\\   local line cursor_index new_command
\\
\\   line="$LBUFFER$RBUFFER"
\\   cursor_index=${#LBUFFER}
\\   local old_rbuffer="$RBUFFER"
\\
\\   new_command=$(
\\     ~/Code/suggest/zig-out/bin/suggest \
\\       --path ~/.zsh_history \
\\       --line="$line" \
\\       --cursor-idx="$cursor_index" \
\\       --max-height=15 \
\\       --max-width=20 \
\\       --bigram-weight=400
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
