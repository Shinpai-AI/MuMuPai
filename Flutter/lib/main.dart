import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:just_audio/just_audio.dart' as ja;

Future<String?> getPublicIP() async {
  for (final url in ['https://api.ipify.org', 'https://ifconfig.me/ip']) {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();
      final ip = body.trim();
      if (ip.isNotEmpty && RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(ip)) return ip;
    } catch (_) {}
  }
  return null;
}

void _globalCleanup() {
  if (Platform.isLinux || Platform.isMacOS) {
    try { Process.runSync('pkill', ['-f', 'ffplay.*-nodisp.*-autoexit']); } catch (_) {}
  } else if (Platform.isWindows) {
    try { Process.runSync('taskkill', ['/F', '/IM', 'ffplay.exe']); } catch (_) {}
    try { Process.runSync('taskkill', ['/F', '/IM', 'ffplay']); } catch (_) {}
  }
}

// ffplay/ffprobe Pfade ermitteln
String _findBundledBinary(String name) {
  // Linux: System-Binary bevorzugen (kompatibel mit lokalen Libs)
  if (Platform.isLinux) {
    try {
      final result = Process.runSync('which', [name]);
      if (result.exitCode == 0) return result.stdout.toString().trim();
    } catch (_) {}
  }
  // Windows/macOS: Bundled bevorzugen
  final exeDir = p.dirname(Platform.resolvedExecutable);
  final bundled = p.join(exeDir, 'ffmpeg', Platform.isWindows ? '$name.exe' : name);
  if (File(bundled).existsSync()) return bundled;
  // Fallback: System PATH
  return name;
}

String ffplayBin = 'ffplay';
String ffprobeBin = 'ffprobe';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!(Platform.isAndroid || Platform.isIOS)) {
    ffplayBin = _findBundledBinary('ffplay');
    ffprobeBin = _findBundledBinary('ffprobe');
  }

  if (Platform.isLinux || Platform.isMacOS) {
    ProcessSignal.sigterm.watch().listen((_) { _globalCleanup(); exit(0); });
    ProcessSignal.sigint.watch().listen((_) { _globalCleanup(); exit(0); });
  }

  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(420, 720),
        minimumSize: Size(380, 600),
        title: 'MuMuPai',
        center: true,
        titleBarStyle: TitleBarStyle.normal,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  runApp(const MuMuPaiApp());
}

// === COLORS ===
const Color bgDark = Color(0xFF0a0f0a);
const Color bgCard = Color(0xFF142014);
const Color bgInput = Color(0xFF1c2e1c);
const Color bgPlayerOval = Color(0xFF0d1a0d);
const Color fgWhite = Color(0xFFe8f0e4);
const Color fgGray = Color(0xFF5a7a5a);
const Color fgGreen = Color(0xFF00c853);
const Color fgGreenDark = Color(0xFF1b5e20);
const Color fgGreenLight = Color(0xFF69f0ae);
const Color fgGreenGlow = Color(0xFF00e676);
const Color fgOrange = Color(0xFFe8724a);
const Color fgPurple = Color(0xFFa832b8);

class MuMuPaiApp extends StatelessWidget {
  const MuMuPaiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MuMuPai',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bgDark,
        colorScheme: const ColorScheme.dark(primary: fgGreen, secondary: fgOrange, surface: bgCard),
        useMaterial3: true,
      ),
      home: const MuMuPaiHome(),
    );
  }
}

class MuMuPaiHome extends StatefulWidget {
  const MuMuPaiHome({super.key});
  @override
  State<MuMuPaiHome> createState() => _MuMuPaiHomeState();
}

class _MuMuPaiHomeState extends State<MuMuPaiHome> with WindowListener, TrayListener {
  Process? _playerProcess;
  ja.AudioPlayer? _audioPlayer; // Android/iOS Player
  bool get _isAndroid => Platform.isAndroid || Platform.isIOS;
  List<String> playlist = [];
  int currentIndex = -1;
  bool isPlaying = false;
  bool isShuffle = false;
  bool isRepeat = false;
  double volume = 80;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool _isDragging = false;
  HttpServer? _streamServer;
  bool isStreaming = false;
  String? streamUrl;
  String? _localIP;
  String? _publicIP;
  bool _showPublicLink = false;
  Timer? _positionTimer;
  bool _playlistExpanded = true;

  final int streamPort = 8888;

