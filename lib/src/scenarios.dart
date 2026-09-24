import 'dart:async';

import 'resilience_adapter.dart';

/// Fails a route a fixed number of times, then succeeds on later attempts.
ScenarioRoute transientFailure({
  required String path,
  String method = 'GET',
  int failures = 2,
  int failureStatus = 503,
  Object? successBody = const {'ok': true},
  Map<String, List<String>> failureHeaders = const {},
}) {
  if (failures < 1) {
    throw ArgumentError.value(failures, 'failures', 'Must be positive');
  }
  if (failureStatus < 400 || failureStatus > 599) {
    throw ArgumentError.value(
      failureStatus,
      'failureStatus',
      'Must be 400–599',
    );
  }
  return ScenarioRoute(
    path: path,
    method: method,
    handle: (_, attempt) => attempt <= failures
        ? ScenarioResponse(failureStatus, headers: failureHeaders)
        : ScenarioResponse(200, body: successBody),
  );
}

/// Holds a request until released, allowing cancellation at a known point.
ScenarioRoute heldResponse({
  required String path,
  required ScenarioGate gate,
  String method = 'GET',
  ScenarioResponse response = const ScenarioResponse(200, body: {'ok': true}),
}) => ScenarioRoute(
  path: path,
  method: method,
  handle: (_, _) async {
    await gate.wait();
    return response;
  },
);

/// Forces a cohort of requests to receive 401 before accepting a new token.
///
/// Each instance is single-use. Dispatch exactly [concurrentRequests] initial
/// requests to [protectedPath]. The test must install its own auth interceptor.
/// More initial requests than configured fail explicitly. Always use a test
/// timeout: too few participants will intentionally leave the barrier waiting.
final class ConcurrentRefreshScenario {
  /// Configures one protected GET route and one refresh POST route.
  ConcurrentRefreshScenario({
    this.concurrentRequests = 5,
    this.protectedPath = '/profile',
    this.refreshPath = '/auth/refresh',
    this.freshToken = 'scenario-fresh-token',
  }) {
    if (concurrentRequests < 1) {
      throw ArgumentError.value(concurrentRequests, 'concurrentRequests');
    }
  }

  /// Number of initial requests held at the 401 barrier.
  final int concurrentRequests;

  /// Protected GET endpoint.
  final String protectedPath;

  /// Refresh POST endpoint returning an access_token field.
  final String refreshPath;

  /// Synthetic token accepted after refresh.
  final String freshToken;

  final _cohort = Completer<void>();
  int _arrivals = 0;
  bool _issued = false;

  /// Routes to install on a single [ResilienceAdapter].
  late final List<ScenarioRoute> routes = List.unmodifiable([
    ScenarioRoute(
      path: protectedPath,
      method: 'GET',
      handle: (request, _) async {
        final authorization = request.headers.entries
            .where((entry) => entry.key.toLowerCase() == 'authorization')
            .map((entry) => entry.value)
            .firstOrNull;
        if (_issued && authorization == 'Bearer $freshToken') {
          return const ScenarioResponse(200, body: {'ok': true});
        }
        if (++_arrivals > concurrentRequests) {
          throw StateError(
            'Unexpected stale-token retry or extra initial request.',
          );
        }
        if (_arrivals == concurrentRequests) _cohort.complete();
        await _cohort.future;
        return const ScenarioResponse(401, body: {'error': 'expired_token'});
      },
    ),
    ScenarioRoute(
      path: refreshPath,
      method: 'POST',
      handle: (_, _) {
        _issued = true;
        return ScenarioResponse(200, body: {'access_token': freshToken});
      },
    ),
  ]);

  /// Checks one refresh and one successful HTTP response per initial request.
  /// Also await/assert the application's returned futures to validate its results.
  void verify(ResilienceAdapter adapter) {
    adapter.expectRequestCount('POST', refreshPath, 1);
    adapter.expectRequestCount('GET', protectedPath, concurrentRequests * 2);
    final successes = adapter.events
        .where(
          (event) =>
              event.method == 'GET' &&
              event.path == protectedPath &&
              event.outcome == 'HTTP 200',
        )
        .length;
    if (successes != concurrentRequests) {
      throw ResilienceFailure(
        'Expected $concurrentRequests recovered requests; '
        'observed $successes.\n${adapter.report}',
      );
    }
    adapter.verify();
  }
}

