// Histórico de cobros — tabla cronológica con badges de status y link al PDF.
//
// La generación de PDF la hace el backend (PRD Fase 8) — acá solo abrimos
// el path si está disponible. Mientras la Fase 8 no esté lista, el botón de
// recibo queda deshabilitado con tooltip.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/mango_colors.dart';
import '../../../data/models/billing_charge.dart';
import '../../../services/session/session_controller.dart';
import '../providers/billing_providers.dart';

class ChargeHistoryView extends ConsumerWidget {
  const ChargeHistoryView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final businessId = ref.watch(sessionProvider).activeBusinessId;
    if (businessId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Historial de cobros')),
        body: const Center(child: Text('Selecciona un negocio')),
      );
    }

    final chargesAsync = ref.watch(chargesProvider(businessId));

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
          'Historial de cobros',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(chargesProvider(businessId));
          await Future<void>.delayed(const Duration(milliseconds: 250));
        },
        child: chargesAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            padding: const EdgeInsets.all(24),
            children: [Center(child: Text('No pudimos cargar el historial: $e'))],
          ),
          data: (charges) {
            if (charges.isEmpty) {
              return ListView(
                padding: const EdgeInsets.all(32),
                children: const [
                  Center(
                    child: Column(
                      children: [
                        Icon(Icons.receipt_long_rounded,
                            color: MangoColors.muted, size: 48),
                        SizedBox(height: 12),
                        Text(
                          'Aún no tienes cobros registrados',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        SizedBox(height: 6),
                        Text(
                          'Aquí verás cada mes de tu suscripción con su comprobante.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: MangoColors.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              itemCount: charges.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _ChargeRow(charge: charges[i]),
            );
          },
        ),
      ),
    );
  }
}

class _ChargeRow extends StatelessWidget {
  final BillingCharge charge;
  const _ChargeRow({required this.charge});

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat("d 'de' MMM yyyy", 'es');
    final periodFmt = DateFormat('d MMM', 'es');
    final hasReceipt = charge.receiptPdfPath != null && charge.receiptPdfPath!.isNotEmpty;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      charge.formattedAmount,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: MangoColors.darkGray,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _StatusChip(status: charge.status),
                    if (charge.attemptNumber > 1) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF3C7),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'Intento ${charge.attemptNumber}',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFB45309),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  dateFmt.format(charge.attemptedAt),
                  style: const TextStyle(fontSize: 12, color: MangoColors.muted),
                ),
                const SizedBox(height: 2),
                Text(
                  'Periodo ${periodFmt.format(charge.billingPeriodStart)} – '
                  '${periodFmt.format(charge.billingPeriodEnd)}',
                  style: const TextStyle(fontSize: 12, color: MangoColors.muted),
                ),
                if (charge.responseMessage != null &&
                    charge.responseMessage!.isNotEmpty &&
                    charge.status != BillingChargeStatus.approved) ...[
                  const SizedBox(height: 4),
                  Text(
                    charge.responseMessage!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFFB45309),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (charge.status == BillingChargeStatus.approved)
            IconButton(
              icon: Icon(
                Icons.picture_as_pdf_outlined,
                color: hasReceipt ? MangoColors.primaryOrange : MangoColors.muted,
              ),
              tooltip: hasReceipt
                  ? 'Descargar comprobante'
                  : 'Comprobante en preparación',
              onPressed: hasReceipt ? () => _openReceipt(context, charge) : null,
            ),
        ],
      ),
    );
  }

  Future<void> _openReceipt(BuildContext context, BillingCharge charge) async {
    final path = charge.receiptPdfPath;
    if (path == null) return;
    // El path es relativo al bucket de Storage; idealmente generamos signed URL
    // desde el repo. Por ahora intentamos abrirlo si ya es URL absoluta.
    if (path.startsWith('http')) {
      await launchUrl(Uri.parse(path), mode: LaunchMode.externalApplication);
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('El comprobante está en preparación.')),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final BillingChargeStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (status) {
      BillingChargeStatus.approved => (const Color(0xFFE8F8EF), const Color(0xFF15803D)),
      BillingChargeStatus.declined => (const Color(0xFFFEE2E2), const Color(0xFFB91C1C)),
      BillingChargeStatus.error => (const Color(0xFFFEF3C7), const Color(0xFFB45309)),
      BillingChargeStatus.voided => (const Color(0xFFE5E7EB), Color(0xFF374151)),
      BillingChargeStatus.pending => (const Color(0xFFE6F0FE), const Color(0xFF1D4ED8)),
      BillingChargeStatus.unknown => (const Color(0xFFE5E7EB), MangoColors.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        status.label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: fg),
      ),
    );
  }
}
