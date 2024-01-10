import 'dart:async';

import 'package:launchdarkly_dart_common/ld_common.dart';

import '../src/config/ld_dart_config.dart';
import '../src/flag_manager/flag_updater.dart';
import 'config/defaults/default_config.dart';
import 'context_modifiers/anonymous_context_modifier.dart';
import 'context_modifiers/context_modifier.dart';
import 'context_modifiers/env_context_modifier.dart';
import 'data_sources/data_source_event_handler.dart';
import 'data_sources/data_source_manager.dart';
import 'data_sources/data_source_status.dart';
import 'data_sources/data_source_status_manager.dart';
import 'data_sources/polling_data_source.dart';
import 'data_sources/streaming_data_source.dart';
import 'flag_manager/flag_manager.dart';
import 'persistence/persistence.dart';

/// Base class used for all identify results. Using a sealed class allows for
/// exhaustive matching the the return from identify operations.
sealed class IdentifyResult {}

/// The identify has been completed. Either the identify completed with
/// cached data, or new data was fetched from LaunchDarkly.
final class IdentifyComplete implements IdentifyResult {
  IdentifyComplete();
}

/// The identify has been superseded. Multiple identify calls were outstanding
/// and this one has been cancelled.
final class IdentifySuperseded implements IdentifyResult {}

/// The identify operation encountered an error and will not complete.
final class IdentifyError implements IdentifyResult {
  /// The error which prevented the identify from completing.
  final Object error;

  IdentifyError(this.error);
}

final class LDDartClient {
  final LDDartConfig _config;
  final Persistence _persistence;
  final LDLogger _logger;
  final FlagManager _flagManager;
  final DataSourceStatusManager _dataSourceStatusManager;
  late final DataSourceManager _dataSourceManager;
  late final EventProcessor _eventProcessor;
  late final DiagnosticsManager? _diagnosticsManager;
  late final EnvironmentReporter _envReporter;
  late final AsyncSingleQueue<void> _identifyQueue = AsyncSingleQueue();

  // Modifications will happen in the order they are specified in this list.
  // If there are cross-dependent modifiers, then this must be considered.
  late final List<ContextModifier> _modifiers;
  final LDContext _initialUndecoratedContext;

  // During startup the _context will be invalid until the identify process
  // is complete.
  LDContext _context = LDContextBuilder().build();

  Future<IdentifyResult>? _startFuture;

  Stream<DataSourceStatus> get dataSourceStatusChanges {
    return _dataSourceStatusManager.changes;
  }

  DataSourceStatus get dataSourceStatus => _dataSourceStatusManager.status;

  Stream<FlagsChangedEvent> get flagChanges {
    return _flagManager.changes;
  }

  LDDartClient(LDDartConfig config, LDContext context)
      : _config = config,
        _persistence = config.persistence ?? InMemoryPersistence(),
        _logger = config.logger,
        _flagManager = FlagManager(
            sdkKey: config.sdkCredential,
            maxCachedContexts: 5, // TODO: Get from config.
            logger: config.logger,
            persistence: config.persistence),
        _dataSourceStatusManager = DataSourceStatusManager(),
        _initialUndecoratedContext = context {
    // TODO: Figure out how we will construct this.
    _diagnosticsManager = null;

    final dataSourceEventHandler = DataSourceEventHandler(
        flagManager: _flagManager,
        statusManager: _dataSourceStatusManager,
        logger: _logger);

    _dataSourceManager = DataSourceManager(
        statusManager: _dataSourceStatusManager,
        dataSourceEventHandler: dataSourceEventHandler,
        logger: _logger);
  }

  Future<EnvironmentReporter> _makeEnvReporter(LDDartConfig config) async {
    final reporterBuilder = PrioritizedEnvReporterBuilder();
    reporterBuilder.setConfigLayer(ConcreteEnvReporter(
        applicationInfo: Future.value(_config.applicationInfo),
        osInfo: Future.value(null),
        deviceInfo: Future.value(null),
        locale: Future.value(null)));
    if (_config.autoEnvAttributes) {
      reporterBuilder.setPlatformLayer(_config.platformEnvReporter);
    }
    return await reporterBuilder.build();
  }

