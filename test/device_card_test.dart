import 'dart:async';

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
  bool failRemove = false;
  Completer<void>? volumeGate; // when set, setVolume waits for it

  @override
  Future<DevicesSnapshot> getDevices() async => snapshot;

  @override
  Future<void> setVolume(String id, int level) async {
    calls.add('volume $id $level');
    if (volumeGate != null) await volumeGate!.future;
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
  Future<void> removeDevice(String id) async {
    calls.add('remove $id');
    if (failRemove) throw ApiException('backend busy', statusCode: 500);
  }
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

  testWidgets('the thumb keeps following a new drag when an earlier request completes', (tester) async {
    final client = await pumpCard(tester);
    client.volumeGate = Completer<void>();
    final slider = find.byType(Slider);
    final width = tester.getSize(slider).width;
    final left = tester.getTopLeft(slider);

    // Drag 1: release near 80 — its request stays in flight.
    final first = await tester.startGesture(tester.getCenter(slider));
    await first.moveTo(Offset(left.dx + width * 0.8, tester.getCenter(slider).dy));
    await first.up();
    await tester.pump();
    // Drag 2: hold near 30.
    final second = await tester.startGesture(tester.getCenter(slider));
    await second.moveTo(Offset(left.dx + width * 0.3, tester.getCenter(slider).dy));
    await tester.pump();
    final held = tester.widget<Slider>(slider).value;

    client.volumeGate!.complete(); // drag 1's request finishes mid-drag
    await tester.pump();
    expect(tester.widget<Slider>(slider).value, held, reason: 'no jump while the finger is down');
    await second.up();
    await tester.pumpAndSettle();
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

  testWidgets('a failed remove is reported even if the card is gone', (tester) async {
    final client = await pumpCard(tester);
    client.failRemove = true;
    await tester.drag(find.byType(Slidable), const Offset(-300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    client.snapshot = const DevicesSnapshot(streaming: true, devices: []);
    final container = ProviderScope.containerOf(tester.element(find.byType(ListView)));
    await container.read(devicesProvider.notifier).refresh();
    await tester.pump();
    expect(find.byType(DeviceCard), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not remove Dining Room: backend busy'), findsOneWidget);
  });

  testWidgets('no error is shown for an action whose connection is gone', (tester) async {
    // e.g. Disconnect while the remove dialog is open: the device list (and
    // its client) is replaced, so the old request's failure is moot.
    final client = FakeClient(const DevicesSnapshot(streaming: true, devices: [_cast]))..failRemove = true;
    final connection = StateProvider<int>((ref) => 0);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        devicesProvider.overrideWith((ref) {
          ref.watch(connection);
          return DevicesNotifier(client);
        }),
      ],
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
    await tester.drag(find.byType(Slidable), const Offset(-300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    container.read(connection.notifier).state++; // the old notifier is disposed
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(client.calls, ['remove cast']);
    expect(find.textContaining('Could not remove'), findsNothing);
  });

  testWidgets('a request cut off by Disconnect shows no error', (tester) async {
    // Guard: Riverpod disposes the old device list synchronously when the
    // connection changes, before the closed client's error arrives.
    final client = FakeClient(const DevicesSnapshot(streaming: true, devices: [_cast]))
      ..failVolume = true
      ..volumeGate = Completer<void>();
    final connection = StateProvider<int>((ref) => 0);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        devicesProvider.overrideWith((ref) {
          ref.watch(connection);
          return DevicesNotifier(client);
        }),
      ],
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
    await tester.drag(find.byType(Slider), const Offset(150, 0)); // setVolume in flight
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    // Disconnect: the connection changes and the closed client fails the request.
    container.read(connection.notifier).state++;
    client.volumeGate!.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not set volume'), findsNothing);
  });

  testWidgets('the enable switch is named for screen readers', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpCard(tester);
    expect(find.bySemanticsLabel(RegExp('Enable Dining Room')), findsOneWidget);
    semantics.dispose();
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
