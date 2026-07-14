// Selección/cambio de plan. Muestra la lista de planes activos y, cuando el
// usuario elige uno distinto al actual, calcula el prorrateo lineal (PRD §8.7)
// y pide confirmación antes de aplicar el cambio.
//
// IMPORTANTE: el cambio de plan REAL (cobro/crédito de prorrateo + UPDATE de
// memberships.plan_id) lo hace el backend vía una RPC server-side. Esta UI por
// ahora solo muestra el preview y deja un placeholder visible para conectar
// la mutación cuando esté lista (Fase 4 del PRD bloqueada por doc WS DataVault).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/mango_colors.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/models/billing_plan.dart';
import '../../../data/models/billing_state.dart';
import '../../../data/repositories/billing_repository.dart';
import '../../../services/session/session_controller.dart';
import '../providers/billing_providers.dart';

class PlanSelectionView extends ConsumerWidget {
  const PlanSelectionView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final businessId = ref.watch(sessionProvider).activeBusinessId;
    final plansAsync = ref.watch(availablePlansProvider);
    final stateAsync = businessId != null
        ? ref.watch(billingStateProvider(businessId))
        : const AsyncValue<BillingState?>.data(null);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.6,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.go(AppRoutes.settingsBilling),
        ),
        title: const Text(
          'Elige tu plan',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
      ),
      body: plansAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('No pudimos cargar los planes: $e'),
          ),
        ),
        data: (plans) {
          if (plans.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No hay planes disponibles en este momento.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final currentPlan = stateAsync.value?.plan;
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            itemCount: plans.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              final plan = plans[i];
              final isCurrent = currentPlan?.id == plan.id;
              return _PlanCard(
                plan: plan,
                isCurrent: isCurrent,
                onSelect: isCurrent
                    ? null
                    : () => _onSelectPlan(
                          context: context,
                          ref: ref,
                          newPlan: plan,
                          currentPlan: currentPlan,
                        ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _onSelectPlan({
    required BuildContext context,
    required WidgetRef ref,
    required BillingPlan newPlan,
    required BillingPlan? currentPlan,
  }) async {
    final repo = ref.read(billingRepositoryProvider);
    final preview = currentPlan != null
        ? repo.previewProration(
            currentPlan: currentPlan,
            newPlan: newPlan,
            today: DateTime.now(),
          )
        : null;

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ChangePlanSheet(
        currentPlan: currentPlan,
        newPlan: newPlan,
        proration: preview,
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;

    // TODO(Fase 4): conectar con backend para cambiar plan + cobrar prorrateo.
    // Por ahora mostramos un mensaje claro de que esta acción quedará pendiente.
    AppToast.info(
      context,
      'El cambio de plan se confirmará cuando habilitemos el cobro automático. '
      'Por ahora, contáctanos para procesarlo manualmente.',
    );
  }
}

// ---------------------------------------------------------------------------
// Plan card
// ---------------------------------------------------------------------------

class _PlanCard extends StatelessWidget {
  final BillingPlan plan;
  final bool isCurrent;
  final VoidCallback? onSelect;

  const _PlanCard({
    required this.plan,
    required this.isCurrent,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = isCurrent ? MangoColors.primaryOrange : MangoColors.cardBorder;
    return Container(
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: isCurrent ? 2 : 1),
        boxShadow: const [
          BoxShadow(color: Color(0x0A000000), blurRadius: 14, offset: Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  plan.name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: MangoColors.darkGray,
                  ),
                ),
              ),
              if (isCurrent)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFE6D5),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'Plan actual',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: MangoColors.primaryOrange,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                plan.formattedPrice,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  color: MangoColors.darkGray,
                ),
              ),
              const SizedBox(width: 4),
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text(
                  '/ mes',
                  style: TextStyle(fontSize: 13, color: MangoColors.muted),
                ),
              ),
            ],
          ),
          if (plan.description != null) ...[
            const SizedBox(height: 8),
            Text(
              plan.description!,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF60646C),
                height: 1.5,
              ),
            ),
          ],
          if (plan.features.isNotEmpty) ...[
            const SizedBox(height: 14),
            ...plan.features.map(
              (f) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_circle_rounded,
                        color: MangoColors.successGreen, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        f,
                        style: const TextStyle(fontSize: 13, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (plan.trialDays > 0 && !isCurrent) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFFE6F0FE),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'Incluye ${plan.trialDays} días de prueba gratis',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1D4ED8),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor:
                    isCurrent ? const Color(0xFFE5E7EB) : MangoColors.primaryOrange,
                foregroundColor:
                    isCurrent ? MangoColors.muted : MangoColors.white,
                minimumSize: const Size.fromHeight(44),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: onSelect,
              child: Text(
                isCurrent ? 'Plan actual' : 'Cambiar a ${plan.name}',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom sheet de confirmación con preview de prorrateo
// ---------------------------------------------------------------------------

class _ChangePlanSheet extends StatelessWidget {
  final BillingPlan? currentPlan;
  final BillingPlan newPlan;
  final ProrationPreview? proration;

  const _ChangePlanSheet({
    required this.currentPlan,
    required this.newPlan,
    required this.proration,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: MangoColors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: MangoColors.cardBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Cambiar a ${newPlan.name}',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              currentPlan != null
                  ? 'Estás cambiando desde ${currentPlan!.name}'
                  : 'Estás activando tu primer plan',
              style: const TextStyle(fontSize: 13, color: MangoColors.muted),
            ),
            const SizedBox(height: 16),
            _DetailLine(
              label: 'Plan nuevo',
              value: '${newPlan.name} · ${newPlan.formattedPrice} / mes',
            ),
            if (currentPlan != null)
              _DetailLine(
                label: 'Plan actual',
                value: '${currentPlan!.name} · ${currentPlan!.formattedPrice} / mes',
              ),
            if (proration != null) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7F7F7),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: MangoColors.cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _prorationHeadline(proration!),
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _prorationExplanation(proration!),
                      style: const TextStyle(
                        fontSize: 12,
                        color: MangoColors.muted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      side: const BorderSide(color: MangoColors.cardBorder),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancelar'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: MangoColors.primaryOrange,
                      foregroundColor: MangoColors.white,
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text(
                      'Confirmar cambio',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _prorationHeadline(ProrationPreview p) {
    switch (p.kind) {
      case ProrationKind.upgrade:
        return 'Se te cobrará un ajuste de ${p.formattedAdjustment} hoy';
      case ProrationKind.downgrade:
        return 'Recibirás un crédito de ${p.formattedAdjustment} en tu próximo cobro';
      case ProrationKind.same:
        return 'No hay diferencia de precio';
    }
  }

  String _prorationExplanation(ProrationPreview p) {
    return 'Por los ${p.daysRemaining} días restantes del mes (de ${p.daysInMonth}). '
        'El monto se calcula proporcionalmente.';
  }
}

class _DetailLine extends StatelessWidget {
  final String label;
  final String value;
  const _DetailLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: MangoColors.muted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: MangoColors.darkGray,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
