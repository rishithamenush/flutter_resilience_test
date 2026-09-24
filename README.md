# flutter_resilience_test

Catch duplicate token refreshes, broken retries, and cancelled requests that keep
running—using your application's actual Dio interceptors.

A small, pure Dart test utility for Flutter and Dart projects. All scenario
requests stay in memory. No server, native plugin, or state-management dependency.

Version 0.1.0 is tested on the Dart VM with Dart 3.9.0 and Dio 5.11.1. The
Flutter example includes widget tests and a physical-device integration suite.
The full integration flow passed on a physical Pixel 7 (Android 17 / API 37).
See `example/README.md` for running the app, test results, and platform limits.

## Install

Add the package to your application's `pubspec.yaml`:

```yaml
dev_dependencies:
  flutter_resilience_test: ^0.1.0
```

Your application should already depend on Dio. Use `package:test/test.dart` in
Dart tests or `package:flutter_test/flutter_test.dart` in Flutter tests.

## Interactive Flutter example

The `example/` directory is a complete Flutter app with token refresh, deliberate
refresh bugs, retry recovery, retry limits, cancellation, and request timelines.

```sh
cd example
flutter pub get
flutter run -d <device-id>
flutter test
flutter test integration_test/app_test.dart -d <device-id>
```

See [the example guide](example/README.md) for device setup and limitations.

## Test concurrent token refresh

```dart
final scenario = ConcurrentRefreshScenario(concurrentRequests: 5);
final adapter = ResilienceAdapter(scenario.routes);
final dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
  ..httpClientAdapter = adapter;

// Install YOUR application's authentication interceptor here.
// See example/flutter_resilience_test_example.dart for runnable sample logic.
addTearDown(() => dio.close(force: true));

final responses = await Future.wait(
  List.generate(5, (_) => dio.get<Map<String, dynamic>>('/profile')),
);
expect(responses.map((response) => response.data?['ok']), everyElement(true));
scenario.verify(adapter);
```

The scenario holds the initial requests until all five arrive, returns 401,
exposes `POST /auth/refresh` returning `{"access_token":"scenario-fresh-token"}`,
and accepts retries with that bearer token. Verification requires exactly one
refresh, ten protected endpoint attempts, and five successful HTTP responses.
The app must parse the refresh response and perform its own retries.

A broken implementation produces a report such as:

```text
FAIL: POST /auth/refresh
Expected: 1 request(s)
Observed: 5 request(s)

#1 GET /profile: started
...
```

Create a fresh scenario and adapter for every test. Dispatch exactly the specified
number of initial requests. Too few leave the barrier waiting; use a test timeout.
The preset uses one GET endpoint; custom routes support other contracts.

## Test transient errors and retry limits

```dart
final adapter = ResilienceAdapter([
  transientFailure(path: '/items', failures: 2),
]);
dio.httpClientAdapter = adapter;
// Keep the application's retry interceptor installed.
final response = await dio.get<Map<String, dynamic>>('/items');
expect(response.data, {'ok': true});
adapter.expectRequestCount('GET', '/items', 3);
adapter.verify();
```

The route returns 503 twice, then 200. Set `failureStatus: 429` and
`failureHeaders: {'retry-after': ['2']}` for a rate-limit fixture. The package
passes headers through; it does not implement or automatically assert backoff
scheduling. Test that behavior using your application's injectable clock.

## Control cancellation without sleeps

```dart
final gate = ScenarioGate();
final adapter = ResilienceAdapter([
  heldResponse(path: '/slow', gate: gate),
]);
dio.httpClientAdapter = adapter;
addTearDown(gate.release);
final token = CancelToken();
final assertion = expectLater(
  dio.get<dynamic>('/slow', cancelToken: token),
  throwsA(isA<DioException>().having(
    (error) => error.type, 'type', DioExceptionType.cancel,
  )),
);
await gate.entered;
token.cancel();
await assertion;
gate.release();
adapter.expectRequestCount('GET', '/slow', 1);
```

The tests also demonstrate a gate inside an application's retry wait: cancel at
that point, release the gate, await completion, then assert no further dispatch.
An assertion only describes work observed so far—advance your application's
scheduler before asserting if it schedules detached future retries.

## Custom scenarios

`ScenarioRoute` matches an exact URI path and HTTP method. The handler receives
Dio's `RequestOptions` and the route's 1-based transport attempt count. Inspect
query parameters, headers, or request data there when necessary. Return a
`ScenarioResponse`, wait on a `ScenarioGate`, or throw a `DioException` to simulate
a connection/timeout failure. Routes ignore host and query for matching.

Routes must be unique. Unmatched requests fail; there is no network fallback.
`verify()` detects unused routes, unexpected requests (even if an interceptor
swallows the error), and unfinished adapter fetches. It is not an assertion of
application success: always await and assert the returned application futures.

## Scope and limitations

- This package supplies faults and observations, not production retry/auth logic.
- Attempts are counted at the adapter boundary. Requests resolved by interceptors
  or cancelled before dispatch do not reach the adapter.
- Controlled barriers make scenarios repeatable. Concurrent arrival order is
  determined by your application's scheduling; no virtual clock is installed.
- No actual sockets, TLS, DNS, bandwidth, upload progress, streaming-body fidelity,
  OS background execution, or automatic enforcement of Dio timeout durations.
- Responses are JSON encoded. Request streams are not consumed or validated.
- Reports omit query strings, headers, and bodies. Paths are retained; use
  synthetic data and avoid secrets in paths.
- `close()` rejects new fetches; `close(force: true)` also cancels pending fetches.
  It cannot terminate custom handler code. Release gates in teardown.
- Sharing an adapter across Dio clients also shares its close lifecycle.

## Run the example and checks

```sh
dart pub get
dart run example/flutter_resilience_test_example.dart
dart analyze --fatal-infos
dart test
dart format --output=none --set-exit-if-changed .
```

The runnable example demonstrates single-flight refresh. The test suite includes
its deliberately broken variant to prove the assertion detects duplicate refresh.
The GitHub Actions workflow runs checks on Dart 3.9.0 and stable when hosted.

## Contributing

Issues and pull requests are welcome in the
[GitHub repository](https://github.com/rishitha-menusha/flutter_resilience_test).
Before opening a pull request, run the formatting, analysis, and test commands
above.
