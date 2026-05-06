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
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/core/printing/device_identity.dart';
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
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final printers = ref.watch(printingPrintersViewModelProvider);
    return RefreshIndicator(
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
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFBFDBFE)),
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
