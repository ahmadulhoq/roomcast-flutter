// mDNS discovery of the Roomcast FM backend service.
// Scans for _roomcast._tcp.local. and returns the first result as a
// base URL (e.g. http://192.168.1.10:8888).

import 'dart:async';
import 'package:multicast_dns/multicast_dns.dart';

const _serviceType = '_roomcast._tcp';
const _scanTimeout = Duration(seconds: 8);

class ServiceDiscovery {
  /// Scan the local network for a Roomcast FM backend.
  ///
  /// Returns the base URL (http://ip:port) of the first service found,
  /// or null if none found within the timeout.
  static Future<String?> findService() async {
    final client = MDnsClient();
    await client.start();

    try {
      // 1. Find PTR records for the service type
      await for (final PtrResourceRecord ptr in client
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer(_serviceType),
          )
          .timeout(_scanTimeout, onTimeout: (_) {})) {
        // 2. Resolve the SRV record for the instance name
        await for (final SrvResourceRecord srv in client
            .lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(ptr.domainName),
            )
            .timeout(const Duration(seconds: 3), onTimeout: (_) {})) {
          // 3. Resolve IP from the SRV target hostname
          await for (final IPAddressResourceRecord ip in client
              .lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(srv.target),
              )
              .timeout(const Duration(seconds: 3), onTimeout: (_) {})) {
            client.stop();
            return 'http://${ip.address.address}:${srv.port}';
          }
        }
      }
    } on TimeoutException {
      // No service found in time
    } catch (_) {
      // Ignore scan errors
    } finally {
      client.stop();
    }

    return null;
  }
}
