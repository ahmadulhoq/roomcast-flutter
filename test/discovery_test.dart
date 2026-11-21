// findService() end to end against a fake bonsoir platform.

import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roomcast_fm/services/mdns_discovery.dart';

class FakeDiscoveryAction extends BonsoirAction<BonsoirDiscoveryEvent> with ServiceResolver {
  final controller = StreamController<BonsoirDiscoveryEvent>.broadcast();
  final resolveCalls = <String>[];
  void Function(BonsoirService service)? onResolve;
  bool _ready = false;
  bool _stopped = false;

  @override
  Stream<BonsoirDiscoveryEvent>? get eventStream => _ready ? controller.stream : null;

  @override
  Future<void> initialize() async => _ready = true;

  @override
  Future<void> start() async {
    onStart?.call();
    if (hangStart) await Completer<void>().future; // the platform never answers
    if (startDelay != null) await Future<void>.delayed(startDelay!);
    if (_stopped) running = true; // started after stop(): browsing with no one listening
  }

  Duration? startDelay;
  bool running = false;

  void Function()? onStart;
  bool hangStart = false;
  bool hangStop = false;

  @override
  Future<void> stop() async {
    _stopped = true;
    running = false;
    if (hangStop) await Completer<void>().future;
  }

  @override
  bool get isReady => _ready && !_stopped;

  @override
  bool get isStopped => _stopped;

  @override
  Future<void> resolveService(BonsoirService service) async {
    resolveCalls.add(service.name);
    onResolve?.call(service);
  }

  void emit(BonsoirDiscoveryEvent e) => controller.add(e);
  void error() => controller.addError(PlatformException(code: 'discoveryError'));
}

class FakeBonsoirPlatform extends BonsoirPlatformInterface {
  FakeBonsoirPlatform(this.action);
  final FakeDiscoveryAction action;

  @override
  BonsoirAction<BonsoirBroadcastEvent> createBroadcastAction(BonsoirService service, {bool printLogs = false}) =>
      throw UnimplementedError();

  @override
  BonsoirAction<BonsoirDiscoveryEvent> createDiscoveryAction(String type, {bool printLogs = false}) => action;
}

BonsoirService svc(String name, {String? host, Map<String, String> attrs = const {}}) =>
    BonsoirService.ignoreNorms(name: name, type: serviceType, port: 8888, host: host, attributes: attrs);

