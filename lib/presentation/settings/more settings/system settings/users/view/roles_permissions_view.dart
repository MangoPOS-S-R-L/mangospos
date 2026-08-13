import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/repositories/permissions_repository.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SettingsRolesView extends ConsumerStatefulWidget {
  final String businessId;
  final String? targetUserId;
  final String? targetEmployeeId;

  const SettingsRolesView({
    super.key,
    required this.businessId,
    this.targetUserId,
    this.targetEmployeeId,
  });

  @override
  ConsumerState<SettingsRolesView> createState() => _SettingsRolesViewState();
}

class _SettingsRolesViewState extends ConsumerState<SettingsRolesView> {
  static const actions = [
    'acceso',
    'ver',
    'graba/mod',
    'anula',
    'reimprime',
  ];

  final Map<String, Set<String>> _grants = {};
  final _repo = PermissionsRepository(Supabase.instance.client);

  bool _loading = true;
  String? _error;
  String? _businessId;

  /// Permisos efectivos tal como se leyeron al abrir la pantalla.
  ///
  /// Hace falta porque esta grilla no cubre todo el catálogo: contabilidad,
  /// créditos y reservas no tienen fila acá. Como el guardado borra los
  /// overrides del usuario y reinserta solo lo que se manda, sin este
  /// respaldo un guardado desde esta pantalla le arrancaba en silencio
  /// permisos de esos módulos que habían sido concedidos desde Usuarios.
  Set<String> _loadedCodes = <String>{};

