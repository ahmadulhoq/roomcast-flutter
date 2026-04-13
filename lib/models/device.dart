// Models for Roomcast FM devices.

enum DeviceType { chromecast, dlna, unknown }

enum DeviceState { idle, connecting, playing, error, disabled, unknown }

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
      type: _parseType(json['type'] as String?),
      ip: json['ip'] as String?,
      locationUrl: json['location_url'] as String?,
      idSuggestion: json['id_suggestion'] as String? ?? 'device',
    );
  }

  static DeviceType _parseType(String? t) {
    switch (t) {
      case 'chromecast':
        return DeviceType.chromecast;
      case 'dlna':
        return DeviceType.dlna;
      default:
        return DeviceType.unknown;
    }
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
      config['device_ip'] = ip;
      if (locationUrl != null) config['location_url'] = locationUrl;
      config['dlna_stream_mode'] = 'chunked';
    }
    return config;
  }
}

/// A paired device with live status from the backend.
class PairedDevice {
  final String id;
  final String name;
  final DeviceState state;
  final int volume;
  final String? error;

  const PairedDevice({
    required this.id,
    required this.name,
    required this.state,
    required this.volume,
    this.error,
  });

  factory PairedDevice.fromJson(Map<String, dynamic> json) {
    return PairedDevice(
      id: json['id'] as String,
      name: json['name'] as String? ?? json['id'] as String,
      state: _parseState(json['state'] as String?),
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

  PairedDevice copyWith({int? volume, DeviceState? state}) {
    return PairedDevice(
      id: id,
      name: name,
      state: state ?? this.state,
      volume: volume ?? this.volume,
      error: error,
    );
  }
}
