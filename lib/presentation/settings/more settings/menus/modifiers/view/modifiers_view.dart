import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../../../../app/router/routes.dart';
import '../../../../../../../app/theme/mango_tokens.dart';
import '../state/modifiers_state.dart';
import '../viewmodel/modifiers_viewmodel.dart';

class ModifiersView extends ConsumerStatefulWidget {
  const ModifiersView({super.key});

  @override
  ConsumerState<ModifiersView> createState() => _ModifiersViewState();
}

class _ModifiersViewState extends ConsumerState<ModifiersView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(modifiersViewModelProvider).init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(modifiersViewModelProvider);
    final state = vm.state;
    final selectedGroup = state.selectedGroup;
    final groupModifiers = state.selectedGroupModifiers;
    final assignedProductIds = state.selectedGroupAssignedProductIds.toSet();
    final currency = NumberFormat.currency(
      locale: 'es_DO',
      symbol: 'RD\$',
      decimalDigits: 2,
    );

    return Scaffold(
      backgroundColor: MangoTokens.background,
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _HeaderRow(
                  onBack: () => context.go(AppRoutes.settings),
                  onRefresh: state.saving
                      ? null
                      : () => ref.read(modifiersViewModelProvider).refresh(),
                  onAddGroup: state.saving ? null : _openCreateGroupDialog,
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    _KpiCard(
                      label: 'Grupos',
                      value: '${state.groups.length}',
                      valueColor: MangoTokens.foreground,
                    ),
                    _KpiCard(
                      label: 'Modificadores',
                      value: '${state.modifiers.length}',
                      valueColor: MangoTokens.info,
                    ),
                    _KpiCard(
                      label: 'Productos asignados',
                      value:
                          '${state.assignedProductIdsByGroup.values.fold<int>(0, (sum, ids) => sum + ids.length)}',
                      valueColor: MangoTokens.success,
                    ),
                  ],
                ),
                if (state.error != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFFECACA)),
                    ),
                    child: Text(
                      state.error!,
                      style: const TextStyle(color: Color(0xFF991B1B)),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isWide = constraints.maxWidth > 1100;
                    if (!isWide) {
                      return Column(
                        children: [
                          _GroupsPanel(
                            state: state,
                            onSelect: ref.read(modifiersViewModelProvider).selectGroup,
                            onEdit: selectedGroup == null
                                ? null
                                : () => _openEditGroupDialog(selectedGroup),
                            onDelete: selectedGroup == null
                                ? null
                                : () => _confirmDeleteGroup(selectedGroup),
                          ),
                          const SizedBox(height: 16),
                          _ModifiersPanel(
                            selectedGroup: selectedGroup,
                            modifiers: groupModifiers,
                            currency: currency,
                            onAdd: selectedGroup == null
                                ? null
                                : () => _openCreateModifierDialog(selectedGroup),
                            onEdit: _openEditModifierDialog,
                            onDelete: _confirmDeleteModifier,
                          ),
                          const SizedBox(height: 16),
                          _AssignmentsPanel(
                            selectedGroup: selectedGroup,
                            products: state.products,
                            assignedProductIds: assignedProductIds,
                            onChanged: (ids) => ref
                                .read(modifiersViewModelProvider)
                                .replaceAssignments(
                                  groupId: selectedGroup!.id,
                                  menuItemIds: ids,
                                ),
                          ),
                        ],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _GroupsPanel(
                            state: state,
                            onSelect: ref.read(modifiersViewModelProvider).selectGroup,
                            onEdit: selectedGroup == null
                                ? null
                                : () => _openEditGroupDialog(selectedGroup),
                            onDelete: selectedGroup == null
                                ? null
                                : () => _confirmDeleteGroup(selectedGroup),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _ModifiersPanel(
                            selectedGroup: selectedGroup,
                            modifiers: groupModifiers,
                            currency: currency,
                            onAdd: selectedGroup == null
                                ? null
                                : () => _openCreateModifierDialog(selectedGroup),
                            onEdit: _openEditModifierDialog,
                            onDelete: _confirmDeleteModifier,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _AssignmentsPanel(
                            selectedGroup: selectedGroup,
                            products: state.products,
                            assignedProductIds: assignedProductIds,
                            onChanged: (ids) => ref
                                .read(modifiersViewModelProvider)
                                .replaceAssignments(
                                  groupId: selectedGroup!.id,
                                  menuItemIds: ids,
                                ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          if (state.loading)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                minHeight: 2,
                color: MangoTokens.primary,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openCreateGroupDialog() async {
    final payload = await showDialog<_GroupFormResult>(
      context: context,
      builder: (_) => const _GroupFormDialog(),
    );
    if (payload == null) return;
    await ref.read(modifiersViewModelProvider).createGroup(
      name: payload.name,
      minSelect: payload.minSelect,
      maxSelect: payload.maxSelect,
      isActive: payload.isActive,
    );
  }

  Future<void> _openEditGroupDialog(ModifierGroupSummary group) async {
    final payload = await showDialog<_GroupFormResult>(
      context: context,
      builder: (_) => _GroupFormDialog(initialGroup: group),
    );
    if (payload == null) return;
    await ref.read(modifiersViewModelProvider).updateGroup(
      id: group.id,
      name: payload.name,
      minSelect: payload.minSelect,
      maxSelect: payload.maxSelect,
      isActive: payload.isActive,
    );
  }

  Future<void> _confirmDeleteGroup(ModifierGroupSummary group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Eliminar grupo'),
        content: Text(
          'Se eliminara "${group.name}" junto con sus modificadores y asignaciones.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    await ref.read(modifiersViewModelProvider).deleteGroup(group.id);
  }

  Future<void> _openCreateModifierDialog(ModifierGroupSummary group) async {
    final payload = await showDialog<_ModifierFormResult>(
      context: context,
      builder: (_) => _ModifierFormDialog(group: group),
    );
    if (payload == null) return;
    await ref.read(modifiersViewModelProvider).createModifier(
      groupId: group.id,
      name: payload.name,
      priceDelta: payload.priceDelta,
      isActive: payload.isActive,
    );
  }

  Future<void> _openEditModifierDialog(ModifierOption modifier) async {
    final state = ref.read(modifiersViewModelProvider).state;
    final group = state.groups
        .where((candidate) => candidate.id == modifier.groupId)
        .cast<ModifierGroupSummary?>()
        .firstWhere((candidate) => candidate != null, orElse: () => null);
    if (group == null) return;

    final payload = await showDialog<_ModifierFormResult>(
      context: context,
      builder: (_) => _ModifierFormDialog(
        group: group,
        initialModifier: modifier,
      ),
    );
    if (payload == null) return;

    await ref.read(modifiersViewModelProvider).updateModifier(
      id: modifier.id,
      groupId: group.id,
      name: payload.name,
      priceDelta: payload.priceDelta,
      isActive: payload.isActive,
    );
  }

  Future<void> _confirmDeleteModifier(ModifierOption modifier) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Eliminar modificador'),
        content: Text('Se eliminara "${modifier.name}" del grupo actual.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    await ref.read(modifiersViewModelProvider).deleteModifier(modifier.id);
  }
}

class _HeaderRow extends StatelessWidget {
  final VoidCallback onBack;
  final VoidCallback? onRefresh;
  final VoidCallback? onAddGroup;

  const _HeaderRow({
    required this.onBack,
    required this.onRefresh,
    required this.onAddGroup,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(onPressed: onBack, icon: const Icon(Icons.arrow_back)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Modificadores', style: MangoTokens.h1()),
              const SizedBox(height: 2),
              Text(
                'Crea grupos, opciones y vinculos con productos.',
                style: MangoTokens.subtitle(),
              ),
            ],
          ),
        ),
        IconButton(onPressed: onRefresh, icon: const Icon(Icons.refresh)),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: onAddGroup,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Nuevo grupo'),
        ),
      ],
    );
  }
}

class _KpiCard extends StatelessWidget {
  final String label;
  final String value;
  final Color valueColor;

  const _KpiCard({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: MangoTokens.card,
        borderRadius: BorderRadius.circular(MangoTokens.radius),
        border: Border.all(color: MangoTokens.border),
        boxShadow: MangoTokens.shadowCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: MangoTokens.label()),
          const SizedBox(height: 8),
          Text(value, style: MangoTokens.kpiValue(color: valueColor)),
        ],
      ),
    );
  }
}

