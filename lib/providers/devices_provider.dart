// Manages paired devices list and scan results.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/device.dart';
import '../services/api_client.dart';
import 'service_provider.dart';

// ------------------------------------------------------------------
// Paired devices
// ------------------------------------------------------------------

/// How often the device list (states, streaming) is refreshed in the
/// background while connected. Null disables polling (tests).
final devicesPollIntervalProvider =
    Provider<Duration?>((ref) => const Duration(seconds: 5));

class DevicesNotifier extends StateNotifier<AsyncValue<DevicesSnapshot>> {
  DevicesNotifier(this._client, {Duration? pollInterval})
      : super(const AsyncValue.loading()) {
    refresh();
    if (pollInterval != null) {
      _timer = Timer.periodic(pollInterval, (_) => _poll());
    }
  }

  final RoomcastApiClient _client;
  Timer? _timer;

  /// Incremented by every refresh and every local change; a response is only
  /// applied if no newer refresh or change happened while it was in flight.
  int _requestSeq = 0;

  /// The refresh currently in flight, if any.
  Future<void>? _inFlight;

  /// Background poll: skipped while a refresh is still running, so a slow or
  /// unreachable backend (requests time out after 10 s) can't stack requests
  /// that each invalidate the previous one's result.
  void _poll() {
    if (_inFlight == null) refresh();
  }

  Future<void> refresh() {
    final future = _refresh();
    _inFlight = future;
    future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
    return future;
  }

  Future<void> _refresh() async {
    final seq = ++_requestSeq;
    // Keep showing the current list while reloading (no spinner flash).
    state = const AsyncValue<DevicesSnapshot>.loading().copyWithPrevious(state);
    try {
      final snapshot = await _client.getDevices();
      if (mounted && seq == _requestSeq) state = AsyncValue.data(snapshot);
    } catch (e, st) {
      if (mounted && seq == _requestSeq) {
        state = AsyncValue<DevicesSnapshot>.error(e, st).copyWithPrevious(state);
      }
    }
  }

  /// Throws [ApiException] on failure.
  Future<void> remove(String id) async {
    await _client.removeDevice(id);
    await refresh();
  }

  /// Optimistic: the slider shows the new level at once and is rolled back if
  /// the request fails. Throws [ApiException] on failure.
  Future<void> setVolume(String id, int level) async {
    final oldVolume = state.valueOrNull?.devices
        .where((d) => d.id == id)
        .map((d) => d.volume)
        .firstOrNull;
    // A refresh already in flight carries the old level: drop its result.
    _requestSeq++;
    _updateDevice(id, (d) => d.copyWith(volume: level));
    try {
      await _client.setVolume(id, level);
    } catch (_) {
      // Roll back only this device's volume, keeping any newer updates.
      if (mounted && oldVolume != null) {
        _updateDevice(id, (d) => d.copyWith(volume: oldVolume));
      }
      rethrow;
    }
  }

  /// Throws [ApiException] on failure.
  Future<void> setEnabled(String id, bool enabled) async {
    _requestSeq++; // an in-flight refresh predates this change
    if (enabled) {
      await _client.enableDevice(id);
    } else {
      await _client.disableDevice(id);
    }
    await refresh();
  }

  void _updateDevice(String id, PairedDevice Function(PairedDevice) update) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncValue.data(current.copyWith(devices: [
      for (final d in current.devices)
        if (d.id == id) update(d) else d,
    ]));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final devicesProvider = StateNotifierProvider<DevicesNotifier,
    AsyncValue<DevicesSnapshot>>((ref) {
  final serviceState = ref.watch(serviceProvider);
  final client = serviceState.client;
  if (client == null) {
    return DevicesNotifier(_NullClient());
  }
  return DevicesNotifier(client, pollInterval: ref.watch(devicesPollIntervalProvider));
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

  /// Pair a discovered device. Returns null on success, else an error message.
  Future<String?> addDevice(DiscoveredDevice discovered, String id) async {
    try {
      final config = discovered.toDeviceConfig(id: id);
      await _client.addDevice(config);
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
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
  Future<DevicesSnapshot> getDevices() async => DevicesSnapshot.empty;

  @override
  Future<List<DiscoveredDevice>> scan() async => [];
}
