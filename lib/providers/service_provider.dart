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
    state = const ServiceState(status: ConnectionState.scanning);
    final url = await _findService();
    if (url == null) {
      state = ServiceState(
        status: ConnectionState.error,
        errorMessage: [
          'No Roomcast FM service found on this network.',
          ?_lastConnectError,
        ].join('\n'),
      );
      return;
    }
    await connectTo(url);
  }

  /// Connect to a specific base URL (from manual entry or saved pref).
  Future<void> connectTo(String baseUrl) async {
    final client = _newClient(baseUrl);
    try {
      await client.getInfo();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, baseUrl);
      _lastConnectError = null;
      final previous = state.client;
      state = ServiceState(
        status: ConnectionState.connected,
        baseUrl: baseUrl,
        client: client,
      );
      // Close the replaced connection's HTTP client.
      if (previous != null && !identical(previous, client)) previous.dispose();
    } catch (e) {
      client.dispose(); // don't leak the failed attempt's HTTP client
      _lastConnectError = 'Could not reach service at $baseUrl: $e';
      state = ServiceState(
        status: ConnectionState.error,
        errorMessage: _lastConnectError,
      );
    }
  }

  void disconnect() {
    state.client?.dispose();
    state = const ServiceState(status: ConnectionState.idle);
  }
}

final serviceProvider =
    StateNotifierProvider<ServiceNotifier, ServiceState>((ref) {
  return ServiceNotifier(
    ref.watch(serviceFinderProvider),
    clientFactory: ref.watch(apiClientFactoryProvider),
  );
});
