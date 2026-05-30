// PRD 5 F5.3 — Pantalla de diagnóstico de impresión.
//
// Muestra al admin/cajero el estado vivo del sistema de impresión:
//   1. Identidad de este dispositivo (device_id, hardware_id, adopción).
//   2. Agente local (URL, alcanzable, last heartbeat).
//   3. Devices del business actuando como hosts (device_agents).
//   4. Impresoras del business con estado online/offline + last heartbeat.
//
// Cuando algo falla en cocina, el operador puede entrar acá y saber
// exactamente qué pieza está mal sin pedir soporte técnico.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/core/printing/agent_discovery.dart';
import 'package:mangopos/core/printing/device_identity.dart';
import 'package:mangopos/core/services/local_print_service.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/services/print_agent_detector.dart';

class PrintingDiagnosticsView extends ConsumerStatefulWidget {
  const PrintingDiagnosticsView({super.key, this.businessId = 'auto'});

  final String businessId;

  @override
  ConsumerState<PrintingDiagnosticsView> createState() =>
      _PrintingDiagnosticsViewState();
}

class _PrintingDiagnosticsViewState
    extends ConsumerState<PrintingDiagnosticsView> {
  bool _loading = true;
  String? _businessId;
  String? _deviceId;
  String? _hardwareId;
  bool _hwAdopted = false;

  String? _localAgentUrl;
  bool _localAgentReachable = false;

  List<Map<String, dynamic>> _deviceAgents = const [];

  // Sprint 2.3 — Hubs detectados por mDNS en la LAN. La primera vez
  // muestra lo que main.dart ya cacheó al arrancar; el botón "Re-escanear"
  // dispara un scan fresco.
  List<DiscoveredAgent> _lanHubs = const [];
  DateTime? _lanScanAt;
  bool _scanningLan = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final bid = await BusinessResolver.ensure(widget.businessId);
      final deviceId = await DeviceIdentity.getOrCreateId(bid);
      final hwId = await DeviceIdentity.readHardwareId();
      final hwAdopted = await DeviceIdentity.isUsingHardwareId(bid);

      // Agente local
      String? agentUrl;
      bool reachable = false;
      try {
        final detector = PrintAgentDetector();
        agentUrl = await detector.scanLocalFirst();
        if (agentUrl != null) {
          final status = await detector.testAgent(agentUrl);
          reachable = status.ok;
        }
      } catch (_) {}

      // device_agents del business
      List<Map<String, dynamic>> agents = const [];
      try {
        final rows = await Supabase.instance.client
            .from('device_agents')
            .select(
              'id, device_name, agent_url, platform, online, last_heartbeat_at, updated_at',
            )
            .eq('business_id', bid)
            .order('updated_at', ascending: false);
        agents = List<Map<String, dynamic>>.from(rows as List);
      } catch (_) {}

      // Cargar impresoras (usa el viewmodel existente que ya tiene cache)
      await ref
          .read(printingPrintersViewModelProvider.notifier)
          .load(businessId: widget.businessId);

      if (!mounted) return;
      setState(() {
        _businessId = bid;
        _deviceId = deviceId;
        _hardwareId = hwId;
        _hwAdopted = hwAdopted;
        _localAgentUrl = agentUrl;
        _localAgentReachable = reachable;
        _deviceAgents = agents;
        _lanHubs = LocalPrintService.lastDiscoveredAgents;
        _lanScanAt = LocalPrintService.lastDiscoveredAt;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// Sprint 2.3 — Re-escanea la LAN buscando hubs vía mDNS. Dispara
  /// `LocalPrintService.discoverAndPrime` con el filtro del negocio
  /// actual para excluir hubs de otros locales (food court / coworking).
  Future<void> _rescanLanHubs() async {
    if (_scanningLan) return;
    setState(() => _scanningLan = true);
    try {
      final hubs = await LocalPrintService.discoverAndPrime(
        businessIdFilter: _businessId,
      );
      if (!mounted) return;
      setState(() {
        _lanHubs = hubs;
        _lanScanAt = LocalPrintService.lastDiscoveredAt;
      });
      // Re-evaluar el estado del agente local — si encontró 1 hub,
      // discoverAndPrime ya primió la URL, y la card de arriba debe
      // mostrarla como operativa.
      await _load();
    } finally {
      if (mounted) {
        setState(() => _scanningLan = false);
      }
    }
  }

  /// Sprint 2.3 — Marca un hub específico como el activo. Prima la URL
  /// localmente y, si el cajero pidió "compartir", la publica en
  /// `business_settings.agent_url` para que otras tablets también lo
  /// usen.
  Future<void> _useHub(DiscoveredAgent agent, {bool publish = false}) async {
    LocalPrintService.primeBaseUrl(agent.baseUrl);
    if (publish && _businessId != null && _businessId!.isNotEmpty) {
      await LocalPrintService.publishAgentUrl(agent.baseUrl, _businessId!);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          publish
              ? 'Hub activado y compartido con el negocio: ${agent.baseUrl}'
              : 'Hub activado en este dispositivo: ${agent.baseUrl}',
        ),
        backgroundColor: const Color(0xFF22C55E),
      ),
    );
    await _load();
  }

  /// Sprint 2.3 — Fallback manual: mDNS bloqueado por router corporativo,
  /// o el cajero ya sabe la IP. Pide IP/puerto, valida formato y prima
  /// la URL como hub activo.
  Future<void> _enterManualHub() async {
    final ipController = TextEditingController();
    final portController = TextEditingController(text: '4000');
    bool publishToBusiness = false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Ingresar IP del hub manualmente'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ipController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'IP o hostname',
                  hintText: '192.168.1.50',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: portController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Puerto',
                  hintText: '4000',
                ),
              ),
              const SizedBox(height: 12),
              if (_businessId != null && _businessId!.isNotEmpty)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: publishToBusiness,
                  onChanged: (v) =>
                      setLocal(() => publishToBusiness = v ?? false),
                  title: const Text(
                    'Compartir con todas las tablets del negocio',
                    style: TextStyle(fontSize: 13),
                  ),
                  subtitle: const Text(
                    'Guarda esta URL en business_settings para que otros dispositivos también la usen.',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Activar'),
            ),
          ],
        ),
      ),
    );

    if (saved != true) return;
    final ip = ipController.text.trim();
    final port = int.tryParse(portController.text.trim()) ?? 4000;
    if (ip.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('IP requerida.')),
        );
      }
      return;
    }
    final url = 'http://$ip:$port';
    LocalPrintService.primeBaseUrl(url);
    if (publishToBusiness && _businessId != null && _businessId!.isNotEmpty) {
      await LocalPrintService.publishAgentUrl(url, _businessId!);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Hub manual activado: $url'),
        backgroundColor: const Color(0xFF22C55E),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final printers = ref.watch(printingPrintersViewModelProvider);
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.6,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Regresar',
          onPressed: () => context.go(AppRoutes.settings),
        ),
        title: const Text('Diagnóstico de impresión'),
      ),
      body: RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _SectionTitle('Identidad de este dispositivo'),
          const SizedBox(height: 8),
          _IdentityCard(
            deviceId: _deviceId,
            hardwareId: _hardwareId,
            hardwareAdopted: _hwAdopted,
            businessId: _businessId,
          ),

          const SizedBox(height: 24),
          _SectionTitle('Agente de impresión local'),
          const SizedBox(height: 8),
          _LocalAgentCard(
            url: _localAgentUrl,
            reachable: _localAgentReachable,
            loading: _loading,
            onRetest: _load,
          ),

          const SizedBox(height: 24),
          _SectionTitle('Hubs en la LAN (mDNS)'),
          Text(
            'Print agents que se anuncian automáticamente. Si hay varios '
            '(multi-caja / food court), elige cuál usar.',
            style: TextStyle(fontSize: 12, color: MangoColors.muted),
          ),
          const SizedBox(height: 8),
          _LanHubsCard(
            hubs: _lanHubs,
            lastScanAt: _lanScanAt,
            scanning: _scanningLan,
            activeBaseUrl: _localAgentUrl,
            onRescan: _rescanLanHubs,
            onUseHub: _useHub,
            onManualEntry: _enterManualHub,
          ),

          const SizedBox(height: 24),
          _SectionTitle('Otros dispositivos del negocio'),
          Text(
            'Devices que actúan como host de impresoras locales (USB/BT) compartidas.',
            style: TextStyle(fontSize: 12, color: MangoColors.muted),
          ),
          const SizedBox(height: 8),
          if (_loading && _deviceAgents.isEmpty)
            const _LoadingTile()
          else if (_deviceAgents.isEmpty)
            const _EmptyTile('Aún no hay devices registrados como host.')
          else
            ..._deviceAgents.map((a) => _DeviceAgentTile(data: a)),

          const SizedBox(height: 24),
          _SectionTitle('Impresoras'),
          const SizedBox(height: 8),
          if (_loading && printers.items.isEmpty)
            const _LoadingTile()
          else if (printers.items.isEmpty)
            const _EmptyTile('No hay impresoras configuradas.')
          else
            ...printers.items.map(
              (p) => _PrinterStatusTile(
                printer: p,
                hostName: _hostNameFor(p.hostDeviceId),
                isLocalHost: p.hostDeviceId == _deviceId,
              ),
            ),
        ],
      ),
      ),
    );
  }

  String? _hostNameFor(String? hostDeviceId) {
    if (hostDeviceId == null || hostDeviceId.isEmpty) return null;
    for (final a in _deviceAgents) {
      if (a['id'] == hostDeviceId) return a['device_name'] as String?;
    }
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────
// Widgets
// ─────────────────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: MangoColors.darkGray,
        ),
      );
}

