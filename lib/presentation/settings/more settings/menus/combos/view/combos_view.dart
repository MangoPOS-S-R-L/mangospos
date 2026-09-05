import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../../../../app/router/routes.dart';
import '../../../../../../../app/theme/mango_colors.dart';
import '../../../../../../../data/repositories/combos_repository.dart';
import '../../../../../../core/theme/app_colors.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

final combosRepositoryProvider = Provider<CombosRepository>((ref) {
  return CombosRepository(Supabase.instance.client);
});

class CombosView extends ConsumerStatefulWidget {
  const CombosView({super.key});

  @override
  ConsumerState<CombosView> createState() => _CombosViewState();
}

class _CombosViewState extends ConsumerState<CombosView> {
  bool _loading = true;
  String? _businessId;
  String? _selectedComboId;
  List<Map<String, dynamic>> _combos = const [];
  List<Map<String, dynamic>> _products = const [];
  List<Map<String, dynamic>> _groups = const [];
  String? _error;

  CombosRepository get _repo => ref.read(combosRepositoryProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _businessId = await _repo.resolveBusinessId();
      final businessId = _businessId;
      if (businessId == null) {
        throw Exception('No se pudo resolver el negocio activo');
      }
      _combos = await _repo.getComboProducts(businessId);
      _products = await _repo.getProducts(businessId);
      _selectedComboId ??= _combos.isNotEmpty
          ? _combos.first['id']?.toString()
          : null;
      _groups = _selectedComboId == null
          ? const []
          : await _repo.getComboConfig(_selectedComboId!);
    } catch (e) {
      _error = FriendlyError.humanize('$e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _addGroup() async {
    final businessId = _businessId;
    final comboId = _selectedComboId;
    if (businessId == null || comboId == null) return;
    final nameCtrl = TextEditingController();
    final minCtrl = TextEditingController(text: '1');
    final maxCtrl = TextEditingController(text: '1');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Nuevo grupo del combo'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Nombre'),
            ),
            TextField(
              controller: minCtrl,
              decoration: const InputDecoration(labelText: 'Mínimo'),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: maxCtrl,
              decoration: const InputDecoration(labelText: 'Máximo'),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _repo.createComboGroup(
      businessId: businessId,
      comboId: comboId,
      name: nameCtrl.text.trim().isEmpty ? 'Grupo' : nameCtrl.text.trim(),
      minSelect: int.tryParse(minCtrl.text.trim()) ?? 1,
      maxSelect: int.tryParse(maxCtrl.text.trim()) ?? 1,
      sortOrder: _groups.length,
    );
    await _load();
  }

  Future<void> _editGroupItems(Map<String, dynamic> group) async {
    final currentItems = ((group['combo_group_items'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: false);
    final selected = currentItems
        .map((e) => e['menu_item_id']?.toString())
        .whereType<String>()
        .toSet();
    final deltas = {
      for (final item in currentItems)
        item['menu_item_id']?.toString() ?? '':
            (item['price_delta'] as num?)?.toDouble() ?? 0.0,
    };

    final result = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text('Opciones · ${group['name'] ?? 'Grupo'}'),
              content: SizedBox(
                width: 560,
                child: ListView(
                  shrinkWrap: true,
                  children: _products
                      .map((product) {
                        final id = product['id']?.toString() ?? '';
                        final selectedNow = selected.contains(id);
                        return CheckboxListTile(
                          value: selectedNow,
                          title: Text(
                            product['name']?.toString() ?? 'Producto',
                          ),
                          subtitle: selectedNow
                              ? TextFormField(
                                  initialValue: (deltas[id] ?? 0)
                                      .toStringAsFixed(2),
                                  decoration: const InputDecoration(
                                    labelText: 'Extra del combo',
                                  ),
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  onChanged: (value) {
                                    deltas[id] =
                                        double.tryParse(value.trim()) ?? 0.0;
                                  },
                                )
                              : null,
                          onChanged: (value) {
                            setDialogState(() {
                              if (value == true) {
                                selected.add(id);
                                deltas.putIfAbsent(id, () => 0.0);
                              } else {
                                selected.remove(id);
                                deltas.remove(id);
                              }
                            });
                          },
                        );
                      })
                      .toList(growable: false),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(
                      context,
                      selected
                          .toList()
                          .asMap()
                          .entries
                          .map(
                            (entry) => {
                              'menu_item_id': entry.value,
                              'price_delta': deltas[entry.value] ?? 0.0,
                              'is_default': entry.key == 0,
                              'sort_order': entry.key,
                            },
                          )
                          .toList(growable: false),
                    );
                  },
                  child: const Text('Guardar'),
                ),
              ],
            );
          },
        );
      },
    );
    if (result == null) return;
    await _repo.replaceComboGroupItems(
      groupId: group['id'].toString(),
      items: result,
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.4,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Regresar',
          onPressed: () => Navigator.of(context).canPop()
              ? Navigator.of(context).pop()
              : context.go(AppRoutes.menu),
        ),
        title: const Text('Combos'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Combos',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            SizedBox(height: 6),
                            Text(
                              'Arma grupos y productos permitidos para cada combo',
                              style: TextStyle(color: Color(0xFF64748B)),
                            ),
                          ],
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: _selectedComboId == null ? null : _addGroup,
                        icon: const Icon(Icons.add),
                        label: const Text('Nuevo grupo'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_error != null)
                    Text(_error!, style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedComboId,
                    decoration: const InputDecoration(labelText: 'Combo'),
                    items: _combos
                        .map(
                          (combo) => DropdownMenuItem(
                            value: combo['id']?.toString(),
                            child: Text(combo['name']?.toString() ?? 'Combo'),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) async {
                      setState(() => _selectedComboId = value);
                      await _load();
                    },
                  ),
                  const SizedBox(height: 20),
                  Expanded(
                    child: _groups.isEmpty
                        ? const Center(
                            child: Text('Este combo aún no tiene grupos.'),
                          )
                        : ListView.separated(
                            itemCount: _groups.length,
                            separatorBuilder: (context, index) =>
                                const SizedBox(height: 12),
                            itemBuilder: (context, index) {
                              final group = _groups[index];
                              final items =
                                  ((group['combo_group_items'] as List?) ??
                                          const [])
                                      .map(
                                        (e) =>
                                            Map<String, dynamic>.from(e as Map),
                                      )
                                      .toList(growable: false);
                              return Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: const Color(0xFFE2E8F0),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '${group['name']} · ${group['min_select']}-${group['max_select']}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 16,
                                            ),
                                          ),
                                        ),
                                        TextButton.icon(
                                          onPressed: () =>
                                              _editGroupItems(group),
                                          icon: const Icon(Icons.edit_outlined),
                                          label: const Text('Editar opciones'),
                                        ),
                                        IconButton(
                                          onPressed: () async {
                                            await _repo.deleteComboGroup(
                                              group['id'].toString(),
                                            );
                                            await _load();
                                          },
                                          icon: const Icon(
                                            Icons.delete_outline,
                                            color: Colors.red,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: items
                                          .map((item) {
                                            final product =
                                                Map<String, dynamic>.from(
                                                  (item['menu_items']
                                                          as Map?) ??
                                                      const {},
                                                );
                                            final delta =
                                                (item['price_delta'] as num?)
                                                    ?.toDouble() ??
                                                0.0;
                                            return Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 6,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFFF1F5F9),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: Text(
                                                delta > 0
                                                    ? '${product['name']} (+RD\$ ${delta.toStringAsFixed(2)})'
                                                    : '${product['name']}',
                                              ),
                                            );
                                          })
                                          .toList(growable: false),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
    );
  }
}
