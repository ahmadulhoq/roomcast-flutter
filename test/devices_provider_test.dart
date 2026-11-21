import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roomcast_fm/models/device.dart';
import 'package:roomcast_fm/providers/devices_provider.dart';
import 'package:roomcast_fm/screens/home_screen.dart';
import 'package:roomcast_fm/services/api_client.dart';

/// Every getDevices()/setVolume() call waits until the test completes it.
class SlowClient extends RoomcastApiClient {
  SlowClient() : super('http://test');

  final pending = <Completer<DevicesSnapshot>>[];
  final volumeCalls = <Completer<void>>[];

  @override
  Future<DevicesSnapshot> getDevices() {
    final c = Completer<DevicesSnapshot>();
    pending.add(c);
    return c.future;
  }

  @override
  Future<void> setVolume(String id, int level) {
    final c = Completer<void>();
    volumeCalls.add(c);
    return c.future;
  }
}

DevicesSnapshot snap(Map<String, int> volumes) => DevicesSnapshot(streaming: true, devices: [
      for (final e in volumes.entries)
        PairedDevice(id: e.key, name: e.key, type: DeviceType.dlna, state: DeviceState.playing, volume: e.value),
    ]);

int volumeOf(DevicesNotifier n, String id) =>
    n.state.value!.devices.firstWhere((d) => d.id == id).volume;

void main() {
  testWidgets('polls do not stack while a request is slow, and its error shows', (tester) async {
    final client = SlowClient();
    final notifier = DevicesNotifier(client, pollInterval: const Duration(seconds: 5));
    expect(client.pending.length, 1); // initial refresh
    await tester.pump(const Duration(seconds: 12)); // two poll ticks pass
    expect(client.pending.length, 1, reason: 'no new request while one is in flight');

    client.pending.single.completeError(ApiException('Network error: timeout'));
    await tester.pump();
    expect(notifier.state.hasError, isTrue, reason: 'the timed-out request is not discarded');

    await tester.pump(const Duration(seconds: 5));
    expect(client.pending.length, 2, reason: 'polling resumes once the request finished');
    notifier.dispose();
  });

  testWidgets('a refresh in flight does not undo a volume change', (tester) async {
    final client = SlowClient();
    final notifier = DevicesNotifier(client);
    client.pending[0].complete(snap({'cast': 50}));
    await tester.pump();

    unawaited(notifier.refresh()); // e.g. a poll, carrying the old level
    final change = notifier.setVolume('cast', 80);
    expect(volumeOf(notifier, 'cast'), 80);
    client.pending[1].complete(snap({'cast': 50}));
    client.volumeCalls.single.complete();
    await change;
    await tester.pump();
    expect(volumeOf(notifier, 'cast'), 80);
    notifier.dispose();
  });

  testWidgets('a failed volume change rolls back only that device', (tester) async {
    final client = SlowClient();
    final notifier = DevicesNotifier(client);
    client.pending[0].complete(snap({'a': 50, 'b': 30}));
    await tester.pump();

    final change = notifier.setVolume('a', 80);
    unawaited(notifier.refresh()); // newer data arrives while the request is pending
    client.pending[1].complete(snap({'a': 80, 'b': 35}));
    await tester.pump();
    client.volumeCalls.single.completeError(ApiException('speaker offline'));
    await expectLater(change, throwsA(isA<ApiException>()));
    expect(volumeOf(notifier, 'a'), 50);
    expect(volumeOf(notifier, 'b'), 35, reason: "the other device's update is kept");
    notifier.dispose();
  });

  testWidgets('a failed refresh keeps the list and shows a banner', (tester) async {
    final client = SlowClient();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        devicesProvider.overrideWith((ref) => DevicesNotifier(client)),
      ],
      child: const MaterialApp(home: HomeScreen()),
    ));
    client.pending[0].complete(snap({'Dining Room': 50}));
    await tester.pumpAndSettle();
    expect(find.text('Dining Room'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    client.pending[1].completeError(ApiException('Network error: unreachable'));
    await tester.pumpAndSettle();
    expect(find.text('Dining Room'), findsOneWidget, reason: 'list stays on screen');
    expect(find.textContaining("Can't reach Roomcast FM"), findsOneWidget);
    expect(find.textContaining('Failed to load devices'), findsNothing);
  });

  testWidgets('first load failing still shows the error view', (tester) async {
    final client = SlowClient();
    await tester.pumpWidget(ProviderScope(
      overrides: [devicesProvider.overrideWith((ref) => DevicesNotifier(client))],
      child: const MaterialApp(home: HomeScreen()),
    ));
    client.pending[0].completeError(ApiException('Network error: unreachable'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Failed to load devices'), findsOneWidget);
  });
}
