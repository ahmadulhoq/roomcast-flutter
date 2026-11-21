import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:roomcast_fm/main.dart';
import 'package:roomcast_fm/providers/service_provider.dart';
import 'package:roomcast_fm/services/api_client.dart';

class _FakeApi extends RoomcastApiClient {
  _FakeApi(super.baseUrl, {required this.reachable});
  final bool reachable;
  bool disposed = false;

  @override
  Future<Map<String, dynamic>> getInfo() async {
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

