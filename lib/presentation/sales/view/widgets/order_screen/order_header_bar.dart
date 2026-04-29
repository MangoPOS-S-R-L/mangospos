import 'package:flutter/material.dart';

/// 🏷️ Barra superior del carrito con info contextual.
///
/// Muestra (de izquierda a derecha):
///   - **Título** (ej. "Venta Rápida", "Venta Manual", o nombre de mesa).
///   - **Subtítulo** opcional (ej. "X productos", o estado de la orden).
///   - **Selector de cliente** (botón compacto que muestra "Cliente" o el nombre).
///   - **Selector de comprobante fiscal** (dropdown del tipo NCF).
///
/// El widget es puro: emite callbacks. La vista que lo embebe coordina con
/// `sales_viewmodel` (ej. para asignar cliente, cambiar fiscalType).
class OrderHeaderBar extends StatelessWidget {
  final String title;
  final String? subtitle;

  /// Nombre del cliente asignado, o null si no hay.
  final String? customerName;

  /// Tipo fiscal actual (ej. "02", "01", "B02"). Si es null, muestra "Sin configurar".
  final String? fiscalType;

  /// Mapa de fiscalType → label legible para el dropdown.
  /// Ejemplo: {'02': 'Consumo (02)', '01': 'Crédito Fiscal (01)'}.
  /// Si es vacío, el selector de NCF no se renderiza.
  final Map<String, String> fiscalTypeOptions;

  /// Callback al tocar el botón de cliente.
  /// Si es null, el botón no se renderiza.
  final VoidCallback? onTapCustomer;

  /// Callback cuando se selecciona un fiscalType del dropdown.
  /// Si es null, el dropdown no se renderiza.
  final void Function(String fiscalType)? onSelectFiscalType;

  const OrderHeaderBar({
    super.key,
    required this.title,
    this.subtitle,
    this.customerName,
    this.fiscalType,
    this.fiscalTypeOptions = const {},
    this.onTapCustomer,
    this.onSelectFiscalType,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB), width: 1)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF2C2C2C),
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF7A7A7A),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onTapCustomer != null) ...[
            _CustomerChip(
              customerName: customerName,
              onTap: onTapCustomer!,
            ),
            const SizedBox(width: 8),
          ],
          if (onSelectFiscalType != null && fiscalTypeOptions.isNotEmpty)
            _FiscalTypeChip(
              currentValue: fiscalType,
              options: fiscalTypeOptions,
              onSelect: onSelectFiscalType!,
            ),
        ],
      ),
    );
  }
}

class _CustomerChip extends StatelessWidget {
  final String? customerName;
  final VoidCallback onTap;

  const _CustomerChip({required this.customerName, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hasCustomer = customerName != null && customerName!.isNotEmpty;
    final label = hasCustomer ? customerName! : 'Cliente';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFE5E7EB)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.person_outline,
              size: 16,
              color: hasCustomer
                  ? const Color(0xFFF97316)
                  : const Color(0xFF7A7A7A),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: hasCustomer
                    ? const Color(0xFFF97316)
                    : const Color(0xFF7A7A7A),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FiscalTypeChip extends StatelessWidget {
  final String? currentValue;
  final Map<String, String> options;
  final void Function(String) onSelect;

  const _FiscalTypeChip({
    required this.currentValue,
    required this.options,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final currentLabel = currentValue == null
        ? 'Sin configurar'
        : (options[currentValue!] ?? currentValue!);

    return PopupMenuButton<String>(
      tooltip: 'Tipo de comprobante',
      onSelected: onSelect,
      itemBuilder: (_) => options.entries
          .map(
            (e) => PopupMenuItem<String>(
              value: e.key,
              child: Text(e.value),
            ),
          )
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFE5E7EB)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              currentLabel,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF2C2C2C),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.arrow_drop_down,
              size: 18,
              color: Color(0xFF7A7A7A),
            ),
          ],
        ),
      ),
    );
  }
}
