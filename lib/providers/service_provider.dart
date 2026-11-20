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

class ServiceNotifier extends StateNotifier<ServiceState> {
  ServiceNotifier(this._findService)
      : super(const ServiceState(status: ConnectionState.idle));

  final ServiceFinder _findService;

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
      state = const ServiceState(
        status: ConnectionState.error,
        errorMessage: 'No Roomcast FM service found on this network.',
      );
      return;
    }
    await connectTo(url);
  }

  /// Connect to a specific base URL (from manual entry or saved pref).
  Future<void> connectTo(String baseUrl) async {
    final client = RoomcastApiClient(baseUrl);
    try {
      await client.getInfo();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, baseUrl);
      state = ServiceState(
        status: ConnectionState.connected,
        baseUrl: baseUrl,
        client: client,
      );
    } catch (e) {
      state = ServiceState(
        status: ConnectionState.error,
        errorMessage: 'Could not reach service at $baseUrl: $e',
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
  return ServiceNotifier(ref.watch(serviceFinderProvider));
});
