import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:roomcast_fm/main.dart';
import 'package:roomcast_fm/providers/service_provider.dart';

void main() {
  testWidgets('launches, auto-scans, and offers manual entry when nothing is found',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    var scans = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serviceFinderProvider.overrideWithValue(() async {
            scans++;
            return null;
          }),
        ],
        child: const RoomcastApp(),
      ),
    );
    // Launcher shows a loading indicator while checking saved service URL
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpAndSettle();
    expect(scans, 1, reason: 'ConnectScreen scans automatically on first show');
    expect(find.text('No Roomcast FM service found on this network.'), findsOneWidget);
    expect(find.text('Find Service Automatically'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('an unreachable saved address stays visible after a failed auto-scan',
      (WidgetTester tester) async {
    // flutter_test answers every real HTTP request with 400, so the saved URL fails.
    SharedPreferences.setMockInitialValues({'service_base_url': 'http://192.0.2.10:8888'});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [serviceFinderProvider.overrideWithValue(() async => null)],
        child: const RoomcastApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('No Roomcast FM service found on this network.'), findsOneWidget);
    expect(find.textContaining('Could not reach service at http://192.0.2.10:8888'), findsOneWidget);
  });
}

