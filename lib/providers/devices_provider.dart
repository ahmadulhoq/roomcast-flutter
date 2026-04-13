// Manages paired devices list and scan results.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/device.dart';
import '../services/api_client.dart';
import 'service_provider.dart';

// ------------------------------------------------------------------
// Paired devices
// ------------------------------------------------------------------

class DevicesNotifier extends StateNotifier<AsyncValue<List<PairedDevice>>> {
  DevicesNotifier(this._client) : super(const AsyncValue.loading()) {
    refresh();
  }

  final RoomcastApiClient _client;

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    try {
      final devices = await _client.listDevices();
      state = AsyncValue.data(devices);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> remove(String id) async {
    await _client.removeDevice(id);
    await refresh();
  }

  Future<void> setVolume(String id, int level) async {
    await _client.setVolume(id, level);
    // Optimistic update
    state.whenData((devices) {
      state = AsyncValue.data([
        for (final d in devices)
          if (d.id == id) d.copyWith(volume: level) else d,
      ]);
    });
  }

  Future<void> enable(String id) async {
    await _client.enableDevice(id);
    await refresh();
  }

  Future<void> disable(String id) async {
    await _client.disableDevice(id);
    await refresh();
  }
}

final devicesProvider = StateNotifierProvider<DevicesNotifier,
    AsyncValue<List<PairedDevice>>>((ref) {
  final serviceState = ref.watch(serviceProvider);
  final client = serviceState.client;
  if (client == null) {
    return DevicesNotifier(_NullClient());
  }
  return DevicesNotifier(client);
});

// ------------------------------------------------------------------
// Network scan results
// ------------------------------------------------------------------

class ScanNotifier extends StateNotifier<AsyncValue<List<DiscoveredDevice>>> {
  ScanNotifier(this._client) : super(const AsyncValue.data([]));

  final RoomcastApiClient _client;

  Future<void> scan() async {
    state = const AsyncValue.loading();
    try {
      final devices = await _client.scan();
      state = AsyncValue.data(devices);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<bool> addDevice(DiscoveredDevice discovered, String id) async {
    try {
      final config = discovered.toDeviceConfig(id: id);
      await _client.addDevice(config);
      return true;
    } catch (_) {
      return false;
    }
  }
}

final scanProvider = StateNotifierProvider<ScanNotifier,
    AsyncValue<List<DiscoveredDevice>>>((ref) {
  final serviceState = ref.watch(serviceProvider);
  final client = serviceState.client;
  if (client == null) {
    return ScanNotifier(_NullClient());
  }
  return ScanNotifier(client);
});

// ------------------------------------------------------------------
// Null-object client used before service is connected
// ------------------------------------------------------------------

class _NullClient extends RoomcastApiClient {
  _NullClient() : super('http://localhost');

  @override
  Future<List<PairedDevice>> listDevices() async => [];

  @override
  Future<List<DiscoveredDevice>> scan() async => [];
}
