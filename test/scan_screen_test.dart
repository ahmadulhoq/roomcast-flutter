import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roomcast_fm/models/device.dart';
import 'package:roomcast_fm/providers/devices_provider.dart';
import 'package:roomcast_fm/screens/scan_screen.dart';
import 'package:roomcast_fm/services/api_client.dart';

class SlowAddClient extends RoomcastApiClient {
  SlowAddClient() : super('http://test');
  final added = <String>[];
  final gate = Completer<void>();
  final rescan = Completer<void>(); // a real scan takes seconds (spinner shown)
  int scans = 0;

  @override
  Future<List<DiscoveredDevice>> scan() async {
    if (++scans > 1) await rescan.future;
    return const [DiscoveredDevice(name: 'KEF', type: DeviceType.dlna, idSuggestion: 'kef')];
  }

  bool fail = false;

  @override
  Future<void> addDevice(Map<String, dynamic> config) async {
    added.add(config['id'] as String);
    await gate.future;
    if (fail) throw ApiException('speaker busy');
  }

  @override
  Future<DevicesSnapshot> getDevices() async => DevicesSnapshot.empty;
}

void main() {
  testWidgets('a double tap on Add pairs the speaker once', (tester) async {
    final client = SlowAddClient();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        scanProvider.overrideWith((ref) => ScanNotifier(client, adding: ref.read(addingDevicesProvider.notifier))),
        devicesProvider.overrideWith((ref) => DevicesNotifier(client)),
      ],
      child: const MaterialApp(home: ScanScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pump();
    await tester.tap(find.text('Add')); // impatient second tap
    await tester.pump();
    expect(client.added, ['kef'], reason: 'a second POST would replace the output just created');
    client.gate.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('Failed to add'), findsNothing, reason: 'the second tap is not a failure');
  });

  test('a second add of the same id while the first runs is not reported as a failure', () async {
    final client = SlowAddClient();
    final notifier = ScanNotifier(client);
    const kef = DiscoveredDevice(name: 'KEF', type: DeviceType.dlna, idSuggestion: 'kef');
    final first = notifier.addDevice(kef, 'kef');
    expect(await notifier.addDevice(kef, 'kef'), ScanNotifier.alreadyAdding);
    client.gate.complete();
    expect(await first, isNull);
    notifier.dispose();
  });

  testWidgets('"Scan again" during an add does not allow a second one', (tester) async {
    final client = SlowAddClient();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        scanProvider.overrideWith((ref) => ScanNotifier(client, adding: ref.read(addingDevicesProvider.notifier))),
        devicesProvider.overrideWith((ref) => DevicesNotifier(client)),
      ],
      child: MaterialApp(navigatorKey: navigator, home: const Scaffold(body: Text('home'))),
    ));
    navigator.currentState!.push(MaterialPageRoute(builder: (_) => const ScanScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pump();
    await tester.tap(find.byTooltip('Scan again'));
    await tester.pump(); // spinner: the old tiles are gone
    client.rescan.complete();
    await tester.pumpAndSettle(); // new tiles
    await tester.tap(find.text('Add'));
    await tester.pump();
    expect(client.added, ['kef']);
    client.gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('KEF added'), findsOneWidget, reason: "the first add's result is still shown");
    expect(find.text('home'), findsOneWidget, reason: 'the scan screen closed after the add');
  });

  testWidgets('a rebuilt tile is enabled again when the add fails', (tester) async {
    final client = SlowAddClient()..fail = true;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        scanProvider.overrideWith((ref) => ScanNotifier(client, adding: ref.read(addingDevicesProvider.notifier))),
        devicesProvider.overrideWith((ref) => DevicesNotifier(client)),
      ],
      child: const MaterialApp(home: ScanScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pump();
    await tester.tap(find.byTooltip('Scan again'));
    await tester.pump();
    client.rescan.complete();
    await tester.pumpAndSettle();
    client.gate.complete(); // the first add fails
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Add')).onPressed, isNotNull,
        reason: 'the user can retry without another scan');
  });
}
