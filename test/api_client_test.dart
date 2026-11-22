// RoomcastApiClient against a local HTTP server (plain tests: real sockets).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:roomcast_fm/services/api_client.dart';

void main() {
  test('device ids are encoded in request paths', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final paths = <String>[];
    server.listen((request) async {
      paths.add(request.uri.toString());
      request.response
        ..headers.contentType = ContentType.json
        ..write('{"ok": true}');
      await request.response.close();
    });
    final client = RoomcastApiClient('http://127.0.0.1:${server.port}');
    try {
      // Ids paired before the backend checked them can hold '#', '/', ' '.
      await client.enableDevice('kef#2');
      await client.setVolume('a/b c', 30);
    } finally {
      client.dispose();
      await server.close(force: true);
    }
    expect(paths, ['/api/devices/kef%232/enable', '/api/devices/a%2Fb%20c/volume']);
  });
}
