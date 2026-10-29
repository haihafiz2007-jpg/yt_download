import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Developer guide:
// - DownloaderApp contains app-wide themes and the saved light/dark setting.
// - DownloaderPage contains the link form, queue, history, and screen state.
// - MainActivity.kt handles Android-only work such as downloads and file access.
// This is Dart code, so comments use // (a # comment would not compile).
void main() {
  runApp(const DownloaderApp());
}

class DownloaderApp extends StatefulWidget {
  const DownloaderApp({super.key});

  @override
  State<DownloaderApp> createState() => _DownloaderAppState();
}

class _DownloaderAppState extends State<DownloaderApp> {
  // This channel lets Flutter ask Android to store settings and manage files.
  // If you rename this channel, change the matching name in MainActivity.kt too.
  static const _channel = MethodChannel('yt_downloader');
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    // Keep the selected appearance after the app is closed and reopened.
    try {
      final isDark = await _channel.invokeMethod<bool>('getDarkMode') ?? false;
      if (mounted) {
        setState(() => _themeMode = isDark ? ThemeMode.dark : ThemeMode.light);
      }
    } on PlatformException {
      return;
    }
  }

  Future<void> _setDarkMode(bool isDark) async {
    try {
      await _channel.invokeMethod<void>('setDarkMode', {'enabled': isDark});
      if (mounted) {
        setState(() => _themeMode = isDark ? ThemeMode.dark : ThemeMode.light);
      }
    } on PlatformException {
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    // App-wide colors and typography live here; change the themes to restyle
    // the whole app instead of changing each screen widget separately.
    const ink = Color(0xFF20251F);
    const leaf = Color(0xFFBCE96B);

    return MaterialApp(
      title: 'XDZ Download',
      themeMode: _themeMode,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: leaf,
          brightness: Brightness.light,
          surface: const Color(0xFFF4F5EF),
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F5EF),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF4F5EF),
          foregroundColor: ink,
          surfaceTintColor: Colors.transparent,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFD9DDD3)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFD9DDD3)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: ink, width: 1.5),
          ),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: leaf,
          brightness: Brightness.dark,
        ),
      ),
      home: DownloaderPage(
        onThemeChanged: _setDarkMode,
        darkMode: _themeMode == ThemeMode.dark,
      ),
    );
  }
}

class DownloaderPage extends StatefulWidget {
  const DownloaderPage({
    super.key,
    required this.onThemeChanged,
    required this.darkMode,
  });

  final ValueChanged<bool> onThemeChanged;
  final bool darkMode;

  @override
  State<DownloaderPage> createState() => _DownloaderPageState();
}

class _DownloaderPageState extends State<DownloaderPage> {
  // Flutter owns the screen and queue. MainActivity.kt performs native Android
  // work such as downloads and file access through this named method channel.
  static const _channel = MethodChannel('yt_downloader');
  // Keep these values in sync with the format and quality options in the UI
  // and with the format selection handled by MainActivity.kt.
  static const _qualities = ['best', '1080p', '720p', '480p', '360p'];
  // Add a new output format here, then implement the same value in
  // MainActivity.kt before exposing it in the format menu below.
  static const _fileTypes = ['mp4', 'mp3', 'm4a', 'original'];
  final _urlController = TextEditingController();
  final _subtitleLanguageController = TextEditingController(text: 'en');
  String _fileType = 'mp4';
  String _quality = 'best';
  // These choices are saved into each queue item so changing the form later
  // won't unexpectedly change downloads that are already waiting.
  bool _playlist = false;
  bool _subtitles = false;
  String _status = 'Ready';
  String? _savedLocation;
  double? _progress;
  String? _downloadSpeed;
  int? _etaSeconds;
  bool _isDownloading = false;
  bool _wifiOnly = false;
  int? _availableStorageBytes;
  bool _isProcessingQueue = false;
  bool _stopQueue = false;
  String _historyQuery = '';
  String _historyStatus = 'All';
  String? _activeJobId;
  final List<Map<String, dynamic>> _queue = [];
  List<Map<String, dynamic>> _history = [];

