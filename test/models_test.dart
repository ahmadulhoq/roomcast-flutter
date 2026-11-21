import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roomcast_fm/models/device.dart';
import 'package:roomcast_fm/services/mdns_discovery.dart';

void main() {
  group('ResolveTracker', () {
    BonsoirService s(String name) =>
        BonsoirService.ignoreNorms(name: name, type: serviceType, port: 8888);

    test('resolves one service at a time, in order', () {
      final t = ResolveTracker();
      t.found(s('A'));
      t.found(s('B'));
      t.found(s('A')); // re-announce: ignored
      expect(t.next()?.name, 'A');
      expect(t.next(), isNull, reason: 'A is still in flight');
      t.resolved(s('A'));
      expect(t.next()?.name, 'B');
    });

    test('a failure retries only the failed service, after the others', () {
      final t = ResolveTracker(maxAttempts: 2);
      t.found(s('A'));
      t.found(s('B'));
      expect(t.next()?.name, 'A');
      t.failed();                      // A: attempt 1 failed → re-queued behind B
      t.failed();                      // second report of the same failure: no-op
      expect(t.next()?.name, 'B');
      t.resolved(s('B'));
      expect(t.next()?.name, 'A');     // A: attempt 2
      t.failed();
      expect(t.next(), isNull, reason: 'A has no attempts left; B kept its own');
    });

    test('a lost service is forgotten and can be found again', () {
      final t = ResolveTracker();
      t.found(s('A'));
      expect(t.next()?.name, 'A');
      t.lost(s('A'));
      expect(t.resolving, isFalse);
      expect(t.next(), isNull);
      t.found(s('A'));
      expect(t.next()?.name, 'A');
    });

    test('everFound stays true after the service is lost', () {
      final t = ResolveTracker();
      expect(t.everFound, isFalse);
      t.found(s('A'));
      t.lost(s('A'));
      expect(t.everFound, isTrue);
    });
  });

  group('DevicesSnapshot / PairedDevice', () {
    test('parses type, enabled and streaming', () {
      final snapshot = DevicesSnapshot.fromJson({
        'encoder': {'running': true, 'streaming': true, 'clients': 2, 'format': 'mp3'},
        'outputs': [
          {'id': 'cast', 'name': 'Dining Room', 'type': 'chromecast', 'enabled': true,
           'state': 'PLAYING', 'volume': 40, 'error': null},
          {'id': 'kef', 'name': 'KEF', 'type': 'dlna', 'enabled': false,
           'state': 'DISABLED', 'volume': 70, 'error': null},
        ],
      });
      expect(snapshot.streaming, isTrue);
      expect(snapshot.devices.map((d) => d.type), [DeviceType.chromecast, DeviceType.dlna]);
      expect(snapshot.devices[1].enabled, isFalse);
      expect(snapshot.devices[1].state, DeviceState.disabled);
    });

    test('older backends without type/enabled/streaming still parse', () {
      final snapshot = DevicesSnapshot.fromJson({
        'encoder': {'running': true},
        'outputs': [
          {'id': 'x', 'name': 'X', 'state': 'IDLE', 'volume': 10},
        ],
      });
      expect(snapshot.streaming, isNull, reason: 'unknown, so no "Idle" badge');
      expect(snapshot.devices.single.type, DeviceType.unknown);
      expect(snapshot.devices.single.enabled, isTrue);
    });

    test('without an enabled field, a DISABLED state means disabled', () {
      final d = PairedDevice.fromJson({'id': 'x', 'state': 'DISABLED', 'volume': 10});
      expect(d.enabled, isFalse);
    });
  });

  group('DiscoveredDevice.toDeviceConfig', () {
    test('dlna config has no dead dlna_stream_mode and no null ip', () {
      const d = DiscoveredDevice(
        name: 'KEF LSX', type: DeviceType.dlna, ip: null,
        locationUrl: 'http://192.168.86.40:16500/rootDesc.xml', idSuggestion: 'kef',
      );
      final config = d.toDeviceConfig(id: 'kef');
      expect(config.containsKey('dlna_stream_mode'), isFalse);
      expect(config.containsKey('device_ip'), isFalse);
      expect(config['location_url'], 'http://192.168.86.40:16500/rootDesc.xml');
    });

    test('no volume/enabled defaults (re-pairing keeps the stored ones)', () {
      const d = DiscoveredDevice(name: 'Dining Room', type: DeviceType.chromecast, idSuggestion: 'dining_room');
      final config = d.toDeviceConfig(id: 'dining_room');
      expect(config.containsKey('volume'), isFalse);
      expect(config.containsKey('enabled'), isFalse);
    });

    test('device_ip only for an IPv4 address', () {
      DiscoveredDevice dlna(String ip) => DiscoveredDevice(
          name: 'KEF', type: DeviceType.dlna, ip: ip,
          locationUrl: 'http://example/desc.xml', idSuggestion: 'kef');
      expect(dlna('192.168.86.40').toDeviceConfig(id: 'kef')['device_ip'], '192.168.86.40');
      expect(dlna('fd00::5').toDeviceConfig(id: 'kef').containsKey('device_ip'), isFalse);
    });

    test('chromecast config uses the friendly name', () {
      const d = DiscoveredDevice(name: 'Dining Room', type: DeviceType.chromecast, idSuggestion: 'dining_room');
      expect(d.toDeviceConfig(id: 'dining_room')['device_name'], 'Dining Room');
    });
  });

  group('ServiceDiscovery.baseUrlFor', () {
    BonsoirService svc({String? host, int port = 8888, Map<String, String> attrs = const {}}) =>
        BonsoirService.ignoreNorms(name: 'Roomcast FM', type: serviceType, host: host, port: port, attributes: attrs);

    test('prefers the TXT ip over the host name', () {
      expect(ServiceDiscovery.baseUrlFor(svc(host: 'roomcast-fm.local.', attrs: {'ip': '192.168.1.20'})),
          'http://192.168.1.20:8888');
    });

    test('falls back to the resolved host without the trailing dot', () {
      expect(ServiceDiscovery.baseUrlFor(svc(host: 'roomcast-fm.local.')), 'http://roomcast-fm.local:8888');
    });

    test('ignores a TXT ip that is not an address', () {
      expect(ServiceDiscovery.baseUrlFor(svc(host: '192.168.1.21', attrs: {'ip': 'nope'})),
          'http://192.168.1.21:8888');
    });

    test('ignores a loopback/unspecified TXT ip and uses the host', () {
      expect(ServiceDiscovery.baseUrlFor(svc(host: '192.168.1.20', attrs: {'ip': '127.0.0.1'})),
          'http://192.168.1.20:8888');
      expect(ServiceDiscovery.baseUrlFor(svc(host: '192.168.1.20', attrs: {'ip': '0.0.0.0'})),
          'http://192.168.1.20:8888');
      expect(ServiceDiscovery.baseUrlFor(svc(host: '127.0.0.1')), isNull);
    });

    test('brackets IPv6 and rejects unresolved services', () {
      expect(ServiceDiscovery.baseUrlFor(svc(host: 'fe80::1')), 'http://[fe80::1]:8888');
      expect(ServiceDiscovery.baseUrlFor(svc(host: null)), isNull);
      expect(ServiceDiscovery.baseUrlFor(svc(host: '192.168.1.20', port: 0)), isNull);
    });
  });
}
