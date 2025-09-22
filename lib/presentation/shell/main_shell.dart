import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../app/widgets/sidebar/admin_sidebar.dart';
import '../../app/theme/mango_colors.dart';

class MainShell extends StatelessWidget {
  final Widget child;
  const MainShell({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 900;

    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F2),
      body: Column(
        children: [
          // ======= APP BAR =======
          Container(
            height: 80,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              color: MangoColors.white,
              boxShadow: [
                BoxShadow(
                  color: Color(0x1A000000),
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: const Row(children: [_Logo(), Spacer(), _UserInfo()]),
          ),

          // ======= CONTENIDO =======
          Expanded(
            child: Row(
              children: [
                const AdminSidebar(width: 96),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.all(isWide ? 16 : 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Container(color: MangoColors.white, child: child),
                    ),
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

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/logo.png',
      height: 200,
      fit: BoxFit.contain,
    );
  }
}

class _UserInfo extends StatelessWidget {
  const _UserInfo();

  Future<_UserData> _loadUserInfo() async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;

    if (user == null) {
      return const _UserData(
        fullName: 'Invitado',
        uid: '—',
        businessId: '—',
        role: 'guest',
        permissions: <String>[],
      );
    }

    // Nombre SOLO desde profiles
    String fullName = 'Usuario';
    try {
      final profile = await supabase
          .from('profiles')
          .select('full_name')
          .eq('id', user.id)
          .maybeSingle();

      final pName = profile?['full_name']?.toString().trim();
      if (pName != null && pName.isNotEmpty) {
        fullName = pName;
      }
    } catch (_) {}

    // Relación user -> negocio
    String businessId = '—';
    String role = 'user';
    List<dynamic> rawPerms = const [];
    try {
      final ub = await supabase
          .from('user_businesses')
          .select('business_id, role, permissions')
          .eq('user_id', user.id)
          .order('created_at', ascending: true)
          .limit(1)
          .maybeSingle();

      if (ub != null) {
        if (ub['business_id'] != null) {
          businessId = ub['business_id'].toString();
        }
        if (ub['role'] != null) role = ub['role'].toString().toLowerCase();
        if (ub['permissions'] != null) rawPerms = (ub['permissions'] as List);
      }
    } catch (_) {}

    final permissions = rawPerms
        .map((e) => e.toString())
        .toList(growable: false);

    return _UserData(
      fullName: fullName,
      uid: user.id,
      businessId: businessId,
      role: role,
      permissions: permissions,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_UserData>(
      future: _loadUserInfo(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 8),
              Text('Cargando...'),
            ],
          );
        }

        if (snap.hasError || snap.data == null) {
          return const Text(
            'Error al cargar usuario',
            style: TextStyle(color: Colors.red),
          );
        }

        final info = snap.data!;
        final initials = _initialsFromFullName(info.fullName);

        return Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Nombre
                Text(
                  info.fullName,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: MangoColors.darkGray,
                  ),
                ),
                const SizedBox(height: 4),

                // ✅ Label de Rol (en verde si es admin/owner)
                if (info.role == 'admin' || info.role == 'owner')
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: MangoColors.successGreen,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Administrador',
                      style: TextStyle(
                        color: MangoColors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),

            // Avatar
            CircleAvatar(
              radius: 20,
              backgroundColor: MangoColors.primaryOrange.withOpacity(0.12),
              child: Text(
                initials,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: MangoColors.primaryOrange,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  String _initialsFromFullName(String fullName) {
    final parts = fullName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return 'U';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}

class _UserData {
  final String fullName;
  final String uid;
  final String businessId;
  final String role;
  final List<String> permissions;

  const _UserData({
    required this.fullName,
    required this.uid,
    required this.businessId,
    required this.role,
    required this.permissions,
  });
}
