import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:roomcast_fm/main.dart';
import 'package:roomcast_fm/providers/devices_provider.dart';
import 'package:roomcast_fm/providers/service_provider.dart';
import 'package:roomcast_fm/screens/connect_screen.dart';
import 'package:roomcast_fm/services/api_client.dart';

class _ReplaceCounter extends NavigatorObserver {
  int replacements = 0;

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => replacements++;
}

class _FakeApi extends RoomcastApiClient {
  _FakeApi(super.baseUrl, {required this.reachable, this.gate});
  final bool reachable;
  final Future<void>? gate; // getInfo waits for it (a slow backend)
  bool disposed = false;

  @override
  Future<Map<String, dynamic>> getInfo() async {
    if (gate != null) await gate;
    if (!reachable) throw ApiException('Network error: unreachable');
    return {'version': '1.0'};
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

void main() {
  testWidgets('launches, auto-scans, and offers manual entry when nothing is found',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    var scans = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serviceFinderProvider.overrideWithValue(() async {
            scans++;
            return null;
          }),
        ],
        child: const RoomcastApp(),
      ),
    );
    // Launcher shows a loading indicator while checking saved service URL
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpAndSettle();
    expect(scans, 1, reason: 'ConnectScreen scans automatically on first show');
    expect(find.text('No Roomcast FM service found on this network.'), findsOneWidget);
    expect(find.text('Find Service Automatically'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('manual entry stays available while a scan is running', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final scan = Completer<String?>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [serviceFinderProvider.overrideWithValue(() => scan.future)],
        child: const RoomcastApp(),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Searching for Roomcast FM on your network…'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    scan.complete(null);
    await tester.pumpAndSettle();
  });

  test('a failed connect disposes its client; a new connection disposes the old one', () async {
    SharedPreferences.setMockInitialValues({});
    final made = <_FakeApi>[];
    final notifier = ServiceNotifier(
      () async => null,
      clientFactory: (url) {
        final c = _FakeApi(url, reachable: !url.contains('bad'));
        made.add(c);
        return c;
      },
    );
    await notifier.connectTo('http://bad:8888');
    expect(made.single.disposed, isTrue, reason: 'failed attempt closed');
    await notifier.connectTo('http://good1:8888');
    await notifier.connectTo('http://good2:8888');
    expect(made[1].disposed, isTrue, reason: 'replaced connection closed');
    expect(made[2].disposed, isFalse, reason: 'current connection kept');
    notifier.dispose();
  });

  test('a manual connect made during a scan wins over the scan result', () async {
    SharedPreferences.setMockInitialValues({});
    final scan = Completer<String?>();
    final made = <_FakeApi>[];
    final notifier = ServiceNotifier(() => scan.future, clientFactory: (url) {
      final c = _FakeApi(url, reachable: true);
      made.add(c);
      return c;
    });
    final scanning = notifier.scanAndConnect();
    await notifier.connectTo('http://manual:8888');
    expect(notifier.state.baseUrl, 'http://manual:8888');
    scan.complete('http://scanned:8888');
    await scanning;
    expect(notifier.state.isConnected, isTrue);
    expect(notifier.state.baseUrl, 'http://manual:8888', reason: 'scan result dropped');
    expect(made.map((c) => c.baseUrl), ['http://manual:8888'], reason: 'no client for the stale result');
    notifier.dispose();
  });

  test('a scan that finds nothing does not drop a manual connection', () async {
    SharedPreferences.setMockInitialValues({});
    final scan = Completer<String?>();
    final notifier = ServiceNotifier(() => scan.future,
        clientFactory: (url) => _FakeApi(url, reachable: true));
    final scanning = notifier.scanAndConnect();
    await notifier.connectTo('http://manual:8888');
    scan.complete(null);
    await scanning;
    expect(notifier.state.isConnected, isTrue);
    notifier.dispose();
  });

  test('a failed connect keeps the working connection', () async {
    SharedPreferences.setMockInitialValues({});
    final made = <_FakeApi>[];
    final notifier = ServiceNotifier(() async => null, clientFactory: (url) {
      final c = _FakeApi(url, reachable: !url.contains('bad'));
      made.add(c);
      return c;
    });
    await notifier.connectTo('http://good:8888');
    await notifier.connectTo('http://bad:8888');
    expect(notifier.state.isConnected, isTrue);
    expect(notifier.state.baseUrl, 'http://good:8888');
    expect(made.first.disposed, isFalse, reason: 'working client kept open');
    expect(made.last.disposed, isTrue);
    notifier.dispose();
  });

  testWidgets('two quick successful connects open the home screen once', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final observer = _ReplaceCounter();
    late ServiceNotifier notifier;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serviceProvider.overrideWith((ref) {
            return notifier = ServiceNotifier(() => Completer<String?>().future,
                clientFactory: (url) => _FakeApi(url, reachable: true));
          }),
        ],
        child: MaterialApp(
          navigatorObservers: [observer],
          home: const ConnectScreen(autoScan: false),
        ),
      ),
    );
    await notifier.connectTo('http://a:8888');
    await notifier.connectTo('http://b:8888'); // connected → connected
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(observer.replacements, 1);
  });

  test('a failed manual connect does not cancel a scan that then finds the service', () async {
    SharedPreferences.setMockInitialValues({});
    final scan = Completer<String?>();
    final notifier = ServiceNotifier(() => scan.future,
        clientFactory: (url) => _FakeApi(url, reachable: !url.contains('typo')));
    final scanning = notifier.scanAndConnect();
    await notifier.connectTo('http://typo:8888');
    expect(notifier.state.status.name, 'scanning', reason: 'scan still running');
    scan.complete('http://192.168.1.20:8888');
    await scanning;
    expect(notifier.state.isConnected, isTrue);
    expect(notifier.state.baseUrl, 'http://192.168.1.20:8888');
    notifier.dispose();
  });

  test('a scan cancelled by disconnect does not hide a later connect failure', () async {
    SharedPreferences.setMockInitialValues({});
    final scan = Completer<String?>();
    final notifier = ServiceNotifier(() => scan.future,
        clientFactory: (url) => _FakeApi(url, reachable: !url.contains('typo')));
    final scanning = notifier.scanAndConnect();
    await notifier.disconnect();
    await notifier.connectTo('http://typo:8888');
    expect(notifier.state.status.name, 'error',
        reason: 'the cancelled scan can no longer connect, so no spinner');
    scan.complete('http://192.168.1.20:8888');
    await scanning;
    expect(notifier.state.status.name, 'error');
    notifier.dispose();
  });

  test('a failed attempt while connected leaves the state untouched', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = ServiceNotifier(() async => null,
        clientFactory: (url) => _FakeApi(url, reachable: !url.contains('typo')));
    await notifier.connectTo('http://192.168.1.20:8888');
    final connected = notifier.state;
    await notifier.connectTo('http://typo:8888');
    await notifier.scanAndConnect(); // finds nothing
    expect(identical(notifier.state, connected), isTrue,
        reason: 'a new state object would rebuild the device list (and drop pending changes)');
    notifier.dispose();
  });

  testWidgets('a failed manual connect during a scan shows its error', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final scan = Completer<String?>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serviceFinderProvider.overrideWithValue(() => scan.future),
          apiClientFactoryProvider.overrideWithValue(
              (url) => _FakeApi(url, reachable: !url.contains('typo'))),
        ],
        child: const RoomcastApp(),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'typo:8888');
    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(find.text('Searching for Roomcast FM on your network…'), findsOneWidget);
    expect(find.textContaining('Could not reach service at http://typo:8888'), findsOneWidget);
    scan.complete(null);
    await tester.pumpAndSettle();
    expect(find.textContaining('No Roomcast FM service found on this network.'), findsOneWidget);
    expect(find.textContaining('Could not reach service at http://typo:8888'), findsOneWidget);
  });

  test('disposing the notifier closes the live connection', () async {
    SharedPreferences.setMockInitialValues({});
    final clients = <_FakeApi>[];
    final notifier = ServiceNotifier(() async => null,
        clientFactory: (url) => _FakeApi(url, reachable: true)..let(clients.add));
    await notifier.connectTo('http://192.168.1.20:8888');
    notifier.dispose();
    expect(clients.single.disposed, isTrue);
  });

  testWidgets('the connect screen scrolls instead of overflowing on a small phone',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320 * 3, 480 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final scan = Completer<String?>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serviceFinderProvider.overrideWithValue(() => scan.future),
          apiClientFactoryProvider.overrideWithValue(
              (url) => _FakeApi(url, reachable: !url.contains('typo'))),
        ],
        child: const RoomcastApp(),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'typo:8888');
    await tester.ensureVisible(find.text('Connect'));
    await tester.tap(find.text('Connect'));
    await tester.pump(); // scanning, with manual entry and the error box
    expect(tester.takeException(), isNull, reason: 'no RenderFlex overflow');
    expect(find.textContaining('Could not reach service'), findsOneWidget);
    scan.complete(null);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Connect is disabled while a manual attempt is in flight', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'user_disconnected': true}); // no auto-scan
    final slow = Completer<void>();
    var clients = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serviceFinderProvider.overrideWithValue(() async => null),
          apiClientFactoryProvider.overrideWithValue((url) {
            clients++;
            return _FakeApi(url, reachable: false, gate: slow.future);
          }),
        ],
        child: const RoomcastApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '192.168.1.20:8888');
    await tester.tap(find.byType(OutlinedButton));
    await tester.pump();
    await tester.tap(find.byType(OutlinedButton)); // impatient second tap
    await tester.pump();
    expect(clients, 1);
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed, isNull);
    slow.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed, isNotNull);
  });

  testWidgets('typed addresses are normalized before connecting', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'user_disconnected': true}); // no auto-scan
    final urls = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serviceFinderProvider.overrideWithValue(() async => null),
          apiClientFactoryProvider.overrideWithValue((url) {
            urls.add(url);
            return _FakeApi(url, reachable: false);
          }),
        ],
        child: const RoomcastApp(),
      ),
    );
    await tester.pumpAndSettle();
    for (final typed in ['http://192.168.1.5:8888/', 'HTTP://192.168.1.5:8888', 'httpbox.local:8888']) {
      await tester.enterText(find.byType(TextField), typed);
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
    }
    expect(urls, ['http://192.168.1.5:8888', 'http://192.168.1.5:8888', 'http://httpbox.local:8888']);
  });

  test('a manual connect failing while the scan checks its find keeps showing the scan', () async {
    SharedPreferences.setMockInitialValues({});
    final slowCheck = Completer<void>();
    final notifier = ServiceNotifier(() async => 'http://192.168.1.20:8888',
        clientFactory: (url) => url.contains('typo')
            ? _FakeApi(url, reachable: false)
            : _FakeApi(url, reachable: true, gate: slowCheck.future));
    final scanning = notifier.scanAndConnect();
    await Future<void>.delayed(Duration.zero); // found; its getInfo is in flight
    await notifier.connectTo('http://typo:8888');
    expect(notifier.state.status.name, 'scanning', reason: 'the scan is still connecting');
    expect(notifier.state.errorMessage, contains('typo'));
    slowCheck.complete();
    await scanning;
    expect(notifier.state.isConnected, isTrue);
    notifier.dispose();
  });

  test('a failed attempt while connected is not shown later as the reason', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = ServiceNotifier(() async => null,
        clientFactory: (url) => _FakeApi(url, reachable: !url.contains('typo')));
    await notifier.connectTo('http://192.168.1.20:8888');
    await notifier.connectTo('http://typo:8888'); // fails; the connection stays
    await notifier.disconnect();
    await notifier.scanAndConnect(); // finds nothing
    expect(notifier.state.errorMessage, isNot(contains('typo')));
    notifier.dispose();
  });

  test('preferences that fail to load or save never break connecting', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = ServiceNotifier(() async => null,
        clientFactory: (url) => _FakeApi(url, reachable: true),
        preferences: () async => throw StateError('prefs unavailable'));
    await notifier.loadSaved();                         // no throw
    expect(await notifier.userDisconnected(), isFalse);
    await notifier.connectTo('http://192.168.1.20:8888');
    expect(notifier.state.isConnected, isTrue);
    await notifier.disconnect();                        // no throw
    notifier.dispose();
  });

  test("a Disconnect's preference writes can't land after a later connect's", () async {
    SharedPreferences.setMockInitialValues({});
    final slowFirst = Completer<void>();
    var loads = 0;
    final notifier = ServiceNotifier(() async => null,
        clientFactory: (url) => _FakeApi(url, reachable: true),
        preferences: () async {
          if (++loads == 1) await slowFirst.future; // the first write is slow
          return SharedPreferences.getInstance();
        });
    final a = notifier.connectTo('http://192.168.1.20:8888');
    await Future<void>.delayed(Duration.zero);
    final d = notifier.disconnect();
    final b = notifier.connectTo('http://192.168.1.21:8888');
    await Future<void>.delayed(Duration.zero);
    slowFirst.complete();
    await Future.wait([a, d, b]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('service_base_url'), 'http://192.168.1.21:8888');
    expect(prefs.getBool('user_disconnected'), isNull);
    notifier.dispose();
  });

  test('an address saved by an older version is normalized at launch', () async {
    SharedPreferences.setMockInitialValues({'service_base_url': 'http://192.168.1.5:8888/'});
    final urls = <String>[];
    final notifier = ServiceNotifier(() async => null, clientFactory: (url) {
      urls.add(url);
      return _FakeApi(url, reachable: true);
    });
    await notifier.loadSaved();
    expect(urls, ['http://192.168.1.5:8888'], reason: 'with the slash it requested //api/info (404)');
    expect((await SharedPreferences.getInstance()).getString('service_base_url'), 'http://192.168.1.5:8888');
    notifier.dispose();
  });

  test('a path in the address (e.g. behind a reverse proxy) is kept', () async {
    SharedPreferences.setMockInitialValues({'service_base_url': 'http://nas.local/roomcast/'});
    final urls = <String>[];
    final notifier = ServiceNotifier(() async => null, clientFactory: (url) {
      urls.add(url);
      return _FakeApi(url, reachable: true);
    });
    await notifier.loadSaved();
    expect(urls, ['http://nas.local/roomcast']);
    notifier.dispose();
  });

  test('disconnect forgets the saved address', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = ServiceNotifier(() async => null,
        clientFactory: (url) => _FakeApi(url, reachable: true));
    await notifier.connectTo('http://192.168.1.20:8888');
    expect((await SharedPreferences.getInstance()).getString('service_base_url'), isNotNull);
    await notifier.disconnect();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('service_base_url'), isNull);
    expect(prefs.getBool('user_disconnected'), isTrue);
    await notifier.connectTo('http://192.168.1.20:8888');
    expect(prefs.getBool('user_disconnected'), isNull, reason: 'a new connection clears it');
    notifier.dispose();
  });

  testWidgets('after Disconnect the next launch does not scan and reconnect by itself',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'user_disconnected': true});
    var scans = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serviceFinderProvider.overrideWithValue(() async {
            scans++;
            return 'http://192.168.1.20:8888';
          }),
          apiClientFactoryProvider.overrideWithValue((url) => _FakeApi(url, reachable: true)),
        ],
        child: const RoomcastApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(scans, 0);
    expect(find.text('Find Service Automatically'), findsOneWidget);
  });

  testWidgets('a failed scan is retried once when the app returns (iOS permission prompt)',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    var scans = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // The first scan fails while the Local Network prompt is up.
          serviceFinderProvider.overrideWithValue(() async => ++scans == 3 ? 'http://192.168.1.20:8888' : null),
          apiClientFactoryProvider.overrideWithValue((url) => _FakeApi(url, reachable: true)),
          devicesPollIntervalProvider.overrideWithValue(null),
        ],
        child: const RoomcastApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No Roomcast FM service found on this network.'), findsOneWidget);
    void appSwitch() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
    appSwitch(); // the user taps Allow
    await tester.pumpAndSettle();
    expect(scans, 2);
    appSwitch(); // e.g. to look up the IP: no more scans of its own
    await tester.pumpAndSettle();
    expect(scans, 2);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('answering the prompt while the scan runs still retries if that scan fails',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final firstScan = Completer<String?>();
    var scans = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serviceFinderProvider.overrideWithValue(() {
            scans++;
            return scans == 1 ? firstScan.future : Future.value('http://192.168.1.20:8888');
          }),
          apiClientFactoryProvider.overrideWithValue((url) => _FakeApi(url, reachable: true)),
          devicesPollIntervalProvider.overrideWithValue(null),
        ],
        child: const RoomcastApp(),
      ),
    );
    await tester.pump();
    await tester.pump();
    // The user taps Allow while the first scan is still running...
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(scans, 1);
    firstScan.complete(null); // ...and it times out anyway
    await tester.pumpAndSettle();
    expect(scans, 2);
    expect(find.text('No Roomcast FM service found on this network.'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('returning to the app does not scan over a failed manual connect',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    var scans = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serviceFinderProvider.overrideWithValue(() async {
            scans++;
            return null;
          }),
          apiClientFactoryProvider.overrideWithValue(
              (url) => _FakeApi(url, reachable: !url.contains('typo'))),
        ],
        child: const RoomcastApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'typo:8888');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(scans, 1);
    expect(find.textContaining('Could not reach service at http://typo:8888'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  test('a finder that throws ends the scan like finding nothing', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = ServiceNotifier(() async => throw StateError('plugin missing'),
        clientFactory: (url) => _FakeApi(url, reachable: true));
    await notifier.scanAndConnect();
    expect(notifier.state.status.name, 'error');
    expect(notifier.state.errorMessage, contains('No Roomcast FM service found'));
    notifier.dispose();
  });

  testWidgets('an unreachable saved address stays visible after a failed auto-scan',
      (WidgetTester tester) async {
    // flutter_test answers every real HTTP request with 400, so the saved URL fails.
    SharedPreferences.setMockInitialValues({'service_base_url': 'http://192.0.2.10:8888'});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [serviceFinderProvider.overrideWithValue(() async => null)],
        child: const RoomcastApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('No Roomcast FM service found on this network.'), findsOneWidget);
    expect(find.textContaining('Could not reach service at http://192.0.2.10:8888'), findsOneWidget);
  });
}


extension _Let<T> on T {
  void let(void Function(T) f) => f(this);
}
