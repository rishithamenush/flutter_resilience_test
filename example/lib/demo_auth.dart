import 'package:dio/dio.dart';

/// Example application auth behavior, not part of the package implementation.
/// Uses a shared refresh future and detects late failures with an obsolete token.
void installExampleAuth(Dio dio, {bool deduplicate = true}) {
  var token = 'expired-token';
  Future<void>? refreshing;
  Future<void> refresh() async {
    final response = await dio.post<Map<String, dynamic>>('/auth/refresh');
    token = response.data!['access_token'] as String;
  }

  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        request.headers['Authorization'] = 'Bearer $token';
        handler.next(request);
      },
      onError: (error, handler) async {
        if (error.response?.statusCode != 401 ||
            error.requestOptions.path == '/auth/refresh' ||
            error.requestOptions.extra['authRetried'] == true) {
          handler.next(error);
          return;
        }
        try {
          if (!deduplicate) {
            await refresh();
          } else if (error.requestOptions.headers['Authorization'] ==
              'Bearer $token') {
            final pending = refreshing ??= refresh();
            try {
              await pending;
            } finally {
              if (identical(refreshing, pending)) refreshing = null;
            }
          }
          final request = error.requestOptions;
          request.extra['authRetried'] = true;
          handler.resolve(await dio.fetch<dynamic>(request));
        } on DioException catch (failure) {
          handler.reject(failure);
        } catch (failure) {
          handler.reject(
            DioException(requestOptions: error.requestOptions, error: failure),
          );
        }
      },
    ),
  );
}
