import 'dart:async';

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

class _DiscoveredDeviceTile extends ConsumerStatefulWidget {
  final DiscoveredDevice device;

  const _DiscoveredDeviceTile({required this.device});

  @override
  ConsumerState<_DiscoveredDeviceTile> createState() => _DiscoveredDeviceTileState();
}

class _DiscoveredDeviceTileState extends ConsumerState<_DiscoveredDeviceTile> {
  /// An add request is in flight: a second tap would pair it again (and
  /// the backend would replace the output it just created).
  bool _adding = false;

  DiscoveredDevice get device => widget.device;

  @override
  Widget build(BuildContext context) {
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
        onPressed: _adding || ref.read(scanProvider.notifier).isAdding(device.idSuggestion)
            ? null
            : _addDevice,
        child: const Text('Add'),
      ),
    );
  }

  Future<void> _addDevice() async {
    setState(() => _adding = true);
    // Captured first: the tile can be rebuilt (e.g. "Scan again") before the
    // request finishes, and its result must still be shown and applied.
    final devices = ref.read(devicesProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final name = device.name;
    // Use id_suggestion as the device id, deduplicated at API level
    final error = await ref
        .read(scanProvider.notifier)
        .addDevice(device, device.idSuggestion);

    if (error == null) {
      if (devices.mounted) unawaited(devices.refresh()); // the paired list
      messenger.showSnackBar(SnackBar(content: Text('$name added')));
      if (mounted) navigator.pop();
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to add $name: $error'), backgroundColor: Colors.red),
      );
    }
    if (mounted) setState(() => _adding = false);
  }
}
