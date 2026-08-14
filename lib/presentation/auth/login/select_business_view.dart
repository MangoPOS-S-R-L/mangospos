import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../app/router/routes.dart';
import '../../../core/theme/app_breakpoints.dart';
import '../../../core/utils/logger.dart';
import '../../../core/business/business_resolver.dart';
import '../../../core/network/supabase_config.dart';
import '../../../core/storage/storage_service.dart';
import '../../../services/session/session_controller.dart';
import '../../../core/theme/app_colors.dart';

class SelectBusinessView extends ConsumerStatefulWidget {
  const SelectBusinessView({super.key});

  @override
  ConsumerState<SelectBusinessView> createState() => _SelectBusinessViewState();
}

class _SelectBusinessViewState extends ConsumerState<SelectBusinessView> {
  bool _isLoading = true;
  bool _isSelecting = false;
  String? _selectingBusinessId;
  String? _error;
  List<Map<String, dynamic>> _businesses = [];

  static const _loadingMessages = <String>[
    'Validando tu acceso...',
    'Buscando tus negocios...',
    'Preparando tu espacio de trabajo...',
  ];

  @override
  void initState() {
    super.initState();
    _loadBusinesses();
  }

  Future<void> _loadBusinesses() async {
    debugPrint('>>> [SelectBusiness] _loadBusinesses start');
    final supabase = Supabase.instance.client;

    try {
      final user = supabase.auth.currentUser;
      debugPrint('>>> [SelectBusiness] currentUser=${user?.id}');

      if (user == null) {
        debugPrint('>>> [SelectBusiness] no user, redirect to /login');
        if (mounted) context.go('/login');
        return;
      }

      debugPrint('>>> [SelectBusiness] querying user_businesses...');
      final res = await supabase
          .from('user_businesses')
          .select(
            'business_id, role, businesses(business_name, branch_name, domain)',
          )
          .eq('user_id', user.id)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw TimeoutException(
                'user_businesses query timed out after 10s',
              );
            },
          );
      debugPrint('>>> [SelectBusiness] query done, result type=${res.runtimeType}');

      final list = res as List<dynamic>;
      debugPrint('>>> [SelectBusiness] list.length=${list.length}');
      if (list.isEmpty) {
        // user_businesses puede venir vacío aunque el dueño SÍ tenga un
        // negocio: el trigger que enlaza al owner pudo no haberse reflejado
        // todavía (lag justo tras el registro) o la fila quedó huérfana.
        // Antes de mostrar el callejón sin salida "no tienes negocios",
        // buscamos directamente un negocio cuyo owner_id sea este usuario
        // (la RLS businesses_owner_select lo permite). Si existe, entramos:
        // el PendingApprovalGuard mostrará la pantalla "en revisión" cuando
        // el status sea 'pending', en vez de dejar al dueño atascado aquí.
        final owned = await supabase
            .from('businesses')
            .select('id, business_name, branch_name, domain')
            .eq('owner_id', user.id)
            .order('created_at')
            .limit(1)
            .maybeSingle();

        if (owned != null && owned['id'] != null) {
          AppLogger.i(
            '[SelectBusiness] user_businesses vacío; negocio propio '
            '${owned['id']} encontrado por owner_id. Entrando '
            '(el guard mostrará "en revisión" si está pending).',
          );
          await _handleSelect(<String, dynamic>{
            'business_id': owned['id'],
            'role': 'owner',
            'businesses': {
              'business_name': owned['business_name'],
              'branch_name': owned['branch_name'],
              'domain': owned['domain'],
            },
          });
          return;
        }

        setState(() {
          _error = 'No tienes negocios asociados todavía.';
          _isLoading = false;
        });
        return;
      }

      // Solo los OWNERS con múltiples negocios ven el selector. Para todos los
      // demás casos auto-seleccionamos:
      //   - 1 solo negocio (cualquier rol) → directo
      //   - empleado (cashier/waiter/cook/etc.) con múltiples negocios →
      //     directo al primero. Un empleado no debería tener que "elegir"
      //     dónde entrar; va a su sucursal asignada.
      //
      // Si hay un negocio activo previo en storage, lo preferimos por sobre
      // "el primero" para que el empleado caiga en la sucursal donde estaba
      // operando la última vez.
      final isOwnerOfAny = list.any((row) {
        final role = (row as Map<String, dynamic>?)?['role']?.toString();
        return role == 'owner';
      });