  // TeraBox share pages are handed to the official app/browser; they are not
  // sent to the downloader because the bundled extractor does not support them.
  bool get _isTeraBoxLink {
    final uri = Uri.tryParse(_urlController.text.trim());
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return [
      'terabox.com',
      '1024terabox.com',
      'teraboxapp.com',
    ].any((domain) => host == domain || host.endsWith('.$domain'));
  }

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_handleNativeCall);
    _loadHistory();
    _loadQueue();
    _loadDeviceSettings();
    _loadSharedLink();
  }

  Future<void> _loadSharedLink() async {
    try {
      final sharedText = await _channel.invokeMethod<String>(
        'consumeSharedText',
      );
      if (!mounted || sharedText == null || sharedText.trim().isEmpty) return;
      _urlController.text = sharedText.trim();
      setState(() => _status = 'Link received from another app.');
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _status = 'Could not receive shared link: ${error.message}',
        );
      }
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _subtitleLanguageController.dispose();
    super.dispose();
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    // Android sends progress and shared-link events back to Flutter here.
    // Keep event names in sync with the channel callbacks in MainActivity.kt.
    if (!mounted) return;
    if (call.method == 'status') {
      setState(() => _status = call.arguments as String);
      return;
    }
    if (call.method == 'sharedLink') {
      final sharedText = call.arguments as String?;
      if (sharedText != null && sharedText.trim().isNotEmpty) {
        _urlController.text = sharedText.trim();
        setState(() => _status = 'Link received from another app.');
      }
      return;
    }
    if (call.method != 'progress') return;
    final values = Map<Object?, Object?>.from(call.arguments as Map);
    setState(() {
      final percent = (values['progress'] as num?)?.toDouble() ?? 0;
      _progress = (percent / 100).clamp(0.0, 1.0).toDouble();
      final eta = (values['eta'] as num?)?.toInt() ?? 0;
      _etaSeconds = eta > 0 ? eta : null;
      _downloadSpeed = values['speed'] as String?;
      _status = 'Downloading · ${percent.toStringAsFixed(1)}%';
    });
  }

  Future<void> _loadDeviceSettings() async {
    // These values come from Android's private preferences and storage API.
    try {
      final values = await Future.wait<Object?>([
        _channel.invokeMethod<bool>('getWifiOnly'),
        _channel.invokeMethod<Map<Object?, Object?>>('getStorageInfo'),
      ]);
      if (!mounted) return;
      final storage = values[1] as Map<Object?, Object?>?;
      setState(() {
        _wifiOnly = values[0] as bool? ?? false;
        _availableStorageBytes = (storage?['availableBytes'] as num?)?.toInt();
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _status = 'Could not load settings: ${error.message}');
      }
    }
  }

  Future<void> _setWifiOnly(bool value) async {
    try {
      await _channel.invokeMethod<void>('setWifiOnly', {'enabled': value});
      if (mounted) setState(() => _wifiOnly = value);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _status = 'Could not update Wi-Fi setting: ${error.message}',
        );
      }
    }
  }

  Future<void> _loadHistory() async {
    try {
      final entries = await _channel.invokeListMethod<Object?>('getHistory');
      if (!mounted || entries == null) return;
      setState(() {
        _history = entries
            .whereType<Map<Object?, Object?>>()
            .map(
              (entry) =>
                  entry.map((key, value) => MapEntry(key.toString(), value)),
            )
            .toList();
      });
    } on MissingPluginException {
      return;
    } on PlatformException {
      if (mounted) setState(() => _status = 'Could not load download history.');
    }
  }

  Future<void> _recordHistory(Map<String, dynamic> entry) async {
    await _channel.invokeMethod<void>('recordHistory', entry);
    if (!mounted) return;
    setState(() {
      _history = [entry, ..._history].take(100).toList();
    });
  }

  Future<void> _loadQueue() async {
    // Restore waiting jobs after the app is reopened. A job that was running
    // when Android stopped the app is put back in the waiting state.
    try {
      final entries = await _channel.invokeListMethod<Object?>('getQueue');
      if (!mounted || entries == null) return;
      setState(() {
        _queue
          ..clear()
          ..addAll(
            entries.whereType<Map<Object?, Object?>>().map(
              (entry) =>
                  entry.map((key, value) => MapEntry(key.toString(), value)),
            ),
          );
        for (final job in _queue) {
          if (job['status'] == 'Downloading') job['status'] = 'Queued';
        }
      });
      await _persistQueue();
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _status = 'Could not restore queue: ${error.message}');
      }
    }
  }

  Future<void> _persistQueue() async {
    try {
      await _channel.invokeMethod<void>('saveQueue', _queue);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _status = 'Could not save queue: ${error.message}');
      }
    }
  }

  Future<void> _removeQueuedJob(String id) async {
    setState(() => _queue.removeWhere((job) => job['id'] == id));
    await _persistQueue();
  }

  Future<void> _retryJob(String id) async {
    setState(() {
      final job = _queue.firstWhere((entry) => entry['id'] == id);
      job['status'] = 'Queued';
      job.remove('error');
    });
    await _persistQueue();
    unawaited(_processQueue());
  }

  Future<void> _moveJob(String id, int offset) async {
    final index = _queue.indexWhere((job) => job['id'] == id);
    final target = index + offset;
    if (index < 0 ||
        target < 0 ||
        target >= _queue.length ||
        _queue[index]['status'] != 'Queued' ||
        _queue[target]['status'] != 'Queued') {
      return;
    }
    setState(() {
      final job = _queue.removeAt(index);
      _queue.insert(target, job);
    });
    await _persistQueue();
  }

  Future<void> _pasteLink() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboard?.text?.trim();
    if (text == null || text.isEmpty) {
      setState(() => _status = 'Clipboard is empty.');
      return;
    }
    _urlController.text = text;
    setState(() => _status = 'Link pasted. Add it to the queue when ready.');
  }

  Future<void> _addToQueue() async {
    // One link per line is supported, so several links can be queued together.
    // Queue fields below are also read by _processQueue and passed to Kotlin.
    // When adding a per-download setting, store it on every job here, then
    // pass it in _processQueue and read it in MainActivity.kt.
    final urls = _urlController.text
        .split(RegExp(r'[\r\n]+'))
        .map((url) => url.trim())
        .where((url) => url.isNotEmpty)
        .toList();
    if (urls.isEmpty) {
      setState(() => _status = 'Paste or enter one or more links.');
      return;
    }
    final parsedUris = urls.map(Uri.tryParse).toList();
    if (parsedUris.any(
      (uri) =>
          uri == null ||
          !{'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty,
    )) {
      setState(() => _status = 'Enter a valid video or audio URL.');
      return;
    }
    final acceptedUris = parsedUris.whereType<Uri>().toList();
    if (acceptedUris.any(_isSupportedTeraBoxUri)) {
      setState(
        () => _status = 'Open TeraBox links in the official app or browser.',
      );
      return;
    }

    try {
      final hasStorageAccess =
          await _channel.invokeMethod<bool>('requestStoragePermission') ??
          false;
      if (!hasStorageAccess) {
        setState(() => _status = 'Storage permission is needed to save files.');
        return;
      }

      setState(() {
        for (final uri in acceptedUris) {
          _queue.add({
            'id': '${DateTime.now().microsecondsSinceEpoch}-${_queue.length}',
            'url': uri.toString(),
            'fileType': _fileType,
            'quality': _quality,
            'playlist': _playlist,
            'subtitles': _subtitles,
            'subtitleLanguage': _subtitleLanguageController.text.trim(),
            'status': 'Queued',
          });
        }
        _status =
            'Added ${acceptedUris.length} link${acceptedUris.length == 1 ? '' : 's'} to queue.';
      });
      await _persistQueue();
      unawaited(_processQueue());
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Could not prepare download: $error');
    }
  }

  bool _isSupportedTeraBoxUri(Uri uri) {
    final host = uri.host.toLowerCase();
    return [
      'terabox.com',
      '1024terabox.com',
      'teraboxapp.com',
    ].any((domain) => host == domain || host.endsWith('.$domain'));
  }

  Future<void> _processQueue() async {
    // Process only one job at a time. This avoids competing downloads on a phone.
    // The job's status is saved before and after each attempt so an interrupted
    // item can be shown as waiting again when the app is reopened.
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;
    _stopQueue = false;
    while (mounted && !_stopQueue) {
      final pendingIndex = _queue.indexWhere(
        (job) => job['status'] == 'Queued',
      );
      if (pendingIndex < 0) break;
      final job = _queue[pendingIndex];
      final id = job['id'] as String;
      setState(() {
        _activeJobId = id;
        _isDownloading = true;
        _progress = 0;
        _downloadSpeed = null;
        _etaSeconds = null;
        _savedLocation = null;
        _status = 'Starting download';
        job['status'] = 'Downloading';
      });
      await _persistQueue();

      String status;
      String? location;
      String? errorMessage;
      Map<String, Object?>? downloadDetails;
      try {
        // This map is the Flutter-to-Android download request. Its keys must
        // match the arguments read in MainActivity.kt's "download" handler.
        final downloadResult = await _channel
            .invokeMapMethod<String, Object?>('download', {
              'url': job['url'],
              'fileType': job['fileType'],
              'quality': job['quality'],
              'playlist': job['playlist'],
              'subtitles': job['subtitles'],
              'subtitleLanguage': job['subtitleLanguage'],
            });
        downloadDetails = downloadResult;
        location = downloadResult?['location'] as String?;
        if (location == null) {
          throw PlatformException(
            code: 'missing_location',
            message: 'Download completed without a saved file location.',
          );
        }
        status = 'Complete';
      } on PlatformException catch (error) {
        errorMessage = error.message ?? 'Download failed.';
        status = _stopQueue ? 'Cancelled' : 'Failed';
      } catch (error) {
        errorMessage = 'Download failed: $error';
        status = _stopQueue ? 'Cancelled' : 'Failed';
      }

      final historyEntry = <String, dynamic>{
        // Keep history keys consistent with MainActivity.kt's saved JSON and
        // _buildHistorySection, which uses these values to display each file.
        'url': job['url'],
        'fileType': job['fileType'],
        'location': location ?? '',
        'status': status,
        'message': errorMessage ?? '',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        if (downloadDetails?['sizeBytes'] is num)
          'sizeBytes': downloadDetails!['sizeBytes'],
      };
      try {
        await _recordHistory(historyEntry);
      } on PlatformException catch (error) {
        errorMessage =
            'Download $status, but history could not be saved: ${error.message}';
      } catch (error) {
        errorMessage =
            'Download $status, but history could not be saved: $error';
      }
      final files = downloadDetails?['files'];
      if (files is List) {
        for (final item in files.whereType<Map>()) {
          final fileLocation = item['location'] as String?;
          if (fileLocation == null || fileLocation == location) continue;
          final fileHistory = Map<String, dynamic>.from(historyEntry)
            ..['location'] = fileLocation;
          if (item['sizeBytes'] is num) {
            fileHistory['sizeBytes'] = item['sizeBytes'];
          }
          try {
            await _recordHistory(fileHistory);
          } on PlatformException catch (error) {
            errorMessage =
                'Download complete, but some history could not be saved: ${error.message}';
          }
        }
      }
      if (!mounted) return;
      setState(() {
        job['status'] = status;
        job['location'] = location;
        job['error'] = errorMessage;
        _savedLocation = location;
        _progress = status == 'Complete' ? 1 : null;
        _downloadSpeed = null;
        _etaSeconds = null;
        _status =
            errorMessage ??
            (status == 'Complete' ? 'Download complete' : 'Download $status.');
        _isDownloading = false;
        _activeJobId = null;
      });
      await _persistQueue();
    }
    if (mounted) {
      setState(() {
        _isProcessingQueue = false;
        _isDownloading = false;
        _activeJobId = null;
      });
    } else {
      _isProcessingQueue = false;
    }
  }

  Future<void> _cancelDownload() async {
    _stopQueue = true;
    await _channel.invokeMethod<void>('cancelDownload');
    if (!mounted) return;
    setState(() => _status = 'Stopping download');
  }

  Future<void> _clearHistory() async {
    try {
      await _channel.invokeMethod<void>('clearHistory');
      if (!mounted) return;
      setState(() => _history.clear());
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _status = 'Could not clear history: ${error.message}');
      }
    }
  }

  Future<void> _performFileAction(String action, String location) async {
    // Kotlin checks the file location and uses Android's MediaStore/chooser APIs.
    // The action string must be one of the methods registered in MainActivity.kt.
    try {
      await _channel.invokeMethod<void>(action, {'location': location});
      if (action == 'deleteFile' && mounted) {
        setState(
          () => _history.removeWhere((entry) => entry['location'] == location),
        );
        await _channel.invokeMethod<void>('removeHistoryLocation', {
          'location': location,
        });
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _status = error.message ?? 'File action failed.');
      }
    }
  }

  Future<void> _openTeraBoxLink() async {
    try {
      await _channel.invokeMethod<void>('openLink', {
        'url': _urlController.text.trim(),
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _status = error.message ?? 'Could not open this link.');
    }
  }

  @override
  Widget build(BuildContext context) {
    // The page is intentionally built from smaller methods at the bottom:
    // _buildQueueSection and _buildHistorySection handle their own lists.
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            CircleAvatar(
              radius: 17,
              backgroundColor: Color(0xFFBCE96B),
              child: Text('🤪', style: TextStyle(fontSize: 19)),
            ),
            SizedBox(width: 10),
            Text('XDZ Download'),
          ],
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF20251F), Color(0xFF46533B)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x2220251F),
                      blurRadius: 18,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    const CircleAvatar(
                      radius: 28,
                      backgroundColor: Color(0xFFBCE96B),
                      child: Text('🤪', style: TextStyle(fontSize: 28)),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'YOUR MEDIA, READY',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: const Color(0xFFBCE96B),
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.2,
                                ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            'Paste a supported link',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _urlController,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.done,
                      autocorrect: false,
                      enableSuggestions: false,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Links (one per line)',
                        hintText: 'https://example.com/media',
                        prefixIcon: Icon(Icons.link_rounded),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Paste link',
                    onPressed: _pasteLink,
                    icon: const Icon(Icons.content_paste_rounded),
                    style: IconButton.styleFrom(
                      minimumSize: const Size(54, 54),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ],
              ),
              if (_isTeraBoxLink) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF2DE),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'TeraBox link detected',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Open it in TeraBox to access or download the file. XDZ Download cannot extract TeraBox share links.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _openTeraBoxLink,
                        icon: const Icon(Icons.open_in_new_rounded),
                        label: const Text('Open in TeraBox or browser'),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'Works with supported sites. Some links require their official app or website.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: const Color(0xFF697064)),
              ),
              const SizedBox(height: 22),
              Text('File type', style: Theme.of(context).textTheme.titleSmall),
              // The selected format, quality, playlist and subtitle controls
              // below become fields on each new queue item.
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _fileType,
                decoration: const InputDecoration(
                  labelText: 'Output format',
                  prefixIcon: Icon(Icons.perm_media_outlined),
                ),
                items: _fileTypes
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(switch (value) {
                          'mp4' => 'MP4 video',
                          'mp3' => 'MP3 audio',
                          'm4a' => 'M4A audio',
                          _ => 'Original format',
                        }),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) setState(() => _fileType = value);
                },
              ),
              if (_fileType == 'mp4') ...[
                const SizedBox(height: 22),
                Text(
                  'Video quality',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _quality,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.high_quality_outlined),
                  ),
                  items: _qualities
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(
                            value == 'best' ? 'Best available' : value,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: _isDownloading
                      ? null
                      : (value) {
                          if (value != null) setState(() => _quality = value);
                        },
                ),
              ],
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilterChip(
                    label: const Text('Download playlist'),
                    selected: _playlist,
                    onSelected: (value) => setState(() => _playlist = value),
                  ),
                  FilterChip(
                    label: const Text('Download subtitles'),
                    selected: _subtitles,
                    onSelected: (value) => setState(() => _subtitles = value),
                  ),
                ],
              ),
              if (_subtitles) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _subtitleLanguageController,
                  decoration: const InputDecoration(
                    labelText: 'Subtitle languages',
                    hintText: 'en,es',
                    prefixIcon: Icon(Icons.subtitles_outlined),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Dark theme'),
                value: widget.darkMode,
                onChanged: widget.onThemeChanged,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Download only on Wi-Fi'),
                subtitle: Text(
                  _availableStorageBytes == null
                      ? 'Available storage unknown'
                      : '${_formatBytes(_availableStorageBytes!)} available',
                ),
                value: _wifiOnly,
                onChanged: _setWifiOnly,
              ),
              if (_availableStorageBytes != null &&
                  _availableStorageBytes! < 500 * 1024 * 1024)
                Text(
                  'Low storage: less than 500 MB is available.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: _addToQueue,
                  icon: const Icon(Icons.playlist_add_rounded),
                  label: const Text('Add to queue'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF20251F),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
              if (_isDownloading) ...[
                const SizedBox(height: 8),
                Center(
                  child: TextButton.icon(
                    onPressed: _cancelDownload,
                    icon: const Icon(Icons.close_rounded),
                    label: const Text('Cancel current download'),
                  ),
                ),
              ],
              if (!_isProcessingQueue &&
                  _queue.any((job) => job['status'] == 'Queued')) ...[
                const SizedBox(height: 8),
                Center(
                  child: TextButton.icon(
                    onPressed: () => unawaited(_processQueue()),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Resume queue'),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              if (_progress != null) ...[
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 10),
              ],
              if (_isDownloading)
                Text(
                  [
                    if (_progress != null)
                      '${(_progress! * 100).toStringAsFixed(1)}%',
                    if (_downloadSpeed != null && _downloadSpeed!.isNotEmpty)
                      _downloadSpeed!,
                    if (_etaSeconds != null) 'about ${_etaSeconds}s left',
                  ].join(' · '),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF697064),
                  ),
                ),
              Text(
                _status,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF3E473B),
                ),
              ),
              if (_savedLocation != null) ...[
                const SizedBox(height: 4),
                Text(
                  _savedLocation!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF697064),
                  ),
                ),
              ],
              const SizedBox(height: 28),
              _buildQueueSection(context),
              const SizedBox(height: 24),
              _buildHistorySection(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQueueSection(BuildContext context) {
    // Queue actions change local job data first, then save it with _persistQueue.
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Download queue', style: theme.textTheme.titleMedium),
            const SizedBox(width: 8),
            if (_queue.isNotEmpty)
              Chip(
                label: Text(
                  '${_queue.where((job) => job['status'] == 'Queued').length} waiting',
                ),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
        if (_queue.isEmpty)
          Text(
            'Links you add will appear here.',
            style: theme.textTheme.bodySmall,
          )
        else
          ..._queue.asMap().entries.take(20).map((queueEntry) {
            final index = queueEntry.key;
            final job = queueEntry.value;
            final id = job['id'] as String;
            final active = id == _activeJobId;
            return Card(
              margin: const EdgeInsets.only(top: 6),
              child: ListTile(
                dense: true,
                leading: Icon(
                  active
                      ? Icons.downloading_rounded
                      : job['status'] == 'Complete'
                      ? Icons.check_circle_outline_rounded
                      : job['status'] == 'Failed' ||
                            job['status'] == 'Cancelled'
                      ? Icons.error_outline_rounded
                      : Icons.schedule_rounded,
                ),
                title: Text(
                  Uri.tryParse(job['url'] as String)?.host ??
                      job['url'] as String,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${job['fileType']} · ${job['status']}'),
                trailing: PopupMenuButton<String>(
                  enabled: !active,
                  onSelected: (action) {
                    if (action == 'retry') unawaited(_retryJob(id));
                    if (action == 'remove') unawaited(_removeQueuedJob(id));
                    if (action == 'up') unawaited(_moveJob(id, -1));
                    if (action == 'down') unawaited(_moveJob(id, 1));
                  },
                  itemBuilder: (context) => [
                    if (job['status'] == 'Queued') ...[
                      if (index > 0 && _queue[index - 1]['status'] == 'Queued')
                        const PopupMenuItem(
                          value: 'up',
                          child: Text('Move up'),
                        ),
                      if (index + 1 < _queue.length &&
                          _queue[index + 1]['status'] == 'Queued')
                        const PopupMenuItem(
                          value: 'down',
                          child: Text('Move down'),
                        ),
                    ],
                    if (job['status'] == 'Failed' ||
                        job['status'] == 'Cancelled')
                      const PopupMenuItem(value: 'retry', child: Text('Retry')),
                    const PopupMenuItem(value: 'remove', child: Text('Remove')),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _buildHistorySection(BuildContext context) {
    // Show only matching history entries, then offer actions for saved files.
    final theme = Theme.of(context);
    final visibleHistory = _history.where((entry) {
      final url = entry['url'] as String? ?? '';
      final location = entry['location'] as String? ?? '';
      final matchesQuery =
          _historyQuery.isEmpty ||
          url.toLowerCase().contains(_historyQuery.toLowerCase()) ||
          location.toLowerCase().contains(_historyQuery.toLowerCase());
      final matchesStatus =
          _historyStatus == 'All' || entry['status'] == _historyStatus;
      return matchesQuery && matchesStatus;
    }).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Download history',
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (_history.isNotEmpty)
              TextButton(onPressed: _clearHistory, child: const Text('Clear')),
          ],
        ),
        if (_history.isNotEmpty) ...[
          TextField(
            decoration: const InputDecoration(
              hintText: 'Search downloads',
              prefixIcon: Icon(Icons.search_rounded),
              isDense: true,
            ),
            onChanged: (value) => setState(() => _historyQuery = value),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'All', label: Text('All')),
              ButtonSegment(value: 'Complete', label: Text('Complete')),
              ButtonSegment(value: 'Failed', label: Text('Failed')),
            ],
            selected: {_historyStatus},
            onSelectionChanged: (selection) =>
                setState(() => _historyStatus = selection.first),
          ),
        ],
        if (_history.isEmpty)
          Text(
            'Completed downloads will be saved here.',
            style: theme.textTheme.bodySmall,
          )
        else
          ...visibleHistory.take(20).map((entry) {
            final location = entry['location'] as String? ?? '';
            final url = entry['url'] as String? ?? '';
            final timestamp = entry['timestamp'] as num?;
            final sizeBytes = entry['sizeBytes'] as num?;
            final date = timestamp == null
                ? ''
                : DateTime.fromMillisecondsSinceEpoch(
                    timestamp.toInt(),
                  ).toLocal().toString().substring(0, 16);
            return Card(
              margin: const EdgeInsets.only(top: 6),
              child: ListTile(
                dense: true,
                leading: Icon(
                  entry['status'] == 'Complete'
                      ? Icons.check_circle_outline_rounded
                      : Icons.error_outline_rounded,
                ),
                title: Text(
                  location.isNotEmpty
                      ? location.split(RegExp(r'[/\\]')).last
                      : Uri.tryParse(url)?.host ?? url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${entry['fileType'] ?? ''} · ${entry['status'] ?? 'Unknown'}${sizeBytes == null ? '' : ' · ${_formatBytes(sizeBytes.toInt())}'}${date.isEmpty ? '' : ' · $date'}',
                  maxLines: 2,
                ),
                trailing: location.isEmpty
                    ? null
                    : PopupMenuButton<String>(
                        onSelected: (action) =>
                            unawaited(_performFileAction(action, location)),
                        itemBuilder: (context) => const [
                          PopupMenuItem(value: 'openFile', child: Text('Open')),
                          PopupMenuItem(
                            value: 'shareFile',
                            child: Text('Share'),
                          ),
                          PopupMenuItem(
                            value: 'deleteFile',
                            child: Text('Delete file'),
                          ),
                        ],
                      ),
              ),
            );
          }),
      ],
    );
  }

  String _formatBytes(int bytes) {
    // Convert raw byte counts into a size that is easier to read in the UI.
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(1)} ${units[unit]}';
  }
}
