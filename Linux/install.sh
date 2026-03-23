#!/bin/bash
# ╔══════════════════════════════════════════════╗
# ║  🎵 MuMuPai Installer                       ║
# ║  Musik-Player mit Streaming by Shinpai-AI   ║
# ║  Unterstützt: Debian/Ubuntu, Fedora/Nobara, ║
# ║  Arch/Manjaro, openSUSE                     ║
# ╚══════════════════════════════════════════════╝

set -e

APP_NAME="MuMuPai"
APP_VERSION="1.0.0"
DEFAULT_INSTALL_DIR="$HOME/.local/share/mumupai"
DESKTOP_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor/512x512/apps"
BIN_DIR="$HOME/.local/bin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
NC='\033[0m'

echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════╗"
echo "║  🎵 MuMuPai Installer v${APP_VERSION}               ║"
echo "║  Musik-Player mit Streaming!                 ║"
echo "║  by Shinpai-AI                               ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# === DEINSTALLATION ===
if [ "$1" = "--uninstall" ]; then
    echo -e "${YELLOW}🗑️  Deinstalliere MuMuPai...${NC}"
    rm -rf "$DEFAULT_INSTALL_DIR"
    rm -f "$BIN_DIR/mumupai"
    rm -f "$DESKTOP_DIR/mumupai.desktop"
    rm -f "$ICON_DIR/mumupai.png"
    update-desktop-database "$DESKTOP_DIR" &>/dev/null || true
    echo -e "  ${GREEN}✅ MuMuPai deinstalliert!${NC}"
    exit 0
fi

# === DISTRO ERKENNUNG ===
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_NAME="$PRETTY_NAME"
    else
        DISTRO_NAME="Unknown"
    fi

    if command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"; PKG_INSTALL="sudo dnf install -y"
    elif command -v apt &>/dev/null; then
        PKG_MANAGER="apt"; PKG_INSTALL="sudo apt install -y"
    elif command -v pacman &>/dev/null; then
        PKG_MANAGER="pacman"; PKG_INSTALL="sudo pacman -S --noconfirm"
    elif command -v zypper &>/dev/null; then
        PKG_MANAGER="zypper"; PKG_INSTALL="sudo zypper install -y"
    else
        PKG_MANAGER="unknown"; PKG_INSTALL=""
    fi

    echo -e "  System: ${GREEN}${DISTRO_NAME}${NC}"
    echo -e "  Paketmanager: ${GREEN}${PKG_MANAGER}${NC}"
    echo ""
}

# === INSTALLATIONSPFAD ===
choose_install_dir() {
    echo -e "${YELLOW}📁 Wohin installieren?${NC}"
    echo -e "  Standard: ${GREEN}${DEFAULT_INSTALL_DIR}${NC}"
    read -p "  Pfad [Enter = Standard]: " CUSTOM_DIR

    if [ -n "$CUSTOM_DIR" ]; then
        INSTALL_DIR="$(eval echo "$CUSTOM_DIR")"
    else
        INSTALL_DIR="$DEFAULT_INSTALL_DIR"
    fi

    echo -e "  → Installiere nach: ${GREEN}${INSTALL_DIR}${NC}"
    echo ""
}

# === DEPENDENCIES ===
install_deps() {
    echo -e "${YELLOW}📦 Prüfe Abhängigkeiten...${NC}"

    NEED_INSTALL=""

    # ffmpeg (enthält ffplay + ffprobe)
    if command -v ffplay &>/dev/null && command -v ffprobe &>/dev/null; then
        echo -e "  ✅ ffmpeg (ffplay + ffprobe)"
    else
        echo -e "  ❌ ffmpeg fehlt!"
        NEED_INSTALL="$NEED_INSTALL ffmpeg"
    fi

    if [ -n "$NEED_INSTALL" ]; then
        echo ""
        echo -e "  ${YELLOW}Installiere:${NEED_INSTALL}${NC}"
        if [ "$PKG_MANAGER" = "unknown" ]; then
            echo -e "  ${RED}❌ Kein Paketmanager erkannt! Bitte manuell installieren:${NEED_INSTALL}${NC}"
            exit 1
        fi
        $PKG_INSTALL $NEED_INSTALL || {
            echo -e "  ${RED}❌ Installation fehlgeschlagen! Sudo-Passwort nötig?${NC}"
            exit 1
        }
        echo -e "  ${GREEN}✅ Pakete installiert!${NC}"
    fi
    echo ""
}

