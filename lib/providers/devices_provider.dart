// Manages paired devices list and scan results.

import 'dart:async';

import 'package:flutter/widgets.dart';
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

/// A volume change the server may not report yet.
class _PendingVolume {
  _PendingVolume(this.level, this.previous);

  final int level;

  /// The change this one replaced, shown again if this one fails (dropped
  /// once this one is accepted: nothing before it matters then).
  _PendingVolume? previous;

  /// Request sequence at the moment the change succeeded. Snapshots from
  /// refreshes started after that include the new level; earlier ones don't.
  int? confirmedAtSeq;

  /// Its request failed.
  bool failed = false;

  /// The newest change in this chain that hasn't failed (still in flight, or
  /// accepted but not reported yet); null if all failed.
  _PendingVolume? get fallback {
    var p = previous;
    while (p != null && p.failed) {
      p = p.previous;
    }
    return p;
  }
}

class DevicesNotifier extends StateNotifier<AsyncValue<DevicesSnapshot>> {
  DevicesNotifier(this._client, {Duration? pollInterval})
      : _pollInterval = pollInterval,
        super(const AsyncValue.loading()) {
    refresh();
    if (pollInterval != null) {
      // Don't poll while the app is in the background (battery, Wi-Fi). The
      // listener only reports changes, so check the current state too (this
      // notifier can be created while backgrounded, e.g. a connect finishing).
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle == null || lifecycle == AppLifecycleState.resumed) _startPolling();
      _lifecycle = AppLifecycleListener(onStateChange: _onLifecycleChange);
    }
  }

  final RoomcastApiClient _client;
  final Duration? _pollInterval;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(_pollInterval!, (_) => _poll());
  }

  void _onLifecycleChange(AppLifecycleState lifecycle) {
    switch (lifecycle) {
      case AppLifecycleState.resumed:
        if (_timer == null) {
          _startPolling();
          _poll(); // catch up at once on return (unless one is still running)
        }
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _timer?.cancel();
        _timer = null;
      case AppLifecycleState.inactive:
        break; // still visible (e.g. a system sheet on top)
    }
  }

  /// Incremented by every refresh. A successful response is applied unless a
  /// newer one already was; a failure only if no newer refresh started.
  int _requestSeq = 0;

  /// Sequence of the last response applied.
  int _appliedSeq = 0;


  /// Latest device list as reported by the server (without local changes).
  DevicesSnapshot? _server;

  /// Volume changes shown on top of [_server] until the server reports them.
  final _pendingVolumes = <String, _PendingVolume>{};

  /// The last volume request sent per device: the next one waits for it, so
  /// the server gets them in order (separate connections could swap them,
  /// and the server applies the one that arrives last).
  final _volumeSends = <String, Future<void>>{};

  Future<void> _sendVolume(String id, int level) {
    final previous = _volumeSends[id];
    final send = previous == null
        ? _client.setVolume(id, level) // nothing in flight: send now
        : previous
            .then<void>((_) {}, onError: (Object _) {}) // its failure went to its own caller
            .then((_) => _client.setVolume(id, level));
    _volumeSends[id] = send;
    unawaited(send.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_volumeSends[id], send)) _volumeSends.remove(id);
    }));
    return send;
  }

  /// Background poll: skipped while a refresh is still running, so a slow or
  /// unreachable backend (requests time out after 10 s) can't stack requests
  /// that each invalidate the previous one's result.
  void _poll() {
    if (_outstanding == 0) refresh(background: true);
  }

  /// Requests still running (any of them: a newer one can finish first).
  int _outstanding = 0;

  /// Reload the list. A [background] refresh (poll) doesn't mark the state
  /// as loading: that would rebuild the whole list twice per poll.
  Future<void> refresh({bool background = false}) {
    _outstanding++;
    final future = _refresh(background: background);
    future.whenComplete(() => _outstanding--);
    return future;
  }

  Future<void> _refresh({required bool background}) async {
    if (!mounted) return; // e.g. an action finishing after Disconnect
    final seq = ++_requestSeq;
    // Keep showing the current list while reloading (no spinner flash).
    if (!background) {
      state = const AsyncValue<DevicesSnapshot>.loading().copyWithPrevious(state);
    }
    try {
      final snapshot = await _client.getDevices();
      // Fresher than what is shown, even if a newer refresh is still running
      // (it may fail: the list shouldn't stay stale because of that).
      if (!mounted || seq <= _appliedSeq) return;
      _appliedSeq = seq;
      _server = snapshot;
      _pendingVolumes.removeWhere(
          (_, p) => p.confirmedAtSeq != null && seq > p.confirmedAtSeq!);
      final shown = _withPending(snapshot);
      // Nothing changed (most polls): leave the state alone, so the list
      // isn't rebuilt every few seconds.
      if (state is AsyncData<DevicesSnapshot> && !state.isLoading && state.value == shown) return;
      state = AsyncValue.data(shown);
    } catch (e, st) {
      if (mounted && seq == _requestSeq) {
        state = AsyncValue<DevicesSnapshot>.error(e, st).copyWithPrevious(state);
      }
    }
  }

  /// Throws [ApiException] on failure; re-syncs with the server either way
  /// (a timed-out remove may still have happened).
  Future<void> remove(String id) async {
    try {
      await _client.removeDevice(id);
    } finally {
      await refresh();
    }
  }

  /// Optimistic: the slider shows the new level at once. It stays shown,
  /// even over refreshes that started before the server applied it, until
  /// the server reports it. On failure (unless a newer change was made) the
  /// change before it is shown again — still in flight or accepted but not
  /// reported yet — else the server's own level, and the list is re-synced.
  /// Throws [ApiException] on failure, unless a newer change of this device
  /// already replaced this one (its failure doesn't matter any more).
  Future<void> setVolume(String id, int level) async {
    final pending = _PendingVolume(level, _pendingVolumes[id]);
    _pendingVolumes[id] = pending;
    _showLocal();
    try {
      await _sendVolume(id, level);
      // Recorded even if a newer change replaced this one: should that one
      // fail, this level is what the server has.
      pending.confirmedAtSeq = _requestSeq;
      pending.previous = null;
    } catch (_) {
      pending.failed = true; // never shown again, even as a fallback
      if (!identical(_pendingVolumes[id], pending)) return; // superseded: no error to show
      final fallback = pending.fallback;
      if (fallback != null) {
        _pendingVolumes[id] = fallback; // its own outcome then decides
      } else {
        _pendingVolumes.remove(id);
      }
      _showLocal();
      unawaited(refresh());
      rethrow;
    }
  }

  /// Throws [ApiException] on failure; re-syncs with the server either way.
  Future<void> setEnabled(String id, bool enabled) async {
    try {
      if (enabled) {
        await _client.enableDevice(id);
      } else {
        await _client.disableDevice(id);
      }
    } finally {
      await refresh();
    }
  }

  DevicesSnapshot _withPending(DevicesSnapshot snapshot) {
    if (_pendingVolumes.isEmpty) return snapshot;
    return snapshot.copyWith(devices: [
      for (final d in snapshot.devices)
        _pendingVolumes.containsKey(d.id)
            ? d.copyWith(volume: _pendingVolumes[d.id]!.level)
            : d,
    ]);
  }

  /// Re-render the server list with local changes, keeping any error (the
  /// offline banner) in place.
  void _showLocal() {
    final server = _server;
    if (server == null || !mounted) return;
    final data = AsyncValue<DevicesSnapshot>.data(_withPending(server));
    state = state.hasError
        ? AsyncValue<DevicesSnapshot>.error(state.error!, state.stackTrace ?? StackTrace.current)
            .copyWithPrevious(data)
        : data;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }
}

