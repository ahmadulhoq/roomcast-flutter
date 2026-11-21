import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../models/device.dart';
import '../providers/devices_provider.dart';
import '../services/api_client.dart';

class DeviceCard extends ConsumerStatefulWidget {
  final PairedDevice device;

  const DeviceCard({super.key, required this.device});

  @override
  ConsumerState<DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends ConsumerState<DeviceCard> {
  /// Slider position while the user drags (the slider follows the finger);
  /// null when not dragging, then the device's volume is shown.
  double? _dragVolume;

  /// True while the user's finger is on the slider.
  bool _dragging = false;

  /// True while an enable/disable request is in flight.
  bool _togglingEnabled = false;

  PairedDevice get device => widget.device;

  DevicesNotifier get _notifier => ref.read(devicesProvider.notifier);

  /// Run an API action; show [failure] + the server's message on error.
  /// Pass [messenger] and [notifier] when the card may be gone by the time it
  /// fails. Nothing is shown if the notifier was disposed meanwhile (the app
  /// disconnected or switched to another backend): that failure is moot.
  Future<void> _run(Future<void> Function() action, String failure,
      {ScaffoldMessengerState? messenger, DevicesNotifier? notifier}) async {
    final owner = notifier ?? _notifier;
    try {
      await action();
    } catch (e) {
      if (!owner.mounted) return;
      final target = messenger ?? (mounted ? ScaffoldMessenger.of(context) : null);
      if (target == null) return;
      final message = e is ApiException ? e.message : e.toString();
      target.showSnackBar(
        SnackBar(content: Text('$failure: $message'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _confirmRemove() async {
    // Read the notifier before awaiting the dialog: the card may be disposed
    // while it is open (list refresh), and `ref` can't be used after that.
    final notifier = _notifier;
    final messenger = ScaffoldMessenger.of(context);
    final name = device.name;
    final id = device.id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $name?'), // captured: the card may be gone by now
        content: const Text(
            'It stops playing and is unpaired. You can add it again with Add Speaker.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(() => notifier.remove(id), 'Could not remove $name',
          messenger: messenger, notifier: notifier);
    }
  }

  Future<void> _setEnabled(bool enabled) async {
    setState(() => _togglingEnabled = true);
    await _run(
      () => _notifier.setEnabled(device.id, enabled),
      enabled ? 'Could not enable ${device.name}' : 'Could not disable ${device.name}',
    );
    if (mounted) setState(() => _togglingEnabled = false);
  }

  Future<void> _setVolume(double value) async {
    _dragging = false;
    await _run(() => _notifier.setVolume(device.id, value.round()), 'Could not set volume');
    // A new drag may have started while this request was in flight: keep
    // following the finger instead of jumping back.
    if (mounted && !_dragging) setState(() => _dragVolume = null);
  }

  @override
  Widget build(BuildContext context) {
    final volume = _dragVolume ?? device.volume.toDouble().clamp(0, 100).toDouble();

    return Slidable(
      key: ValueKey(device.id),
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.25,
        children: [
          SlidableAction(
            onPressed: (_) => _confirmRemove(),
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
                  _typeIcon(device.type),
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
                  const SizedBox(width: 4),
                  // Named for screen readers ("Switch, on" alone doesn't say
                  // which speaker it turns off).
                  MergeSemantics(
                    child: Semantics(
                      label: 'Enable ${device.name}',
                      child: Switch(
                        value: device.enabled,
                        onChanged: _togglingEnabled ? null : _setEnabled,
                      ),
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
                      value: volume,
                      min: 0,
                      max: 100,
                      divisions: 20,
                      onChangeStart: (_) => _dragging = true,
                      onChanged: (v) => setState(() => _dragVolume = v),
                      onChangeEnd: _setVolume,
                    ),
                  ),
                  const Icon(Icons.volume_up, size: 18, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text('${volume.round()}',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _typeIcon(DeviceType type) {
    switch (type) {
      case DeviceType.chromecast:
        return const Icon(Icons.cast, size: 22, color: Colors.blueGrey, semanticLabel: 'Google Cast');
      case DeviceType.dlna:
        return const Icon(Icons.speaker, size: 22, color: Colors.blueGrey, semanticLabel: 'DLNA speaker');
      case DeviceType.unknown:
        return const Icon(Icons.speaker_group, size: 22, color: Colors.blueGrey);
    }
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
