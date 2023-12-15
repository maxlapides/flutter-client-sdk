import 'stub_config.dart'
    if (dart.library.io) 'io_config.dart'
    if (dart.library.html) 'js_config.dart';

/// Configuration common to web and mobile is contained in this file.
///
/// Configuration specific to either io targets or js targets are in io_config
/// and js_config and then exposed through this file.

final class DefaultEventConfiguration {
  final defaultEventsCapacity = 100;
  final defaultFlushInterval = Duration(seconds: 30);
  final defaultDiagnosticRecordingInterval = Duration(minutes: 15);
  final minDiagnosticRecordingInterval = Duration(minutes: 5);
}

final class DefaultPollingConfiguration {
  final defaultPollingInterval = Duration(minutes: 5);
  final minPollingInterval = Duration(minutes: 5);
}

final class DefaultDataSourceConfig {
  final defaultWithReasons = false;
  final defaultUseReport = false;
}

final class DefaultConfig {
  static final pollingPaths = DefaultPollingPaths();
  static final eventPaths = DefaultEventPaths();
  static final DefaultEndpoints endpoints = DefaultEndpoints();
  static final eventConfig = DefaultEventConfiguration();
  static final pollingConfig = DefaultPollingConfiguration();
  static final dataSourceConfig = DefaultDataSourceConfig();
}
