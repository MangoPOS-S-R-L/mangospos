import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/security/access_control_catalog.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/data/repositories/employee_repository.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _roleHierarchy = <String, int>{
  'owner': 4,
  'admin': 3,
  'manager': 2,
  'cashier': 1,
  'waiter': 1,
  'cook': 1,
  'chef': 1,
  'delivery': 1,
};

bool _canAssignRole(String callerRole, String targetRole) {
  final caller = callerRole.toLowerCase();
  if (caller == 'owner') return true;
  final callerRank = _roleHierarchy[caller] ?? 0;
  final targetRank = _roleHierarchy[targetRole.toLowerCase()] ?? 0;
  return targetRank < callerRank;
}

class SettingsUsersView extends ConsumerStatefulWidget {
  final String businessId;
  const SettingsUsersView({super.key, required this.businessId});

  @override
  ConsumerState<SettingsUsersView> createState() => _SettingsUsersViewState();
}

class _SettingsUsersViewState extends ConsumerState<SettingsUsersView> {
  final _search = TextEditingController();
  String _filterStatus = 'Todos';
  String _filterRole = 'Todos los roles';

  final _repo = EmployeeRepository(Supabase.instance.client);
  List<Employee> _employees = [];
  List<Map<String, dynamic>> _availableRoles = [];
  bool _loading = true;
  String? _error;
  String? _businessId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final sb = Supabase.instance.client;
    try {
      final bid =
          await resolveBusinessIdOrNull(sb, widget.businessId) ??
          widget.businessId;

      try {
        await _repo.ensureBusinessRoleDefaults(businessId: bid);
      } catch (_) {
        // Si el RPC aún no está aplicado en DB, seguimos cargando para no
        // bloquear la pantalla completa.
      }

      final results = await Future.wait([
        _repo.fetchEmployees(businessId: bid),
        _repo.fetchRoles(businessId: bid),
      ]);

      setState(() {
        _businessId = bid;
        _employees = results[0] as List<Employee>;
        _availableRoles = results[1] as List<Map<String, dynamic>>;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Error al cargar datos: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final rolesOptions = [
      'Todos los roles',
      ...{for (final e in _employees) ...e.roles},
    ];

    final filtered = _employees.where((u) {
      final search = _search.text.trim().toLowerCase();
      final matchesSearch =
          search.isEmpty ||
          u.fullName.toLowerCase().contains(search) ||
          u.email.toLowerCase().contains(search) ||
          u.phone.toLowerCase().contains(search);
      final matchesStatus = switch (_filterStatus) {
        'Activos' => u.status == 'active',
        'Inactivos' => u.status == 'inactive',
        'Cambio de Clave' => u.status == 'password_reset',
        _ => true,
      };
      final matchesRole =
          _filterRole == 'Todos los roles' || u.roles.contains(_filterRole);
      return matchesSearch && matchesStatus && matchesRole;
    }).toList();

    final isCompact = ResponsiveHelper.useCompactShell(context);
    return Scaffold(
      backgroundColor: const Color(0xFFFAF8F6),
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.4,
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go(AppRoutes.settings),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Gestión de Usuarios',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: isCompact ? 15 : 18,
              ),
            ),
            if (!isCompact)
              Text(
                'Administra los usuarios del sistema y sus permisos',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
          ],
        ),
        actions: [
          if (isCompact)
            IconButton(
              tooltip: 'Nuevo usuario',
              onPressed: () => _openUserDialog(context),
              icon: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF7F1F),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.add, color: Colors.white, size: 20),
              ),
            )
          else
            ElevatedButton.icon(
              onPressed: () => _openUserDialog(context),
              icon: const Icon(Icons.add),
              label: const Text('Nuevo Usuario'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF7F1F),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          const SizedBox(width: 12),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error!,
                      style: text.bodyMedium?.copyWith(color: Colors.redAccent),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: _load,
                      child: const Text('Reintentar'),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  isCompact ? 12 : 16,
                  isCompact ? 12 : 16,
                  isCompact ? 12 : 16,
                  24,
                ),
                children: [
                  _KpiRow(users: _employees, isCompact: isCompact),
                  SizedBox(height: isCompact ? 14 : 18),
                  _FiltersBar(
                    searchController: _search,
                    onSearch: () => setState(() {}),
                    filterStatus: _filterStatus,
                    onStatusChange: (v) => setState(() => _filterStatus = v),
                    filterRole: _filterRole,
                    roles: rolesOptions,
                    onRoleChange: (v) => setState(() => _filterRole = v),
                  ),
                  const SizedBox(height: 14),
                  if (isCompact)
                    if (filtered.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            'No hay usuarios para los filtros actuales.',
                            style: text.bodyMedium?.copyWith(
                              color: Colors.grey[700],
                            ),
                          ),
                        ),
                      )
                    else
                      ...filtered.map(
                        (u) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _UserCardMobile(
                            user: u,
                            onEdit: () => _openUserDialog(context, user: u),
                            onDelete: () => _deleteUser(u),
                          ),
                        ),
                      )
                  else
                    Card(
                      color: Colors.white,
                      elevation: 0.6,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: Colors.grey.shade200),
                      ),
                      child: Column(
                        children: [
                          _TableHeader(text),
                          const Divider(height: 1),
                          if (filtered.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 24),
                              child: Text(
                                'No hay usuarios para los filtros actuales.',
                                style: text.bodyMedium?.copyWith(
                                  color: Colors.grey[700],
                                ),
                              ),
                            )
                          else
                            ...filtered.map(
                              (u) => _UserRow(
                                user: u,
                                onEdit: () =>
                                    _openUserDialog(context, user: u),
                                onDelete: () => _deleteUser(u),
                                repo: _repo,
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Future<void> _deleteUser(Employee user) async {
    try {
      await _repo.deleteEmployee(employeeId: user.id);
      if (mounted) {
        // ignore: use_build_context_synchronously
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${user.fullName} eliminado.')));
        _load();
      }
    } catch (e) {
      if (mounted) {
        // ignore: use_build_context_synchronously
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error al eliminar: $e')));
      }
    }
  }

  Future<void> _openUserDialog(BuildContext context, {Employee? user}) async {
    final session = ref.read(sessionProvider);
    final activeBusinessId = _businessId ?? widget.businessId;
    final callerRole = session.availableBusinesses
        .firstWhere(
          (b) => b.id == activeBusinessId,
          orElse: () => const SessionBusiness(
            id: '',
            name: '',
            role: '',
          ),
        )
        .role
        .toLowerCase();
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UserDialog(
        user: user,
        businessId: _businessId ?? widget.businessId,
        repo: _repo,
        availableRoles: _availableRoles,
        callerBusinessRole: callerRole,
      ),
    );
    if (result == true) {
      _load();
    }
  }
}

class _KpiRow extends StatelessWidget {
  const _KpiRow({required this.users, this.isCompact = false});
  final List<Employee> users;
  final bool isCompact;

  @override
  Widget build(BuildContext context) {
    final total = users.length;
    final active = users.where((u) => u.status == 'active').length;
    final inactive = users.where((u) => u.status == 'inactive').length;
    final reset = users.where((u) => u.status == 'password_reset').length;
    final cards = [
      _KpiCard(
        title: 'Total Usuarios',
        value: '$total',
        icon: Icons.groups,
        compact: isCompact,
      ),
      _KpiCard(
        title: 'Activos',
        value: '$active',
        icon: Icons.verified_user,
        accent: const Color(0xFF22C55E),
        compact: isCompact,
      ),
      _KpiCard(
        title: 'Inactivos',
        value: '$inactive',
        icon: Icons.person_off,
        compact: isCompact,
      ),
      _KpiCard(
        title: 'Cambio de Clave',
        value: '$reset',
        icon: Icons.vpn_key,
        compact: isCompact,
      ),
    ];
    if (isCompact) {
      // 2x2 grid en móvil
      return LayoutBuilder(
        builder: (context, constraints) {
          const spacing = 10.0;
          final cardWidth = (constraints.maxWidth - spacing) / 2;
          return Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: [
              for (final c in cards) SizedBox(width: cardWidth, child: c),
            ],
          );
        },
      );
    }
    return Row(
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(child: cards[i]),
        ],
      ],
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.title,
    required this.value,
    required this.icon,
    this.accent,
    this.compact = false,
  });
  final String title;
  final String value;
  final IconData icon;
  final Color? accent;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = accent ?? const Color(0xFFFF7F1F);
    return Card(
      color: Colors.white,
      elevation: 0.6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 16,
          vertical: compact ? 10 : 12,
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: compact ? 16 : 20,
              backgroundColor: color.withValues(alpha: 0.12),
              foregroundColor: color,
              child: Icon(icon, size: compact ? 16 : 22),
            ),
            SizedBox(width: compact ? 8 : 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 11 : 13,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 18 : 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FiltersBar extends StatelessWidget {
  const _FiltersBar({
    required this.searchController,
    required this.onSearch,
    required this.filterStatus,
    required this.onStatusChange,
    required this.filterRole,
    required this.roles,
    required this.onRoleChange,
  });

  final TextEditingController searchController;
  final VoidCallback onSearch;
  final String filterStatus;
  final String filterRole;
  final List<String> roles;
  final ValueChanged<String> onStatusChange;
  final ValueChanged<String> onRoleChange;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            blurRadius: 12,
            offset: const Offset(0, 3),
            color: Colors.black.withValues(alpha: 0.04),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: searchController,
                  decoration: InputDecoration(
                    hintText: 'Buscar por nombre, email o teléfono...',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: Colors.grey.shade100,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 0,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (_) => onSearch(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _FilterChip(
                icon: Icons.filter_list,
                label: filterStatus,
                onTap: () async {
                  final value = await _showOptions(context, 'Estado', const [
                    'Todos',
                    'Activos',
                    'Inactivos',
                    'Cambio de Clave',
                  ]);
                  if (value != null) onStatusChange(value);
                },
              ),
              const SizedBox(width: 10),
              _FilterChip(
                icon: Icons.shield_outlined,
                label: filterRole,
                onTap: () async {
                  final value = await _showOptions(context, 'Rol', roles);
                  if (value != null) onRoleChange(value);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.icon, required this.label, this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: Colors.grey[700]),
            const SizedBox(width: 6),
            Text(label),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 18),
          ],
        ),
      ),
    );
  }
}

