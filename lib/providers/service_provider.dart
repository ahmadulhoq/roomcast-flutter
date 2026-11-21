// Manages the connection to the Roomcast FM backend service.
// Persists the discovered base URL in SharedPreferences so the app
// reconnects automatically on next launch without re-scanning.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/mdns_discovery.dart';
import '../services/api_client.dart';

const _prefKey = 'service_base_url';

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
  ServiceNotifier(this._findService, {ApiClientFactory? clientFactory})
      : _newClient = clientFactory ?? RoomcastApiClient.new,
        super(const ServiceState(status: ConnectionState.idle));

  final ServiceFinder _findService;
  final ApiClientFactory _newClient;

  /// Why the last connect attempt failed (e.g. the saved address at launch),
  /// kept so a following failed scan doesn't hide it.
  String? _lastConnectError;

  /// Every scan and connect gets a number. The newest *successful* attempt
  /// wins (an older one finishing later is dropped), a failed attempt never
  /// cancels another (a mistyped manual address doesn't stop a scan that is
  /// still running), and disconnect() cancels everything started before it.
  int _attempt = 0;
  int _connectedAttempt = 0; // attempt of the current connection (0 = none)
  int _cancelledUpTo = 0;    // attempts up to this one were cancelled
  int _scansInFlight = 0;

  /// The working connection, if any. A failed attempt never drops it.
  RoomcastApiClient? _connected;

  bool _isStale(int attempt) =>
      !mounted || attempt <= _cancelledUpTo || attempt < _connectedAttempt;

  /// Try to load a previously saved URL, then connect.
  Future<void> loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefKey);
    if (saved != null) {
      await connectTo(saved);
    }
  }

  /// Scan mDNS for the backend, then connect.
  Future<void> scanAndConnect() async {
    final attempt = ++_attempt;
    _scansInFlight++;
    if (_connected == null) state = const ServiceState(status: ConnectionState.scanning);
    String? url;
    try {
      url = await _findService();
    } finally {
      _scansInFlight--;
    }
    if (_isStale(attempt) || _connectedAttempt > 0) return; // cancelled, or already connected
    if (url == null) {
      _showFailure('No Roomcast FM service found on this network.', withLastError: true);
      return;
    }
    await _connect(url, attempt);
  }

  /// Connect to a specific base URL (from manual entry or saved pref).
  Future<void> connectTo(String baseUrl) => _connect(baseUrl, ++_attempt);

  Future<void> _connect(String baseUrl, int attempt) async {
    final client = _newClient(baseUrl);
    try {
      await client.getInfo();
    } catch (e) {
      client.dispose(); // don't leak the failed attempt's HTTP client
      if (_isStale(attempt)) return;
      _lastConnectError = 'Could not reach service at $baseUrl: $e';
      _showFailure(_lastConnectError!);
      return;
    }
    // No await between this check and the switch below, so a newer attempt
    // or a disconnect can't slip in between.
    if (_isStale(attempt)) {
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
    final prefs = await SharedPreferences.getInstance();
    if (identical(_connected, client)) await prefs.setString(_prefKey, baseUrl);
  }

  /// Show a failure, unless a working connection exists (keep it) or a scan
  /// is still running (it may still find the service).
  void _showFailure(String message, {bool withLastError = false}) {
    final connected = _connected;
    if (connected != null) {
      state = ServiceState(
        status: ConnectionState.connected,
        baseUrl: connected.baseUrl,
        client: connected,
      );
      return;
    }
    if (_scansInFlight > 0) {
      state = const ServiceState(status: ConnectionState.scanning);
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

  /// Disconnect and forget the saved address, so the next launch doesn't
  /// reconnect on its own.
  Future<void> disconnect() async {
    _cancelledUpTo = _attempt; // a scan/connect still in flight must not reconnect
    _connected?.dispose();
    _connected = null;
    _connectedAttempt = 0;
    state = const ServiceState(status: ConnectionState.idle);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
  }
}

final serviceProvider =
    StateNotifierProvider<ServiceNotifier, ServiceState>((ref) {
  return ServiceNotifier(
    ref.watch(serviceFinderProvider),
    clientFactory: ref.watch(apiClientFactoryProvider),
  );
});
