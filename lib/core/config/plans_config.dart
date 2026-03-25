class PlanFeature {
  final String title;
  final bool included;
  const PlanFeature(this.title, {this.included = true});
}

class MangoPlan {
  final String id;
  final String name;
  final String description;
  final String price;
  final List<PlanFeature> features;
  final bool isPopular;

  const MangoPlan({
    required this.id,
    required this.name,
    required this.description,
    required this.price,
    required this.features,
    this.isPopular = false,
  });
}

class PlansConfig {
  static const List<MangoPlan> plans = [
    MangoPlan(
      id: 'base',
      name: 'Plan Base',
      description: 'Ideal para negocios que quieren comenzar a operar con orden y velocidad.',
      price: 'US\$49.99/mes',
      features: [
        PlanFeature('Punto de venta'),
        PlanFeature('Venta por mesas y zonas'),
        PlanFeature('Carrito automático'),
        PlanFeature('Cocina y Comandas (KDS)'),
        PlanFeature('Apertura y cierre de caja'),
        PlanFeature('1 negocio / 1 sucursal'),
      ],
    ),
    MangoPlan(
      id: 'pro',
      name: 'Plan Pro',
      description: 'Más control, orden y capacidad para crecer sin complicar la operación.',
      price: 'US\$79.99/mes',
      isPopular: true,
      features: [
        PlanFeature('Todo lo del Plan Base'),
        PlanFeature('Gestión ampliada de usuarios'),
        PlanFeature('Modificadores y Recetas'),
        PlanFeature('Clientes e historial de compras'),
        PlanFeature('Impresión por áreas (Múltiples impresoras)'),
        PlanFeature('Soporte prioritario'),
      ],
    ),
    MangoPlan(
      id: 'enterprise',
      name: 'Enterprise',
      description: 'Para operaciones que necesitan escalabilidad y acompañamiento cercano.',
      price: 'Personalizado',
      features: [
        PlanFeature('Todo lo del Plan Pro'),
        PlanFeature('Multi-sucursal'),
        PlanFeature('Fidelización, créditos y gift cards'),
        PlanFeature('Integraciones a medida'),
        PlanFeature('Reportería avanzada'),
        PlanFeature('Implementación acompañada (Soporte Premium)'),
      ],
    ),
  ];
}
