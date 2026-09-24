import 'package:dio/dio.dart';
import 'package:flutter_resilience_test/flutter_resilience_test.dart';
import 'package:test/test.dart';

import '../example/flutter_resilience_test_example.dart'
    show installExampleAuth;

Dio client(ResilienceAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
    ..httpClientAdapter = adapter;
  addTearDown(() => dio.close(force: true));
  return dio;
}

void installRetry(Dio dio, {int maxRetries = 2, ScenarioGate? beforeRetry}) {
  dio.interceptors.add(
    InterceptorsWrapper(
      onError: (error, handler) async {
        final request = error.requestOptions;
        final retries = request.extra['retries'] as int? ?? 0;
        if (error.response?.statusCode != 503 || retries >= maxRetries) {
          handler.next(error);
          return;
        }
        if (beforeRetry != null) await beforeRetry.wait();
        if (request.cancelToken?.isCancelled ?? false) {
          handler.reject(request.cancelToken!.cancelError!);
          return;
        }
        request.extra['retries'] = retries + 1;
        try {
          handler.resolve(await dio.fetch<dynamic>(request));
        } on DioException catch (failure) {
          handler.reject(failure);
        }
      },
    ),
  );
}

void main() {
  test('five simultaneous 401s recover through one refresh', () async {
    final scenario = ConcurrentRefreshScenario();
    final adapter = ResilienceAdapter(scenario.routes);
    final dio = client(adapter);
    installExampleAuth(dio);
    final responses = await Future.wait(
      List.generate(5, (_) => dio.get<Map<String, dynamic>>('/profile')),
    );
    expect(responses.map((r) => r.data?['ok']), everyElement(true));
    scenario.verify(adapter);
    expect(adapter.report, isNot(contains(scenario.freshToken)));
  });

  test('detects deliberately broken refresh deduplication', () async {
    final scenario = ConcurrentRefreshScenario();
    final adapter = ResilienceAdapter(scenario.routes);
    final dio = client(adapter);
    installExampleAuth(dio, deduplicate: false);
    await Future.wait(List.generate(5, (_) => dio.get<dynamic>('/profile')));
    expect(
      () => scenario.verify(adapter),
      throwsA(
        isA<ResilienceFailure>().having(
          (e) => e.message,
          'report',
          contains('Observed: 5'),
        ),
      ),
    );
  });

  test('application retries two failures and decodes success', () async {
    final adapter = ResilienceAdapter([transientFailure(path: '/items')]);
    final dio = client(adapter);
    installRetry(dio);
    final response = await dio.get<Map<String, dynamic>>('/items');
    expect(response.data, {'ok': true});
    adapter.expectRequestCount('GET', '/items', 3);
    adapter.verify();
  });

  test('retry budget exhaustion propagates error', () async {
    final adapter = ResilienceAdapter([
      transientFailure(path: '/items', failures: 10),
    ]);
    final dio = client(adapter);
    installRetry(dio);
    await expectLater(
      dio.get<dynamic>('/items'),
      throwsA(
        isA<DioException>().having(
          (e) => e.response?.statusCode,
          'status',
          503,
        ),
      ),
    );
    adapter.expectRequestCount('GET', '/items', 3);
  });

  test('cancellation during retry wait prevents further dispatch', () async {
    final gate = ScenarioGate();
    addTearDown(gate.release);
    final adapter = ResilienceAdapter([transientFailure(path: '/items')]);
    final dio = client(adapter);
    installRetry(dio, beforeRetry: gate);
    final token = CancelToken();
    final assertion = expectLater(
      dio.get<dynamic>('/items', cancelToken: token),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await gate.entered;
    token.cancel();
    gate.release();
    await assertion;
    adapter.expectRequestCount('GET', '/items', 1);
  });

  test('cancel held response without emitting late success', () async {
    final gate = ScenarioGate();
    addTearDown(gate.release);
    final adapter = ResilienceAdapter([
      heldResponse(path: '/slow', gate: gate),
    ]);
    final dio = client(adapter);
    final token = CancelToken();
    final assertion = expectLater(
      dio.get<dynamic>('/slow', cancelToken: token),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await gate.entered;
    token.cancel();
    await assertion;
    gate.release();
    await Future<void>.delayed(Duration.zero);
    expect(adapter.report, contains('cancel'));
    expect(adapter.report, isNot(contains('HTTP 200')));
    adapter.verify();
  });

  test('unexpected request fails closed and is reported', () async {
    final adapter = ResilienceAdapter([]);
    await expectLater(
      client(adapter).get<dynamic>('/unknown'),
      throwsA(isA<DioException>()),
    );
    expect(() => adapter.verify(), throwsA(isA<ResilienceFailure>()));
    expect(adapter.report, contains('/unknown'));
  });

  test('unused routes fail verification', () {
    final adapter = ResilienceAdapter([transientFailure(path: '/unused')]);
    expect(() => adapter.verify(), throwsA(isA<ResilienceFailure>()));
  });

  test('methods match independently and report omits query secrets', () async {
    final adapter = ResilienceAdapter([
      ScenarioRoute(
        path: '/item',
        method: 'post',
        handle: (request, _) {
          expect(request.data, {'input': 1});
          return const ScenarioResponse(201, body: {'id': 1});
        },
      ),
    ]);
    final response = await client(
      adapter,
    ).post<dynamic>('/item?secret=hidden', data: {'input': 1});
    expect(response.statusCode, 201);
    expect(adapter.report, isNot(contains('hidden')));
    adapter.expectRequestCount('post', '/item', 1);
    adapter.verify();
  });

  test('force close cancels pending requests and refuses new ones', () async {
    final gate = ScenarioGate();
    addTearDown(gate.release);
    final adapter = ResilienceAdapter([
      heldResponse(path: '/slow', gate: gate),
    ]);
    final dio = client(adapter);
    final assertion = expectLater(
      dio.get<dynamic>('/slow'),
      throwsA(isA<DioException>()),
    );
    await gate.entered;
    adapter.close(force: true);
    await assertion;
    await expectLater(dio.get<dynamic>('/slow'), throwsA(isA<DioException>()));
    adapter.verify();
  });

  test('duplicate routes and invalid scenarios are rejected', () {
    final route = transientFailure(path: '/items');
    expect(() => ResilienceAdapter([route, route]), throwsArgumentError);
    expect(() => transientFailure(path: '/', failures: 0), throwsArgumentError);
    expect(
      () => transientFailure(path: '/', failureStatus: 200),
      throwsArgumentError,
    );
    expect(
      () => ConcurrentRefreshScenario(concurrentRequests: 0),
      throwsArgumentError,
    );
  });

  test('custom handlers simulate transport exceptions', () async {
    final adapter = ResilienceAdapter([
      ScenarioRoute(
        path: '/timeout',
        method: 'GET',
        handle: (request, _) {
          throw DioException(
            requestOptions: request,
            type: DioExceptionType.receiveTimeout,
          );
        },
      ),
    ]);
    await expectLater(
      client(adapter).get<dynamic>('/timeout'),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      ),
    );
    expect(adapter.report, contains('receiveTimeout'));
    adapter.verify();
  });
}
