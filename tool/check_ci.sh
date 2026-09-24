#!/usr/bin/env bash
# Run the same checks as CI before committing. Never commits or pushes files.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf 'Usage: bash tool/check_ci.sh /path/to/flutter-3.35.0/bin/flutter /path/to/current-stable/dart\n' >&2
  exit 2
fi

resilience_flutter=$(command -v "$1")
resilience_compat_dart=$(command -v "$2")
resilience_dart="$(dirname "$resilience_flutter")/cache/dart-sdk/bin/dart"
resilience_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

resilience_flutter_version=$("$resilience_flutter" --version)
resilience_dart_version=$("$resilience_dart" --version 2>&1)
if [[ "$resilience_flutter_version" != Flutter\ 3.35.0\ * ||
      "$resilience_dart_version" != Dart\ SDK\ version:\ 3.9.0\ * ]]; then
  printf 'Use Flutter 3.35.0 with Dart 3.9.0 to match the pinned CI formatter.\n' >&2
  exit 2
fi

cd "$resilience_root"
printf '\nChecking Dart 3.9.0 package job\n'
"$resilience_dart" pub get --no-example
"$resilience_dart" format --output=none --set-exit-if-changed lib test
"$resilience_dart" analyze --fatal-infos
"$resilience_dart" test

printf '\nChecking compatibility with supplied stable Dart SDK\n'
"$resilience_compat_dart" --version
"$resilience_compat_dart" pub get --no-example
"$resilience_compat_dart" analyze --fatal-infos
"$resilience_compat_dart" test

printf '\nChecking Flutter example job\n'
cd "$resilience_root/example"
"$resilience_flutter" pub get
"$resilience_dart" format --output=none --set-exit-if-changed \
  lib test integration_test test_driver flutter_resilience_test_example.dart
"$resilience_flutter" analyze --fatal-infos
"$resilience_flutter" test
"$resilience_dart" run flutter_resilience_test_example.dart
"$resilience_flutter" build web

printf '\nAll local CI checks passed.\n'
