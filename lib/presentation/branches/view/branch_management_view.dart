import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/services/session/session_controller.dart';

final branchManagementProvider =
    ChangeNotifierProvider<BranchManagementController>((ref) {
      return BranchManagementController();
    });

class BranchManagementController extends ChangeNotifier {
  final _client = Supabase.instance.client;

  bool _loading = false;
  bool _saving = false;
  String? _error;
  List<SessionBusiness> _branches = const [];

  bool get loading => _loading;
  bool get saving => _saving;
  String? get error => _error;
  List<SessionBusiness> get branches => _branches;

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final user = _client.auth.currentUser;
      if (user == null) throw Exception('Sesión no iniciada');

      final memberships = await _client
          .from('user_businesses')
          .select(
            'business_id, role, businesses!inner(id, business_name, branch_name, status)',
          )
          .eq('user_id', user.id)
          .order('created_at', ascending: true);

      _branches = (memberships as List)
          .map((row) {
            final business = row['businesses'] as Map<String, dynamic>? ?? const {};
            final branchName =
                (business['branch_name']?.toString().trim().isNotEmpty == true)
                ? business['branch_name'].toString().trim()
                : (business['business_name']?.toString().trim() ?? 'Sucursal');
            return SessionBusiness(
              id: row['business_id'].toString(),
              name: branchName,
              companyName: business['business_name']?.toString(),
              role: row['role']?.toString() ?? 'owner',
              status: business['status']?.toString(),
            );
          })
          .toList(growable: false);
      _error = null;
    } catch (e) {
      _error = 'No se pudieron cargar las sucursales: $e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> createBranch({
    required String companyName,
    required String branchName,
    String? address,
    String? phone,
    String? copyProductsFromBusinessId,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) throw Exception('Sesión no iniciada');

    _saving = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _client.rpc(
        'create_branch_business',
        params: {
          'p_business_name': companyName.trim(),
          'p_branch_name': branchName.trim(),
          'p_address': address?.trim(),
          'p_phone': phone?.trim(),
          'p_business_type': null,
          'p_country': null,
          'p_domain': null,
        },
      );

      // Copy products from source branch if requested
      if (copyProductsFromBusinessId != null) {
        final newBusinessId = (result as Map<String, dynamic>?)?['business_id']?.toString();
        if (newBusinessId != null && newBusinessId.isNotEmpty) {
          await _client.rpc(
            'fn_copy_products_to_branch',
            params: {
              'p_source_business_id': copyProductsFromBusinessId,
              'p_target_business_id': newBusinessId,
            },
          );
        }
      }

      await load();
    } catch (e) {
      _error = 'No se pudo crear la sucursal: $e';
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  Future<void> deleteBranch(String businessId) async {
    _saving = true;
    _error = null;
    notifyListeners();

    try {
      final response = await _client.rpc(
        'fn_delete_business',
        params: {'p_business_id': businessId},
      );

      final result = response as Map<String, dynamic>?;
      if (result?['success'] == false) {
        throw Exception(result?['error'] ?? 'Error al eliminar la sucursal');
      }

      await load();
    } catch (e) {
      _error = e.toString().replaceAll('Exception: ', '');
      rethrow;
    } finally {
      _saving = false;
      notifyListeners();
    }
  }
}

class BranchManagementView extends ConsumerStatefulWidget {
  const BranchManagementView({super.key});

  @override
  ConsumerState<BranchManagementView> createState() =>
      _BranchManagementViewState();
}

