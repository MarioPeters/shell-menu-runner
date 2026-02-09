#!/bin/bash
read_key() {
    local key=""
    if ! read -rsn1 key; then
        return 1
    fi
    if [ "$key" = $'\x1b' ]; then
        local rest=""
        read -rsn2 -t 0.05 rest 2>/dev/null || rest=""
        key="${key}${rest}"
    fi
    printf "%s" "$key"
}

echo "Press keys. Press q to quit."
while true; do
   k=$(read_key)
   echo "Key hex: $(printf '%s' "$k" | xxd)"
   if [[ "$k" == "q" ]]; then break; fi
done