# === APP INSTALLIEREN ===
install_app() {
    echo -e "${YELLOW}🔧 Installiere MuMuPai...${NC}"

    # Bundle kopieren
    mkdir -p "$INSTALL_DIR"
    cp -r "$SCRIPT_DIR/bundle/"* "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/mumupai"

    # Icon kopieren
    if [ -f "$SCRIPT_DIR/../assets/icon.png" ]; then
        mkdir -p "$INSTALL_DIR/assets"
        cp "$SCRIPT_DIR/../assets/icon.png" "$INSTALL_DIR/assets/"
    fi

    echo -e "  ✅ App kopiert nach: ${GREEN}${INSTALL_DIR}${NC}"

    # Launcher Script
    mkdir -p "$BIN_DIR"
    cat > "$BIN_DIR/mumupai" << LAUNCHER
#!/bin/bash
exec "$INSTALL_DIR/mumupai" --disable-impeller "\$@"
LAUNCHER
    chmod +x "$BIN_DIR/mumupai"
    echo -e "  ✅ Launcher: ${GREEN}${BIN_DIR}/mumupai${NC}"

    # Desktop Entry
    mkdir -p "$DESKTOP_DIR"
    cat > "$DESKTOP_DIR/mumupai.desktop" << DESKTOP
[Desktop Entry]
Name=MuMuPai
GenericName=Music Player
Comment=Dein Musik-Player mit Streaming! — by Shinpai-AI
Exec=${INSTALL_DIR}/mumupai --disable-impeller
Icon=${INSTALL_DIR}/data/flutter_assets/assets/icon.png
Terminal=false
Type=Application
Categories=AudioVideo;Music;Audio;Player;
Keywords=music;player;streaming;mumupai;shinpai;audio;
StartupNotify=false
DESKTOP
    chmod +x "$DESKTOP_DIR/mumupai.desktop"
    echo -e "  ✅ Desktop-Eintrag erstellt"

    # System-Icon
    mkdir -p "$ICON_DIR"
    cp "$INSTALL_DIR/data/flutter_assets/assets/icon.png" "$ICON_DIR/mumupai.png" 2>/dev/null || true
    echo -e "  ✅ System-Icon installiert"

    # Desktop DB + Icon Cache
    update-desktop-database "$DESKTOP_DIR" &>/dev/null || true
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" &>/dev/null || true

    echo ""
}

# === FERTIG ===
finish() {
    echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ MuMuPai erfolgreich installiert!         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  📍 Installiert in: ${PURPLE}${INSTALL_DIR}${NC}"
    echo -e "  🖥️  Startmenü:     ${PURPLE}MuMuPai${NC} (suchen!)"
    echo -e "  💻 Terminal:       ${PURPLE}mumupai${NC}"
    echo ""
    echo -e "  ${YELLOW}Features:${NC}"
    echo -e "  🎵 Spielt alle Audioformate (MP3, FLAC, WAV, OGG, AAC...)"
    echo -e "  📡 Streaming im LAN und Internet"
    echo -e "  💾 Playlisten speichern & laden"
    echo -e "  🔊 Volume Control, Shuffle, Repeat"
    echo ""
    echo -e "  🗑️  Deinstallieren: ${PURPLE}bash install.sh --uninstall${NC}"
    echo ""
    echo -e "  ${GREEN}shinpai.de | AGPL-3.0${NC}"
    echo ""

    read -p "  🎵 MuMuPai jetzt starten? [J/n]: " START_NOW
    if [ "$START_NOW" != "n" ] && [ "$START_NOW" != "N" ]; then
        echo -e "  🚀 Starte MuMuPai..."
        nohup "$INSTALL_DIR/mumupai" --disable-impeller &>/dev/null &
    fi
}

# === MAIN ===
detect_distro
choose_install_dir
install_deps
install_app
finish
