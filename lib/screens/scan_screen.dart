import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/device.dart';
import '../providers/devices_provider.dart';

class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  @override
  void initState() {
    super.initState();
    // Kick off scan immediately on open
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(scanProvider.notifier).scan();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scanState = ref.watch(scanProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Speakers'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Scan again',
            onPressed: () => ref.read(scanProvider.notifier).scan(),
          ),
        ],
      ),
      body: scanState.when(
        loading: () => const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Scanning your network for speakers…'),
            ],
          ),
        ),
        error: (e, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text('Scan failed: $e', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => ref.read(scanProvider.notifier).scan(),
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
                    const Icon(Icons.speaker_notes_off,
                        size: 48, color: Colors.grey),
                    const SizedBox(height: 12),
                    const Text('No speakers found on this network.'),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: () => ref.read(scanProvider.notifier).scan(),
                      icon: const Icon(Icons.search),
                      label: const Text('Scan Again'),
                    ),
                  ],
                ),
              )
            : ListView.builder(
                itemCount: devices.length,
                itemBuilder: (context, i) =>
                    _DiscoveredDeviceTile(device: devices[i]),
              ),
      ),
    );
  }
}

class _DiscoveredDeviceTile extends ConsumerWidget {
  final DiscoveredDevice device;

  const _DiscoveredDeviceTile({required this.device});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: Icon(
        device.type == DeviceType.chromecast
            ? Icons.cast
            : Icons.speaker,
        color: Colors.deepPurple,
      ),
      title: Text(device.name),
      subtitle: Text(
        device.type == DeviceType.chromecast ? 'Google Cast' : 'DLNA / UPnP',
      ),
      trailing: FilledButton(
        onPressed: () => _addDevice(context, ref),
        child: const Text('Add'),
      ),
    );
  }

  Future<void> _addDevice(BuildContext context, WidgetRef ref) async {
    // Use id_suggestion as the device id, deduplicated at API level
    final ok = await ref
        .read(scanProvider.notifier)
        .addDevice(device, device.idSuggestion);

    if (!context.mounted) return;

    if (ok) {
      // Refresh paired list
      ref.read(devicesProvider.notifier).refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${device.name} added')),
      );
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to add ${device.name}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
