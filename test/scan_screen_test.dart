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

  @override
  Future<List<DiscoveredDevice>> scan() async =>
      const [DiscoveredDevice(name: 'KEF', type: DeviceType.dlna, idSuggestion: 'kef')];

  @override
  Future<void> addDevice(Map<String, dynamic> config) async {
    added.add(config['id'] as String);
    await gate.future;
  }

  @override
  Future<DevicesSnapshot> getDevices() async => DevicesSnapshot.empty;
}

void main() {
  testWidgets('a double tap on Add pairs the speaker once', (tester) async {
    final client = SlowAddClient();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        scanProvider.overrideWith((ref) => ScanNotifier(client)),
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
  });
}