class _IdentityCard extends StatelessWidget {
  final String? deviceId;
  final String? hardwareId;
  final bool hardwareAdopted;
  final String? businessId;

  const _IdentityCard({
    required this.deviceId,
    required this.hardwareId,
    required this.hardwareAdopted,
    required this.businessId,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv('Device ID actual', deviceId ?? '—'),
          _kv(
            'UUID de hardware',
            hardwareId ?? 'No disponible en esta plataforma',
          ),
          _kv('Adoptado de hardware', hardwareAdopted ? 'Sí' : 'No'),
          _kv('Business ID', businessId ?? '—'),
          if (hardwareId != null && !hardwareAdopted) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFED7AA)),
              ),
              child: const Text(
                'Recomendación: adoptar el UUID de hardware desde la pestaña '
                '"Impresoras". Sobrevive reinstalaciones del binario.',
                style: TextStyle(fontSize: 12, color: MangoColors.darkGray),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 180,
              child: Text(
                k,
                style: const TextStyle(
                  fontSize: 13,
                  color: MangoColors.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: SelectableText(
                v,
                style: const TextStyle(
                  fontSize: 13,
                  color: MangoColors.darkGray,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      );
}

class _LocalAgentCard extends StatelessWidget {
  final String? url;
  final bool reachable;
  final bool loading;
  final VoidCallback onRetest;

  const _LocalAgentCard({
    required this.url,
    required this.reachable,
    required this.loading,
    required this.onRetest,
  });

  @override
  Widget build(BuildContext context) {
    final status = url == null
        ? ('No detectado', const Color(0xFFEF4444))
        : reachable
            ? ('Operativo', const Color(0xFF22C55E))
            : ('Detectado pero no responde', const Color(0xFFF59F0A));
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: status.$2, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status.$1,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: MangoColors.darkGray,
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  url ?? 'Inicia el agente local en esta máquina.',
                  style: const TextStyle(
                    fontSize: 12,
                    color: MangoColors.muted,
                  ),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: loading ? null : onRetest,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Reintentar'),
          ),
        ],
      ),
    );
  }
}

