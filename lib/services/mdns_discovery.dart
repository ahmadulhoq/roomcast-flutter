// Discovery of the Roomcast FM backend on the local network.
//
// Uses the platform's native service discovery through bonsoir: Bonjour
// (NSNetService/DNS-SD) on iOS and macOS, NsdManager on Android. Raw multicast
// sockets (the multicast_dns package) need Apple's restricted multicast
// entitlement on iOS 14+ and a WifiManager.MulticastLock on Android; the
// native APIs need neither — only NSBonjourServices (_roomcast._tcp) and
// NSLocalNetworkUsageDescription in Info.plist.

import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

const serviceType = '_roomcast._tcp';
const _scanTimeout = Duration(seconds: 8);

class ServiceDiscovery {
  /// Scan the local network for a Roomcast FM backend.
  ///
  /// Returns the base URL (http://ip:port) of the first service found,
  /// or null if none is found within [timeout] or discovery fails.
  static Future<String?> findService({Duration timeout = _scanTimeout}) async {
    final discovery = BonsoirDiscovery(type: serviceType);
    final found = Completer<String?>();
    StreamSubscription<BonsoirDiscoveryEvent>? subscription;
    try {
      await discovery.initialize();
      subscription = discovery.eventStream!.listen((event) {
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent():
            discovery.serviceResolver.resolveService(event.service);
          case BonsoirDiscoveryServiceResolvedEvent():
            final url = baseUrlFor(event.service);
            if (url != null && !found.isCompleted) found.complete(url);
          default:
            break;
        }
      });
      await discovery.start();
      return await found.future.timeout(timeout, onTimeout: () => null);
    } catch (_) {
      return null; // no service / discovery unavailable — caller shows manual entry
    } finally {
      await subscription?.cancel();
      try {
        await discovery.stop();
      } catch (_) {}
    }
  }

  /// Base URL for a resolved service.
  ///
  /// Prefers the IP the backend publishes in its TXT record ("ip"), so no
  /// `.local` host name has to be resolved; falls back to the resolved host
  /// (an IP on Android, a host name such as `roomcast-fm.local.` on iOS).
  static String? baseUrlFor(BonsoirService service) {
    final txtIp = service.attributes['ip'];
    var host = (txtIp != null && InternetAddress.tryParse(txtIp) != null)
        ? txtIp
        : service.host;
    if (host == null || host.isEmpty || service.port <= 0) return null;
    if (host.endsWith('.')) host = host.substring(0, host.length - 1);
    final address = InternetAddress.tryParse(host);
    if (address != null && address.type == InternetAddressType.IPv6) {
      host = '[$host]';
    }
    return 'http://$host:${service.port}';
  }
}