final devicesProvider = StateNotifierProvider<DevicesNotifier,
    AsyncValue<DevicesSnapshot>>((ref) {
  final serviceState = ref.watch(serviceProvider);
  final client = serviceState.client;
  if (client == null) {
    final placeholder = _NullClient();
    ref.onDispose(placeholder.dispose); // it owns an http.Client too
    return DevicesNotifier(placeholder);
  }
  return DevicesNotifier(client, pollInterval: ref.watch(devicesPollIntervalProvider));
});

// ------------------------------------------------------------------
// Network scan results
// ------------------------------------------------------------------

/// Device ids with an add request in flight (the Add buttons watch it).
final addingDevicesProvider = StateProvider<Set<String>>((ref) => const <String>{});

class ScanNotifier extends StateNotifier<AsyncValue<List<DiscoveredDevice>>> {

  final RoomcastApiClient _client;

  /// Incremented by every scan: only the newest one's result is shown.
  int _scanSeq = 0;

  /// The scan in progress. Another request while it runs joins it: the
  /// backend runs scans one at a time, so a second one would only start
  /// after this one (5–8 s) and then hit the client's 10 s timeout.
  Future<void>? _scanning;

  Future<void> scan() {
    final running = _scanning;
    if (running != null) return running;
    final future = _scan();
    _scanning = future;
    future.whenComplete(() {
      if (identical(_scanning, future)) _scanning = null;
    });
    return future;
  }

  Future<void> _scan() async {
    final seq = ++_scanSeq;
    state = const AsyncValue.loading();
    try {
      final devices = await _client.scan();
      // Not if the connection changed meanwhile, or a newer scan started.
      if (mounted && seq == _scanSeq) state = AsyncValue.data(devices);
    } catch (e, st) {
      if (mounted && seq == _scanSeq) state = AsyncValue.error(e, st);
    }
  }

  ScanNotifier(this._client, {StateController<Set<String>>? adding})
      : _addingIds = adding ?? StateController(<String>{}),
        super(const AsyncValue.data([]));

  /// Ids with an add request in flight, watched by the list tiles (see
  /// [addingDevicesProvider]). Kept outside the tiles: a "Scan again"
  /// rebuilds them, and a second add of the same id would make the backend
  /// replace the output it has just created.
  final StateController<Set<String>> _addingIds;

  bool isAdding(String id) => _addingIds.state.contains(id);

  /// What addDevice returns for a second tap while the first add runs:
  /// not a failure — the first add reports the outcome.
  static const alreadyAdding = '';

  /// Pair a discovered device. Returns null on success, [alreadyAdding] if
  /// that id is already being added, else an error message.
  Future<String?> addDevice(DiscoveredDevice discovered, String id) async {
    if (isAdding(id)) return alreadyAdding;
    _addingIds.state = {..._addingIds.state, id};
    try {
      final config = discovered.toDeviceConfig(id: id);
      await _client.addDevice(config);
      return null;
    } on ApiException catch (e) {
      // Never empty: '' means "already being added" (alreadyAdding).
      return e.message.isEmpty ? 'request failed (HTTP ${e.statusCode ?? '?'})' : e.message;
    } catch (e) {
      return e.toString();
    } finally {
      _addingIds.state = {..._addingIds.state}..remove(id);
    }
  }
}

final scanProvider = StateNotifierProvider<ScanNotifier,
    AsyncValue<List<DiscoveredDevice>>>((ref) {
  final serviceState = ref.watch(serviceProvider);
  final client = serviceState.client;
  if (client == null) {
    final placeholder = _NullClient();
    ref.onDispose(placeholder.dispose);
    return ScanNotifier(placeholder, adding: ref.read(addingDevicesProvider.notifier));
  }
  return ScanNotifier(client, adding: ref.read(addingDevicesProvider.notifier));
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
