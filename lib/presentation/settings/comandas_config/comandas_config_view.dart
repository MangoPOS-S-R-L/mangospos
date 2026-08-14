// Ajustes → Comandas y Precuentas → Config. de Comandas.
//
// Hoy expone dos switches independientes que controlan las franjas
// (banners inversos) que se imprimen en la comanda de cocina:
//   - "Mostrar franja «Para comer aquí»": si está prendido, la sección
//     de items dine-in lleva su banner arriba.
//   - "Mostrar franja «Para llevar»": idem para los items takeout.
// Los items siempre se separan por isTakeout. Los switches solo
// controlan si CADA sección imprime su banner. Default: ambos ON
// (comportamiento legacy).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_features_provider.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import '../../../core/theme/app_colors.dart';

class ComandasConfigView extends ConsumerStatefulWidget {
  const ComandasConfigView({super.key, this.businessId = 'auto'});

  final String businessId;

  @override
  ConsumerState<ComandasConfigView> createState() => _ComandasConfigViewState();
}

class _ComandasConfigViewState extends ConsumerState<ComandasConfigView> {
  String? _resolvedBusinessId;
  BusinessFeatures _features = BusinessFeatures.defaults;
  bool _completeOnPayment = true;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final id = await BusinessResolver.ensure(widget.businessId);
      final repo = ref.read(posSettingsRepositoryProvider);
      final features = await repo.getBusinessFeatures(id);
      final completeOnPayment = await repo.getKdsCompleteOnPayment(id);
      if (!mounted) return;
      setState(() {
        _resolvedBusinessId = id;
        _features = features;
        _completeOnPayment = completeOnPayment;
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

  Future<void> _setBanner({bool? dineIn, bool? takeout}) async {
    if (_saving || _resolvedBusinessId == null) return;
    final previous = _features;
    setState(() {
      _features = _features.copyWith(
        kitchenBannerDineIn: dineIn,
        kitchenBannerTakeout: takeout,
      );
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(posSettingsRepositoryProvider).setBusinessFeatures(
            businessId: _resolvedBusinessId!,
            features: _features,
          );
      ref.invalidate(businessFeaturesProvider);
      if (!mounted) return;
      setState(() => _saving = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _features = previous;
        _saving = false;
        _error = 'No se pudo guardar el cambio: $e';
      });
    }
  }

  Future<void> _setCompleteOnPayment(bool enabled) async {
    if (_saving ||
        _resolvedBusinessId == null ||
        enabled == _completeOnPayment) {
      return;
    }
    final previous = _completeOnPayment;
    setState(() {
      _completeOnPayment = enabled;
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(posSettingsRepositoryProvider).setKdsCompleteOnPayment(
            businessId: _resolvedBusinessId!,
            enabled: enabled,
          );
      if (!mounted) return;
      setState(() => _saving = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _completeOnPayment = previous;
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
          'Config. de Comandas',
          style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _IntroCard(saving: _saving),
        const SizedBox(height: 16),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _ErrorBanner(message: _error!),
          ),
        const _SectionLabel('Franjas en la comanda de cocina'),
        const SizedBox(height: 8),
        _BannerSwitch(
          icon: Icons.restaurant_outlined,
          title: 'Mostrar franja «Para comer aquí»',
          subtitle:
              'Cuando hay items dine-in, se imprime un banner inverso '
              '«PARA COMER AQUI» arriba de ellos.',
          value: _features.kitchenBannerDineIn,
          onChanged: _saving
              ? null
              : (v) => _setBanner(dineIn: v),
        ),
        const SizedBox(height: 12),
        _BannerSwitch(
          icon: Icons.takeout_dining_outlined,
          title: 'Mostrar franja «Para llevar»',
          subtitle:
              'Cuando hay items para llevar, se imprime un banner '
              'inverso «PARA LLEVAR» arriba de ellos.',
          value: _features.kitchenBannerTakeout,
          onChanged: _saving
              ? null
              : (v) => _setBanner(takeout: v),
        ),
        const SizedBox(height: 24),
        const _SectionLabel('Comportamiento en el KDS'),
        const SizedBox(height: 8),
        _BannerSwitch(
          icon: Icons.point_of_sale_outlined,
          title: 'Sacar la comanda del KDS al pagar',
          subtitle:
              'Activado (por defecto): al cobrar una orden sale sola del '
              'tablero de cocina. Desactivado: la orden se queda en cocina '
              '—aunque esté pagada— hasta que un cocinero la marque con '
              '«Marcar todo listo».',
          value: _completeOnPayment,
          onChanged: _saving ? null : _setCompleteOnPayment,
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        color: Colors.black54,
        letterSpacing: 0.8,
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.saving});

  final bool saving;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.list_alt_rounded, color: Colors.black54),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Controla el formato y el comportamiento de las comandas '
              'que se envían a cocina. El cambio aplica a la siguiente '
              'comanda; las que ya se imprimieron no se ven afectadas.',
              style: TextStyle(color: Colors.black87, fontSize: 14),
            ),
          ),
          if (saving) ...[
            const SizedBox(width: 12),
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ],
      ),
    );
  }
}

class _BannerSwitch extends StatelessWidget {
  const _BannerSwitch({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: value ? MangoColors.primaryOrange : MangoColors.cardBorder,
          width: value ? 1.5 : 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: value
                  ? const Color(0xFFFFEDD5)
                  : const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icon,
              color: value ? MangoColors.primaryOrange : MangoColors.muted,
              size: 20,
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
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: value
                        ? MangoColors.primaryOrange
                        : MangoColors.darkGray,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: MangoColors.muted,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch.adaptive(
            value: value,
            activeTrackColor: MangoColors.primaryOrange,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEBEE),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFA32D2D)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFA32D2D)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Color(0xFFA32D2D), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
