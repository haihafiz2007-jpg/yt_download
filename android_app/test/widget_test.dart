// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yt_downloader/main.dart';

const _channel = MethodChannel('yt_downloader');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          switch (call.method) {
            case 'getHistory':
              return <Object?>[];
            case 'consumeSharedText':
              return null;
            case 'getQueue':
              return <Object?>[];
            case 'getWifiOnly':
              return false;
            case 'getDarkMode':
              return false;
            case 'getStorageInfo':
              return <String, Object?>{
                'availableBytes': 4 * 1024 * 1024 * 1024,
                'totalBytes': 32 * 1024 * 1024 * 1024,
              };
            case 'requestStoragePermission':
              return true;
            case 'download':
              return <String, Object?>{
                'location': 'Downloads/YT Downloader/test.mp4',
                'sizeBytes': 2048,
              };
            case 'recordHistory':
            case 'saveQueue':
            case 'setWifiOnly':
            case 'setDarkMode':
            case 'clearHistory':
            case 'removeHistoryLocation':
              return null;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  testWidgets('shows downloader options', (WidgetTester tester) async {
    await tester.pumpWidget(const DownloaderApp());

    expect(find.text('xdz_360 yt'), findsOneWidget);
    expect(find.text('Links (one per line)'), findsOneWidget);
    expect(find.text('MP4 video'), findsOneWidget);
    await tester.tap(find.text('MP4 video'));
    await tester.pumpAndSettle();
    expect(find.text('MP3 audio'), findsOneWidget);
    expect(find.text('Add to queue'), findsOneWidget);
    expect(find.byTooltip('Paste link'), findsOneWidget);
    expect(find.text('Download playlist'), findsOneWidget);
  });

  testWidgets('offers official handoff for TeraBox links', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const DownloaderApp());

    await tester.enterText(
      find.byType(TextField),
      'https://www.terabox.com/s/abc123',
    );
    await tester.pump();

    expect(find.text('TeraBox link detected'), findsOneWidget);
    expect(find.text('Open in TeraBox or browser'), findsOneWidget);
    expect(
      find.textContaining('cannot extract TeraBox share links'),
      findsOneWidget,
    );
  });

  testWidgets('downloads a queued link and records it in history', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const DownloaderApp());
    await tester.enterText(
      find.byType(TextField),
      'https://www.youtube.com/watch?v=example',
    );
    await tester.ensureVisible(find.text('Add to queue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();

    expect(find.text('Download complete'), findsOneWidget);
    expect(find.text('www.youtube.com'), findsOneWidget);
    expect(find.text('test.mp4'), findsOneWidget);
  });

  testWidgets('shows the downloader error for a failed link', (
    WidgetTester tester,
  ) async {
    const errorMessage = 'This video is unavailable';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          switch (call.method) {
            case 'getHistory':
            case 'getQueue':
              return <Object?>[];
            case 'consumeSharedText':
              return null;
            case 'getWifiOnly':
            case 'getDarkMode':
              return false;
            case 'getStorageInfo':
              return <String, Object?>{
                'availableBytes': 4 * 1024 * 1024 * 1024,
                'totalBytes': 32 * 1024 * 1024 * 1024,
              };
            case 'requestStoragePermission':
              return true;
            case 'download':
              throw PlatformException(
                code: 'download_failed',
                message: errorMessage,
              );
            case 'recordHistory':
            case 'saveQueue':
              return null;
            default:
              return null;
          }
        });

    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const DownloaderApp());
    await tester.enterText(
      find.byType(TextField).first,
      'https://www.youtube.com/watch?v=example',
    );
    await tester.ensureVisible(find.text('Add to queue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();

    expect(find.textContaining(errorMessage), findsWidgets);
  });
}
