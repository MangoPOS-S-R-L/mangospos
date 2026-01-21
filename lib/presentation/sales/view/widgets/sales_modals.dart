import 'package:flutter/material.dart';
import 'package:mangopos/presentation/sales/view/theme/sales_theme.dart';

class SalesModals {
  static Future<void> showProductCustomization(BuildContext context) {
    return showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: SalesTheme.cardBackground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        // Max width 480
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: const _ProductCustomizationContent(),
        ),
      ),
    );
  }

  static Future<void> showPayment(BuildContext context) {
    return showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: SalesTheme.cardBackground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        // Max width 672
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 672),
          child: const _PaymentContent(),
        ),
      ),
    );
  }

  static Future<void> showSplitBill(BuildContext context) {
    return showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: SalesTheme.cardBackground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        // Max width 896
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 896),
          child: const _SplitBillContent(),
        ),
      ),
    );
  }
}

class _ProductCustomizationContent extends StatelessWidget {
  const _ProductCustomizationContent();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Personalizar Producto',
            style: SalesTheme.textTheme.headlineMedium,
          ),
        ),
        const Divider(height: 1),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Selector cantidad
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton.filledTonal(
                      onPressed: () {},
                      icon: const Icon(Icons.remove),
                    ),
                    const SizedBox(width: 24),
                    Text('1', style: SalesTheme.textTheme.displaySmall),
                    const SizedBox(width: 24),
                    IconButton.filled(
                      onPressed: () {},
                      style: IconButton.styleFrom(
                        backgroundColor: SalesTheme.primary,
                      ),
                      icon: const Icon(Icons.add, color: Colors.white),
                    ),
                  ],
                ),
                const SizedBox(height: 32),

                // Grupos de modificadores (Ejemplo)
                Text(
                  'Término de la carne',
                  style: SalesTheme.textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  children: ['Bien cocido', 'Medio', 'Tres cuartos']
                      .map(
                        (e) => ChoiceChip(
                          label: Text(e),
                          selected: e == 'Medio',
                          onSelected: (_) {},
                          selectedColor: SalesTheme.primary.withOpacity(0.1),
                          labelStyle: TextStyle(
                            color: e == 'Medio'
                                ? SalesTheme.primary
                                : SalesTheme.foreground,
                            fontWeight: e == 'Medio'
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                          side: BorderSide(
                            color: e == 'Medio'
                                ? SalesTheme.primary
                                : SalesTheme.border,
                          ),
                        ),
                      )
                      .toList(),
                ),

                const SizedBox(height: 24),
                Text(
                  'Acompañantes (Max 2)',
                  style: SalesTheme.textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Column(
                  children: ['Papas fritas', 'Ensalada', 'Tostones']
                      .map(
                        (e) => CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            e,
                            style: SalesTheme.textTheme.bodyMedium,
                          ),
                          value: false,
                          onChanged: (_) {},
                          activeColor: SalesTheme.primary,
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                      )
                      .toList(),
                ),

                const SizedBox(height: 24),
                Text(
                  'Notas especiales',
                  style: SalesTheme.textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                TextField(
                  maxLines: 3,
                  decoration: InputDecoration(
                    hintText: 'Sin cebolla, extra salsa...',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        // Footer
        Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            children: [
              Text(
                'RD\$ 450.00',
                style: SalesTheme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar'),
              ),
              const SizedBox(width: 16),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                style: FilledButton.styleFrom(
                  backgroundColor: SalesTheme.primary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 16,
                  ),
                ),
                child: const Text('Agregar'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PaymentContent extends StatelessWidget {
  const _PaymentContent();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 600,
      child: Row(
        children: [
          // Columna Métodos
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.all(24),
              color: SalesTheme.background,
              child: Column(
                children: [
                  Text(
                    'Método de Pago',
                    style: SalesTheme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 24),
                  _PaymentMethodCard(
                    icon: Icons.money,
                    label: 'Efectivo',
                    selected: true,
                  ),
                  const SizedBox(height: 12),
                  _PaymentMethodCard(
                    icon: Icons.credit_card,
                    label: 'Tarjeta',
                    selected: false,
                  ),
                  const SizedBox(height: 12),
                  _PaymentMethodCard(
                    icon: Icons.qr_code,
                    label: 'Transferencia',
                    selected: false,
                  ),
                ],
              ),
            ),
          ),
          // Columna Montos/Numpad
          Expanded(
            flex: 3,
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        // Display monto
                        Container(
                          padding: const EdgeInsets.all(16),
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: SalesTheme.secondary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                'Total a Pagar',
                                style: SalesTheme.textTheme.bodySmall,
                              ),
                              Text(
                                'RD\$ 1,475.00',
                                style: SalesTheme.textTheme.displaySmall,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        // Montos rápidos
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [2000, 1500, 500]
                              .map(
                                (e) => OutlinedButton(
                                  onPressed: () {},
                                  child: Text('RD\$ $e'),
                                ),
                              )
                              .toList(),
                        ),
                        const Spacer(),
                        // Numpad Placeholder
                        const Center(
                          child: Icon(
                            Icons.dialpad,
                            size: 64,
                            color: SalesTheme.border,
                          ),
                        ),
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: SalesTheme.border)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: const Text('Cancelar'),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.pop(context),
                          style: FilledButton.styleFrom(
                            backgroundColor: SalesTheme.success,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: const Text('COBRAR RD\$ 1,475'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PaymentMethodCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  const _PaymentMethodCard({
    required this.icon,
    required this.label,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: selected ? SalesTheme.primary.withOpacity(0.1) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? SalesTheme.primary : SalesTheme.border,
        ),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            color: selected ? SalesTheme.primary : SalesTheme.mutedForeground,
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: selected ? SalesTheme.primary : SalesTheme.foreground,
            ),
          ),
        ],
      ),
    );
  }
}

class _SplitBillContent extends StatelessWidget {
  const _SplitBillContent();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 600,
      child: Row(
        children: [
          Expanded(
            child: Center(
              child: Text(
                "Selección de Productos\n(Placeholder)",
                textAlign: TextAlign.center,
              ),
            ),
          ),
          VerticalDivider(width: 1, color: SalesTheme.border),
          Expanded(
            child: Center(
              child: Text(
                "Subcuentas\n(Placeholder)",
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
