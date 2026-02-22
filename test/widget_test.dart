import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:draw_mountain/main.dart';

void main() {
  testWidgets('overlay page starts with loading indicator', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ContourRouteApp());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
