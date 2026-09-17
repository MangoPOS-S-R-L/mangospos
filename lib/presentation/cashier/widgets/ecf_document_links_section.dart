import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/ecf_documents_repository.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';

/// Bloque "Factura electrónica" del detalle de venta en el Historial: abre el
/// comprobante en la DGII, el PDF de Alanube y el XML firmado.
///
/// No se dibuja nada si el comprobante es de papel. El PDF y el XML se piden
/// al servidor en cada toque porque sus enlaces vencen.
class EcfDocumentLinksSection extends ConsumerStatefulWidget {
  const EcfDocumentLinksSection({required this.fiscalDocumentId, super.key});

  final String fiscalDocumentId;

  @override
  ConsumerState<EcfDocumentLinksSection> createState() =>
      _EcfDocumentLinksSectionState();
}

enum _EcfLink { dgii, pdf, xml }

class _EcfDocumentLinksSectionState
    extends ConsumerState<EcfDocumentLinksSection> {
  late final Future<FiscalDocument?> _docFuture = ref
      .read(salesRepositoryProvider)
      .getFiscalDocumentById(widget.fiscalDocumentId);

  /// Enlaces ya pedidos en esta apertura del detalle.
  EcfDocumentLinks? _links;
  _EcfLink? _loading;

  Future<void> _open(FiscalDocument doc, _EcfLink which) async {
    // La consulta DGII guardada no vence: se abre sin ir al servidor.
    if (which == _EcfLink.dgii && (doc.publicUrl?.isNotEmpty ?? false)) {
      await _launch(doc.publicUrl!);
      return;
    }

    setState(() => _loading = which);
    try {
      // PDF y XML siempre frescos; la consulta DGII se reusa si ya vino.
      final links = which == _EcfLink.dgii && _links?.stampUrl != null
          ? _links!
          : await ref
              .read(ecfDocumentsRepositoryProvider)
              .getLinks(widget.fiscalDocumentId);
      if (!mounted) return;
      _links = links;
      final url = switch (which) {
        _EcfLink.dgii => links.stampUrl,
        _EcfLink.pdf => links.pdfUrl,
        _EcfLink.xml => links.xmlUrl,
      };
      if (url == null) {
        AppToast.warning(
          context,
          switch (which) {
            _EcfLink.dgii => 'La DGII todavía no tiene la consulta de este comprobante.',
            _EcfLink.pdf => 'Alanube todavía no generó el PDF de este comprobante.',
            _EcfLink.xml => 'Alanube todavía no tiene el XML de este comprobante.',
          },
        );
        return;
      }
      await _launch(url);
    } catch (e) {
      if (!mounted) return;
      AppToast.error(
        context,
        e is EcfDocumentsException
            ? e.message
            : 'No se pudo abrir la factura electrónica.',
      );
    } finally {
      if (mounted) setState(() => _loading = null);
    }
  }

  Future<void> _launch(String url) async {
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (ok || !mounted) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    AppToast.info(context, 'No se pudo abrir el navegador: el enlace quedó copiado.');
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FiscalDocument?>(
      future: _docFuture,
      builder: (context, snap) {
        final doc = snap.data;
        if (doc == null || !doc.isElectronic) return const SizedBox.shrink();

        final sent = doc.alanubeDocumentId?.isNotEmpty ?? false;
        final (statusText, statusColor) = _status(doc);

        return Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: MangoColors.bgLight,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: MangoColors.cardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.verified_outlined, size: 16, color: MangoColors.infoBlue),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'Factura electrónica',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      statusText,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: statusColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (!sent)
                Text(
                  doc.ecfStatus == 'rejected'
                      ? 'No llegó a la DGII: no hay documento que abrir.'
                      : 'Todavía no llega a la DGII. Vuelve a abrir el detalle en unos minutos.',
                  style: const TextStyle(fontSize: 12, color: MangoColors.muted),
                )
              else ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _button(doc, _EcfLink.dgii, Icons.travel_explore, 'Ver en la DGII'),
                    _button(doc, _EcfLink.pdf, Icons.picture_as_pdf_outlined, 'PDF'),
                    _button(doc, _EcfLink.xml, Icons.code, 'XML'),
                  ],
                ),
                // El PDF de Alanube declara el MontoTotal (base + ITBIS) y no
                // pinta la propina legal: si la venta la lleva, su total no
                // cuadra con el del ticket, que es lo que pagó el cliente.
                if (doc.total - (doc.taxableAmount + doc.itbisAmount) > 0.01) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'El PDF de Alanube puede mostrar un total menor al del ticket: '
                    'no incluye la propina legal. Lo cobrado es lo del ticket.',
                    style: TextStyle(fontSize: 11, color: MangoColors.muted),
                  ),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _button(FiscalDocument doc, _EcfLink which, IconData icon, String label) {
    final loading = _loading == which;
    return OutlinedButton.icon(
      onPressed: _loading != null ? null : () => _open(doc, which),
      icon: loading
          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
  }

  (String, Color) _status(FiscalDocument doc) {
    if (doc.status == 'cancelled') return ('Anulada', Colors.redAccent);
    switch (doc.ecfStatus) {
      case 'accepted':
        return ('Aceptada DGII', MangoColors.successGreen);
      case 'sent':
        return ('En proceso DGII', MangoColors.infoBlue);
      case 'rejected':
        return ('Rechazada', Colors.redAccent);
      default:
        return ('Pendiente', MangoColors.primaryOrange);
    }
  }
}