class _GroupsPanel extends StatelessWidget {
  final ModifiersState state;
  final ValueChanged<String> onSelect;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _GroupsPanel({
    required this.state,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Grupos',
      action: Row(
        children: [
          IconButton(onPressed: onEdit, icon: const Icon(Icons.edit_outlined)),
          IconButton(onPressed: onDelete, icon: const Icon(Icons.delete_outline)),
        ],
      ),
      child: state.groups.isEmpty
          ? const Text('No hay grupos creados.')
          : Column(
              children: state.groups
                  .map(
                    (group) => ListTile(
                      onTap: () => onSelect(group.id),
                      selected: state.selectedGroup?.id == group.id,
                      title: Text(group.name),
                      subtitle: Text(
                        'Min ${group.minSelect} · Max ${group.maxSelect}',
                      ),
                      trailing: Text(
                        group.isActive ? 'Activo' : 'Inactivo',
                        style: TextStyle(
                          color: group.isActive
                              ? MangoTokens.success
                              : MangoTokens.warning,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
    );
  }
}

class _ModifiersPanel extends StatelessWidget {
  final ModifierGroupSummary? selectedGroup;
  final List<ModifierOption> modifiers;
  final NumberFormat currency;
  final VoidCallback? onAdd;
  final ValueChanged<ModifierOption> onEdit;
  final ValueChanged<ModifierOption> onDelete;

  const _ModifiersPanel({
    required this.selectedGroup,
    required this.modifiers,
    required this.currency,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: selectedGroup == null
          ? 'Opciones'
          : 'Opciones · ${selectedGroup!.name}',
      action: TextButton.icon(
        onPressed: onAdd,
        icon: const Icon(Icons.add),
        label: const Text('Agregar'),
      ),
      child: selectedGroup == null
          ? const Text('Selecciona un grupo para ver sus opciones.')
          : modifiers.isEmpty
          ? const Text('Este grupo no tiene modificadores todavía.')
          : Column(
              children: modifiers
                  .map(
                    (modifier) => ListTile(
                      title: Text(modifier.name),
                      subtitle: Text(
                        modifier.isActive ? 'Activo' : 'Inactivo',
                      ),
                      trailing: Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(currency.format(modifier.priceDelta)),
                          IconButton(
                            onPressed: () => onEdit(modifier),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            onPressed: () => onDelete(modifier),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
    );
  }
}

class _AssignmentsPanel extends StatefulWidget {
  final ModifierGroupSummary? selectedGroup;
  final List<ModifierProduct> products;
  final Set<String> assignedProductIds;
  final ValueChanged<List<String>> onChanged;

  const _AssignmentsPanel({
    required this.selectedGroup,
    required this.products,
    required this.assignedProductIds,
    required this.onChanged,
  });

  @override
  State<_AssignmentsPanel> createState() => _AssignmentsPanelState();
}

class _AssignmentsPanelState extends State<_AssignmentsPanel> {
  late Set<String> _localAssigned;

  @override
  void initState() {
    super.initState();
    _localAssigned = {...widget.assignedProductIds};
  }

  @override
  void didUpdateWidget(covariant _AssignmentsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedGroup?.id != widget.selectedGroup?.id ||
        oldWidget.assignedProductIds.length != widget.assignedProductIds.length) {
      _localAssigned = {...widget.assignedProductIds};
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Asignacion a productos',
      action: TextButton(
        onPressed: widget.selectedGroup == null
            ? null
            : () => widget.onChanged(_localAssigned.toList(growable: false)),
        child: const Text('Guardar'),
      ),
      child: widget.selectedGroup == null
          ? const Text('Selecciona un grupo para asignarlo a productos.')
          : widget.products.isEmpty
          ? const Text('No hay productos disponibles.')
          : Column(
              children: widget.products
                  .map(
                    (product) => CheckboxListTile(
                      value: _localAssigned.contains(product.id),
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(product.name),
                      subtitle: Text(product.isActive ? 'Activo' : 'Inactivo'),
                      onChanged: (value) {
                        setState(() {
                          if (value == true) {
                            _localAssigned.add(product.id);
                          } else {
                            _localAssigned.remove(product.id);
                          }
                        });
                      },
                    ),
                  )
                  .toList(growable: false),
            ),
    );
  }
}

class _Panel extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? action;

  const _Panel({
    required this.title,
    required this.child,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: MangoTokens.card,
        borderRadius: BorderRadius.circular(MangoTokens.radius),
        border: Border.all(color: MangoTokens.border),
        boxShadow: MangoTokens.shadowCard,
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: MangoTokens.body().copyWith(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                if (action != null) action!,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _GroupFormResult {
  final String name;
  final int minSelect;
  final int maxSelect;
  final bool isActive;

  const _GroupFormResult({
    required this.name,
    required this.minSelect,
    required this.maxSelect,
    required this.isActive,
  });
}

class _GroupFormDialog extends StatefulWidget {
  final ModifierGroupSummary? initialGroup;

  const _GroupFormDialog({this.initialGroup});

  @override
  State<_GroupFormDialog> createState() => _GroupFormDialogState();
}

class _GroupFormDialogState extends State<_GroupFormDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _minController;
  late final TextEditingController _maxController;
  bool _isActive = true;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialGroup;
    _nameController = TextEditingController(text: initial?.name ?? '');
    _minController = TextEditingController(
      text: (initial?.minSelect ?? 0).toString(),
    );
    _maxController = TextEditingController(
      text: (initial?.maxSelect ?? 1).toString(),
    );
    _isActive = initial?.isActive ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _minController.dispose();
    _maxController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initialGroup == null ? 'Nuevo grupo' : 'Editar grupo'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Nombre'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _minController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Minimo'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _maxController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Maximo'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              value: _isActive,
              onChanged: (value) => setState(() => _isActive = value),
              title: const Text('Activo'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Guardar'),
        ),
      ],
    );
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final minSelect = int.tryParse(_minController.text.trim()) ?? 0;
    final maxSelect = int.tryParse(_maxController.text.trim()) ?? 0;
    Navigator.of(context).pop(
      _GroupFormResult(
        name: name,
        minSelect: minSelect,
        maxSelect: maxSelect < minSelect ? minSelect : maxSelect,
        isActive: _isActive,
      ),
    );
  }
}

class _ModifierFormResult {
  final String name;
  final double priceDelta;
  final bool isActive;

  const _ModifierFormResult({
    required this.name,
    required this.priceDelta,
    required this.isActive,
  });
}

class _ModifierFormDialog extends StatefulWidget {
  final ModifierGroupSummary group;
  final ModifierOption? initialModifier;

  const _ModifierFormDialog({
    required this.group,
    this.initialModifier,
  });

  @override
  State<_ModifierFormDialog> createState() => _ModifierFormDialogState();
}

class _ModifierFormDialogState extends State<_ModifierFormDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _priceController;
  bool _isActive = true;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialModifier;
    _nameController = TextEditingController(text: initial?.name ?? '');
    _priceController = TextEditingController(
      text: (initial?.priceDelta ?? 0).toStringAsFixed(2),
    );
    _isActive = initial?.isActive ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.initialModifier == null
            ? 'Nuevo modificador'
            : 'Editar modificador',
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Grupo: ${widget.group.name}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Nombre'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _priceController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Delta de precio'),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              value: _isActive,
              onChanged: (value) => setState(() => _isActive = value),
              title: const Text('Activo'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Guardar'),
        ),
      ],
    );
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final priceDelta = double.tryParse(_priceController.text.trim()) ?? 0;
    Navigator.of(context).pop(
      _ModifierFormResult(
        name: name,
        priceDelta: priceDelta,
        isActive: _isActive,
      ),
    );
  }
}
