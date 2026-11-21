// REST API client for the Roomcast FM backend.
// All methods throw [ApiException] on non-2xx responses or network errors.

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/device.dart';

class ApiException implements Exception {
  final int? statusCode;
  final String message;
  ApiException(this.message, {this.statusCode});

  @override
  String toString() => statusCode != null
      ? 'ApiException($statusCode): $message'
      : 'ApiException: $message';
}

class RoomcastApiClient {
  final String baseUrl;
  final http.Client _http;

  RoomcastApiClient(this.baseUrl) : _http = http.Client();

  // ------------------------------------------------------------------
  // Service info
  // ------------------------------------------------------------------

  Future<Map<String, dynamic>> getInfo() => _get('/api/info');

  // ------------------------------------------------------------------
  // Device scan
  // ------------------------------------------------------------------

  /// Trigger a network scan. Returns list of discovered devices.
  Future<List<DiscoveredDevice>> scan() async {
    final data = await _get('/api/scan');
    final list = data['devices'] as List<dynamic>? ?? [];
    return list
        .cast<Map<String, dynamic>>()
        .map(DiscoveredDevice.fromJson)
        .toList();
  }

  // ------------------------------------------------------------------
  // Paired devices
  // ------------------------------------------------------------------

  /// All paired devices with their live status, plus whether audio is streaming.
  Future<DevicesSnapshot> getDevices() async {
    return DevicesSnapshot.fromJson(await _get('/api/devices'));
  }

  /// Add (pair) a new device. Config must include id + type.
  Future<void> addDevice(Map<String, dynamic> config) async {
    await _post('/api/devices', config);
  }

  /// Remove (unpair) a device by id.
  Future<void> removeDevice(String id) async {
    try {
      final response = await _http
          .delete(Uri.parse('$baseUrl/api/devices/${Uri.encodeComponent(id)}'))
          .timeout(const Duration(seconds: 10));
      _checkStatus(response);
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException('Network error: $e');
    }
  }

  // ------------------------------------------------------------------
  // Device control
  // ------------------------------------------------------------------

  Future<void> setVolume(String id, int level) async {
    await _post('/api/devices/${Uri.encodeComponent(id)}/volume', {'level': level});
  }

  Future<void> enableDevice(String id) async {
    await _post('/api/devices/${Uri.encodeComponent(id)}/enable', {});
  }

  Future<void> disableDevice(String id) async {
    await _post('/api/devices/${Uri.encodeComponent(id)}/disable', {});
  }

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------

  Future<Map<String, dynamic>> _get(String path) async {
    try {
      final response = await _http
          .get(Uri.parse('$baseUrl$path'))
          .timeout(const Duration(seconds: 10));
      _checkStatus(response);
      return json.decode(response.body) as Map<String, dynamic>;
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException('Network error: $e');
    }
  }

  Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body) async {
    try {
      final response = await _http
          .post(
            Uri.parse('$baseUrl$path'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(body),
          )
          .timeout(const Duration(seconds: 10));
      _checkStatus(response);
      return json.decode(response.body) as Map<String, dynamic>;
    } on ApiException {
      rethrow;
    } catch (e) {
      throw ApiException('Network error: $e');
    }
  }

  void _checkStatus(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String message = 'HTTP ${response.statusCode}';
      try {
        final body = json.decode(response.body) as Map<String, dynamic>;
        message = body['error'] as String? ?? message;
      } catch (_) {}
      throw ApiException(message, statusCode: response.statusCode);
    }
  }

  void dispose() => _http.close();
}