      if (list.length == 1 || !isOwnerOfAny) {
        Map<String, dynamic>? target;

        // Preferir el negocio activo previo si sigue en la lista del usuario.
        try {
          final storage = await StorageService.getInstance();
          final stored = await storage.read(StorageKeys.activeBusinessId);
          if (stored != null && stored.isNotEmpty) {
            for (final row in list) {
              final map = row as Map<String, dynamic>;
              if (map['business_id']?.toString() == stored) {
                target = map;
                break;
              }
            }
          }
        } catch (_) {/* storage no crítico */}

        target ??= list.first as Map<String, dynamic>;
        final businessId = target['business_id'] as String?;
        if (businessId != null) {
          AppLogger.i(
            '[SelectBusiness] Auto-seleccionando $businessId '
            '(isOwnerOfAny=$isOwnerOfAny, total=${list.length})',
          );
          await _handleSelect(target);
          return;
        }
      }

      // Owner con múltiples negocios → mostrar el selector
      if (mounted) {
        setState(() {
          _businesses = list.cast<Map<String, dynamic>>();
          _isLoading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (SupabaseConfig.isAuthRefreshSchemaMismatchError(e)) {
        AppLogger.w(
          'La sesion expiro y el backend auth no pudo renovarla. Regresando al login.',
          error: e,
        );

        await supabase.auth.signOut(scope: SignOutScope.local);
        if (mounted) context.go(AppRoutes.login);
        return;
      }

      if (mounted) {
        setState(() {
          _error = SupabaseConfig.isTlsCertificateError(e)
              ? SupabaseConfig.getFriendlyErrorMessage(e)
              : 'No pudimos cargar tus accesos.';
          _isLoading = false;
        });
      }
      AppLogger.w('Error cargando negocios: $e');
    }
  }

  /// Cierra la sesión Supabase y vuelve al login. Útil cuando el usuario
  /// quedó bloqueado en esta pantalla — cuenta huérfana, business pending,
  /// o entró con un correo equivocado — y necesita salir sin matar la app.
  Future<void> _handleSignOut() async {
    try {
      await Supabase.instance.client.auth.signOut(
        scope: SignOutScope.local,
      );
    } catch (e) {
      AppLogger.w('Error cerrando sesión desde select_business: $e');
    }
    if (mounted) context.go(AppRoutes.login);
  }

  Future<void> _handleSelect(Map<String, dynamic> item) async {
    final businessId = item['business_id'] as String?;
    if (businessId == null) return;

    if (mounted) {
      setState(() {
        _isSelecting = true;
        _selectingBusinessId = businessId;
      });
    }

    debugPrint('>>> [SelectBusiness] _handleSelect start businessId=$businessId');

    try {
      debugPrint('>>> [SelectBusiness] writing storage');
      final storage = await StorageService.getInstance();
      await storage.write(StorageKeys.activeBusinessId, businessId);
      debugPrint('>>> [SelectBusiness] storage written');

      BusinessResolver.setActiveBusinessId(businessId);
      debugPrint('>>> [SelectBusiness] BusinessResolver set');

      final notifier = ref.read(sessionProvider.notifier);
      final state = ref.read(sessionProvider);
      final currentBusinessId = state.activeBusinessId;
      final hasAvailable = state.availableBusinesses.isNotEmpty;
      final isDifferentBusiness =
          currentBusinessId != null && currentBusinessId != businessId;

      // switchBusiness solo cuando realmente estamos CAMBIANDO de negocio
      // (multi-business owner que toca otra sucursal). Para el primer
      // login o un re-select del mismo negocio, basta con setActiveBusiness
      // simple — restoreFromSupabaseSession ya cargó el rol y permisos en
      // paralelo y switchBusiness duplica queries que pueden colgarse.
      if (hasAvailable && isDifferentBusiness) {
        debugPrint('>>> [SelectBusiness] calling switchBusiness (changing biz)');
        await notifier.switchBusiness(businessId).timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            debugPrint('>>> [SelectBusiness] switchBusiness TIMEOUT');
            // Fallback: al menos cambiamos el id para no quedar atorados.
            notifier.setActiveBusiness(businessId);
          },
        );
        debugPrint('>>> [SelectBusiness] switchBusiness done');
      } else {
        debugPrint('>>> [SelectBusiness] simple setActiveBusiness');
        notifier.setActiveBusiness(businessId);
        // Si la sesión aún no tiene rol cargado, esperamos brevemente a
        // que restoreFromSupabaseSession termine. Sin esto, homeRoute
        // devuelve '/dashboard' por null y el route guard puede patear.
        var waited = 0;
        while (mounted &&
            ref.read(sessionProvider).activeRole == null &&
            waited < 3000) {
          await Future.delayed(const Duration(milliseconds: 100));
          waited += 100;
        }
        debugPrint('>>> [SelectBusiness] waited ${waited}ms for activeRole');
      }

      if (!mounted) return;
      final home = notifier.homeRoute;
      debugPrint('>>> [SelectBusiness] navigating to $home');
      context.go(home);
    } catch (e, st) {
      debugPrint('>>> [SelectBusiness][WARN] error seleccionando: $e\n$st');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isSelecting = false;
          _selectingBusinessId = null;
          _error = 'No pudimos entrar a ese negocio. Intenta otra vez.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCompact = ResponsiveHelper.useCompactShell(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: SingleChildScrollView(
          padding: isCompact
              ? const EdgeInsets.symmetric(horizontal: 16, vertical: 20)
              : const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Logo / Branding — en móvil mostramos solo este (sin duplicar
              // dentro del card) y más compacto.
              Center(
                child: Image.asset(
                  'assets/images/Logo Completo.png',
                  height: isCompact ? 52 : 75,
                  fit: BoxFit.contain,
                ),
              ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.2),

              SizedBox(height: isCompact ? 16 : 24),

              // Header Animado
              Container(
                    constraints: const BoxConstraints(maxWidth: 520),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(isCompact ? 18 : 24),
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
                          padding: EdgeInsets.all(isCompact ? 16 : 24),
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: Color(0xFFF1F5F9)),
                            ),
                          ),
                          child: Row(
                            children: [
                              if (!isCompact) ...[
                                Image.asset(
                                  'assets/images/Logo Completo.png',
                                  height: 30,
                                  fit: BoxFit.contain,
                                ),
                                const SizedBox(width: 12),
                              ],
                              Text(
                                'Selecciona tu negocio',
                                style: TextStyle(
                                  fontSize: isCompact ? 15 : 16,
                                  fontWeight: FontWeight.w700,
                                  color: const Color(0xFF0F172A),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.all(isCompact ? 16 : 32),
                          child: _buildContent(isCompact),
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

  Widget _buildContent(bool isCompact) {
    if (_isLoading) {
      return const _BusinessLoadingState().animate().fadeIn();
    }

    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
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
                    style:
                        const TextStyle(color: Color(0xFFEF4444), fontSize: 14),
                  ),
                ),
              ],
            ),
          ).animate().fadeIn().shakeX(amount: 5),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                setState(() {
                  _error = null;
                  _isLoading = true;
                });
                _loadBusinesses();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFEF4444),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Salida del estado bloqueado: si la cuenta no tiene negocios
          // asociados (huérfana, pending, o el usuario entró con otra
          // cuenta por error), permitir cerrar sesión y volver al login
          // sin tener que matar la app.
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              onPressed: _handleSignOut,
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('Cerrar sesión'),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF64748B),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      );
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
        final businessId = item['business_id']?.toString();
        final isCurrentSelection =
            _isSelecting && _selectingBusinessId == businessId;

        final branchName = biz['branch_name']?.toString() ?? '';
        final businessName =
            biz['business_name']?.toString() ??
            biz['name']?.toString() ??
            'Negocio Desconocido';
        final domain = biz['domain']?.toString() ?? '';
        final role = item['role']?.toString().toUpperCase() ?? 'OWNER';

        final avatarSize = isCompact ? 40.0 : 48.0;
        final itemPadding = isCompact
            ? const EdgeInsets.all(14)
            : const EdgeInsets.all(20);
        final titleSize = isCompact ? 14.0 : 16.0;
        final subtitleSize = isCompact ? 11.5 : 13.0;
        final gapAfterAvatar = isCompact ? 12.0 : 16.0;
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _isSelecting ? null : () => _handleSelect(item),
              borderRadius: BorderRadius.circular(16),
              hoverColor: const Color(0xFFF97316).withValues(alpha: 0.04),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                padding: itemPadding,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isCurrentSelection
                        ? const Color(0xFFF97316)
                        : const Color(0xFFE2E8F0),
                    width: isCurrentSelection ? 1.8 : 1,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  color: isCurrentSelection
                      ? const Color(0xFFFFF7ED)
                      : Colors.white,
                  boxShadow: isCurrentSelection
                      ? const [
                          BoxShadow(
                            color: Color(0x14F97316),
                            blurRadius: 18,
                            offset: Offset(0, 8),
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      width: avatarSize,
                      height: avatarSize,
                      decoration: BoxDecoration(
                        color: isCurrentSelection
                            ? const Color(0xFFF97316)
                            : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
                        child: Text(
                          businessName.isNotEmpty
                              ? businessName.substring(0, 1).toUpperCase()
                              : 'B',
                          style: TextStyle(
                            fontSize: isCompact ? 16 : 18,
                            fontWeight: FontWeight.bold,
                            color: isCurrentSelection
                                ? Colors.white
                                : const Color(0xFF334155),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: gapAfterAvatar),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  branchName.isNotEmpty
                                      ? '$businessName - $branchName'
                                      : businessName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: titleSize,
                                    fontWeight: FontWeight.w700,
                                    height: 1.2,
                                    color: const Color(0xFF0F172A),
                                  ),
                                ),
                              ),
                              if (!isCompact) ...[
                                const SizedBox(width: 8),
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 260),
                                  curve: Curves.easeOutCubic,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isCurrentSelection
                                        ? const Color(0xFFFED7AA)
                                        : const Color(0xFFF1F5F9),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    role,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: isCurrentSelection
                                          ? const Color(0xFF9A3412)
                                          : const Color(0xFF475569),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              if (isCompact)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isCurrentSelection
                                          ? const Color(0xFFFED7AA)
                                          : const Color(0xFFF1F5F9),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      role,
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.4,
                                        color: isCurrentSelection
                                            ? const Color(0xFF9A3412)
                                            : const Color(0xFF475569),
                                      ),
                                    ),
                                  ),
                                ),
                              Expanded(
                                child: Text(
                                  domain,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: subtitleSize,
                                    color: const Color(0xFF64748B),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: isCurrentSelection
                          ? const SizedBox(
                              key: ValueKey('loading-business'),
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Color(0xFFF97316),
                              ),
                            )
                          : const Icon(
                              Icons.chevron_right_rounded,
                              key: ValueKey('chevron-business'),
                              color: Color(0xFF94A3B8),
                            ),
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

class _BusinessLoadingState extends StatefulWidget {
  const _BusinessLoadingState();

  @override
  State<_BusinessLoadingState> createState() => _BusinessLoadingStateState();
}

class _BusinessLoadingStateState extends State<_BusinessLoadingState>
    with SingleTickerProviderStateMixin {
  int _messageIndex = 0;
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 1400),
          )
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) {
              _controller.forward(from: 0);
              if (!mounted) return;
              setState(() {
                _messageIndex =
                    (_messageIndex + 1) %
                    _SelectBusinessViewState._loadingMessages.length;
              });
            }
          })
          ..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          const SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(
              color: Color(0xFFF97316),
              strokeWidth: 3,
            ),
          ),
          const SizedBox(height: 18),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.18),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: Text(
              _SelectBusinessViewState._loadingMessages[_messageIndex],
              key: ValueKey(_messageIndex),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF64748B)),
            ),
          ),
        ],
      ),
    );
  }
}
