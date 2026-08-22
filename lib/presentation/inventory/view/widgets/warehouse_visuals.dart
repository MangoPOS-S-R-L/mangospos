// Identidad visual de una bodega: su color y su ícono.
//
// El mapa y el interior tienen que hablar del MISMO sitio: si la Cocina es
// azul con la olla en la tarjeta, adentro sigue siendo azul con la olla. Con
// los colores calculados en cada pantalla eso duraba hasta el primer cambio.
//
// El color sale de la posición en la lista (estable mientras no se creen ni
// borren bodegas) salvo dos casos con significado propio: la principal usa
// el naranja de marca y la inactiva un gris que la saca de la conversación.

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';

/// Paleta rotativa. Es la misma de las columnas de Insumos v2, así que el
/// punto de la columna "Bar" y la tarjeta de Bar coinciden.
const List<Color> kWarehouseAccents = <Color>[
  AppColors.info,
  AppColors.reserved,
  AppColors.success,
  AppColors.warning,
  Color(0xFF0EA5E9),
  Color(0xFFEC4899),
  Color(0xFF14B8A6),
];

/// Gris de la bodega desactivada.
const Color kWarehouseInactive = Color(0xFFC4BDB8);

/// Color de una bodega según su rol y posición.
Color warehouseAccent({
  required int index,
  required bool isMain,
  required bool isActive,
}) {
  if (!isActive) return kWarehouseInactive;
  if (isMain) return AppColors.primary;
  return kWarehouseAccents[index % kWarehouseAccents.length];
}

/// Ícono deducido del nombre. No hay campo de tipo en `warehouses` y pedirlo
/// sería un formulario más para algo que el nombre ya dice: en la práctica
/// los almacenes se llaman Cocina, Bar, Depósito. Cuando no se reconoce nada,
/// cae en el ícono genérico de almacén — nunca en un ícono equivocado.
IconData warehouseIcon(String name, {bool isInTransit = false}) {
  if (isInTransit) return Icons.local_shipping_outlined;
  final n = name.toLowerCase();
  if (n.contains('cocina') || n.contains('kitchen')) {
    return Icons.soup_kitchen_outlined;
  }
  if (n.contains('bar') || n.contains('barra')) return Icons.local_bar_outlined;
  if (n.contains('nevera') ||
      n.contains('refri') ||
      n.contains('congel') ||
      n.contains('frío') ||
      n.contains('frio')) {
    return Icons.ac_unit_outlined;
  }
  if (n.contains('tienda') || n.contains('salón') || n.contains('salon')) {
    return Icons.storefront_outlined;
  }
  if (n.contains('depósito') || n.contains('deposito')) {
    return Icons.inventory_2_outlined;
  }
  return Icons.warehouse_outlined;
}

/// Alto MÍNIMO de un chip de estado. Es mínimo y no fijo a propósito: con la
/// escala de texto del sistema al doble, una caja rígida de 26 recorta la
/// etiqueta y Flutter pinta las franjas de overflow. Así la tarjeta crece un
/// poco en vez de romperse.
const double kWarehouseFlagMinHeight = 26;

/// Chip de estado de una bodega: "1 bajo mínimo", "2 por recibir",
/// "Sin contar 47 días". Vive acá —y no dentro de la pantalla— para que la
/// prueba de desbordes monte EXACTAMENTE el widget que se usa en producción.
class WarehouseFlag extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const WarehouseFlag({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: kWarehouseFlagMinHeight),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
