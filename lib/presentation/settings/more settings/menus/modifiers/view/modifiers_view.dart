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
                  totalGroups: state.groups.length,
                  totalModifiers: state.modifiers.length,
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
        backgroundColor: MangoTokens.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const _DialogHeader(
          icon: Icons.delete_outline,
          title: 'Eliminar grupo',
          subtitle: 'Esta acción también eliminará sus modificadores y asignaciones.',
        ),
        content: Text(
          'Se eliminará "${group.name}" de forma permanente. Verifica que ya no lo necesitas antes de continuar.',
          style: MangoTokens.body(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: MangoTokens.destructive),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Eliminar grupo'),
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
        backgroundColor: MangoTokens.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const _DialogHeader(
          icon: Icons.delete_sweep_outlined,
          title: 'Eliminar modificador',
          subtitle: 'Quitarás esta opción del grupo actual.',
        ),
        content: Text(
          'Se eliminará "${modifier.name}" y dejará de estar disponible para los productos vinculados a este grupo.',
          style: MangoTokens.body(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: MangoTokens.destructive),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Eliminar modificador'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    await ref.read(modifiersViewModelProvider).deleteModifier(modifier.id);
  }
}

class _HeaderRow extends StatelessWidget {
  final int totalGroups;
  final int totalModifiers;
  final VoidCallback onBack;
  final VoidCallback? onRefresh;
  final VoidCallback? onAddGroup;

  const _HeaderRow({
    required this.totalGroups,
    required this.totalModifiers,
    required this.onBack,
    required this.onRefresh,
    required this.onAddGroup,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: MangoTokens.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: MangoTokens.border),
        boxShadow: MangoTokens.shadowCard,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 820;
          return compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    IconButton(
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back),
                    ),
                    const SizedBox(height: 8),
                    _HeaderSummary(
                      totalGroups: totalGroups,
                      totalModifiers: totalModifiers,
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        OutlinedButton.icon(
                          onPressed: onRefresh,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('Actualizar'),
                        ),
                        FilledButton.icon(
                          onPressed: onAddGroup,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Nuevo grupo'),
                        ),
                      ],
                    ),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    IconButton(
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _HeaderSummary(
                        totalGroups: totalGroups,
                        totalModifiers: totalModifiers,
                      ),
                    ),
                    const SizedBox(width: 16),
                    OutlinedButton.icon(
                      onPressed: onRefresh,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Actualizar'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: onAddGroup,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Nuevo grupo'),
                    ),
                  ],
                );
        },
      ),
    );
  }
}

class _HeaderSummary extends StatelessWidget {
  final int totalGroups;
  final int totalModifiers;

  const _HeaderSummary({
    required this.totalGroups,
    required this.totalModifiers,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: MangoTokens.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.tune_rounded,
                color: MangoTokens.primary,
              ),
            ),
            const SizedBox(width: 12),
            Flexible(child: Text('Modificadores', style: MangoTokens.h1())),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Organiza grupos de opciones, controla reglas de selección y asigna modificadores a los productos correctos.',
          style: MangoTokens.subtitle(),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _HeaderPill(
              icon: Icons.layers_outlined,
              label: '$totalGroups grupos',
            ),
            _HeaderPill(
              icon: Icons.extension_outlined,
              label: '$totalModifiers opciones',
            ),
          ],
        ),
      ],
    );
  }
}

class _HeaderPill extends StatelessWidget {
  final IconData icon;
  final String label;

