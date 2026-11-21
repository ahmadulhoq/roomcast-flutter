import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/devices_provider.dart';
import '../providers/service_provider.dart';
import '../widgets/device_card.dart';
import 'scan_screen.dart';
import 'connect_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serviceState = ref.watch(serviceProvider);
    final devicesAsync = ref.watch(devicesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Roomcast FM'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => ref.read(devicesProvider.notifier).refresh(),
          ),
          PopupMenuButton(
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'disconnect',
                child: Text('Disconnect'),
              ),
            ],
            onSelected: (v) {
              if (v == 'disconnect') {
                unawaited(ref.read(serviceProvider.notifier).disconnect());
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    // The user chose to disconnect: don't auto-reconnect.
                    builder: (_) => const ConnectScreen(autoScan: false),
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _ServiceStatusBar(
            serviceState: serviceState,
            // Unknown while the backend can't be reached (don't show stale state).
            streaming: devicesAsync.hasError ? null : devicesAsync.valueOrNull?.streaming,
          ),
          // A failed background refresh keeps the last list on screen (so a
          // Wi-Fi blip doesn't cut off a volume drag) and shows this banner.
          if (devicesAsync.hasError && devicesAsync.hasValue)
            const _OfflineBanner(),
          Expanded(
            child: devicesAsync.when(
              skipError: true, // error view only when there is no list to show
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline, size: 48, color: Colors.red),
                    const SizedBox(height: 12),
                    Text('Failed to load devices: $e',
                        textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () =>
                          ref.read(devicesProvider.notifier).refresh(),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
              data: (snapshot) => snapshot.devices.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.speaker,
                              size: 64, color: Colors.grey),
                          const SizedBox(height: 16),
                          const Text('No speakers added yet.'),
                          const SizedBox(height: 8),
                          const Text(
                            'Tap + to scan for speakers on your network.',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: () =>
                          ref.read(devicesProvider.notifier).refresh(),
                      child: ListView.builder(
                        itemCount: snapshot.devices.length,
                        itemBuilder: (_, i) => DeviceCard(
                          key: ValueKey(snapshot.devices[i].id),
                          device: snapshot.devices[i],
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ScanScreen()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Add Speaker'),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.orange.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.wifi_off, size: 16, color: Colors.orange.shade800),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "Can't reach Roomcast FM — showing the last known state, retrying…",
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.orange.shade900),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceStatusBar extends StatelessWidget {
  final ServiceState serviceState;

  /// Whether the backend is streaming audio (null = not known yet).
  final bool? streaming;

  const _ServiceStatusBar({required this.serviceState, this.streaming});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.deepPurple.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.circle,
              size: 10,
              color: serviceState.isConnected ? Colors.green : Colors.grey),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              serviceState.isConnected
                  ? 'Connected — ${serviceState.baseUrl}'
                  : 'Not connected',
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (serviceState.isConnected && streaming != null) ...[
            Icon(
              streaming! ? Icons.graphic_eq : Icons.pause_circle_outline,
              size: 16,
              color: streaming! ? Colors.green : Colors.grey,
            ),
            const SizedBox(width: 4),
            Text(
              streaming! ? 'Streaming' : 'Idle',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: streaming! ? Colors.green.shade700 : Colors.grey,
                  ),
            ),
          ],
        ],
      ),
    );
  }
}
