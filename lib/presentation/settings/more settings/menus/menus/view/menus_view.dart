import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_tokens.dart';
import 'package:mangopos/data/models/menu.dart';

import '../viewmodel/menus_viewmodel.dart';

class MenusView extends ConsumerStatefulWidget {
  final String businessId; // puede ser "auto"
  const MenusView({super.key, required this.businessId});

  @override
  ConsumerState<MenusView> createState() => _MenusViewState();
}

class _MenusViewState extends ConsumerState<MenusView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(menusVmProvider.notifier).load(businessId: widget.businessId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(menusVmProvider);
    final menus = vm.filtered;
    final totalMenus = menus.length;
    final activeMenus = menus.where((m) => m.isActive).length;
    final totalProducts = menus.fold<int>(
      0,
      (acc, m) => acc + (m.itemsCount ?? 0),
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
                  onAdd: _openCreateDialog,
                ),
                const SizedBox(height: 24),
                _KpiGrid(
                  totalMenus: totalMenus,
                  activeMenus: activeMenus,
                  totalProducts: totalProducts,
                ),
                const SizedBox(height: 24),
                _MenuListCard(
                  menus: menus,
                  onToggleStatus: (menu, value) async {
                    await ref
                        .read(menusVmProvider.notifier)
                        .toggleActive(menu.id, value);
                  },
                  onEdit: _openEditDialog,
                  onDelete: (menu) async {
                    await ref.read(menusVmProvider.notifier).remove(menu.id);
                  },
                ),
                if (vm.error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Error: ${vm.error}',
                    style: MangoTokens.body(color: MangoTokens.destructive),
                  ),
                ],
              ],
            ),
          ),
          if (vm.loading)
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

  Future<void> _openCreateDialog() async {
    final payload = await showDialog<_MenuFormPayload>(
      context: context,
      barrierDismissible: true,
      barrierColor: const Color(0xCC000000),
      builder: (_) => const _MenuFormDialog(),
    );
    if (payload == null || !mounted) return;

    await ref
        .read(menusVmProvider.notifier)
        .createMenu(
          name: payload.name,
          description: payload.description,
          schedule: payload.schedule,
          isActive: payload.isActive,
        );
  }

  Future<void> _openEditDialog(Menu menu) async {
    final payload = await showDialog<_MenuFormPayload>(
      context: context,
      barrierDismissible: true,
      barrierColor: const Color(0xCC000000),
      builder: (_) => _MenuFormDialog(initialMenu: menu),
    );
    if (payload == null || !mounted) return;

    await ref
        .read(menusVmProvider.notifier)
        .updateMenu(
          id: menu.id,
          name: payload.name,
          description: payload.description,
          schedule: payload.schedule,
          isActive: payload.isActive,
        );
  }
}

class _HeaderRow extends StatelessWidget {
  final VoidCallback onBack;
  final VoidCallback onAdd;

  const _HeaderRow({required this.onBack, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: MangoTokens.card,
            borderRadius: BorderRadius.circular(MangoTokens.radiusMd),
            border: Border.all(color: MangoTokens.border),
          ),
          child: IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, size: 20),
            color: MangoTokens.foreground,
            padding: EdgeInsets.zero,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Menu', style: MangoTokens.h1()),
              const SizedBox(height: 2),
              Text('Configuracion de menus', style: MangoTokens.subtitle()),
            ],
          ),
        ),
        SizedBox(
          height: 40,
          child: ElevatedButton.icon(
            onPressed: onAdd,
            style: ElevatedButton.styleFrom(
              backgroundColor: MangoTokens.primary,
              foregroundColor: MangoTokens.primaryForeground,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(MangoTokens.radiusMd),
              ),
            ),
            icon: const Icon(Icons.add, size: 16),
            label: Text(
              'Agregar Menu',
              style: MangoTokens.label(color: MangoTokens.primaryForeground),
            ),
          ),
        ),
      ],
    );
  }
}

class _KpiGrid extends StatelessWidget {
  final int totalMenus;
  final int activeMenus;
  final int totalProducts;

