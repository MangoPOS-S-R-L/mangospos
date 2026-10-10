import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mangopos/app/theme/mango_colors.dart';

import '../../../../../../data/repositories/pos_settings_repository.dart';

/// Configura el ciclo de notas de venta para consumidor final en efectivo.
/// El contador es informativo: el servidor lo actualiza al emitir documentos.
class SalesNoteSettingsSection extends StatelessWidget {
  const SalesNoteSettingsSection({
    super.key,
    required this.features,
    required this.prefixController,
    required this.limitController,
    required this.onEnabledChanged,
    required this.onLimitSubmitted,
    required this.onPrefixSubmitted,
  });

  final BusinessFeatures features;
  final TextEditingController prefixController;
  final TextEditingController limitController;
  final ValueChanged<bool> onEnabledChanged;

  /// Los callbacks deben ignorar valores sin cambios: `onTapOutside` puede
  /// dispararse con cualquier toque fuera del campo.
  final VoidCallback onLimitSubmitted;
  final VoidCallback onPrefixSubmitted;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: MangoColors.primaryOrange.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.description_outlined,
                color: MangoColors.primaryOrange,
                size: 20,
              ),
            ),
            const SizedBox(width: 16),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Vender por nota de venta',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                  Text(
                    'Solo para consumidor final que paga en efectivo. '
                    'Tarjeta, transferencia y crédito fiscal siempre usan '
                    'factura con comprobante. La nota de venta NO consume NCF.',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Switch(
              value: features.salesNoteEnabled,
              onChanged: onEnabledChanged,
            ),
          ],
        ),
        if (features.salesNoteEnabled) ...[
          const SizedBox(height: 20),
          _settingRow(
            title: 'Notas de venta antes de una factura',
            description:
                'Después de ${features.salesNoteLimit} notas de venta, '
                'el siguiente cobro en efectivo a consumidor final se marca '
                'como factura con comprobante y comienza un nuevo ciclo.',
            control: _field(
              controller: limitController,
              label: 'Cantidad de notas',
              tooltip: 'Guardar cantidad de notas',
              onSubmitted: onLimitSubmitted,
              numeric: true,
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(left: 56),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Notas utilizadas desde la última factura: '
                  '${features.salesNoteCount}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (features.salesNoteCount >= features.salesNoteLimit)
                  const Text(
                    'El próximo cobro en efectivo a consumidor final será '
                    'una factura con comprobante.',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _settingRow(
            title: 'Prefijo de la numeración',
            description:
                'Se imprime como ${features.salesNotePrefix}000123. '
                'Cambiar el prefijo no reinicia la numeración ni el ciclo.',
            control: _field(
              controller: prefixController,
              label: 'Prefijo',
              tooltip: 'Guardar prefijo',
              onSubmitted: onPrefixSubmitted,
            ),
          ),
        ],
      ],
    );
  }

  Widget _settingRow({
    required String title,
    required String description,
    required Widget control,
  }) {
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
        Text(
          description,
          style: const TextStyle(fontSize: 13, color: Colors.grey),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        return Padding(
          padding: const EdgeInsets.only(left: 56),
          child: constraints.maxWidth < 620
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [details, const SizedBox(height: 12), control],
                )
              : Row(
                  children: [
                    Expanded(child: details),
                    const SizedBox(width: 16),
                    control,
                  ],
                ),
        );
      },
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String tooltip,
    required VoidCallback onSubmitted,
    bool numeric = false,
  }) {
    return SizedBox(
      width: numeric ? 220 : 260,
      child: TextField(
        controller: controller,
        textCapitalization: numeric
            ? TextCapitalization.none
            : TextCapitalization.characters,
        keyboardType: numeric ? TextInputType.number : TextInputType.text,
        inputFormatters: numeric
            ? [FilteringTextInputFormatter.digitsOnly]
            : null,
        maxLength: numeric ? null : 6,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => onSubmitted(),
        onTapOutside: (_) => onSubmitted(),
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          counterText: '',
          filled: true,
          fillColor: MangoColors.sidebarBg.withValues(alpha: 0.3),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          suffixIcon: IconButton(
            icon: const Icon(Icons.check_rounded, size: 20),
            tooltip: tooltip,
            onPressed: onSubmitted,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: MangoColors.cardBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: MangoColors.cardBorder),
          ),
        ),
      ),
    );
  }
}
