import 'package:flutter/material.dart';

class BusinessTypeOption {
  final String label;
  final String dbValue;
  final String subtitle;
  final IconData icon;

  const BusinessTypeOption({
    required this.label,
    required this.dbValue,
    required this.subtitle,
    required this.icon,
  });
}

const businessTypeOptions = <BusinessTypeOption>[
  BusinessTypeOption(
    label: 'Restaurante',
    dbValue: 'Restaurante',
    subtitle: 'Salon, mesas y operacion completa.',
    icon: Icons.restaurant_menu_rounded,
  ),
  BusinessTypeOption(
    label: 'Comida Rápida',
    dbValue: 'Comida Rapida',
    subtitle: 'Mostrador, alta rotacion y despacho agil.',
    icon: Icons.lunch_dining_rounded,
  ),
  BusinessTypeOption(
    label: 'Cafetería / Panadería',
    dbValue: 'Cafeteria / Panaderia',
    subtitle: 'Cafe, vitrinas y consumo recurrente.',
    icon: Icons.bakery_dining_rounded,
  ),
  BusinessTypeOption(
    label: 'Bar / Lounge',
    dbValue: 'Bar / Lounge',
    subtitle: 'Bebidas, comandas y ambiente nocturno.',
    icon: Icons.local_bar_rounded,
  ),
  BusinessTypeOption(
    label: 'Heladería / Postres',
    dbValue: 'Heladeria / Postres',
    subtitle: 'Tickets rapidos y productos frios.',
    icon: Icons.icecream_rounded,
  ),
  BusinessTypeOption(
    label: 'Solo Delivery',
    dbValue: 'Solo Delivery',
    subtitle: 'Pedidos, rutas y cocina sin salon.',
    icon: Icons.delivery_dining_rounded,
  ),
  BusinessTypeOption(
    label: 'Tienda de Conveniencia',
    dbValue: 'Tienda de Conveniencia',
    subtitle: 'Retail rapido con caja e inventario.',
    icon: Icons.storefront_rounded,
  ),
  BusinessTypeOption(
    label: 'Bar de Jugos / Comida Saludable',
    dbValue: 'Bar de Jugos / Comida Saludable',
    subtitle: 'Jugos, bowls y menu saludable.',
    icon: Icons.local_drink_rounded,
  ),
  BusinessTypeOption(
    label: 'Food Truck',
    dbValue: 'Food Truck',
    subtitle: 'Operacion movil y ticket express.',
    icon: Icons.ramen_dining_rounded,
  ),
  BusinessTypeOption(
    label: 'Otro',
    dbValue: 'Otro',
    subtitle: 'Configura MangoPOS para tu formato.',
    icon: Icons.widgets_rounded,
  ),
];

BusinessTypeOption businessTypeByDbValue(String? value) {
  return businessTypeOptions.firstWhere(
    (option) => option.dbValue == value,
    orElse: () => businessTypeOptions.first,
  );
}
