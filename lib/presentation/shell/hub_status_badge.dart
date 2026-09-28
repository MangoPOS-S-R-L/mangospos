// Indicador de Hub en el header del POS, al lado del badge de sincronización.
//
// Por qué existe: todo esto ya estaba, pero enterrado en Ajustes → Red local,
// que un mesero no abre (permiso `settings.acceso`) y que además mezcla la
// política del local, promover este equipo a Hub y quitarle el control a otro.
// Nada de eso le sirve al mesero: lo único que necesita es ver si su tablet
// está hablando con la caja y, si no, volver a encontrarla.
//
// Por eso este indicador expone SOLO la parte segura: ver el estado y elegir
// a qué caja conectarse. La política y la promoción se quedan en Ajustes.
//
// NO necesita internet: el rol y la IP del Hub viven en el propio equipo
// (SharedPreferences vía HubConfigService) y el descubrimiento es LAN pura
// (mDNS + barrido TCP). Por eso sirve justo cuando más falta hace.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/offline/hub/hub_client.dart';
import '../../core/offline/hub/hub_config.dart';
import '../../core/offline/hub/hub_mode.dart';
import '../../core/offline/hub/hub_mode_controller.dart';
import '../../core/utils/app_snackbar.dart';
import '../../core/utils/friendly_error.dart';
import '../../services/session/session_controller.dart';
import '../settings/hub/hub_network_settings_view.dart'
    show showDeviceDiscoverySheet;

/// Estado visible del equipo respecto al Hub.
enum HubLinkState {
  /// Este equipo ES el Hub: no hay a quién conectarse.
  isHub,

  /// Conectado a la caja que hace de Hub.
  connected,

  /// El local usa Hub pero este equipo no lo encuentra.
  disconnected,
}

/// Traduce el modo del terminal a lo que el mesero necesita ver.
///
/// `null` = el local NO usa Hub (política `cloud`): el indicador no se dibuja.
/// Un icono que no explica nada solo ocupa espacio en el header.
HubLinkState? hubLinkStateFor(TerminalMode mode) {
  switch (mode) {
    case TerminalMode.hubHost:
      return HubLinkState.isHub;
    case TerminalMode.hubClient:
      return HubLinkState.connected;
    case TerminalMode.cloud:
    case TerminalMode.solo:
      return null;
  }
}

class HubStatusBadge extends ConsumerWidget {
  const HubStatusBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!kHubModeEnabled) return const SizedBox.shrink();

    final mode = ref.watch(hubModeProvider);
    final controller = ref.watch(hubModeProvider.notifier);
    var link = hubLinkStateFor(mode);

    // `cloud`/`solo` con una IP de Hub guardada = el local SÍ usa Hub y este
    // equipo lo perdió. Sin esto el indicador desaparecería justo cuando hay
    // que mirarlo, que es el momento en que la tablet se quedó sola.
    if (link == null) {
      if (controller.configuredHubUrl == null) return const SizedBox.shrink();
      link = HubLinkState.disconnected;
    }

    final (icon, bg, fg, tip) = switch (link) {
      HubLinkState.isHub => (
        Icons.dns_rounded,
        const Color(0xFFDCFCE7),
        const Color(0xFF15803D),
        'Este equipo es el Hub del local',
      ),
      HubLinkState.connected => (
        Icons.lan_rounded,
        const Color(0xFFDCFCE7),
        const Color(0xFF15803D),
        'Conectado a la caja${_suffix(controller.reachableHubUrl)}',
      ),
      HubLinkState.disconnected => (
        Icons.link_off_rounded,
        const Color(0xFFFEE2E2),
        const Color(0xFFB91C1C),
        'Sin conexión con la caja — toca para buscarla',
      ),
    };

    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Tooltip(
        message: tip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => showHubPickerDialog(context, ref),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Icon(icon, color: fg),
            ),
          ),
        ),
      ),
    );
  }

  static String _suffix(String? url) {
    final clean = url?.trim() ?? '';
    return clean.isEmpty ? '' : ' ($clean)';
  }
}

/// Modal del mesero: ver a qué caja está conectado y, si hace falta, buscarla.
Future<void> showHubPickerDialog(BuildContext context, WidgetRef ref) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _HubPickerDialog(),
  );
}

class _HubPickerDialog extends ConsumerStatefulWidget {
  const _HubPickerDialog();

  @override
  ConsumerState<_HubPickerDialog> createState() => _HubPickerDialogState();
}

