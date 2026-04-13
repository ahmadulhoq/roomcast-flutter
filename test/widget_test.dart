import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:roomcast_fm/main.dart';

void main() {
  testWidgets('App launches without error', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: RoomcastApp()),
    );
    // Launcher shows a loading indicator while checking saved service URL
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
