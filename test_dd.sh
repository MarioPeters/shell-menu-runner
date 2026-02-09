#!/usr/bin/env bash
# Alternative Methode mit dd

echo "Drücke Pfeiltaste (Links/Rechts/Hoch/Runter):"
echo ""

# Set terminal to raw mode
stty -echo -icanon min 1 time 0 2>/dev/null

# Read 3 bytes (max arrow key length)
key=$(dd bs=1 count=3 2>/dev/null | xxd -p)

# Restore terminal
stty sane 2>/dev/null

echo "Gelesen (hex): $key"

case "$key" in
    1b5b41) echo "Arrow UP";;
    1b5b42) echo "Arrow DOWN";;
    1b5b43) echo "Arrow RIGHT";;
    1b5b44) echo "Arrow LEFT";;
    1b)     echo "Pure ESC";;
    *)      echo "Andere Taste: $key";;
esac
