import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/offline/hub/hub_client.dart';
import '../../../core/offline/hub/hub_config.dart';
import '../../../core/offline/hub/hub_mode_controller.dart';
import '../../../core/offline/offline_pos_service.dart';
import '../../../core/printing/agent_discovery.dart';
import '../../../data/repositories/pos_settings_repository.dart';
import '../../../services/session/session_controller.dart';

/// Ajustes → "Red local (Hub)". Configura el modo híbrido LAN-first:
/// - Política del local (cloud / hub) — solo el dueño.
/// - Rol de ESTE dispositivo (caja / hub / respaldo).
/// - IP/URL del Hub que usan las cajas para conectarse.
///
/// Gateada tras [kHubModeEnabled] desde el call-site (no aparece en producción
/// hasta que el ruteo LAN-first esté cableado y probado — H4+). Ver
/// docs/PRD_HUB_HIBRIDO_LAN_FIRST.md.
class HubNetworkSettingsView extends ConsumerStatefulWidget {
  const HubNetworkSettingsView({super.key});

  @override
  ConsumerState<HubNetworkSettingsView> createState() =>
      _HubNetworkSettingsViewState();
}

class _HubNetworkSettingsViewState
    extends ConsumerState<HubNetworkSettingsView> {
  final HubConfigService _hubConfig = HubConfigService();
  final TextEditingController _urlController = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _businessId;
  NetworkPolicy _policy = NetworkPolicy.cloud;
  HubDeviceRole _role = HubDeviceRole.pos;
  String? _probeResult; // texto del último "probar conexión"
  bool _discovering = false; // buscando equipos en la red (mDNS)
  int _pendingCount = 0; // operaciones sin subir al servidor (cola + dead)
  int _hubOpLogCount = 0; // ops en el op-log del Hub (solo si este equipo es Hub)

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider);
    final bizId = session.activeBusinessId;
    if (bizId == null || bizId.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final repo = ref.read(posSettingsRepositoryProvider);
      final modeStr = await repo.getNetworkMode(bizId);
      final role = await _hubConfig.getDeviceRole(bizId);
      final url = await _hubConfig.getHubUrl(bizId);
      if (!mounted) return;
      setState(() {
        _businessId = bizId;
        _policy = networkPolicyFromString(modeStr);
        _role = role;
        _urlController.text = url ?? '';
        _loading = false;
      });
      await _loadStatus();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Diagnóstico: cuántas operaciones tiene este equipo sin subir al servidor
  /// y, si es el Hub, cuántas hay en su op-log. Ayuda a depurar la prueba
  /// multi-dispositivo.
  Future<void> _loadStatus() async {
    final bizId = _businessId;
    if (bizId == null || bizId.isEmpty) return;
    final svc = OfflinePosService();
    var pending = 0;
    var hubOps = 0;
    try {
      pending = await svc.pendingActionsCount(bizId) +
          await svc.deadActionsCount(bizId);
    } catch (_) {}
    try {
      hubOps = (await svc.getLocalHubOps(bizId)).length;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _pendingCount = pending;
      _hubOpLogCount = hubOps;
    });
  }

  Future<void> _savePolicy(NetworkPolicy p) async {
    final bizId = _businessId;
    if (bizId == null) return;
    setState(() {
      _policy = p;
      _saving = true;
    });
    try {
      await ref.read(posSettingsRepositoryProvider).setNetworkMode(
            businessId: bizId,
            mode: networkPolicyToString(p),
          );
      // Efecto inmediato: recalcular el modo del terminal con la nueva política.
      unawaited(
        ref.read(hubModeProvider.notifier).reloadConfigAndRefresh(),
      );
    } catch (e) {
      _toast('No se pudo guardar la política: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveRole(HubDeviceRole r) async {
    final bizId = _businessId;
    if (bizId == null) return;
    setState(() => _role = r);
    await _hubConfig.setDeviceRole(bizId, r);
    // Efecto inmediato: recalcular el modo con el nuevo rol de este equipo.
    unawaited(ref.read(hubModeProvider.notifier).reloadConfigAndRefresh());
  }

  Future<void> _saveUrl() async {
    final bizId = _businessId;
    if (bizId == null) return;
    await _hubConfig.setHubUrl(bizId, _urlController.text);
    _toast('Dirección del Hub guardada.');
  }

  Future<void> _probe() async {
    final bizId = _businessId;
    if (bizId == null) return;
    setState(() => _probeResult = 'Probando…');
    try {
      final url = await HubClient().findReachableHub(
        businessId: bizId,
        configuredUrl: _urlController.text.trim().isEmpty
            ? null
            : _urlController.text.trim(),
      );
      if (!mounted) return;
      setState(() => _probeResult = url != null
          ? '✅ Hub alcanzable en $url'
          : '❌ No se encontró un Hub alcanzable');
    } catch (e) {
      if (mounted) setState(() => _probeResult = '❌ Error al probar: $e');
    }
  }

  /// Busca por mDNS los equipos MangoPOS en la red local y deja elegir uno
  /// como Hub. El agente de la caja principal (Windows/desktop) se anuncia, así
  /// que aparece aquí; al elegirlo guardamos su IP (el puerto del Hub —4000 o
  /// 4100— lo detecta solo la conexión).
  Future<void> _discoverDevices() async {
    if (_discovering) return;
    setState(() => _discovering = true);
    List<DiscoveredAgent> found = const [];
    try {
      final disc = AgentDiscovery();
      // Detección de 30s: mDNS en redes reales (Windows/routers) puede tardar
      // en responder; una ventana amplia asegura encontrar la caja principal.
      // Primero filtrando por negocio; si no aparece nada (el agente no anuncia
      // business_id), reintento corto sin filtro mostrando todo lo de la red.
      found = await disc.discover(
        businessIdFilter: _businessId,
        timeout: const Duration(seconds: 30),
      );
      if (found.isEmpty) {
        found = await disc.discover(timeout: const Duration(seconds: 5));
      }
    } catch (_) {
      found = const [];
    }
    if (!mounted) return;
    setState(() => _discovering = false);

    if (found.isEmpty) {
      _toast('No se encontraron equipos en la red. Verifica que estén en la '
          'misma red/Wi-Fi, o escribe la IP manualmente.');
      return;
    }

    final chosen = await showModalBottomSheet<DiscoveredAgent>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text('Equipos encontrados en la red',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
            for (final a in found)
              ListTile(
                leading: const Icon(Icons.computer_outlined),
                title: Text(a.name.trim().isNotEmpty ? a.name : (a.ip ?? a.host)),
                subtitle: Text('${a.ip ?? a.host}:${a.port}'),
                onTap: () => Navigator.of(ctx).pop(a),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (chosen == null) return;
    setState(() => _urlController.text = chosen.ip ?? chosen.host);
    await _saveUrl();
    unawaited(_probe());
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final isOwner = ref.watch(sessionProvider).isOwner;
    return Scaffold(
      appBar: AppBar(title: const Text('Red local (Hub)')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _businessId == null
              ? const Center(child: Text('No hay un negocio activo.'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _infoCard(),
                    const SizedBox(height: 16),
                    _statusCard(),
                    const SizedBox(height: 16),
                    _sectionTitle('Modo del local'),
                    _policySelector(isOwner),
                    if (_policy == NetworkPolicy.hub) ...[
                      const SizedBox(height: 16),
                      _sectionTitle('Rol de este dispositivo'),
                      _roleSelector(),
                      if (_role != HubDeviceRole.hub) ...[
                        const SizedBox(height: 16),
                        _sectionTitle('Dirección del Hub'),
                        _urlField(),
                      ],
                    ],
                  ],
                ),
    );
  }

  String _modeLabel(TerminalMode m) {
    switch (m) {
      case TerminalMode.hubHost:
        return 'Hub — este equipo es el servidor de la red local';
      case TerminalMode.hubClient:
        return 'Conectado al Hub por la red local';
      case TerminalMode.cloud:
        return 'Nube (directo al servidor)';
      case TerminalMode.solo:
        return 'Sin conexión (cola local)';
    }
  }

  Widget _statusCard() {
    final mode = ref.watch(hubModeProvider);
    final hubUrl = ref.read(hubModeProvider.notifier).reachableHubUrl;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Estado de este equipo',
                      style: TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
                ),
                IconButton(
                  tooltip: 'Actualizar',
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: _loadStatus,
                ),
              ],
            ),
            _statusRow('Modo actual', _modeLabel(mode)),
            if (mode == TerminalMode.hubClient && hubUrl != null)
              _statusRow('Hub conectado', hubUrl),
            if (mode == TerminalMode.hubHost)
              _statusRow('Operaciones en el Hub', '$_hubOpLogCount'),
            _statusRow('Sin subir al servidor', '$_pendingCount'),
          ],
        ),
      ),
    );
  }

  Widget _statusRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(label,
                style: const TextStyle(color: Colors.grey, fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _infoCard() {
    return Card(
      color: const Color(0xFFEFF6FF),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.hub_outlined, color: Color(0xFF1D4ED8)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'En modo Hub, una computadora del local (la caja principal) es '
                'el servidor central de la red local: todas las cajas leen y '
                'escriben de ella y solo el Hub sube al servidor. Úsalo cuando '
                'el internet del local sea malo o intermitente.',
                style: const TextStyle(color: Color(0xFF1E3A8A), fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t,
            style:
                const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
      );

  Widget _policySelector(bool isOwner) {
    return Column(
      children: [
        // Solo el dueño (o mientras no se guarda) puede interactuar; para el
        // resto se absorbe el toque (RadioGroup.onChanged no admite null).
        AbsorbPointer(
          absorbing: !isOwner || _saving,
          child: RadioGroup<NetworkPolicy>(
            groupValue: _policy,
            onChanged: (v) {
              if (v != null) _savePolicy(v);
            },
            child: const Column(
            children: [
              RadioListTile<NetworkPolicy>(
                value: NetworkPolicy.cloud,
                title: Text('Nube (directo al servidor)'),
                subtitle: Text(
                    'Cada caja se comunica directo con el servidor. Ideal si '
                    'la red del local es buena.'),
              ),
              RadioListTile<NetworkPolicy>(
                value: NetworkPolicy.hub,
                title: Text('Hub local (caja principal como servidor)'),
                subtitle: Text(
                    'Las cajas van por la LAN a la caja principal. Resuelve el '
                    'internet malo/intermitente.'),
              ),
            ],
            ),
          ),
        ),
        if (!isOwner)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('Solo el dueño puede cambiar la política del local.',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
      ],
    );
  }

  Widget _roleSelector() {
    return RadioGroup<HubDeviceRole>(
      groupValue: _role,
      onChanged: (v) {
        if (v != null) _saveRole(v);
      },
      child: const Column(
        children: [
          RadioListTile<HubDeviceRole>(
            value: HubDeviceRole.pos,
            title: Text('Caja (se conecta al Hub)'),
          ),
          RadioListTile<HubDeviceRole>(
            value: HubDeviceRole.hub,
            title: Text('Este equipo ES el Hub'),
            subtitle: Text(
                'Debe permanecer encendido con la app abierta durante el '
                'servicio. Solo uno por local.'),
          ),
          RadioListTile<HubDeviceRole>(
            value: HubDeviceRole.hubBackup,
            title: Text('Respaldo del Hub'),
            subtitle: Text(
                'Toma el control si la caja principal se apaga (failover).'),
          ),
        ],
      ),
    );
  }

  Widget _urlField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _discovering ? null : _discoverDevices,
            icon: _discovering
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_tethering, size: 18),
            label: Text(
              _discovering
                  ? 'Buscando equipos… (hasta 30s)'
                  : 'Buscar equipos en la red',
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _urlController,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'IP del Hub',
            hintText: '192.168.1.50',
            helperText:
                'Usa "Buscar equipos en la red" o escribe la IP de la caja '
                'principal. El puerto se detecta solo (4000/4100).',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _saveUrl,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: const Text('Guardar'),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: _probe,
              icon: const Icon(Icons.wifi_find_outlined, size: 18),
              label: const Text('Probar conexión'),
            ),
          ],
        ),
        if (_probeResult != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_probeResult!,
                style: const TextStyle(fontSize: 13)),
          ),
      ],
    );
  }
}
