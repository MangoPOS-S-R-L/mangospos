import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../viewmodel/sales_viewmodel.dart';

class QuickSaleView extends ConsumerWidget {
  const QuickSaleView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(currentOrderProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Venta Rápida'),
        backgroundColor: MangoColors.primaryOrange,
      ),
      body: Column(
        children: [
          if (s.order == null)
            Padding(
              padding: const EdgeInsets.all(20),
              child: ElevatedButton.icon(
                onPressed: () =>
                    ref.read(currentOrderProvider.notifier).openQuick(),
                icon: const Icon(Icons.flash_on),
                label: const Text('Iniciar venta rápida'),
              ),
            ),
          if (s.order != null)
            Expanded(
              child: ListView.builder(
                itemCount: s.items.length,
                itemBuilder: (_, i) {
                  final it = s.items[i];
                  return ListTile(
                    title: Text(it.productName),
                    subtitle: Text('Cant: ${it.qty}'),
                    trailing: Text('RD\$ ${it.total.toStringAsFixed(2)}'),
                  );
                },
              ),
            ),
        ],
      ),
      floatingActionButton: s.order == null
          ? null
          : FloatingActionButton(
              onPressed: () async {
                final c = Supabase.instance.client;
                final first = await c
                    .from('menu_items')
                    .select('id')
                    .eq('is_active', true)
                    .limit(1)
                    .maybeSingle();
                if (first != null) {
                  await ref.read(currentOrderProvider.notifier).addItem(
                        menuItemId: first['id'] as String,
                        qty: 1,
                      );
                }
              },
              tooltip: 'Agregar producto',
              child: const Icon(Icons.add),
            ),
    );
  }
}
