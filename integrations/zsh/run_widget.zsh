function _open_runner_widget() {
    local PREV_BUFFER="$BUFFER"; local PREV_CURSOR="$CURSOR"
    BUFFER=""; zle redisplay
    run < /dev/tty
    BUFFER="$PREV_BUFFER"; CURSOR="$PREV_CURSOR"; zle redisplay
}
zle -N _open_runner_widget
bindkey '^o' _open_runner_widget