  /// Todos los códigos que esta grilla sabe conceder o quitar. Lo que caiga
  /// fuera de este conjunto no se toca al guardar.
  static final Set<String> _managedCodes = _codeMap.values
      .expand((byAction) => byAction.values)
      .expand((codes) => codes)
      .toSet();

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  final _groups = <_PermissionGroup>[
    _PermissionGroup(
      title: 'Dashboard',
      permissions: [
        _PermissionRow('dashboard', 'Acceso al dashboard'),
      ],
    ),
    _PermissionGroup(
      title: 'Configuracion',
      permissions: [
        _PermissionRow('settings.usuarios', 'Usuarios'),
        _PermissionRow('settings.roles', 'Roles'),
        _PermissionRow('settings.impresoras', 'Impresoras / Areas'),
        _PermissionRow('settings.zonas_mesas', 'Zonas y mesas'),
        _PermissionRow('settings.impuestos', 'Impuestos y NCF'),
        _PermissionRow('settings.metodos_pago', 'Metodos de pago'),
        _PermissionRow('settings.descuentos_propinas', 'Descuentos y propinas'),
        _PermissionRow('settings.kds', 'KDS / Targets de impresion'),
      ],
    ),
    _PermissionGroup(
      title: 'Ventas por salon / manual',
      permissions: [
        _PermissionRow('ventas.mesas', 'Mesas (abrir/mover/unir)'),
        _PermissionRow(
          'ventas.mesas.liberar',
          'Mesas (liberar / anular la cuenta)',
        ),
        _PermissionRow('ventas.orden', 'Orden (agregar/editar/enviar)'),
        _PermissionRow(
          'ventas.orden.eliminar',
          'Orden (eliminar producto de la cuenta)',
        ),
        _PermissionRow(
          'ventas.orden.descuento',
          'Orden (aplicar descuento / cortesía)',
        ),
        _PermissionRow('ventas.cuenta', 'Cuenta (split manual/equitativo)'),
      ],
    ),
    _PermissionGroup(
      title: 'Venta rapida / express',
      permissions: [
        _PermissionRow('ventas_rapida.orden', 'Orden rapida'),
        _PermissionRow('ventas_rapida.cobro', 'Cobro inmediato'),
      ],
    ),
    _PermissionGroup(
      title: 'Pagos y caja',
      permissions: [
        _PermissionRow('pagos', 'Modal de pagos'),
        _PermissionRow('caja', 'Apertura / cierre / arqueo'),
        _PermissionRow(
          'caja.movimientos',
          'Movimientos de caja (ingresos / egresos / gastos)',
        ),
      ],
    ),
    _PermissionGroup(
      title: 'KDS / Cocina',
      permissions: [
        _PermissionRow('kds', 'Comandas y estados'),
      ],
    ),
    _PermissionGroup(
      title: 'Gestión de productos',
      permissions: [
        _PermissionRow('productos', 'Productos (Menú)'),
        _PermissionRow('categorias', 'Categorías de menú'),
      ],
    ),
    _PermissionGroup(
      title: 'Reportes',
      permissions: [
        _PermissionRow('reportes.ventas', 'Ventas'),
        _PermissionRow('reportes.productos', 'Productos'),
        _PermissionRow('reportes.caja', 'Caja'),
        _PermissionRow('reportes.fiscales', 'Fiscales'),
      ],
    ),
    _PermissionGroup(
      title: 'Clientes y delivery',
      permissions: [
        _PermissionRow('clientes', 'Clientes'),
        _PermissionRow('delivery', 'Delivery / repartidores'),
      ],
    ),
    _PermissionGroup(
      title: 'Inventario / compras',
      permissions: [
        _PermissionRow('inventario', 'Inventario'),
        _PermissionRow('compras', 'Compras / ordenes / recepciones'),
        _PermissionRow(
          'produccion',
          'Producción (transformación de materias primas)',
        ),
        _PermissionRow(
          'conteo',
          'Conteo físico (freeze → contar → ajustar)',
        ),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final isMobile = ResponsiveHelper.isMobile(context);
    final hPad = isMobile ? 10.0 : 16.0;

    return Scaffold(
      backgroundColor: MangoColors.sidebarBg,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go(AppRoutes.settingsUsers),
        ),
        title: Text(
          'Gestionar Roles',
          style: TextStyle(fontSize: isMobile ? 16 : 20),
        ),
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: .4,
        actions: [
          if (isMobile)
            IconButton(
              tooltip: 'Guardar',
              onPressed: _onSave,
              icon: const Icon(Icons.save_outlined),
            )
          else
            TextButton.icon(
              onPressed: _onSave,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Guardar'),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _error!,
                      style:
                          text.bodyMedium?.copyWith(color: Colors.redAccent),
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _bootstrap,
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(hPad, hPad, hPad, 24),
                    children: [
                      _HeaderCard(
                        onImportMatrix: _importPreset,
                        isMobile: isMobile,
                      ),
                      SizedBox(height: isMobile ? 12 : 16),
                      ..._groups.map((group) => _PermissionGroupCard(
                            group: group,
                            actions: actions,
                            grants: _grants,
                            onToggle: _toggle,
                            isMobile: isMobile,
                          )),
                      SizedBox(height: isMobile ? 14 : 20),
                      Card(
                        elevation: .4,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Padding(
                          padding: EdgeInsets.all(isMobile ? 12 : 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Nota rapida',
                                style: text.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  fontSize: isMobile ? 14 : null,
                                ),
                              ),
                              SizedBox(height: isMobile ? 4 : 6),
                              Text(
                                '- Acceso controla si el modulo/pantalla se muestra.\n'
                                '- Ver es solo lectura; Graba/Mod permite crear/editar.\n'
                                '- Anula cubre cancelaciones/reaperturas (motivo requerido).\n'
                                '- Reimprime aplica a recibos/comandas/fiscales.',
                                style: TextStyle(
                                  fontSize: isMobile ? 12 : 14,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  void _toggle(String code, String action, bool value) {
    setState(() {
      final set = _grants[code] ?? <String>{};
      if (value) {
        set.add(action);
      } else {
        set.remove(action);
      }
      _grants[code] = set;
    });
  }

  void _onSave() {
    _persist();
  }

  void _importPreset() {
    // Pre-carga un preset sugerido para acelerar demos.
    setState(() {
      _grants
        ..clear()
        ..addAll({
          'settings.usuarios': {'acceso', 'ver', 'graba/mod'},
          'settings.roles': {'acceso', 'ver', 'graba/mod'},
          'ventas.mesas': {'acceso', 'ver', 'graba/mod'},
          'ventas.orden': {'acceso', 'ver', 'graba/mod'},
          'pagos': {'acceso', 'ver', 'graba/mod', 'anula', 'reimprime'},
          'caja': {'acceso', 'ver', 'graba/mod'},
          'kds': {'acceso', 'ver', 'graba/mod', 'reimprime'},
          'reportes.ventas': {'acceso', 'ver'},
        });
    });
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final sb = Supabase.instance.client;
    // Usar el usuario objetivo si se proporciona, de lo contrario el actual
    final userId = widget.targetUserId ?? sb.auth.currentUser?.id;
    if (userId == null) {
      setState(() {
        _loading = false;
        _error = 'No hay usuario autenticado.';
      });
      return;
    }
    try {
      final bid =
          await resolveBusinessIdOrNull(sb, widget.businessId) ?? widget.businessId;
      _businessId = bid;
      final codes =
          await _repo.fetchEffectivePermissions(businessId: bid, userId: userId);
      _loadedCodes = codes;
      _syncFromCodes(codes);
      setState(() {
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Error al cargar permisos: $e';
      });
    }
  }

  void _syncFromCodes(Set<String> codes) {
    _grants.clear();
    for (final group in _groups) {
      for (final row in group.permissions) {
        for (final action in actions) {
          final mapped = _codeMap[row.code]?[action] ?? const [];
          if (mapped.isNotEmpty &&
              mapped.every((c) => codes.contains(c))) {
            _grants.putIfAbsent(row.code, () => <String>{}).add(action);
          }
        }
      }
    }
  }

  Future<void> _persist() async {
    final session = ref.read(sessionProvider);
    
    // Prioridad: 1) Parámetros del widget, 2) Sesión actual
    final userId = widget.targetUserId ?? session.userId;
    final employeeId = widget.targetEmployeeId ?? session.employeeId;

    if (userId == null || _businessId == null || employeeId == null) {
      AppToast.info(
          context, 'Falta usuario, negocio o ID de empleado para guardar.');
      return;
    }
    final desiredCodes = <String>{};
    _grants.forEach((rowCode, actionsSelected) {
      for (final action in actionsSelected) {
        desiredCodes.addAll(_codeMap[rowCode]?[action] ?? const []);
      }
    });

    // Conservar lo que esta grilla no gestiona (contabilidad, créditos,
    // reservas). El guardado hace borrón y cuenta nueva sobre los overrides
    // del usuario, así que todo lo que no se reenvíe se pierde.
    desiredCodes.addAll(
      _loadedCodes.where((code) => !_managedCodes.contains(code)),
    );

    try {
      await _repo.saveUserOverrides(
        businessId: _businessId!,
        userId: userId,
        employeeId: employeeId,
        codes: desiredCodes,
      );
      if (!mounted) return;
      AppToast.success(context, 'Permisos guardados en backend.');
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Error al guardar: $e');
    }
  }
}

class _PermissionGroupCard extends StatelessWidget {
  const _PermissionGroupCard({
    required this.group,
    required this.actions,
    required this.grants,
    required this.onToggle,
    this.isMobile = false,
  });

  final _PermissionGroup group;
  final List<String> actions;
  final Map<String, Set<String>> grants;
  final void Function(String code, String action, bool value) onToggle;
  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      elevation: .5,
      margin: EdgeInsets.only(bottom: isMobile ? 10 : 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          isMobile ? 12 : 14,
          isMobile ? 10 : 12,
          isMobile ? 12 : 14,
          isMobile ? 8 : 10,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              group.title,
              style: text.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                fontSize: isMobile ? 14 : null,
              ),
            ),
            SizedBox(height: isMobile ? 8 : 12),
            if (!isMobile) ...[
              _PermissionTableHeader(actions: actions),
              const Divider(height: 14),
            ],
            ...group.permissions.map(
              (p) => _PermissionRowWidget(
                row: p,
                actions: actions,
                availableActions: {
                  for (final a in actions)
                    if ((_codeMap[p.code]?[a] ?? const []).isNotEmpty) a,
                },
                selected: grants[p.code] ?? const {},
                onToggle: onToggle,
                isMobile: isMobile,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionTableHeader extends StatelessWidget {
  const _PermissionTableHeader({required this.actions});
  final List<String> actions;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Text(
            'Modulo / Recurso',
            style: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        ...actions.map(
          (a) => Expanded(
            child: Text(
              a.toUpperCase(),
              textAlign: TextAlign.center,
              style: text.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: Colors.grey[700],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PermissionRowWidget extends StatelessWidget {
  const _PermissionRowWidget({
    required this.row,
    required this.actions,
    required this.availableActions,
    required this.selected,
    required this.onToggle,
    this.isMobile = false,
  });

  final _PermissionRow row;
  final List<String> actions;
  final Set<String> availableActions;
  final Set<String> selected;
  final void Function(String code, String action, bool value) onToggle;
  final bool isMobile;

  static const _labels = {
    'acceso': 'Acceso',
    'ver': 'Ver',
    'graba/mod': 'Graba/Mod',
    'anula': 'Anula',
    'reimprime': 'Reimprime',
  };

  @override
  Widget build(BuildContext context) {
    if (isMobile) {
      // Vista móvil: label arriba, chips toggleables debajo.
      // Solo mostramos las acciones disponibles para este permiso.
      final available =
          actions.where((a) => availableActions.contains(a)).toList();
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          decoration: BoxDecoration(
            color: const Color(0xFFFAFAFA),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFEEEEEE)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                row.label,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 8),
              if (available.isEmpty)
                const Text(
                  'Sin acciones configurables',
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFF9CA3AF),
                    fontStyle: FontStyle.italic,
                  ),
                )
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: available
                      .map(
                        (a) => _ActionChip(
                          label: _labels[a] ?? a,
                          selected: selected.contains(a),
                          onTap: () => onToggle(
                              row.code, a, !selected.contains(a)),
                        ),
                      )
                      .toList(),
                ),
            ],
          ),
        ),
      );
    }

    // Vista desktop/tablet: tabla con checkboxes en columnas.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              row.label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          ...actions.map(
            (a) => Expanded(
              child: Center(
                child: availableActions.contains(a)
                    ? Checkbox(
                        value: selected.contains(a),
                        onChanged: (v) => onToggle(row.code, a, v ?? false),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      )
                    : const Text(
                        '—',
                        style: TextStyle(color: Color(0xFFCBD5E1)),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = selected
        ? MangoColors.primaryOrange.withValues(alpha: 0.14)
        : Colors.white;
    final fg = selected
        ? MangoColors.primaryOrange
        : const Color(0xFF374151);
    final border = selected
        ? MangoColors.primaryOrange
        : const Color(0xFFD1D5DB);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: border, width: selected ? 1.4 : 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 14,
              color: fg,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 11.5,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.onImportMatrix,
    this.isMobile = false,
  });
  final VoidCallback onImportMatrix;
  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      elevation: .6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          isMobile ? 12 : 14,
          isMobile ? 10 : 12,
          isMobile ? 12 : 14,
          isMobile ? 10 : 12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Roles basados en permisos',
              style: text.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                fontSize: isMobile ? 14 : null,
              ),
            ),
            SizedBox(height: isMobile ? 4 : 6),
            Text(
              isMobile
                  ? 'Activa los permisos por acción. Acceso muestra la pantalla; '
                      'los demás habilitan acciones específicas.'
                  : 'Activa los permisos por accion segun el documento de roles. '
                      'Acceso muestra la pantalla; los demas toggles habilitan acciones '
                      'como crear/editar, anular/reabrir o reimprimir.',
              style: TextStyle(
                fontSize: isMobile ? 12 : 14,
                height: 1.4,
              ),
            ),
            SizedBox(height: isMobile ? 8 : 10),
            Wrap(
              spacing: isMobile ? 6 : 8,
              runSpacing: isMobile ? 6 : 8,
              children: [
                OutlinedButton.icon(
                  icon: Icon(Icons.table_rows, size: isMobile ? 16 : 18),
                  label: Text(
                    isMobile ? 'Preset demo' : 'Cargar preset demo',
                    style: TextStyle(fontSize: isMobile ? 12 : 14),
                  ),
                  onPressed: onImportMatrix,
                ),
                OutlinedButton.icon(
                  icon: Icon(
                    Icons.description_outlined,
                    size: isMobile ? 16 : 18,
                  ),
                  label: Text(
                    isMobile ? 'Definiciones' : 'Ver definiciones',
                    style: TextStyle(fontSize: isMobile ? 12 : 14),
                  ),
                  onPressed: () => AppToast.info(
                    context,
                    'Ver backend data structure/roles_usuarios_mangopos.txt',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionGroup {
  final String title;
  final List<_PermissionRow> permissions;
  const _PermissionGroup({required this.title, required this.permissions});
}

class _PermissionRow {
  final String code;
  final String label;
  const _PermissionRow(this.code, this.label);
}

// Mapeo de columnas (acceso/ver/graba/anula/reimprime) -> permisos granulares
// Basado en backend data structure/roles_usuarios_mangopos.txt
const Map<String, Map<String, List<String>>> _codeMap = {
  'dashboard': {
    'acceso': ['dashboard.acceso'],
    'ver': ['dashboard.acceso'],
  },
  'settings.usuarios': {
    'acceso': ['settings.usuarios.acceso'],
    'ver': ['settings.usuarios.ver'],
    'graba/mod': ['settings.usuarios.crear', 'settings.usuarios.editar'],
    'anula': ['settings.usuarios.desactivar'],
  },
  'settings.roles': {
    'acceso': ['settings.roles.acceso'],
    'ver': ['settings.roles.ver'],
    'graba/mod': ['settings.roles.crear', 'settings.roles.editar'],
    'anula': ['settings.roles.eliminar'],
  },
  'settings.impresoras': {
    'acceso': ['settings.impresoras.gestionar'],
    'graba/mod': ['settings.impresoras.gestionar'],
  },
  'settings.zonas_mesas': {
    'acceso': ['settings.zonas_mesas.gestionar'],
    'graba/mod': ['settings.zonas_mesas.gestionar'],
  },
  'settings.impuestos': {
    'acceso': ['settings.impuestos_fiscal.gestionar'],
    'graba/mod': ['settings.impuestos_fiscal.gestionar'],
  },
  'settings.metodos_pago': {
    'acceso': ['settings.metodos_pago.gestionar'],
    'graba/mod': ['settings.metodos_pago.gestionar'],
  },
  'settings.descuentos_propinas': {
    'acceso': ['settings.descuentos_propinas.gestionar'],
    'graba/mod': ['settings.descuentos_propinas.gestionar'],
  },
  'settings.kds': {
    'acceso': ['settings.kds.gestionar'],
    'graba/mod': ['settings.kds.gestionar'],
  },
  'ventas.mesas': {
    'acceso': ['ventas.mesas.acceso', 'ventas.mesas.ver_estado'],
    'ver': ['ventas.mesas.ver_estado'],
    'graba/mod': [
      'ventas.mesas.abrir',
      'ventas.mesas.mover_unir',
      'ventas.mesas.marcar_pagando',
    ],
  },
  // Independiente de abrir/mover: permite decidir si un mesero puede liberar
  // (anular la cuenta y soltar) una mesa sin PIN de supervisor.
  'ventas.mesas.liberar': {
    'graba/mod': ['ventas.mesas.liberar'],
  },
  'ventas.orden': {
    'acceso': ['ventas.orden.ver_total'],
    'ver': ['ventas.orden.ver_total'],
    'graba/mod': [
      'ventas.orden.agregar_item',
      'ventas.orden.editar_item',
      'ventas.orden.enviar_cocina',
    ],
    'anula': ['ventas.orden.anular', 'ventas.orden.reabrir'],
  },
  'ventas.orden.eliminar': {
    'graba/mod': ['ventas.orden.eliminar_item'],
  },
  // Independiente de agregar/editar: controla descuentos y cortesías por igual
  // (ambos usan el mismo permiso 'ventas.orden.descuento_aplicar').
  'ventas.orden.descuento': {
    'graba/mod': ['ventas.orden.descuento_aplicar'],
  },
  'ventas.cuenta': {
    'acceso': ['ventas.cuenta.split_manual', 'ventas.cuenta.split_equiv'],
    'graba/mod': ['ventas.cuenta.split_manual', 'ventas.cuenta.split_equiv'],
  },
  'ventas_rapida.orden': {
    'acceso': ['ventas_rapida.acceso'],
    'graba/mod': ['ventas_rapida.crear_orden', 'ventas_rapida.enviar_cocina'],
  },
  'ventas_rapida.cobro': {
    'acceso': ['ventas_rapida.cobrar_inmediato'],
    'graba/mod': ['ventas_rapida.cobrar_inmediato'],
  },
  'pagos': {
    'acceso': ['pagos.acceso'],
    'graba/mod': [
      'pagos.cobrar_efectivo',
      'pagos.cobrar_tarjeta',
      'pagos.cobrar_transferencia',
      'pagos.asignar_referencia'
    ],
    'anula': ['pagos.anular_pago'],
    'reimprime': ['pagos.reimprimir_recibo'],
  },
  'caja': {
    'acceso': ['caja.apertura', 'caja.cierre'],
    'ver': ['caja.arqueo_ver'],
    'graba/mod': ['caja.apertura', 'caja.cierre'],
  },
  // Movimientos de caja separados de apertura/cierre — un cajero con
  // cierre a ciegas (sin caja.arqueo_ver) DEBE poder registrar
  // ingresos/egresos/gastos. Antes ambos perms vivían en el mismo grupo
  // y el de "movimientos_crear" no estaba mapeado a ninguna columna,
  // por lo que era imposible asignárselo desde la UI.
  //
  // `graba/mod` incluye `movimientos_ver` además de `movimientos_crear`:
  // no tiene sentido crear sin poder ver la lista — la card de
  // "Ingresos y Egresos" en el cashier_view se muestra con `ver`. Si
  // solo das `crear`, el cajero no encuentra dónde hacerlo.
  'caja.movimientos': {
    'ver': ['caja.movimientos_ver'],
    'graba/mod': ['caja.movimientos_ver', 'caja.movimientos_crear'],
  },
  'kds': {
    'acceso': ['kds.acceso', 'kds.ver_comandas'],
    'graba/mod': ['kds.cambiar_estado'],
    'reimprime': ['kds.reimprimir_comanda'],
  },
  'reportes.ventas': {
    'acceso': ['reportes.ventas'],
    'ver': ['reportes.ventas'],
  },
  'reportes.productos': {
    'acceso': ['reportes.productos'],
    'ver': ['reportes.productos'],
  },
  'reportes.caja': {
    'acceso': ['reportes.caja'],
    'ver': ['reportes.caja'],
  },
  'reportes.fiscales': {
    'acceso': ['reportes.fiscales'],
    'ver': ['reportes.fiscales'],
  },
  'clientes': {
    'acceso': ['clientes.ver'],
    'ver': ['clientes.ver'],
    'graba/mod': ['clientes.crear_editar', 'clientes.asignar_a_mesa'],
  },
  'delivery': {
    'acceso': ['delivery.crear_orden'],
    'graba/mod': [
      'delivery.crear_orden',
      'delivery.asignar_repartidor',
      'delivery.marcar_entregado'
    ],
  },
  'productos': {
    'acceso': ['productos.acceso'],
    'ver': ['productos.ver'],
    'graba/mod': ['productos.crear', 'productos.editar'],
    'anula': ['productos.eliminar'],
  },
  'categorias': {
    // No existe `categorias.acceso` en el catálogo; usamos `categorias.ver`
    // como puerta de entrada al módulo (igual que en otros grupos sin
    // permiso explícito de "acceso").
    'acceso': ['categorias.ver'],
    'ver': ['categorias.ver'],
    'graba/mod': ['categorias.crear', 'categorias.editar'],
    'anula': ['categorias.eliminar'],
  },
  'inventario': {
    'acceso': ['inventario.acceso'],
    'graba/mod': [
      'inventario.productos.crear_editar',
      'inventario.ajustes.crear',
      'inventario.transferencias.crear',
      'inventario.transferencias.recibir',
      'inventario.transferencias.aprobar',
    ],
  },
  'compras': {
    'acceso': ['compras.acceso'],
    'graba/mod': [
      'compras.proveedores.crear_editar',
      'compras.ordenes.crear',
      'compras.ordenes.recibir'
    ],
    'anula': ['compras.ordenes.anular'],
  },
  'produccion': {
    'acceso': ['produccion.acceso'],
    'graba/mod': ['produccion.crear', 'produccion.completar'],
    'anula': ['produccion.anular'],
  },
  'conteo': {
    'acceso': ['inventario.conteo.acceso'],
    'graba/mod': ['inventario.conteo.crear', 'inventario.conteo.completar'],
    'anula': ['inventario.conteo.anular'],
  },
};