  const _HeaderPill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: MangoTokens.secondary,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: MangoTokens.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: MangoTokens.mutedForeground),
          const SizedBox(width: 8),
          Text(label, style: MangoTokens.label(color: MangoTokens.foreground)),
        ],
      ),
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
          ? const _EmptyPanelState(message: 'No hay grupos creados todavía.')
          : Column(
              children: state.groups
                  .map(
                    (group) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _SelectableCard(
                        selected: state.selectedGroup?.id == group.id,
                        onTap: () => onSelect(group.id),
                        title: group.name,
                        subtitle:
                            'Selección mínima ${group.minSelect} · máxima ${group.maxSelect}',
                        trailing: _StatusBadge(
                          label: group.isActive ? 'Activo' : 'Inactivo',
                          color: group.isActive
                              ? MangoTokens.success
                              : MangoTokens.warning,
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
          ? const _EmptyPanelState(
              message: 'Selecciona un grupo para administrar sus opciones.',
            )
          : modifiers.isEmpty
          ? const _EmptyPanelState(
              message: 'Este grupo todavía no tiene modificadores.',
            )
          : Column(
              children: modifiers
                  .map(
                    (modifier) => Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: MangoTokens.secondary,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: MangoTokens.border),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  modifier.name,
                                  style: MangoTokens.body().copyWith(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    _StatusBadge(
                                      label: modifier.isActive
                                          ? 'Activo'
                                          : 'Inactivo',
                                      color: modifier.isActive
                                          ? MangoTokens.success
                                          : MangoTokens.warning,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      currency.format(modifier.priceDelta),
                                      style: MangoTokens.body().copyWith(
                                        color: MangoTokens.primary,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Editar modificador',
                                onPressed: () => onEdit(modifier),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                              IconButton(
                                tooltip: 'Eliminar modificador',
                                onPressed: () => onDelete(modifier),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
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
          ? const _EmptyPanelState(
              message: 'Selecciona un grupo para asignarlo a productos.',
            )
          : widget.products.isEmpty
          ? const _EmptyPanelState(message: 'No hay productos disponibles.')
          : Column(
              children: widget.products
                  .map(
                    (product) => Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: MangoTokens.secondary,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: MangoTokens.border),
                      ),
                      child: CheckboxListTile(
                        value: _localAssigned.contains(product.id),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        title: Text(
                          product.name,
                          style: MangoTokens.body().copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          product.isActive ? 'Disponible para venta' : 'Inactivo',
                          style: MangoTokens.label(),
                        ),
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
        borderRadius: BorderRadius.circular(18),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: MangoTokens.body().copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Gestiona esta sección con cambios claros y controlados.',
                        style: MangoTokens.label(),
                      ),
                    ],
                  ),
                ),
                if (action != null) action!,
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _EmptyPanelState extends StatelessWidget {
  final String message;

  const _EmptyPanelState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: MangoTokens.secondary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MangoTokens.border),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.inbox_outlined,
            size: 26,
            color: MangoTokens.mutedForeground,
          ),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: MangoTokens.body(color: MangoTokens.mutedForeground),
          ),
        ],
      ),
    );
  }
}

class _SelectableCard extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  final String title;
  final String subtitle;
  final Widget? trailing;

  const _SelectableCard({
    required this.selected,
    required this.onTap,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected
              ? MangoTokens.primary.withValues(alpha: 0.08)
              : MangoTokens.secondary,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? MangoTokens.primary : MangoTokens.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: MangoTokens.body().copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(subtitle, style: MangoTokens.label()),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: MangoTokens.label(color: color).copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w700,
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
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      backgroundColor: MangoTokens.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      title: _DialogHeader(
        icon: Icons.layers_outlined,
        title: widget.initialGroup == null ? 'Nuevo grupo' : 'Editar grupo',
        subtitle: 'Define la regla de selección y el estado del grupo.',
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Nombre del grupo',
                hintText: 'Ej. Extras, toppings, sabores',
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _minController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Mínimo'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _maxController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Máximo'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              decoration: BoxDecoration(
                color: MangoTokens.secondary,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: MangoTokens.border),
              ),
              child: SwitchListTile(
                value: _isActive,
                onChanged: (value) => setState(() => _isActive = value),
                title: Text(
                  'Grupo activo',
                  style: MangoTokens.body().copyWith(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'Solo los grupos activos estarán disponibles al vender.',
                  style: MangoTokens.label(),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.save_outlined, size: 18),
          label: const Text('Guardar grupo'),
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

class _DialogHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _DialogHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: MangoTokens.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: MangoTokens.primary),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: MangoTokens.h1().copyWith(fontSize: 20)),
              const SizedBox(height: 6),
              Text(subtitle, style: MangoTokens.label()),
            ],
          ),
        ),
      ],
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
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      backgroundColor: MangoTokens.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      title: _DialogHeader(
        icon: Icons.extension_outlined,
        title: widget.initialModifier == null
            ? 'Nuevo modificador'
            : 'Editar modificador',
        subtitle: 'Ajusta el nombre, el impacto en precio y su disponibilidad.',
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: MangoTokens.secondary,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: MangoTokens.border),
              ),
              child: Row(
                children: [
                  const Icon(Icons.account_tree_outlined, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Grupo: ${widget.group.name}',
                      style: MangoTokens.body().copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Nombre del modificador',
                hintText: 'Ej. Queso extra, sin cebolla, término 3/4',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _priceController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Delta de precio',
                prefixText: 'RD\$ ',
              ),
            ),
            const SizedBox(height: 14),
            Container(
              decoration: BoxDecoration(
                color: MangoTokens.secondary,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: MangoTokens.border),
              ),
              child: SwitchListTile(
                value: _isActive,
                onChanged: (value) => setState(() => _isActive = value),
                title: Text(
                  'Modificador activo',
                  style: MangoTokens.body().copyWith(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'Si lo desactivas, no aparecerá al momento de vender.',
                  style: MangoTokens.label(),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.save_outlined, size: 18),
          label: const Text('Guardar modificador'),
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
