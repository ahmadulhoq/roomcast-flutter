import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/service_provider.dart' as sp;
import 'home_screen.dart';

class ConnectScreen extends ConsumerStatefulWidget {
  /// Scan for the backend as soon as the screen opens (off after an explicit
  /// Disconnect, so the app doesn't reconnect straight away).
  final bool autoScan;

  const ConnectScreen({super.key, this.autoScan = true});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _ipController = TextEditingController();
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoScan) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final state = ref.read(sp.serviceProvider);
        if (state.status != sp.ConnectionState.scanning && !state.isConnected) {
          ref.read(sp.serviceProvider.notifier).scanAndConnect();
        }
      });
    }
  }

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final serviceState = ref.watch(sp.serviceProvider);

    // Navigate to home once connected — once, even if two attempts succeed
    // close together (the route is still listening while it animates out).
    ref.listen<sp.ServiceState>(sp.serviceProvider, (previous, next) {
      if (next.isConnected && !(previous?.isConnected ?? false) && !_navigated) {
        _navigated = true;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    });

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.radio, size: 64, color: Colors.deepPurple),
              const SizedBox(height: 16),
              Text(
                'Roomcast FM',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Multi-room audio streaming',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              if (serviceState.status == sp.ConnectionState.scanning) ...[
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 16),
                const Text(
                  'Searching for Roomcast FM on your network…',
                  textAlign: TextAlign.center,
                ),
              ] else
                FilledButton.icon(
                  onPressed: () =>
                      ref.read(sp.serviceProvider.notifier).scanAndConnect(),
                  icon: const Icon(Icons.search),
                  label: const Text('Find Service Automatically'),
                ),
              // Manual entry stays available while a scan runs (it can take
              // up to ~8 s, after a failed saved address up to ~18 s).
              ...[
                const SizedBox(height: 24),
                const Row(children: [
                  Expanded(child: Divider()),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('or enter IP manually'),
                  ),
                  Expanded(child: Divider()),
                ]),
                const SizedBox(height: 16),
                TextField(
                  controller: _ipController,
                  decoration: const InputDecoration(
                    labelText: 'Service address',
                    hintText: '192.168.1.x:8888',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lan),
                  ),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () {
                    final raw = _ipController.text.trim();
                    if (raw.isEmpty) return;
                    final url = raw.startsWith('http') ? raw : 'http://$raw';
                    ref.read(sp.serviceProvider.notifier).connectTo(url);
                  },
                  child: const Text('Connect'),
                ),
              ],
              if (serviceState.status == sp.ConnectionState.error) ...[
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Text(
                    serviceState.errorMessage ?? 'Connection failed',
                    style: TextStyle(color: Colors.red.shade700),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
