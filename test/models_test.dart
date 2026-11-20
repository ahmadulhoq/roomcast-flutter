import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roomcast_fm/models/device.dart';
import 'package:roomcast_fm/services/mdns_discovery.dart';

void main() {
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
      expect(snapshot.streaming, isFalse);
      expect(snapshot.devices.single.type, DeviceType.unknown);
      expect(snapshot.devices.single.enabled, isTrue);
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

    test('brackets IPv6 and rejects unresolved services', () {
      expect(ServiceDiscovery.baseUrlFor(svc(host: 'fe80::1')), 'http://[fe80::1]:8888');
      expect(ServiceDiscovery.baseUrlFor(svc(host: null)), isNull);
      expect(ServiceDiscovery.baseUrlFor(svc(host: '192.168.1.20', port: 0)), isNull);
    });
  });
}