class _LanHubsCard extends StatelessWidget {
  final List<DiscoveredAgent> hubs;
  final DateTime? lastScanAt;
  final bool scanning;

  /// URL del hub actualmente primado. Sirve para marcar visualmente
  /// cuál de la lista está en uso.
  final String? activeBaseUrl;

  final VoidCallback onRescan;
  final Future<void> Function(DiscoveredAgent agent, {bool publish}) onUseHub;
  final VoidCallback onManualEntry;

  const _LanHubsCard({
    required this.hubs,
    required this.lastScanAt,
    required this.scanning,
    required this.activeBaseUrl,
    required this.onRescan,
    required this.onUseHub,
    required this.onManualEntry,
  });

  String _scanLabel() {
    if (lastScanAt == null) return 'Sin escaneos aún';
    final secs = DateTime.now().difference(lastScanAt!).inSeconds;
    if (secs < 5) return 'Recién escaneado';
    if (secs < 60) return 'Hace ${secs}s';
    final mins = secs ~/ 60;
    return 'Hace ${mins}m';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${hubs.length} hub(s) detectado(s) · ${_scanLabel()}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: MangoColors.darkGray,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: scanning ? null : onRescan,
                icon: scanning
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 16),
                label: Text(scanning ? 'Escaneando...' : 'Re-escanear LAN'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (hubs.isEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFBEB),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFDE68A)),
              ),
              child: const Text(
                'Ningún hub se anunció. Puede ser que mDNS esté bloqueado '
                'por el router o que no haya un agent corriendo en la LAN. '
                'Usa "Ingresar IP manualmente" para configurar el hub a mano.',
                style: TextStyle(fontSize: 12, color: MangoColors.darkGray),
              ),
            )
          else
            ...hubs.map(
              (h) => _HubTile(
                agent: h,
                active: activeBaseUrl == h.baseUrl,
                onUse: () => onUseHub(h, publish: false),
                onUseAndShare: () => onUseHub(h, publish: true),
              ),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onManualEntry,
              icon: const Icon(Icons.edit, size: 16),
              label: const Text('Ingresar IP manualmente'),
            ),
          ),
        ],
      ),
    );
  }
}

