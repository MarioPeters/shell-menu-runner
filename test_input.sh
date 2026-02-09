#!/usr/bin/env bash
# Test-Script für Input-Handling

set -u

echo "==================================="
echo "Input-Handling Test"
echo "==================================="
echo ""
echo "Drücke Pfeiltasten oder ESC zum Beenden"
echo "Jede Taste wird angezeigt"
echo ""

count=0
while [ $count -lt 10 ]; do
    echo -n "Taste #$((count+1)): "
    
    # Read first character directly
    key=""
    read -rsn1 key
    
    # If ESC, read next 2 chars without timeout (they arrive instantly for arrow keys)
    if [ "$key" = $'\x1b' ]; then
        char2=""
        char3=""
        # Try to read with timeout, but use || true to avoid failures
        read -rsn1 -t 0.2 char2 2>/dev/null || true
        if [ -n "$char2" ]; then
            # Got second char - read third one
            read -rsn1 -t 0.2 char3 2>/dev/null || true
            key="${key}${char2}${char3}"
        fi
    fi
    
    # Show what was pressed
    case "$key" in
        $'\x1b[A') echo "Arrow UP";;
        $'\x1b[B') echo "Arrow DOWN";;
        $'\x1b[C') echo "Arrow RIGHT";;
        $'\x1b[D') echo "Arrow LEFT";;
        $'\x1b')   echo "ESC - Beende..."; break;;
        "")        echo "<ENTER>";;
        *)         echo "'$key'";;
    esac
    
    ((count++))
done

echo ""
echo "Test beendet."
