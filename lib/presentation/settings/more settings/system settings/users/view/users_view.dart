import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/repositories/employee_repository.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SettingsUsersView extends StatefulWidget {
  final String businessId;
  const SettingsUsersView({super.key, required this.businessId});

  @override
  State<SettingsUsersView> createState() => _SettingsUsersViewState();
}

class _SettingsUsersViewState extends State<SettingsUsersView> {
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

    return Scaffold(
      backgroundColor: const Color(0xFFFAF8F6),
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.4,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go(AppRoutes.settings),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Gestión de Usuarios',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            Text(
              'Administra los usuarios del sistema y sus permisos',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
          ],
        ),
        actions: [
          OutlinedButton.icon(
            onPressed: () => context.go(AppRoutes.settingsRoles),
            icon: const Icon(Icons.shield_outlined),
            label: const Text('Gestionar Roles'),
            style: OutlinedButton.styleFrom(
              foregroundColor: MangoColors.darkGray,
              side: BorderSide(color: Colors.grey.shade300),
            ),
          ),
          const SizedBox(width: 8),
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
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  _KpiRow(users: _employees),
                  const SizedBox(height: 18),
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
                              onEdit: () => _openUserDialog(context, user: u),
                              onDelete: () => _deleteUser(u),
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
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UserDialog(
        user: user,
        businessId: _businessId ?? widget.businessId,
        repo: _repo,
        availableRoles: _availableRoles,
      ),
    );
    if (result == true) {
      _load();
    }
  }
}

class _KpiRow extends StatelessWidget {
  const _KpiRow({required this.users});
  final List<Employee> users;

  @override
  Widget build(BuildContext context) {
    final total = users.length;
    final active = users.where((u) => u.status == 'active').length;
    final inactive = users.where((u) => u.status == 'inactive').length;
    final reset = users.where((u) => u.status == 'password_reset').length;
    return Row(
      children: [
        Expanded(
          child: _KpiCard(
            title: 'Total Usuarios',
            value: '$total',
            icon: Icons.groups,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _KpiCard(
            title: 'Activos',
            value: '$active',
            icon: Icons.verified_user,
            accent: Colors.green,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _KpiCard(
            title: 'Inactivos',
            value: '$inactive',
            icon: Icons.person_off,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _KpiCard(
            title: 'Cambio de Clave',
            value: '$reset',
            icon: Icons.vpn_key,
          ),
        ),
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
  });
  final String title;
  final String value;
  final IconData icon;
  final Color? accent;

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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: color.withOpacity(0.12),
              foregroundColor: color,
              child: Icon(icon),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
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
            color: Colors.black.withOpacity(0.04),
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
                  _showPermissionsDialog(context, user);
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
                    const Text('Ver Permisos'),
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
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Resetear Contraseña'),
        content: Text('¿Deseas resetear la contraseña de ${user.fullName}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () {
              // TODO: Implementar reset de contraseña
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Contraseña reseteada')),
              );
            },
            child: const Text('Resetear'),
          ),
        ],
      ),
    );
  }

  void _showPermissionsDialog(BuildContext context, Employee user) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Permisos de ${user.fullName}'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Roles: ${user.roles.join(", ")}'),
              const SizedBox(height: 16),
              const Text('Permisos activos:'),
              const SizedBox(height: 8),
              // TODO: Cargar permisos desde el backend
              const Text('- Cargando permisos...'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
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
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
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
  });
  final Employee? user;
  final String businessId;
  final EmployeeRepository repo;
  final List<Map<String, dynamic>> availableRoles;

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

  @override
  void initState() {
    super.initState();
    if (widget.user != null) {
      _loadUserData(widget.user!);
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
      } catch (_) {
        // Rol no encontrado en la configuración actual o borrado
      }
    }

    // TODO: Cargar AFP y ARS cuando estén disponibles en el modelo
  }

  Future<void> _onSubmit(BuildContext context) async {
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
          // No actualizamos PIN/Password aquí por seguridad
        );

        // Actualizar roles
        await widget.repo.updateEmployeeRoles(
          employeeId: widget.user!.id,
          roleIds: roleIds,
        );

        if (mounted) {
          Navigator.pop(context, true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Usuario actualizado correctamente.')),
          );
        }
      } else {
        // CREAR NUEVO USUARIO
        await widget.repo.createEmployee(
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
          pin: _pin.text.isNotEmpty ? _pin.text.trim() : null,
          password: _password.text.isNotEmpty ? _password.text.trim() : null,
          roleIds: roleIds,
        );

        if (mounted) {
          Navigator.pop(context, true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Usuario creado correctamente.')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error al guardar: $e')));
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
                              _onSubmit(context);
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
                    label: 'Contraseña *',
                    controller: _password,
                    hint: widget.user == null
                        ? 'Mínimo 6 caracteres'
                        : 'Bloqueado por seguridad',
                    enabled: widget.user == null,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _LabeledField(
                    label: 'PIN (4-6 dígitos)',
                    controller: _pin,
                    hint: widget.user == null
                        ? 'Ej: 1234'
                        : 'Bloqueado por seguridad',
                    keyboardType: TextInputType.number,
                    enabled: widget.user == null,
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
        return Column(
          key: const ValueKey(3),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Text(
              'Selecciona los roles para este usuario',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[600],
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 16),
            if (widget.availableRoles.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('No hay roles disponibles configurados.'),
                ),
              )
            else
              ...widget.availableRoles.map((role) {
                final id = role['id'] as String;
                final name = role['name'] as String;
                final desc = role['description'] as String?;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _RoleCheckbox(
                    title: name,
                    description: desc ?? '',
                    isSelected: _selectedRoles.contains(id),
                    onChanged: (selected) {
                      setState(() {
                        if (selected) {
                          _selectedRoles.add(id);
                        } else {
                          _selectedRoles.remove(id);
                        }
                      });
                    },
                  ),
                );
              }),
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

class _LabeledField extends StatelessWidget {
  const _LabeledField({
    required this.label,
    this.hint,
    this.controller,
    this.enabled = true,
    this.keyboardType,
  });
  final String label;
  final String? hint;
  final TextEditingController? controller;
  final bool enabled;
  final TextInputType? keyboardType;
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
        TextField(
          controller: controller,
          enabled: enabled,
          keyboardType: keyboardType,
          style: const TextStyle(fontSize: 14, color: Color(0xFF1A1A1A)),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(fontSize: 14, color: Colors.grey.shade400),
            filled: true,
            fillColor: enabled ? Colors.white : const Color(0xFFF9F9F9),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
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
              ? const Color(0xFFFF7F1F).withOpacity(0.08)
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
