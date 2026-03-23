#!/bin/bash
# 🎵 MuMuPai — Dein Musik-Player mit Streaming! by Shinpai-AI
# Portable Start — einfach doppelklicken!
DIR="$(cd "$(dirname "$0")" && pwd)"

# ffmpeg/ffplay Check
if ! command -v ffplay &>/dev/null; then
    echo ""
    echo "  ❌ ffplay nicht gefunden!"
    echo "  MuMuPai braucht ffmpeg (enthält ffplay + ffprobe)."
    echo ""
    echo "  Installieren mit:"
    echo "    Fedora/Nobara:  sudo dnf install ffmpeg"
    echo "    Ubuntu/Debian:  sudo apt install ffmpeg"
    echo "    Arch/Manjaro:   sudo pacman -S ffmpeg"
    echo ""
    echo "  Oder nutze install.sh für automatische Installation!"
    echo ""
    read -p "  [Enter zum Beenden]" _
    exit 1
fi

cd "$DIR/bundle"
exec ./mumupai --disable-impeller "$@"
