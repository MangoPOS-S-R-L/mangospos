// Bottom sheet para elegir destino de pre-cuenta cuando hay >1 disponible.
//
// UX inspirada en el screenshot del cliente: lista de destinos con icono
// según tipo (LAN/USB/BT/pantalla), nombre, subtítulo con detalle de
// conexión y badge de salud (verde/amarillo/rojo).
//
// La elección se memoriza por device en SharedPreferences vía
// PrechecPrinterPreference, así la próxima vez aparece pre-seleccionada
// la última usada.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/models/printing_v2.dart';
import 'package:mangopos/services/printing/print_destination.dart';

/// Muestra el bottom sheet. Retorna el destino elegido o null si el
/// usuario cerró sin elegir.
Future<PrintDestination?> showPrintDestinationPicker(
  BuildContext context, {
  required List<PrintDestination> destinations,
  String title = '¿Dónde imprimir la pre-cuenta?',
  String? recentlyUsedKey,
}) {
  return showModalBottomSheet<PrintDestination>(
    context: context,
    // Root navigator SIEMPRE: el picker de recibo se dispara con el modal
    // de pago todavía abierto (dialog en el ROOT navigator). Sin esto, el
    // sheet se monta en el navigator anidado del shell y queda DETRÁS del
    // modal: el cajero ve "Imprimiendo..." eterno sin saber que hay un
    // selector invisible esperándolo (caso real 2026-07-26 — la factura
    // "se trababa" hasta que alguien daba ESC).
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _PrintDestinationPickerSheet(
      destinations: destinations,
      title: title,
      recentlyUsedKey: recentlyUsedKey,
    ),
  );
}

/// Persistencia de la impresora fijada por device para pre-cuenta.
///
/// Aunque el nombre histórico es 'Precheck', semánticamente desde Slice 2
/// representa la impresora "fijada" para este device — la primera elección
/// queda persistida y se reusa hasta que el cajero la cambie (long press
/// en Pre-Cuenta para forzar el picker).
///
/// Para la impresora de recibos post-pago ver [ReceiptPrinterPreference].
class PrechecPrinterPreference {
  static const _keyPrefix = 'precheck_last_destination_';

  /// Lee el persistKey fijado para este device. Retorna null si nunca
  /// se fijó o el preference no es accesible.
  static Future<String?> read(String deviceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('$_keyPrefix$deviceId');
    } catch (_) {
      return null;
    }
  }

  /// Guarda el persistKey. Fail-soft: si SharedPreferences truena, no
  /// rompe el flujo de impresión.
  static Future<void> save(String deviceId, String persistKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_keyPrefix$deviceId', persistKey);
    } catch (_) {
      // ignore
    }
  }
}

/// Persistencia de la impresora fijada por device para factura/recibo
/// post-pago (Slice 3). Diferente storage que PrechecPrinterPreference —
/// el cajero puede tener una impresora distinta para precuenta vs recibo
/// si así lo quiere.
///
/// NOTA: tiene precedencia menor que `cash_register.receipt_printer_id`.
/// Si el admin asignó una impresora a la caja, esa gana siempre y este
/// pin nunca se usa.
class ReceiptPrinterPreference {
  static const _keyPrefix = 'receipt_pinned_destination_';

  static Future<String?> read(String deviceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('$_keyPrefix$deviceId');
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String deviceId, String persistKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_keyPrefix$deviceId', persistKey);
    } catch (_) {
      // ignore
    }
  }
}

class _PrintDestinationPickerSheet extends StatelessWidget {
  final List<PrintDestination> destinations;
  final String title;
  final String? recentlyUsedKey;

  const _PrintDestinationPickerSheet({
    required this.destinations,
    required this.title,
    this.recentlyUsedKey,
  });

  @override
  Widget build(BuildContext context) {
    final sorted = _sortDestinations(destinations, recentlyUsedKey);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE5E5E5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text(
                title,
                style: GoogleFonts.inter(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: const Color(0xFF111111),
                ),
              ),
            ),
            const Divider(height: 1, color: Color(0xFFE5E5E5)),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.6,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: sorted.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: Color(0xFFF1F1F1)),
                itemBuilder: (ctx, i) {
                  final dest = sorted[i];
                  return _DestinationTile(
                    destination: dest,
                    isRecentlyUsed: recentlyUsedKey != null &&
                        dest.persistKey == recentlyUsedKey,
                    onTap: () => Navigator.of(ctx).pop(dest),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Pone la última usada al tope; el resto mantiene su orden de entrada.
  List<PrintDestination> _sortDestinations(
    List<PrintDestination> list,
    String? recentKey,
  ) {
    if (recentKey == null) return list;
    final recent = <PrintDestination>[];
    final others = <PrintDestination>[];
    for (final d in list) {
      if (d.persistKey == recentKey) {
        recent.add(d);
      } else {
        others.add(d);
      }
    }
    return [...recent, ...others];
  }
}

class _DestinationTile extends StatelessWidget {
  final PrintDestination destination;
  final bool isRecentlyUsed;
  final VoidCallback onTap;

  const _DestinationTile({
    required this.destination,
    required this.isRecentlyUsed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            _icon(),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          destination.displayName,
                          style: GoogleFonts.inter(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: const Color(0xFF111111),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isRecentlyUsed) ...[
                        const SizedBox(width: 8),
                        _badge('Última usada', const Color(0xFF6B7280)),
                      ],
                    ],
                  ),
                  if (destination.subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      destination.subtitle!,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: const Color(0xFF888888),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            _healthBadge(),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right,
                size: 20, color: Color(0xFFAAAAAA)),
          ],
        ),
      ),
    );
  }

  Widget _icon() {
    final iconData = switch (destination.kind) {
      PrintDestinationKind.printer => _printerIcon(),
      PrintDestinationKind.screenOnly => Icons.desktop_windows_outlined,
    };
    final color = destination.kind == PrintDestinationKind.screenOnly
        ? const Color(0xFF6366F1)
        : const Color(0xFFF97316);
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Icon(iconData, color: color, size: 20),
    );
  }

  IconData _printerIcon() {
    final printer = destination.printer;
    if (printer == null) return Icons.print_outlined;
    return switch (printer.transport) {
      PrinterTransport.bluetooth => Icons.bluetooth,
      PrinterTransport.usb => Icons.usb,
      PrinterTransport.serial => Icons.cable,
      PrinterTransport.cups => Icons.print,
      PrinterTransport.lan => Icons.lan_outlined,
    };
  }

  Widget _healthBadge() {
    final health = destination.health;
    if (destination.kind == PrintDestinationKind.screenOnly) {
      return const SizedBox.shrink();
    }
    if (health == null) {
      // Sin probe nunca → gris.
      return _statusDot(const Color(0xFFAAAAAA), 'Sin datos');
    }
    final status = health.status;
    if (status.isOperational) {
      return _statusDot(const Color(0xFF10B981), 'OK');
    }
    if (status.needsAttention) {
      return _statusDot(const Color(0xFFF59E0B), _labelForStatus(status));
    }
    if (status == PrinterHealthStatus.offline) {
      return _statusDot(const Color(0xFFEF4444), 'Offline');
    }
    return _statusDot(const Color(0xFFAAAAAA), 'Desconocido');
  }

  Widget _statusDot(Color color, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  String _labelForStatus(PrinterHealthStatus s) => switch (s) {
        PrinterHealthStatus.noPaper => 'Sin papel',
        PrinterHealthStatus.coverOpen => 'Tapa abierta',
        PrinterHealthStatus.error => 'Error',
        _ => 'Atención',
      };

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
