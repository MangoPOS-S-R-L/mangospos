import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../core/utils/logger.dart';
import '../../../core/business/business_resolver.dart';
import '../../../core/storage/storage_service.dart';
import '../../../services/session/session_controller.dart';

class SelectBusinessView extends ConsumerStatefulWidget {
  const SelectBusinessView({super.key});

  @override
  ConsumerState<SelectBusinessView> createState() => _SelectBusinessViewState();
}

class _SelectBusinessViewState extends ConsumerState<SelectBusinessView> {
  bool _isLoading = true;
  String? _error;
  List<Map<String, dynamic>> _businesses = [];

  @override
  void initState() {
    super.initState();
    _loadBusinesses();
  }

  Future<void> _loadBusinesses() async {
    try {
      final supabase = Supabase.instance.client;
      final user = supabase.auth.currentUser;

      if (user == null) {
        if (mounted) context.go('/login');
        return;
      }

      final res = await supabase
          .from('user_businesses')
          .select(
            'business_id, role, businesses(business_name, branch_name, domain)',
          )
          .eq('user_id', user.id);

      final list = res as List<dynamic>;
      if (list.isEmpty) {
        setState(() {
          _error = 'No tienes negocios asociados todavía.';
          _isLoading = false;
        });
        return;
      }

      // Si solo tiene 1 negocio → selección automática interna
      if (list.length == 1) {
        final item = list.first as Map<String, dynamic>;
        final businessId = item['business_id'] as String?;
        if (businessId != null) {
          AppLogger.i(
            '[SelectBusiness] Un solo negocio, seleccionando $businessId',
          );
          await _handleSelect(item);
          return;
        }
      }

      // Múltiples negocios → mostrar el selector
      if (mounted) {
        setState(() {
          _businesses = list.cast<Map<String, dynamic>>();
          _isLoading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'No pudimos cargar tus accesos.';
          _isLoading = false;
        });
      }
      AppLogger.w('Error cargando negocios: $e');
    }
  }

  Future<void> _handleSelect(Map<String, dynamic> item) async {
    final businessId = item['business_id'] as String?;
    if (businessId == null) return;

    AppLogger.i('Negocio seleccionado internamente: $businessId');

    final storage = await StorageService.getInstance();
    await storage.write(StorageKeys.activeBusinessId, businessId);
    BusinessResolver.setActiveBusinessId(businessId);
    ref.read(sessionProvider.notifier).setActiveBusiness(businessId);

    if (mounted) {
      context.go('/dashboard');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFA),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Logo Oculto / Branding
              const Center(
                child: Icon(
                  Icons.storefront_rounded,
                  size: 48,
                  color: Color(0xFFF97316), // Naranja MangosPOS
                ),
              ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.2),

              const SizedBox(height: 24),

              // Header Animado
              Container(
                    constraints: const BoxConstraints(maxWidth: 520),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x0A000000),
                          blurRadius: 20,
                          offset: Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(24),
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: Color(0xFFF1F5F9)),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF97316),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Center(
                                  child: Text(
                                    'M',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              const Text(
                                'Selecciona tu negocio',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: _buildContent(),
                        ),
                      ],
                    ),
                  )
                  .animate()
                  .fadeIn(duration: 500.ms)
                  .slideY(begin: 0.1, delay: 100.ms),
            ],
          ), // Cascade effect removed as children are individually animated
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Column(
          children: [
            CircularProgressIndicator(color: Color(0xFFF97316)),
            SizedBox(height: 16),
            Text(
              'Cargando tus accesos...',
              style: TextStyle(color: Color(0xFF64748B)),
            ),
          ],
        ),
      ).animate().fadeIn();
    }

    if (_error != null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF2F2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFFFCA5A5).withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              color: Color(0xFFEF4444),
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _error!,
                style: const TextStyle(color: Color(0xFFEF4444), fontSize: 14),
              ),
            ),
          ],
        ),
      ).animate().fadeIn().shakeX(amount: 5);
    }

    if (_businesses.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, color: Color(0xFF64748B), size: 20),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'No tienes negocios asociados todavía.',
                style: TextStyle(color: Color(0xFF64748B), fontSize: 14),
              ),
            ),
          ],
        ),
      ).animate().fadeIn();
    }

    return Column(
      children: _businesses.asMap().entries.map((entry) {
        final i = entry.key;
        final item = entry.value;
        final biz = item['businesses'] ?? {};

        final branchName = biz['branch_name']?.toString() ?? '';
        final businessName =
            biz['business_name']?.toString() ??
            biz['name']?.toString() ??
            'Negocio Desconocido';
        final domain = biz['domain']?.toString() ?? '';
        final role = item['role']?.toString().toUpperCase() ?? 'OWNER';

        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _handleSelect(item),
              borderRadius: BorderRadius.circular(16),
              hoverColor: const Color(0xFFF97316).withValues(alpha: 0.04),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                  borderRadius: BorderRadius.circular(16),
                  color: Colors.white,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
                        child: Text(
                          businessName.isNotEmpty
                              ? businessName.substring(0, 1).toUpperCase()
                              : 'B',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF334155),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            branchName.isNotEmpty
                                ? '$businessName - $branchName'
                                : businessName,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            domain,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        role,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF475569),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: Color(0xFF94A3B8),
                    ),
                  ],
                ),
              ),
            ),
          ).animate().fadeIn(delay: (100 * i).ms).slideX(begin: 0.1),
        );
      }).toList(),
    );
  }
}
