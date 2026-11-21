import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/service_provider.dart';
import 'screens/connect_screen.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const ProviderScope(child: RoomcastApp()));
}

class RoomcastApp extends ConsumerWidget {
  const RoomcastApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'Roomcast FM',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const _Launcher(),
    );
  }
}

/// Tries to reconnect to a saved service URL on launch.
/// Shows HomeScreen if successful, ConnectScreen otherwise.
class _Launcher extends ConsumerStatefulWidget {
  const _Launcher();

  @override
  ConsumerState<_Launcher> createState() => _LauncherState();
}

class _LauncherState extends ConsumerState<_Launcher> {
  bool _checked = false;
  bool _autoScan = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final notifier = ref.read(serviceProvider.notifier);
      await notifier.loadSaved();
      // After an explicit Disconnect, don't scan and reconnect by itself.
      final autoScan = !await notifier.userDisconnected();
      if (mounted) {
        setState(() {
          _checked = true;
          _autoScan = autoScan;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final state = ref.read(serviceProvider);
    return state.isConnected ? const HomeScreen() : ConnectScreen(autoScan: _autoScan);
  }
}