Future<String?> _showOptions(
  BuildContext context,
  String title,
  List<String> options,
) async {
  return showModalBottomSheet<String>(
    context: context,
    builder: (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          ...options.map(
            (o) => ListTile(
              title: Text(o),
              onTap: () => Navigator.pop(context, o),
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    ),
  );
}

class _TableHeader extends StatelessWidget {
  const _TableHeader(this.text);
  final TextTheme text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          _HeaderCell('Usuario', flex: 3, text: text),
          _HeaderCell('Rol', flex: 2, text: text),
          _HeaderCell('Departamento', flex: 2, text: text),
          _HeaderCell('Salario', flex: 2, text: text),
          _HeaderCell('Estado', flex: 1, text: text),
          const SizedBox(width: 32),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell(this.label, {required this.flex, required this.text});
  final String label;
  final int flex;
  final TextTheme text;
  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Text(
        label,
        style: text.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: Colors.grey[700],
        ),
      ),
    );
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({
    required this.user,
    required this.onEdit,
    required this.onDelete,
    required this.repo,
  });
  final Employee user;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final EmployeeRepository repo;

  String _formatMoney(double? value) {
    if (value == null) return 'RD\$0';
    return 'RD\$${value.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: const Color(0xFFFFF2E8),
                  foregroundColor: const Color(0xFFFF7F1F),
                  child: Text(user.initials),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.fullName,
                      style: text.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(user.email, style: TextStyle(color: Colors.grey[600])),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: _Pill(
              label: user.roles.isNotEmpty ? user.roles.first : 'Sin rol',
            ),
          ),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(user.department ?? '-', style: text.bodyMedium),
                Text(
                  user.position ?? '-',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _formatMoney(user.salaryBase),
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  user.payFrequency ?? '-',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 1,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _StatusPill(status: user.status),
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz, color: Colors.grey),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            offset: const Offset(0, 40),
            onSelected: (value) {
              switch (value) {
                case 'edit':
                  onEdit();
                  break;
                case 'reset_password':
                  _showResetPasswordDialog(context, user);
                  break;
                case 'view_permissions':
                  if (user.userId != null) {
                    context.push(
                      '${AppRoutes.settingsRoles}/${user.userId}/${user.id}',
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Este empleado no tiene un usuario de acceso vinculado.',
                        ),
                      ),
                    );
                  }
                  break;
                case 'deactivate':
                  _showDeactivateDialog(context, user);
                  break;
                case 'delete':
                  _showDeleteDialog(context, user);
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(
                      Icons.edit_outlined,
                      size: 20,
                      color: Colors.grey[700],
                    ),
                    const SizedBox(width: 12),
                    const Text('Editar Usuario'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'reset_password',
                child: Row(
                  children: [
                    Icon(Icons.key_outlined, size: 20, color: Colors.grey[700]),
                    const SizedBox(width: 12),
                    const Text('Resetear Contraseña'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'view_permissions',
                child: Row(
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 20,
                      color: Colors.grey[700],
                    ),
                    const SizedBox(width: 12),
                    const Text('Editar Permisos'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'deactivate',
                child: Row(
                  children: [
                    Icon(
                      Icons.person_off_outlined,
                      size: 20,
                      color: Colors.grey[700],
                    ),
                    const SizedBox(width: 12),
                    const Text('Desactivar'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_outline,
                      size: 20,
                      color: Colors.red[600],
                    ),
                    const SizedBox(width: 12),
                    Text('Eliminar', style: TextStyle(color: Colors.red[600])),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showResetPasswordDialog(BuildContext context, Employee user) {
    if (user.userId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Este empleado no tiene un usuario de acceso vinculado.',
          ),
        ),
      );
      return;
    }

    final passwordController = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => _ResetPasswordDialog(
        user: user,
        passwordController: passwordController,
        repo: repo,
      ),
    ).whenComplete(() => passwordController.dispose());
  }

  void _showDeactivateDialog(BuildContext context, Employee user) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Desactivar Usuario'),
        content: Text('¿Deseas desactivar a ${user.fullName}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF97316),
            ),
            onPressed: () {
              // TODO: Implementar desactivación
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Usuario desactivado')),
              );
            },
            child: const Text('Desactivar'),
          ),
        ],
      ),
    );
  }

  void _showDeleteDialog(BuildContext context, Employee user) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Eliminar Usuario'),
        content: Text(
          '¿Estás seguro de eliminar a ${user.fullName}? Esta acción no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red[600]),
            onPressed: () {
              Navigator.pop(context);
              onDelete();
            },
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
  }
}

