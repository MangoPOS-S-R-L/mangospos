// Pistola de código de barras en el módulo de Inventario.
//
// La infraestructura del lector ya existe (`ScanDispatcher` +
// `BarcodeScanListener`, en el módulo de ventas): un solo handler de teclado
// para toda la app y una pila de suscriptores, para que el escaneo llegue
// SOLO a la pantalla de arriba.
//
// Lo que falta acá es la otra mitad: convertir el código en un insumo. Y eso
// no puede ser la misma búsqueda que usa una persona.

import 'package:flutter/material.dart';

import '../../../core/utils/app_toast.dart';
import '../../sales/widgets/pos_barcode_scanner.dart';
import '../state/inventory_state.dart';

/// Cómo termina un escaneo.
enum ScanOutcome {
  /// Un solo insumo, sin ambigüedad.
  resolved,

  /// El código no corresponde a ningún insumo conocido.
  notFound,

  /// Varios insumos comparten ese código. No se elige por el usuario: se le
  /// avisa, porque adivinar acá mete mercancía en el insumo equivocado.
  ambiguous,
}

class ScanResult {
  final ScanOutcome outcome;
  final InventoryItemSummary? item;
  final List<InventoryItemSummary> candidates;

  const ScanResult._(this.outcome, this.item, this.candidates);

  const ScanResult.resolved(InventoryItemSummary item)
      : this._(ScanOutcome.resolved, item, const []);
  const ScanResult.notFound() : this._(ScanOutcome.notFound, null, const []);
  const ScanResult.ambiguous(List<InventoryItemSummary> candidates)
      : this._(ScanOutcome.ambiguous, null, candidates);

  bool get isResolved => outcome == ScanOutcome.resolved;
}

/// Resuelve un código escaneado contra el catálogo de insumos.
///
/// POR QUÉ NO SE REUSA LA BÚSQUEDA DE LA PANTALLA:
///   La búsqueda que teclea una persona es un `contains` sobre nombre, SKU,
///   descripción y código — está bien para buscar "harina". Para una pistola
///   es peligroso: escanear `7461` casaría con cualquier insumo cuyo NOMBRE
///   contenga esos dígitos, y el operador no se entera de que agregó otra
///   cosa. Un código de barras es una identidad, no un texto parecido.
///
/// PRECEDENCIA, de más fuerte a más débil:
///   1. Código de barras EXACTO.
///   2. SKU EXACTO.
///   3. Un único insumo cuyo código o SKU CONTENGA lo escaneado. Cubre al
///      lector que antepone ceros o corta un dígito de control; sólo se
///      acepta cuando hay uno y nada más que uno.
///
/// Si dos insumos comparten el mismo código, devuelve `ambiguous` en vez de
/// elegir: son datos mal cargados y hay que arreglarlos, no taparlos.
ScanResult resolveScannedItem(
  List<InventoryItemSummary> items,
  String rawCode, {
  bool onlyActive = true,
}) {
  final code = rawCode.trim().toLowerCase();
  if (code.isEmpty) return const ScanResult.notFound();

  final universo = onlyActive
      ? items.where((i) => i.isActive).toList(growable: false)
      : items;

  List<InventoryItemSummary> porExacto(String Function(InventoryItemSummary) f) =>
      universo
          .where((i) => f(i).trim().toLowerCase() == code)
          .toList(growable: false);

  for (final campo in <String Function(InventoryItemSummary)>[
    (i) => i.barcode,
    (i) => i.sku,
  ]) {
    final exactos = porExacto(campo);
    if (exactos.length == 1) return ScanResult.resolved(exactos.first);
    if (exactos.length > 1) return ScanResult.ambiguous(exactos);
  }

  final parciales = universo
      .where((i) =>
          (i.barcode.trim().isNotEmpty &&
              i.barcode.toLowerCase().contains(code)) ||
          (i.sku.trim().isNotEmpty && i.sku.toLowerCase().contains(code)))
      .toList(growable: false);
  if (parciales.length == 1) return ScanResult.resolved(parciales.first);
  if (parciales.length > 1) return ScanResult.ambiguous(parciales);

  return const ScanResult.notFound();
}

/// Envuelve una pantalla de inventario para que la pistola funcione ahí.
///
/// Se apoya en [BarcodeScanListener], así que hereda su comportamiento: sólo
/// la pantalla de más arriba recibe el escaneo, y un tecleo humano no lo
/// dispara.
///
/// [onItem] recibe el insumo ya resuelto. [onUnresolved] es opcional: sirve
/// para reintentar contra la red cuando el insumo pudo darse de alta en otra
/// terminal. Si no se pasa, el aviso lo da este widget.
class InventoryScanListener extends StatelessWidget {
  const InventoryScanListener({
    super.key,
    required this.enabled,
    required this.items,
    required this.onItem,
    required this.child,
    this.onUnresolved,
    this.onlyActive = true,
  });

  final bool enabled;
  final List<InventoryItemSummary> items;
  final ValueChanged<InventoryItemSummary> onItem;
  final void Function(String code)? onUnresolved;
  final bool onlyActive;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return BarcodeScanListener(
      enabled: enabled,
      onScan: (code) {
        final resultado =
            resolveScannedItem(items, code, onlyActive: onlyActive);
        switch (resultado.outcome) {
          case ScanOutcome.resolved:
            onItem(resultado.item!);
          case ScanOutcome.notFound:
            if (onUnresolved != null) {
              onUnresolved!(code.trim());
            } else {
              AppToast.warning(
                context,
                'Ningún insumo con el código "${code.trim()}".',
              );
            }
          case ScanOutcome.ambiguous:
            // Decir CUÁNTOS y pedir que se arregle: elegir uno al azar
            // metería mercancía en el insumo equivocado.
            AppToast.warning(
              context,
              '${resultado.candidates.length} insumos comparten el código '
              '"${code.trim()}". Corregí el duplicado en Insumos.',
            );
        }
      },
      child: child,
    );
  }
}
