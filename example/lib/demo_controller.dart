import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_resilience_test/flutter_resilience_test.dart';
import 'demo_auth.dart';

enum DemoScenario {
  refresh('Token refresh', 'Five expired requests recover with one refresh.'),
  brokenRefresh(
    'Broken refresh',
    'Catch an interceptor that refreshes five times.',
  ),
  retry(
    'Retry recovery',
    'Two temporary failures, then a successful response.',
  ),
  exhausted(
    'Retry limit',
    'Stop after three attempts when the server keeps failing.',
  ),
  cancellation(
    'Cancellation',
    'Cancel while the app waits before its next retry.',
  );

  const DemoScenario(this.label, this.description);
  final String label;
  final String description;
}

class DemoController extends ChangeNotifier {
  DemoScenario selected = DemoScenario.refresh;
  bool running = false;
  bool canCancel = false;
  String status = 'Ready';
  String detail = 'Choose a scenario and run it.';
  String timeline = '';
  int attempts = 0;
  bool _disposed = false;
  Dio? _dio;
  ScenarioGate? _gate;
  CancelToken? _token;

  void select(DemoScenario scenario) {
    if (running) return;
    selected = scenario;
    status = 'Ready';
    detail = scenario.description;
    timeline = '';
    attempts = 0;
    notifyListeners();
  }

  void cancel() {
    if (!canCancel) return;
    canCancel = false;
    _token?.cancel('Cancelled by demo user');
    _gate?.release();
    _notify();
  }

  Future<void> run() async {
    if (running || _disposed) return;
    running = true;
    status = 'Running';
    detail = selected.description;
    timeline = '';
    attempts = 0;
    _notify();
    final refresh = ConcurrentRefreshScenario();
    final isAuth =
        selected == DemoScenario.refresh ||
        selected == DemoScenario.brokenRefresh;
    final adapter = ResilienceAdapter(
      isAuth
          ? refresh.routes
          : [
              transientFailure(
                path: '/items',
                failures: selected == DemoScenario.exhausted ? 10 : 2,
              ),
            ],
    );
    final dio = _dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
      ..httpClientAdapter = adapter;
    try {
      if (isAuth) {
        installExampleAuth(dio, deduplicate: selected == DemoScenario.refresh);
        final responses = await Future.wait(
          List.generate(5, (_) => dio.get<Map<String, dynamic>>('/profile')),
        ).timeout(const Duration(seconds: 10));
        if (responses.any((r) => r.data?['ok'] != true)) {
          throw StateError('An application response did not recover.');
        }
        try {
          refresh.verify(adapter);
          if (selected == DemoScenario.brokenRefresh) {
            throw StateError(
              'The intentionally broken interceptor was not detected.',
            );
          }
          status = 'Passed';
          detail = '5 requests recovered • 1 token refresh';
        } on ResilienceFailure {
          if (selected != DemoScenario.brokenRefresh) rethrow;
          adapter.expectRequestCount('POST', '/auth/refresh', 5);
          adapter.verify();
          status = 'Bug detected';
          detail =
              'Expected 1 token refresh; observed 5. This is the intentional bug.';
        }
      } else {
        final gate = selected == DemoScenario.cancellation
            ? ScenarioGate()
            : null;
        _gate = gate;
        final token = _token = CancelToken();
        _installRetry(dio, gate);
        final outcome = dio
            .get<Map<String, dynamic>>('/items', cancelToken: token)
            .then<Object>(
              (response) => response,
              onError: (Object error) => error,
            );
        if (gate != null) {
          await gate.entered.timeout(const Duration(seconds: 10));
          canCancel = true;
          status = 'Waiting to retry';
          detail =
              'The first attempt failed. Tap Cancel request to stop the retry.';
          timeline = adapter.report;
          _notify();
        }
        final result = await outcome.timeout(const Duration(minutes: 2));
        if (selected == DemoScenario.cancellation) {
          if (result is! DioException ||
              result.type != DioExceptionType.cancel) {
            throw StateError('Expected a cancellation, got $result');
          }
          adapter.expectRequestCount('GET', '/items', 1);
          status = 'Cancelled';
          detail = '1 attempt • no request was retried after cancellation';
        } else if (selected == DemoScenario.exhausted) {
          if (result is! DioException || result.response?.statusCode != 503) {
            throw StateError('Expected a final 503, got $result');
          }
          adapter.expectRequestCount('GET', '/items', 3);
          status = 'Limit verified';
          detail =
              'Stopped after 3 attempts. The application received the final error.';
        } else {
          if (result is! Response<Map<String, dynamic>> ||
              result.data?['ok'] != true) {
            throw StateError('Expected a recovered response, got $result');
          }
          adapter.expectRequestCount('GET', '/items', 3);
          status = 'Passed';
          detail = '503 → 503 → 200 • recovered on attempt 3';
        }
        adapter.verify();
      }
    } catch (error) {
      status = 'Failed';
      detail = error.toString();
    } finally {
      _gate?.release();
      _token?.cancel('Scenario finished');
      dio.close(force: true);
      timeline = adapter.report;
      attempts = adapter.events.where((e) => e.outcome == 'started').length;
      running = false;
      canCancel = false;
      _dio = null;
      _gate = null;
      _token = null;
      _notify();
    }
  }

  void _installRetry(Dio dio, ScenarioGate? gate) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onError: (error, handler) async {
          final request = error.requestOptions;
          final retries = request.extra['retries'] as int? ?? 0;
          if (error.response?.statusCode != 503 || retries >= 2) {
            handler.next(error);
            return;
          }
          if (gate != null) await gate.wait();
          if (request.cancelToken?.isCancelled ?? false) {
            handler.reject(request.cancelToken!.cancelError!);
            return;
          }
          request.extra['retries'] = retries + 1;
          try {
            handler.resolve(await dio.fetch<dynamic>(request));
          } on DioException catch (failure) {
            handler.reject(failure);
          } catch (failure) {
            handler.reject(
              DioException(requestOptions: request, error: failure),
            );
          }
        },
      ),
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _token?.cancel('Demo disposed');
    _gate?.release();
    _dio?.close(force: true);
    super.dispose();
  }
}