  Future<HttpProperties> _makeHttpProperties(LDDartConfig config,
      EnvironmentReporter reporter, LDLogger logger) async {
    final appInfo = await _envReporter.applicationInfo;
    if (appInfo == null) {
      return _config.httpProperties;
    }

    if (appInfo.applicationId == null) {
      // indicates ID was dropped at some point
      _logger.info('A valid applicationId was not provided.');
    }

    return _config.httpProperties.withHeaders(appInfo.asHeaderMap());
  }

  Future<void> _setAndDecorateContext(LDContext context) async {
    _context = await _modifiers.asyncReduce(
        (reducer, accumulator) async => await reducer.decorate(accumulator),
        context);
  }

  /// This instructs the SDK to start connecting to LaunchDarkly. Ideally
  /// this is called before any other methods. Variation calls before the SDK
  /// has been started, or after starting but before initialization is complete,
  /// will return default values.
  ///
  /// When starting the [IdentifyResult] will not be [IdentifySuperseded].
  Future<IdentifyResult> start() {
    if (_startFuture != null) {
      return _startFuture!;
    }
    final completer = Completer<IdentifyResult>();
    _startFuture = completer.future;

    _startInternal().then((value) => completer.complete(value));

    return _startFuture!;
  }

  Future<IdentifyResult> _startInternal() async {
    // TODO: Do we start the process when we create the client, and provide
    // a way to know when it completes? Or do we not even start it as we
    // are doing here.
    _envReporter = await _makeEnvReporter(_config);

    // set up context modifiers, adding the auto env modifier if turned on
    _modifiers = [AnonymousContextModifier(_persistence)];
    if (_config.autoEnvAttributes) {
      _modifiers.add(
          AutoEnvContextModifier(_envReporter, _persistence, _config.logger));
    }

    final httpProperties =
        await _makeHttpProperties(_config, _envReporter, _logger);

    _eventProcessor = EventProcessor(
        logger: _logger,
        eventCapacity: _config.eventsConfig.eventCapacity,
        flushInterval: _config.eventsConfig.flushInterval,
        // TODO: Get from config. Use correct auth header setup.
        client: HttpClient(
            httpProperties: httpProperties
                // TODO: this authorization header location is inconsistent with others
                .withHeaders({'authorization': _config.sdkCredential})),
        analyticsEventsPath: DefaultConfig.eventPaths
            .getAnalyticEventsPath(_config.sdkCredential),
        diagnosticEventsPath: DefaultConfig.eventPaths
            .getDiagnosticEventsPath(_config.sdkCredential),
        diagnosticsManager: _diagnosticsManager,
        endpoints: _config.endpoints,
        diagnosticRecordingInterval:
            _config.eventsConfig.diagnosticRecordingInterval);
    _eventProcessor.start();

    _dataSourceManager.setFactories({
      ConnectionMode.streaming: (LDContext context) {
        return StreamingDataSource(
            credential: _config.sdkCredential,
            context: context,
            endpoints: _config.endpoints,
            logger: _logger,
            dataSourceConfig: _config.streamingConfig,
            httpProperties: httpProperties);
      },
      ConnectionMode.polling: (LDContext context) {
        return PollingDataSource(
            credential: _config.sdkCredential,
            context: context,
            endpoints: _config.endpoints,
            logger: _logger,
            dataSourceConfig: _config.pollingConfig,
            httpProperties: httpProperties);
      },
    });

    return await identify(_initialUndecoratedContext);
  }

  /// Triggers immediate sending of pending events to LaunchDarkly.
  ///
  /// Note that the future completes after the native SDK is requested to perform a flush, not when the said flush completes.
  Future<void> flush() async {
    await _eventProcessor.flush();
  }

  /// Changes the active context.
  ///
  /// When the context is changed, the SDK will load flag values for the context from a local cache if available, while
  /// initiating a connection to retrieve the most current flag values. An event will be queued to be sent to the service
  /// containing the public [LDContext] fields for indexing on the dashboard.
  Future<IdentifyResult> identify(LDContext context) async {
    // TODO: Check for difference?
    // TODO: Does the SDK need to have been started?
    await _setAndDecorateContext(context);
    return _identifyInternal();
  }

  Future<IdentifyResult> _identifyInternal() async {
    final res = await _identifyQueue.execute(() async {
      final completer = Completer<void>();
      _eventProcessor.processIdentifyEvent(IdentifyEvent(context: _context));
      final loadedFromCache = await _flagManager.loadCached(_context);

      _dataSourceManager.identify(_context, completer);

      if (loadedFromCache) {
        return;
      }
      return completer.future;
    });
    switch (res) {
      case TaskComplete<void>():
        return IdentifyComplete();
      case TaskShed<void>():
        return IdentifySuperseded();
      case TaskError<void>(error: var error):
        return IdentifyError(error);
    }
  }

