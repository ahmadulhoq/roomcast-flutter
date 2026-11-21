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
const _stopTimeout = Duration(seconds: 2);

class ServiceDiscovery {
  /// Scan the local network for a Roomcast FM backend.
  ///
  /// Returns the base URL (http://ip:port) of the first service found,
  /// or null if none is found within [timeout] (which covers the whole scan,
  /// a platform call that never answers included) or discovery fails.
  static Future<String?> findService({Duration timeout = _scanTimeout}) async {
    final discovery = BonsoirDiscovery(type: serviceType);
    final found = Completer<String?>();
    final tracker = ResolveTracker();
    var done = false;
    StreamSubscription<BonsoirDiscoveryEvent>? subscription;
    late final void Function() onResolveFailed;

    // Resolve one service at a time (Android NSD before API 34 allows only
    // one), so a failure can be attributed to the service being resolved.
    void pump() {
      if (done || found.isCompleted) return;
      final service = tracker.next();
      if (service == null) return;
      unawaited(discovery.serviceResolver
          .resolveService(service)
          .catchError((Object _) => onResolveFailed()));
    }

    void handleResolved(BonsoirService service) {
      tracker.resolved(service);
      final url = baseUrlFor(service);
      if (url != null && !found.isCompleted) {
        found.complete(url);
      } else {
        pump();
      }
    }

    // One failure can be reported twice (an exception and an event); the
    // delay lets the second report find nothing in flight.
    onResolveFailed = () {
      if (done) return;
      tracker.failed();
      Future<void>.delayed(const Duration(milliseconds: 300), pump);
    };

    Future<String?> scan() async {
      await discovery.initialize();
      if (done) return null; // timed out meanwhile
      subscription = discovery.eventStream!.listen(
        (event) {
          switch (event) {
            case BonsoirDiscoveryServiceFoundEvent():
              tracker.found(event.service);
              pump();
            case BonsoirDiscoveryServiceResolvedEvent():
              handleResolved(event.service);
            case BonsoirDiscoveryServiceUpdatedEvent():
              // e.g. TXT attributes (the backend's "ip") arriving after
              // resolve. iOS also reports TXT changes of services not
              // resolved yet: only a usable address counts as a resolve,
              // otherwise the service stays queued.
              if (baseUrlFor(event.service) != null) handleResolved(event.service);
            case BonsoirDiscoveryServiceResolveFailedEvent():
              onResolveFailed();
            case BonsoirDiscoveryServiceLostEvent():
              tracker.lost(event.service);
              pump();
            default:
              break;
          }
        },
        // bonsoir reports fatal discovery errors and per-service resolve
        // problems the same way (code "discoveryError"). While a resolve is
        // in flight treat it as that resolve failing; otherwise discovery
        // itself failed (e.g. permission denied): stop and offer manual entry.
        onError: (Object _) {
          if (tracker.resolving) {
            onResolveFailed();
          } else if (!tracker.everFound && !found.isCompleted) {
            found.complete(null);
          }
          // Otherwise (e.g. Android "Failed to register service info callback"
          // right after a resolve): not fatal, keep going until the timeout.
        },
      );
      await discovery.start();
      if (done) {
        // Timed out while starting: the stop in `finally` came too early.
        try {
          await discovery.stop().timeout(_stopTimeout);
        } catch (_) {}
        return null;
      }
      return found.future;
    }

    try {
      return await scan().timeout(timeout, onTimeout: () => null);
    } catch (_) {
      return null; // no service / discovery unavailable — caller shows manual entry
    } finally {
      done = true;
      await subscription?.cancel();
      try {
        await discovery.stop().timeout(_stopTimeout);
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
    // InternetAddress.tryParse rejects a zone ID (Android NSD reports
    // link-local IPv6 as "fe80::1%wlan0"), so parse without it — otherwise
    // the address isn't bracketed and the URL doesn't parse.
    final address = InternetAddress.tryParse(host.split('%').first);
    if (address != null && !_usable(address)) return null;
    if (address != null && address.type == InternetAddressType.IPv6) {
      host = '[$host]'; // Uri.parse encodes the zone's '%' as %25
    }
    return 'http://$host:${service.port}';
  }

  /// Not loopback, multicast or unspecified (0.0.0.0 / ::).
  static bool _usable(InternetAddress a) =>
      !a.isLoopback && !a.isMulticast && a.address != '0.0.0.0' && a.address != '::';
}

/// Decides which discovered service to resolve next. Resolves run one at a
/// time; a failed one is retried (up to [maxAttempts]) after the others
/// waiting in the queue. Android NSD before API 34 allows only one resolve at
/// a time and fails others with FAILURE_ALREADY_ACTIVE.
class ResolveTracker {
  ResolveTracker({this.maxAttempts = 3});

  final int maxAttempts;
  final _attempts = <String, int>{};
  final _queue = <BonsoirService>[];
  BonsoirService? _inFlight;

  /// True while a resolve started by [next] hasn't finished.
  bool get resolving => _inFlight != null;

  /// True once any service has been found, even if it was lost again:
  /// discovery itself works, so a later error isn't fatal.
  bool get everFound => _everFound;
  bool _everFound = false;

  /// A service was found: queue it (once; a re-announce of a known service
  /// is ignored until it is lost).
  void found(BonsoirService service) {
    _everFound = true;
    if (_attempts.containsKey(service.name)) return;
    _attempts[service.name] = 0;
    _queue.add(service);
  }

  /// The next service to resolve, or null if one is in flight or none waits.
  BonsoirService? next() {
    if (_inFlight != null || _queue.isEmpty) return null;
    final service = _queue.removeAt(0);
    _attempts[service.name] = _attempts[service.name]! + 1;
    return _inFlight = service;
  }

  void resolved(BonsoirService service) {
    if (_inFlight?.name == service.name) _inFlight = null;
    _queue.removeWhere((s) => s.name == service.name);
  }

  /// The in-flight resolve failed: re-queue it if it has attempts left.
  /// A no-op if nothing is in flight (e.g. a second report of one failure).
  void failed() {
    final service = _inFlight;
    if (service == null) return;
    _inFlight = null;
    if (_attempts[service.name]! < maxAttempts) _queue.add(service);
  }

  /// The service went away: forget it (a later re-announce starts afresh).
  void lost(BonsoirService service) {
    _queue.removeWhere((s) => s.name == service.name);
    if (_inFlight?.name == service.name) _inFlight = null;
    _attempts.remove(service.name);
  }
}