class _HubPickerDialogState extends ConsumerState<_HubPickerDialog> {
  final _ipCtrl = TextEditingController();
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    _loadCurrent();
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    super.dispose();
  }

  String? get _businessId => ref.read(sessionProvider).activeBusinessId;

  Future<void> _loadCurrent() async {
    final bid = _businessId;
    if (bid == null || bid.isEmpty) return;
    final url = await HubConfigService().getHubUrl(bid);
    if (!mounted) return;
    setState(() => _ipCtrl.text = url ?? '');
  }

  /// Guarda la IP y vuelve a resolver el modo. No se valida antes a propósito:
  /// la caja puede estar apagada en este momento y el mesero igual necesita
  /// dejarla configurada para cuando encienda.
  Future<void> _save(String raw, {required bool announce}) async {
    final bid = _businessId;
    if (bid == null || bid.isEmpty) return;
    await HubConfigService().setHubUrl(bid, raw.trim());
    await ref.read(hubModeProvider.notifier).reloadConfigAndRefresh();
    if (!mounted) return;
    final url = ref.read(hubModeProvider.notifier).reachableHubUrl;
    setState(() {
      _messageIsError = url == null;
      _message = url != null
          ? 'Conectado a $url.'
          : 'Guardado, pero no se pudo contactar la caja. Revisa que esté '
                'encendida y en la misma red.';
    });
    if (announce && url != null && mounted) {
      ScaffoldMessenger.of(context).showAppSnackBar(
        SnackBar(content: Text('Conectado a la caja ($url).')),
      );
    }
  }

  Future<void> _search() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final chosen = await showDeviceDiscoverySheet(
        context,
        businessId: _businessId,
      );
      if (!mounted) return;
      if (chosen == null) {
        setState(() => _busy = false);
        return;
      }
      _ipCtrl.text = chosen.ip ?? chosen.host;
      await _save(_ipCtrl.text, announce: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messageIsError = true;
        _message = FriendlyError.humanize('No se pudo buscar: $e');
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _probe() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final url = await HubClient().findReachableHub(
        businessId: _businessId,
        configuredUrl: _ipCtrl.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _messageIsError = url == null;
        _message = url != null
            ? 'La caja respondió en $url.'
            : 'No respondió. Revisa que esté encendida y en la misma red '
                  '(el wifi del local, no datos móviles).';
      });
      if (url != null) await ref.read(hubModeProvider.notifier).refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messageIsError = true;
        _message = FriendlyError.humanize('No se pudo probar: $e');
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(hubModeProvider);
    final controller = ref.watch(hubModeProvider.notifier);
    final link = hubLinkStateFor(mode) ?? HubLinkState.disconnected;
    final isHub = link == HubLinkState.isHub;

    return AlertDialog(
      title: const Text('Conexión con la caja'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _statusTile(link, controller.reachableHubUrl),
            if (!isHub) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _ipCtrl,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'IP de la caja',
                  hintText: 'Ej. 192.168.1.50',
                  helperText: 'El puerto se detecta solo',
                  isDense: true,
                ),
                onSubmitted: (v) => _save(v, announce: true),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _search,
                      icon: const Icon(Icons.wifi_find_rounded, size: 18),
                      label: const Text('Buscar la caja'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _busy ? null : _probe,
                    child: const Text('Probar'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'La búsqueda puede tardar hasta 30 segundos.',
                style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
              ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: _messageIsError
                      ? const Color(0xFFFEF2F2)
                      : const Color(0xFFF0FDF4),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _messageIsError
                        ? const Color(0xFFFECACA)
                        : const Color(0xFFBBF7D0),
                  ),
                ),
                child: Text(
                  _message!,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: _messageIsError
                        ? const Color(0xFF991B1B)
                        : const Color(0xFF166534),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }

  Widget _statusTile(HubLinkState link, String? url) {
    final (color, bg, title, subtitle) = switch (link) {
      HubLinkState.isHub => (
        const Color(0xFF15803D),
        const Color(0xFFDCFCE7),
        'Este equipo es la caja',
        'Los demás equipos se conectan aquí. No hay nada que elegir.',
      ),
      HubLinkState.connected => (
        const Color(0xFF15803D),
        const Color(0xFFDCFCE7),
        'Conectado',
        url == null ? 'Hablando con la caja.' : 'Hablando con la caja en $url.',
      ),
      HubLinkState.disconnected => (
        const Color(0xFFB91C1C),
        const Color(0xFFFEE2E2),
        'Sin conexión con la caja',
        'Tus mesas no se están viendo en la caja. Búscala aquí abajo.',
      ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            link == HubLinkState.disconnected
                ? Icons.link_off_rounded
                : Icons.check_circle_rounded,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: color.withValues(alpha: 0.85),
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