class _BranchManagementViewState extends ConsumerState<BranchManagementView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(branchManagementProvider).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(branchManagementProvider);
    final session = ref.watch(sessionProvider);
    final activeBranch = vm.branches.where((b) => b.id == session.activeBusinessId);
    final activeName = activeBranch.isNotEmpty
        ? activeBranch.first.name
        : (session.activeBusinessName ?? 'Sin sucursal activa');

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => ref.read(branchManagementProvider).load(),
          color: AppColors.primary,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            children: [
              _HeroCard(
                activeName: activeName,
                totalBranches: vm.branches.length,
                isSaving: vm.saving,
                onCreate: (vm.saving || !session.isOwner)
                    ? null
                    : () => _showCreateBranchDialog(context),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _StatCard(
                      title: 'Sucursal activa',
                      value: activeName,
                      icon: Icons.storefront_rounded,
                      accent: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _StatCard(
                      title: 'Sucursales registradas',
                      value: '${vm.branches.length}',
                      icon: Icons.apartment_rounded,
                      accent: AppColors.info,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _StatCard(
                      title: 'Modelo operativo',
                      value: 'Datos aislados',
                      icon: Icons.lock_outline_rounded,
                      accent: AppColors.success,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              if (vm.error != null) _ErrorBanner(message: vm.error!),
              const SizedBox(height: 18),
              const _SectionHeader(
                title: 'Sucursales disponibles',
                subtitle:
                    'Cada sucursal se maneja como un negocio independiente dentro del mismo panel administrativo.',
              ),
              const SizedBox(height: 14),
              if (vm.loading)
                const Padding(
                  padding: EdgeInsets.only(top: 60),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (vm.branches.isEmpty)
                const _EmptyBranchesState()
              else
                ...vm.branches.map((branch) {
                  final isActive = branch.id == session.activeBusinessId;
                  final canManage = session.isOwner;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: _BranchCard(
                      branch: branch,
                      isActive: isActive,
                      onSwitch: (isActive || !canManage)
                          ? null
                          : () async {
                              await ref
                                  .read(sessionProvider.notifier)
                                  .switchBusiness(branch.id);
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  behavior: SnackBarBehavior.floating,
                                  content: Text(
                                    'Ahora estás trabajando en ${branch.name}.',
                                  ),
                                ),
                              );
                            },
                      onDelete: (isActive || !canManage)
                          ? null
                          : () => _confirmDelete(context, branch),
                    ),
                  );
                }),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCreateBranchDialog(BuildContext context) async {
    final companyCtrl = TextEditingController();
    final branchCtrl = TextEditingController();
    final addressCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();

    final session = ref.read(sessionProvider);
    companyCtrl.text = session.availableBusinesses.isNotEmpty
        ? (session.availableBusinesses.first.companyName ?? '')
        : (session.activeBusinessName ?? '');

    bool copyProducts = false;
    String? copyFromBusinessId = session.activeBusinessId;

    final branches = session.availableBusinesses;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: Container(
                width: 560,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: AppColors.border),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 30,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [AppColors.primary, AppColors.primaryGradientEnd],
                          ),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: const Icon(
                          Icons.add_business_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        'Crear nueva sucursal',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: AppColors.foreground,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'La sucursal se crea con datos aislados. Puedes copiar los productos de una sucursal existente.',
                        style: TextStyle(
                          color: AppColors.mutedForeground,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 22),
                      _FormInput(
                        controller: companyCtrl,
                        label: 'Nombre del negocio',
                        hint: 'Ej. MangoPOS Restaurant Group',
                      ),
                      const SizedBox(height: 14),
                      _FormInput(
                        controller: branchCtrl,
                        label: 'Nombre de la sucursal',
                        hint: 'Ej. Piantini / Jardines / Santiago Centro',
                      ),
                      const SizedBox(height: 14),
                      _FormInput(
                        controller: addressCtrl,
                        label: 'Dirección',
                        hint: 'Opcional',
                      ),
                      const SizedBox(height: 14),
                      _FormInput(
                        controller: phoneCtrl,
                        label: 'Teléfono',
                        hint: 'Opcional',
                      ),
                      const SizedBox(height: 18),
                      // ── Copy products section ──
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: copyProducts
                              ? AppColors.primary.withValues(alpha: 0.06)
                              : AppColors.background,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: copyProducts
                                ? AppColors.primary.withValues(alpha: 0.3)
                                : AppColors.border,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Checkbox(
                                  value: copyProducts,
                                  activeColor: AppColors.primary,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  onChanged: (v) {
                                    setDialogState(() => copyProducts = v ?? false);
                                  },
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () {
                                      setDialogState(() => copyProducts = !copyProducts);
                                    },
                                    child: const Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Copiar productos de otra sucursal',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 14,
                                            color: AppColors.foreground,
                                          ),
                                        ),
                                        SizedBox(height: 2),
                                        Text(
                                          'Copia categorías, productos y menús. No copia ventas ni inventario.',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: AppColors.mutedForeground,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (copyProducts && branches.length > 1) ...[
                              const SizedBox(height: 12),
                              DropdownButtonFormField<String>(
                                value: copyFromBusinessId,
                                isExpanded: true,
                                decoration: InputDecoration(
                                  labelText: 'Copiar desde',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 12,
                                  ),
                                ),
                                items: branches.map((b) {
                                  final label = b.name.isNotEmpty
                                      ? b.name
                                      : (b.companyName ?? 'Sucursal');
                                  return DropdownMenuItem<String>(
                                    value: b.id,
                                    child: Text(label),
                                  );
                                }).toList(),
                                onChanged: (v) {
                                  setDialogState(() => copyFromBusinessId = v);
                                },
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(dialogContext).pop(),
                            child: const Text('Cancelar'),
                          ),
                          const SizedBox(width: 10),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 14,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            onPressed: () async {
                              if (companyCtrl.text.trim().isEmpty ||
                                  branchCtrl.text.trim().isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Completa negocio y sucursal.'),
                                  ),
                                );
                                return;
                              }
                              await ref.read(branchManagementProvider).createBranch(
                                    companyName: companyCtrl.text,
                                    branchName: branchCtrl.text,
                                    address: addressCtrl.text,
                                    phone: phoneCtrl.text,
                                    copyProductsFromBusinessId:
                                        copyProducts ? copyFromBusinessId : null,
                                  );
                              if (!context.mounted) return;
                              Navigator.of(dialogContext).pop();
                              if (copyProducts) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Sucursal creada con productos copiados exitosamente.',
                                    ),
                                    backgroundColor: Color(0xFF16A34A),
                                  ),
                                );
                              }
                            },
                            child: Text(
                              copyProducts
                                  ? 'Crear y copiar productos'
                                  : 'Crear sucursal',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _confirmDelete(BuildContext context, SessionBusiness branch) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Eliminar sucursal?'),
        content: Text(
          'Esta acción es irreversible y eliminará todos los datos asociados a "${branch.name}" (ventas, productos, clientes, etc.).\n\n¿Estás seguro?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.destructive),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar definitivamente'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await ref.read(branchManagementProvider).deleteBranch(branch.id);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sucursal "${branch.name}" eliminada.')),
        );
      } catch (e) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.activeName,
    required this.totalBranches,
    required this.isSaving,
    required this.onCreate,
  });

  final String activeName;
  final int totalBranches;
  final bool isSaving;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFF97316), Color(0xFFFBAA16)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26F97316),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'MULTISUCURSAL',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Administra varias sucursales desde el mismo panel.',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Sucursal activa: $activeName · $totalBranches registradas',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.88),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: AppColors.primary,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: onCreate,
            icon: isSaving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_business_rounded),
            label: Text(isSaving ? 'Creando...' : 'Nueva sucursal'),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.accent,
  });

  final String title;
  final String value;
  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: AppColors.foreground,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: const TextStyle(
            color: AppColors.mutedForeground,
            fontSize: 14,
          ),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF1F2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFDA4AF)),
      ),
      child: Text(
        message,
        style: const TextStyle(color: Color(0xFFBE123C)),
      ),
    );
  }
}

