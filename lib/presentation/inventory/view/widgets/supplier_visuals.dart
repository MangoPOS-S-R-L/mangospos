// Identidad visual de un proveedor: su color, su avatar y el chip que resume
// las condiciones.
//
// La lista y el interior tienen que hablar del MISMO proveedor: si Ferretti
// es azul con «DF» en la fila, adentro sigue siendo azul con «DF». Con los
// colores calculados en cada pantalla eso duraba hasta el primer cambio —es
// la misma lección de `warehouse_visuals.dart`, y por eso comparte la paleta.
//
// El chip de condiciones vive acá y no dentro de la pantalla para que la
// prueba de desbordes monte EXACTAMENTE el widget que se usa en producción.

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../state/supplier_overview_state.dart';

/// Paleta rotativa, la misma de Bodegas e Insumos v2.
const List<Color> kSupplierAccents = <Color>[
  AppColors.info,
  AppColors.success,
  AppColors.reserved,
  AppColors.warning,
  Color(0xFF0EA5E9),
  Color(0xFFEC4899),
  Color(0xFF14B8A6),
];

/// Gris del proveedor desactivado: sigue visible para auditoría, pero no
/// compite con los que operan.
const Color kSupplierInactive = Color(0xFFC4BDB8);

/// Color de un proveedor según su rol y su posición en la lista.
Color supplierAccent({
  required int index,
  required bool isPreferred,
  required bool isActive,
}) {
  if (!isActive) return kSupplierInactive;
  // El preferido de algún insumo lleva el naranja de marca: es el proveedor
  // que el negocio ya eligió, no uno más de la lista.
  if (isPreferred) return AppColors.primary;
  return kSupplierAccents[index % kSupplierAccents.length];
}

/// Color e ícono de unas condiciones de pago.
///
/// «Sin definir» es ÁMBAR y no gris a propósito: no es un dato faltante
/// cualquiera, es el que impide calcular cualquier vencimiento.
({Color color, IconData icon}) supplierTermsStyle(SupplierTerms terms) {
  switch (terms.type) {
    case SupplierTermsType.contado:
      return (color: AppColors.success, icon: Icons.payments_outlined);
    case SupplierTermsType.credito:
      return (color: AppColors.info, icon: Icons.credit_card);
    case SupplierTermsType.anticipo:
      return (color: AppColors.reserved, icon: Icons.credit_score_outlined);
    case null:
      return terms.freeText.trim().isEmpty
          ? (color: AppColors.warning, icon: Icons.help_outline)
          // Hay texto pero no se pudo interpretar: se muestra literal con un
          // ícono neutro. Pintarlo de alarma castigaría a quien SÍ escribió
          // sus condiciones, sólo que en un formato que no es un plazo.
          : (color: AppColors.mutedForeground, icon: Icons.notes_outlined);
  }
}

/// Alto MÍNIMO de un chip. Mínimo y no fijo: con la escala de texto del
/// sistema al doble, una caja rígida recorta la etiqueta y Flutter pinta las
/// franjas de desborde. Así la fila crece un poco en vez de romperse.
const double kSupplierChipMinHeight = 24;

/// Avatar del proveedor: sus iniciales sobre su color.
class SupplierAvatar extends StatelessWidget {
  final String initials;
  final Color color;
  final double size;

  const SupplierAvatar({
    super.key,
    required this.initials,
    required this.color,
    this.size = 36,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.iconBox),
      ),
      child: Text(
        initials,
        maxLines: 1,
        style: TextStyle(
          fontSize: size * 0.36,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

/// Chip de las condiciones de pago: «Crédito 30 días», «Contado»,
/// «Sin definir».
class SupplierTermsChip extends StatelessWidget {
  final SupplierTerms terms;

  /// El plazo se dedujo del texto libre y todavía no lo confirmó nadie. Se
  /// marca con un borde punteado en vez de esconderlo: la diferencia entre
  /// «30 días» escrito a mano y «30 días» configurado es justo la que decide
  /// si se puede calcular un vencimiento.
  final bool showUnconfirmed;

  const SupplierTermsChip({
    super.key,
    required this.terms,
    this.showUnconfirmed = true,
  });

  @override
  Widget build(BuildContext context) {
    final style = supplierTermsStyle(terms);
    final unconfirmed =
        showUnconfirmed && terms.type != null && !terms.structured;

    return Container(
      constraints: const BoxConstraints(minHeight: kSupplierChipMinHeight),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: style.color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: unconfirmed
            ? Border.all(color: style.color.withValues(alpha: 0.45))
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.icon, size: 13, color: style.color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              terms.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: style.color,
              ),
            ),
          ),
          if (unconfirmed) ...[
            const SizedBox(width: 4),
            Icon(
              Icons.help_outline,
              size: 12,
              color: style.color.withValues(alpha: 0.75),
            ),
          ],
        ],
      ),
    );
  }
}

/// Etiqueta chica del nombre: «PRINCIPAL», «FALTA RNC», «INACTIVO».
class SupplierTag extends StatelessWidget {
  final String label;
  final Color color;

  const SupplierTag({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 18),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

/// Barra de cumplimiento: qué porcentaje de las órdenes llegó completo.
///
/// Sin órdenes resueltas NO se pinta una barra en cero: eso acusaría de
/// incumplir a un proveedor al que todavía no se le compró nada.
class SupplierFulfillmentBar extends StatelessWidget {
  final double? pct;
  final String label;

  const SupplierFulfillmentBar({super.key, this.pct, required this.label});

  /// Verde arriba de 90, ámbar entre 70 y 90, rojo por debajo. El corte de 90
  /// no es cosmético: una de cada diez órdenes incompleta ya obliga a
  /// recomprar.
  static Color colorFor(double? pct) {
    if (pct == null) return kSupplierInactive;
    if (pct >= 90) return AppColors.success;
    if (pct >= 70) return AppColors.warning;
    return AppColors.destructive;
  }

  @override
  Widget build(BuildContext context) {
    final value = pct;
    final color = colorFor(value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: value == null ? 0 : (value / 100).clamp(0.0, 1.0),
            minHeight: 6,
            backgroundColor: AppColors.muted,
            color: color,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10.5, color: AppColors.mutedForeground),
        ),
      ],
    );
  }
}
