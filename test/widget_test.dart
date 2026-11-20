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
}
