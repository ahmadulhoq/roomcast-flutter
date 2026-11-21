import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roomcast_fm/models/device.dart';
import 'package:roomcast_fm/providers/devices_provider.dart';
import 'package:roomcast_fm/services/api_client.dart';
import 'package:roomcast_fm/widgets/device_card.dart';

class FakeClient extends RoomcastApiClient {
  FakeClient(this.snapshot) : super('http://test');

  DevicesSnapshot snapshot;
  final calls = <String>[];
  bool failVolume = false;

  @override
  Future<DevicesSnapshot> getDevices() async => snapshot;

  @override
  Future<void> setVolume(String id, int level) async {
    calls.add('volume $id $level');
    if (failVolume) throw ApiException('speaker offline', statusCode: 500);
  }

  @override
  Future<void> enableDevice(String id) async => calls.add('enable $id');

  @override
  Future<void> disableDevice(String id) async {
    calls.add('disable $id');
    snapshot = DevicesSnapshot(streaming: false, devices: [
      for (final d in snapshot.devices) d.id == id ? d.copyWith(enabled: false, state: DeviceState.disabled) : d,
    ]);
  }

  @override
  Future<void> removeDevice(String id) async => calls.add('remove $id');
}

const _cast = PairedDevice(
  id: 'cast', name: 'Dining Room', type: DeviceType.chromecast,
  enabled: true, state: DeviceState.playing, volume: 50,
);

Future<FakeClient> pumpCard(WidgetTester tester, {PairedDevice device = _cast}) async {
  final client = FakeClient(DevicesSnapshot(streaming: true, devices: [device]));
  await tester.pumpWidget(ProviderScope(
    overrides: [devicesProvider.overrideWith((ref) => DevicesNotifier(client))],
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(builder: (context, ref, _) {
          final snapshot = ref.watch(devicesProvider).valueOrNull;
          if (snapshot == null) return const SizedBox();
          return ListView(children: [
            for (final d in snapshot.devices) DeviceCard(key: ValueKey(d.id), device: d),
          ]);
        }),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return client;
}

void main() {
  testWidgets('shows the Cast icon and enabled switch', (tester) async {
    await pumpCard(tester);
    expect(find.byIcon(Icons.cast), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.text('Playing'), findsOneWidget);
  });

  testWidgets('slider follows the drag and sends one volume request on release', (tester) async {
    final client = await pumpCard(tester);
    final slider = find.byType(Slider);
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(Offset(tester.getSize(slider).width * 0.3, 0));
    await tester.pump();
    final dragged = tester.widget<Slider>(slider).value;
    expect(dragged, greaterThan(50), reason: 'thumb moves while dragging');
    expect(client.calls, isEmpty, reason: 'no request until release');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(client.calls, ['volume cast ${dragged.round()}']);
    expect(find.text('${dragged.round()}'), findsOneWidget);
  });

  testWidgets('failed volume change rolls back and shows the error', (tester) async {
    final client = await pumpCard(tester);
    client.failVolume = true;
    await tester.drag(find.byType(Slider), const Offset(150, 0));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not set volume: speaker offline'), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 50);
  });

  testWidgets('switch disables the device', (tester) async {
    final client = await pumpCard(tester);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(client.calls, ['disable cast']);
    expect(find.text('Disabled'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('remove asks for confirmation first', (tester) async {
    final client = await pumpCard(tester);
    await tester.drag(find.byType(Slidable), const Offset(-300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Remove Dining Room?'), findsOneWidget);
    expect(client.calls, isEmpty);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(client.calls, isEmpty);

    await tester.drag(find.byType(Slidable), const Offset(-300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(client.calls, ['remove cast']);
  });

  testWidgets('remove still works if the card is gone when the dialog is confirmed', (tester) async {
    final client = await pumpCard(tester);
    await tester.drag(find.byType(Slidable), const Offset(-300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    // A refresh drops the card from the list while the dialog is open.
    client.snapshot = const DevicesSnapshot(streaming: true, devices: []);
    final container = ProviderScope.containerOf(tester.element(find.byType(ListView)));
    await container.read(devicesProvider.notifier).refresh();
    await tester.pump();
    expect(find.byType(DeviceCard), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(client.calls, ['remove cast']);
  });

  testWidgets('DLNA device shows the speaker icon', (tester) async {
    await pumpCard(tester, device: const PairedDevice(
      id: 'kef', name: 'KEF', type: DeviceType.dlna, enabled: false,
      state: DeviceState.disabled, volume: 30,
    ));
    expect(find.byIcon(Icons.speaker), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });
}
