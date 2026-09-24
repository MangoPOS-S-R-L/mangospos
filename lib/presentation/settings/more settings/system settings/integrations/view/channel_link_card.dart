// Tarjeta "Pedidos en línea" de Ajustes → Integraciones.
//
// El dueño conecta el canal sin que nadie corra SQL ni le mande una API key por
// mensaje: toca Conectar, sale un código de 8 caracteres, se lo dicta al canal,
// y el canal lo canjea contra el servidor. Las llaves nunca se muestran acá
// porque nunca pasan por la app.
//
// Sigue el patrón de `EcfRequestCard`: estado arriba, qué le toca hacer al
// cliente abajo.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/repositories/channel_link_repository.dart';

class ChannelLinkCard extends ConsumerStatefulWidget {
  const ChannelLinkCard({
    required this.businessId,
    this.channel = 'pincer',
    this.channelLabel = 'Pincer',
    super.key,
  });

  final String businessId;
  final String channel;
  final String channelLabel;

  @override
  ConsumerState<ChannelLinkCard> createState() => _ChannelLinkCardState();
}

class _ChannelLinkCardState extends ConsumerState<ChannelLinkCard> {
  bool _trabajando = false;
  Timer? _cuentaRegresiva;

  @override
  void dispose() {
    _cuentaRegresiva?.cancel();
    super.dispose();
  }

  ({String businessId, String channel}) get _arg =>
      (businessId: widget.businessId, channel: widget.channel);

  void _recargar() => ref.invalidate(channelLinkStatusProvider(_arg));

  Future<void> _conectar() async {
    setState(() => _trabajando = true);
    try {
      await ref
          .read(channelLinkRepositoryProvider)
          .createCode(businessId: widget.businessId, channel: widget.channel);
      _recargar();
      // Tic para que el "vence en X" de la pantalla baje solo.
      _cuentaRegresiva?.cancel();
      _cuentaRegresiva = Timer.periodic(
        const Duration(seconds: 20),
        (_) => mounted ? setState(() {}) : _cuentaRegresiva?.cancel(),
      );
    } catch (e) {
      if (mounted) AppToast.error(context, 'No se pudo generar el código: $e');
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }

  Future<void> _desconectar() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Desconectar ${widget.channelLabel}?'),
        content: Text(
          'Dejan de entrar pedidos de ${widget.channelLabel} de inmediato. '
          'Los pedidos que ya entraron no se tocan.\n\n'
          'Para volver a conectarlo hay que generar un código nuevo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade600),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Desconectar'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _trabajando = true);
    try {
      await ref
          .read(channelLinkRepositoryProvider)
          .disconnect(businessId: widget.businessId, channel: widget.channel);
      _recargar();
      if (mounted) {
        AppToast.success(context, '${widget.channelLabel} quedó desconectado');
      }
    } catch (e) {
      if (mounted) AppToast.error(context, 'No se pudo desconectar: $e');
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusAsync = ref.watch(channelLinkStatusProvider(_arg));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: statusAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => _Fila(
          titulo: widget.channelLabel,
          subtitulo: 'No se pudo leer el estado de la integración',
          accion: TextButton(onPressed: _recargar, child: const Text('Reintentar')),
        ),
        data: (s) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Fila(
              titulo: widget.channelLabel,
              subtitulo: s.connected
                  ? 'Conectado · ${s.ordersToday} pedido(s) hoy'
                  : 'Recibe los pedidos en línea directo en el POS',
              conectado: s.connected,
              prueba: s.connected && s.esPrueba,
              accion: _trabajando
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : s.connected
                  ? TextButton(
                      onPressed: _desconectar,
                      child: Text(
                        'Desconectar',
                        style: TextStyle(color: Colors.red.shade600),
                      ),
                    )
                  : FilledButton(
                      onPressed: _conectar,
                      style: FilledButton.styleFrom(
                        backgroundColor: MangoColors.primaryOrange,
                      ),
                      child: const Text('Conectar'),
                    ),
            ),
            if (s.pendingCode != null) ...[
              const SizedBox(height: 14),
              _CodigoVivo(
                code: s.pendingCode!,
                expiresAt: s.pendingCodeExpiresAt,
                canal: widget.channelLabel,
                onRegenerar: _trabajando ? null : _conectar,
              ),
            ],
            if (s.connected) ...[
              const SizedBox(height: 12),
              _Detalle(status: s, canal: widget.channelLabel),
            ],
          ],
        ),
      ),
    );
  }
}