// Vista compacta de usuario para móvil: card apilada en vez de fila tabla.
// Reutiliza `_Pill`, `_StatusPill` y los dialogs definidos en `_UserRow` no
// son accesibles desde fuera, así que para móvil solo dejamos editar +
// eliminar + permisos en el menú (el flujo más común). Resetear contraseña
// y desactivar quedan accesibles abriendo el usuario y editándolo.
class _UserCardMobile extends StatelessWidget {
  const _UserCardMobile({
    required this.user,
    required this.onEdit,
    required this.onDelete,
  });
  final Employee user;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  String _formatMoney(double? value) {
    if (value == null) return 'RD\$0';
    return 'RD\$${value.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.white,
      elevation: 0.4,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: InkWell(
        onTap: onEdit,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: const Color(0xFFFFF2E8),
                    foregroundColor: const Color(0xFFFF7F1F),
                    child: Text(user.initials,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user.fullName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          user.email,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_horiz, color: Colors.grey),
                    onSelected: (value) {
                      switch (value) {
                        case 'edit':
                          onEdit();
                          break;
                        case 'view_permissions':
                          if (user.userId != null) {
                            context.push(
                              '${AppRoutes.settingsRoles}/${user.userId}/${user.id}',
                            );
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Este empleado no tiene un usuario de acceso vinculado.',
                                ),
                              ),
                            );
                          }
                          break;
                        case 'delete':
                          showDialog<void>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              title: const Text('Eliminar Usuario'),
                              content: Text(
                                '¿Estás seguro de eliminar a ${user.fullName}? '
                                'Esta acción no se puede deshacer.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('Cancelar'),
                                ),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.red[600],
                                  ),
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    onDelete();
                                  },
                                  child: const Text('Eliminar'),
                                ),
                              ],
                            ),
                          );
                          break;
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem<String>(
                        value: 'edit',
                        child: Row(
                          children: [
                            Icon(Icons.edit_outlined,
                                size: 18, color: Colors.grey[700]),
                            const SizedBox(width: 10),
                            const Text('Editar usuario'),
                          ],
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'view_permissions',
                        child: Row(
                          children: [
                            Icon(Icons.shield_outlined,
                                size: 18, color: Colors.grey[700]),
                            const SizedBox(width: 10),
                            const Text('Editar permisos'),
                          ],
                        ),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem<String>(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline,
                                size: 18, color: Colors.red[600]),
                            const SizedBox(width: 10),
                            Text(
                              'Eliminar',
                              style: TextStyle(color: Colors.red[600]),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _Pill(
                    label: user.roles.isNotEmpty
                        ? user.roles.first
                        : 'Sin rol',
                  ),
                  _StatusPill(status: user.status),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Departamento',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.grey[500],
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          user.department ?? '-',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if ((user.position ?? '').isNotEmpty)
                          Text(
                            user.position!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Salario',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.grey[500],
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _formatMoney(user.salaryBase),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if ((user.payFrequency ?? '').isNotEmpty)
                          Text(
                            user.payFrequency!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(30),
      ),
      child: Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});
  final String status;
  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    String label;
    switch (status) {
      case 'inactive':
        bg = const Color(0xFFF1EDEA);
        fg = const Color(0xFF8D7C72);
        label = 'Inactivo';
        break;
      case 'password_reset':
        bg = const Color(0xFFFFF5E5);
        fg = const Color(0xFFCC7A00);
        label = 'Cambio de clave';
        break;
      default:
        bg = const Color(0xFFDFF7E5);
        fg = const Color(0xFF1E8D4D);
        label = 'Activo';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(30),
      ),
      child: Text(
        label,
        style: TextStyle(color: fg, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _UserDialog extends StatefulWidget {
  const _UserDialog({
    this.user,
    required this.businessId,
    required this.repo,
    required this.availableRoles,
    required this.callerBusinessRole,
  });
  final Employee? user;
  final String businessId;
  final EmployeeRepository repo;
  final List<Map<String, dynamic>> availableRoles;
  final String callerBusinessRole;

  @override
  State<_UserDialog> createState() => _UserDialogState();
}

class _UserDialogState extends State<_UserDialog> {
  int _tab = 0;
  int _maxStep = 0;
  final _tabs = const ['Personal', 'Trabajo', 'Salario', 'Roles', 'Emergencia'];
  bool _saving = false;

  // Controllers básicos
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _nationalId = TextEditingController(text: '000-0000000-0');
  final _address = TextEditingController();
  final _password = TextEditingController();
  final _pin = TextEditingController();
  final _salary = TextEditingController();
  final _workSchedule = TextEditingController();
  final _accountNumber = TextEditingController();
  final _emergencyName = TextEditingController();
  final _emergencyRelation = TextEditingController();
  final _emergencyPhone = TextEditingController();
  DateTime? _hireDate;
  String _gender = 'Seleccionar';
  String _department = 'Seleccionar';
  String _position = 'Seleccionar';
  String _payFrequency = 'Mensual';
  String _contractType = 'Tiempo Completo';
  String _afp = 'AFP Popular';
  String _ars = 'ARS Humano';
  String _bank = 'Popular';
  final List<String> _selectedRoles = [];
  Set<String> _effectivePermissionCodes = {};
  String _primaryBusinessRole = 'waiter';
  bool _loadingAccess = false;
  bool _accessDirty = false;
  bool _hasLoginAccess = false;

  @override
  void initState() {
    super.initState();
    if (widget.user != null) {
      _loadUserData(widget.user!);
      _loadAccessProfile();
    } else {
      _ensureDefaultRoleSelected();
      _applyPresetForRole(_primaryBusinessRole);
    }
  }

  void _loadUserData(Employee user) {
    // Cargar datos personales
    _firstName.text = user.firstName;
    _lastName.text = user.lastName;
    _email.text = user.email;
    _phone.text = user.phone;
    _nationalId.text = user.nationalId ?? '000-0000000-0';
    _address.text = user.address ?? '';
    _gender = user.gender ?? 'Seleccionar';

    // Cargar datos de trabajo
    _hireDate = user.hireDate;
    _contractType = user.contractType ?? 'Tiempo Completo';
    _department = user.department ?? 'Seleccionar';
    _position = user.position ?? 'Seleccionar';
    _workSchedule.text = user.workSchedule ?? '';

    // Cargar datos de salario
    if (user.salaryBase != null) {
      _salary.text = user.salaryBase!.toStringAsFixed(0);
    }
    _payFrequency = user.payFrequency ?? 'Mensual';
    _bank = user.bankName ?? 'Popular';
    _accountNumber.text = user.bankAccount ?? '';

    // NO cargar PIN ni contraseña por seguridad
    // Los campos estarán bloqueados al editar

    // Cargar datos de emergencia
    _emergencyName.text = user.emergencyName ?? '';
    _emergencyRelation.text = user.emergencyRelation ?? '';
    _emergencyPhone.text = user.emergencyPhone ?? '';

    // Cargar roles
    // Cargar roles mapeando nombres a IDs
    _selectedRoles.clear();
    for (final roleName in user.roles) {
      try {
        final role = widget.availableRoles.firstWhere(
          (r) => r['name'] == roleName,
        );
        _selectedRoles.add(role['id'] as String);
        _primaryBusinessRole = normalizeBusinessRole(role['name']?.toString());
      } catch (_) {
        // Rol no encontrado en la configuración actual o borrado
      }
    }

    // TODO: Cargar AFP y ARS cuando estén disponibles en el modelo
  }

  Future<void> _loadAccessProfile() async {
    final user = widget.user;
    if (user == null) return;

    setState(() => _loadingAccess = true);
    try {
      final payload = await widget.repo.fetchUserAccessProfile(
        employeeId: user.id,
        businessId: widget.businessId,
      );

      final roleIds =
          (payload['role_ids'] as List?)
              ?.map((value) => value.toString())
              .where((value) => value.isNotEmpty)
              .toList() ??
          const <String>[];
      final effectivePermissions =
          (payload['effective_permissions'] as List?)
              ?.map((value) => value.toString())
              .where((value) => value.isNotEmpty)
              .toSet() ??
          <String>{};

      if (!mounted) return;
      setState(() {
        _selectedRoles
          ..clear()
          ..addAll(roleIds);
        _primaryBusinessRole = normalizeBusinessRole(
          payload['primary_role']?.toString(),
        );
        _effectivePermissionCodes = effectivePermissions;
        _hasLoginAccess = payload['has_login'] == true;
        _loadingAccess = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingAccess = false;
        _hasLoginAccess = user.userId != null;
        if (_effectivePermissionCodes.isEmpty) {
          _applyPresetForRole(_primaryBusinessRole);
        }
      });
    }
  }

  void _applyPresetForRole(String roleKey) {
    _effectivePermissionCodes = presetCodesForRole(roleKey);
  }

  void _ensureDefaultRoleSelected() {
    if (_selectedRoles.isNotEmpty) return;
    Map<String, dynamic>? preferredRole;
    for (final role in _systemRoles) {
      final normalized = normalizeBusinessRole(role['name']?.toString());
      if (normalized == 'waiter') {
        preferredRole = role;
        break;
      }
      preferredRole ??= role;
    }
    if (preferredRole == null) return;
    _selectedRoles
      ..clear()
      ..add(preferredRole['id'].toString());
    _primaryBusinessRole = normalizeBusinessRole(
      preferredRole['name']?.toString(),
    );
  }

  List<Map<String, dynamic>> get _systemRoles {
    const systemRoleNames = {
      'owner',
      'admin',
      'manager',
      'cashier',
      'waiter',
      'cook',
      'delivery',
      'chef',
    };
    return widget.availableRoles
        .where((role) {
          final name = (role['name']?.toString() ?? '').toLowerCase();
          if (!systemRoleNames.contains(name)) return false;
          return _canAssignRole(widget.callerBusinessRole, name);
        })
        .toList(growable: false);
  }

  Map<String, int> _categoryCounts(Set<String> codes) {
    final counts = <String, int>{};
    for (final category in accessCategories) {
      final items = permissionsForCategory(category.id);
      counts[category.id] = items
          .where((item) => codes.contains(item.code))
          .length;
    }
    return counts;
  }

  Future<void> _openPermissionsEditor() async {
    final selectedRole = _primaryBusinessRole;
    final currentCodes = {..._effectivePermissionCodes};
    var workingCodes = {...currentCodes};
    var selectedCategoryId = accessCategories.first.id;

    final applied = await showDialog<Set<String>>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final category = accessCategories.firstWhere(
              (item) => item.id == selectedCategoryId,
            );
            final categoryPermissions = permissionsForCategory(category.id);
            final allSelected =
                categoryPermissions.isNotEmpty &&
                categoryPermissions.every(
                  (permission) => workingCodes.contains(permission.code),
                );
            final counts = _categoryCounts(workingCodes);

            return Dialog(
              backgroundColor: Colors.white,
              insetPadding: const EdgeInsets.all(24),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: SizedBox(
                width: 1080,
                height: 720,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Permisos del usuario',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Cargo: ${businessRoleLabel(selectedRole)}',
                                  style: TextStyle(
                                    color: Colors.grey[700],
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () {
                              setModalState(() {
                                workingCodes = presetCodesForRole(selectedRole);
                              });
                            },
                            icon: const Icon(Icons.replay_outlined),
                            label: const Text('Usar permisos predeterminados'),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: Row(
                        children: [
                          Container(
                            width: 320,
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8F7F5),
                              border: Border(
                                right: BorderSide(color: Colors.grey.shade200),
                              ),
                            ),
                            child: ListView.separated(
                              itemCount: accessCategories.length,
                              separatorBuilder: (_, separatorIndex) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (context, index) {
                                final item = accessCategories[index];
                                final total = permissionsForCategory(
                                  item.id,
                                ).length;
                                final selected = counts[item.id] ?? 0;
                                final active = item.id == selectedCategoryId;

                                return InkWell(
                                  onTap: () {
                                    setModalState(() {
                                      selectedCategoryId = item.id;
                                    });
                                  },
                                  borderRadius: BorderRadius.circular(14),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 14,
                                    ),
                                    decoration: BoxDecoration(
                                      color: active
                                          ? const Color(0xFFFFF1E4)
                                          : Colors.white,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: active
                                            ? const Color(0xFFFFB36B)
                                            : Colors.grey.shade200,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            item.label,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                              color: active
                                                  ? const Color(0xFFF97316)
                                                  : const Color(0xFF2C2C2C),
                                            ),
                                          ),
                                        ),
                                        Text(
                                          '$selected/$total',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w700,
                                            color: Colors.grey[700],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          category.label,
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                      Checkbox(
                                        value: allSelected,
                                        onChanged: (value) {
                                          setModalState(() {
                                            for (final permission
                                                in categoryPermissions) {
                                              if (value == true) {
                                                workingCodes.add(
                                                  permission.code,
                                                );
                                              } else {
                                                workingCodes.remove(
                                                  permission.code,
                                                );
                                              }
                                            }
                                          });
                                        },
                                      ),
                                      const Text(
                                        'Seleccionar todo',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Expanded(
                                    child: ListView.separated(
                                      itemCount: categoryPermissions.length,
                                      separatorBuilder: (_, separatorIndex) =>
                                          Divider(
                                            height: 1,
                                            color: Colors.grey.shade200,
                                          ),
                                      itemBuilder: (context, index) {
                                        final permission =
                                            categoryPermissions[index];
                                        final selected = workingCodes.contains(
                                          permission.code,
                                        );
                                        return SwitchListTile(
                                          value: selected,
                                          onChanged: (value) {
                                            setModalState(() {
                                              if (value) {
                                                workingCodes.add(
                                                  permission.code,
                                                );
                                              } else {
                                                workingCodes.remove(
                                                  permission.code,
                                                );
                                              }
                                            });
                                          },
                                          title: Text(
                                            permission.label,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          subtitle: Text(
                                            permission.description,
                                            style: TextStyle(
                                              color: Colors.grey[600],
                                            ),
                                          ),
                                          activeThumbColor: const Color(
                                            0xFF3B82F6,
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Cancelar'),
                          ),
                          ElevatedButton.icon(
                            onPressed: () =>
                                Navigator.of(context).pop({...workingCodes}),
                            icon: const Icon(Icons.add_task_outlined),
                            label: const Text('Aplicar permisos'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF3B82F6),
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (applied == null || !mounted) return;
    setState(() {
      _effectivePermissionCodes = applied;
      _accessDirty = true;
    });
  }

  /// Mapea errores crudos del backend (PostgrestException, signUp,
  /// etc.) a mensajes accionables para el cajero. Cubre los casos
  /// más comunes; cualquier otro error cae al fallback con la causa
  /// raíz visible.
  String _friendlyUserSaveError(Object error) {
    final raw = error.toString();
    final lower = raw.toLowerCase();

    // Email duplicado en auth.users (constraint partial unique).
    if (lower.contains('users_email_partial_key') ||
        lower.contains('already registered') ||
        lower.contains('already been registered') ||
        lower.contains('user_already_exists') ||
        (lower.contains('email') &&
            lower.contains('already exists'))) {
      final email = _email.text.trim();
      return 'El correo ${email.isEmpty ? '' : '"$email" '}ya tiene una '
          'cuenta registrada. Si es la misma persona, contáctala para '
          'que inicie sesión con ese correo, o usa un email distinto '
          'para este usuario.';
    }

    // Pin duplicado (si hay constraint en employees.pin per business).
    if (lower.contains('pin') && lower.contains('duplicate')) {
      return 'Ese PIN ya está asignado a otro usuario en este negocio. '
          'Elige uno distinto.';
    }

    // Password muy corto (Supabase Auth: mínimo 6).
    if (lower.contains('password') &&
        (lower.contains('short') || lower.contains('weak'))) {
      return 'La contraseña debe tener al menos 6 caracteres.';
    }

    // Email inválido.
    if (lower.contains('invalid') && lower.contains('email')) {
      return 'El correo no tiene un formato válido. Revísalo.';
    }

    // Conexión.
    if (lower.contains('socket') ||
        lower.contains('timeout') ||
        lower.contains('failed host lookup')) {
      return 'Sin conexión al servidor. Verifica tu internet e intenta '
          'de nuevo.';
    }

    // Fallback: dejar el error crudo accesible para soporte pero más
    // limpio de leer.
    return 'No se pudo guardar el usuario. Detalle técnico: $raw';
  }

  Future<void> _onSubmit() async {
    if (_firstName.text.isEmpty ||
        _lastName.text.isEmpty ||
        _email.text.isEmpty ||
        _phone.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Completa nombre, apellido, email y teléfono.'),
        ),
      );
      return;
    }
    if (_selectedRoles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Selecciona al menos un cargo para el usuario.'),
        ),
      );
      return;
    }

    final normalizedPin = _pin.text.trim();
    final isEditing = widget.user != null;
    // Al editar un usuario existente, si dejan el PIN vacío lo mantenemos como
    // estaba (no queremos forzar re-teclearlo cada vez que se modifica otro
    // campo). Solo exigimos PIN al crear un usuario nuevo.
    if (!isEditing && normalizedPin.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Debes asignar un PIN de 4 dígitos al usuario.'),
        ),
      );
      return;
    }
    if (normalizedPin.isNotEmpty &&
        !RegExp(r'^\d{4}$').hasMatch(normalizedPin)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('El PIN debe ser numérico y de 4 dígitos.'),
        ),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      final parsedSalary = double.tryParse(_salary.text.replaceAll(',', ''));

      // Usamos los IDs directamente de _selectedRoles
      final List<String> roleIds = List.from(_selectedRoles);

      if (widget.user != null) {
        // ACTUALIZAR USUARIO EXISTENTE
        await widget.repo.updateEmployee(
          employeeId: widget.user!.id,
          firstName: _firstName.text.trim(),
          lastName: _lastName.text.trim(),
          email: _email.text.trim(),
          phone: _phone.text.trim(),
          nationalId: _nationalId.text.trim(),
          gender: _gender == 'Seleccionar' ? null : _gender,
          address: _address.text.trim(),
          hireDate: _hireDate,
          contractType: _contractType,
          department: _department == 'Seleccionar' ? null : _department,
          position: _position == 'Seleccionar' ? null : _position,
          workSchedule: _workSchedule.text.trim(),
          salaryBase: parsedSalary,
          payFrequency: _payFrequency,
          bankName: _bank,
          bankAccount: _accountNumber.text.trim(),
          emergencyName: _emergencyName.text.trim(),
          emergencyRelation: _emergencyRelation.text.trim(),
          emergencyPhone: _emergencyPhone.text.trim(),
          pin: normalizedPin.isNotEmpty ? normalizedPin : null,
        );

        // Actualizar contraseña si se proporcionó una nueva
        final newPassword = _password.text.trim();
        if (newPassword.isNotEmpty && widget.user!.userId != null) {
          if (newPassword.length < 6) {
            setState(() => _saving = false);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('La contraseña debe tener al menos 6 caracteres.'),
                ),
              );
            }
            return;
          }
          await widget.repo.updateUserPassword(
            userId: widget.user!.userId!,
            newPassword: newPassword,
          );
        }

        // Actualizar roles
        await widget.repo.updateEmployeeRoles(
          employeeId: widget.user!.id,
          roleIds: roleIds,
        );

        await widget.repo.saveUserAccessProfile(
          employeeId: widget.user!.id,
          businessId: widget.businessId,
          roleIds: roleIds,
          primaryRole: _primaryBusinessRole,
          effectivePermissionCodes: _effectivePermissionCodes,
        );

        if (mounted) {
          Navigator.of(context).pop(true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Usuario actualizado correctamente.')),
          );
        }
      } else {
        // CREAR NUEVO USUARIO
        final createdEmployee = await widget.repo.createEmployee(
          businessId: widget.businessId,
          firstName: _firstName.text.trim(),
          lastName: _lastName.text.trim(),
          email: _email.text.trim(),
          phone: _phone.text.trim(),
          nationalId: _nationalId.text.trim(),
          gender: _gender == 'Seleccionar' ? null : _gender,
          address: _address.text.trim(),
          hireDate: _hireDate,
          contractType: _contractType,
          department: _department == 'Seleccionar' ? null : _department,
          position: _position == 'Seleccionar' ? null : _position,
          workSchedule: _workSchedule.text.trim(),
          salaryBase: parsedSalary,
          payFrequency: _payFrequency,
          bankName: _bank,
          bankAccount: _accountNumber.text.trim(),
          emergencyName: _emergencyName.text.trim(),
          emergencyRelation: _emergencyRelation.text.trim(),
          emergencyPhone: _emergencyPhone.text.trim(),
          pin: normalizedPin.isNotEmpty ? normalizedPin : null,
          password: _password.text.isNotEmpty ? _password.text.trim() : null,
          primaryRole: _primaryBusinessRole,
          roleIds: roleIds,
        );

        await widget.repo.saveUserAccessProfile(
          employeeId: createdEmployee.id,
          businessId: widget.businessId,
          roleIds: roleIds,
          primaryRole: _primaryBusinessRole,
          effectivePermissionCodes: _effectivePermissionCodes,
        );

        if (mounted) {
          Navigator.of(context).pop(true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Usuario creado correctamente.')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_friendlyUserSaveError(e)),
            backgroundColor: const Color(0xFFEF4444),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _email.dispose();
    _phone.dispose();
    _nationalId.dispose();
    _address.dispose();
    _password.dispose();
    _pin.dispose();
    _salary.dispose();
    _workSchedule.dispose();
    _accountNumber.dispose();
    _emergencyName.dispose();
    _emergencyRelation.dispose();
    _emergencyPhone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        width: 720,
        constraints: const BoxConstraints(maxHeight: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 20, 16),
              child: Row(
                children: [
                  Text(
                    widget.user == null ? 'Nuevo Usuario' : 'Editar Usuario',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),

            // Tabs
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: List.generate(_tabs.length, (i) {
                  final selected = _tab == i;
                  final icon = switch (i) {
                    0 => Icons.person_outline,
                    1 => Icons.work_outline,
                    2 => Icons.attach_money,
                    3 => Icons.shield_outlined,
                    _ => Icons.favorite_border,
                  };
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: i <= _maxStep
                            ? () => setState(() => _tab = i)
                            : null,
                        borderRadius: BorderRadius.circular(8),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeInOut,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: selected
                                ? const Color(0xFFF5F5F5)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                icon,
                                size: 16,
                                color: selected
                                    ? const Color(0xFF1A1A1A)
                                    : const Color(0xFF9E9E9E),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _tabs[i],
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: selected
                                      ? const Color(0xFF1A1A1A)
                                      : const Color(0xFF9E9E9E),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),

            const SizedBox(height: 20),

            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  switchInCurve: Curves.easeInOut,
                  switchOutCurve: Curves.easeInOut,
                  transitionBuilder: (child, animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0.02, 0),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    );
                  },
                  child: _tabContent(_tab),
                ),
              ),
            ),

            // Footer
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF666666),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Cancelar',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: _saving
                        ? null
                        : () {
                            if (_tab < _tabs.length - 1) {
                              setState(() {
                                _tab++;
                                if (_tab > _maxStep) _maxStep = _tab;
                              });
                            } else {
                              _onSubmit();
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF7F1F),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      elevation: 0,
                    ),
                    child: Text(
                      _tab == _tabs.length - 1
                          ? (widget.user == null
                                ? 'Crear Usuario'
                                : 'Guardar cambios')
                          : 'Siguiente',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabContent(int index) {
    switch (index) {
      case 0:
        return Column(
          key: const ValueKey(0),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _LabeledField(
                    label: 'Nombre *',
                    controller: _firstName,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _LabeledField(
                    label: 'Apellido *',
                    controller: _lastName,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _LabeledField(label: 'Email *', controller: _email),
            const SizedBox(height: 16),
            _LabeledField(
              label: 'Cédula',
              hint: '000-0000000-0',
              controller: _nationalId,
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _LabeledField(
                    label: 'Teléfono *',
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _DropdownField(
                    label: 'Género',
                    items: const [
                      'Seleccionar',
                      'Masculino',
                      'Femenino',
                      'Otro',
                    ],
                    value: _gender,
                    onChanged: (v) => setState(() => _gender = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _LabeledField(label: 'Dirección', controller: _address),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _LabeledField(
                    label: widget.user == null
                        ? 'Contraseña *'
                        : 'Nueva Contraseña',
                    controller: _password,
                    hint: widget.user == null
                        ? 'Mínimo 6 caracteres'
                        : 'Dejar vacío para no cambiar',
                    obscureText: true,
                    showVisibilityToggle: true,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _LabeledField(
                    label: 'PIN (4 dígitos)',
                    controller: _pin,
                    hint: 'Ej: 1234',
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                    digitsOnly: true,
                    obscureText: true,
                    showVisibilityToggle: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        );
      case 1:
        return Column(
          key: const ValueKey(1),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _DropdownField(
                    label: 'Departamento *',
                    items: const [
                      'Seleccionar',
                      'Gerencia',
                      'Administración',
                      'Cocina',
                      'Servicio/Salón',
                      'Barra',
                      'Caja',
                      'Delivery',
                      'Limpieza',
                      'Seguridad',
                      'Recursos Humanos',
                      'Marketing',
                    ],
                    value: _department,
                    onChanged: (v) => setState(() => _department = v),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _DropdownField(
                    label: 'Posición *',
                    items: const [
                      'Seleccionar',
                      'Gerente General',
                      'Gerente de Turno',
                      'Supervisor',
                      'Chef Ejecutivo',
                      'Sous Chef',
                      'Cocinero',
                      'Ayudante de Cocina',
                      'Bartender',
                      'Mesero',
                      'Host/Hostess',
                      'Cajero',
                    ],
                    value: _position,
                    onChanged: (v) => setState(() => _position = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _DropdownField(
                    label: 'Tipo de Contrato',
                    items: const [
                      'Tiempo Completo',
                      'Medio Tiempo',
                      'Temporal',
                    ],
                    value: _contractType,
                    onChanged: (v) => setState(() => _contractType = v),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _DateField(
                    label: 'Fecha de Ingreso',
                    selectedDate: _hireDate,
                    onDateSelected: (date) => setState(() => _hireDate = date),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _LabeledField(
              label: 'Horario de Trabajo',
              hint: 'Ej: Lun-Vie 8:00-17:00',
              controller: _workSchedule,
            ),
            const SizedBox(height: 24),
          ],
        );
      case 2:
        return Column(
          key: const ValueKey(2),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _LabeledField(
                    label: 'Salario Base (DOP) *',
                    controller: _salary,
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _DropdownField(
                    label: 'Frecuencia de Pago',
                    items: const ['Semanal', 'Quincenal', 'Mensual'],
                    value: _payFrequency,
                    onChanged: (v) => setState(() => _payFrequency = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _DropdownField(
                    label: 'AFP (2.87%)',
                    items: const ['AFP Popular', 'AFP Crecer', 'AFP Siembra'],
                    value: _afp,
                    onChanged: (v) => setState(() => _afp = v),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _DropdownField(
                    label: 'ARS (3.04%)',
                    items: const ['ARS Humano', 'ARS Universal', 'ARS Mapfre'],
                    value: _ars,
                    onChanged: (v) => setState(() => _ars = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const _LabeledField(
              label: 'Beneficios',
              hint: 'Transporte, Alimentación...',
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _DropdownField(
                    label: 'Banco',
                    items: const ['Popular', 'BHD', 'Reservas'],
                    value: _bank,
                    onChanged: (v) => setState(() => _bank = v),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _LabeledField(
                    label: 'Número de Cuenta',
                    controller: _accountNumber,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        );
      case 3:
        final categoryCounts = _categoryCounts(_effectivePermissionCodes);
        return Column(
          key: const ValueKey(3),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Define el cargo principal y ajusta los permisos de este usuario.',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (_loadingAccess)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (_systemRoles.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('No hay roles disponibles configurados.'),
                ),
              )
            else
              ..._systemRoles.map((role) {
                final id = role['id'] as String;
                final roleName = role['name'] as String;
                final desc = role['description'] as String?;
                final normalizedRole = normalizeBusinessRole(roleName);

                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _RoleCheckbox(
                    title: businessRoleLabel(roleName),
                    description: desc ?? roleName,
                    isSelected: _selectedRoles.contains(id),
                    onChanged: (selected) {
                      setState(() {
                        _selectedRoles
                          ..clear()
                          ..add(id);
                        _primaryBusinessRole = normalizedRole;
                        _applyPresetForRole(normalizedRole);
                        _accessDirty = false;
                      });
                    },
                  ),
                );
              }),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F7F5),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Permisos',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _hasLoginAccess
                                  ? 'Este usuario tiene acceso al sistema. Puedes ajustar permisos finos por encima del cargo.'
                                  : 'Este registro es un empleado sin login enlazado. El cargo y permisos quedaran preparados para cuando tenga acceso.',
                              style: TextStyle(
                                color: Colors.grey[700],
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _selectedRoles.isEmpty
                            ? null
                            : _openPermissionsEditor,
                        icon: const Icon(Icons.tune_outlined),
                        label: Text(
                          _accessDirty
                              ? 'Editar permisos personalizados'
                              : 'Asignar permisos',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: accessCategories
                        .map((category) {
                          final total = permissionsForCategory(
                            category.id,
                          ).length;
                          final selected = categoryCounts[category.id] ?? 0;
                          return Container(
                            width: 220,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.grey.shade200),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  category.label,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '$selected / $total permisos',
                                  style: TextStyle(
                                    color: Colors.grey[700],
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          );
                        })
                        .toList(growable: false),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        );
      case 4:
      default:
        return Column(
          key: const ValueKey(4),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _LabeledField(
              label: 'Nombre del Contacto',
              controller: _emergencyName,
            ),
            const SizedBox(height: 16),
            _LabeledField(label: 'Relación', controller: _emergencyRelation),
            const SizedBox(height: 16),
            _LabeledField(
              label: 'Teléfono',
              controller: _emergencyPhone,
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 24),
          ],
        );
    }
  }
}

class _ResetPasswordDialog extends StatefulWidget {
  const _ResetPasswordDialog({
    required this.user,
    required this.passwordController,
    required this.repo,
  });
  final Employee user;
  final TextEditingController passwordController;
  final EmployeeRepository repo;

  @override
  State<_ResetPasswordDialog> createState() => _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends State<_ResetPasswordDialog> {
  bool _saving = false;
  bool _obscured = true;

  Future<void> _handleReset() async {
    final password = widget.passwordController.text.trim();
    if (password.isEmpty || password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('La contraseña debe tener al menos 6 caracteres.'),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await widget.repo.updateUserPassword(
        userId: widget.user.userId!,
        newPassword: password,
      );
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Contraseña de ${widget.user.fullName} actualizada correctamente.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al cambiar contraseña: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const kPrimary = Color(0xFFFF7F1F);
    const kTextSecondary = Color(0xFF6B7280);
    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'Cambiar Contraseña',
        style: TextStyle(fontWeight: FontWeight.w700),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Nueva contraseña para ${widget.user.fullName}:',
            style: const TextStyle(color: kTextSecondary),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: widget.passwordController,
            obscureText: _obscured,
            decoration: InputDecoration(
              hintText: 'Mínimo 6 caracteres',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscured
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 20,
                ),
                onPressed: () => setState(() => _obscured = !_obscured),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: kTextSecondary),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _handleReset,
          style: ElevatedButton.styleFrom(
            backgroundColor: kPrimary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            elevation: 0,
          ),
          child: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : const Text(
                  'Guardar',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
        ),
      ],
    );
  }
}

class _LabeledField extends StatefulWidget {
  const _LabeledField({
    required this.label,
    this.hint,
    this.controller,
    this.enabled = true,
    this.keyboardType,
    this.maxLength,
    this.digitsOnly = false,
    this.obscureText = false,
    this.showVisibilityToggle = false,
  });
  final String label;
  final String? hint;
  final TextEditingController? controller;
  final bool enabled;
  final TextInputType? keyboardType;
  final int? maxLength;
  final bool digitsOnly;
  final bool obscureText;
  final bool showVisibilityToggle;

  @override
  State<_LabeledField> createState() => _LabeledFieldState();
}

class _LabeledFieldState extends State<_LabeledField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    final effectiveObscure = widget.obscureText && _obscured;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Color(0xFF666666),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: widget.controller,
          enabled: widget.enabled,
          keyboardType: widget.keyboardType,
          obscureText: effectiveObscure,
          maxLength: widget.maxLength,
          inputFormatters: [
            if (widget.digitsOnly) FilteringTextInputFormatter.digitsOnly,
            if (widget.maxLength != null)
              LengthLimitingTextInputFormatter(widget.maxLength),
          ],
          style: const TextStyle(fontSize: 14, color: Color(0xFF1A1A1A)),
          decoration: InputDecoration(
            hintText: widget.hint,
            counterText: '',
            hintStyle: TextStyle(fontSize: 14, color: Colors.grey.shade400),
            filled: true,
            fillColor:
                widget.enabled ? Colors.white : const Color(0xFFF9F9F9),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
            suffixIcon: widget.showVisibilityToggle && widget.obscureText
                ? IconButton(
                    icon: Icon(
                      _obscured
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 20,
                      color: Colors.grey.shade500,
                    ),
                    onPressed: () => setState(() => _obscured = !_obscured),
                  )
                : null,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey.shade300, width: 1),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey.shade300, width: 1),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(
                color: Color(0xFFFF7F1F),
                width: 1.5,
              ),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey.shade200, width: 1),
            ),
          ),
        ),
      ],
    );
  }
}

class _DropdownField extends StatelessWidget {
  const _DropdownField({
    required this.label,
    required this.items,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final List<String> items;
  final String value;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Color(0xFF666666),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade300, width: 1),
          ),
          child: DropdownButton<String>(
            value: value,
            isExpanded: true,
            underline: const SizedBox(),
            icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            style: const TextStyle(fontSize: 14, color: Color(0xFF1A1A1A)),
            items: items
                .map((i) => DropdownMenuItem(value: i, child: Text(i)))
                .toList(),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ],
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.selectedDate,
    required this.onDateSelected,
  });
  final String label;
  final DateTime? selectedDate;
  final ValueChanged<DateTime?> onDateSelected;

  @override
  Widget build(BuildContext context) {
    final dateText = selectedDate != null
        ? '${selectedDate!.day.toString().padLeft(2, '0')}/${selectedDate!.month.toString().padLeft(2, '0')}/${selectedDate!.year}'
        : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Color(0xFF666666),
          ),
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: () async {
            final date = await showDatePicker(
              context: context,
              initialDate: selectedDate ?? DateTime.now(),
              firstDate: DateTime(1950),
              lastDate: DateTime.now().add(const Duration(days: 365)),
              builder: (context, child) {
                return Theme(
                  data: Theme.of(context).copyWith(
                    colorScheme: const ColorScheme.light(
                      primary: Color(0xFFFF7F1F),
                      onPrimary: Colors.white,
                      surface: Colors.white,
                      onSurface: Color(0xFF1A1A1A),
                    ),
                  ),
                  child: child!,
                );
              },
            );
            if (date != null) {
              onDateSelected(date);
            }
          },
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300, width: 1),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    dateText.isEmpty ? 'Seleccionar fecha' : dateText,
                    style: TextStyle(
                      fontSize: 14,
                      color: dateText.isEmpty
                          ? Colors.grey.shade400
                          : const Color(0xFF1A1A1A),
                    ),
                  ),
                ),
                Icon(
                  Icons.calendar_today,
                  size: 18,
                  color: Colors.grey.shade600,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RoleCheckbox extends StatelessWidget {
  final String title;
  final String description;
  final bool isSelected;
  final ValueChanged<bool> onChanged;

  const _RoleCheckbox({
    required this.title,
    required this.description,
    required this.isSelected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!isSelected),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFFFF7F1F).withValues(alpha: 0.08)
              : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? const Color(0xFFFF7F1F) : Colors.grey.shade300,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Checkbox(
              value: isSelected,
              onChanged: (value) => onChanged(value ?? false),
              activeColor: const Color(0xFFFF7F1F),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: isSelected
                          ? const Color(0xFFFF7F1F)
                          : Colors.grey[900],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(color: Colors.grey[600], fontSize: 14),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
