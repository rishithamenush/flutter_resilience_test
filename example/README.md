# Resilience Lab — Flutter example

An interactive app demonstrating `flutter_resilience_test` with actual application
Dio interceptors and in-memory API responses. No backend account or API key is
needed. All requests are simulated, including on physical devices.

## Run

From this directory:

```sh
flutter pub get
flutter devices
flutter run -d <device-id>
```

Android, iOS, macOS, and web scaffolds are included. For an iPhone, enable Developer
Mode, trust the development computer, and select your own signing team in
`ios/Runner.xcworkspace`. No App Store publishing is involved.

## Scenarios

| Scenario | Expected result |
| --- | --- |
| Token refresh | Five requests recover with exactly one refresh. |
| Broken refresh | The package detects five refreshes instead of one. This result is intentional. |
| Retry recovery | 503, 503, then 200; exactly three attempts. |
| Retry limit | Stop after three attempts and surface the final 503. |
| Cancellation | Pause after the first 503. Tap **Cancel request**; no retry is dispatched. |

Choose a scenario, tap **Run scenario**, and inspect the outcome and request
timeline. Selection and repeated runs are disabled while a scenario is active.
Cancellation waits for user input, with a two-minute guard against abandoned runs.
A fresh client and adapter are used for every run.

`lib/demo_auth.dart` and `lib/demo_controller.dart` contain illustrative application
recovery logic. The package supplies failures and assertions; it does not retry
or refresh on behalf of the application.

## Tests

```sh
flutter analyze
flutter test
flutter test integration_test/app_test.dart -d <device-id>
```

For a wireless iPhone with Flutter 3.35, use the driver entrypoint so the
VM service is advertised to the Mac:

```sh
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/app_test.dart --publish-port -d <device-id>
```

The integration test taps every scenario through the visible controls, checks
results, cancels a pending retry, and reruns refresh to check isolation. The widget
tests additionally cover a small viewport with large text and disposal while a
request is waiting. Passing these tests validates simulated recovery on that
runtime; it does not validate real Wi-Fi changes, cellular connectivity, TLS,
or background execution.

To reopen the interactive app after integration tests, run `flutter run -d
<device-id>` again; integration tests install a test entrypoint.

The original command-line example is still available from the package root:

```sh
dart run example/flutter_resilience_test_example.dart
```

## Verified locally

On 2026-09-23, using Flutter 3.35.0 / Dart 3.9.0:

- All 12 package tests passed.
- All 3 Flutter widget tests passed.
- The complete integration flow passed on a physical Pixel 7 over USB
  (Android 17 / API 37), including all five scenarios and repeat-run isolation.
- Package and example static analysis passed.
- The web release build compiled successfully; browser interaction was not tested.
- The iOS build succeeded, but wireless VM-service discovery did not complete,
  so physical iPhone execution is not verified.

These are simulated transport scenarios running on real hardware, not tests of
actual network outages.
