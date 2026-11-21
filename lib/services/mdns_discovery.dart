// Discovery of the Roomcast FM backend on the local network.
//
// Uses the platform's native service discovery through bonsoir: Bonjour
// (DNS-SD) on iOS, NsdManager on Android. (The macOS build would also need the
// network-client entitlement and the Bonjour Info.plist keys.) Raw multicast
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
    final tracker = ResolveTracker();
    var done = false;
    StreamSubscription<BonsoirDiscoveryEvent>? subscription;
    late final void Function(BonsoirService) resolve;

    void retryFailedResolves() {
      if (done || found.isCompleted) return;
      for (final service in tracker.retries()) {
        Future<void>.delayed(const Duration(milliseconds: 300), () {
          if (!done && !found.isCompleted) resolve(service);
        });
      }
    }

    // Errors here (e.g. Android NSD busy: FAILURE_ALREADY_ACTIVE) are retried,
    // never surfaced as uncaught async errors.
    resolve = (BonsoirService service) {
      unawaited(discovery.serviceResolver
          .resolveService(service)
          .catchError((Object _) => retryFailedResolves()));
    };

    try {
      await discovery.initialize();
      subscription = discovery.eventStream!.listen(
        (event) {
          switch (event) {
            case BonsoirDiscoveryServiceFoundEvent():
              if (tracker.found(event.service)) resolve(event.service);
            case BonsoirDiscoveryServiceResolvedEvent():
              tracker.resolved(event.service);
              final url = baseUrlFor(event.service);
              if (url != null && !found.isCompleted) found.complete(url);
            case BonsoirDiscoveryServiceResolveFailedEvent():
              retryFailedResolves();
            default:
              break;
          }
        },
        // Discovery itself failed (e.g. local-network permission denied):
        // stop waiting and let the caller offer manual entry.
        onError: (Object _) {
          if (!found.isCompleted) found.complete(null);
        },
      );
      await discovery.start();
      return await found.future.timeout(timeout, onTimeout: () => null);
    } catch (_) {
      return null; // no service / discovery unavailable — caller shows manual entry
    } finally {
      done = true;
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
    final txtAddress = txtIp == null ? null : InternetAddress.tryParse(txtIp);
    // A backend without a default route advertises 127.0.0.1: that would be
    // the phone itself, so fall back to the resolved host.
    var host = (txtAddress != null && _usable(txtAddress)) ? txtIp : service.host;
    if (host == null || host.isEmpty || service.port <= 0) return null;
    if (host.endsWith('.')) host = host.substring(0, host.length - 1);
    final address = InternetAddress.tryParse(host);
    if (address != null && !_usable(address)) return null;
    if (address != null && address.type == InternetAddressType.IPv6) {
      host = '[$host]';
    }
    return 'http://$host:${service.port}';
  }

  /// Not loopback, multicast or unspecified (0.0.0.0 / ::).
  static bool _usable(InternetAddress a) =>
      !a.isLoopback && !a.isMulticast && a.address != '0.0.0.0' && a.address != '::';
}

/// Decides which discovered services to resolve, and which to retry after a
/// failed resolve. Android NSD (before API 34) allows only one resolve at a
/// time and fails others with FAILURE_ALREADY_ACTIVE.
class ResolveTracker {
  ResolveTracker({this.maxAttempts = 3});

  final int maxAttempts;
  final _attempts = <String, int>{};
  final _unresolved = <String, BonsoirService>{};

  /// A service was found: true if it should be resolved now (first sighting).
  bool found(BonsoirService service) {
    if (_attempts.containsKey(service.name)) return false;
    _attempts[service.name] = 1;
    _unresolved[service.name] = service;
    return true;
  }

  void resolved(BonsoirService service) => _unresolved.remove(service.name);

  /// After a failed resolve: the unresolved services with attempts left.
  List<BonsoirService> retries() {
    final result = <BonsoirService>[];
    for (final entry in _unresolved.entries) {
      final attempts = _attempts[entry.key]!;
      if (attempts < maxAttempts) {
        _attempts[entry.key] = attempts + 1;
        result.add(entry.value);
      }
    }
    return result;
  }
}