  /// Returns the value of flag [flagKey] for the current context as a bool.
  ///
  /// Will return the provided [defaultValue] if the flag is missing, not a bool, or if some error occurs.
  bool boolVariation(String flagKey, bool defaultValue) {
    return _variationInternal(flagKey, LDValue.ofBool(defaultValue),
            isDetailed: false, type: LDValueType.boolean)
        .value
        .booleanValue();
  }

  /// Returns the value of flag [flagKey] for the current context as a bool, along with information about the resultant value.
  ///
  /// See [LDEvaluationDetail] for more information on the returned value. Note that [LDConfigBuilder.evaluationReasons]
  /// must have been set to `true` to request the additional evaluation information from the backend.
  LDEvaluationDetail<bool> boolVariationDetail(
      String flagKey, bool defaultValue) {
    final ldValueVariation = _variationInternal(
        flagKey, LDValue.ofBool(defaultValue),
        isDetailed: true, type: LDValueType.boolean);

    return LDEvaluationDetail(ldValueVariation.value.booleanValue(),
        ldValueVariation.variationIndex, ldValueVariation.reason);
  }

  /// Returns the value of flag [flagKey] for the current context as an int.
  ///
  /// Will return the provided [defaultValue] if the flag is missing, not a number, or if some error occurs.
  int intVariation(String flagKey, int defaultValue) {
    return _variationInternal(flagKey, LDValue.ofNum(defaultValue),
            isDetailed: false, type: LDValueType.number)
        .value
        .intValue();
  }

  /// Returns the value of flag [flagKey] for the current context as an int, along with information about the resultant value.
  ///
  /// See [LDEvaluationDetail] for more information on the returned value. Note that [LDConfigBuilder.evaluationReasons]
  /// must have been set to `true` to request the additional evaluation information from the backend.
  LDEvaluationDetail<int> intVariationDetail(String flagKey, int defaultValue) {
    final ldValueVariation = _variationInternal(
        flagKey, LDValue.ofNum(defaultValue),
        isDetailed: true, type: LDValueType.number);

    return LDEvaluationDetail(ldValueVariation.value.intValue(),
        ldValueVariation.variationIndex, ldValueVariation.reason);
  }

  /// Returns the value of flag [flagKey] for the current context as a double.
  ///
  /// Will return the provided [defaultValue] if the flag is missing, not a number, or if some error occurs.
  double doubleVariation(String flagKey, double defaultValue) {
    return _variationInternal(flagKey, LDValue.ofNum(defaultValue),
            isDetailed: false, type: LDValueType.number)
        .value
        .doubleValue();
  }

  /// Returns the value of flag [flagKey] for the current context as a double, along with information about the resultant value.
  ///
  /// See [LDEvaluationDetail] for more information on the returned value. Note that [LDConfigBuilder.evaluationReasons]
  /// must have been set to `true` to request the additional evaluation information from the backend.
  LDEvaluationDetail<double> doubleVariationDetail(
      String flagKey, double defaultValue) {
    final ldValueVariation = _variationInternal(
        flagKey, LDValue.ofNum(defaultValue),
        isDetailed: true, type: LDValueType.number);

    return LDEvaluationDetail(ldValueVariation.value.doubleValue(),
        ldValueVariation.variationIndex, ldValueVariation.reason);
  }

  /// Returns the value of flag [flagKey] for the current context as a string.
  ///
  /// Will return the provided [defaultValue] if the flag is missing, not a string, or if some error occurs.
  String stringVariation(String flagKey, String defaultValue) {
    return _variationInternal(flagKey, LDValue.ofString(defaultValue),
            isDetailed: false, type: LDValueType.string)
        .value
        .stringValue();
  }

  //
  /// Returns the value of flag [flagKey] for the current context as a string, along with information about the resultant value.
  ///
  /// See [LDEvaluationDetail] for more information on the returned value. Note that [LDConfigBuilder.evaluationReasons]
  /// must have been set to `true` to request the additional evaluation information from the backend.
  LDEvaluationDetail<String> stringVariationDetail(
      String flagKey, String defaultValue) {
    final ldValueVariation = _variationInternal(
        flagKey, LDValue.ofString(defaultValue),
        isDetailed: true, type: LDValueType.string);

    return LDEvaluationDetail(ldValueVariation.value.stringValue(),
        ldValueVariation.variationIndex, ldValueVariation.reason);
  }

