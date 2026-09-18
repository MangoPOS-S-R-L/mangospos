import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/session/session_controller.dart';
import '../model/report_column.dart';

/// Vista que el usuario guardó para un tipo de reporte.
class SavedReportView {
  const SavedReportView({
    required this.id,
    required this.name,
    required this.config,
  });

  final String id;
  final String name;
  final ReportViewConfig config;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'config': config.toJson(),
      };

  static SavedReportView? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString();
    final name = raw['name']?.toString();
    final config = ReportViewConfig.fromJson(raw['config']);
    if (id == null || name == null || config == null) return null;
    return SavedReportView(id: id, name: name, config: config);
  }
}

/// Prefijo del id de selección de una vista guardada (los presets usan su
/// id tal cual: `default`, `pareto`, …).
const String savedViewPrefix = 'saved:';

class ReportViewPreferencesState {
  const ReportViewPreferencesState({
    this.active = const {},
    this.selected = const {},
    this.saved = const {},
    this.density = ReportDensity.comfortable,
    this.receiptDetail = false,
  });

  /// Configuración en uso por reporte. En memoria: sobrevive a cambiar el
  /// rango (que no toca esto) pero no a cambiar de tipo, que la restablece.
  final Map<String, ReportViewConfig> active;

  /// Vista elegida por reporte (preset o `saved:<id>`).
  final Map<String, String> selected;

  /// Vistas guardadas por reporte. Persisten por usuario.
  final Map<String, List<SavedReportView>> saved;

  /// Densidad de la tabla. Global: cambiar de tipo o de vista predefinida no
  /// la toca; una vista guardada sí trae la suya.
  final ReportDensity density;

  /// Nivel del reporte por comprobante: resumen por tipo o detalle.
  final bool receiptDetail;

  ReportViewPreferencesState copyWith({
    Map<String, ReportViewConfig>? active,
    Map<String, String>? selected,
    Map<String, List<SavedReportView>>? saved,
    ReportDensity? density,
    bool? receiptDetail,
  }) {
    return ReportViewPreferencesState(
      active: active ?? this.active,
      selected: selected ?? this.selected,
      saved: saved ?? this.saved,
      density: density ?? this.density,
      receiptDetail: receiptDetail ?? this.receiptDetail,
    );
  }

  String selectedViewId(String reportKey) =>
      selected[reportKey] ?? 'default';

  List<SavedReportView> savedFor(String reportKey) =>
      saved[reportKey] ?? const [];

  /// Configuración de una vista (preset o guardada), o null si ya no existe.
  ReportViewConfig? viewConfig(ReportDefinition definition, String viewId) {
    if (viewId.startsWith(savedViewPrefix)) {
      final id = viewId.substring(savedViewPrefix.length);
      for (final view in savedFor(definition.key)) {
        if (view.id == id) return view.config;
      }
      return null;
    }
    return definition.preset(viewId)?.config;
  }

  ReportViewConfig configFor(ReportDefinition definition) =>
      (active[definition.key] ?? definition.defaultConfig)
          .normalizedFor(definition);

  /// True si las columnas, el orden o la agrupación ya no coinciden con la
  /// vista elegida: es cuando aparece "Guardar vista".
  bool isModified(ReportDefinition definition) {
    final base =
        viewConfig(definition, selectedViewId(definition.key)) ??
            definition.defaultConfig;
    return !configFor(definition).sameLayoutAs(base.normalizedFor(definition));
  }
}

