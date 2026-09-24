import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A response produced by a scenario. Bodies must be JSON encodable.
final class ScenarioResponse {
  /// Creates an HTTP response without making a network request.
  const ScenarioResponse(this.statusCode, {this.body, this.headers = const {}});

  /// HTTP status passed to Dio's normal validation and error interceptors.
  final int statusCode;

  /// A JSON value; null produces an empty body.
  final Object? body;

  /// Additional response headers, such as Retry-After.
  final Map<String, List<String>> headers;

  ResponseBody _toBody() => ResponseBody.fromString(
    body == null ? '' : jsonEncode(body),
    statusCode,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
      ...headers,
    },
  );
}

/// Receives the real request options after application request interceptors run.
typedef ScenarioHandler =
    FutureOr<ScenarioResponse> Function(RequestOptions request, int attempt);

/// A deterministic route; attempts are counted per route in arrival order.
final class ScenarioRoute {
  /// Matches an exact URI path and HTTP method, ignoring host and query.
  ScenarioRoute({
    required this.path,
    required String method,
    required this.handle,
  }) : method = method.toUpperCase();

  /// Exact URI path, for example /profile.
  final String path;

  /// Uppercase HTTP method.
  final String method;

  /// Produces a response, or throws a DioException to simulate transport failure.
  final ScenarioHandler handle;
}

/// One transport observation. Headers, query values and bodies are not recorded.
final class RequestEvent {
  const RequestEvent._(this.requestId, this.method, this.path, this.outcome);

  /// Stable sequence number assigned when fetch starts.
  final int requestId;

  /// Request HTTP method.
  final String method;

  /// URI path only. Avoid putting secrets in URL paths.
  final String path;

  /// Started, HTTP status, cancellation, or error type.
  final String outcome;

  @override
  String toString() => '#$requestId $method $path: $outcome';
}

/// An assertion failure including the transport timeline.
final class ResilienceFailure implements Exception {
  /// Creates a human-readable failure.
  const ResilienceFailure(this.message);

  /// Explanation and request timeline.
  final String message;

  @override
  String toString() => message;
}

/// An in-memory Dio transport that never falls back to real networking.
///
/// Keep application interceptors installed: this adapter tests their behavior,
/// rather than implementing token refresh or retries on their behalf.
final class ResilienceAdapter implements HttpClientAdapter {
  /// Creates an isolated scenario. Duplicate method/path pairs are rejected.
  ResilienceAdapter(Iterable<ScenarioRoute> routes) {
    for (final route in routes) {
      final key = '${route.method} ${route.path}';
      if (_routes.containsKey(key)) {
        throw ArgumentError('Duplicate route: $key');
      }
      _routes[key] = route;
    }
  }

  final _routes = <String, ScenarioRoute>{};
  final _counts = <String, int>{};
  final _events = <RequestEvent>[];
  final _pending = <Completer<void>>{};
  int _nextId = 0;
  bool _closed = false;

  /// An immutable snapshot of observations in execution order.
  List<RequestEvent> get events => List.unmodifiable(_events);

  /// A readable timeline, without request headers or bodies.
  String get report => _events.isEmpty
      ? 'No requests observed.'
      : _events.map((event) => event.toString()).join('\n');

  /// Number of transport attempts; pre-dispatch cancellations are not counted.
  int requestCount(String method, String path) =>
      _counts['${method.toUpperCase()} $path'] ?? 0;

  /// Asserts an exact count, useful for refresh deduplication and retry bounds.
  void expectRequestCount(String method, String path, int expected) {
    final actual = requestCount(method, path);
    if (actual != expected) {
      throw ResilienceFailure(
        'FAIL: ${method.toUpperCase()} $path\n'
        'Expected: $expected request(s)\nObserved: $actual request(s)\n\n$report',
      );
    }
  }

  /// Asserts that every expected route was exercised at least once and that no
  /// unexpected request or unfinished fetch was observed.
  void verify() {
    final missing = _routes.keys.where((key) => (_counts[key] ?? 0) == 0);
    final unexpected = _counts.keys.where((key) => !_routes.containsKey(key));
    if (missing.isNotEmpty || unexpected.isNotEmpty || _pending.isNotEmpty) {
      throw ResilienceFailure(
        'Scenario incomplete. Unused: ${missing.join(', ')}; '
        'unexpected: ${unexpected.join(', ')}; pending: ${_pending.length}\n$report',
      );
    }
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) throw StateError('ResilienceAdapter is closed.');
    final method = options.method.toUpperCase();
    final path = options.uri.path;
    final key = '$method $path';
    final id = ++_nextId;
    final attempt = _counts.update(
      key,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    void record(String outcome) =>
        _events.add(RequestEvent._(id, method, path, outcome));
    record('started');
    final stop = Completer<void>();
    _pending.add(stop);
    try {
      final route = _routes[key];
      if (route == null) {
        throw StateError('Unexpected request: $key. No network fallback.');
      }
      final response = await Future.any<ScenarioResponse>([
        Future.sync(() => route.handle(options, attempt)),
        if (cancelFuture != null)
          cancelFuture.then<ScenarioResponse>(
            (_) => throw DioException(
              requestOptions: options,
              type: DioExceptionType.cancel,
              message: 'Scenario request cancelled.',
            ),
          ),
        stop.future.then<ScenarioResponse>(
          (_) => throw DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
            message: 'Adapter force closed.',
          ),
        ),
      ]);
      final body = response._toBody();
      record('HTTP ${response.statusCode}');
      return body;
    } catch (error) {
      record(
        error is DioException ? error.type.name : error.runtimeType.toString(),
      );
      rethrow;
    } finally {
      _pending.remove(stop);
    }
  }

  /// Refuses new requests. Force also cancels pending adapter fetches.
  /// Custom handler futures cannot be terminated; release their gates in teardown.
  @override
  void close({bool force = false}) {
    _closed = true;
    if (force) {
      for (final pending in _pending.toList()) {
        if (!pending.isCompleted) pending.complete();
      }
    }
  }
}

/// Explicit synchronization for tests, avoiding wall-clock sleeps.
final class ScenarioGate {
  final _entered = Completer<void>();
  final _released = Completer<void>();

  /// Completes when a handler reaches [wait].
  Future<void> get entered => _entered.future;

  /// Marks arrival and waits for the test to call [release].
  Future<void> wait() {
    if (!_entered.isCompleted) _entered.complete();
    return _released.future;
  }

  /// Releases current and future waiters. Safe to call in teardown.
  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}