  // Playlist-Persistenz
  String _playlistName = '';
  String? _playlistDir;
  static String get _configDir {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'] ?? 'C:\\Users\\Public';
      return '$appData\\MuMuPai';
    }
    final home = Platform.environment['HOME'] ?? '/tmp';
    return '$home/.config/mumupai';
  }
  static String get _defaultPlaylistDir => '$_configDir/playlists';
  static String get _sessionPath => '$_configDir/session.json';

  // System Tray
  final TrayManager _trayManager = trayManager;
  bool _trayReady = false;

  @override
  void initState() {
    super.initState();
    if (!_isAndroid) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
    if (_isAndroid) _audioPlayer = ja.AudioPlayer();
    _loadSession();
    if (!_isAndroid) _initSystemTray();
    if (!_isAndroid) _checkFirstLaunch();
  }

  Future<void> _initSystemTray() async {
    try {
      _trayManager.addListener(this);

      // Icon-Pfad
      final exeDir = p.dirname(Platform.resolvedExecutable);
      String iconPath = '$exeDir/data/flutter_assets/assets/icon.png';
      if (!File(iconPath).existsSync()) iconPath = '/media/shinpai/KI-Tools/MuMuPai/assets/icon.png';
      if (!File(iconPath).existsSync()) return;

      await _trayManager.setIcon(iconPath);

      await _trayManager.setContextMenu(Menu(items: [
        MenuItem(label: 'Zeigen', onClick: (_) => _showFromTray()),
        MenuItem(label: 'Play/Pause', onClick: (_) => _togglePlay()),
        MenuItem(label: 'Weiter', onClick: (_) => _next()),
        MenuItem.separator(),
        MenuItem(label: 'Beenden', onClick: (_) async { _fullCleanup(); _trayManager.destroy(); await windowManager.destroy(); }),
      ]));
      _trayReady = true;
    } catch (e) {
      _trayReady = false;
      debugPrint('Tray init failed: $e');
    }
  }

  @override
  void onTrayIconMouseDown() => _showFromTray();

  @override
  void onTrayIconRightMouseDown() => _trayManager.popUpContextMenu();

  void _minimizeToTray() async {
    if (_trayReady) {
      await windowManager.hide();
    } else {
      // Tray nicht verfügbar → normales Minimieren
      await windowManager.minimize();
    }
  }

  void _showFromTray() async {
    await windowManager.show();
    await windowManager.focus();
  }

  // === FIRST LAUNCH INSTALL DIALOG ===
  static String get _installedMarker => '$_configDir/.installed';

  Future<void> _checkFirstLaunch() async {
    // Warte bis UI bereit
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    if (File(_installedMarker).existsSync()) return;

    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: [
          ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.asset('assets/icon.png', width: 32, height: 32)),
          const SizedBox(width: 12),
          Text('MuMuPai', style: GoogleFonts.orbitron(color: fgGreen, fontSize: 18)),
        ]),
        content: const Text('Wie möchtest du MuMuPai nutzen?\n\nPortable: Einfach so starten, nix installieren.\nInstallieren: Desktop-Icon + Startmenü.',
            style: TextStyle(color: fgWhite, fontSize: 13, height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop('portable'),
            child: const Text('Portable', style: TextStyle(color: fgGray))),
          TextButton(onPressed: () => Navigator.of(ctx).pop('install'),
            child: const Text('Installieren', style: TextStyle(color: fgGreen, fontWeight: FontWeight.bold))),
        ],
      ),
    );

    if (choice == 'install') {
      await _performInstall();
    }

    // Marker setzen (auch bei portable — nicht nochmal fragen)
    try {
      final dir = Directory(_configDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      await File(_installedMarker).writeAsString('mode=${choice ?? "portable"}\ndate=${DateTime.now()}');
    } catch (_) {}
  }

  Future<void> _performInstall() async {
    String? installDir;
    if (Platform.isWindows) {
      installDir = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Installationsordner wählen');
      installDir ??= '${Platform.environment['APPDATA'] ?? 'C:\\Users\\Public'}\\MuMuPai';
    } else {
      installDir = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Installationsordner wählen');
      installDir ??= '${Platform.environment['HOME']}/.local/share/mumupai';
    }

    try {
      final dir = Directory(installDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);

      // Exe/Binary kopieren
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final sourceDir = Directory(exeDir);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Installiere nach $installDir...')));
      }

      // Alle Dateien kopieren
      for (var entity in sourceDir.listSync(recursive: true)) {
        final relative = p.relative(entity.path, from: exeDir);
        final target = p.join(installDir, relative);
        if (entity is Directory) {
          Directory(target).createSync(recursive: true);
        } else if (entity is File) {
          Directory(p.dirname(target)).createSync(recursive: true);
          entity.copySync(target);
        }
      }

      if (Platform.isWindows) {
        await _createWindowsShortcuts(installDir);
      } else if (Platform.isLinux) {
        await _createLinuxDesktopEntry(installDir);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('MuMuPai installiert in $installDir!')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler: $e'), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _createWindowsShortcuts(String installDir) async {
    try {
      final desktop = Platform.environment['USERPROFILE'] ?? '';
      final startMenu = '${Platform.environment['APPDATA']}\\Microsoft\\Windows\\Start Menu\\Programs';
      final exePath = '$installDir\\mumupai.exe';

      // PowerShell Shortcut-Erstellung
      final script = '''
\$shell = New-Object -ComObject WScript.Shell
\$s1 = \$shell.CreateShortcut("$desktop\\Desktop\\MuMuPai.lnk")
\$s1.TargetPath = "$exePath"
\$s1.WorkingDirectory = "$installDir"
\$s1.Save()
\$s2 = \$shell.CreateShortcut("$startMenu\\MuMuPai.lnk")
\$s2.TargetPath = "$exePath"
\$s2.WorkingDirectory = "$installDir"
\$s2.Save()
''';
      await Process.run('powershell', ['-Command', script]);
    } catch (_) {}
  }

  Future<void> _createLinuxDesktopEntry(String installDir) async {
    try {
      final home = Platform.environment['HOME']!;
      final desktopDir = '$home/.local/share/applications';
      final iconDir = '$home/.local/share/icons/hicolor/512x512/apps';
      final binDir = '$home/.local/bin';
      Directory(desktopDir).createSync(recursive: true);
      Directory(iconDir).createSync(recursive: true);
      Directory(binDir).createSync(recursive: true);

      // Desktop Entry
      await File('$desktopDir/mumupai.desktop').writeAsString(
        '[Desktop Entry]\nName=MuMuPai\nComment=Musik-Player mit Streaming! by Shinpai-AI\n'
        'Exec=$installDir/mumupai --disable-impeller\nIcon=mumupai\n'
        'Terminal=false\nType=Application\nCategories=AudioVideo;Music;Audio;Player;\n');

      // Icon
      final iconSrc = '$installDir/data/flutter_assets/assets/icon.png';
      if (File(iconSrc).existsSync()) File(iconSrc).copySync('$iconDir/mumupai.png');

      // CLI Launcher
      await File('$binDir/mumupai').writeAsString('#!/bin/bash\nexec "$installDir/mumupai" --disable-impeller "\$@"\n');
      await Process.run('chmod', ['+x', '$binDir/mumupai']);

      // Caches
      Process.run('update-desktop-database', [desktopDir]);
      Process.run('gtk-update-icon-cache', ['-f', '-t', '$home/.local/share/icons/hicolor']);
    } catch (_) {}
  }

  @override
  void onWindowClose() async {
    _fullCleanup();
    _trayManager.destroy();
    await windowManager.destroy();
  }

  void _fullCleanup() {
    _stopPlayer();
    _audioPlayer?.dispose();
    _streamServer?.close(force: true);
    _streamServer = null;
    if (!_isAndroid) _globalCleanup();
  }

  @override
  void dispose() {
    if (!_isAndroid) windowManager.removeListener(this);
    _fullCleanup();
    super.dispose();
  }

  void _stopPlayer() {
    if (_isAndroid) {
      _audioPlayer?.stop();
    } else {
      if (_playerProcess != null) {
        _playerProcess!.kill(ProcessSignal.sigkill);
        _playerProcess = null;
      }
    }
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  // === SESSION SAVE/LOAD ===

  Future<void> _saveSession() async {
    try {
      final dir = Directory(_configDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final data = {
        'playlist': playlist, 'playlistName': _playlistName,
        'currentIndex': currentIndex, 'volume': volume,
        'isShuffle': isShuffle, 'isRepeat': isRepeat, 'playlistDir': _playlistDir,
      };
      await File(_sessionPath).writeAsString(json.encode(data));
    } catch (_) {}
  }

  Future<void> _loadSession() async {
    try {
      final file = File(_sessionPath);
      if (!file.existsSync()) return;
      final data = json.decode(await file.readAsString()) as Map<String, dynamic>;
      final savedList = (data['playlist'] as List?)?.cast<String>() ?? [];
      final validFiles = savedList.where((f) => File(f).existsSync()).toList();
      setState(() {
        if (validFiles.isNotEmpty) {
          playlist = validFiles;
          currentIndex = (data['currentIndex'] as int?) ?? -1;
          if (currentIndex >= playlist.length) currentIndex = -1;
        }
        _playlistName = (data['playlistName'] as String?) ?? '';
        volume = (data['volume'] as num?)?.toDouble() ?? 80;
        isShuffle = (data['isShuffle'] as bool?) ?? false;
        isRepeat = (data['isRepeat'] as bool?) ?? false;
        _playlistDir = data['playlistDir'] as String?;
      });
    } catch (_) {}
  }

  // === PLAYLIST MANAGEMENT ===

  String get _effectivePlaylistDir => _playlistDir ?? _defaultPlaylistDir;

  Future<void> _savePlaylist() async {
    if (playlist.isEmpty) return;
    final name = await _askPlaylistName(_playlistName.isEmpty ? null : _playlistName);
    if (name == null || name.isEmpty) return;
    if (_playlistDir == null) {
      final chosenDir = await _askPlaylistDir();
      if (chosenDir == null) return;
      _playlistDir = chosenDir;
    }
    final dir = Directory(_effectivePlaylistDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final safeName = name.replaceAll(RegExp(r'[^\w\s\-äöüÄÖÜß]'), '').trim();
    final filePath = '$_effectivePlaylistDir/$safeName.mpl';
    await File(filePath).writeAsString(json.encode({'name': name, 'songs': playlist}));
    setState(() => _playlistName = name);
    _saveSession();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gespeichert: $name')));
  }

  Future<void> _loadPlaylist() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Playlist laden', initialDirectory: _effectivePlaylistDir,
      type: FileType.custom, allowedExtensions: ['mpl'],
    );
    if (result == null || result.files.isEmpty || result.files.first.path == null) return;
    try {
      final content = await File(result.files.first.path!).readAsString();
      final data = json.decode(content) as Map<String, dynamic>;
      final songs = (data['songs'] as List?)?.cast<String>() ?? [];
      final validSongs = songs.where((f) => File(f).existsSync()).toList();
      if (validSongs.isEmpty) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Keine Songs gefunden!'), backgroundColor: Colors.red));
        return;
      }
      _stopPlayer();
      setState(() {
        playlist = validSongs; currentIndex = -1; isPlaying = false;
        position = Duration.zero; duration = Duration.zero;
        _playlistName = (data['name'] as String?) ?? p.basenameWithoutExtension(result.files.first.path!);
        _playlistDir = p.dirname(result.files.first.path!);
      });
      _saveSession();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Fehler: $e'), backgroundColor: Colors.red));
    }
  }

  Future<String?> _askPlaylistName(String? current) async {
    final controller = TextEditingController(text: current ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Playlist benennen', style: TextStyle(color: fgGreen)),
        content: TextField(
          controller: controller, autofocus: true, style: const TextStyle(color: fgWhite),
          decoration: InputDecoration(
            hintText: 'z.B. Chill Vibes', hintStyle: TextStyle(color: fgGray.withValues(alpha: 0.5)),
            filled: true, fillColor: bgInput,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Abbrechen', style: TextStyle(color: fgGray))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(controller.text.trim()), child: const Text('OK', style: TextStyle(color: fgGreen, fontWeight: FontWeight.bold))),
        ],
      ),
    );
  }

  Future<String?> _askPlaylistDir() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Speicherort', style: TextStyle(color: fgGreen)),
        content: Text('Default: $_defaultPlaylistDir\n\nOder eigenen Ordner wählen.',
            style: const TextStyle(color: fgWhite, fontSize: 13, height: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Abbrechen', style: TextStyle(color: fgGray))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Default', style: TextStyle(color: fgOrange))),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Wählen', style: TextStyle(color: fgGreen, fontWeight: FontWeight.bold))),
        ],
      ),
    );
    if (confirmed == null) return null;
    if (confirmed == false) {
      final dir = Directory(_defaultPlaylistDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return _defaultPlaylistDir;
    }
    return await FilePicker.platform.getDirectoryPath(dialogTitle: 'Playlist-Ordner');
  }

  void _removeSong(int index) {
    if (index < 0 || index >= playlist.length) return;
    setState(() {
      final wasPlaying = index == currentIndex && isPlaying;
      playlist.removeAt(index);
      if (currentIndex == index) {
        _stopPlayer(); isPlaying = false; position = Duration.zero; duration = Duration.zero;
        if (playlist.isNotEmpty) { currentIndex = index < playlist.length ? index : 0; if (wasPlaying) _play(currentIndex); }
        else { currentIndex = -1; }
      } else if (currentIndex > index) { currentIndex--; }
    });
    _saveSession();
  }

  // === PLAYLIST ADD ===

  void _addFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.custom, allowedExtensions: ['mp3', 'wav', 'flac', 'ogg', 'aac', 'm4a', 'wma']);
    if (result != null) {
      setState(() { for (var f in result.files) { if (f.path != null && !playlist.contains(f.path!)) playlist.add(f.path!); } });
      _saveSession();
    }
  }

  void _addFolder() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      final exts = ['.mp3', '.wav', '.flac', '.ogg', '.aac', '.m4a', '.wma'];
      setState(() { for (var f in Directory(result).listSync(recursive: true).whereType<File>()) { if (exts.any((e) => f.path.toLowerCase().endsWith(e)) && !playlist.contains(f.path)) playlist.add(f.path); } });
      _saveSession();
    }
  }

  void _onDrop(DropDoneDetails details) {
    final exts = ['.mp3', '.wav', '.flac', '.ogg', '.aac', '.m4a', '.wma'];
    setState(() {
      for (var file in details.files) {
        final fp = file.path;
        if (FileSystemEntity.isDirectorySync(fp)) {
          for (var f in Directory(fp).listSync(recursive: true).whereType<File>()) { if (exts.any((e) => f.path.toLowerCase().endsWith(e)) && !playlist.contains(f.path)) playlist.add(f.path); }
        } else if (exts.any((e) => fp.toLowerCase().endsWith(e)) && !playlist.contains(fp)) { playlist.add(fp); }
      }
    });
    _saveSession();
  }

  // === PLAYER ===

  Future<void> _play(int index, {int seekSeconds = 0}) async {
    if (index < 0 || index >= playlist.length) return;
    try {
      _stopPlayer();
      final path = playlist[index];
      setState(() { currentIndex = index; isPlaying = true; position = Duration(seconds: seekSeconds); });

      if (_isAndroid) {
        await _playAndroid(path, seekSeconds);
      } else {
        await _playDesktop(path, seekSeconds);
      }
      _saveSession();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Fehler: $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _playAndroid(String path, int seekSeconds) async {
    final player = _audioPlayer!;
    await player.setFilePath(path);
    final dur = player.duration;
    if (dur != null && mounted) setState(() => duration = dur);
    await player.setVolume(volume / 100);
    if (seekSeconds > 0) await player.seek(Duration(seconds: seekSeconds));
    player.play();

    // Position-Updates via Stream
    _positionTimer?.cancel();
    player.positionStream.listen((pos) {
      if (mounted && isPlaying) setState(() => position = pos);
    });
    player.durationStream.listen((dur) {
      if (mounted && dur != null) setState(() => duration = dur);
    });
    player.playerStateStream.listen((state) {
      if (state.processingState == ja.ProcessingState.completed && mounted) {
        setState(() => isPlaying = false);
        _next();
      }
    });
  }

  Future<void> _playDesktop(String path, int seekSeconds) async {
    try {
      final probe = await Process.run(ffprobeBin, ['-v', 'quiet', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', path]);
      final dur = double.tryParse(probe.stdout.toString().trim()) ?? 0;
      if (mounted) setState(() => duration = Duration(milliseconds: (dur * 1000).round()));
    } catch (_) {}

    final args = ['-nodisp', '-autoexit', '-loglevel', 'quiet', '-volume', volume.round().toString()];
    if (seekSeconds > 0) args.addAll(['-ss', seekSeconds.toString()]);
    args.add(path);
    _playerProcess = await Process.start(ffplayBin, args);

    final startTime = DateTime.now();
    final startOffset = seekSeconds;
    _positionTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!isPlaying || !mounted) return;
      final total = Duration(seconds: startOffset) + DateTime.now().difference(startTime);
      setState(() => position = total);
      if (total >= duration && duration.inSeconds > 0) { _stopPlayer(); _next(); }
    });

    _playerProcess!.exitCode.then((code) {
      if (mounted && isPlaying && code == 0) { _stopPlayer(); setState(() => isPlaying = false); _next(); }
    });
  }

  void _togglePlay() {
    if (currentIndex < 0 && playlist.isNotEmpty) { _play(0); }
    else if (isPlaying) {
      if (_isAndroid) { _audioPlayer?.pause(); }
      else { _stopPlayer(); }
      setState(() => isPlaying = false);
    }
    else if (currentIndex >= 0) {
      if (_isAndroid) { _audioPlayer?.play(); setState(() => isPlaying = true); }
      else { _play(currentIndex, seekSeconds: position.inSeconds); }
    }
  }

  void _seekTo(double value) {
    if (duration.inSeconds <= 0 || currentIndex < 0) return;
    if (_isAndroid) {
      final seekPos = Duration(milliseconds: (value * duration.inMilliseconds).round());
      _audioPlayer?.seek(seekPos);
    } else {
      _play(currentIndex, seekSeconds: (value * duration.inSeconds).round());
    }
  }

  void _next() {
    if (playlist.isEmpty) return;
    if (isRepeat) { _play(currentIndex); }
    else if (isShuffle) { _play((currentIndex + 1 + (DateTime.now().millisecond % (playlist.length - 1).clamp(1, 999))) % playlist.length); }
    else { _play((currentIndex + 1) % playlist.length); }
  }

  void _prev() {
    if (playlist.isEmpty) return;
    if (position.inSeconds > 3) { _play(currentIndex); }
    else { _play((currentIndex - 1 + playlist.length) % playlist.length); }
  }

  void _setVolume(double val) {
    setState(() => volume = val);
    if (_isAndroid) {
      _audioPlayer?.setVolume(val / 100);
    } else if (isPlaying && currentIndex >= 0) {
      _play(currentIndex, seekSeconds: position.inSeconds);
    }
    _saveSession();
  }

  // === STREAMING ===

  Future<void> _toggleStreaming() async {
    if (isStreaming) {
      _streamServer?.close(force: true); _streamServer = null;
      setState(() { isStreaming = false; streamUrl = null; _localIP = null; _publicIP = null; _showPublicLink = false; });
    } else {
      try {
        _streamServer = await HttpServer.bind(InternetAddress.anyIPv4, streamPort);
        final ip = await _getLocalIP();
        _localIP = ip;
        setState(() { isStreaming = true; streamUrl = 'http://$ip:$streamPort'; });
        _streamServer!.listen(_handleStreamRequest);
        getPublicIP().then((pubIp) { if (mounted && isStreaming) setState(() => _publicIP = pubIp); });
      } catch (_) {}
    }
  }

  String get _displayUrl {
    if (_showPublicLink && _publicIP != null) return 'http://$_publicIP:$streamPort';
    return streamUrl ?? '';
  }

  Future<String> _getLocalIP() async {
    try {
      for (var iface in await NetworkInterface.list(type: InternetAddressType.IPv4, includeLinkLocal: false)) {
        for (var addr in iface.addresses) { if (!addr.isLoopback) return addr.address; }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  String _buildStreamHTML() {
    final songListJson = playlist.asMap().entries.map((e) {
      final name = p.basenameWithoutExtension(e.value).replaceAll("'", "\\'").replaceAll('"', '\\"');
      return '{"idx":${e.key},"name":"$name"}';
    }).join(',');

    return '''<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>MuMuPai Stream</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;}
body{background:#0a1a0a;color:#e8f0e4;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;min-height:100vh;}
.wrap{max-width:500px;margin:0 auto;padding:16px;}
.head{text-align:center;padding:20px 0 12px;}
.head h1{color:#00c853;font-size:1.6em;margin-bottom:4px;}
.head .sub{color:#7a9a7a;font-size:0.85em;}
.now{background:linear-gradient(135deg,rgba(27,94,32,0.3),#1a2e1a);border-radius:16px;padding:20px;margin:12px 0;text-align:center;}
.now .song{font-size:1.15em;font-weight:bold;color:#e8f0e4;margin-bottom:14px;min-height:1.4em;}
.ctrls{display:flex;align-items:center;justify-content:center;gap:12px;}
.ctrls button{background:none;border:none;color:#e8f0e4;cursor:pointer;padding:10px;border-radius:50%;transition:background 0.2s;display:flex;align-items:center;justify-content:center;}
.ctrls button:hover{background:rgba(0,200,83,0.15);}
.ctrls button svg{width:24px;height:24px;fill:currentColor;}
.ctrls .play-btn{background:#00c853;color:#0a1a0a;width:56px;height:56px;border-radius:50%;}
.ctrls .play-btn svg{width:28px;height:28px;}
.ctrls .play-btn:hover{background:#69f0ae;}
.ctrls .active{color:#00c853;}
.progress{width:100%;margin:12px 0 4px;appearance:none;height:4px;border-radius:2px;background:#243624;outline:none;cursor:pointer;}
.progress::-webkit-slider-thumb{appearance:none;width:14px;height:14px;border-radius:50%;background:#69f0ae;cursor:pointer;}
.progress::-moz-range-thumb{width:14px;height:14px;border-radius:50%;background:#69f0ae;border:none;cursor:pointer;}
.time{display:flex;justify-content:space-between;color:#7a9a7a;font-size:0.75em;padding:0 4px;}
.plist{margin-top:16px;}
.plist .ph{color:#e8724a;font-size:0.75em;font-weight:bold;letter-spacing:1px;padding:8px 0;}
.plist .song-item{display:flex;align-items:center;padding:10px 14px;background:#1a2e1a;border-radius:8px;margin:4px 0;cursor:pointer;transition:background 0.2s;gap:10px;}
.plist .song-item:hover{background:#243624;}
.plist .song-item.active{background:rgba(27,94,32,0.5);border-left:3px solid #00c853;}
.plist .song-item .icon{flex-shrink:0;width:20px;height:20px;}
.plist .song-item .icon svg{width:20px;height:20px;fill:#7a9a7a;}
.plist .song-item.active .icon svg{fill:#00c853;}
.plist .song-item .name{font-size:0.9em;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.foot{text-align:center;color:#7a9a7a;font-size:0.7em;margin-top:24px;padding:12px 0;}
</style></head>
<body><div class="wrap">
<div class="head"><h1>MuMuPai Stream</h1><p class="sub">\${playlist.length} Songs bereit</p></div>
<div class="now">
  <div class="song" id="nowName">Klick einen Song!</div>
  <audio id="audio" preload="none"></audio>
  <input type="range" class="progress" id="progress" min="0" max="1000" value="0">
  <div class="time"><span id="timeCur">0:00</span><span id="timeDur">0:00</span></div>
  <div class="ctrls">
    <button id="btnShuffle" title="Shuffle" onclick="toggleShuffle()"><svg viewBox="0 0 24 24"><path d="M10.59 9.17L5.41 4 4 5.41l5.17 5.17 1.42-1.41zM14.5 4l2.04 2.04L4 18.59 5.41 20 17.96 7.46 20 9.5V4h-5.5zm.33 9.41l-1.41 1.41 3.13 3.13L14.5 20H20v-5.5l-2.04 2.04-3.13-3.13z"/></svg></button>
    <button title="Vorheriger" onclick="prev()"><svg viewBox="0 0 24 24"><path d="M6 6h2v12H6zm3.5 6l8.5 6V6z"/></svg></button>
    <button class="play-btn" id="btnPlay" onclick="togglePlay()"><svg viewBox="0 0 24 24" id="playIcon"><path d="M8 5v14l11-7z"/></svg></button>
    <button title="Naechster" onclick="next()"><svg viewBox="0 0 24 24"><path d="M6 18l8.5-6L6 6v12zM16 6v12h2V6h-2z"/></svg></button>
    <button id="btnRepeat" title="Wiederholen" onclick="toggleRepeat()"><svg viewBox="0 0 24 24"><path d="M7 7h10v3l4-4-4-4v3H5v6h2V7zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2v4z"/></svg></button>
  </div>
</div>
<div class="plist"><div class="ph">PLAYLIST</div><div id="list"></div></div>
<p class="foot">MuMuPai by Shinpai-AI &bull; shinpai.de</p>
</div>
<script>
const songs=[$songListJson];const audio=document.getElementById('audio');const nowName=document.getElementById('nowName');
const progress=document.getElementById('progress');const timeCur=document.getElementById('timeCur');const timeDur=document.getElementById('timeDur');
let cur=-1,shuffle=false,repeat=false;
function fmt(s){const m=Math.floor(s/60);return m+':'+(Math.floor(s%60)+'').padStart(2,'0');}
function render(){document.getElementById('list').innerHTML=songs.map((s,i)=>'<div class="song-item'+(i===cur?' active':'')+'" onclick="playSong('+i+')"><span class="icon"><svg viewBox="0 0 24 24"><path d="'+(i===cur?'M8 5v14l11-7z':'M12 3v10.55A4 4 0 1014 19V7h4V3h-6z')+'"/></svg></span><span class="name">'+s.name+'</span></div>').join('');}
function playSong(i){if(i<0||i>=songs.length)return;cur=i;nowName.textContent=songs[i].name;audio.src='/play/'+songs[i].idx+'/stream';audio.play();render();updatePlayBtn();}
function togglePlay(){if(cur<0&&songs.length>0){playSong(0);return;}if(audio.paused){audio.play();}else{audio.pause();}updatePlayBtn();}
function updatePlayBtn(){document.getElementById('playIcon').innerHTML=audio.paused?'<path d="M8 5v14l11-7z"/>':'<path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/>';}
audio.addEventListener('timeupdate',()=>{if(audio.duration){const pct=(audio.currentTime/audio.duration)*1000;progress.value=pct;progress.style.setProperty('--prog',(pct/10)+'%');timeCur.textContent=fmt(audio.currentTime);timeDur.textContent=fmt(audio.duration);}});
progress.addEventListener('input',()=>{if(audio.duration){audio.currentTime=(progress.value/1000)*audio.duration;}});
function next(){if(!songs.length)return;if(repeat){playSong(cur);return;}if(shuffle){playSong(Math.floor(Math.random()*songs.length));return;}playSong((cur+1)%songs.length);}
function prev(){if(!songs.length)return;if(audio.currentTime>3){audio.currentTime=0;return;}playSong((cur-1+songs.length)%songs.length);}
function toggleShuffle(){shuffle=!shuffle;document.getElementById('btnShuffle').classList.toggle('active',shuffle);}
function toggleRepeat(){repeat=!repeat;document.getElementById('btnRepeat').classList.toggle('active',repeat);}
audio.addEventListener('ended',()=>{next();});audio.addEventListener('play',()=>{updatePlayBtn();});audio.addEventListener('pause',()=>{updatePlayBtn();});
render();
</script></body></html>''';
  }

  Future<void> _handleStreamRequest(HttpRequest request) async {
    try {
      if (request.uri.path == '/') {
        request.response..headers.contentType = ContentType.html..write(_buildStreamHTML());
        await request.response.close();
      } else if (request.uri.path == '/api/info') {
        request.response..headers.contentType = ContentType.json..headers.set('Access-Control-Allow-Origin', '*')..write(json.encode({'app': 'MuMuPai', 'songs': playlist.length}));
        await request.response.close();
      } else if (request.uri.path.startsWith('/play/') && request.uri.path.endsWith('/stream')) {
        final idx = int.tryParse(request.uri.pathSegments[1]) ?? -1;
        if (idx >= 0 && idx < playlist.length) {
          final file = File(playlist[idx]);
          final ext = p.extension(file.path).toLowerCase();
          final mimeTypes = {'.mp3': 'audio/mpeg', '.wav': 'audio/wav', '.flac': 'audio/flac', '.ogg': 'audio/ogg', '.aac': 'audio/aac', '.m4a': 'audio/mp4', '.wma': 'audio/x-ms-wma'};
          final size = await file.length();
          request.response..headers.set('Content-Type', mimeTypes[ext] ?? 'audio/mpeg')..headers.set('Content-Length', '$size')..headers.set('Accept-Ranges', 'bytes');
          await file.openRead().pipe(request.response);
        } else { request.response.statusCode = 404; await request.response.close(); }
      } else { request.response.statusCode = 404; await request.response.close(); }
    } catch (_) {}
  }

  // === HELPERS ===

  String _fmt(Duration d) {
    final min = d.inMinutes;
    final sec = d.inSeconds % 60;
    return '$min:${sec.toString().padLeft(2, '0')}';
  }

  String get _currentSongName =>
      currentIndex >= 0 && currentIndex < playlist.length ? p.basenameWithoutExtension(playlist[currentIndex]) : 'Keine Musik';

  // === UI ===

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GestureDetector(
        onPanStart: _isAndroid ? null : (_) => windowManager.startDragging(),
        child: Column(
          children: [
            // === HEADER BAR ===
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  Text('MuMuPai', style: GoogleFonts.orbitron(fontSize: 11, color: fgGray, fontWeight: FontWeight.w500)),
                  const Spacer(),
                  _tinyBtn(isStreaming ? Icons.wifi : Icons.wifi_off, isStreaming ? fgGreenLight : fgGray, _toggleStreaming),
                  if (!_isAndroid) _tinyBtn(Icons.arrow_downward, fgGray, _minimizeToTray),
                ],
              ),
            ),

            // === LOGO + PLAYER OVAL ===
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(60),
                  gradient: RadialGradient(
                    colors: [fgGreenDark.withValues(alpha: 0.3), bgPlayerOval],
                    radius: 1.0,
                  ),
                  border: Border.all(color: fgGreen.withValues(alpha: isPlaying ? 0.25 : 0.1), width: 1.5),
                  boxShadow: [
                    BoxShadow(color: fgGreenGlow.withValues(alpha: isPlaying ? 0.12 : 0.03), blurRadius: 40, spreadRadius: 4),
                  ],
                ),
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                child: Column(
                  children: [
                    // Logo
                    ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Image.asset('assets/icon.png', width: 56, height: 56)),
                    const SizedBox(height: 4),
                    Text('MuMuPai', style: GoogleFonts.orbitron(fontSize: 20, fontWeight: FontWeight.bold, color: fgGreen,
                      shadows: [Shadow(color: fgGreenGlow.withValues(alpha: 0.4), blurRadius: 12)])),
                    const SizedBox(height: 12),

                    // Song Name
                    Text(_currentSongName,
                        style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600, color: fgWhite),
                        textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 12),

                    // Progress
                    SliderTheme(
                      data: SliderThemeData(
                        activeTrackColor: fgGreen, inactiveTrackColor: bgInput,
                        thumbColor: fgGreenLight,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                        trackHeight: 3, overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                      ),
                      child: Slider(
                        value: duration.inMilliseconds > 0 ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0) : 0,
                        onChanged: _seekTo,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_fmt(position), style: const TextStyle(color: fgGray, fontSize: 11)),
                          Text(_fmt(duration), style: const TextStyle(color: fgGray, fontSize: 11)),
                        ],
                      ),
                    ),

                    // Volume
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          Icon(volume == 0 ? Icons.volume_off : volume < 40 ? Icons.volume_down : Icons.volume_up, color: fgGray, size: 16),
                          Expanded(
                            child: SliderTheme(
                              data: SliderThemeData(
                                activeTrackColor: fgGreen.withValues(alpha: 0.5), inactiveTrackColor: bgInput,
                                thumbColor: fgGreenLight,
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
                                trackHeight: 2, overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                              ),
                              child: Slider(value: volume, min: 0, max: 100, onChanged: (v) => setState(() => volume = v), onChangeEnd: _setVolume),
                            ),
                          ),
                          SizedBox(width: 24, child: Text('${volume.round()}', style: const TextStyle(color: fgGray, fontSize: 10), textAlign: TextAlign.right)),
                        ],
                      ),
                    ),

                    const SizedBox(height: 4),

                    // Controls
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _ctrlBtn(Icons.shuffle, isShuffle ? fgGreen : fgGray, () { setState(() => isShuffle = !isShuffle); _saveSession(); }, 20),
                        const SizedBox(width: 12),
                        _ctrlBtn(Icons.skip_previous, fgWhite, _prev, 28),
                        const SizedBox(width: 8),
                        // Big Play Button
                        GestureDetector(
                          onTap: _togglePlay,
                          child: Container(
                            width: 56, height: 56,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(colors: [fgGreen, fgGreenLight], begin: Alignment.topLeft, end: Alignment.bottomRight),
                              boxShadow: [BoxShadow(color: fgGreenGlow.withValues(alpha: isPlaying ? 0.3 : 0.1), blurRadius: 16, spreadRadius: 2)],
                            ),
                            child: Icon(isPlaying ? Icons.pause : Icons.play_arrow, color: bgDark, size: 32),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _ctrlBtn(Icons.skip_next, fgWhite, _next, 28),
                        const SizedBox(width: 12),
                        _ctrlBtn(Icons.repeat, isRepeat ? fgGreen : fgGray, () { setState(() => isRepeat = !isRepeat); _saveSession(); }, 20),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),

            // === STREAM URL ===
            if (isStreaming && streamUrl != null)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: bgCard, borderRadius: BorderRadius.circular(12)),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(_showPublicLink ? Icons.public : Icons.wifi, color: _showPublicLink ? fgOrange : fgGreenLight, size: 16),
                        const SizedBox(width: 6),
                        Expanded(child: Text(_displayUrl, style: TextStyle(color: _showPublicLink ? fgOrange : fgGreenLight, fontSize: 11, fontFamily: 'monospace'))),
                        InkWell(
                          onTap: () { Clipboard.setData(ClipboardData(text: _displayUrl)); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link kopiert!'))); },
                          child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.copy, size: 14, color: fgGray)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(children: [
                      if (_publicIP != null)
                        InkWell(
                          onTap: () => setState(() => _showPublicLink = !_showPublicLink),
                          child: Text(_showPublicLink ? 'LAN zeigen' : 'Internet zeigen', style: TextStyle(fontSize: 10, color: _showPublicLink ? fgOrange : fgGray)),
                        ),
                      if (_publicIP != null && _showPublicLink) ...[
                        const Spacer(),
                        Text('Port $streamPort → $_localIP', style: const TextStyle(fontSize: 10, color: fgOrange)),
                      ],
                    ]),
                  ],
                ),
              ),

            const SizedBox(height: 4),

            // === PLAYLIST HEADER (aufklappbar) ===
            GestureDetector(
              onTap: () => setState(() => _playlistExpanded = !_playlistExpanded),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: bgCard,
                  borderRadius: _playlistExpanded
                      ? const BorderRadius.vertical(top: Radius.circular(12))
                      : BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(_playlistExpanded ? Icons.expand_less : Icons.expand_more, color: fgOrange, size: 18),
                    const SizedBox(width: 6),
                    Expanded(
                      child: GestureDetector(
                        onTap: () async {
                          final name = await _askPlaylistName(_playlistName.isEmpty ? null : _playlistName);
                          if (name != null && name.isNotEmpty) { setState(() => _playlistName = name); _saveSession(); }
                        },
                        child: Text(
                          _playlistName.isEmpty ? 'PLAYLIST (${playlist.length})' : '$_playlistName (${playlist.length})',
                          style: GoogleFonts.inter(color: fgOrange, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    _miniBtn('📄', _addFiles), const SizedBox(width: 3),
                    _miniBtn('📂', _addFolder), const SizedBox(width: 3),
                    _miniBtn('📥', _savePlaylist), const SizedBox(width: 3),
                    _miniBtn('📤', _loadPlaylist),
                    if (playlist.isNotEmpty) ...[const SizedBox(width: 3),
                      _miniBtn('🗑️', () { _stopPlayer(); setState(() { playlist.clear(); currentIndex = -1; isPlaying = false; position = Duration.zero; duration = Duration.zero; _playlistName = ''; }); _saveSession(); }),
                    ],
                  ],
                ),
              ),
            ),

            // === PLAYLIST (aufklappbar) ===
            if (_playlistExpanded)
              Expanded(
                child: DropTarget(
                  onDragDone: _onDrop,
                  onDragEntered: (_) => setState(() => _isDragging = true),
                  onDragExited: (_) => setState(() => _isDragging = false),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 20),
                    decoration: BoxDecoration(
                      color: bgInput.withValues(alpha: 0.5),
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                      border: Border.all(color: _isDragging ? fgGreen : Colors.transparent, width: 2),
                    ),
                    child: playlist.isEmpty
                        ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Icon(_isDragging ? Icons.file_download : Icons.library_music, color: _isDragging ? fgGreen : fgGray, size: 36),
                            const SizedBox(height: 8),
                            Text(_isDragging ? 'Loslassen!' : 'Musik hierher ziehen', textAlign: TextAlign.center, style: TextStyle(color: _isDragging ? fgGreen : fgGray, fontSize: 12)),
                          ]))
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: playlist.length,
                            itemBuilder: (_, i) => Dismissible(
                              key: ValueKey(playlist[i]),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 16),
                                color: Colors.red.withValues(alpha: 0.3),
                                child: const Icon(Icons.delete, color: Colors.red, size: 18),
                              ),
                              onDismissed: (_) => _removeSong(i),
                              child: InkWell(
                                onTap: () => _play(i),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: i == currentIndex ? fgGreenDark.withValues(alpha: 0.3) : Colors.transparent,
                                    border: i == currentIndex ? const Border(left: BorderSide(color: fgGreen, width: 3)) : null,
                                  ),
                                  child: Row(children: [
                                    Icon(i == currentIndex && isPlaying ? Icons.equalizer : Icons.music_note,
                                        color: i == currentIndex ? fgGreen : fgGray, size: 16),
                                    const SizedBox(width: 10),
                                    Expanded(child: Text(p.basenameWithoutExtension(playlist[i]),
                                        style: TextStyle(fontSize: 12, color: i == currentIndex ? fgGreenLight : fgWhite),
                                        overflow: TextOverflow.ellipsis)),
                                    InkWell(onTap: () => _removeSong(i),
                                      child: Icon(Icons.close, size: 14, color: fgGray.withValues(alpha: 0.4))),
                                  ]),
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            if (!_playlistExpanded) const Spacer(),

            // Footer
            Padding(
              padding: const EdgeInsets.only(bottom: 12, top: 4),
              child: Text('shinpai.de | AGPL-3.0', style: TextStyle(color: fgGray.withValues(alpha: 0.5), fontSize: 9)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ctrlBtn(IconData icon, Color color, VoidCallback onTap, double size) => InkWell(
    onTap: onTap, borderRadius: BorderRadius.circular(20),
    child: Padding(padding: const EdgeInsets.all(6), child: Icon(icon, color: color, size: size)),
  );

  Widget _tinyBtn(IconData icon, Color color, VoidCallback onTap) => InkWell(
    onTap: onTap, borderRadius: BorderRadius.circular(8),
    child: Padding(padding: const EdgeInsets.all(6), child: Icon(icon, color: color, size: 16)),
  );

  Widget _miniBtn(String text, VoidCallback onPressed) => InkWell(
    onTap: onPressed,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bgInput, borderRadius: BorderRadius.circular(4)),
      child: Text(text, style: const TextStyle(fontSize: 12)),
    ),
  );
}
