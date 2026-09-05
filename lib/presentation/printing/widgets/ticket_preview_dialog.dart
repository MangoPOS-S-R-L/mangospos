// lib/presentation/printing/widgets/ticket_preview_dialog.dart
//
// Salida en pantalla del "modo sin impresora" (ver
// core/printing/printerless_mode.dart). Muestra el ticket con el MISMO
// layout que saldría en papel — el texto viene de `PrintTicket.rawText`,
// que el EscPosGenerator arma en paralelo a los bytes ESC/POS — y ofrece
// compartirlo en PDF (WhatsApp, correo, guardar) o mandarlo a una
// impresora normal del sistema operativo.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../data/models/printing.dart' show PrintTicket;
import 'package:mangopos/core/utils/app_snackbar.dart';

/// Muestra [ticket] en pantalla. No-op silencioso si el ticket no trae
/// texto plano (caso de tickets 100% gráficos), para no dejar al cajero
/// mirando un modal vacío.
Future<void> showPrintTicketOnScreen(
  BuildContext context, {
  required PrintTicket ticket,
  required String title,
  String? subtitle,
  String fileNamePrefix = 'ticket',
}) {
  final text = ticket.rawText ?? '';
  if (text.trim().isEmpty) return Future<void>.value();
  return showTicketPreviewDialog(
    context,
    title: title,
    plainText: text,
    subtitle: subtitle,
    fileNamePrefix: fileNamePrefix,
  );
}

Future<void> showTicketPreviewDialog(
  BuildContext context, {
  required String title,
  required String plainText,
  String? subtitle,
  String fileNamePrefix = 'ticket',
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _TicketPreviewDialog(
      title: title,
      subtitle: subtitle,
      plainText: plainText,
      fileNamePrefix: fileNamePrefix,
    ),
  );
}

class _TicketPreviewDialog extends StatefulWidget {
  final String title;
  final String? subtitle;
  final String plainText;
  final String fileNamePrefix;

  const _TicketPreviewDialog({
    required this.title,
    required this.plainText,
    required this.fileNamePrefix,
    this.subtitle,
  });

  @override
  State<_TicketPreviewDialog> createState() => _TicketPreviewDialogState();
}

class _TicketPreviewDialogState extends State<_TicketPreviewDialog> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxHeight = media.size.height * 0.82;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 460, maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context),
            Flexible(child: _paper(context)),
            _actions(context),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: const Color(0xFFEAF0FF),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.receipt_long_rounded,
              size: 20,
              color: Color(0xFF2563EB),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  widget.subtitle ?? 'Modo sin impresora',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Cerrar',
            icon: const Icon(Icons.close_rounded),
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  /// El "papel": fondo blanco y texto monoespaciado en ambos temas, para
  /// que el cajero (o el cliente al que le enseñan la pantalla) vea lo
  /// mismo que saldría impreso.
  Widget _paper(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Scrollbar(
        child: SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(
              widget.plainText,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: ['Courier New', 'Menlo', 'monospace'],
                fontSize: 11,
                height: 1.25,
                color: Color(0xFF111827),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _actions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: [
          TextButton.icon(
            onPressed: _busy ? null : _copy,
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Copiar'),
          ),
          TextButton.icon(
            onPressed: _busy ? null : _printWithOs,
            icon: const Icon(Icons.print_outlined, size: 18),
            label: const Text('Impresora del sistema'),
          ),
          FilledButton.icon(
            onPressed: _busy ? null : _sharePdf,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share_rounded, size: 18),
            label: const Text('Compartir PDF'),
          ),
        ],
      ),
    );
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.plainText));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showAppSnackBar(
      const SnackBar(
        duration: Duration(seconds: 2),
        content: Text('Ticket copiado al portapapeles'),
      ),
    );
  }

  String get _fileName =>
      '${widget.fileNamePrefix}_${DateTime.now().millisecondsSinceEpoch}.pdf';

  Future<void> _sharePdf() async {
    setState(() => _busy = true);
    try {
      final bytes = await buildTicketPdf(widget.plainText);
      await Printing.sharePdf(bytes: bytes, filename: _fileName);
    } catch (e) {
      _reportFailure('No se pudo generar el PDF: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Manda el ticket al diálogo de impresión del sistema operativo. Sirve
  /// para negocios sin térmica pero con una impresora normal (o "Guardar
  /// como PDF" del SO).
  Future<void> _printWithOs() async {
    setState(() => _busy = true);
    try {
      final bytes = await buildTicketPdf(widget.plainText);
      await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: _fileName,
      );
    } catch (e) {
      _reportFailure('Este dispositivo no ofrece impresión del sistema: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _reportFailure(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showAppSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFFEF4444),
        duration: const Duration(seconds: 4),
        content: Text(message),
      ),
    );
  }
}

/// Arma el PDF del ticket en formato rollo de 80mm, con fuente monoespaciada
/// para que las columnas caigan igual que en la térmica. El tamaño de letra
/// se ajusta a la línea más larga: así un ticket de 48 columnas (80mm) y uno
/// de 32 (58mm) llenan el ancho sin cortarse.
Future<Uint8List> buildTicketPdf(String plainText) async {
  final normalized = _normalizeForPdf(plainText);
  final lines = normalized.split('\n');
  final longest = lines.fold<int>(0, (max, l) => math.max(max, l.length));

  const pageWidth = 80 * PdfPageFormat.mm;
  const margin = 4 * PdfPageFormat.mm;
  final available = pageWidth - (margin * 2);
  // Courier avanza 0.6 em por caracter.
  final fitSize = longest > 0 ? available / (longest * 0.6) : 9.0;
  final fontSize = fitSize.clamp(4.5, 10.0).toDouble();

  final doc = pw.Document();
  final mono = pw.Font.courier();
  final monoBold = pw.Font.courierBold();

  doc.addPage(
    pw.Page(
      pageFormat: const PdfPageFormat(
        pageWidth,
        double.infinity,
        marginAll: margin,
      ),
      build: (context) => pw.Text(
        normalized,
        style: pw.TextStyle(
          font: mono,
          fontBold: monoBold,
          fontSize: fontSize,
          lineSpacing: fontSize * 0.25,
        ),
      ),
    ),
  );

  return doc.save();
}

/// Las fuentes estándar del PDF usan WinAnsi: los acentos pasan, pero los
/// caracteres tipográficos que meten iOS/Word no. Mismo criterio que
/// `EscPosGenerator._encodeText`.
String _normalizeForPdf(String value) {
  return value
      .replaceAll('‘', "'")
      .replaceAll('’', "'")
      .replaceAll('‚', "'")
      .replaceAll('‛', "'")
      .replaceAll('“', '"')
      .replaceAll('”', '"')
      .replaceAll('„', '"')
      .replaceAll('–', '-')
      .replaceAll('—', '-')
      .replaceAll('…', '...')
      .replaceAll('≈', '~')
      .replaceAll('≠', '!=')
      .replaceAll('≤', '<=')
      .replaceAll('≥', '>=')
      .replaceAll(' ', ' ');
}
