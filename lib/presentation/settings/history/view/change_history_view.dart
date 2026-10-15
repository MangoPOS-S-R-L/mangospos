import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/currency/business_currency_provider.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/utils/app_time.dart';
import 'package:mangopos/data/models/change_history_entry.dart';
import 'package:mangopos/data/repositories/change_history_repository.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';
import 'package:mangopos/services/session/session_controller.dart';

import '../change_history_text.dart';

/// Ajustes → Historial.
///
/// Todo lo que se crea, cambia o borra en el negocio, quién lo hizo y cuándo
/// (tabla `change_history`, migraciones 20261013_0001/0002). Lo llena la base
/// de datos sola; aquí solo se lee. Solo dueño y administradores: la RLS no
/// le devuelve nada a nadie más.
class ChangeHistoryView extends ConsumerStatefulWidget {
  const ChangeHistoryView({super.key});

  @override
  ConsumerState<ChangeHistoryView> createState() => _ChangeHistoryViewState();
}

class _ChangeHistoryViewState extends ConsumerState<ChangeHistoryView> {
  final _search = TextEditingController();
  Timer? _debounce;

  List<ChangeHistoryEntry> _entries = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  bool _notActivated = false;
  String? _error;
  String _area = 'all';
  String? _action;

  /// Cada carga nueva invalida las que siguen en vuelo (filtro cambiado).
  int _request = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<String?> _businessId() async {
    final fromSession = ref.read(sessionProvider).activeBusinessId;
    if (fromSession != null && fromSession.isNotEmpty) return fromSession;
    return resolveBusinessIdOrNull(Supabase.instance.client, 'auto');
  }

  Future<void> _load({bool more = false, bool silent = false}) async {
    if (!mounted) return;
    final request = ++_request;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else if (!silent || _entries.isEmpty) {
        _loading = true;
      }
      _error = null;
    });
    try {
      final businessId = await _businessId();
      if (businessId == null) {
        throw StateError('No se pudo identificar el negocio.');
      }
      final area = historyAreas.firstWhere(
        (a) => a.key == _area,
        orElse: () => historyAreas.first,
      );
      final page = await ref
          .read(changeHistoryRepositoryProvider)
          .loadPage(
            businessId: businessId,
            offset: more ? _entries.length : 0,
            tables: area.tables,
            action: _action,
            search: _search.text,
          );
      if (!mounted || request != _request) return;
      setState(() {
        _entries = more ? [..._entries, ...page] : page;
        _hasMore = page.length == ChangeHistoryRepository.pageSize;
        _loading = false;
        _loadingMore = false;
        _notActivated = false;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _notActivated = ChangeHistoryRepository.isNotActivated(e);
        _error = _notActivated
            ? null
            : e is StateError
            ? e.message
            : ChangeHistoryRepository.humanizeError(e);
      });
    }
  }

  void _setArea(String area) {
    if (area == _area) return;
    setState(() => _area = area);
    _load();
  }

  void _setAction(String? action) {
    if (action == _action) return;
    setState(() => _action = action);
    _load();
  }

  void _onSearchChanged(String _) {
    setState(() {}); // muestra u oculta la X
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _load);
  }

  void _clearSearch() {
    _debounce?.cancel();
    _search.clear();
    setState(() {});
    _load();
  }

  bool get _hasFilters =>
      _area != 'all' || _action != null || _search.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final businessName = ref.watch(
      sessionProvider.select((s) => s.activeBusinessName),
    );
    final currency = currentBusinessCurrencyOrFallback(ref);
    final reader = HistoryText(money: currency.formatter.format);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.6,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Regresar',
          onPressed: () => Navigator.of(context).canPop()
              ? Navigator.of(context).pop()
              : context.go(AppRoutes.settings),
        ),
        title: const Text('Historial'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _load(silent: true),
            tooltip: 'Actualizar',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(silent: true),
        color: MangoColors.primaryOrange,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.all(16),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                _Intro(businessName: businessName),
                const SizedBox(height: 12),
                TextField(
                  controller: _search,
                  onChanged: _onSearchChanged,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Buscar producto, mesa, caja o persona…',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Borrar búsqueda',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: _clearSearch,
                          ),
                    filled: true,
                    fillColor: AppColors.card,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _ChipWrap(
                  children: [
                    for (final area in historyAreas)
                      _FilterChip(
                        label: area.label,
                        selected: _area == area.key,
                        onTap: () => _setArea(area.key),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                _ChipWrap(
                  children: [
                    for (final (value, label) in historyActions)
                      _FilterChip(
                        label: label,
                        selected: _action == value,
                        onTap: () => _setAction(value),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                ..._body(reader),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _body(HistoryText reader) {
    if (_notActivated) {
      return const [
        _Message(
          icon: Icons.history_toggle_off_rounded,
          title: 'El historial no está activado',
          message:
              'Todavía no está encendido en el servidor. Escríbele a '
              'soporte de MangoPOS para activarlo.',
        ),
      ];
    }
    if (_loading && _entries.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(
            child: CircularProgressIndicator(color: MangoColors.primaryOrange),
          ),
        ),
      ];
    }
    if (_error != null && _entries.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Column(
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.destructive),
              ),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _load, child: const Text('Reintentar')),
            ],
          ),
        ),
      ];
    }
    if (_entries.isEmpty) {
      return [
        _Message(
          icon: Icons.history_rounded,
          title: _hasFilters
              ? 'No hay cambios con ese filtro'
              : 'Todavía no hay cambios',
          message: _hasFilters
              ? 'Prueba con otra búsqueda o vuelve a «Todo».'
              : 'Desde ahora, todo lo que se cree, cambie o borre queda aquí.',
        ),
      ];
    }

    final now = AppTime.nowAst();
    final out = <Widget>[];
    String? day;
    for (final entry in _entries) {
      final label = historyDayLabel(entry.changedAt, now: now);
      if (label != day) {
        day = label;
        out.add(_DayHeader(label: label));
      }
      out.add(
        _HistoryTile(key: ValueKey(entry.id), entry: entry, reader: reader),
      );
    }
    if (_hasMore || _loadingMore) {
      out.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: _loadingMore
                ? const SizedBox(
                    height: 28,
                    width: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: AppColors.primary,
                    ),
                  )
                : OutlinedButton.icon(
                    onPressed: () => _load(more: true),
                    icon: const Icon(Icons.expand_more_rounded, size: 18),
                    label: const Text('Ver más'),
                  ),
          ),
        ),
      );
    }
    return out;
  }
}