  /// Returns the value of flag [flagKey] for the current context as an [LDValue].
  ///
  /// Will return the provided [defaultValue] if the flag is missing, or if some error occurs.
  LDValue jsonVariation(String flagKey, LDValue defaultValue) {
    return _variationInternal(flagKey, defaultValue, isDetailed: false).value;
  }

  /// Returns the value of flag [flagKey] for the current context as an [LDValue], along with information about the resultant value.
  ///
  /// See [LDEvaluationDetail] for more information on the returned value. Note that [LDConfigBuilder.evaluationReasons]
  /// must have been set to `true` to request the additional evaluation information from the backend.
  LDEvaluationDetail<LDValue> jsonVariationDetail(
      String flagKey, LDValue defaultValue) {
    return _variationInternal(flagKey, defaultValue, isDetailed: true);
  }

  LDEvaluationDetail<LDValue> _variationInternal(
      String flagKey, LDValue defaultValue,
      {required bool isDetailed, LDValueType? type}) {
    final evalResult = _flagManager.get(flagKey);

    LDEvaluationDetail<LDValue> detail;

    if (evalResult != null && evalResult.flag != null) {
      if (type == null || type == evalResult.flag!.detail.value.type) {
        detail = evalResult.flag!.detail;
      } else {
        detail = LDEvaluationDetail(defaultValue, null,
            LDEvaluationReason.error(errorKind: LDErrorKind.wrongType));
      }
    } else {
      detail =
          LDEvaluationDetail(defaultValue, null, LDEvaluationReason.unknown());
    }

    _eventProcessor.processEvalEvent(EvalEvent(
        flagKey: flagKey,
        defaultValue: defaultValue,
        evaluationDetail: detail,
        context: _context,
        // Include the reason when available if this is a detailed evaluation.
        withReason: isDetailed,
        trackEvent: evalResult?.flag?.trackEvents ?? false,
        debugEventsUntilDate: evalResult?.flag?.debugEventsUntilDate != null
            ? DateTime.fromMillisecondsSinceEpoch(
                evalResult!.flag!.debugEventsUntilDate!)
            : null,
        version: evalResult?.version));

    return detail;
  }

  /// Returns a map of all feature flags for the current context, without sending evaluation events to LaunchDarkly.
  ///
  /// The resultant map contains an entry for each known flag, the key being the flag's key and the value being its
  /// value as an [LDValue].
  Map<String, LDValue> allFlags() {
    final res = <String, LDValue>{};

    final allEvalResults = _flagManager.getAll();

    for (var MapEntry(key: flagKey, value: evalResult)
        in allEvalResults.entries) {
      if (evalResult.flag != null) {
        res[flagKey] = evalResult.flag!.detail.value;
      }
    }

    return res;
  }

  /// Set the connection mode the SDK should use.
  void setMode(ConnectionMode mode) {
    _dataSourceManager.setMode(mode);
  }

  void setNetworkAvailability(bool available) {
    _dataSourceManager.setNetworkAvailable(available);
  }

  bool get offline =>
      _dataSourceStatusManager.status.state == DataSourceState.setOffline;

  /// Get the logger for the client. This is primarily intended for SDK wrappers
  /// and LaunchDarkly provided modules. It is not recommended that this
  /// instance is used for general purpose logging.
  LDLogger get logger => _logger;

  /// Track custom events associated with the current context for data export or experimentation.
  ///
  /// The [eventName] is the key associated with the event or experiment. [data] is an optional parameter for additional
  /// data to include in the event for data export. [metricValue] can be used to record numeric metric for experimentation.
  void track(String eventName, {LDValue? data, num? metricValue}) async {
    _eventProcessor.processCustomEvent(CustomEvent(
        key: eventName,
        context: _context,
        metricValue: metricValue,
        data: data));
  }

  /// Permanently shuts down the client.
  ///
  /// It's not normally necessary to explicitly shut down the client.
  void close() {
    _eventProcessor.stop();
    _dataSourceManager.stop();
    _dataSourceStatusManager.stop();
  }
}
