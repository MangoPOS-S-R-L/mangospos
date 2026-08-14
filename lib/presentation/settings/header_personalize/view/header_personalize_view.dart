// Ajustes → Personalizar Header.
//
// Permite al owner/admin elegir qué destinos del shell (topbar desktop /
// drawer móvil) se muestran a TODOS los empleados del business. Los
// destinos ocultados se guardan en `business_settings.header_destinations_disabled`
// (array de routes). El shell combina esta lista con los permisos por
// rol — un destino se muestra solo si el rol del empleado lo permite
// Y no está en esta lista.
//
// Reglas de UI:
//   - Owner/admin que entra aquí ve TODOS los destinos del catálogo,
//     incluso los que su rol no usaría normalmente.
//   - Switch ON = visible; OFF = oculto para todos los empleados.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/presentation/shell/shell_destinations.dart';
import 'package:mangopos/services/session/session_controller.dart';
import '../../../../core/theme/app_colors.dart';

class HeaderPersonalizeView extends ConsumerStatefulWidget {
  const HeaderPersonalizeView({super.key});

  @override
  ConsumerState<HeaderPersonalizeView> createState() =>
      _HeaderPersonalizeViewState();
}

class _HeaderPersonalizeViewState extends ConsumerState<HeaderPersonalizeView> {
  Set<String> _disabled = <String>{};
  bool _loading = true;
  bool _saving = false;
  String? _error;

  String get _businessId =>
      ref.read(sessionProvider).activeBusinessId ?? '';

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    try {
      if (_businessId.isEmpty) {
        throw StateError('No hay business activo');
      }
      final list = await ref
          .read(posSettingsRepositoryProvider)
          .getHeaderDestinationsDisabled(_businessId);
      if (!mounted) return;
      setState(() {
        _disabled = list.toSet();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'No se pudo cargar la configuración: $e';
        _loading = false;
      });
    }
  }

  Future<void> _toggle(String route, bool visible) async {
    if (_saving) return;
    // Toggle local, persist optimistically, revert on error.
    final previous = Set<String>.from(_disabled);
    setState(() {
      if (visible) {
        _disabled.remove(route);
      } else {
        _disabled.add(route);
      }
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(posSettingsRepositoryProvider)
          .setHeaderDestinationsDisabled(
            businessId: _businessId,
            routes: _disabled.toList(),
          );
      // Forzar refetch del provider para que el shell repinte de inmediato.
      ref.invalidate(headerDestinationsDisabledProvider(_businessId));
      if (!mounted) return;
      setState(() => _saving = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _disabled = previous;
        _saving = false;
        _error = 'No se pudo guardar el cambio: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () => context.go(AppRoutes.settings),
        ),
        title: const Text(
          'Personalizar Header',
          style: TextStyle(
            color: Colors.black87,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _IntroCard(),
        const SizedBox(height: 16),
        if (_error != null)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF2F2),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFFECACA)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Color(0xFFDC2626),
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: Color(0xFF991B1B),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(
            children: [
              for (var i = 0; i < kPrimaryDestinations.length; i++) ...[
                if (i > 0)
                  const Divider(height: 1, color: Color(0xFFE5E7EB)),
                _DestinationTile(
                  destination: kPrimaryDestinations[i],
                  visible: !_disabled.contains(kPrimaryDestinations[i].route),
                  busy: _saving,
                  onChanged: (v) =>
                      _toggle(kPrimaryDestinations[i].route, v),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _IntroCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEBF8FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFBEE3F8)),
      ),
      child: Row(
        children: const [
          Icon(Icons.info_outline, color: Color(0xFF3182CE), size: 20),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Elige qué módulos aparecen en el header para TODOS los '
              'empleados de este negocio. Los módulos sin permiso de '
              'rol ya se ocultan automáticamente — esta lista solo '
              'añade una capa de personalización adicional.',
              style: TextStyle(
                color: Color(0xFF2C5282),
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DestinationTile extends StatelessWidget {
  const _DestinationTile({
    required this.destination,
    required this.visible,
    required this.busy,
    required this.onChanged,
  });

  final ShellDestination destination;
  final bool visible;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final iconColor = visible
        ? MangoColors.primaryOrange
        : const Color(0xFFCBD5E0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: visible
                  ? MangoColors.primaryOrange.withValues(alpha: 0.1)
                  : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: destination.svgAsset != null
                  ? SvgPicture.asset(
                      destination.svgAsset!,
                      width: 22,
                      height: 22,
                      colorFilter: ColorFilter.mode(
                        iconColor,
                        BlendMode.srcIn,
                      ),
                    )
                  : Icon(destination.materialIcon, color: iconColor),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  destination.label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1A202C),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  visible
                      ? 'Visible para empleados con permiso'
                      : 'Oculto para TODOS los empleados',
                  style: TextStyle(
                    fontSize: 12,
                    color: visible
                        ? const Color(0xFF718096)
                        : const Color(0xFFE53E3E),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: visible,
            onChanged: busy ? null : onChanged,
            activeThumbColor: MangoColors.primaryOrange,
          ),
        ],
      ),
    );
  }
}
