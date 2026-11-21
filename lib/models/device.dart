// Models for Roomcast FM devices.

enum DeviceType { chromecast, dlna, unknown }

enum DeviceState { idle, connecting, playing, error, disabled, unknown }

DeviceType parseDeviceType(String? t) {
  switch (t) {
    case 'chromecast':
      return DeviceType.chromecast;
    case 'dlna':
      return DeviceType.dlna;
    default:
      return DeviceType.unknown;
  }
}

/// A discovered (unpaired) device returned by the backend scan.
class DiscoveredDevice {
  final String name;
  final DeviceType type;
  final String? ip;
  final String? locationUrl;
  final String idSuggestion;

  const DiscoveredDevice({
    required this.name,
    required this.type,
    this.ip,
    this.locationUrl,
    required this.idSuggestion,
  });

  factory DiscoveredDevice.fromJson(Map<String, dynamic> json) {
    return DiscoveredDevice(
      name: json['name'] as String? ?? 'Unknown',
      type: parseDeviceType(json['type'] as String?),
      ip: json['ip'] as String?,
      locationUrl: json['location_url'] as String?,
      idSuggestion: json['id_suggestion'] as String? ?? 'device',
    );
  }

  /// Build a device config dict for POST /api/devices.
  Map<String, dynamic> toDeviceConfig({required String id}) {
    final config = <String, dynamic>{
      'id': id,
      'display_name': name,
      'type': type == DeviceType.chromecast ? 'chromecast' : 'dlna',
      'enabled': true,
      'volume': 75,
    };
    if (type == DeviceType.chromecast) {
      config['device_name'] = name;
    } else {
      if (ip != null) config['device_ip'] = ip;
      if (locationUrl != null) config['location_url'] = locationUrl;
    }
    return config;
  }
}

/// A paired device with live status from the backend.
class PairedDevice {
  final String id;
  final String name;
  final DeviceType type;
  final bool enabled;
  final DeviceState state;
  final int volume;
  final String? error;

  const PairedDevice({
    required this.id,
    required this.name,
    this.type = DeviceType.unknown,
    this.enabled = true,
    required this.state,
    required this.volume,
    this.error,
  });

  factory PairedDevice.fromJson(Map<String, dynamic> json) {
    final state = _parseState(json['state'] as String?);
    return PairedDevice(
      id: json['id'] as String,
      name: json['name'] as String? ?? json['id'] as String,
      // type/enabled were added to /api/devices later; older backends omit
      // them (a DISABLED state then still means disabled).
      type: parseDeviceType(json['type'] as String?),
      enabled: json['enabled'] as bool? ?? state != DeviceState.disabled,
      state: state,
      volume: (json['volume'] as num?)?.toInt() ?? 0,
      error: json['error'] as String?,
    );
  }

  static DeviceState _parseState(String? s) {
    switch (s) {
      case 'PLAYING':
        return DeviceState.playing;
      case 'CONNECTING':
        return DeviceState.connecting;
      case 'ERROR':
        return DeviceState.error;
      case 'DISABLED':
        return DeviceState.disabled;
      case 'IDLE':
        return DeviceState.idle;
      default:
        return DeviceState.unknown;
    }
  }

  PairedDevice copyWith({int? volume, DeviceState? state, bool? enabled}) {
    return PairedDevice(
      id: id,
      name: name,
      type: type,
      enabled: enabled ?? this.enabled,
      state: state ?? this.state,
      volume: volume ?? this.volume,
      error: error,
    );
  }
}

/// Paired devices plus whether the backend is streaming audio right now.
class DevicesSnapshot {
  final bool streaming;
  final List<PairedDevice> devices;

  const DevicesSnapshot({required this.streaming, required this.devices});

  static const empty = DevicesSnapshot(streaming: false, devices: []);

  factory DevicesSnapshot.fromJson(Map<String, dynamic> json) {
    final encoder = json['encoder'] as Map<String, dynamic>? ?? const {};
    final outputs = json['outputs'] as List<dynamic>? ?? const [];
    return DevicesSnapshot(
      streaming: encoder['streaming'] as bool? ?? false,
      devices: outputs.cast<Map<String, dynamic>>().map(PairedDevice.fromJson).toList(),
    );
  }

  DevicesSnapshot copyWith({List<PairedDevice>? devices}) =>
      DevicesSnapshot(streaming: streaming, devices: devices ?? this.devices);
}
