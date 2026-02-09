#!/usr/bin/env bash
# Debug: Was sendet das Terminal wirklich?

echo "Drücke eine Pfeiltaste, dann ENTER:"
echo ""

# Read entire input with hex dump
IFS= read -r input
echo "Input als Text: '$input'"
echo "Input als Hex:"
echo -n "$input" | xxd

echo ""
echo "Länge: ${#input} Zeichen"