class _Intro extends StatelessWidget {
  final String? businessName;

  const _Intro({required this.businessName});

  @override
  Widget build(BuildContext context) {
    final where = (businessName == null || businessName!.trim().isEmpty)
        ? 'el negocio'
        : businessName!.trim();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.infoSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.infoBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, color: AppColors.info, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Todo lo que se crea, cambia o borra en $where: quién lo hizo '
              'y cuándo. Nadie lo puede editar ni borrar, ni siquiera el '
              'dueño.',
              style: const TextStyle(color: AppColors.foreground, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChipWrap extends StatelessWidget {
  final List<Widget> children;

  const _ChipWrap({required this.children});

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 8, runSpacing: 8, children: children);
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
      selectedColor: MangoColors.primaryOrange.withValues(alpha: 0.18),
      labelStyle: TextStyle(
        color: selected ? MangoColors.primaryOrange : MangoColors.darkGray,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: selected ? MangoColors.primaryOrange : MangoColors.cardBorder,
        ),
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  final String label;

  const _DayHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: AppColors.mutedForeground,
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const _Message({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Icon(icon, size: 40, color: AppColors.mutedForeground),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.mutedForeground),
          ),
        ],
      ),
    );
  }
}

/// Una línea del historial. Las ediciones muestran antes → después de una
/// vez; lo creado, borrado o anulado guarda la foto detrás de «Ver detalles».
class _HistoryTile extends StatefulWidget {
  final ChangeHistoryEntry entry;
  final HistoryText reader;

  const _HistoryTile({super.key, required this.entry, required this.reader});

  @override
  State<_HistoryTile> createState() => _HistoryTileState();
}

class _HistoryTileState extends State<_HistoryTile> {
  late bool _open = widget.entry.action == 'update';

  static Color _color(String action) => switch (action) {
    'create' => AppColors.success,
    'update' => AppColors.warning,
    _ => AppColors.destructive,
  };

  static IconData _icon(String action) => switch (action) {
    'create' => Icons.add_rounded,
    'update' => Icons.edit_rounded,
    'void' => Icons.block_rounded,
    _ => Icons.delete_outline_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final lines = widget.reader.details(e);
    final canToggle = lines.isNotEmpty && e.action != 'update';
    final area = historyAreaLabel(e.tableName);
    final color = _color(e.action);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: canToggle ? () => setState(() => _open = !_open) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(_icon(e.action), size: 18, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.reader.sentence(e),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.foreground,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          historyTime(e.changedAt),
                          if (area.isNotEmpty) area,
                        ].join(' · '),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.mutedForeground,
                        ),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 180),
                        alignment: Alignment.topLeft,
                        child: !_open || lines.isEmpty
                            ? const SizedBox(width: double.infinity)
                            : Container(
                                width: double.infinity,
                                margin: const EdgeInsets.only(top: 8),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: AppColors.secondary,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    for (final line in lines)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 2,
                                        ),
                                        child: _LineText(line: line),
                                      ),
                                  ],
                                ),
                              ),
                      ),
                      if (canToggle)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            _open
                                ? 'Ocultar detalles'
                                : e.action == 'delete'
                                ? 'Ver lo que se borró'
                                : 'Ver detalles',
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: MangoColors.primaryOrange,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LineText extends StatelessWidget {
  final HistoryLine line;

  const _LineText({required this.line});

  @override
  Widget build(BuildContext context) {
    const base = TextStyle(fontSize: 13, color: AppColors.foreground);
    final strong = base.copyWith(fontWeight: FontWeight.w700);
    final muted = base.copyWith(color: AppColors.mutedForeground);
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(
            text: line.field.isEmpty ? '•  ' : '${line.field}: ',
            style: strong,
          ),
          if (line.isChange) ...[
            TextSpan(text: line.before, style: muted),
            TextSpan(text: '  →  ', style: muted),
            TextSpan(text: line.after, style: strong),
          ] else
            TextSpan(text: line.before),
        ],
      ),
    );
  }
}
