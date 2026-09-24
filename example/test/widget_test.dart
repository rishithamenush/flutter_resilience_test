import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resilience_example/main.dart';
import 'demo_flow.dart';

void main() {
  registerDemoTests();
  testWidgets('small viewport and large text remain scrollable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(const ResilienceDemoApp());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('run-scenario')),
      200,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('run-scenario')).hitTestable(),
      findsOneWidget,
    );
  });
  testWidgets('disposing a pending cancellation scenario is safe', (
    tester,
  ) async {
    await tester.pumpWidget(const ResilienceDemoApp());
    await runScenario(tester, 'cancellation', 'Waiting to retry');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