class _BranchCard extends StatelessWidget {
  const _BranchCard({
    required this.branch,
    required this.isActive,
    required this.onSwitch,
    this.onDelete,
  });

  final SessionBusiness branch;
  final bool isActive;
  final VoidCallback? onSwitch;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final accent = isActive ? AppColors.primary : AppColors.info;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isActive ? AppColors.primaryBorder : AppColors.border,
          width: isActive ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(
              isActive ? Icons.radio_button_checked_rounded : Icons.storefront_rounded,
              color: accent,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        branch.name,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: AppColors.foreground,
                        ),
                      ),
                    ),
                    if (isActive)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.successBg,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          'Activa',
                          style: TextStyle(
                            color: AppColors.success,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  branch.companyName ?? 'Negocio',
                  style: const TextStyle(
                    color: AppColors.mutedForeground,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _MetaPill(
                      icon: Icons.badge_outlined,
                      text: branch.roleLabel,
                    ),
                    _MetaPill(
                      icon: Icons.verified_outlined,
                      text: (branch.status ?? 'active') == 'active'
                          ? 'Operativa'
                          : (branch.status ?? 'inactiva'),
                    ),
                    _MetaPill(
                      icon: Icons.lock_outline_rounded,
                      text: 'Datos separados',
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 18),
          isActive
              ? Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primaryBg,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Text(
                    'En uso',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              : OutlinedButton.icon(
                  onPressed: onSwitch,
                  icon: const Icon(Icons.swap_horiz_rounded),
                  label: const Text('Cambiar'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.foreground,
                    side: const BorderSide(color: AppColors.border),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
          if (onDelete != null) ...[
            const SizedBox(width: 8),
            IconButton(
              onPressed: onDelete,
              icon: const Icon(
                Icons.delete_outline_rounded,
                color: AppColors.destructive,
              ),
              tooltip: 'Eliminar sucursal',
            ),
          ],
        ],
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.secondary,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: AppColors.mutedForeground),
          const SizedBox(width: 7),
          Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.foreground,
            ),
          ),
        ],
      ),
    );
  }
}

class _FormInput extends StatelessWidget {
  const _FormInput({
    required this.controller,
    required this.label,
    required this.hint,
  });

  final TextEditingController controller;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.foreground,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: AppColors.accent,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: AppColors.primary, width: 1.4),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyBranchesState extends StatelessWidget {
  const _EmptyBranchesState();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(36),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.border),
      ),
      child: const Column(
        children: [
          Icon(
            Icons.apartment_rounded,
            size: 58,
            color: AppColors.mutedForeground,
          ),
          SizedBox(height: 14),
          Text(
            'Todavía no tienes sucursales adicionales.',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: AppColors.foreground,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Crea una nueva sucursal y luego podrás cambiar entre negocios desde el dropdown del usuario.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.mutedForeground,
              fontSize: 14,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}
