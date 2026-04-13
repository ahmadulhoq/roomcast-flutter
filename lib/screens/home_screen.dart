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
                ref.read(serviceProvider.notifier).disconnect();
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const ConnectScreen()),
                );
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _ServiceStatusBar(serviceState: serviceState),
          Expanded(
            child: devicesAsync.when(
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
              data: (devices) => devices.isEmpty
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
                        itemCount: devices.length,
                        itemBuilder: (_, i) =>
                            DeviceCard(device: devices[i]),
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

class _ServiceStatusBar extends StatelessWidget {
  final ServiceState serviceState;

  const _ServiceStatusBar({required this.serviceState});

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
          Text(
            serviceState.isConnected
                ? 'Connected — ${serviceState.baseUrl}'
                : 'Not connected',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
