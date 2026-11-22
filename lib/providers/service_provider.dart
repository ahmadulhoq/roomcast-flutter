// Manages the connection to the Roomcast FM backend service.
// Persists the discovered base URL in SharedPreferences so the app
// reconnects automatically on next launch without re-scanning.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/mdns_discovery.dart';
import '../services/api_client.dart';
import '../services/base_url.dart';

const _prefKey = 'service_base_url';

/// Set by an explicit Disconnect, cleared by the next successful connect: the
/// app then doesn't scan (and reconnect) on its own at launch.
const _disconnectedKey = 'user_disconnected';

enum ConnectionState { idle, scanning, connected, error }

class ServiceState {
  final ConnectionState status;
  final String? baseUrl;
  final RoomcastApiClient? client;
  final String? errorMessage;

  const ServiceState({
    required this.status,
    this.baseUrl,
    this.client,
    this.errorMessage,
  });

  ServiceState copyWith({
    ConnectionState? status,
    String? baseUrl,
    RoomcastApiClient? client,
    String? errorMessage,
  }) {
    return ServiceState(
      status: status ?? this.status,
      baseUrl: baseUrl ?? this.baseUrl,
      client: client ?? this.client,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  bool get isConnected => status == ConnectionState.connected && client != null;
}

/// Finds the backend on the network; returns its base URL or null.
typedef ServiceFinder = Future<String?> Function();

/// Overridable in tests (the real finder needs the platform plugin).
final serviceFinderProvider =
    Provider<ServiceFinder>((ref) => ServiceDiscovery.findService);

/// Creates the REST client for a base URL (overridable in tests).
typedef ApiClientFactory = RoomcastApiClient Function(String baseUrl);

final apiClientFactoryProvider =
    Provider<ApiClientFactory>((ref) => RoomcastApiClient.new);

class ServiceNotifier extends StateNotifier<ServiceState> {
  ServiceNotifier(this._findService,
      {ApiClientFactory? clientFactory, Future<SharedPreferences> Function()? preferences})
      : _newClient = clientFactory ?? RoomcastApiClient.new,
        _preferences = preferences ?? SharedPreferences.getInstance,
        super(const ServiceState(status: ConnectionState.idle));

  final ServiceFinder _findService;
  final ApiClientFactory _newClient;
  final Future<SharedPreferences> Function() _preferences;

  /// Preference writes run one after another, in the order they were
  /// asked for (a Disconnect's writes can't land after a later connect's),
  /// and a failing one never breaks connecting or disconnecting.
  Future<void> _prefsWrites = Future<void>.value();

  Future<void> _writePrefs(Future<void> Function(SharedPreferences prefs) write) {
    final next = _prefsWrites.then((_) async {
      try {
        await write(await _preferences());
      } catch (_) {
        // Not saved: the app still works, it just won't remember this.
      }
    });
    _prefsWrites = next;
    return next;
  }

  /// A preference read; null if preferences can't be read.
  Future<SharedPreferences?> _readPrefs() async {
    try {
      return await _preferences();
    } catch (_) {
      return null;
    }
  }

  /// Why the last connect attempt failed (e.g. the saved address at launch),
  /// kept so a following failed scan doesn't hide it. A new scan forgets an
  /// older failed attempt, except the saved address's failure at launch: that
  /// one stays (it says why the app didn't reconnect) until a connect
  /// succeeds or another attempt fails.
  String? _lastConnectError;
  bool _lastConnectErrorIsSaved = false;

  /// Every scan and connect gets a number. The newest *successful* attempt
  /// wins (an older one finishing later is dropped), a failed attempt never
  /// cancels another (a mistyped manual address doesn't stop a scan that is
  /// still running), and disconnect() cancels everything started before it.
  int _attempt = 0;
  int _connectedAttempt = 0; // attempt of the current connection (0 = none)
  int _cancelledUpTo = 0;    // attempts up to this one were cancelled

  /// Attempt numbers of the scans still running. One cancelled by
  /// disconnect() doesn't count: it can no longer connect.
  final _scans = <int>{};

  bool get _scanRunning => _scans.any((attempt) => attempt > _cancelledUpTo);

  /// The working connection, if any. A failed attempt never drops it.
  RoomcastApiClient? _connected;

  bool _isStale(int attempt) =>
      !mounted || attempt <= _cancelledUpTo || attempt < _connectedAttempt;

  /// True if the user disconnected and hasn't connected since.
  Future<bool> userDisconnected() async =>
      (await _readPrefs())?.getBool(_disconnectedKey) ?? false;

  /// Try to load a previously saved URL, then connect.
  Future<void> loadSaved() async {
    final saved = (await _readPrefs())?.getString(_prefKey);
    if (saved != null) {
      // Older versions saved what was typed ("http://x:8888/" → "//api/info"
      // 404s); a successful connect saves the normalized URL.
      final url = normalizeBaseUrl(saved);
      if (url == null) {
        // Not a usable address — or one with a user name and password, which
        // must not be shown or kept in plain text: forget it.
        await _writePrefs((prefs) async => prefs.remove(_prefKey));
        return;
      }
      await _connect(url, ++_attempt, savedAddress: true);
    }
  }

  /// Scan mDNS for the backend, then connect.
  Future<void> scanAndConnect() async {
    final attempt = ++_attempt;
    _scans.add(attempt);
    // An older failed attempt isn't this scan's business — except the saved
    // address's, kept until a connect succeeds or another attempt fails.
    if (!_lastConnectErrorIsSaved) _lastConnectError = null;
    if (_connected == null) state = const ServiceState(status: ConnectionState.scanning);
    // The scan counts as running until its own connect is done too, so a
    // manual connect failing meanwhile is shown next to its progress.
    try {
      String? url;
      try {
        url = await _findService();
      } catch (_) {
        url = null; // discovery itself broke: same as finding nothing
      }
      if (_isStale(attempt) || _connectedAttempt > 0) return; // cancelled, or already connected
      if (url == null) {
        _scans.remove(attempt);
        _showFailure('No Roomcast FM service found on this network.', withLastError: true);
        return;
      }
      await _connect(url, attempt);
    } finally {
      _scans.remove(attempt);
    }
  }

  /// Connect to a specific base URL (from manual entry or saved pref).
  Future<void> connectTo(String baseUrl) => _connect(baseUrl, ++_attempt);

  Future<void> _connect(String baseUrl, int attempt, {bool savedAddress = false}) async {
    final client = _newClient(baseUrl);
    try {
      await client.getInfo();
    } catch (e) {
      client.dispose(); // don't leak the failed attempt's HTTP client
      _scans.remove(attempt); // a scan's own connect failed: it's over
      if (_isStale(attempt)) return;
      final message = 'Could not reach service at $baseUrl: $e';
      // Kept to show with a later failed scan, but only if it's why there is
      // no connection (not a failed attempt while connected).
      if (_connected == null) {
        _lastConnectError = message;
        _lastConnectErrorIsSaved = savedAddress;
      }
      _showFailure(message);
      return;
    }
    // No await between this check and the switch below, so a newer attempt
    // or a disconnect can't slip in between.
    if (_isStale(attempt)) {
      client.dispose();
      return;
    }
    if (_connected != null && _connected!.baseUrl == baseUrl) {
      // Already connected to this backend (e.g. a manual connect to the
      // address the scan found): keep the working connection rather than
      // rebuilding everything and cutting off its requests.
      client.dispose();
      return;
    }
    final previous = _connected;
    _connected = client;
    _connectedAttempt = attempt;
    _lastConnectError = null;
    state = ServiceState(
      status: ConnectionState.connected,
      baseUrl: baseUrl,
      client: client,
    );
    // Close the replaced connection's HTTP client.
    if (previous != null && !identical(previous, client)) previous.dispose();
    await _writePrefs((prefs) async {
      // Checked when the write runs: a Disconnect since must win.
      if (identical(_connected, client)) await prefs.setString(_prefKey, baseUrl);
      if (identical(_connected, client)) await prefs.remove(_disconnectedKey);
    });
  }

  /// Show a failure. With a working connection nothing changes (the state
  /// is left as it is, so nothing watching it is rebuilt). While a scan is
  /// still running (it may still find the service) the message is shown
  /// next to its progress.
  void _showFailure(String message, {bool withLastError = false}) {
    if (_connected != null) return;
    if (_scanRunning) {
      state = ServiceState(status: ConnectionState.scanning, errorMessage: message);
      return;
    }
    state = ServiceState(
      status: ConnectionState.error,
      errorMessage: [
        message,
        if (withLastError && _lastConnectError != message) ?_lastConnectError,
      ].join('\n'),
    );
  }

  @override
  void dispose() {
    _cancelledUpTo = _attempt; // an attempt finishing later must not connect
    _connected?.dispose();     // close the live connection's HTTP client
    _connected = null;
    super.dispose();
  }

  /// Disconnect and forget the saved address; the next launch doesn't scan
  /// or reconnect on its own either.
  Future<void> disconnect() async {
    _cancelledUpTo = _attempt; // a scan/connect still in flight must not reconnect
    _lastConnectError = null;
    _connected?.dispose();
    _connected = null;
    _connectedAttempt = 0;
    state = const ServiceState(status: ConnectionState.idle);
    await _writePrefs((prefs) async {
      await prefs.remove(_prefKey);
      await prefs.setBool(_disconnectedKey, true);
    });
  }
}

final serviceProvider =
    StateNotifierProvider<ServiceNotifier, ServiceState>((ref) {
  return ServiceNotifier(
    ref.watch(serviceFinderProvider),
    clientFactory: ref.watch(apiClientFactoryProvider),
  );
});
