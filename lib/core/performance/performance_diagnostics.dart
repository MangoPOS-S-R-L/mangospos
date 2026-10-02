import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'process_memory_stub.dart'
    if (dart.library.io) 'process_memory_io.dart'
    as process_memory;

class _OperationSamples {
  final List<int> milliseconds = [];
  int failures = 0;

  void add(int elapsedMs, {required bool success}) {
    if (milliseconds.length == 500) milliseconds.removeAt(0);
    milliseconds.add(elapsedMs);
    if (!success) failures++;
  }
}

/// Diagnóstico voluntario, local y acotado. Nunca almacena IDs ni importes.
class PerformanceDiagnostics extends ChangeNotifier {
  PerformanceDiagnostics._();

  static final PerformanceDiagnostics instance = PerformanceDiagnostics._();

  final Map<String, _OperationSamples> _operations = {};
  final List<int> _rssBytes = [];
  Timer? _sampleTimer;
  DateTime? _startedAt;
  DateTime? _stoppedAt;
  String _role = '';
  int _frames = 0;
  int _slowFrames = 0;
  int _verySlowFrames = 0;

  bool get isRunning => _startedAt != null && _stoppedAt == null;
  bool get hasReport => _startedAt != null;

  void start({required String role}) {
    if (isRunning) return;
    _operations.clear();
    _rssBytes.clear();
    _frames = 0;
    _slowFrames = 0;
    _verySlowFrames = 0;
    _role = role;
    _startedAt = DateTime.now();
    _stoppedAt = null;
    _sampleMemory();
    SchedulerBinding.instance.addTimingsCallback(_onFrames);
    _sampleTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _sampleMemory(),
    );
    notifyListeners();
  }

  void stop() {
    if (!isRunning) return;
    _stoppedAt = DateTime.now();
    _sampleTimer?.cancel();
    _sampleTimer = null;
    SchedulerBinding.instance.removeTimingsCallback(_onFrames);
    notifyListeners();
  }

  Future<T> measure<T>(
    String name,
    Future<T> Function() operation, {
    bool Function(T value)? accepted,
  }) {
    if (!isRunning) return operation();
    return _measureActive(name, operation, accepted: accepted);
  }

  Future<T> _measureActive<T>(
    String name,
    Future<T> Function() operation, {
    bool Function(T value)? accepted,
  }) async {
    final watch = Stopwatch()..start();
    var success = false;
    try {
      final value = await operation();
      success = accepted?.call(value) ?? true;
      return value;
    } finally {
      watch.stop();
      record(name, watch.elapsedMilliseconds, success: success);
    }
  }

  void record(String name, int elapsedMs, {bool success = true}) {
    if (!isRunning) return;
    _operations
        .putIfAbsent(name, _OperationSamples.new)
        .add(elapsedMs, success: success);
    notifyListeners();
  }

  void _sampleMemory() {
    if (!isRunning) return;
    final bytes = process_memory.currentProcessRssBytes();
    if (bytes == null) return;
    if (_rssBytes.length == 120) _rssBytes.removeAt(0);
    _rssBytes.add(bytes);
    notifyListeners();
  }

  void _onFrames(List<FrameTiming> timings) {
    if (!isRunning) return;
    for (final timing in timings) {
      _frames++;
      final ms = timing.totalSpan.inMilliseconds;
      if (ms > 16) _slowFrames++;
      if (ms > 33) _verySlowFrames++;
    }
    notifyListeners();
  }

  static int _percentile(List<int> values, double percentile) {
    if (values.isEmpty) return 0;
    final sorted = List<int>.from(values)..sort();
    final index = ((sorted.length - 1) * percentile).ceil();
    return sorted[index];
  }

  String get reportText {
    if (_startedAt == null) return 'Aún no hay medición.';
    final end = _stoppedAt ?? DateTime.now();
    final lines = <String>[
      'Diagnóstico de rendimiento MangoPOS',
      'Rol: $_role',
      'Inicio: ${_startedAt!.toIso8601String()}',
      'Duración: ${end.difference(_startedAt!).inSeconds} s',
      'Estado: ${isRunning ? 'en curso' : 'finalizado'}',
      'Frames: $_frames; >16 ms: $_slowFrames; >33 ms: $_verySlowFrames',
    ];
    if (_rssBytes.isNotEmpty) {
      lines.add(
        'Memoria RSS: inicio ${(_rssBytes.first / 1048576).round()} MiB; '
        'última ${(_rssBytes.last / 1048576).round()} MiB; '
        'máxima ${(_rssBytes.reduce((a, b) => a > b ? a : b) / 1048576).round()} MiB',
      );
    }
    for (final entry in _operations.entries) {
      final sample = entry.value;
      lines.add(
        '${entry.key}: n=${sample.milliseconds.length}, '
        'p50=${_percentile(sample.milliseconds, 0.50)} ms, '
        'p95=${_percentile(sample.milliseconds, 0.95)} ms, '
        'fallos=${sample.failures}',
      );
    }
    return lines.join('\n');
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
