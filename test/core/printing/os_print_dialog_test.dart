// El panel de impresión del sistema congelaba la app en Mac (y lo mismo pasa
// en iPad): con maquetación dinámica el plugin bloquea el hilo principal
// esperando el PDF, y Dart corre en ese mismo hilo. Ver
// lib/core/printing/os_print_dialog.dart.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/printing/os_print_dialog.dart';

void main() {
  test('Mac e iPad arman el PDF antes de abrir el panel', () {
    expect(
      osPrintNeedsStaticLayout(platform: TargetPlatform.macOS, isWeb: false),
      isTrue,
    );
    expect(
      osPrintNeedsStaticLayout(platform: TargetPlatform.iOS, isWeb: false),
      isTrue,
    );
  });

  test('Windows, Android y web conservan la maquetación dinámica', () {
    for (final p in [
      TargetPlatform.windows,
      TargetPlatform.android,
      TargetPlatform.linux,
    ]) {
      expect(
        osPrintNeedsStaticLayout(platform: p, isWeb: false),
        isFalse,
        reason: '$p',
      );
    }
    expect(
      osPrintNeedsStaticLayout(platform: TargetPlatform.macOS, isWeb: true),
      isFalse,
    );
  });

  test('nadie llama Printing.layoutPdf directo (congelaría Mac/iPad)', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('os_print_dialog.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (line.startsWith('//')) continue;
        if (line.contains('Printing.layoutPdf(')) {
          offenders.add('${entity.path}:${i + 1}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'Usa printWithOsDialog() de core/printing/os_print_dialog.dart',
    );
  });
}