class ReportViewPreferencesNotifier
    extends Notifier<ReportViewPreferencesState> {
  static const _prefsKeyPrefix = 'report_views.v1.';

  /// Tope por reporte: las vistas viven en SharedPreferences y ese archivo ya
  /// se infló una vez (34 MB). Unas pocas vistas por reporte son de sobra.
  static const maxSavedPerReport = 12;

  String? _userId;

  @override
  ReportViewPreferencesState build() {
    _userId = ref.watch(sessionProvider.select((s) => s.userId));
    unawaited(_load(_userId));
    return const ReportViewPreferencesState();
  }

  Future<void> _load(String? userId) async {
    if (userId == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_prefsKeyPrefix$userId');
      if (raw == null || _userId != userId) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final saved = <String, List<SavedReportView>>{};
      decoded.forEach((key, value) {
        if (value is! List) return;
        final views = value
            .map(SavedReportView.fromJson)
            .whereType<SavedReportView>()
            .toList(growable: false);
        if (views.isNotEmpty) saved[key.toString()] = views;
      });
      state = state.copyWith(saved: saved);
    } catch (_) {
      // Preferencias ilegibles: se arranca sin vistas guardadas.
    }
  }

  Future<void> _persist() async {
    final userId = _userId;
    if (userId == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = <String, dynamic>{
        for (final entry in state.saved.entries)
          if (entry.value.isNotEmpty)
            entry.key: [for (final view in entry.value) view.toJson()],
      };
      await prefs.setString('$_prefsKeyPrefix$userId', jsonEncode(payload));
    } catch (_) {
      // Sin persistencia: la vista queda en memoria para esta sesión.
    }
  }

  void setConfig(ReportDefinition definition, ReportViewConfig config) {
    state = state.copyWith(active: {
      ...state.active,
      definition.key: config.normalizedFor(definition),
    });
  }

  /// Aplica una vista predefinida o guardada.
  void applyView(ReportDefinition definition, String viewId) {
    final config = state.viewConfig(definition, viewId);
    if (config == null) return;
    state = state.copyWith(
      active: {...state.active, definition.key: config.normalizedFor(definition)},
      selected: {...state.selected, definition.key: viewId},
      density: viewId.startsWith(savedViewPrefix) ? config.density : null,
    );
  }

  /// Toca un encabezado: numéricas arrancan de mayor a menor, texto de A a Z;
  /// el segundo toque invierte y el tercero vuelve al orden de origen.
  void toggleSort(ReportDefinition definition, String columnId) {
    final column = definition.column(columnId);
    if (column == null || !column.sortable) return;
    final config = state.configFor(definition);
    final firstAscending = !column.kind.isNumeric;
    ReportViewConfig next;
    if (config.sortColumn != columnId) {
      next = config.copyWith(
          sortColumn: columnId, sortAscending: firstAscending);
    } else if (config.sortAscending == firstAscending) {
      next = config.copyWith(sortAscending: !firstAscending);
    } else {
      next = config.copyWith(clearSort: true);
    }
    setConfig(definition, next);
  }

  void setGroupBy(ReportDefinition definition, String? columnId) {
    final config = state.configFor(definition);
    setConfig(
      definition,
      columnId == null
          ? config.copyWith(clearGroup: true)
          : config.copyWith(groupBy: columnId),
    );
  }

  void setDensity(ReportDensity density) {
    if (density == state.density) return;
    state = state.copyWith(density: density);
  }

  void setReceiptDetail(bool detail) {
    if (detail == state.receiptDetail) return;
    state = state.copyWith(receiptDetail: detail);
  }

  /// Cambiar de tipo restablece columnas y orden de los reportes indicados.
  void resetReports(Iterable<String> reportKeys) {
    final active = {...state.active};
    final selected = {...state.selected};
    for (final key in reportKeys) {
      active.remove(key);
      selected.remove(key);
    }
    state = state.copyWith(active: active, selected: selected);
  }

  /// Guarda la configuración actual (con la densidad actual) como vista.
  Future<void> saveCurrentView(ReportDefinition definition, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final config =
        state.configFor(definition).copyWith(density: state.density);
    final existing = state.savedFor(definition.key);
    // Mismo nombre → se reemplaza en vez de duplicar.
    final kept = existing
        .where((v) => v.name.toLowerCase() != trimmed.toLowerCase())
        .toList();
    final view = SavedReportView(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: trimmed,
      config: config,
    );
    final views = [...kept, view];
    while (views.length > maxSavedPerReport) {
      views.removeAt(0);
    }
    state = state.copyWith(
      saved: {...state.saved, definition.key: views},
      selected: {
        ...state.selected,
        definition.key: '$savedViewPrefix${view.id}',
      },
    );
    await _persist();
  }

  Future<void> deleteView(ReportDefinition definition, String viewId) async {
    final views = state
        .savedFor(definition.key)
        .where((v) => v.id != viewId)
        .toList(growable: false);
    final selected = {...state.selected};
    if (selected[definition.key] == '$savedViewPrefix$viewId') {
      // La configuración en uso se queda; solo deja de estar "guardada".
      selected.remove(definition.key);
    }
    state = state.copyWith(
      saved: {...state.saved, definition.key: views},
      selected: selected,
    );
    await _persist();
  }
}

final reportViewPreferencesProvider = NotifierProvider<
    ReportViewPreferencesNotifier, ReportViewPreferencesState>(
  ReportViewPreferencesNotifier.new,
);
