#!/usr/bin/env bash
# Test mit stty raw mode

set -u

echo "==================================="
echo "Input-Handling Test (stty raw)"
echo "==================================="
echo ""
echo "Drücke Pfeiltasten oder 'q' zum Beenden"
echo ""

count=0
while [ $count -lt 10 ]; do
    echo -n "Taste #$((count+1)): "
    
    # Set to raw mode for reading
    old_stty=$(stty -g)
    stty raw -echo 2>/dev/null
    
    # Read first byte
    key=$(dd bs=1 count=1 2>/dev/null)
    
    # If ESC, read 2 more bytes
    if [ "$key" = $'\x1b' ]; then
        rest=$(dd bs=1 count=2 2>/dev/null)
        key="${key}${rest}"
    fi
    
    # Restore terminal
    stty "$old_stty" 2>/dev/null
    
    # Show what was pressed
    case "$key" in
        $'\x1b[A') echo "Arrow UP";;
        $'\x1b[B') echo "Arrow DOWN";;
        $'\x1b[C') echo "Arrow RIGHT";;
        $'\x1b[D') echo "Arrow LEFT";;
        "q"|"Q")   echo "QUIT - Beende..."; break;;
        "")        echo "<ENTER>";;
        *)         echo "'$key'";;
    esac
    
    ((count++))
done

echo ""
echo "Test beendet."