class _HubTile extends StatelessWidget {
  final DiscoveredAgent agent;
  final bool active;
  final VoidCallback onUse;
  final VoidCallback onUseAndShare;

  const _HubTile({
    required this.agent,
    required this.active,
    required this.onUse,
    required this.onUseAndShare,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: active ? const Color(0xFFEFFDF4) : const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: active ? const Color(0xFF22C55E) : MangoColors.cardBorder,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            active ? Icons.check_circle : Icons.dns,
            size: 18,
            color: active ? const Color(0xFF22C55E) : MangoColors.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  agent.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: MangoColors.darkGray,
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  agent.baseUrl,
                  style: const TextStyle(
                    fontSize: 12,
                    color: MangoColors.muted,
                  ),
                ),
                if (agent.version != null || agent.cloudQueue)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 6,
                      children: [
                        if (agent.version != null)
                          _Chip(
                            label: 'v${agent.version}',
                            color: const Color(0xFFFFEDD5),
                            text: const Color(0xFF9A3412),
                          ),
                        if (agent.cloudQueue)
                          const _Chip(
                            label: 'cloud queue',
                            color: Color(0xFFDCFCE7),
                            text: Color(0xFF166534),
                          ),
                      ],
                    ),
                  ),
                if (active)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'En uso en este dispositivo',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFF166534),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Activar este hub',
            onSelected: (v) {
              if (v == 'use') onUse();
              if (v == 'share') onUseAndShare();
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                value: 'use',
                child: Text('Usar solo en este dispositivo'),
              ),
              PopupMenuItem(
                value: 'share',
                child: Text('Usar y compartir con el negocio'),
              ),
            ],
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFF97316),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Activar',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Icon(Icons.arrow_drop_down, color: Colors.white, size: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  final Color text;
  const _Chip({required this.label, required this.color, required this.text});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: text,
        ),
      ),
    );
  }
}

class _DeviceAgentTile extends StatelessWidget {
  final Map<String, dynamic> data;
  const _DeviceAgentTile({required this.data});

  @override
  Widget build(BuildContext context) {
    final name = data['device_name']?.toString() ?? 'Sin nombre';
    final platform = data['platform']?.toString() ?? '—';
    final agentUrl = data['agent_url']?.toString() ?? '—';
    final online = data['online'] == true;
    final lastHb = _formatTimestamp(data['last_heartbeat_at']);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: online ? const Color(0xFF22C55E) : MangoColors.muted,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$name · $platform',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: MangoColors.darkGray,
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  agentUrl,
                  style: const TextStyle(
                    fontSize: 12,
                    color: MangoColors.muted,
                  ),
                ),
                if (lastHb != null)
                  Text(
                    'Último heartbeat: $lastHb',
                    style: const TextStyle(
                      fontSize: 11,
                      color: MangoColors.muted,
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

class _PrinterStatusTile extends StatelessWidget {
  final PrinterDevice printer;
  final String? hostName;
  final bool isLocalHost;
  const _PrinterStatusTile({
    required this.printer,
    required this.hostName,
    required this.isLocalHost,
  });

  @override
  Widget build(BuildContext context) {
    final color = printer.online
        ? const Color(0xFF22C55E)
        : const Color(0xFFEF4444);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  printer.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: MangoColors.darkGray,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${printer.type.name.toUpperCase()} · ${printer.online ? "Online" : "Offline"}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: MangoColors.muted,
                  ),
                ),
                if (printer.hostDeviceId != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    isLocalHost
                        ? 'Hosteada por este device'
                        : 'Hosteada por: ${hostName ?? printer.hostDeviceId}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: MangoColors.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingTile extends StatelessWidget {
  const _LoadingTile();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(20),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: MangoColors.cardBorder),
        ),
        child: const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
}

class _EmptyTile extends StatelessWidget {
  final String text;
  const _EmptyTile(this.text);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: MangoColors.cardBorder),
        ),
        child: Text(
          text,
          style: const TextStyle(fontSize: 13, color: MangoColors.muted),
        ),
      );
}

String? _formatTimestamp(dynamic raw) {
  if (raw == null) return null;
  try {
    final dt = DateTime.parse(raw.toString()).toLocal();
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    final age = DateTime.now().difference(dt);
    final ageLabel = age.inMinutes < 1
        ? 'hace ${age.inSeconds}s'
        : age.inHours < 1
            ? 'hace ${age.inMinutes}min'
            : 'hace ${age.inHours}h';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} $h:$m:$s ($ageLabel)';
  } catch (_) {
    return raw.toString();
  }
}
