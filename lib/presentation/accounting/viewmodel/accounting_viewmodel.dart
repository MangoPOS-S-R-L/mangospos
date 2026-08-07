import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/data/models/accounting_models.dart';
import 'package:mangopos/data/repositories/accounting_repository.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';

final accountingRepositoryProvider = Provider<AccountingRepository>((ref) {
  return AccountingRepository(Supabase.instance.client);
});

final accountingViewModelProvider =
    ChangeNotifierProvider<AccountingViewModel>((ref) {
  return AccountingViewModel(ref.read(accountingRepositoryProvider));
});

/// Estado del módulo contable.
///
/// El rango de fechas es compartido por todas las pestañas (diario, mayor,
/// balanza, resultados); el balance general usa solo el `to` como fecha de
/// corte. Cada pestaña carga bajo demanda para no traer cinco reportes en el
/// primer frame.
class AccountingViewModel extends ChangeNotifier {
  final AccountingRepository _repository;

  AccountingViewModel(this._repository) {
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, 1);
    _to = DateTime(now.year, now.month + 1, 0);
  }

  String? _businessId;
  bool _isLoading = false;
  bool _isBusy = false;
  String? _error;
  bool _initialized = false;

  late DateTime _from;
  late DateTime _to;

  List<AccountingAccount> _accounts = const [];
  List<AccountingCostCenter> _costCenters = const [];
  List<AccountingPeriod> _periods = const [];
  List<AccountingEntry> _entries = const [];
  List<Map<String, dynamic>> _mappings = const [];

  List<Map<String, dynamic>> _trialBalance = const [];
  List<Map<String, dynamic>> _incomeStatement = const [];
  List<Map<String, dynamic>> _balanceSheet = const [];
  List<Map<String, dynamic>> _ledger = const [];
  String? _ledgerAccountId;

  String? get businessId => _businessId;
  bool get isLoading => _isLoading;
  bool get isBusy => _isBusy;
  String? get error => _error;
  bool get initialized => _initialized;
  DateTime get from => _from;
  DateTime get to => _to;

  List<AccountingAccount> get accounts => _accounts;
  List<AccountingAccount> get postableAccounts =>
      _accounts.where((a) => a.isPostable && a.isActive).toList();
  List<AccountingCostCenter> get costCenters => _costCenters;
  List<AccountingPeriod> get periods => _periods;
  List<AccountingEntry> get entries => _entries;
  List<Map<String, dynamic>> get mappings => _mappings;
  List<Map<String, dynamic>> get trialBalance => _trialBalance;
  List<Map<String, dynamic>> get incomeStatement => _incomeStatement;
  List<Map<String, dynamic>> get balanceSheet => _balanceSheet;
  List<Map<String, dynamic>> get ledger => _ledger;
  String? get ledgerAccountId => _ledgerAccountId;

  /// ¿El mes en el que cae `to` está cerrado? Lo usa la UI para avisar antes
  /// de que la BD rechace con PERIOD_CLOSED.
  bool get isCurrentRangeClosed => _periods.any(
      (p) => p.year == _to.year && p.month == _to.month && p.isClosed);

  // ── Ciclo de vida ─────────────────────────────────────────────────────────

  Future<void> init() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _businessId =
          await resolveBusinessIdOrNull(Supabase.instance.client, 'auto');
      if (_businessId != null) {
        _initialized = await _repository.isInitialized(_businessId!);
        if (_initialized) await _loadCore();
      }
    } catch (e) {
      _error = _friendly(e);
      debugPrint('Contabilidad init: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> reload() async {
    if (_businessId == null) return init();
    _isLoading = true;
    notifyListeners();
    try {
      _initialized = await _repository.isInitialized(_businessId!);
      if (_initialized) await _loadCore();
      _error = null;
    } catch (e) {
      _error = _friendly(e);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _loadCore() async {
    final bid = _businessId!;
    final results = await Future.wait([
      _repository.getAccounts(bid),
      _repository.getCostCenters(bid),
      _repository.getPeriods(bid),
      _repository.getEntries(bid, from: _from, to: _to),
    ]);
    _accounts = results[0] as List<AccountingAccount>;
    _costCenters = results[1] as List<AccountingCostCenter>;
    _periods = results[2] as List<AccountingPeriod>;
    _entries = results[3] as List<AccountingEntry>;
  }

  void setRange(DateTime from, DateTime to) {
    _from = DateTime(from.year, from.month, from.day);
    _to = DateTime(to.year, to.month, to.day);
    // Los reportes cacheados dejan de valer con otro rango.
    _trialBalance = const [];
    _incomeStatement = const [];
    _balanceSheet = const [];
    _ledger = const [];
    notifyListeners();
    reload();
  }

  // ── Inicialización del catálogo ───────────────────────────────────────────

  Future<String?> seedChart() async {
    final bid = _businessId;
    if (bid == null) return 'No hay negocio activo.';
    return _run(() async {
      final res = await _repository.seedChart(bid);
      _initialized = true;
      await _loadCore();
      return 'Catálogo listo: ${res['accounts_created'] ?? 0} cuentas creadas.';
    });
  }

  // ── Asientos ──────────────────────────────────────────────────────────────

  Future<String?> generateAutomatic() async {
    final bid = _businessId;
    if (bid == null) return 'No hay negocio activo.';
    return _run(() async {
      final res = await _repository.generateAutomatic(
          businessId: bid, from: _from, to: _to);
      await _loadCore();
      await _refreshLoadedReports();
      final total = (res['total'] as num?)?.toInt() ?? 0;
      if (total == 0) {
        return 'Sin novedades: el rango ya estaba asentado.';
      }
      return 'Generados $total asientos '
          '(ventas ${res['sales']}, compras ${res['purchases']}, '
          'caja ${res['cash']}, créditos ${res['credits']}).';
    });
  }

  Future<String?> postEntry({
    required DateTime date,
    required String description,
    required List<JournalLineDraft> lines,
    String? reference,
  }) async {
    final bid = _businessId;
    if (bid == null) return 'No hay negocio activo.';
    return _run(() async {
      await _repository.postEntry(
        businessId: bid,
        date: date,
        description: description,
        lines: lines,
        reference: reference,
      );
      await _loadCore();
      await _refreshLoadedReports();
      return 'Asiento registrado.';
    });
  }

  Future<String?> reverseEntry(String entryId, {String? reason}) async {
    return _run(() async {
      await _repository.reverseEntry(entryId: entryId, reason: reason);
      await _loadCore();
      await _refreshLoadedReports();
      return 'Asiento revertido.';
    });
  }

  Future<List<Map<String, dynamic>>> entryLines(String entryId) =>
      _repository.getEntryLines(entryId);

  // ── Períodos ──────────────────────────────────────────────────────────────

  Future<String?> setPeriodStatus(int year, int month, String status) async {
    final bid = _businessId;
    if (bid == null) return 'No hay negocio activo.';
    return _run(() async {
      await _repository.setPeriodStatus(
          businessId: bid, year: year, month: month, status: status);
      _periods = await _repository.getPeriods(bid);
      return status == 'closed' ? 'Período cerrado.' : 'Período reabierto.';
    });
  }

  // ── Catálogo ──────────────────────────────────────────────────────────────

  Future<String?> saveAccount({
    String? id,
    required String code,
    required String name,
    required String accountType,
    String? parentId,
    bool isPostable = true,
    bool isActive = true,
  }) async {
    final bid = _businessId;
    if (bid == null) return 'No hay negocio activo.';
    return _run(() async {
      await _repository.upsertAccount(
        businessId: bid,
        id: id,
        code: code,
        name: name,
        accountType: accountType,
        parentId: parentId,
        isPostable: isPostable,
        isActive: isActive,
      );
      _accounts = await _repository.getAccounts(bid);
      return 'Cuenta guardada.';
    });
  }

  Future<String?> toggleAccount(AccountingAccount account) async {
    final bid = _businessId;
    if (bid == null) return 'No hay negocio activo.';
    return _run(() async {
      await _repository.setAccountActive(account.id, !account.isActive);
      _accounts = await _repository.getAccounts(bid);
      return account.isActive ? 'Cuenta desactivada.' : 'Cuenta activada.';
    });
  }

  Future<String?> saveCostCenter({
    String? id,
    required String code,
    required String name,
    required String kind,
    bool isActive = true,
  }) async {
    final bid = _businessId;
    if (bid == null) return 'No hay negocio activo.';
    return _run(() async {
      await _repository.upsertCostCenter(
        businessId: bid,
        id: id,
        code: code,
        name: name,
        kind: kind,
        isActive: isActive,
      );
      _costCenters = await _repository.getCostCenters(bid);
      return 'Centro de costo guardado.';
    });
  }

  Future<void> loadMappings() async {
    final bid = _businessId;
    if (bid == null) return;
    _mappings = await _repository.getMappings(bid);
    notifyListeners();
  }

  Future<String?> setMapping(String eventKey, String accountId) async {
    final bid = _businessId;
    if (bid == null) return 'No hay negocio activo.';
    return _run(() async {
      await _repository.setMapping(
          businessId: bid, eventKey: eventKey, accountId: accountId);
      _mappings = await _repository.getMappings(bid);
      return 'Mapeo actualizado.';
    });
  }

  // ── Reportes (carga bajo demanda) ─────────────────────────────────────────

  Future<void> loadTrialBalance({String? costCenterId}) async {
    final bid = _businessId;
    if (bid == null) return;
    await _loadReport(() async {
      _trialBalance = await _repository.trialBalance(
          businessId: bid, from: _from, to: _to, costCenterId: costCenterId);
    });
  }

  Future<void> loadIncomeStatement() async {
    final bid = _businessId;
    if (bid == null) return;
    await _loadReport(() async {
      _incomeStatement = await _repository.incomeStatement(
          businessId: bid, from: _from, to: _to);
    });
  }

  Future<void> loadBalanceSheet() async {
    final bid = _businessId;
    if (bid == null) return;
    await _loadReport(() async {
      _balanceSheet =
          await _repository.balanceSheet(businessId: bid, asOf: _to);
    });
  }

  Future<void> loadLedger(String accountId) async {
    final bid = _businessId;
    if (bid == null) return;
    _ledgerAccountId = accountId;
    await _loadReport(() async {
      _ledger = await _repository.ledger(
          businessId: bid, accountId: accountId, from: _from, to: _to);
    });
  }

  /// Vuelve a pedir los reportes que YA estaban cargados. Se llama después de
  /// cada escritura: si no, postear un asiento parado en Balanza dejaba los
  /// números viejos en pantalla.
  Future<void> _refreshLoadedReports() async {
    final bid = _businessId;
    if (bid == null) return;
    try {
      if (_trialBalance.isNotEmpty) {
        _trialBalance = await _repository.trialBalance(
            businessId: bid, from: _from, to: _to);
      }
      if (_incomeStatement.isNotEmpty) {
        _incomeStatement = await _repository.incomeStatement(
            businessId: bid, from: _from, to: _to);
      }
      if (_balanceSheet.isNotEmpty) {
        _balanceSheet =
            await _repository.balanceSheet(businessId: bid, asOf: _to);
      }
      final acc = _ledgerAccountId;
      if (acc != null && _ledger.isNotEmpty) {
        _ledger = await _repository.ledger(
            businessId: bid, accountId: acc, from: _from, to: _to);
      }
    } catch (e) {
      // Refrescar reportes es secundario: el asiento ya se guardó. No se
      // pisa el mensaje de éxito con un error de lectura.
      debugPrint('Contabilidad: refresco de reportes falló: $e');
    }
  }

  Future<void> _loadReport(Future<void> Function() body) async {
    _isBusy = true;
    notifyListeners();
    try {
      await body();
      _error = null;
    } catch (e) {
      _error = _friendly(e);
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  /// Envuelve una acción de escritura: marca ocupado, traduce el error de la
  /// BD y devuelve el mensaje para el toast (null nunca; siempre hay texto).
  Future<String?> _run(Future<String> Function() body) async {
    _isBusy = true;
    notifyListeners();
    try {
      final msg = await body();
      _error = null;
      return msg;
    } catch (e) {
      _error = _friendly(e);
      return _error;
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  /// Los códigos que levantan las RPC contables son estables; se traducen acá
  /// para no mostrarle un stack de Postgres al contador.
  String _friendly(Object e) {
    final raw = e.toString();
    if (raw.contains('UNBALANCED_ENTRY')) {
      return 'El asiento no cuadra: los débitos deben ser iguales a los créditos.';
    }
    if (raw.contains('PERIOD_CLOSED')) {
      return 'Ese mes está cerrado. Reábrelo desde Períodos para poder asentar.';
    }
    if (raw.contains('ENTRY_IMMUTABLE')) {
      return 'Un asiento posteado no se edita ni se borra: hay que revertirlo.';
    }
    if (raw.contains('ALREADY_REVERSED')) {
      return 'Ese asiento ya fue revertido.';
    }
    if (raw.contains('CANNOT_REVERSE_REVERSAL')) {
      return 'No se puede revertir un asiento que ya es una reversión.';
    }
    if (raw.contains('ACCOUNT_NOT_POSTABLE')) {
      return 'Elegiste una cuenta de agrupación o inactiva. Usa una cuenta de detalle.';
    }
    if (raw.contains('ACCOUNT_NOT_FOUND')) {
      return 'Hay una cuenta que no existe en el catálogo.';
    }
    if (raw.contains('INVALID_LINES')) {
      return 'El asiento necesita al menos dos líneas.';
    }
    if (raw.contains('EMPTY_ENTRY')) {
      return 'El asiento no mueve importes.';
    }
    if (raw.contains('ACCESS_DENIED') || raw.contains('42501')) {
      return 'No tienes permiso para esta acción contable.';
    }
    if (raw.contains('42P01') || raw.contains('does not exist')) {
      return 'El módulo contable no está instalado en la base de datos '
          '(falta aplicar la migración 20260805_0001).';
    }
    return raw.replaceFirst('PostgrestException(', '').replaceAll(')', '');
  }
}