void main() {
  late FakeDiscoveryAction action;

  setUp(() {
    action = FakeDiscoveryAction();
    BonsoirPlatformInterface.instance = FakeBonsoirPlatform(action);
  });

  test('found → resolved returns the TXT ip URL', () async {
    action.onStart = () => action.emit(BonsoirDiscoveryServiceFoundEvent(service: svc('Roomcast FM')));
    action.onResolve = (s) => action.emit(BonsoirDiscoveryServiceResolvedEvent(
        service: svc(s.name, host: 'roomcast-fm.local.', attrs: {'ip': '192.168.1.20'})));
    expect(await ServiceDiscovery.findService(timeout: const Duration(seconds: 2)), 'http://192.168.1.20:8888');
  });

  test('a failed resolve is retried', () async {
    var failures = 0;
    action.onStart = () => action.emit(BonsoirDiscoveryServiceFoundEvent(service: svc('Roomcast FM')));
    action.onResolve = (s) {
      if (failures++ == 0) {
        action.emit(const BonsoirDiscoveryServiceResolveFailedEvent());
      } else {
        action.emit(BonsoirDiscoveryServiceResolvedEvent(service: svc(s.name, host: '192.168.1.20')));
      }
    };
    expect(await ServiceDiscovery.findService(timeout: const Duration(seconds: 2)), 'http://192.168.1.20:8888');
    expect(action.resolveCalls, ['Roomcast FM', 'Roomcast FM']);
  });

  test('a non-fatal error after a resolve does not end the scan', () async {
    action.onStart = () => action.emit(BonsoirDiscoveryServiceFoundEvent(service: svc('stale')));
    action.onResolve = (s) {
      if (s.name == 'stale') {
        // Resolves to an unusable host; then, with no resolve in flight,
        // Android reports "Failed to register service info callback"; then
        // the real backend is found.
        action.emit(BonsoirDiscoveryServiceResolvedEvent(service: svc('stale', host: '127.0.0.1')));
        action.error();
        action.emit(BonsoirDiscoveryServiceFoundEvent(service: svc('Roomcast FM')));
      } else {
        action.emit(BonsoirDiscoveryServiceResolvedEvent(service: svc(s.name, host: '192.168.1.21')));
      }
    };
    expect(await ServiceDiscovery.findService(timeout: const Duration(seconds: 2)), 'http://192.168.1.21:8888');
  });

  test('an error after a found service was lost again does not end the scan', () async {
    action.onStart = () => action.emit(BonsoirDiscoveryServiceFoundEvent(service: svc('old')));
    action.onResolve = (s) {
      if (s.name == 'old') {
        // The old instance goes away mid-resolve, then a non-fatal error,
        // then the backend's new instance appears.
        action.emit(BonsoirDiscoveryServiceLostEvent(service: svc('old')));
        action.error();
        action.emit(BonsoirDiscoveryServiceFoundEvent(service: svc('Roomcast FM')));
      } else {
        action.emit(BonsoirDiscoveryServiceResolvedEvent(service: svc(s.name, host: '192.168.1.22')));
      }
    };
    expect(await ServiceDiscovery.findService(timeout: const Duration(seconds: 2)), 'http://192.168.1.22:8888');
  });

  test('the timeout covers a platform call that never answers', () async {
    action
      ..hangStart = true
      ..hangStop = true;
    final started = DateTime.now();
    final result = await ServiceDiscovery.findService(timeout: const Duration(milliseconds: 500))
        .timeout(const Duration(seconds: 6), onTimeout: () => 'hung');
    expect(result, isNull);
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 4)));
  });

  test('discovery that finishes starting after the timeout is stopped', () async {
    action.startDelay = const Duration(milliseconds: 800);
    expect(await ServiceDiscovery.findService(timeout: const Duration(milliseconds: 300)), isNull);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(action.running, isFalse, reason: 'no browse left running in the background');
  });

  test('a TXT update of a queued, unresolved service does not drop it from the queue', () async {
    action.onStart = () {
      action.emit(BonsoirDiscoveryServiceFoundEvent(service: svc('stale')));
      action.emit(BonsoirDiscoveryServiceFoundEvent(service: svc('Roomcast FM')));
    };
    action.onResolve = (s) {
      if (s.name == 'stale') {
        // iOS reports the queued backend's TXT change (no host, no ip yet)…
        action.emit(BonsoirDiscoveryServiceUpdatedEvent(service: svc('Roomcast FM', attrs: {'version': '1.0'})));
        // …then the stale one resolves to an unusable address.
        action.emit(BonsoirDiscoveryServiceResolvedEvent(service: svc('stale', host: '127.0.0.1')));
      } else {
        action.emit(BonsoirDiscoveryServiceResolvedEvent(service: svc(s.name, host: '192.168.1.23')));
      }
    };
    expect(await ServiceDiscovery.findService(timeout: const Duration(seconds: 2)), 'http://192.168.1.23:8888');
  });

  test('a resolve that never reports back does not block the next service', () async {
    action.onStart = () {
      action.emit(BonsoirDiscoveryServiceFoundEvent(service: svc('stale cached instance')));
      action.emit(BonsoirDiscoveryServiceFoundEvent(service: svc('Roomcast FM')));
    };
    action.onResolve = (s) {
      if (s.name == 'Roomcast FM') {
        action.emit(BonsoirDiscoveryServiceResolvedEvent(service: svc(s.name, host: '192.168.1.24')));
      } // the stale one never answers
    };
    expect(await ServiceDiscovery.findService(timeout: const Duration(seconds: 6)), 'http://192.168.1.24:8888');
  });

  test('the URL is returned without waiting for discovery to stop', () async {
    action.hangStop = true;
    action.onStart = () => action.emit(BonsoirDiscoveryServiceFoundEvent(service: svc('Roomcast FM')));
    action.onResolve = (s) =>
        action.emit(BonsoirDiscoveryServiceResolvedEvent(service: svc(s.name, host: '192.168.1.25')));
    final started = DateTime.now();
    expect(await ServiceDiscovery.findService(timeout: const Duration(seconds: 5)), 'http://192.168.1.25:8888');
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 1)));
  });

  test('an error before anything is found ends the scan at once', () async {
    action.onStart = () => action.error(); // e.g. local-network permission denied
    final started = DateTime.now();
    expect(await ServiceDiscovery.findService(timeout: const Duration(seconds: 5)), isNull);
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 1)));
  });

  test('a late TXT update supplies the address', () async {
    action.onStart = () => action.emit(BonsoirDiscoveryServiceFoundEvent(service: svc('Roomcast FM')));
    action.onResolve = (s) {
      action.emit(BonsoirDiscoveryServiceResolvedEvent(service: svc(s.name, host: '127.0.0.1')));
      action.emit(BonsoirDiscoveryServiceUpdatedEvent(
          service: svc(s.name, host: '127.0.0.1', attrs: {'ip': '192.168.1.22'})));
    };
    expect(await ServiceDiscovery.findService(timeout: const Duration(seconds: 2)), 'http://192.168.1.22:8888');
  });

  test('the IPv6 zone URL it builds is a valid URI', () {
    final url = ServiceDiscovery.baseUrlFor(svc('x', host: 'fe80::1%wlan0'))!;
    expect(Uri.parse('$url/api/info').host, 'fe80::1%25wlan0');
  });
}
