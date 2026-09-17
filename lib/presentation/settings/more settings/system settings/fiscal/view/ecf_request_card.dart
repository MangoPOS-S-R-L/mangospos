import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/repositories/ecf_request_repository.dart';
import 'ecf_request_dialog.dart';

/// Tarjeta "Facturación electrónica" de Ajustes → Comprobantes fiscales.
///
/// Si el negocio nunca la pidió, invita a solicitarla. Si ya la pidió (o
/// MangoPOS la empezó desde el panel), muestra en qué paso va y qué le toca
/// al cliente. El avance lo calcula el servidor.
class EcfRequestCard extends ConsumerWidget {
  const EcfRequestCard({required this.businessId, super.key});

  final String businessId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(ecfRequestStatusProvider(businessId));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: statusAsync.when(
        loading: () => const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: MangoColors.primaryOrange),
          ),
        ),
        error: (e, _) => Row(
          children: [
            Expanded(
              child: Text(
                e is EcfRequestException
                    ? e.message
                    : 'No se pudo consultar el estado de la facturación electrónica.',
                style: const TextStyle(fontSize: 13, color: MangoColors.muted),
              ),
            ),
            TextButton(
              onPressed: () => ref.invalidate(ecfRequestStatusProvider(businessId)),
              child: const Text('Reintentar'),
            ),
          ],
        ),
        data: (status) => _content(context, ref, status),
      ),
    );
  }

  Widget _content(BuildContext context, WidgetRef ref, EcfRequestStatus status) {
    if (status.stage == EcfRequestStage.none) {
      return Row(
        children: [
          const _Icon(),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Conviértete en emisor electrónico',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
                SizedBox(height: 2),
                Text(
                  'MangoPOS registra tu empresa con su proveedor y te acompaña en la '
                  'certificación ante la DGII. Necesitas tu certificado de firma digital (.p12).',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => _request(context, ref, status),
            child: const Text('Solicitar'),
          ),
        ],
      );
    }

    final df = DateFormat('d MMM yyyy', 'es');
    final stage = status.stage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const _Icon(),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stage == EcfRequestStage.active
                        ? 'Facturación electrónica activa'
                        : 'Solicitud de facturación electrónica',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                  if (status.requestedAt != null && stage != EcfRequestStage.active)
                    Text(
                      'Enviada el ${df.format(status.requestedAt!.toLocal())}',
                      style: const TextStyle(fontSize: 12.5, color: Colors.grey),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Actualizar',
              onPressed: () => ref.invalidate(ecfRequestStatusProvider(businessId)),
              icon: const Icon(Icons.refresh, size: 18),
            ),
          ],
        ),
        if (stage != EcfRequestStage.active) ...[
          const SizedBox(height: 16),
          _Step('Solicitud enviada', done: true),
          _Step('Empresa registrada con el proveedor', done: stage.index > EcfRequestStage.company.index),
          _Step('Autorización de la DGII', done: stage.index > EcfRequestStage.certification.index),
          _Step('Secuencias e-NCF cargadas', done: stage.index > EcfRequestStage.sequences.index),
          _Step('Activación', done: false, isLast: true),
        ],
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: MangoColors.bgLight,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            _nextStepText(status),
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
        ),
        if (status.contactName != null && stage != EcfRequestStage.active) ...[
          const SizedBox(height: 8),
          Text(
            'Contacto: ${status.contactName}${status.contactPhone != null ? ' · ${status.contactPhone}' : ''}',
            style: const TextStyle(fontSize: 12, color: MangoColors.muted),
          ),
        ],
        // Si el alta con el proveedor no se completó (contraseña equivocada,
        // por ejemplo), el cliente puede reenviar con el certificado correcto.
        if (stage == EcfRequestStage.company) ...[
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => _request(context, ref, status),
            child: const Text('Enviar de nuevo con mi certificado'),
          ),
        ],
      ],
    );
  }

  String _nextStepText(EcfRequestStatus status) {
    switch (status.stage) {
      case EcfRequestStage.none:
        return '';
      case EcfRequestStage.company:
        return 'Recibimos tu solicitud, pero tu empresa todavía no quedó registrada con el '
            'proveedor. Si tu certificado o la contraseña dieron error, vuelve a enviarla. '
            'MangoPOS te contactará.';
      case EcfRequestStage.certification:
        return status.alreadyAuthorized == true
            ? 'Tu empresa ya está registrada. Indicaste que ya eres emisor electrónico: '
                'MangoPOS lo confirma con la DGII y sigue con tus secuencias.'
            : 'Tu empresa ya está registrada. Sigue la certificación ante la DGII: MangoPOS '
                'te guía con la postulación y las pruebas en tu Oficina Virtual.';
      case EcfRequestStage.sequences:
        return 'La DGII ya te autorizó. Solicita en tu Oficina Virtual las secuencias E31, '
            'E32 y E34, y envíale a MangoPOS el PDF de la autorización.';
      case EcfRequestStage.activation:
        return 'Todo está listo: MangoPOS está activando tu facturación electrónica.';
      case EcfRequestStage.active:
        return 'Tu negocio emite comprobantes electrónicos (serie E). Puedes ver cada '
            'factura electrónica desde el Historial de ventas.';
    }
  }

  Future<void> _request(BuildContext context, WidgetRef ref, EcfRequestStatus status) async {
    final result = await showEcfRequestDialog(context, businessId: businessId, status: status);
    if (result == null || !context.mounted) return;
    ref.invalidate(ecfRequestStatusProvider(businessId));
    if (result.companyRegistered) {
      AppToast.success(context, 'Solicitud enviada. MangoPOS te contactará para seguir.');
    } else {
      AppToast.info(context, result.message ?? 'Solicitud enviada. MangoPOS te contactará.');
    }
  }
}

class _Icon extends StatelessWidget {
  const _Icon();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: MangoColors.primaryOrange.withValues(alpha: 0.1),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.verified_outlined, color: MangoColors.primaryOrange, size: 20),
      );
}

class _Step extends StatelessWidget {
  const _Step(this.label, {required this.done, this.isLast = false});

  final String label;
  final bool done;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 8),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 18,
            color: done ? MangoColors.successGreen : MangoColors.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: done ? FontWeight.w600 : FontWeight.w400,
                color: done ? null : MangoColors.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
