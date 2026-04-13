import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../models/device.dart';
import '../providers/devices_provider.dart';

class DeviceCard extends ConsumerWidget {
  final PairedDevice device;

  const DeviceCard({super.key, required this.device});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(devicesProvider.notifier);

    return Slidable(
      key: ValueKey(device.id),
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.25,
        children: [
          SlidableAction(
            onPressed: (_) => notifier.remove(device.id),
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
            icon: Icons.delete_outline,
            label: 'Remove',
          ),
        ],
      ),
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _typeIcon(device),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      device.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  _statusDot(device.state),
                  const SizedBox(width: 6),
                  Text(
                    _stateLabel(device.state),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _stateColor(device.state),
                        ),
                  ),
                ],
              ),
              if (device.error != null) ...[
                const SizedBox(height: 4),
                Text(
                  device.error!,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.red),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.volume_down, size: 18, color: Colors.grey),
                  Expanded(
                    child: Slider(
                      value: device.volume.toDouble(),
                      min: 0,
                      max: 100,
                      divisions: 20,
                      onChangeEnd: (v) =>
                          notifier.setVolume(device.id, v.round()),
                      onChanged: (_) {}, // visual only during drag
                    ),
                  ),
                  const Icon(Icons.volume_up, size: 18, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text('${device.volume}',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _typeIcon(PairedDevice d) {
    // Infer type from state/name heuristic — could be extended with stored type
    return const Icon(Icons.speaker, size: 22, color: Colors.blueGrey);
  }

  Widget _statusDot(DeviceState state) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: _stateColor(state),
        shape: BoxShape.circle,
      ),
    );
  }

  Color _stateColor(DeviceState state) {
    switch (state) {
      case DeviceState.playing:
        return Colors.green;
      case DeviceState.connecting:
        return Colors.orange;
      case DeviceState.error:
        return Colors.red;
      case DeviceState.disabled:
        return Colors.grey;
      default:
        return Colors.grey.shade400;
    }
  }

  String _stateLabel(DeviceState state) {
    switch (state) {
      case DeviceState.playing:
        return 'Playing';
      case DeviceState.connecting:
        return 'Connecting…';
      case DeviceState.error:
        return 'Error';
      case DeviceState.disabled:
        return 'Disabled';
      case DeviceState.idle:
        return 'Idle';
      default:
        return '';
    }
  }
}