class _Fila extends StatelessWidget {
  const _Fila({
    required this.titulo,
    required this.subtitulo,
    required this.accion,
    this.conectado = false,
    this.prueba = false,
  });

  final String titulo;
  final String subtitulo;
  final Widget accion;
  final bool conectado;
  final bool prueba;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: (conectado ? MangoColors.successGreen : MangoColors.muted)
                .withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.storefront,
            size: 20,
            color: conectado ? MangoColors.successGreen : MangoColors.muted,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      titulo,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: MangoColors.darkGray,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (prueba) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: MangoColors.infoBlue.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'PRUEBAS',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: MangoColors.infoBlue,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                subtitulo,
                style: const TextStyle(fontSize: 12, color: MangoColors.muted),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        accion,
      ],
    );
  }
}

class _CodigoVivo extends StatelessWidget {
  const _CodigoVivo({
    required this.code,
    required this.expiresAt,
    required this.canal,
    this.onRegenerar,
  });

  final String code;
  final DateTime? expiresAt;
  final String canal;
  final VoidCallback? onRegenerar;

  String get _restante {
    final exp = expiresAt;
    if (exp == null) return '';
    final falta = exp.difference(DateTime.now());
    if (falta.isNegative) return 'vencido';
    if (falta.inMinutes >= 1) return 'vence en ${falta.inMinutes} min';
    return 'vence en menos de 1 min';
  }

  @override
  Widget build(BuildContext context) {
    final vencido = _restante == 'vencido';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: MangoColors.bgLight,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Dale este código a $canal',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  code,
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 3,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: vencido
                        ? MangoColors.muted
                        : MangoColors.primaryOrange,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Copiar',
                onPressed: vencido
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: code));
                        AppToast.success(context, 'Código copiado');
                      },
                icon: const Icon(Icons.copy_rounded, size: 20),
              ),
            ],
          ),
          Text(
            vencido
                ? 'Este código venció. Genera otro.'
                : 'Solo sirve una vez y $_restante.',
            style: TextStyle(
              fontSize: 12,
              color: vencido ? Colors.red.shade600 : MangoColors.muted,
              fontWeight: vencido ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Puedes dictárselo por teléfono: no lleva letras que se confundan '
            '(sin O, 0, I ni 1). Cuando $canal lo canjee, la conexión queda '
            'lista y este código deja de servir.',
            style: const TextStyle(fontSize: 11, color: MangoColors.muted),
          ),
          if (onRegenerar != null) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onRegenerar,
                child: const Text('Generar otro'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Detalle extends StatelessWidget {
  const _Detalle({required this.status, required this.canal});

  final ChannelLinkStatus status;
  final String canal;

  String _cuando(DateTime? d) {
    if (d == null) return 'nunca';
    final falta = DateTime.now().difference(d);
    if (falta.inMinutes < 1) return 'hace un momento';
    if (falta.inHours < 1) return 'hace ${falta.inMinutes} min';
    if (falta.inDays < 1) return 'hace ${falta.inHours} h';
    return 'hace ${falta.inDays} día(s)';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MangoColors.bgLight,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _linea('Credencial', status.keyPrefix ?? '—'),
          _linea('Último pedido', _cuando(status.lastOrderAt)),
          _linea('Pedidos en total', '${status.ordersTotal}'),
          if (status.esPrueba)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Está en modo de pruebas: los pedidos entran marcados como '
                'PRUEBA y no imprimen comanda.',
                style: TextStyle(fontSize: 11, color: MangoColors.infoBlue),
              ),
            ),
        ],
      ),
    );
  }

  Widget _linea(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(k, style: const TextStyle(fontSize: 12, color: MangoColors.muted)),
        Text(
          v,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: MangoColors.darkGray,
          ),
        ),
      ],
    ),
  );
}