  const _KpiGrid({
    required this.totalMenus,
    required this.activeMenus,
    required this.totalProducts,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width >= 1024 ? 3 : (width >= 768 ? 2 : 1);

        return GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          childAspectRatio: width >= 768 ? 2.7 : 2.2,
          children: [
            _KpiCard(
              label: 'Total Menus',
              value: '$totalMenus',
              valueColor: MangoTokens.foreground,
            ),
            _KpiCard(
              label: 'Activos',
              value: '$activeMenus',
              valueColor: MangoTokens.success,
            ),
            _KpiCard(
              label: 'Total Productos',
              value: '$totalProducts',
              valueColor: MangoTokens.info,
            ),
          ],
        );
      },
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
      decoration: BoxDecoration(
        color: MangoTokens.card,
        borderRadius: BorderRadius.circular(MangoTokens.radius),
        border: Border.all(color: MangoTokens.border),
        boxShadow: MangoTokens.shadowCard,
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label, style: MangoTokens.label()),
            const SizedBox(height: 8),
            Text(value, style: MangoTokens.kpiValue(color: valueColor)),
          ],
        ),
      ),
    );
  }
}

class _MenuListCard extends StatelessWidget {
  final List<Menu> menus;
  final Future<void> Function(Menu menu, bool value) onToggleStatus;
  final Future<void> Function(Menu menu) onEdit;
  final Future<void> Function(Menu menu) onDelete;

