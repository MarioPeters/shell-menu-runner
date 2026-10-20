#!/usr/bin/env zsh
# Zsh widget: open the Shell Menu Runner menu with Ctrl+O.
# Source this file from ~/.zshrc — it is not meant to be executed.
# (Syntax is checked with `zsh -n`, ShellCheck cannot parse zsh code.)

function _open_runner_widget() {
    local PREV_BUFFER="$BUFFER"; local PREV_CURSOR="$CURSOR"
    BUFFER=""; zle redisplay
    run < /dev/tty
    BUFFER="$PREV_BUFFER"; CURSOR="$PREV_CURSOR"; zle redisplay
}
zle -N _open_runner_widget
bindkey '^o' _open_runner_widget
