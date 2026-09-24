import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resilience_example/main.dart';

Future<void> runScenario(
  WidgetTester tester,
  String scenario,
  String expected,
) async {
  final choice = find.byKey(ValueKey('scenario-$scenario'));
  await Scrollable.ensureVisible(tester.element(choice), alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.tap(choice);
  await tester.pumpAndSettle();
  final run = find.byKey(const ValueKey('run-scenario'));
  await Scrollable.ensureVisible(tester.element(run), alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.tap(run);
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    final status = tester
        .widget<Text>(find.byKey(const ValueKey('scenario-status')))
        .data;
    if (status == expected) return;
    if (status == 'Failed') break;
  }
  expect(
    tester.widget<Text>(find.byKey(const ValueKey('scenario-status'))).data,
    expected,
  );
}

void registerDemoTests() {
  testWidgets('all scenarios run through the visible app controls', (
    tester,
  ) async {
    await tester.pumpWidget(const ResilienceDemoApp());
    await runScenario(tester, 'refresh', 'Passed');
    expect(find.text('5 requests recovered • 1 token refresh'), findsOneWidget);
    await runScenario(tester, 'brokenRefresh', 'Bug detected');
    await runScenario(tester, 'retry', 'Passed');
    expect(
      find.text('503 → 503 → 200 • recovered on attempt 3'),
      findsOneWidget,
    );
    await runScenario(tester, 'exhausted', 'Limit verified');
    await runScenario(tester, 'cancellation', 'Waiting to retry');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('run-scenario')))
          .onPressed,
      isNull,
    );
    final cancel = find.byKey(const ValueKey('cancel-request'));
    await Scrollable.ensureVisible(tester.element(cancel), alignment: 0.5);
    await tester.pump();
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('scenario-status'))).data,
      'Cancelled',
    );
    expect(
      find.text('1 attempt • no request was retried after cancellation'),
      findsOneWidget,
    );
    await runScenario(tester, 'refresh', 'Passed');
    expect(tester.takeException(), isNull);
  });
}
