// Command-line example intentionally prints its result.
// ignore_for_file: avoid_print

import 'package:dio/dio.dart';
import 'package:flutter_resilience_test/flutter_resilience_test.dart';

import 'lib/demo_auth.dart';
export 'lib/demo_auth.dart' show installExampleAuth;

Future<void> main() async {
  final scenario = ConcurrentRefreshScenario();
  final adapter = ResilienceAdapter(scenario.routes);
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
    ..httpClientAdapter = adapter;
  installExampleAuth(dio);
  try {
    await Future.wait(
      List.generate(5, (_) => dio.get<dynamic>('/profile')),
    ).timeout(const Duration(seconds: 5));
    scenario.verify(adapter);
    print('PASS: five requests recovered with one token refresh.');
    print(adapter.report);
  } finally {
    dio.close(force: true);
  }
}
