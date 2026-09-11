import 'package:flutter/material.dart';
import 'package:mangopos/app/theme/mango_colors.dart';

import '../../../../../../data/repositories/pos_settings_repository.dart';

/// Ajustes de la NOTA DE VENTA dentro de Configuración Fiscal.
///
/// La nota no es un comprobante fiscal — no consume NCF ni se declara — pero
/// se configura junto a los que sí lo son porque es el otro documento con el
/// que puede cerrarse una venta.
///
/// Vive en su propio archivo, y no como método de la pantalla, para poder
/// montarlo en un test de layout: la primera versión reventaba con
/// "non-zero flex but incoming width constraints are unbounded" por un
/// `Expanded` dentro de un `Row` anidado sin acotar, y ese tipo de fallo solo
/// aparece al renderizar.
class SalesNoteSettingsSection extends StatelessWidget {
  const SalesNoteSettingsSection({
    super.key,
    required this.features,
    required this.prefixController,
    required this.onEnabledChanged,
    required this.onDefaultChanged,
    required this.onPrefixSubmitted,
  });

  final BusinessFeatures features;

  /// Controlado por la pantalla para poder sembrarlo tras la carga inicial.
  final TextEditingController prefixController;

  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<bool> onDefaultChanged;

  /// Corre al confirmar el campo del prefijo (Enter, botón, o al salir del
  /// campo). Quien lo implemente debe ignorar el caso "no cambió nada":
  /// `onTapOutside` se dispara con cualquier toque de la pantalla.
  final VoidCallback onPrefixSubmitted;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // El Expanded va ACÁ, sobre el Row anidado. Sin él ese Row recibe
            // ancho infinito del Row de afuera, y el Expanded de adentro
            // revienta en layout. El texto de esta fila es largo y necesita
            // envolver, así que el flex no es opcional.
            Expanded(
              child: Row(
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
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          'Documento numerado propio (NV-000123) para el '
                          'cliente que no pide comprobante. NO consume NCF ni '
                          'se declara; la venta igual entra a caja e '
                          'inventario.',
                          style: TextStyle(fontSize: 13, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
              ),
            ),
            Switch(
              value: features.salesNoteEnabled,
              onChanged: onEnabledChanged,
              activeThumbColor: MangoColors.primaryOrange,
            ),
          ],
        ),
        if (features.salesNoteEnabled) ...[
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.only(left: 56, right: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Preseleccionar al cobrar',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        'El cobro arranca en nota de venta en vez del '
                        'comprobante predefinido. El cajero puede cambiarlo '
                        'antes de confirmar.',
                        style: TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ),
              Switch(
                value: features.salesNoteDefault,
                onChanged: onDefaultChanged,
                activeThumbColor: MangoColors.primaryOrange,
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 56, right: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Prefijo de la numeración',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        'Se imprime como '
                        '${features.salesNotePrefix}000123. La serie se lleva '
                        'por los dígitos, así que cambiarlo no la reinicia.',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Ancho fijo con tope: a 1024 dp (las tablets del salón) 260 dp
              // entran, pero en una ventana angosta hay que ceder o el campo
              // empuja al texto fuera de la fila.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: SizedBox(
                  width: 260,
                  child: TextField(
                    controller: prefixController,
                    textCapitalization: TextCapitalization.characters,
                    maxLength: 6,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => onPrefixSubmitted(),
                    onTapOutside: (_) => onPrefixSubmitted(),
                    decoration: InputDecoration(
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
                        tooltip: 'Guardar prefijo',
                        onPressed: onPrefixSubmitted,
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
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