  const _MenuListCard({
    required this.menus,
    required this.onToggleStatus,
    required this.onEdit,
    required this.onDelete,
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
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.content_paste,
                  size: 18,
                  color: MangoTokens.secondaryForeground,
                ),
                const SizedBox(width: 8),
                Text(
                  'Lista de Menus',
                  style: MangoTokens.body().copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (menus.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 28,
                  horizontal: 16,
                ),
                decoration: BoxDecoration(
                  color: MangoTokens.background,
                  borderRadius: BorderRadius.circular(MangoTokens.radiusMd),
                  border: Border.all(color: MangoTokens.border),
                ),
                child: Text(
                  'No hay menus configurados',
                  style: MangoTokens.body(color: MangoTokens.mutedForeground),
                ),
              )
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  final tableWidth = constraints.maxWidth < 980
                      ? 980.0
                      : constraints.maxWidth;
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: tableWidth,
                      child: Column(
                        children: [
                          const _MenuTableHeader(),
                          ...menus.map(
                            (menu) => _MenuTableRow(
                              menu: menu,
                              onToggleStatus: onToggleStatus,
                              onEdit: onEdit,
                              onDelete: onDelete,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _MenuTableHeader extends StatelessWidget {
  const _MenuTableHeader();

  @override
  Widget build(BuildContext context) {
    final headerStyle = MangoTokens.label(
      color: MangoTokens.secondaryForeground,
    ).copyWith(fontSize: 15, fontWeight: FontWeight.w600);

    return Container(
      height: 52,
      decoration: const BoxDecoration(
        color: MangoTokens.accent,
        border: Border(bottom: BorderSide(color: MangoTokens.border)),
      ),
      child: Row(
        children: [
          _FlexTableCell(
            flex: 19,
            isHeader: true,
            child: Text('Nombre', style: headerStyle),
          ),
          _FlexTableCell(
            flex: 29,
            isHeader: true,
            child: Text('Descripción', style: headerStyle),
          ),
          _FlexTableCell(
            flex: 19,
            isHeader: true,
            child: Text('Horario', style: headerStyle),
          ),
          _FlexTableCell(
            flex: 12,
            isHeader: true,
            child: Text('Productos', style: headerStyle),
          ),
          _FlexTableCell(
            flex: 12,
            isHeader: true,
            alignment: Alignment.center,
            child: Text('Estado', style: headerStyle),
          ),
          _FlexTableCell(
            flex: 9,
            isHeader: true,
            alignment: Alignment.center,
            child: Text('Acciones', style: headerStyle),
          ),
        ],
      ),
    );
  }
}

class _MenuTableRow extends StatelessWidget {
  final Menu menu;
  final Future<void> Function(Menu menu, bool value) onToggleStatus;
  final Future<void> Function(Menu menu) onEdit;
  final Future<void> Function(Menu menu) onDelete;

  const _MenuTableRow({
    required this.menu,
    required this.onToggleStatus,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final description = _defaultDescription(menu);
    final schedule = _defaultSchedule(menu);

    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: MangoTokens.border)),
      ),
      child: Row(
        children: [
          _FlexTableCell(
            flex: 19,
            child: Text(
              menu.name,
              style: MangoTokens.body().copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          _FlexTableCell(
            flex: 29,
            child: Text(
              description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: MangoTokens.body(color: MangoTokens.mutedForeground),
            ),
          ),
          _FlexTableCell(
            flex: 19,
            child: _Pill(
              text: schedule,
              textColor: MangoTokens.foreground,
              backgroundColor: MangoTokens.card,
              borderColor: MangoTokens.border,
            ),
          ),
          _FlexTableCell(
            flex: 12,
            child: _Pill(
              text: '${menu.itemsCount ?? 0}',
              textColor: MangoTokens.secondaryForeground,
              backgroundColor: MangoTokens.secondary,
              borderColor: Colors.transparent,
            ),
          ),
          _FlexTableCell(
            flex: 12,
            alignment: Alignment.center,
            child: Switch(
              value: menu.isActive,
              onChanged: (value) => onToggleStatus(menu, value),
              activeTrackColor: MangoTokens.primary,
              activeThumbColor: Colors.white,
              inactiveTrackColor: MangoTokens.border,
              inactiveThumbColor: Colors.white,
            ),
          ),
          _FlexTableCell(
            flex: 9,
            alignment: Alignment.center,
            child: Align(
              alignment: Alignment.center,
              child: PopupMenuButton<_MenuAction>(
                icon: const Icon(
                  Icons.more_horiz,
                  size: 18,
                  color: MangoTokens.secondaryForeground,
                ),
                color: MangoTokens.card,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(MangoTokens.radiusSm),
                ),
                onSelected: (action) async {
                  switch (action) {
                    case _MenuAction.edit:
                      await onEdit(menu);
                    case _MenuAction.delete:
                      await onDelete(menu);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem<_MenuAction>(
                    value: _MenuAction.edit,
                    child: Row(
                      children: [
                        const Icon(Icons.edit_outlined, size: 16),
                        const SizedBox(width: 8),
                        Text('Editar', style: MangoTokens.body()),
                      ],
                    ),
                  ),
                  PopupMenuItem<_MenuAction>(
                    value: _MenuAction.delete,
                    child: Row(
                      children: [
                        const Icon(
                          Icons.delete_outline,
                          size: 16,
                          color: MangoTokens.destructive,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Eliminar',
                          style: MangoTokens.body(
                            color: MangoTokens.destructive,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _defaultDescription(Menu menu) {
    if ((menu.description ?? '').trim().isNotEmpty) {
      return menu.description!.trim();
    }
    return switch (menu.name.toLowerCase()) {
      'menu principal' => 'Carta completa del restaurante',
      'menu almuerzo' => 'Opciones de almuerzo ejecutivo',
      'menu desayuno' => 'Desayunos y brunch',
      'menu happy hour' => 'Bebidas y aperitivos especiales',
      _ => 'Sin descripcion',
    };
  }

  String _defaultSchedule(Menu menu) {
    if ((menu.schedule ?? '').trim().isNotEmpty) {
      return menu.schedule!.trim();
    }
    return 'Todo el dia';
  }
}

class _FlexTableCell extends StatelessWidget {
  final int flex;
  final Alignment alignment;
  final bool isHeader;
  final Widget child;

  const _FlexTableCell({
    required this.flex,
    required this.child,
    this.alignment = Alignment.centerLeft,
    this.isHeader = false,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: isHeader ? 12 : 16,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color textColor;
  final Color backgroundColor;
  final Color borderColor;

  const _Pill({
    required this.text,
    required this.textColor,
    required this.backgroundColor,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor),
      ),
      child: Text(
        text,
        style: MangoTokens.body(
          color: textColor,
        ).copyWith(fontWeight: FontWeight.w500),
      ),
    );
  }
}

enum _MenuAction { edit, delete }

class _MenuFormPayload {
  final String name;
  final String? description;
  final String? schedule;
  final bool isActive;

  const _MenuFormPayload({
    required this.name,
    required this.description,
    required this.schedule,
    required this.isActive,
  });
}

class _MenuFormDialog extends StatefulWidget {
  final Menu? initialMenu;

  const _MenuFormDialog({this.initialMenu});

  @override
  State<_MenuFormDialog> createState() => _MenuFormDialogState();
}

class _MenuFormDialogState extends State<_MenuFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _scheduleController;
  late bool _isActive;

  bool get _isEdit => widget.initialMenu != null;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.initialMenu?.name ?? '',
    );
    _descriptionController = TextEditingController(
      text: widget.initialMenu?.description ?? '',
    );
    _scheduleController = TextEditingController(
      text: widget.initialMenu?.schedule ?? 'Todo el dia',
    );
    _isActive = widget.initialMenu?.isActive ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _scheduleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 448),
        child: Container(
          decoration: BoxDecoration(
            color: MangoTokens.card,
            borderRadius: BorderRadius.circular(MangoTokens.radius),
            border: Border.all(color: MangoTokens.border),
            boxShadow: MangoTokens.shadowSoft,
          ),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _isEdit ? 'Editar Menu' : 'Agregar Menu',
                          style: MangoTokens.h1().copyWith(fontSize: 20),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close, size: 20),
                        color: MangoTokens.mutedForeground,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: MangoTokens.border),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _DialogLabel('Nombre *'),
                      _DialogInput(
                        controller: _nameController,
                        hintText: 'Ej: Menu Principal',
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'El nombre es obligatorio';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      _DialogLabel('Descripcion'),
                      _DialogInput(
                        controller: _descriptionController,
                        hintText: 'Descripcion del menu',
                        minLines: 2,
                        maxLines: 3,
                      ),
                      const SizedBox(height: 12),
                      _DialogLabel('Horario'),
                      _DialogInput(
                        controller: _scheduleController,
                        hintText: 'Ej: 11:00 AM - 3:00 PM',
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Text('Activo', style: MangoTokens.body()),
                          const Spacer(),
                          Switch(
                            value: _isActive,
                            onChanged: (v) => setState(() => _isActive = v),
                            activeTrackColor: MangoTokens.primary,
                            activeThumbColor: Colors.white,
                            inactiveTrackColor: MangoTokens.border,
                            inactiveThumbColor: Colors.white,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: MangoTokens.border),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: MangoTokens.border),
                          foregroundColor: MangoTokens.foreground,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              MangoTokens.radiusMd,
                            ),
                          ),
                        ),
                        child: const Text('Cancelar'),
                      ),
                      const SizedBox(width: 10),
                      ElevatedButton(
                        onPressed: _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: MangoTokens.primary,
                          foregroundColor: MangoTokens.primaryForeground,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              MangoTokens.radiusMd,
                            ),
                          ),
                        ),
                        child: Text(_isEdit ? 'Guardar Cambios' : 'Crear Menu'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    Navigator.pop(
      context,
      _MenuFormPayload(
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        schedule: _scheduleController.text.trim(),
        isActive: _isActive,
      ),
    );
  }
}

class _DialogLabel extends StatelessWidget {
  final String text;
  const _DialogLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: MangoTokens.label(color: MangoTokens.secondaryForeground),
      ),
    );
  }
}

class _DialogInput extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final int minLines;
  final int maxLines;
  final String? Function(String?)? validator;

  const _DialogInput({
    required this.controller,
    required this.hintText,
    this.minLines = 1,
    this.maxLines = 1,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      validator: validator,
      style: MangoTokens.body(),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: MangoTokens.body(color: MangoTokens.mutedForeground),
        filled: true,
        fillColor: MangoTokens.card,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MangoTokens.radiusMd),
          borderSide: const BorderSide(color: MangoTokens.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MangoTokens.radiusMd),
          borderSide: const BorderSide(color: MangoTokens.primary, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MangoTokens.radiusMd),
          borderSide: const BorderSide(color: MangoTokens.destructive),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MangoTokens.radiusMd),
          borderSide: const BorderSide(color: MangoTokens.destructive),
        ),
      ),
    );
  }
}
