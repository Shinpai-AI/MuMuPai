# 🎵 MuMuPai

**Dein Musik-Player der jeden Ton spielt — und streamt!**

MuMuPai spielt alle gängigen Audioformate, sammelt sie in Playlisten und macht deine Musik per Streaming für jeden verfügbar. Lokal im WLAN oder übers Internet.

**Ein Player. Jedes Format. Überall streambar.**

![License](https://img.shields.io/badge/license-AGPL--3.0-green)
![Platform](https://img.shields.io/badge/platform-Linux-brightgreen)

---

## Features

- **Alle Formate** — MP3, FLAC, WAV, OGG, AAC, M4A, WMA
- **Streaming** — Eingebauter Server mit Web-UI für jeden Browser
- **LAN + Internet** — Public IP Erkennung + Port-Forwarding Hinweis
- **Playlisten** — Speichern, laden, benennen, merkt sich den letzten Stand
- **Drag & Drop** — Dateien und Ordner einfach reinziehen
- **Volume Control** — Lautstärke direkt in der App
- **Shuffle & Repeat** — Wie du's gewohnt bist
- **System Tray** — Minimiert in den Tray, immer griffbereit
- **Session Restore** — Startet genau da wo du aufgehört hast
- **Web-Player** — Empfänger bekommt einen vollen Player im Browser (SVG-Icons, Seekbar, Playlist)

## Installation

### Linux

**Option 1: Portable (Einfach starten)**
```bash
cd Linux
bash start.sh
```

**Option 2: Installieren (Desktop-Icon + Startmenü)**
```bash
cd Linux
bash install.sh
```
Danach findest du MuMuPai im Startmenü oder tippst `mumupai` im Terminal.

**Deinstallieren:**
```bash
bash install.sh --uninstall
```

### Voraussetzungen

- **ffmpeg** (enthält ffplay + ffprobe) — wird vom Installer automatisch installiert
- Unterstützte Distros: Debian/Ubuntu, Fedora/Nobara, Arch/Manjaro, openSUSE

### Windows / macOS / Android

Coming soon! MuMuPai ist aktuell für Linux optimiert. Weitere Plattformen folgen.

## Streaming

1. MuMuPai starten und Musik laden
2. WiFi-Icon oben rechts klicken → Stream startet
3. Link kopieren und in jedem Browser öffnen
4. Musik genießen — überall im Netzwerk!

Für Internet-Zugang: Port 8888 im Router freigeben (Port-Forwarding).

## Screenshots

*Coming soon*

## Tech Stack

- **Flutter** (Dart) — Cross-Platform UI
- **ffplay/ffprobe** — Audio Playback & Metadata
- **Dart HttpServer** — Streaming Backend

## License

AGPL-3.0 — siehe [LICENSE](LICENSE)

---

**MuMuPai by [Shinpai-AI](https://shinpai.de)**
