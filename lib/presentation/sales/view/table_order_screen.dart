import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/breakpoints.dart';
import 'package:mangopos/app/theme/sizes.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/business/business_features_provider.dart';
import 'package:mangopos/core/business/business_model.dart';
import 'package:mangopos/presentation/sales/viewmodel/retail_carts_provider.dart';
import 'package:mangopos/core/utils/display_name_utils.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/models/fiscal_models.dart';
import 'package:mangopos/data/repositories/bank_accounts_repository.dart';
import 'package:mangopos/data/repositories/business_profile_repository.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/data/repositories/printing_repository.dart'
    show PrintOutcome;
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';
import 'package:mangopos/presentation/sales/viewmodel/menu_browser_viewmodel.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/state/sales_zoom_provider.dart';
import 'package:mangopos/presentation/sales/widgets/sales_zoom_control.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/presentation/split_bill/widgets/split_bill_modal.dart';
import 'package:mangopos/presentation/customers/viewmodel/customers_viewmodel.dart';
import 'package:mangopos/services/dgii_lookup_service.dart';

import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:mangopos/services/printing/print_destination.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';
import 'package:mangopos/services/printing/qr_esc_pos_builder.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:mangopos/app/widgets/skeleton_loading.dart';
import 'package:mangopos/presentation/sales/widgets/precheck/pre_check_dialog.dart';
import 'package:mangopos/presentation/sales/widgets/precheck/print_destination_picker.dart';
import 'package:mangopos/core/printing/device_identity.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/presentation/sales/widgets/payment_success_dialog.dart';
import 'package:mangopos/presentation/sales/widgets/pin_verification_modal.dart';
import 'package:mangopos/presentation/sales/widgets/transfer_session_dialog.dart';
import 'package:mangopos/data/models/table_status.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/presentation/sales/view/widgets/product_detail_modal.dart';
import 'package:mangopos/presentation/sales/view/table_selector_modal.dart';
import 'payment_split_screen.dart';

const Color _salesSurface = Color(0xFFFFFFFF);
const Color _salesDivider = Color(0xFFE9E6E2);
const Color _salesTextPrimary = Color(0xFF2C2C2C);
const Color _salesTextSecondary = Color(0xFF7A7A7A);
const Color _salesTextHint = Color(0xFF9A9A9A);
const Color _salesKitchenButton = Color(0xFFFB8A3C); // naranja cocina sólido
const Color _salesPayButton = Color(0xFF22C55E); // verde puro (success)
const Color _salesTotalColor = Color(0xFFF97316); // mango fuerte
const Color _salesTabActiveBg = Color(0xFFF3F0ED);

const double _salesRadiusCard = 14;
const double _salesRadiusButton = 12; // botones pill
const double _salesRadiusField = 14;
const double _salesRadiusTab = 12;

/// Locks de acciones por orden (envío a cocina, impresión, etc.) — el
/// valor es el timestamp en ms cuando se adquirió el lock. Permite que
/// `_isActionLocked` ignore locks expirados aunque el timer failsafe no
/// haya llegado a correr (ej: app en background, frame skip).
final _salesActionLocksProvider = StateProvider<Map<String, int>>(
  (ref) => const {},
);

/// Vida máxima de un lock antes de considerarse stale y permitir
/// reintento. Si la acción legítimamente puede tomar más tiempo, hay que
/// pasar `failsafeTimeout` mayor en `_runLockedAction`.
const Duration _kLockMaxAge = Duration(seconds: 15);

Future<bool> _ensureCanDeleteOrderItem(
  BuildContext context,
  WidgetRef ref, {

  /// `true` cuando el item aun esta en estado `draft` (todavia no se
  /// envio a cocina). Mesero/cajero puede eliminarlo sin PIN — es como
  /// quitar algo del carrito antes de confirmar. La proteccion con PIN
  /// solo aplica cuando el item ya salio impreso a cocina/bar.
  required bool isDraft,
}) async {
  if (isDraft) return true;

  // Solo el owner del negocio se salta el PIN. Cualquier otro rol (admin,
  // supervisor, cajero, mesero…) debe escribir PIN de supervisor/admin para
  // reducir la cantidad o eliminar un item que YA salió impreso a cocina/bar.
  if (ref.read(sessionProvider).isOwner) return true;

  final authorized = await showPinVerificationModal(
    context,
    ref,
    level: PinAccessLevel.supervisor,
    title: 'Autorización para eliminar',
    subtitle:
        'Se requiere PIN de Supervisor o Administrador para reducir o eliminar este producto.',
  );
  return authorized;
}

const List<BoxShadow> _salesSoftShadow = [
  BoxShadow(color: Color(0x10000000), blurRadius: 6, offset: Offset(0, 2)),
];

Color _parseHexColor(String? hex, {Color fallback = _salesDivider}) {
  if (hex == null || hex.isEmpty) return fallback;
  try {
    final buffer = StringBuffer();
    if (hex.length == 6 || hex.length == 7) buffer.write('ff');
    buffer.write(hex.replaceFirst('#', ''));
    return Color(int.parse(buffer.toString(), radix: 16));
  } catch (_) {
    return fallback;
  }
}

class _BusinessReceiptProfile {
  final String name;
  final String? businessName;
  final String? legalName;
  final String? address;
  final String? phone;
  final String? rnc;

  const _BusinessReceiptProfile({
    required this.name,
    this.businessName,
    this.legalName,
    this.address,
    this.phone,
    this.rnc,
  });
}

Future<_BusinessReceiptProfile> _loadBusinessReceiptProfile(
  WidgetRef ref,
) async {
  final session = ref.read(sessionProvider);
  final businessId = session.activeBusinessId;
  final fallbackName = (session.activeBusinessName?.trim().isNotEmpty ?? false)
      ? session.activeBusinessName!.trim()
      : 'Negocio';

  if (businessId == null || businessId.isEmpty) {
    return _BusinessReceiptProfile(name: fallbackName, phone: null);
  }

  final client = Supabase.instance.client;
  String? name = fallbackName;
  String? businessName;
  String? address;
  String? phone;
  String? rnc;
  String? legalName;

  try {
    final business = await client
        .from('businesses')
        .select(
          'business_name, branch_name, address, phone, fiscal_rnc, fiscal_name',
        )
        .eq('id', businessId)
        .maybeSingle();

    final branchName = business?['branch_name']?.toString().trim();
    final businessName = business?['business_name']?.toString().trim();
    final fiscalNameVal = business?['fiscal_name']?.toString().trim();

    // Prefer fiscal_name if available for receipts
    name = fiscalNameVal?.isNotEmpty == true
        ? fiscalNameVal
        : (branchName?.isNotEmpty == true
              ? branchName
              : (businessName?.isNotEmpty == true
                    ? businessName
                    : fallbackName));

    address = business?['address']?.toString().trim();
    phone = business?['phone']?.toString().trim();
    rnc = business?['fiscal_rnc']?.toString().trim();
    legalName = fiscalNameVal;
  } catch (_) {}

  return _BusinessReceiptProfile(
    name: name ?? fallbackName,
    businessName: businessName,
    legalName: legalName,
    address: address,
    phone: phone,
    rnc: rnc,
  );
}

/// Extrae el porcentaje numérico de una label de impuesto tipo
/// "ITBIS (18%)" / "Propina Ley (10%)" / "ITBIS (16.5%)". Devuelve null
/// si la label no encaja con el patrón — el caller cae al fallback de
/// usar `summary.subtotal` / `summary.tax` directos del backend.
final RegExp _cartRateInLabelRegex = RegExp(r'\((\d+(?:[.,]\d+)?)\s*%\)');

double? _parseCartRatePercent(String label) {
  final match = _cartRateInLabelRegex.firstMatch(label);
  if (match == null) return null;
  final raw = match.group(1)?.replaceAll(',', '.') ?? '';
  return double.tryParse(raw);
}

/// Resuelve el nombre del mesero para mostrar en precuenta/factura.
///
/// Orden de prioridad:
/// 1. **`opened_by_employee_id`** (multimesero) → empleado que metió PIN
///    al abrir la mesa. Este es el "mesero real" cuando varios meseros
///    comparten un mismo dispositivo (modo multimesero).
/// 2. **`opened_by` + employees** → empleado vinculado al user_id que
///    abrió la mesa (modo single-mesero, cada mesero loguea su propia
///    cuenta).
/// 3. **`opened_by` + auth.users.full_name** → si no hay registro de
///    empleado, usar el full_name del auth user.
/// 4. **`sessionProvider.userName`** → fallback final cuando todo lo
///    anterior falla.
Future<String?> _loadWaiterName(WidgetRef ref, String orderId) async {
  final fallback = ref.read(sessionProvider).userName;
  final client = Supabase.instance.client;

  // Resolvemos el nombre del mesero que ABRIÓ la mesa (no quien agregó
  // cada item). Esa identidad se preserva en `table_sessions.opened_by`
  // y `opened_by_employee_id` y NO cambia cuando otro mesero agrega
  // productos — exactamente lo que necesitamos para "MESERO:" en
  // comanda / precuenta / factura.
  //
  // Llamamos a la RPC `fn_order_opener_name` en vez de hacer SELECTs
  // directos a `employees` porque RLS bloqueaba esos SELECTs para
  // cajeros sin permisos especiales — el helper silenciosamente caía
  // al `fallback = sessionProvider.userName` y el ticket terminaba
  // imprimiendo el nombre del cajero logueado, no del opener real.
  try {
    final result = await client.rpc(
      'fn_order_opener_name',
      params: {'p_order_id': orderId},
    );
    final name = result?.toString().trim();
    if (name != null && name.isNotEmpty) {
      return preferredDisplayName(fullName: name);
    }
  } catch (e) {
    debugPrint('[audit] fn_order_opener_name falló: $e');
  }

  return fallback;
}

Future<FiscalDocument?> _loadFiscalDocument(
  WidgetRef ref,
  String orderId, {
  String? fiscalDocumentId,
}) async {
  try {
    // Si conocemos el fd_id (vino con el payment recién cobrado), lo
    // cargamos directo por id — único camino fiable cuando la orden
    // tiene múltiples fds (split bill, multi-method).
    if (fiscalDocumentId != null && fiscalDocumentId.isNotEmpty) {
      return await ref
          .read(salesRepositoryProvider)
          .getFiscalDocumentById(fiscalDocumentId);
    }
    return await ref
        .read(salesRepositoryProvider)
        .getOrderFiscalDocument(orderId);
  } catch (_) {
    return null;
  }
}

Future<void> _showMissingKitchenPrinterDialog(
  BuildContext context,
  NoAssignedKitchenPrinterException error,
) {
  final areas = error.areaCodes.isEmpty
      ? 'cocina'
      : error.areaCodes.join(', ').replaceAll('_', ' ').toUpperCase();

  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(
        children: [
          Icon(Icons.print_disabled_outlined, color: Colors.orange),
          SizedBox(width: 10),
          Expanded(child: Text('Impresora no configurada')),
        ],
      ),
      content: Text(
        'No hay una impresora asignada para $areas.\n\nConfigura una impresora en Ajustes > Impresion de comandas antes de enviar esta orden a cocina.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cerrar'),
        ),
        FilledButton.icon(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            context.go(AppRoutes.printingOrders);
          },
          icon: const Icon(Icons.settings_outlined, size: 18),
          label: const Text('Configurar ahora'),
        ),
      ],
    ),
  );
}

double _effectiveItemTotal(Order? order, OrderItem item) {
  return itemDisplayTotal(order, item);
}

double _uiItemDisplayAmount(Order? order, OrderItem item) {
  return itemDisplayTotal(order, item);
}

enum OrderOrigin { table, manual, quick, delivery }

class OrderScreen extends ConsumerStatefulWidget {
  final OrderOrigin origin;
  final String? tableId;
  final String? tableCode;
  final String? zoneId;
  final String? deliveryType;
  final int initialPeopleCount;

  const OrderScreen({
    super.key,
    this.origin = OrderOrigin.table,
    this.tableId,
    this.tableCode,
    this.zoneId,
    this.deliveryType,
    this.initialPeopleCount = 1,
  });

  @override
  ConsumerState<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends ConsumerState<OrderScreen> {
  String? _currentTableCode;

  /// Toggle business_settings.delivery_address_enabled, cargado una vez al
  /// montar cuando el origin es delivery. Controla si el header muestra el
  /// campo opcional de dirección de entrega.
  bool _deliveryAddressEnabled = false;

  // Snapshot del estado para la limpieza en dispose(). Se mantienen al día en
  // build() vía ref.listen / ref.read para poder liberar la mesa al salir por
  // CUALQUIER ruta (atrás, gesto del sistema, context.go, etc.) sin depender de
  // `ref` después del dispose.
  String? _activeOrderId;
  bool _activeOrderEmpty = false;
  String? _activeBusinessId;
  SalesRepository? _salesRepoRef;

  bool _isOpenItem(OrderItem item) {
    return item.status != 'paid' && item.status != 'void';
  }

  @override
  void dispose() {
    // Catch-all: si se sale de una MESA sin productos (orden vacía) por
    // cualquier vía, liberar la mesa de inmediato. El _handleBack ya lo intenta
    // para refrescar la zona al volver; esto garantiza que también ocurra
    // cuando se sale por otra ruta o se destruye la pantalla abruptamente.
    // Usa una referencia capturada (no `ref`) y el cliente global de Supabase,
    // así sigue siendo válida durante el teardown. releaseEmptyTableIfNeeded es
    // idempotente: si ya se cerró/liberó, no hace nada.
    if (widget.origin == OrderOrigin.table &&
        _activeOrderEmpty &&
        _activeOrderId != null) {
      final repo = _salesRepoRef ?? SalesRepository(Supabase.instance.client);
      final orderId = _activeOrderId!;
      final businessId = _activeBusinessId;
      unawaited(
        repo
            .releaseEmptyTableIfNeeded(orderId, businessId: businessId)
            .catchError((_) => false),
      );
    }
    super.dispose();
  }

  /// Construye la URL de vuelta a `/sales/by-zone` preservando la zona
  /// donde el usuario estaba. Si no hay zoneId disponible (origen
  /// manual/quick), regresa al path plano y la vista arranca en index 0.
  String _salesByZoneBackUrl() {
    final zoneId = widget.zoneId?.trim();
    if (zoneId == null || zoneId.isEmpty) {
      return AppRoutes.salesByZone;
    }
    return Uri(
      path: AppRoutes.salesByZone,
      queryParameters: {'zone': zoneId},
    ).toString();
  }

  Future<void> _handleBack(BuildContext context) async {
    // Capture state needed for background cleanup before navigating.
    final orderState = ref.read(currentOrderProvider);
    final order = orderState.order;
    final hasEmptyOrder = order != null && orderState.items.isEmpty;
    final businessId = ref.read(sessionProvider).activeBusinessId;
    final zoneId = widget.zoneId;
    final salesRepo = ref.read(salesRepositoryProvider);
    final zoneVm = ref.read(byZoneVmProvider.notifier);
    final orderNotifier = ref.read(currentOrderProvider.notifier);

    // 1. Navigate IMMEDIATELY — user sees instant response.
    if (context.mounted) {
      if (widget.origin == OrderOrigin.delivery) {
        context.go(
          Uri(
            path: AppRoutes.salesReact,
            queryParameters: const {'mode': 'delivery'},
          ).toString(),
        );
      } else {
        // Preservar la zona donde el mesero estaba antes de entrar a la
        // mesa. Sin este `?zone=<id>` el TabController arranca en index
        // 0 y el mesero queda en "Salón Principal" — un click extra cada
        // vez que sale de una mesa.
        context.go(_salesByZoneBackUrl());
      }
    }

    // 2. Cleanup in background — release empty table + refresh zone.
    if (hasEmptyOrder) {
      unawaited(
        Future.microtask(() async {
          try {
            await salesRepo.releaseEmptyTableIfNeeded(
              order.id,
              businessId: businessId,
            );
          } catch (_) {
            try {
              await orderNotifier.cancelCurrentOrder();
            } catch (_) {}
          }
          // Refresh zone status so tables update via realtime fallback.
          try {
            if (zoneId != null && zoneId.isNotEmpty) {
              await zoneVm.loadZoneStatus(zoneId, emitError: false);
            } else if (businessId != null && businessId.isNotEmpty) {
              await zoneVm.load(businessId);
            }
          } catch (_) {}
        }),
      );
    }
  }

  /// PRD-12 F2: abre el dialog de transferencia de cuenta. El dialog
  /// orquesta los pasos (qué transferir → mesa destino → PIN supervisor)
  /// y devuelve `true` si la transferencia se completó. Cuando esto
  /// pasa, regresamos al grid de zonas — la cuenta ya no está en esta
  /// mesa.
  ///
  /// Enforcement de `ventas.mesas.mover_unir`: si el usuario tiene el
  /// permiso en su rol, procede directo. Si no, pide PIN de supervisor
  /// (mismo patrón que anular orden). Antes el dialog se abría sin
  /// chequear permiso de rol — solo dependía del PIN final, lo que
  /// dejaba la puerta abierta para que cualquier mesero/cajero iniciara
  /// el flujo.
  Future<void> _handleTransferSession(BuildContext context) async {
    final orderState = ref.read(currentOrderProvider);
    final order = orderState.order;
    final messenger = ScaffoldMessenger.of(context);

    if (order == null || order.sessionId.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No hay cuenta activa para transferir.')),
      );
      return;
    }
    if (widget.origin != OrderOrigin.table) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('La transferencia solo aplica a cuentas de mesa.'),
        ),
      );
      return;
    }

    // El gate de PIN vive dentro del diálogo (_submit), que es el punto
    // único de ejecución para ambos flujos (transferir y unir mesas). No
    // lo duplicamos aquí para no pedir el PIN dos veces.

    // Resolver businessId vía el resolver canónico (mismo patrón que
    // otras pantallas — Order no expone business_id directo).
    final businessId = await BusinessResolver.ensure('auto');
    if (!context.mounted) return;

    final tableLabel = _currentTableCode ?? widget.tableCode ?? 'Mesa';
    final sourceTableId = widget.tableId ?? '';
    if (sourceTableId.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No se pudo identificar la mesa origen.')),
      );
      return;
    }

    final transferred = await showTransferSessionDialog(
      context,
      ref,
      businessId: businessId,
      sourceSessionId: order.sessionId,
      sourceTableId: sourceTableId,
      sourceTableLabel: tableLabel,
      items: orderState.items,
    );

    if (!transferred) return;
    if (!context.mounted) return;
    // Volver al grid: la cuenta ya está en otra mesa.
    context.go(AppRoutes.salesByZone);
  }

  Future<void> _handleReleaseTable(BuildContext context) async {
    await _handleVoidCurrentOrder(
      context,
      title: 'Liberar mesa',
      content:
          'Esto anulará la orden actual y liberará la mesa. ¿Deseas continuar?',
      confirmLabel: 'Liberar',
      goToZonesOnSuccess: true,
      bypassPermission: 'ventas.mesas.liberar',
    );
  }

  /// Autoriza una acción sensible: el dueño y quien tenga [permission] pasan
  /// directo; cualquier otro puede autorizar con PIN de Supervisor/Administrador
  /// como respaldo. Devuelve false si el usuario cancela el PIN.
  Future<bool> _authorizeWithPermissionOrPin(
    BuildContext context, {
    required String permission,
    required String pinTitle,
    required String pinSubtitle,
  }) async {
    if (ref.read(sessionProvider).isOwner) return true;
    if (ref.read(sessionProvider.notifier).hasPermission(permission)) {
      return true;
    }
    return showPinVerificationModal(
      context,
      ref,
      level: PinAccessLevel.supervisor,
      title: pinTitle,
      subtitle: pinSubtitle,
    );
  }

  /// Toggle inteligente: si TODOS los items abiertos ya están como takeout,
  /// los marca como NO takeout. Si no, marca todos como takeout. Pide
  /// confirmación porque cambia muchas líneas de un solo paso.
  Future<void> _handleMarkAllTakeout(BuildContext context) async {
    final orderState = ref.read(currentOrderProvider);
    if (orderState.order == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No hay una orden activa.')));
      return;
    }
    final openItems = orderState.items
        .where((i) => i.status != 'paid' && i.status != 'void')
        .toList(growable: false);
    if (openItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('La orden no tiene items para marcar.')),
      );
      return;
    }
    final allAlready = openItems.every((i) => i.isTakeout);
    final newValue = !allAlready;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          newValue ? 'Marcar todo para llevar' : 'Quitar "para llevar"',
        ),
        content: Text(
          newValue
              ? '${openItems.length} item(s) quedarán marcados como "para '
                    'llevar". Los impuestos pueden cambiar si tu negocio tiene '
                    'reglas específicas para takeout.'
              : '${openItems.length} item(s) volverán a "consumo en local".',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(newValue ? 'Marcar todo' : 'Quitar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await ref.read(currentOrderProvider.notifier).toggleTakeout(newValue);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newValue
                ? 'Todos los items marcados para llevar.'
                : 'Todos los items vuelven a consumo en local.',
          ),
          backgroundColor: _salesPayButton,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('No se pudo actualizar: $e')));
    }
  }

  Future<void> _handleVoidCurrentOrder(
    BuildContext context, {
    required String title,
    required String content,
    required String confirmLabel,
    bool goToZonesOnSuccess = false,
    String? bypassPermission,
  }) async {
    final orderState = ref.read(currentOrderProvider);
    if (orderState.order == null) return;

    // El owner del negocio se salta el PIN. Quien tenga [bypassPermission]
    // (p. ej. un mesero con 'ventas.mesas.liberar') también pasa directo.
    // Cualquier otro rol debe escribir PIN de Supervisor/Administrador
    // como respaldo para anular o liberar la mesa.
    final isOwner = ref.read(sessionProvider).isOwner;
    final hasBypassPermission = bypassPermission != null &&
        ref.read(sessionProvider.notifier).hasPermission(bypassPermission);
    if (!isOwner && !hasBypassPermission) {
      final authorized = await showPinVerificationModal(
        context,
        ref,
        level: PinAccessLevel.supervisor,
        title: 'Autorización para anular',
        subtitle:
            'Se requiere PIN de Supervisor o Administrador para anular esta orden.',
      );
      if (!authorized) return;
      if (!context.mounted) return;
    }

    final openItems = orderState.items
        .where(_isOpenItem)
        .toList(growable: false);
    final dialogResult = await showDialog<_VoidOrderDialogResult>(
      context: context,
      builder: (dialogContext) => _VoidOrderDialog(
        title: title,
        content: content,
        confirmLabel: confirmLabel,
        openItemsCount: openItems.length,
        openItemsQty: openItems.fold<double>(
          0,
          (sum, item) => sum + item.quantity,
        ),
        totalAmount: summarizeOrderPricing(orderState.order, openItems).total,
      ),
    );

    if (dialogResult == null) return;
    if (!mounted) return;

    await ref
        .read(currentOrderProvider.notifier)
        .cancelCurrentOrder(reason: dialogResult.reason);
    if (!context.mounted) return;

    final reasonText = dialogResult.reason.trim();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          reasonText.isEmpty
              ? 'Orden anulada correctamente.'
              : 'Orden anulada. Motivo: $reasonText',
        ),
      ),
    );

    if (goToZonesOnSuccess) {
      context.go(AppRoutes.salesByZone);
    }
  }

  String? _parseLegalName(String? notes) {
    if (notes == null) return null;
    final parts = notes.split(' | ');
    for (final part in parts) {
      if (part.trim().startsWith('business_name: ')) {
        return part.substring('business_name: '.length).trim();
      }
    }
    return null;
  }

  Future<void> _handleProductTap(
    BuildContext context,
    MenuProduct product,
  ) async {
    final vm = ref.read(currentOrderProvider.notifier);

    // Tile de OFERTA vendible: UNA línea (cantidad N) a precio original con el
    // descuento del deal (se ve abajo en los totales), optimista e instantánea.
    if (product.itemType == 'offer') {
      await vm.addOfferDeal(
        menuItemId: product.id,
        lineQty: product.offerLineQty ?? 1,
        discount: product.offerDiscount ?? 0,
        name: product.name,
        originalPrice: product.price,
        promotionId: product.offerPromoId,
        productTaxMode: product.taxMode,
        productTaxRate: product.taxRate,
      );
      return;
    }

    List<SelectedModifierInput> selectedModifiers = const [];
    if (product.itemType == 'combo') {
      final comboGroups = await vm.getMenuItemComboGroups(product.id);
      if (!context.mounted) return;
      final comboResult = await showDialog<List<SelectedModifierInput>>(
        context: context,
        builder: (_) =>
            _ComboSelectionDialog(product: product, groups: comboGroups),
      );
      if (!context.mounted || comboResult == null) return;
      selectedModifiers = comboResult;
    }

    final groups = await vm.getMenuItemModifierGroups(product.id);
    if (!context.mounted) return;
    if (groups.isNotEmpty) {
      final result = await showDialog<List<SelectedModifierInput>>(
        context: context,
        builder: (_) =>
            _ModifiersSelectionDialog(product: product, groups: groups),
      );
      if (!context.mounted || result == null) return;
      selectedModifiers = [...selectedModifiers, ...result];
    }

    // Ítem nuevo: default de "para llevar" por ORIGEN (mesa → consumo en mesa),
    // NO heredado de otros ítems. Antes se propagaba state.takeout (derivado de
    // "todos los ítems son takeout"), lo que contagiaba: al marcar 1-2 ítems
    // para llevar, los siguientes entraban para llevar solos. El cajero marca
    // cada ítem con el toggle por-ítem cuando aplique.
    final orderTakeout =
        ref.read(currentOrderProvider.notifier).defaultTakeoutForNewItem();
    await vm.addItem(
      menuItemId: product.id,
      productName: product.name,
      productPrice: product.price,
      productTaxMode: product.taxMode,
      productTaxRate: product.calculateTaxRate(
        ref.read(currentOrderProvider).origin ?? 'table',
      ),
      productFullTaxRate: product.calculateFullTaxRate(),
      selectedModifiers: selectedModifiers,
      takeout: orderTakeout,
    );
  }

  Future<void> _handleAssignClient(BuildContext context) async {
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _AssignCustomerDialog(),
    );

    if (selected == null) return;

    final customerId = selected['id'] as String?;
    final customerName = (selected['name'] as String?)?.trim();
    final customerTaxId = selected['tax_id'] as String?;
    final notes = selected['notes'] as String?;
    final customerLegalName = _parseLegalName(notes);

    if (customerId == null || customerId.isEmpty) return;
    if (customerName == null || customerName.isEmpty) return;
    if (!mounted) return;

    // Si hay una sub-cuenta seleccionada en el header, el cliente va a ESE
    // check (order_checks), no a la sesión general. Así cada sub-cuenta
    // conserva su propio nombre en vez de quedarse con el general.
    final selectedCheckId = ref.read(currentOrderProvider).selectedCheckId;
    if (selectedCheckId != null) {
      await ref
          .read(currentOrderProvider.notifier)
          .assignCustomerToCheck(
            checkId: selectedCheckId,
            customerId: customerId,
            customerName: customerName,
          );
    } else {
      await ref
          .read(currentOrderProvider.notifier)
          .assignCustomerToCurrentOrder(
            customerId: customerId,
            customerName: customerName,
            customerLegalName: customerLegalName,
            customerTaxId: customerTaxId,
          );
    }

    if (!context.mounted) return;
    final scopeLabel = selectedCheckId != null ? ' a la subcuenta' : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Cliente asignado$scopeLabel: $customerName')),
    );
  }

  Future<void> _handleApplyDiscount(BuildContext context) async {
    final orderState = ref.read(currentOrderProvider);
    final openItems = orderState.items
        .where(_isOpenItem)
        .toList(growable: false);
    if (orderState.order == null || openItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay productos abiertos para descontar.'),
        ),
      );
      return;
    }

    final authorized = await _authorizeWithPermissionOrPin(
      context,
      permission: 'ventas.orden.descuento_aplicar',
      pinTitle: 'Autorización para descuento',
      pinSubtitle:
          'Se requiere PIN de Supervisor o Administrador para aplicar descuentos.',
    );
    if (!authorized || !context.mounted) return;

    final result = await showDialog<_DiscountDialogResult>(
      context: context,
      builder: (_) =>
          _DiscountDialog(items: openItems, order: orderState.order),
    );
    if (result == null) return;

    final targetIds = result.scope == _DiscountScope.table
        ? openItems.map((e) => e.id).toList(growable: false)
        : result.selectedItemIds;
    if (targetIds.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selecciona al menos un producto.')),
      );
      return;
    }

    try {
      if (!mounted) return;
      await ref
          .read(currentOrderProvider.notifier)
          .applyDiscountPercentToItems(
            itemIds: targetIds,
            percent: result.percent,
            preAuthorized: true,
          );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Descuento ${result.percent.toStringAsFixed(0)}% aplicado.',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo aplicar descuento: $e')),
      );
    }
  }

  Future<void> _handleCourtesyByProduct(BuildContext context) async {
    final orderState = ref.read(currentOrderProvider);
    final openItems = orderState.items
        .where(_isOpenItem)
        .toList(growable: false);
    if (orderState.order == null || openItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay productos abiertos para cortesía.'),
        ),
      );
      return;
    }

    final authorized = await _authorizeWithPermissionOrPin(
      context,
      permission: 'ventas.orden.descuento_aplicar',
      pinTitle: 'Autorización para cortesía',
      pinSubtitle:
          'Se requiere PIN de Supervisor o Administrador para aplicar cortesías.',
    );
    if (!authorized || !context.mounted) return;

    final result = await showDialog<_CourtesyDialogResult>(
      context: context,
      builder: (_) =>
          _CourtesyDialog(items: openItems, order: orderState.order),
    );
    if (result == null || result.selectedItemIds.isEmpty) return;

    try {
      if (!mounted) return;
      await ref
          .read(currentOrderProvider.notifier)
          .applyCourtesyToItems(
            itemIds: result.selectedItemIds,
            reason: result.reason,
            preAuthorized: true,
          );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.reason.trim().isEmpty
                ? 'Cortesía aplicada.'
                : 'Cortesía aplicada: ${result.reason.trim()}',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo aplicar cortesía: $e')),
      );
    }
  }

  void _initializeOrder() {
    final notifier = ref.read(currentOrderProvider.notifier);
    if (widget.origin == OrderOrigin.table && widget.tableId != null) {
      notifier.openTable(
        widget.tableId!,
        peopleCount: widget.initialPeopleCount,
      );
    } else if (widget.origin == OrderOrigin.manual) {
      notifier.ensureManualOrder();
    } else if (widget.origin == OrderOrigin.quick) {
      notifier.ensureQuickOrder();
    } else if (widget.origin == OrderOrigin.delivery &&
        widget.tableId != null) {
      notifier.openDeliveryOrder(
        tableId: widget.tableId!,
        deliveryType: widget.deliveryType,
      );
    }
  }

  @override
  void didUpdateWidget(OrderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.origin != oldWidget.origin ||
        widget.tableId != oldWidget.tableId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _initializeOrder();
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _currentTableCode = widget.tableCode;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeOrder();
      _loadDeliveryAddressSetting();
    });
  }

  /// Carga el toggle "pedir dirección de entrega" cuando el pedido es
  /// delivery. Best-effort: si falla, el campo simplemente no se muestra.
  Future<void> _loadDeliveryAddressSetting() async {
    if (widget.origin != OrderOrigin.delivery) return;
    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) return;
    try {
      final enabled = await ref
          .read(posSettingsRepositoryProvider)
          .getDeliveryAddressEnabled(businessId);
      if (mounted && enabled != _deliveryAddressEnabled) {
        setState(() => _deliveryAddressEnabled = enabled);
      }
    } catch (_) {
      // Best-effort: dirección es opcional.
    }
  }

  @override
  Widget build(BuildContext context) {
    // Mantener al día el snapshot que usa dispose() para liberar la mesa vacía.
    // ref.listen no provoca rebuild; solo actualiza los campos cuando cambia la
    // orden. El repo y el businessId se capturan por lectura directa.
    ref.listen<CurrentOrderState>(currentOrderProvider, (prev, next) {
      _activeOrderId = next.order?.id;
      _activeOrderEmpty = next.order != null && next.items.isEmpty;
    });
    final orderSnapshot = ref.read(currentOrderProvider);
    _activeOrderId = orderSnapshot.order?.id;
    _activeOrderEmpty =
        orderSnapshot.order != null && orderSnapshot.items.isEmpty;
    _salesRepoRef = ref.read(salesRepositoryProvider);
    _activeBusinessId = ref.read(sessionProvider).activeBusinessId;
    // Retail: sin mesas ni zonas, el rail de herramientas (que en venta
    // rápida solo lleva "Regresar") no aplica. Se observa aquí (fuera del
    // LayoutBuilder, que corre en fase de layout) para registrar bien la
    // dependencia de rebuild.
    final isRetail = ref.watch(currentBusinessModelProvider).isRetail;

    return Scaffold(
      backgroundColor: _salesSurface,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final isDesktop = width >= 1200;
            final isMobile = width < 600;

            double cartWidth = 320.0;
            if (isDesktop) {
              cartWidth = 400.0;
            }

            final cart = _CartView(
              origin: widget.origin,
              tableCode: _currentTableCode ?? '',
              onAssignClient: () => _handleAssignClient(context),
              deliveryAddressEnabled: _deliveryAddressEnabled,
            );
            final catalog = _CatalogArea(
              origin: widget.origin,
              tableCode: _currentTableCode ?? 'Venta Libre',
              onProductTap: (product) {
                final orderState = ref.read(currentOrderProvider);
                if (orderState.loading) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Cargando orden. Intenta de nuevo.'),
                    ),
                  );
                  return;
                }
                if (orderState.order == null) {
                  final errorMsg =
                      orderState.error ?? 'No hay una orden activa.';
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Error: $errorMsg\nPor favor envíame una captura de este mensaje.',
                        maxLines: 4,
                      ),
                    ),
                  );
                  return;
                }
                _handleProductTap(context, product);
              },
            );

            if (isMobile) {
              // Layout móvil portrait: catálogo a pantalla completa, ticket
              // en bottom sheet draggable accesible desde la barra inferior.
              // El _CartView (que tiene los botones Pagar/Pre-Cuenta/Dividir)
              // se monta dentro del sheet sin duplicar lógica.
              return Column(
                children: [
                  _MobileSalesHeader(
                    title: widget.tableCode?.isNotEmpty == true
                        ? widget.tableCode!
                        : 'Venta libre',
                    showTableActions: widget.origin == OrderOrigin.table,
                    onBack: () => _handleBack(context),
                    onTransferSession: () => _handleTransferSession(context),
                    onReleaseTable: () => _handleReleaseTable(context),
                    onVoidOrder: () => _handleVoidCurrentOrder(
                      context,
                      title: 'Anular orden',
                      content:
                          'Esta acción anulará la orden actual. Si la mesa no tiene más órdenes activas, también quedará liberada. ¿Deseas continuar?',
                      confirmLabel: 'Anular',
                    ),
                    onApplyDiscount: () => _handleApplyDiscount(context),
                    onApplyCourtesy: () => _handleCourtesyByProduct(context),
                  ),
                  Container(height: 1, color: _salesDivider),
                  if (isRetail) const _RetailCartTabs(),
                  Expanded(
                    child: Stack(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 72),
                          child: catalog,
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: _MobileCartBar(
                            onOpenCart: () => _openMobileCartSheet(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!isRetail)
                  _SalesToolsRail(
                    onBack: () => _handleBack(context),
                    showTableActions: widget.origin == OrderOrigin.table,
                    onReleaseTable: () => _handleReleaseTable(context),
                    onVoidOrder: () => _handleVoidCurrentOrder(
                      context,
                      title: 'Anular orden',
                      content:
                          'Esta acción anulará la orden actual. Si la mesa no tiene más órdenes activas, también quedará liberada. ¿Deseas continuar?',
                      confirmLabel: 'Anular',
                    ),
                    onApplyDiscount: () => _handleApplyDiscount(context),
                    onApplyCourtesy: () => _handleCourtesyByProduct(context),
                    onTransferSession: () => _handleTransferSession(context),
                    onMarkAllTakeout: () => _handleMarkAllTakeout(context),
                  ),
                // Usamos ancho fijo según especificación (400px o 320px)
                SizedBox(
                  width: cartWidth,
                  child: isRetail
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const _RetailCartTabs(),
                            Expanded(child: cart),
                          ],
                        )
                      : cart,
                ),
                Container(width: 1, color: _salesDivider),
                Expanded(child: catalog), // Resto disponible
              ],
            );
          },
        ),
      ),
    );
  }
}

class _VoidOrderDialogResult {
  final String reason;

  const _VoidOrderDialogResult({required this.reason});
}

// =============================================================================
// Mobile shell: header compacto + bottom bar persistente + sheet del cart.
// Solo se usa cuando el ancho es <600dp. El layout desktop no se toca.
// =============================================================================

extension _MobileSalesShell on _OrderScreenState {
  Future<void> _openMobileCartSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      barrierColor: Colors.black54,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return FractionallySizedBox(
          heightFactor: 0.92,
          child: Column(
            children: [
              // Drag handle
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFE5E7EB),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: _CartView(
                  origin: widget.origin,
                  tableCode: widget.tableCode ?? 'Venta libre',
                  isStacked: true,
                  onAssignClient: () => _handleAssignClient(context),
                  deliveryAddressEnabled: _deliveryAddressEnabled,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MobileSalesHeader extends StatelessWidget {
  final String title;
  final bool showTableActions;
  final VoidCallback onBack;
  final VoidCallback onTransferSession;
  final VoidCallback onReleaseTable;
  final VoidCallback onVoidOrder;
  final VoidCallback onApplyDiscount;
  final VoidCallback onApplyCourtesy;

  const _MobileSalesHeader({
    required this.title,
    required this.showTableActions,
    required this.onBack,
    required this.onTransferSession,
    required this.onReleaseTable,
    required this.onVoidOrder,
    required this.onApplyDiscount,
    required this.onApplyCourtesy,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: const BoxDecoration(color: _salesSurface),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded),
            color: _salesTextPrimary,
            tooltip: 'Regresar',
            onPressed: onBack,
          ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: _salesTextPrimary,
              ),
            ),
          ),
          if (showTableActions)
            PopupMenuButton<_MobileSalesAction>(
              icon: const Icon(
                Icons.more_vert_rounded,
                color: _salesTextPrimary,
              ),
              tooltip: 'Más opciones',
              onSelected: (action) {
                switch (action) {
                  case _MobileSalesAction.transferSession:
                    onTransferSession();
                    break;
                  case _MobileSalesAction.releaseTable:
                    onReleaseTable();
                    break;
                  case _MobileSalesAction.voidOrder:
                    onVoidOrder();
                    break;
                  case _MobileSalesAction.applyDiscount:
                    onApplyDiscount();
                    break;
                  case _MobileSalesAction.applyCourtesy:
                    onApplyCourtesy();
                    break;
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: _MobileSalesAction.transferSession,
                  child: ListTile(
                    leading: Icon(Icons.swap_horiz_rounded),
                    title: Text('Transferir cuenta'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: _MobileSalesAction.releaseTable,
                  child: ListTile(
                    leading: Icon(Icons.logout_rounded),
                    title: Text('Liberar mesa'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: _MobileSalesAction.voidOrder,
                  child: ListTile(
                    leading: Icon(Icons.block_rounded),
                    title: Text('Anular orden'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: _MobileSalesAction.applyDiscount,
                  child: ListTile(
                    leading: Icon(Icons.percent_rounded),
                    title: Text('Aplicar descuento'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: _MobileSalesAction.applyCourtesy,
                  child: ListTile(
                    leading: Icon(Icons.card_giftcard_rounded),
                    title: Text('Cortesía producto'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

enum _MobileSalesAction {
  transferSession,
  releaseTable,
  voidOrder,
  applyDiscount,
  applyCourtesy,
}

/// Barra inferior persistente en el layout móvil. Lee `currentOrderProvider`
/// para mostrar items abiertos + total. Tap abre el bottom sheet con el
/// `_CartView` completo (Pagar/Pre-Cuenta/Dividir viven adentro).
class _MobileCartBar extends ConsumerWidget {
  final VoidCallback onOpenCart;
  const _MobileCartBar({required this.onOpenCart});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // PRD 8 Fase 2 fix #3: `.select` granular en lugar de
    // `ref.watch(currentOrderProvider)` entero. Antes, cualquier cambio
    // en loading/error/customerName/fiscalType/taxConfigError/etc.
    // disparaba rebuild del CartBar aunque el total no cambiara. Ahora
    // solo se rebuild cuando uno de estos 5 campos REALMENTE cambia.
    final relevant = ref.watch(
      currentOrderProvider.select(
        (s) => (
          items: s.items,
          selectedCheckId: s.selectedCheckId,
          checks: s.checks,
          order: s.order,
          origin: s.origin,
        ),
      ),
    );
    final openItems = relevant.items
        .where((i) => i.status != 'paid' && i.status != 'void')
        .toList(growable: false);
    final selectedCheckId = relevant.selectedCheckId;
    final allChecks = relevant.checks;
    final displayedItems = selectedCheckId != null
        ? openItems
              .where((i) => i.checkId == selectedCheckId)
              .toList(growable: false)
        : openItems
              .where((i) {
                final checkIsClosed = allChecks.any(
                  (c) => c.id == i.checkId && c.isClosed,
                );
                return !checkIsClosed;
              })
              .toList(growable: false);

    final itemCount = displayedItems.length;
    final pricingSummary = summarizeOrderPricing(
      relevant.order,
      displayedItems,
      forcedOrigin: relevant.origin,
    );
    final total = pricingSummary.total;
    final hasItems = itemCount > 0;
    final currency = NumberFormat('#,##0.00', 'en_US');

    return Material(
      color: Colors.white,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: InkWell(
          onTap: onOpenCart,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: _salesDivider)),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: hasItems
                        ? _salesPayButton.withValues(alpha: 0.12)
                        : const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(
                        Icons.receipt_long_rounded,
                        color: hasItems
                            ? _salesPayButton
                            : const Color(0xFF6B7280),
                        size: 22,
                      ),
                      if (hasItems)
                        Positioned(
                          top: -6,
                          right: -8,
                          child: Container(
                            constraints: const BoxConstraints(
                              minWidth: 18,
                              minHeight: 18,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: _salesPayButton,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: Colors.white,
                                width: 1.5,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              itemCount > 99 ? '99+' : '$itemCount',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                height: 1,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        hasItems
                            ? '$itemCount item${itemCount == 1 ? '' : 's'} en el ticket'
                            : 'Sin items',
                        style: const TextStyle(
                          fontSize: 12,
                          color: _salesTextSecondary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hasItems
                            ? 'RD\$ ${currency.format(total)}'
                            : 'Toca para ver el ticket',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: hasItems
                              ? _salesTextPrimary
                              : _salesTextSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: hasItems ? _salesPayButton : const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        hasItems ? 'Ver pedido' : 'Agregar',
                        style: TextStyle(
                          color: hasItems
                              ? Colors.white
                              : const Color(0xFF475569),
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.keyboard_arrow_up_rounded,
                        size: 18,
                        color: hasItems
                            ? Colors.white
                            : const Color(0xFF475569),
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

class _VoidOrderDialog extends StatefulWidget {
  final String title;
  final String content;
  final String confirmLabel;
  final int openItemsCount;
  final double openItemsQty;
  final double totalAmount;

  const _VoidOrderDialog({
    required this.title,
    required this.content,
    required this.confirmLabel,
    required this.openItemsCount,
    required this.openItemsQty,
    required this.totalAmount,
  });

  @override
  State<_VoidOrderDialog> createState() => _VoidOrderDialogState();
}

class _VoidOrderDialogState extends State<_VoidOrderDialog> {
  final TextEditingController _reasonCtrl = TextEditingController();

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat('#,##0.00', 'en_US');

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.content),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFED7AA)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Impacto de la anulación',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text('Líneas abiertas: ${widget.openItemsCount}'),
                  Text(
                    'Cantidad abierta: ${widget.openItemsQty.toStringAsFixed(widget.openItemsQty % 1 == 0 ? 0 : 2)}',
                  ),
                  Text(
                    'Total abierto: RD\$ ${currency.format(widget.totalAmount)}',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _reasonCtrl,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Motivo de anulación *',
                hintText:
                    'Ej: cliente desistió, error de captura, duplicada...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'El motivo se guardará en la nota de la sesión para dejar rastro operativo.',
              style: TextStyle(fontSize: 12, color: _salesTextSecondary),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            final reason = _reasonCtrl.text.trim();
            if (reason.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Indica el motivo de la anulación.'),
                ),
              );
              return;
            }
            Navigator.pop(context, _VoidOrderDialogResult(reason: reason));
          },
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

String? _extractLatestVoidAudit(String? note) {
  if (note == null || note.trim().isEmpty) return null;
  final lines = note
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.startsWith('[ANULACION]'))
      .toList(growable: false);
  if (lines.isEmpty) return null;
  return lines.last;
}

// -----------------------------------------------------------------------------
// 2. VISTA DE CARRITO
// -----------------------------------------------------------------------------
/// Barra del header de delivery: muestra la dirección de entrega (o un
/// prompt para agregarla) y abre el editor al tocarla. Campo opcional.
class _DeliveryAddressBar extends StatelessWidget {
  final String? address;
  final VoidCallback onEdit;
  const _DeliveryAddressBar({required this.address, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final hasAddress = address != null && address!.trim().isNotEmpty;
    return InkWell(
      onTap: onEdit,
      borderRadius: BorderRadius.circular(_salesRadiusButton),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: _salesDivider),
          borderRadius: BorderRadius.circular(_salesRadiusButton),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.location_on_outlined,
              size: 18,
              color: _salesTotalColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Dirección de entrega',
                    style: TextStyle(
                      fontSize: 11,
                      color: _salesTextSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasAddress ? address!.trim() : 'Agregar dirección (opcional)',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: hasAddress
                          ? _salesTextPrimary
                          : _salesTextSecondary,
                      fontWeight:
                          hasAddress ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.edit_outlined,
              size: 16,
              color: _salesTextSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

class _CartView extends ConsumerWidget {
  final OrderOrigin origin;
  final String tableCode;
  final bool isStacked;
  final Future<void> Function() onAssignClient;

  /// Si true y origin==delivery, el header muestra el campo opcional de
  /// dirección de entrega (toggle business_settings.delivery_address_enabled).
  final bool deliveryAddressEnabled;

  const _CartView({
    required this.origin,
    required this.tableCode,
    required this.onAssignClient,
    this.isStacked = false,
    this.deliveryAddressEnabled = false,
  });

  bool _isOpenItem(OrderItem item) {
    return item.status != 'paid' && item.status != 'void';
  }

  /// Nombre a mostrar en el chip de cliente del header. Si hay una
  /// sub-cuenta seleccionada, muestra el cliente PROPIO de ese check
  /// (order_checks.customer_name); si no, el cliente general de la mesa.
  String _resolveHeaderCustomerName(CurrentOrderState orderState) {
    final selectedCheckId = orderState.selectedCheckId;
    if (selectedCheckId != null) {
      for (final check in orderState.checks) {
        if (check.id == selectedCheckId) {
          final name = check.customerName?.trim();
          return (name != null && name.isNotEmpty) ? name : 'Cliente';
        }
      }
    }
    final generalName = orderState.customerName?.trim();
    return (generalName != null && generalName.isNotEmpty)
        ? generalName
        : 'Cliente';
  }

  /// Abre un diálogo para capturar/editar la dirección de entrega del
  /// delivery. Campo opcional: guardar vacío la limpia. Cancelar no
  /// cambia nada.
  Future<void> _editDeliveryAddress(
    BuildContext context,
    WidgetRef ref,
    CurrentOrderState orderState,
  ) async {
    final controller =
        TextEditingController(text: orderState.deliveryAddress ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text(
          'Dirección de entrega',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: SizedBox(
          width: 380,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: 'Calle, número, sector, referencia…',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, controller.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return; // cancelado
    await ref.read(currentOrderProvider.notifier).updateDeliveryAddress(result);
  }

  double _sumItemQty(Iterable<OrderItem> items) {
    return items.fold<double>(0, (sum, item) => sum + item.quantity);
  }

  String _formatQtyBadge(double qty) {
    final normalized = double.parse(qty.toStringAsFixed(2));
    if ((normalized - normalized.roundToDouble()).abs() < 0.001) {
      return normalized.toStringAsFixed(0);
    }
    return normalized.toStringAsFixed(2);
  }

  // --- 🪄 UI HELPERS ----------------------------------------------------

  String _sendKitchenActionKey(String? orderId) {
    return 'send_kitchen:${orderId ?? 'none'}';
  }

  String _printActionKey(String type, {String? orderId, String? checkId}) {
    return 'print:$type:${orderId ?? 'none'}:${checkId ?? 'all'}';
  }

  String _reprintActionKey(String orderId, List<OrderItem> items) {
    final itemIds = items.map((item) => item.id).toList()..sort();
    return 'reprint:$orderId:${itemIds.join(",")}';
  }

  bool _isActionLocked(WidgetRef ref, String key) {
    return ref.watch(
      _salesActionLocksProvider.select((locks) {
        final ts = locks[key];
        if (ts == null) return false;
        // Lock expirado por edad → ignorado. Permite reintento aunque el
        // timer failsafe no haya corrido (app suspendida, frame skip).
        final age = DateTime.now().millisecondsSinceEpoch - ts;
        return age < _kLockMaxAge.inMilliseconds;
      }),
    );
  }

  Future<void> _runLockedAction(
    WidgetRef ref,
    String key,
    Future<void> Function() action, {
    Duration failsafeTimeout = _kLockMaxAge,
  }) async {
    final notifier = ref.read(_salesActionLocksProvider.notifier);
    final now = DateTime.now().millisecondsSinceEpoch;

    // Si ya hay un lock fresco para esta key, ignorar la nueva invocación.
    // Si el lock está expirado, lo sobrescribimos (timer anterior nunca
    // limpió por algún motivo).
    final current = ref.read(_salesActionLocksProvider);
    final existingTs = current[key];
    if (existingTs != null &&
        now - existingTs < failsafeTimeout.inMilliseconds) {
      debugPrint(
        '[SalesLocks] SKIP "$key": lock fresco existente '
        '(edad ${now - existingTs}ms < TTL ${failsafeTimeout.inMilliseconds}ms). '
        'Click ignorado.',
      );
      return;
    }
    debugPrint(
      '[SalesLocks] ACQUIRE "$key" en ts=$now '
      '(${existingTs == null ? "sin lock previo" : "sobrescribiendo lock viejo de hace ${now - existingTs}ms"}).',
    );
    notifier.state = {...current, key: now};

    // Failsafe: si la acción se cuelga, libera el lock tras
    // [failsafeTimeout] para que el botón vuelva a habilitarse. La acción
    // puede seguir corriendo en background — el `finally` también limpia
    // (idempotente).
    final failsafe = Timer(failsafeTimeout, () {
      // Mismo blindaje que el finally: si el widget murio antes de que
      // el timer dispare, `ref.read` truena. No propagamos — el lock se
      // limpia solo al siguiente provider rebuild.
      try {
        final state = ref.read(_salesActionLocksProvider);
        if (!state.containsKey(key)) return;
        final next = {...state}..remove(key);
        notifier.state = next;
        debugPrint(
          '[SalesLocks] FAILSAFE release "$key" tras '
          '${failsafeTimeout.inSeconds}s sin completar.',
        );
      } catch (e) {
        debugPrint('[SalesLocks] FAILSAFE "$key" SKIP — widget disposed: $e');
      }
    });

    try {
      await action();
    } finally {
      failsafe.cancel();
      // Si el widget se disposo durante `action()` (caso comun en print
      // flows largos donde el cajero navega o el flujo popula dialogs),
      // `ref.read` truena con StateError. Envolvemos el release del
      // lock para no propagar la excepcion: el lock vive en provider
      // global y se autolimpia con el failsafe; perder un release
      // puntual no rompe nada.
      try {
        final next = {...ref.read(_salesActionLocksProvider)};
        final hadKey = next.remove(key) != null;
        notifier.state = next;
        debugPrint(
          '[SalesLocks] RELEASE "$key" tras ${DateTime.now().millisecondsSinceEpoch - now}ms '
          '(finally, ${hadKey ? "lock estaba presente" : "lock ya removido"}).',
        );
      } catch (e) {
        debugPrint(
          '[SalesLocks] RELEASE "$key" SKIP — widget disposed durante action: $e',
        );
      }
    }
  }

  void _openPaymentModal(
    BuildContext context,
    WidgetRef ref,
    Order order,
    double total, {
    String? checkId,
    String? customerId,
    String? customerName,
  }) async {
    // Feature flag `kitchen_enabled`: si la cocina está apagada y hay
    // items draft/pending, los marcamos `ready` antes de abrir el pago
    // para no atascarnos en validaciones de estado. NO imprimimos
    // comanda — el negocio no tiene cocina.
    final features =
        ref.read(businessFeaturesProvider).value ?? BusinessFeatures.defaults;
    if (!features.kitchenEnabled) {
      final hasOpenItems = ref
          .read(currentOrderProvider)
          .items
          .any(
            (i) =>
                i.status == 'draft' ||
                i.status == 'pending' ||
                i.status == 'preparing',
          );
      if (hasOpenItems) {
        try {
          await ref
              .read(salesRepositoryProvider)
              .markOrderItemsAsReady(order.id);
          if (!context.mounted) return;
          await ref.read(currentOrderProvider.notifier).refreshOrder();
        } catch (e) {
          debugPrint('[order] markOrderItemsAsReady falló: $e');
          // No abortamos el cobro; el flujo legacy puede validar abajo.
        }
      }
    }

    // FRESH antes de cobrar: recargamos la orden del server para no cobrar /
    // imprimir factura/precuenta con ítems stale (Realtime pudo perder
    // eventos, u otra caja agregó ítems). No-op offline o en orden local; el
    // estado se re-lee abajo, así prePaymentItems queda fresco.
    await ref.read(currentOrderProvider.notifier).reloadOrderNow();
    if (!context.mounted) return;

    var currentOrderState = ref.read(currentOrderProvider);
    final fiscalConfigError = _buildFiscalConfigError(currentOrderState);
    if (fiscalConfigError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(fiscalConfigError),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final isFiscal =
        currentOrderState.fiscalType == 'B01' ||
        currentOrderState.fiscalType == '01' ||
        currentOrderState.fiscalType == 'B14' ||
        currentOrderState.fiscalType == '14' ||
        currentOrderState.fiscalType == 'B15' ||
        currentOrderState.fiscalType == '15' ||
        currentOrderState.fiscalType == 'E31' ||
        currentOrderState.fiscalType == '31';

    if (isFiscal) {
      // Usamos los valores del estado para la validación inicial
      if (currentOrderState.customerId == null ||
          currentOrderState.customerId!.isEmpty ||
          currentOrderState.customerTaxId == null ||
          currentOrderState.customerTaxId!.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Para comprobante fiscal se requiere un cliente con RNC/Cédula.',
            ),
            backgroundColor: Colors.orange,
          ),
        );

        await onAssignClient();

        if (!context.mounted) return;

        // RE-LEER estado después de la asignación
        currentOrderState = ref.read(currentOrderProvider);
        if (currentOrderState.customerId == null ||
            currentOrderState.customerId!.isEmpty ||
            currentOrderState.customerTaxId == null ||
            currentOrderState.customerTaxId!.trim().isEmpty) {
          return; // Sigue sin cliente o sin RNC válido
        }
      }
    }

    // Sincronizar estas variables con el estado más reciente.
    // Split bill (2026-05-30): si estamos cobrando una sub-cuenta puntual,
    // `customerId`/`customerName` llegan con el cliente PROPIO del check
    // (order_checks.customer_id/customer_name). Hay que respetarlos en vez
    // de pisarlos con el cliente general de la mesa — antes el recibo/cobro
    // de cada sub-cuenta salía con el nombre general. Fallback al estado
    // general cuando el check no tiene cliente asignado o se paga todo.
    final finalCustomerId = customerId ?? currentOrderState.customerId;
    final finalCustomerName = customerName ?? currentOrderState.customerName;
    final finalFiscalType = currentOrderState.fiscalType;
    final finalCustomerTaxId = currentOrderState.customerTaxId;
    final finalCustomerLegalName = currentOrderState.customerLegalName;
    final prePaymentItems = checkId == null
        ? List<OrderItem>.from(currentOrderState.items)
        : currentOrderState.items.where((i) => i.checkId == checkId).toList();
    var prePaymentOrder = order;
    if (checkId != null) {
      try {
        final check = currentOrderState.checks.firstWhere(
          (c) => c.id == checkId,
        );
        prePaymentOrder = check.toOrder(createdAt: order.createdAt);
      } catch (_) {
        prePaymentOrder = order;
      }
    }

    // Usamos el tableCode disponible en la vista
    final tableName = tableCode;

    if (!context.mounted) return;

    // onFinish corre DESPUÉS de que PaymentSplitDialog hace pop —
    // navega/recarga la orden. Definido aquí para que tanto onConfirmed
    // (vía _showReimpresionDialog en error) como el .then() lo puedan
    // invocar.
    void onFinish() {
      if (checkId == null) {
        // PRD 4: en Quick/Manual cerramos la orden de forma MANDATORIA,
        // reseteamos el state, y abrimos UNA SESIÓN NUEVA en el mismo
        // modo para que el operador pueda agregar productos
        // inmediatamente sin tener que navegar. Sin el openQuick/Manual
        // final, el cart queda vacío con state.order=null y los taps
        // de producto fallan con "no hay orden activa".
        if (origin == OrderOrigin.quick || origin == OrderOrigin.manual) {
          () async {
            try {
              await ref
                  .read(salesRepositoryProvider)
                  .closeOrder(orderId: order.id, status: 'paid');
            } catch (_) {
              // Si ya estaba cerrada, processPayment lo hizo. OK.
            }
            await ref
                .read(currentOrderProvider.notifier)
                .refreshOrder(clearIfPaid: true);
            // Retail: NO reabrimos una sesión quick única — el hook de
            // refreshOrder(clearIfPaid) ya cierra la pestaña pagada y pasa a
            // otro carrito (o crea uno vacío). Reabrir aquí rompería el
            // sistema de carritos múltiples.
            final isRetail = ref.read(currentBusinessModelProvider).isRetail;
            if (!isRetail) {
              if (origin == OrderOrigin.quick) {
                await ref
                    .read(currentOrderProvider.notifier)
                    .openQuick(forceRestart: true);
              } else {
                await ref
                    .read(currentOrderProvider.notifier)
                    .openManual(forceRestart: true);
              }
            }
          }();
        } else {
          if (context.mounted) context.go(AppRoutes.salesByZone);
        }
      } else {
        // Cobro de una sub-cuenta (split bill). Refrescar y verificar si
        // era la última sub-cuenta abierta: en ese caso el backend ya
        // cerró la orden (fn_process_payment_v3 → fn_close_order_and_table
        // cuando v_open_items_count == 0), así que navegamos afuera para
        // no dejar al cajero atascado en una mesa cerrada vacía.
        () async {
          await ref.read(currentOrderProvider.notifier).refreshOrder();
          final refreshed = ref.read(currentOrderProvider).order;
          final orderClosed =
              refreshed == null ||
              refreshed.closedAt != null ||
              refreshed.status == 'paid' ||
              refreshed.status == 'closed' ||
              refreshed.status == 'void' ||
              refreshed.status == 'cancelled';
          if (orderClosed && context.mounted) {
            context.go(AppRoutes.salesByZone);
          }
        }();
      }
    }

    _showSmoothDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PaymentSplitDialog(
        orderId: order.id,
        totalAmount: total,
        tableName: tableName,
        checkId: checkId,
        customerId: finalCustomerId,
        customerName: finalCustomerName,
        fiscalType: finalFiscalType,
        // onConfirmed corre con el modal de pago AÚN MONTADO. Aquí
        // hacemos la impresión y mostramos el popup de "Imprimir copia"
        // encima — así el cajero ve el modal de pago detrás, en lugar
        // de un fondo vacío. Cuando este Future resuelve, el modal de
        // pago hace pop y el .then() de abajo dispara onFinish.
        onConfirmed: (payments, {offlineNcf}) async {
          if (!context.mounted) return;

          final items = List<OrderItem>.from(prePaymentItems);
          final printOrder = prePaymentOrder;

          // Si los pagos vienen con status='pending' significa que
          // PaymentSplitViewModel cayó al fallback offline: no hay NCF
          // todavía, no hay fiscal_document. Imprimimos PRECUENTA en
          // lugar de factura — el cajero entrega un comprobante interno
          // al cliente y, cuando el sync llegue al server, el NCF se
          // emite con la fecha real (paid_at) y la factura puede
          // re-imprimirse desde el historial.
          final isOfflineQueued =
              payments.isNotEmpty &&
              payments.every((p) => p.status == 'pending');

          final businessProfile = await _loadBusinessReceiptProfile(ref);
          // Pasar el fd_id del payment recién cobrado para obtener EL fd
          // correcto. Una orden con split bill o multi-method tiene N fds
          // y getOrderFiscalDocument no puede elegir el correcto solo por
          // order_id. Post migration 0007, el RPC retorna payment con
          // fiscal_document_id seteado correctamente.
          final fdIdFromPayment = payments.isNotEmpty
              ? payments.last.fiscalDocumentId
              : null;
          final fiscalDoc = await _loadFiscalDocument(
            ref,
            order.id,
            fiscalDocumentId: fdIdFromPayment,
          );
          final waiterName =
              await _loadWaiterName(ref, order.id) ??
              ref.read(sessionProvider).userName;
          final issuedAt =
              fiscalDoc?.issuedAt ??
              (payments.isNotEmpty
                  ? payments
                        .map((payment) => payment.createdAt)
                        .reduce((a, b) => a.isAfter(b) ? a : b)
                  : order.createdAt);

          final ncfFromPayment = payments.isNotEmpty
              ? payments.last.reference
              : null;
          final printedFiscalType = fiscalDoc?.ncfType ?? finalFiscalType;

          if (!context.mounted) return;

          final invoicePrintLockKey = _printActionKey(
            'invoice',
            orderId: printOrder.id,
            checkId: checkId,
          );
          final invoiceData = {
            'title': '*** FACTURA ***',
            'restaurantName': businessProfile.name,
            'legalName': businessProfile.legalName,
            'rnc': businessProfile.rnc,
            'phone': businessProfile.phone,
            'address': businessProfile.address,
            'ncf': ncfFromPayment ?? fiscalDoc?.ncfNumber,
            'fiscalType': printedFiscalType,
            'customerName': finalCustomerName,
            'customerLegalName': finalCustomerLegalName,
            'customerTaxId': finalCustomerTaxId,
            'deliveryAddress': ref.read(currentOrderProvider).deliveryAddress,
            'issuedAt': issuedAt.toIso8601String(),
            'tableName': tableName,
            'waiterName': waiterName,
            'items': items
                .map(
                  (i) => {
                    'quantity': i.quantity,
                    'name': i.productName,
                    'price': itemDisplayTotal(printOrder, i),
                  },
                )
                .toList(),
            'subtotal': printOrder.subtotal,
            'tax': printOrder.tax,
            'serviceFee': printOrder.serviceFee,
            'total': printOrder.total,
          };

          // Cobro offline: imprimimos precuenta (sin NCF) en lugar de
          // la factura. Reusamos el destination picker de precuenta para
          // que respete la impresora fijada del device.
          if (isOfflineQueued) {
            // F4: si el Hub asignó un NCF de papel, imprimimos el COMPROBANTE
            // con ese número en el acto (no la precuenta). _handlePrintFlow es
            // offline-seguro: el fetch del fd remoto da null (no hay QR en
            // papel) y el NCF sale de data['ncf'].
            if (offlineNcf != null) {
              final fiscalInvoiceData = Map<String, dynamic>.from(invoiceData);
              fiscalInvoiceData['ncf'] = offlineNcf;
              try {
                await _runLockedAction(ref, invoicePrintLockKey, () async {
                  await _handlePrintFlow(
                    context,
                    ref,
                    'invoice',
                    fiscalInvoiceData,
                    orderObj: printOrder,
                    orderItems: items,
                    payments: payments,
                    tableName: tableName,
                    waiterName: waiterName,
                    showSnackBar: false,
                  );
                });
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      backgroundColor: const Color(0xFF10B981),
                      behavior: SnackBarBehavior.floating,
                      content: Text(
                        'Comprobante emitido offline · NCF $offlineNcf. '
                        'Pendiente de sincronizar.',
                      ),
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      backgroundColor: const Color(0xFFEF4444),
                      content: Text('No se pudo imprimir el comprobante: $e'),
                    ),
                  );
                }
              }
              return;
            }

            final preCheckData = <String, dynamic>{
              'restaurantName': businessProfile.name,
              'businessName': businessProfile.businessName,
              'legalName': businessProfile.legalName,
              'rnc': businessProfile.rnc,
              'phone': businessProfile.phone,
              'address': businessProfile.address,
              'tableName': tableName,
              'waiterName': waiterName,
              'customerName': finalCustomerName,
              'items': items
                  .map(
                    (i) => {
                      'quantity': i.quantity,
                      'name': i.productName,
                      'price': itemDisplayTotal(printOrder, i),
                    },
                  )
                  .toList(),
              'subtotal': printOrder.subtotal,
              'tax': printOrder.tax,
              'serviceFee': printOrder.serviceFee,
              'total': printOrder.total,
            };
            try {
              await _runPrecheckWithDestinationPicker(
                context,
                ref,
                preCheckData: preCheckData,
                orderObj: printOrder,
                orderItems: items,
                forcePicker: false,
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    backgroundColor: Color(0xFFF59E0B),
                    behavior: SnackBarBehavior.floating,
                    content: Text(
                      'Pago guardado offline. Precuenta impresa. El comprobante fiscal se emitirá al sincronizar.',
                    ),
                  ),
                );
              }
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: const Color(0xFFEF4444),
                    content: Text('No se pudo imprimir la precuenta: $e'),
                  ),
                );
              }
            }
            return;
          }

          try {
            await _runLockedAction(ref, invoicePrintLockKey, () async {
              await _handlePrintFlow(
                context,
                ref,
                'invoice',
                invoiceData,
                orderObj: printOrder,
                orderItems: items,
                payments: payments,
                tableName: tableName,
                waiterName: waiterName,
                showSnackBar: true,
              );
            });
            if (context.mounted) {
              await showPaymentSuccessDialog(
                context: context,
                onReprint: () async {
                  // Marcamos el ticket como "COPIA" para que se
                  // distinga del original y no se confunda con una
                  // segunda venta.
                  final copyData = Map<String, dynamic>.from(invoiceData);
                  copyData['title'] = '*** COPIA - FACTURA ***';
                  await _handlePrintFlow(
                    context,
                    ref,
                    'invoice',
                    copyData,
                    orderObj: printOrder,
                    orderItems: items,
                    payments: payments,
                    tableName: tableName,
                    waiterName: waiterName,
                    showSnackBar: true,
                  );
                },
              );
            }
          } catch (e) {
            if (context.mounted) {
              // AWAIT explicito: este Future no resuelve hasta que el
              // cajero o bien reimprime con exito, o bien elige
              // "Continuar sin imprimir". Esto mantiene el modal de
              // pago abierto mientras tanto — el cajero NO puede salir
              // por accidente sin haber visto el ticket.
              await _showReimpresionDialog(
                context: context,
                ref: ref,
                type: 'invoice',
                data: invoiceData,
                orderObj: order,
                orderItems: items,
                payments: payments,
                tableName: tableName,
                waiterName: waiterName,
                errorMsg: e.toString(),
                // onFinish ya corre desde el .then() del modal de pago,
                // así que no lo pasamos aquí — evita doble navegación.
              );
            }
          }
        },
      ),
    ).then((result) {
      if (result is List<Payment>) {
        onFinish();
      }
    });
  }

  void _openSplitBillModal(BuildContext context, WidgetRef ref, Order order) {
    _showSmoothDialog(
      context: context,
      builder: (context) => SplitBillModal(
        order: order,
        onSplitApplied: () {
          // Refrescar la orden actual
          ref.read(currentOrderProvider.notifier).refreshOrder();
        },
      ),
    );
  }

  // PRD 4: abre el selector de mesas en flujo Manual.
  // El modal llama internamente a `assignManualOrderToTable`, que convierte
  // la orden a origin=table y refresca el state. OrderScreen reacciona solo.
  void _openTableSelector(BuildContext context, WidgetRef ref, String orderId) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.85,
        child: TableSelectorModal(orderId: orderId),
      ),
    );
  }

  void _openProductDetailModal(
    BuildContext context,
    WidgetRef ref,
    OrderItem item, {
    List<OrderItem>? groupedItems,
  }) {
    showDialog(
      context: context,
      builder: (context) => ProductDetailModal(
        item: item,
        groupedItems: groupedItems,
        loadModifierGroups: (menuItemId) => ref
            .read(currentOrderProvider.notifier)
            .getMenuItemModifierGroups(menuItemId),
        onReplaceModifiers: (itemId, selectedModifiers) => ref
            .read(currentOrderProvider.notifier)
            .replaceItemModifiers(
              itemId: itemId,
              selectedModifiers: selectedModifiers,
            ),
        onSave: (updatedItem) async {
          await ref
              .read(currentOrderProvider.notifier)
              .updateItem(item.id, updatedItem);
        },
        onSaveBatch: (items, updatedItem, reductionReason) async {
          final salesRepo = ref.read(salesRepositoryProvider);
          final orderNotifier = ref.read(currentOrderProvider.notifier);
          final totalBase = items.fold<double>(
            0,
            (sum, current) => sum + (current.subtotal + current.tax),
          );
          final originalTotalQty = items.fold<double>(
            0,
            (sum, current) => sum + current.quantity,
          );
          final targetTotalQty = updatedItem.quantity <= 0
              ? 1.0
              : updatedItem.quantity;
          if (targetTotalQty < originalTotalQty) {
            // Si TODOS los items consolidated estan en draft no requiere
            // PIN — el operador esta reduciendo cantidades antes de
            // enviar a cocina. Si alguno ya salio impreso, mantenemos la
            // proteccion.
            final allDraft = items.every((i) => i.status == 'draft');
            if (!await _ensureCanDeleteOrderItem(
              context,
              ref,
              isDraft: allDraft,
            )) {
              return;
            }
          }
          // Fase 1 Toast redesign: distribución discreta sin fracciones.
          // - Si reducimos: caminar de la primera a la última fila, mantener
          //   cada fila completa mientras quepa; cuando ya no cabe, truncar
          //   esa fila al sobrante (entero) y borrar las restantes.
          // - Si aumentamos: dejar cada fila intacta; el delta se suma a la
          //   última fila.
          // El target se redondea a entero porque el modal sólo permite
          // unidades enteras post-rediseño; el round es defensa.
          final isReducing = targetTotalQty < originalTotalQty;
          var remaining = targetTotalQty.round();

          for (var index = 0; index < items.length; index++) {
            final current = items[index];
            final isLast = index == items.length - 1;
            final currentQtyInt = current.quantity.round();
            int nextQtyInt;

            if (isReducing) {
              if (remaining >= currentQtyInt) {
                nextQtyInt = currentQtyInt;
              } else {
                nextQtyInt = remaining < 0 ? 0 : remaining;
              }
            } else {
              nextQtyInt = isLast ? remaining : currentQtyInt;
            }

            final nextQty = nextQtyInt.toDouble();

            final base = current.subtotal + current.tax;
            final discountShare = totalBase > 0
                ? (updatedItem.discounts * (base / totalBase))
                : 0.0;
            final trimmedNotes = updatedItem.notes?.trim();
            final mergedNotes = <String>[];
            if (trimmedNotes != null && trimmedNotes.isNotEmpty) {
              mergedNotes.add(trimmedNotes);
            }
            if (reductionReason != null && reductionReason.trim().isNotEmpty) {
              mergedNotes.add('[REDUCCION:${reductionReason.trim()}]');
            }

            if (nextQty <= 0.0001) {
              await orderNotifier.deleteItem(
                current.id,
                reason: reductionReason ?? 'Reducción de cantidad',
              );
            } else {
              await salesRepo.updateItemDetails(
                itemId: current.id,
                productName: updatedItem.productName,
                quantity: nextQty,
                isTakeout: updatedItem.isTakeout,
                discounts: discountShare,
                notes: mergedNotes.isEmpty ? null : mergedNotes.join('\n'),
              );
            }

            remaining -= nextQtyInt;
            if (remaining < 0) remaining = 0;
          }

          await ref.read(currentOrderProvider.notifier).refreshOrder();
        },
        onDelete: (reason) async {
          // Fase 1 Toast redesign: si el modal se abrió desde TODAS (varias
          // filas del mismo producto agrupadas porque están en distintos
          // checks), borrar todo el grupo. Si se abrió desde una sub-cuenta
          // (groupedItems == null o de tamaño 1), borrar sólo la fila actual.
          // Esto evita el bug histórico donde "Eliminar" desde TODAS dejaba
          // fantasmas en los otros checks.
          final orderNotifier = ref.read(currentOrderProvider.notifier);
          final group = groupedItems;
          if (group != null && group.length > 1) {
            for (final row in group) {
              await orderNotifier.deleteItem(row.id, reason: reason);
            }
          } else {
            await orderNotifier.deleteItem(item.id, reason: reason);
          }
        },
        onBeforeDelete: () => _ensureCanDeleteOrderItem(
          context,
          ref,
          isDraft: item.status == 'draft',
        ),
        onMarkSoldOut: item.productId == null
            ? null
            : () async {
                await ref
                    .read(salesRepositoryProvider)
                    .setMenuItemAvailability(
                      menuItemId: item.productId!,
                      isActive: false,
                    );
                await ref
                    .read(menuBrowserVmProvider.notifier)
                    .loadAll(
                      preselectCategoryId: ref
                          .read(menuBrowserVmProvider)
                          .selectedCategoryId,
                    );
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '${item.productName} quedó marcado como agotado',
                    ),
                  ),
                );
              },
        onReprint: (item.status != 'draft')
            ? () {
                final order = ref.read(currentOrderProvider).order;
                final itemsToReprint = groupedItems?.isNotEmpty == true
                    ? groupedItems!
                    : [item];
                if (order == null) return;

                final reprintLockKey = _reprintActionKey(
                  order.id,
                  itemsToReprint,
                );
                // El lock está vivo si tiene timestamp dentro de la
                // ventana _kLockMaxAge. Locks expirados se ignoran y el
                // _runLockedAction posterior los va a sobrescribir.
                final now = DateTime.now().millisecondsSinceEpoch;
                final ts = ref.read(_salesActionLocksProvider)[reprintLockKey];
                if (ts != null && now - ts < _kLockMaxAge.inMilliseconds) {
                  return;
                }

                unawaited(
                  _runLockedAction(ref, reprintLockKey, () async {
                    await ref
                        .read(currentOrderProvider.notifier)
                        .reprintKitchenTicket(
                          orderId: order.id,
                          items: itemsToReprint,
                        );
                  }),
                );
              }
            : null,
      ),
    );
  }

  /// Helper para transiciones suaves
  Future<T?> _showSmoothDialog<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
  }) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black54, // Fondo oscuro estándar
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (ctx, anim1, anim2) => builder(ctx),
      transitionBuilder: (ctx, anim1, anim2, child) {
        // Combinación de Fade y Scale para un efecto "Pop" suave
        return FadeTransition(
          opacity: CurvedAnimation(parent: anim1, curve: Curves.easeOut),
          child: ScaleTransition(
            scale: CurvedAnimation(
              parent: anim1,
              curve: Curves.easeOutBack, // Rebote muy sutil
            ),
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orderState = ref.watch(currentOrderProvider); // RESTORED
    // Tablet = ancho lógico < 1200 (mismo corte que el layout principal, que
    // reserva el cart de 400px solo para >= 1200). En tablet bajamos 4px el
    // título de la mesa; en desktop se mantiene en 20.
    final isTablet = MediaQuery.sizeOf(context).width < 1200;
    // Retail: habilita el botón "Pausar venta" (hold) junto a Pagar.
    final isRetail = ref.watch(currentBusinessModelProvider).isRetail;
    final sessionCtrl = ref.read(sessionProvider.notifier);
    final canCharge = sessionCtrl.hasAnyPermission([
      'pagos.acceso',
      'pagos.cobrar_efectivo',
      'pagos.cobrar_tarjeta',
      'pagos.cobrar_transferencia',
    ]);
    final allItems = orderState.items; // RESTORED
    final openItems = allItems.where(_isOpenItem).toList();

    final selectedCheckId = orderState.selectedCheckId;
    final allChecks = orderState.checks;
    OrderCheck? selectedCheck;
    if (selectedCheckId != null) {
      for (final check in allChecks) {
        if (check.id == selectedCheckId) {
          selectedCheck = check;
          break;
        }
      }
    }
    final activeChecks = allChecks.where((c) => !c.isClosed).toList();
    final hasChecks =
        activeChecks.length > 1 ||
        (activeChecks.length == 1 && activeChecks.first.position > 1);

    // Filter Items
    final List<OrderItem> displayedItems;
    if (selectedCheckId != null) {
      displayedItems = openItems
          .where((i) => i.checkId == selectedCheckId)
          .toList();
    } else {
      // Global View (TODAS)
      // Filter out items from closed checks (paid subcuentas)
      displayedItems = openItems.where((i) {
        final checkIsClosed = allChecks.any(
          (c) => c.id == i.checkId && c.isClosed,
        );
        return !checkIsClosed;
      }).toList();
    }

    // 2. Summary
    final pricingSummary = summarizeOrderPricing(
      orderState.order,
      displayedItems,
      forcedOrigin: orderState.origin,
    );
    final displayTotal = pricingSummary.total;

    final vm = ref.read(currentOrderProvider.notifier);
    final taxBreakdown = vm.getTaxBreakdown(pricingSummary.subtotal);
    final rawBreakdown = buildOrderTaxBreakdown(
      orderState.order,
      displayedItems,
      forcedOrigin: orderState.origin,
      configuredBreakdown: taxBreakdown,
    );

    // Aplicamos el modo de presentación del descuento elegido por el
    // negocio (business_settings.discount_display_mode). Ver
    // `discountDisplayModeProvider` y print_ticket_service.generateInvoice
    // para la fuente única de la lógica. Hasta que el provider resuelva
    // la primera lectura usamos el default 'pre_discount' (= modo A,
    // comportamiento histórico).
    final activeBusinessId = ref.watch(sessionProvider).activeBusinessId ?? '';
    final discountModeAsync = ref.watch(
      discountDisplayModeProvider(activeBusinessId),
    );
    final discountMode =
        discountModeAsync.valueOrNull ??
        PosSettingsRepository.discountPreDiscount;
    final isPostDiscountMode =
        discountMode == PosSettingsRepository.discountPostDiscount;

    // Detección de tasas uniformes: si TODAS las líneas de tax tienen
    // la misma tasa Y la tasa efectiva de la orden coincide con la
    // suma de las tasas declaradas, podemos aplicar el recompute del
    // modo de descuento (subtotal = (total + descuento) / (1 + tasa)).
    //
    // Caso típico donde NO aplica:
    //   - Mezcla takeout + dine-in: items takeout tienen tax_rate=0 y
    //     dine-in tienen tax_rate=10. La tasa efectiva real
    //     (summary.tax / summary.subtotal) es menor que la tasa
    //     declarada en taxBreakdown (10%). Recompute daría números
    //     incorrectos. En ese caso usamos los valores nativos del
    //     summary, que son correctos por item.
    final lineRates = <double?>[];
    for (final entry in rawBreakdown) {
      lineRates.add(_parseCartRatePercent(entry.label));
    }
    final allRatesKnown = rawBreakdown.isNotEmpty && !lineRates.contains(null);
    final declaredRate = allRatesKnown
        ? lineRates.fold<double>(0, (s, r) => s + (r ?? 0)) / 100.0
        : 0.0;
    final actualRate = pricingSummary.subtotal > 0.005
        ? (pricingSummary.tax + pricingSummary.serviceFee) /
              pricingSummary.subtotal
        : 0.0;
    final ratesAreUniform = (actualRate - declaredRate).abs() < 0.001;
    final canRecompute = allRatesKnown && declaredRate > 0 && ratesAreUniform;

    final double displaySubtotal;
    final List<({String label, double amount})> reconciledBreakdown;
    final double displayDiscounts;
    if (canRecompute) {
      final discountForBase = isPostDiscountMode
          ? 0.0
          : pricingSummary.discounts;
      final subtotalBase =
          (displayTotal + discountForBase) / (1 + declaredRate);
      displaySubtotal = subtotalBase;
      reconciledBreakdown = [
        for (var i = 0; i < rawBreakdown.length; i++)
          (
            label: rawBreakdown[i].label,
            amount: subtotalBase * ((lineRates[i] ?? 0) / 100),
          ),
      ];
      // En modo B el descuento sale como nota informativa fuera del
      // sum aditivo: ocultamos la línea sustractiva pasando 0 y
      // dejamos que el subtotal/ITBIS deriven del total post-descuento.
      displayDiscounts = isPostDiscountMode ? 0.0 : pricingSummary.discounts;
    } else {
      // Fallback: tasas mixtas (ej. takeout + dine-in juntos), sin
      // tasa parseable, o no aplicable. Usamos los valores nativos
      // del summary — son correctos porque se computan item por item.
      displaySubtotal = pricingSummary.subtotal;
      reconciledBreakdown = rawBreakdown;
      displayDiscounts = pricingSummary.discounts;
    }

    final pendingOrderItems = openItems.where((i) {
      final checkIsClosed = allChecks.any(
        (c) => c.id == i.checkId && c.isClosed,
      );
      return !checkIsClosed;
    }).toList();

    final pendingOrderTotal = summarizeOrderPricing(
      orderState.order,
      pendingOrderItems,
    ).total;

    final currency = NumberFormat('#,##0.00', 'en_US');

    // Group items for display.
    // El orden se invierte para que los productos agregados más recientemente
    // aparezcan ARRIBA. Items agrupados (mismo nombre/takeout) toman el orden
    // del más reciente porque la iteración entra primero.
    final sentItems = displayedItems.reversed
        .where((i) => i.status != 'draft')
        .toList(growable: false);
    final draftItems = displayedItems.reversed
        .where((i) => i.status == 'draft')
        .toList(growable: false);
    final itemsCount = _sumItemQty(
      displayedItems,
    ); // Cantidad real, no cantidad de líneas

    final Map<String, _GroupedSentItem> groupedSent = {};
    for (final item in sentItems) {
      final name = item.productName;
      final qty = item.quantity.toDouble();
      final totalItem = _uiItemDisplayAmount(orderState.order, item);
      final groupKey = '${name.toLowerCase().trim()}|${item.isTakeout}';
      if (groupedSent.containsKey(groupKey)) {
        groupedSent[groupKey] = groupedSent[groupKey]!.copyWith(
          qty: groupedSent[groupKey]!.qty + qty,
          total: groupedSent[groupKey]!.total + totalItem,
          items: [...groupedSent[groupKey]!.items, item],
        );
      } else {
        groupedSent[groupKey] = _GroupedSentItem(
          name: name,
          qty: qty,
          total: totalItem,
          isTakeout: item.isTakeout,
          items: [item],
        );
      }
    }
    final groupedSentItems = groupedSent.values.toList();
    // Solo mostrar el panel "Última anulación" si la orden actual está
    // anulada/cerrada. Si la orden actual es nueva pero la sesión tiene
    // historial de anulación, no aplica al momento actual.
    final currentOrder = orderState.order;
    final isCurrentOrderVoided =
        currentOrder != null &&
        (currentOrder.status == 'void' ||
            currentOrder.status == 'cancelled' ||
            currentOrder.closedAt != null);
    final latestVoidAudit = isCurrentOrderVoided
        ? _extractLatestVoidAudit(orderState.sessionNote)
        : null;
    final currentOrderId = orderState.order?.id;
    final sendKitchenLockKey = _sendKitchenActionKey(currentOrderId);
    final precheckLockKey = _printActionKey(
      'precheck',
      orderId: currentOrderId,
      checkId: selectedCheckId,
    );
    // Solo bloqueamos por el lock TTL específico de la acción. Antes
    // también dependíamos de `orderState.loading`, pero ese flag puede
    // quedar pegado si un fetch/persist HTTP se cuelga, y dejaba el
    // botón inservible aún cuando la operación de envío a cocina sí
    // podía proceder. El lock TTL (60s) es la única gate confiable.
    final sendKitchenLocked = _isActionLocked(ref, sendKitchenLockKey);
    final precheckLocked = _isActionLocked(ref, precheckLockKey);

    return Column(
      children: [
        if (!isStacked)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Encabezado apilado verticalmente: el título va a todo el
                // ancho del panel (320–400px) y los controles de Cliente /
                // Comprobante debajo, también a ancho completo. Antes iban en
                // un Row lado a lado, lo que en tablet comprimía el título a
                // ~60px y lo rompía carácter por carácter ("Me sa T0 3").
                // Solo en tablet (< 1200) usamos el encabezado apilado en dos
                // filas (Mesa+Cliente / Productos+Comprobante). En desktop
                // (>= 1200) se conserva el layout original de una sola fila.
                if (isTablet) ...[
                  // Fila "Mesa": título + botón Cliente a la derecha.
                  // Fila "Productos": subtítulo + selector de comprobante.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          origin == OrderOrigin.table
                              ? (tableCode.toLowerCase().startsWith('mesa')
                                    ? tableCode
                                    : 'Mesa $tableCode')
                              : origin == OrderOrigin.delivery
                              ? 'Delivery ${tableCode.isNotEmpty ? " • $tableCode" : ""}'
                              : origin == OrderOrigin.manual
                              ? 'Venta Manual ${tableCode.isNotEmpty ? " • $tableCode" : ""}'
                              : 'Venta Rápida',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: isTablet ? 16 : 20,
                            fontWeight: FontWeight.w600,
                            color: _salesTextPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 168,
                        height: 40,
                        child: OutlinedButton.icon(
                          onPressed: onAssignClient,
                          icon: const Icon(Icons.person_outline, size: 16),
                          label: Text(
                            _resolveHeaderCustomerName(orderState),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _salesTotalColor,
                            side: const BorderSide(color: _salesDivider),
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                _salesRadiusButton,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          '${_formatQtyBadge(itemsCount)} ${itemsCount == 1 ? "producto" : "productos"}',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: const TextStyle(
                            fontSize: 14,
                            color: _salesTextSecondary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 168,
                        height: 40,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            border: Border.all(color: _salesDivider),
                            borderRadius: BorderRadius.circular(
                              _salesRadiusButton,
                            ),
                          ),
                          child: Builder(
                            builder: (context) {
                              final activeSequences = orderState.fiscalSequences
                                  .where((sequence) => sequence.activo)
                                  .toList(growable: false);
                              final selectedFiscalType = _normalizeFiscalType(
                                orderState.fiscalType,
                              );
                              final initialValue =
                                  activeSequences.any(
                                    (sequence) => _matchesFiscalSequenceType(
                                      sequence,
                                      selectedFiscalType,
                                    ),
                                  )
                                  ? selectedFiscalType
                                  : null;

                              return PopupMenuButton<String>(
                                initialValue: initialValue,
                                onSelected: (String newValue) {
                                  ref
                                      .read(currentOrderProvider.notifier)
                                      .updateFiscalType(newValue);
                                },
                                tooltip: 'Tipo de comprobante',
                                padding: EdgeInsets.zero,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                offset: const Offset(0, 40),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        selectedFiscalType.isEmpty
                                            ? 'Sin configurar'
                                            : '${_getNcfLabel(selectedFiscalType)} ($selectedFiscalType)',
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: _salesTextPrimary,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    const Icon(
                                      Icons.arrow_drop_down,
                                      color: _salesTotalColor,
                                      size: 20,
                                    ),
                                  ],
                                ),
                                itemBuilder: (BuildContext context) {
                                  if (activeSequences.isEmpty) {
                                    return const [
                                      PopupMenuItem<String>(
                                        enabled: false,
                                        value: '__no_sequences__',
                                        child: Text(
                                          'Sin secuencias fiscales activas',
                                        ),
                                      ),
                                    ];
                                  }

                                  return activeSequences.map((seq) {
                                    return PopupMenuItem<String>(
                                      value: seq.tipo,
                                      child: Text(
                                        '${_getNcfLabel(seq.tipo)} (${seq.tipo})',
                                      ),
                                    );
                                  }).toList();
                                },
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (selectedCheckId != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'Subcuenta',
                          style: TextStyle(
                            fontSize: 10,
                            color: Color(0xFFF97316),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (orderState.isOfflineMode ||
                      orderState.syncInFlight ||
                      orderState.pendingOfflineActions > 0) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _OrderSyncStatusChip(orderState: orderState),
                    ),
                  ],
                ] else ...[
                  // Encabezado original (desktop >= 1200): título + bloque de
                  // controles (Cliente / Comprobante) en una sola fila.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              origin == OrderOrigin.table
                                  ? (tableCode.toLowerCase().startsWith('mesa')
                                        ? tableCode
                                        : 'Mesa $tableCode')
                                  : origin == OrderOrigin.delivery
                                  ? 'Delivery ${tableCode.isNotEmpty ? " • $tableCode" : ""}'
                                  : origin == OrderOrigin.manual
                                  ? 'Venta Manual ${tableCode.isNotEmpty ? " • $tableCode" : ""}'
                                  : 'Venta Rápida',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                                color: _salesTextPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${_formatQtyBadge(itemsCount)} ${itemsCount == 1 ? "producto" : "productos"}',
                              style: const TextStyle(
                                fontSize: 14,
                                color: _salesTextSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (selectedCheckId != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.blue.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'Subcuenta',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Color(0xFFF97316),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          const SizedBox(height: 8),
                          if (orderState.isOfflineMode ||
                              orderState.syncInFlight ||
                              orderState.pendingOfflineActions > 0)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _OrderSyncStatusChip(
                                orderState: orderState,
                              ),
                            ),
                          OutlinedButton.icon(
                            onPressed: onAssignClient,
                            icon: const Icon(Icons.person_outline, size: 16),
                            label: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 148),
                              child: Text(
                                _resolveHeaderCustomerName(orderState),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: _salesTotalColor,
                              side: const BorderSide(color: _salesDivider),
                              minimumSize: const Size(0, 36),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  _salesRadiusButton,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            height: 36,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              border: Border.all(color: _salesDivider),
                              borderRadius: BorderRadius.circular(
                                _salesRadiusButton,
                              ),
                            ),
                            child: Builder(
                              builder: (context) {
                                final activeSequences = orderState
                                    .fiscalSequences
                                    .where((sequence) => sequence.activo)
                                    .toList(growable: false);
                                final selectedFiscalType = _normalizeFiscalType(
                                  orderState.fiscalType,
                                );
                                final initialValue =
                                    activeSequences.any(
                                      (sequence) => _matchesFiscalSequenceType(
                                        sequence,
                                        selectedFiscalType,
                                      ),
                                    )
                                    ? selectedFiscalType
                                    : null;

                                return PopupMenuButton<String>(
                                  initialValue: initialValue,
                                  onSelected: (String newValue) {
                                    ref
                                        .read(currentOrderProvider.notifier)
                                        .updateFiscalType(newValue);
                                  },
                                  tooltip: 'Tipo de comprobante',
                                  padding: EdgeInsets.zero,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  offset: const Offset(0, 40),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          selectedFiscalType.isEmpty
                                              ? 'Sin configurar'
                                              : '${_getNcfLabel(selectedFiscalType)} ($selectedFiscalType)',
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: _salesTextPrimary,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        const Icon(
                                          Icons.arrow_drop_down,
                                          color: _salesTotalColor,
                                          size: 20,
                                        ),
                                      ],
                                    ),
                                  ),
                                  itemBuilder: (BuildContext context) {
                                    if (activeSequences.isEmpty) {
                                      return const [
                                        PopupMenuItem<String>(
                                          enabled: false,
                                          value: '__no_sequences__',
                                          child: Text(
                                            'Sin secuencias fiscales activas',
                                          ),
                                        ),
                                      ];
                                    }

                                    return activeSequences.map((seq) {
                                      return PopupMenuItem<String>(
                                        value: seq.tipo,
                                        child: Text(
                                          '${_getNcfLabel(seq.tipo)} (${seq.tipo})',
                                        ),
                                      );
                                    }).toList();
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),

        // Dirección de entrega (delivery + setting activo). Campo opcional.
        if (origin == OrderOrigin.delivery && deliveryAddressEnabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _DeliveryAddressBar(
              address: orderState.deliveryAddress,
              onEdit: () => _editDeliveryAddress(context, ref, orderState),
            ),
          ),

        if (orderState.order != null ||
            (orderState.sessionNote?.trim().isNotEmpty ?? false))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              children: [
                if (orderState.order != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (orderState.order!.closedAt != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFF6FF),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: const Color(0xFFBFDBFE),
                              ),
                            ),
                            child: Text(
                              'Cerrada ${DateFormat('dd/MM HH:mm').format(orderState.order!.closedAt!.toLocal())}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF1D4ED8),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (latestVoidAudit != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFFECACA)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.history_toggle_off,
                          color: Color(0xFFDC2626),
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Última anulación registrada',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF991B1B),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                latestVoidAudit,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF7F1D1D),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

        // CHECK SELECTOR (TABS)
        if (hasChecks)
          Container(
            height: 98,
            width: double.infinity,
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: _salesDivider)),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              child: Row(
                children: [
                  _BigCheckSelector(
                    label: 'TODAS',
                    isSelected: selectedCheckId == null,
                    onTap: () => ref
                        .read(currentOrderProvider.notifier)
                        .selectCheck(null),
                    itemCount: _sumItemQty(openItems),
                    isGlobal: true,
                  ),
                  const SizedBox(width: 8),
                  ...activeChecks
                      .where(
                        (c) => !hasChecks || c.position > 1,
                      ) // Ocultar cuenta principal si esta dividida
                      .map((check) {
                        final isSelected = check.id == selectedCheckId;
                        final checkItemsCount = _sumItemQty(
                          openItems.where((i) => i.checkId == check.id),
                        );
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _BigCheckSelector(
                            label: check.label.isEmpty
                                ? 'C${check.position}'
                                : check.label,
                            isSelected: isSelected,
                            itemCount: checkItemsCount,
                            onTap: () => ref
                                .read(currentOrderProvider.notifier)
                                .selectCheck(check.id),
                          ),
                        );
                      }),
                ],
              ),
            ),
          ),

        if (!isStacked && !hasChecks)
          Container(height: 1, color: _salesDivider),

        Expanded(
          child: displayedItems.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'No hay productos',
                        style: TextStyle(
                          fontSize: 14,
                          color: _salesTextSecondary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        selectedCheckId != null
                            ? 'Esta subcuenta está vacía'
                            : 'Selecciona productos del menú',
                        style: const TextStyle(
                          fontSize: 13,
                          color: _salesTextHint,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView(
                  // Solo en tablet subimos "ENVIADOS A COCINA" con un top
                  // reducido (10 vs 24). Desktop conserva el padding original.
                  padding: EdgeInsets.fromLTRB(
                    isStacked ? 12 : 24,
                    isStacked ? 8 : (isTablet ? 10 : 24),
                    isStacked ? 12 : 24,
                    isStacked ? 12 : 24,
                  ),
                  children: [
                    // UX: cuando hay items en draft (POR CONFIRMAR),
                    // ocultamos los ya enviados para reducir ruido visual
                    // — el mesero solo ve lo que está agregando en este
                    // momento. Al confirmar (enviar a cocina) los drafts
                    // pasan a status 'sent' y todo se muestra junto otra
                    // vez en la siguiente render.
                    if (groupedSentItems.isNotEmpty && draftItems.isEmpty) ...[
                      const _SectionLabel(
                        label: 'ENVIADOS A COCINA',
                        color: Color(0xFF22C55E),
                      ),
                      const SizedBox(height: 6),
                      // Encabezado de columnas
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: _salesDivider),
                          ),
                        ),
                        child: Row(
                          children: const [
                            SizedBox(
                              width: 52,
                              child: Text(
                                'Cant.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: _salesTextSecondary,
                                ),
                              ),
                            ),
                            SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Producto',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: _salesTextSecondary,
                                ),
                              ),
                            ),
                            SizedBox(width: 6),
                            Text(
                              'Precio',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: _salesTextSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Column(
                        children: [
                          for (int i = 0; i < groupedSentItems.length; i++) ...[
                            _SentLineItem(
                              name: groupedSentItems[i].name,
                              qty: groupedSentItems[i].qty,
                              total: groupedSentItems[i].total,
                              isTakeout: groupedSentItems[i].isTakeout,
                              auditItem: groupedSentItems[i].items.first,
                              orderOrigin: orderState.order?.origin,
                              groupSize: groupedSentItems[i].items.length,
                              onTap: () => _openProductDetailModal(
                                context,
                                ref,
                                groupedSentItems[i].items.first,
                                groupedItems: groupedSentItems[i].items,
                              ),
                            ),
                            if (i < groupedSentItems.length - 1)
                              const Divider(
                                height: 12,
                                color: _salesDivider,
                                thickness: 0.8,
                              ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (draftItems.isNotEmpty) ...[
                      const _SectionLabel(
                        label: 'POR CONFIRMAR',
                        color: Color(0xFFF59E0B),
                      ),
                      const SizedBox(height: 8),
                      // Encabezado
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: _salesDivider),
                          ),
                        ),
                        child: Row(
                          children: const [
                            SizedBox(
                              width: 52,
                              child: Text(
                                'Cant.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: _salesTextSecondary,
                                ),
                              ),
                            ),
                            SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Producto',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: _salesTextSecondary,
                                ),
                              ),
                            ),
                            SizedBox(width: 6),
                            Text(
                              'Precio',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: _salesTextSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      ...draftItems.map((item) {
                        final line = _CartLineItem(
                          item: item,
                          isDraft: true,
                          onTap: () =>
                              _openProductDetailModal(context, ref, item),
                          onDelete: () async {
                            // Items en draftItems son por definicion
                            // status='draft' (filtrados arriba), pero
                            // pasamos el chequeo igual por defensa.
                            if (!await _ensureCanDeleteOrderItem(
                              context,
                              ref,
                              isDraft: item.status == 'draft',
                            )) {
                              return;
                            }
                            await ref
                                .read(currentOrderProvider.notifier)
                                .deleteItem(item.id);
                          },
                        );
                        // Animar SOLO el item optimista (tmp) al aparecer →
                        // feedback inmediato. El real reconciliado (y los items
                        // al abrir la mesa) entran SEAMLESS, sin re-flash. La
                        // key estable mantiene la reconciliación correcta.
                        return item.id.startsWith('tmp_')
                            ? line
                                  .animate(
                                    key: ValueKey('cart_anim_${item.id}'),
                                  )
                                  .fadeIn(duration: 160.ms)
                                  .slideX(
                                    begin: -0.04,
                                    end: 0,
                                    duration: 160.ms,
                                    curve: Curves.easeOut,
                                  )
                            : KeyedSubtree(
                                key: ValueKey('cart_${item.id}'),
                                child: line,
                              );
                      }),
                    ],
                  ],
                ),
        ),
        Container(height: 1, color: _salesDivider),
        // PRD 6 F2.1: padding adaptativo en compact para ganar espacio
        // vertical sin perder el pin al bottom (panel sigue al pie del cart).
        Padding(
          padding: EdgeInsets.all(
            isStacked || Breakpoints.isCompact(context) ? 12 : 24,
          ),
          child: Column(
            children: [
              _SummaryRow(
                label: 'Subtotal',
                value: 'RD\$ ${currency.format(displaySubtotal)}',
              ),
              for (final entry in reconciledBreakdown) ...[
                const SizedBox(height: 8),
                _SummaryRow(
                  label: entry.label,
                  value: 'RD\$ ${currency.format(entry.amount)}',
                ),
              ],
              if (displayDiscounts > 0) ...[
                const SizedBox(height: 8),
                _SummaryRow(
                  label: 'Descuento',
                  value: '- RD\$ ${currency.format(displayDiscounts)}',
                  valueColor: const Color(0xFF16A34A),
                  valueWeight: FontWeight.w700,
                ),
              ],
              const SizedBox(height: 12),
              _SummaryRow(
                label: 'Total',
                value: 'RD\$ ${currency.format(displayTotal)}',
                valueColor: _salesTotalColor,
                valueWeight: FontWeight.w700,
              ),
              // Modo post_discount: el descuento no está en el sum
              // aditivo (subtotal+ITBIS = total). Lo mostramos como nota
              // informativa debajo del Total para que el cajero sepa
              // que se aplicó un ahorro al cliente.
              if (isPostDiscountMode && pricingSummary.discounts > 0) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    'Incluye descuento aplicado de '
                    'RD\$ ${currency.format(pricingSummary.discounts)}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF6B7280),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ],

              // REMOVED OLD SPLIT PREVIEW PANEL
              if (allItems.isNotEmpty) ...[
                // Use allItems check to keep buttons visible even if view is empty? No prefer items check.
                const SizedBox(height: 16),
                // PRD 4: en Venta Manual ofrecer asignar mesa al final del flujo.
                if (origin == OrderOrigin.manual &&
                    orderState.order != null) ...[
                  _SecondaryActionButton(
                    label: 'Asignar a Mesa',
                    icon: Icons.table_restaurant_outlined,
                    onPressed: orderState.loading
                        ? null
                        : () => _openTableSelector(
                            context,
                            ref,
                            orderState.order!.id,
                          ),
                  ),
                  const SizedBox(height: 8),
                ],
                // Bloque para órdenes con items DRAFT (recién agregados,
                // sin enviar). Muestra:
                //   - Enviar Pedido (sólo si el feature `kitchen_enabled`
                //     está prendido — para kioskos/minimarkets sin cocina
                //     este botón no tiene sentido y los items se marcan
                //     ready en el momento del cobro).
                //   - Pagar (SIEMPRE, independiente de kitchen_enabled —
                //     el cajero tiene que poder cobrar drafts en un
                //     negocio sin cocina sin pasar por "enviar primero").
                //
                // Fix bug 2026-05-27: antes el check de kitchen_enabled
                // envolvía el bloque entero, lo que escondía Pagar en
                // negocios sin cocina y dejaba al usuario sin forma de
                // cobrar drafts.
                if (draftItems.isNotEmpty) ...[
                  if (ref.watchBusinessFeatures().kitchenEnabled) ...[
                    _ActionButton(
                      label: 'Enviar Pedido',
                      background: _salesKitchenButton,
                      onPressed: sendKitchenLocked
                          ? null
                          : () async {
                              await _runLockedAction(
                                ref,
                                sendKitchenLockKey,
                                () async {
                                  try {
                                    final waiterName =
                                        await _loadWaiterName(
                                          ref,
                                          orderState.order!.id,
                                        ) ??
                                        ref.read(sessionProvider).userName;
                                    if (!context.mounted) return;
                                    final kitchenResult = await ref
                                        .read(currentOrderProvider.notifier)
                                        .confirmOrder(
                                          tableName: tableCode,
                                          waiterName: waiterName,
                                        );
                                    if (!context.mounted) return;
                                    // Refrescar stock — el trigger auto-86 ya
                                    // corrió en backend, queremos que el
                                    // badge del catálogo refleje las nuevas
                                    // cantidades sin esperar al próximo
                                    // loadAll.
                                    unawaited(
                                      ref
                                          .read(menuBrowserVmProvider.notifier)
                                          .refreshStock(),
                                    );
                                    // Si alguna área tuvo que escalar al
                                    // worker, mostramos snackbar amigable
                                    // amarillo en lugar del verde de éxito.
                                    if (kitchenResult != null &&
                                        kitchenResult.hadAnyEscalation) {
                                      final areas = kitchenResult.escalatedAreas
                                          .join(', ');
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          backgroundColor: const Color(
                                            0xFFF59E0B,
                                          ),
                                          duration: const Duration(seconds: 4),
                                          content: Text(
                                            'Orden enviada a cocina. Las '
                                            'impresoras de $areas no '
                                            'respondieron, el sistema lo '
                                            'está intentando de otra forma '
                                            '— las comandas saldrán en '
                                            'unos segundos.',
                                          ),
                                        ),
                                      );
                                    } else {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          backgroundColor: Color(0xFF22C55E),
                                          content: Text(
                                            'Orden enviada a cocina',
                                          ),
                                        ),
                                      );
                                    }

                                    // Auto-close para delivery externo (ya pagado)
                                    final dt = orderState.deliveryType;
                                    if (origin == OrderOrigin.delivery &&
                                        (dt == 'uber_eats' ||
                                            dt == 'pedidos_ya')) {
                                      final orderId = orderState.order?.id;
                                      if (orderId != null) {
                                        await ref
                                            .read(salesRepositoryProvider)
                                            .closeDeliveryOrder(
                                              orderId: orderId,
                                            );
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Orden cerrada automaticamente (pagada externamente)',
                                              ),
                                            ),
                                          );
                                          context.go(
                                            Uri(
                                              path: AppRoutes.salesReact,
                                              queryParameters: const {
                                                'mode': 'delivery',
                                              },
                                            ).toString(),
                                          );
                                        }
                                      }
                                    }
                                  } on NoAssignedKitchenPrinterException catch (
                                    e
                                  ) {
                                    if (!context.mounted) return;
                                    await _showMissingKitchenPrinterDialog(
                                      context,
                                      e,
                                    );
                                  } catch (e) {
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          'Error al enviar el pedido: ${e.toString()}',
                                        ),
                                        backgroundColor: Colors.red,
                                      ),
                                    );
                                  }
                                },
                              );
                            },
                      icon: Icons.soup_kitchen_outlined,
                    ),
                    const SizedBox(height: 12),
                  ], // cierra `if (kitchenEnabled)`
                  // Pagar — siempre visible cuando hay drafts, independiente
                  // de kitchen_enabled. Si el negocio no tiene cocina, los
                  // items se marcan ready en el flujo de _openPaymentModal.
                  if (selectedCheckId != null && hasChecks) ...[
                    Row(
                      children: [
                        Expanded(
                          child: _ActionButton(
                            label:
                                'Pagar esta cuenta RD\$ ${currency.format(displayTotal)}',
                            background: _salesPayButton,
                            onPressed:
                                !canCharge ||
                                    orderState.order == null ||
                                    displayTotal < 0
                                ? null
                                : () => _openPaymentModal(
                                    context,
                                    ref,
                                    orderState.order!,
                                    displayTotal,
                                    checkId: selectedCheckId,
                                    customerId:
                                        selectedCheck?.customerId ??
                                        orderState.customerId,
                                    customerName:
                                        selectedCheck?.customerName ??
                                        orderState.customerName,
                                  ),
                            icon: Icons.payments_outlined,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _ActionButton(
                            label:
                                'Pagar todo lo pendiente RD\$ ${currency.format(pendingOrderTotal)}',
                            background: _salesPayButton,
                            onPressed:
                                !canCharge ||
                                    orderState.order == null ||
                                    pendingOrderTotal < 0
                                ? null
                                : () => _openPaymentModal(
                                    context,
                                    ref,
                                    orderState.order!,
                                    pendingOrderTotal,
                                    checkId: null,
                                    customerId: orderState.customerId,
                                    customerName: orderState.customerName,
                                  ),
                            icon: Icons.point_of_sale_rounded,
                          ),
                        ),
                      ],
                    ),
                  ] else if (isRetail) ...[
                    // Retail: "Pausar venta" (hold) deja la venta actual como
                    // pestaña y abre un carrito nuevo para atender a otro
                    // cliente, junto al botón de Pagar.
                    Row(
                      children: [
                        Expanded(
                          child: _ActionButton(
                            label: 'Pausar venta',
                            background: const Color(0xFFF97316),
                            onPressed: orderState.order == null
                                ? null
                                : () => ref
                                      .read(currentOrderProvider.notifier)
                                      .newRetailCart(),
                            icon: Icons.pause_circle_outline_rounded,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _ActionButton(
                            label:
                                'Pagar RD\$ ${currency.format(displayTotal)}',
                            background: _salesPayButton,
                            onPressed:
                                !canCharge ||
                                    orderState.order == null ||
                                    displayTotal < 0
                                ? null
                                : () => _openPaymentModal(
                                    context,
                                    ref,
                                    orderState.order!,
                                    displayTotal,
                                    checkId: selectedCheckId,
                                    customerId: orderState.customerId,
                                    customerName: orderState.customerName,
                                  ),
                            icon: Icons.payments_outlined,
                          ),
                        ),
                      ],
                    ),
                  ] else
                    _ActionButton(
                      label: 'Pagar RD\$ ${currency.format(displayTotal)}',
                      background: _salesPayButton,
                      onPressed:
                          !canCharge ||
                              orderState.order == null ||
                              displayTotal < 0
                          ? null
                          : () => _openPaymentModal(
                              context,
                              ref,
                              orderState.order!,
                              displayTotal,
                              checkId: selectedCheckId,
                              customerId: orderState.customerId,
                              customerName: orderState.customerName,
                            ),
                      icon: Icons.payments_outlined,
                    ),
                ] else if (sentItems.isNotEmpty ||
                    (selectedCheckId != null && displayedItems.isNotEmpty)) ...[
                  // If items are sent, show Pre-Check, Split/Edit, Pay
                  // Also if filtered by check and has items (even if sent status is diff?)
                  Row(
                    children: [
                      Expanded(
                        child: Builder(
                          builder: (btnContext) {
                            // Printing v2 (Slice 2): la lógica del Pre-Cuenta
                            // se extrae en una closure local para poder
                            // dispararla tanto desde onPressed (tap normal,
                            // usa fijada si existe) como desde onLongPress
                            // (fuerza el picker para cambiar la fijada).
                            Future<void> runPrecheck({
                              required bool forcePicker,
                            }) async {
                              await _runLockedAction(
                                ref,
                                precheckLockKey,
                                () async {
                                  if (orderState.order == null) return;
                                  // FRESH: recargar la orden del server antes
                                  // de imprimir, para no sacar una precuenta
                                  // con ítems stale (Realtime pudo perder
                                  // eventos / otra caja agregó ítems). No-op
                                  // offline o en orden local.
                                  await ref
                                      .read(currentOrderProvider.notifier)
                                      .reloadOrderNow();
                                  if (!context.mounted) return;
                                  final freshState =
                                      ref.read(currentOrderProvider);
                                  final freshOrder = freshState.order;
                                  if (freshOrder == null) return;
                                  // Recomputamos items/totales desde el estado
                                  // recién recargado (mismo filtro que la vista
                                  // del carrito).
                                  final freshOpen = freshState.items
                                      .where(_isOpenItem)
                                      .toList();
                                  final freshItems = selectedCheckId != null
                                      ? freshOpen
                                            .where(
                                              (i) =>
                                                  i.checkId == selectedCheckId,
                                            )
                                            .toList()
                                      : freshOpen.where((i) {
                                          return !freshState.checks.any(
                                            (c) =>
                                                c.id == i.checkId && c.isClosed,
                                          );
                                        }).toList();
                                  final freshSummary = summarizeOrderPricing(
                                    freshOrder,
                                    freshItems,
                                    forcedOrigin: freshState.origin,
                                  );
                                  final businessProfile =
                                      await _loadBusinessReceiptProfile(ref);
                                  final waiterName =
                                      await _loadWaiterName(
                                        ref,
                                        freshOrder.id,
                                      ) ??
                                      ref.read(sessionProvider).userName;
                                  if (!context.mounted) return;
                                  final preCheckData = {
                                    'restaurantName': businessProfile.name,
                                    'businessName':
                                        businessProfile.businessName,
                                    'legalName': businessProfile.legalName,
                                    'rnc': businessProfile.rnc,
                                    'phone': businessProfile.phone,
                                    'address': businessProfile.address,
                                    'tableName':
                                        '$tableCode ${selectedCheckId != null ? "(Cuentas Separadas)" : ""}',
                                    'waiterName': waiterName,
                                    'customerName': freshState.customerName,
                                    'items': freshItems
                                        .map(
                                          (i) => {
                                            'quantity': i.quantity,
                                            'name': i.productName,
                                            'price': itemDisplayTotal(
                                              freshOrder,
                                              i,
                                            ),
                                          },
                                        )
                                        .toList(),
                                    'subtotal': freshSummary.subtotal,
                                    'tax':
                                        freshSummary.tax +
                                        freshSummary.serviceFee,
                                    'total': freshSummary.total,
                                  };

                                  try {
                                    await _runPrecheckWithDestinationPicker(
                                      context,
                                      ref,
                                      preCheckData: preCheckData,
                                      orderObj: freshOrder,
                                      orderItems: freshItems,
                                      forcePicker: forcePicker,
                                    );
                                  } catch (e) {
                                    if (context.mounted) {
                                      // Precuenta: no bloquea otra
                                      // operacion, fire-and-forget.
                                      unawaited(
                                        _showReimpresionDialog(
                                          context: context,
                                          ref: ref,
                                          type: 'precheck',
                                          data: preCheckData,
                                          orderObj: freshOrder,
                                          orderItems: freshItems,
                                          tableName:
                                              preCheckData['tableName']
                                                  as String?,
                                          waiterName:
                                              preCheckData['waiterName']
                                                  as String?,
                                          errorMsg: e.toString(),
                                        ),
                                      );
                                    }
                                  }
                                },
                              );
                            }

                            return _SecondaryActionButton(
                              label: 'Pre-Cuenta',
                              icon: Icons.receipt_long_outlined,
                              onPressed: precheckLocked
                                  ? null
                                  : () => runPrecheck(forcePicker: false),
                              // Long press → fuerza el picker para cambiar
                              // la impresora fijada (UX de Slice 2).
                              onLongPress: precheckLocked
                                  ? null
                                  : () => runPrecheck(forcePicker: true),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _SecondaryActionButton(
                          label: hasChecks ? 'Editar cuentas' : 'Dividir',
                          onPressed: () => _openSplitBillModal(
                            context,
                            ref,
                            orderState.order!,
                          ),
                          icon: hasChecks
                              ? Icons.edit_note
                              : Icons.call_split_rounded,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (selectedCheckId != null && hasChecks) ...[
                    Row(
                      children: [
                        Expanded(
                          child: _ActionButton(
                            label:
                                'Pagar esta cuenta RD\$ ${currency.format(displayTotal)}',
                            background: _salesPayButton,
                            onPressed:
                                !canCharge ||
                                    orderState.order == null ||
                                    displayTotal < 0
                                ? null
                                : () => _openPaymentModal(
                                    context,
                                    ref,
                                    orderState.order!,
                                    displayTotal,
                                    checkId: selectedCheckId,
                                    customerId:
                                        selectedCheck?.customerId ??
                                        orderState.customerId,
                                    customerName:
                                        selectedCheck?.customerName ??
                                        orderState.customerName,
                                  ),
                            icon: Icons.payments_rounded,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _ActionButton(
                            label:
                                'Pagar todo lo pendiente RD\$ ${currency.format(pendingOrderTotal)}',
                            background: _salesPayButton,
                            onPressed:
                                !canCharge ||
                                    orderState.order == null ||
                                    pendingOrderTotal < 0
                                ? null
                                : () => _openPaymentModal(
                                    context,
                                    ref,
                                    orderState.order!,
                                    pendingOrderTotal,
                                    checkId: null,
                                    customerId: orderState.customerId,
                                    customerName: orderState.customerName,
                                  ),
                            icon: Icons.point_of_sale_rounded,
                          ),
                        ),
                      ],
                    ),
                  ] else
                    _ActionButton(
                      label: 'Pagar RD\$ ${currency.format(displayTotal)}',
                      background: _salesPayButton,
                      onPressed:
                          !canCharge ||
                              orderState.order == null ||
                              displayTotal < 0
                          ? null
                          : () => _openPaymentModal(
                              context,
                              ref,
                              orderState.order!,
                              displayTotal,
                              checkId: selectedCheckId,
                              customerId: orderState.customerId,
                              customerName: orderState.customerName,
                            ),
                      icon: Icons.payments_rounded,
                    ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Printing v2 — Slice B: imprime la pre-cuenta en TODAS las impresoras
  /// precheck-capable del business simultáneamente. Las llamadas se
  /// disparan en paralelo (Future.wait) para no acumular latencia. Si
  /// alguna falla, las demás siguen — un error individual no aborta el lote.
  Future<void> _printPrecheckOnAll(
    BuildContext context,
    WidgetRef ref, {
    required Map<String, dynamic> preCheckData,
    required Order orderObj,
    required List<OrderItem> orderItems,
    String? tableName,
    String? waiterName,
    required List<PrintDestination> destinations,
  }) async {
    final printerDestinations = destinations
        .where(
          (d) => d.kind == PrintDestinationKind.printer && d.printer != null,
        )
        .toList(growable: false);
    if (printerDestinations.isEmpty) return;

    // Mostrar feedback inmediato al usuario.
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(
            'Imprimiendo en ${printerDestinations.length} impresoras...',
          ),
        ),
      );
    }

    final futures = printerDestinations.map((d) async {
      try {
        await _handlePrintFlow(
          context,
          ref,
          'precheck',
          preCheckData,
          orderObj: orderObj,
          orderItems: orderItems,
          tableName: tableName,
          waiterName: waiterName,
          showSnackBar: false,
          forcedPrinter: d.printer,
        );
        return null;
      } catch (e) {
        return '${d.displayName}: $e';
      }
    });

    final errors = (await Future.wait(
      futures,
    )).whereType<String>().toList(growable: false);

    if (context.mounted && errors.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFFEF4444),
          duration: const Duration(seconds: 4),
          content: Text('Algunas copias fallaron:\n${errors.join('\n')}'),
        ),
      );
    }
  }

  /// Pre-Cuenta v2: si hay >1 destino configurado, decide entre:
  ///   - Imprimir directo en la impresora "fijada" para este device
  ///     (saltando el picker — UX rápida para alto volumen).
  ///   - Mostrar el bottom sheet si no hay fijada, o si [forcePicker]=true
  ///     (long press en el botón Pre-Cuenta).
  ///
  /// Al elegir una impresora en el picker, queda automáticamente fijada
  /// para próximas veces.
  Future<void> _runPrecheckWithDestinationPicker(
    BuildContext context,
    WidgetRef ref, {
    required Map<String, dynamic> preCheckData,
    required Order orderObj,
    required List<OrderItem> orderItems,
    bool forcePicker = false,
  }) async {
    final session = ref.read(sessionProvider);
    final businessId = session.activeBusinessId;
    if (businessId == null || businessId.isEmpty) {
      throw Exception('Negocio no resuelto.');
    }

    final tableName = preCheckData['tableName'] as String?;
    final waiterName = preCheckData['waiterName'] as String?;

    // 1. Resolver destinos disponibles. Failure aquí cae al legacy.
    List<PrintDestination> destinations = const [];
    try {
      final resolver = ref.read(printDestinationResolverProvider);
      destinations = await resolver.resolveForPrecheck(businessId: businessId);
    } catch (_) {
      // Si el resolver explota (RLS, red, etc.), seguimos con el flujo legacy.
    }

    // Solo mostrar selector si hay >1 destino impresora (screen-only siempre
    // se agrega). Contamos impresoras únicas.
    final printerDestinations = destinations
        .where((d) => d.kind == PrintDestinationKind.printer)
        .toList(growable: false);

    PrintDestination? chosen;
    if (printerDestinations.length > 1) {
      // ── Slice B: si el business activó multi-copia, fan-out a TODAS
      //    paralelo (sin picker, sin fijada).
      try {
        final modes = await ref
            .read(posSettingsRepositoryProvider)
            .getPrintMultiCopyModes(businessId);
        if (modes.precheck && !forcePicker) {
          await _printPrecheckOnAll(
            context,
            ref,
            preCheckData: preCheckData,
            orderObj: orderObj,
            orderItems: orderItems,
            tableName: tableName,
            waiterName: waiterName,
            destinations: printerDestinations,
          );
          return;
        }
      } catch (_) {
        // Si el setting no se puede leer, seguimos con el flujo normal.
      }

      final deviceId = await DeviceIdentity.getOrCreateId(businessId);
      final pinnedKey = await PrechecPrinterPreference.read(deviceId);

      // ── Atajo: si hay una impresora "fijada" para este device y todavía
      // existe entre los destinos disponibles, imprime directo. UX rápida
      // para cajeros que siempre usan la misma impresora.
      // ── Excepción: forcePicker=true (long press) ignora la fijada y
      // muestra el picker para permitir cambiar la fijación.
      if (!forcePicker && pinnedKey != null) {
        final pinned = destinations.firstWhere(
          (d) =>
              d.persistKey == pinnedKey &&
              d.kind == PrintDestinationKind.printer,
          orElse: () => PrintDestination.screenOnly(),
        );
        if (pinned.kind == PrintDestinationKind.printer) {
          chosen = pinned;
        }
      }

      // Si no hubo atajo (no había fijada, ya no existe, o forcePicker)
      // → mostrar el selector.
      if (chosen == null) {
        if (!context.mounted) return;
        chosen = await showPrintDestinationPicker(
          context,
          destinations: destinations,
          recentlyUsedKey: pinnedKey,
        );
        if (chosen == null) return; // usuario canceló

        // Auto-fijar la elección — primer tap = fija. Si el usuario quiere
        // cambiarla después, long press en Pre-Cuenta.
        unawaited(PrechecPrinterPreference.save(deviceId, chosen.persistKey));
      }
    } else if (printerDestinations.length == 1) {
      // Una sola impresora → comportamiento actual (sin picker), usa esa.
      chosen = printerDestinations.first;
    }

    // 2. Procesar la elección.
    if (chosen != null && chosen.kind == PrintDestinationKind.screenOnly) {
      // Solo pantalla: mostrar el dialog en vez de imprimir.
      final mode = await ref
          .read(posSettingsRepositoryProvider)
          .getReceiptItemDisplayMode(businessId);
      if (!context.mounted) return;
      // ignore: use_build_context_synchronously
      unawaited(
        showDialog<void>(
          context: context,
          builder: (dialogCtx) => PreCheckDialog(
            data: preCheckData,
            receiptItemDisplayMode: mode,
            onCancel: () => Navigator.of(dialogCtx).pop(),
            onPrint: () => Navigator.of(dialogCtx).pop(),
          ),
        ),
      );
      return;
    }

    // 3. Imprimir con la impresora forzada (o auto-resolución si chosen==null,
    //    caso "0 destinos resueltos" — _handlePrintFlow lanzará error claro).
    if (!context.mounted) return;
    await _handlePrintFlow(
      context,
      ref,
      'precheck',
      preCheckData,
      orderObj: orderObj,
      orderItems: orderItems,
      tableName: tableName,
      waiterName: waiterName,
      forcedPrinter: chosen?.printer,
    );
  }

  /// Printing v2 (Slice 3 + B): resuelve la impresora para el recibo
  /// final cuando la caja no tiene una `cash_register.receipt_printer_id`
  /// asignada (el paso 1 del fallback no resolvió).
  ///
  /// Lógica:
  ///   - 0 destinos receipt-capable: retorna null → cae al fallback legacy
  ///     (area-based) que ya estaba antes.
  ///   - 1 destino: lo usa directo, sin picker.
  ///   - 2+ destinos + business.print_receipt_multi_copy=true (Slice B):
  ///     - Asigna `extraReceiptPrintersToFanOut` con las demás impresoras
  ///       para que `_handlePrintFlow` haga fan-out paralelo, y retorna
  ///       la primera como "principal" del flujo legacy.
  ///   - 2+ destinos sin multi-copia:
  ///     - Si hay impresora "fijada" para receipts en este device → usa.
  ///     - Sino → muestra picker rápido. Al elegir, queda fijada.
  Future<({PrinterConfig? primary, List<PrinterConfig> extras})>
  _resolveReceiptDestination(
    BuildContext context,
    WidgetRef ref, {
    required String businessId,
  }) async {
    List<PrintDestination> destinations = const [];
    try {
      final resolver = ref.read(printDestinationResolverProvider);
      destinations = await resolver.resolveForReceipt(businessId: businessId);
    } catch (_) {
      // Resolver falló (RLS, red); que el fallback legacy se encargue.
      return (primary: null, extras: const <PrinterConfig>[]);
    }

    final printerDestinations = destinations
        .where(
          (d) => d.kind == PrintDestinationKind.printer && d.printer != null,
        )
        .toList(growable: false);

    if (printerDestinations.isEmpty) {
      return (primary: null, extras: const <PrinterConfig>[]);
    }
    if (printerDestinations.length == 1) {
      return (
        primary: printerDestinations.first.printer,
        extras: const <PrinterConfig>[],
      );
    }

    // Slice B: si el business activó multi-copia para recibo, fan-out
    // paralelo a TODAS las impresoras receipt-capable.
    try {
      final modes = await ref
          .read(posSettingsRepositoryProvider)
          .getPrintMultiCopyModes(businessId);
      if (modes.receipt) {
        return (
          primary: printerDestinations.first.printer,
          extras: printerDestinations
              .skip(1)
              .map((d) => d.printer!)
              .toList(growable: false),
        );
      }
    } catch (_) {
      // Si falla, seguir con el flujo normal (picker o fijada).
    }

    // >1 destinos receipt-capable sin multi-copia: usar fijada o pedir.
    final deviceId = await DeviceIdentity.getOrCreateId(businessId);
    final pinnedKey = await ReceiptPrinterPreference.read(deviceId);

    if (pinnedKey != null) {
      final pinned = destinations.firstWhere(
        (d) =>
            d.persistKey == pinnedKey && d.kind == PrintDestinationKind.printer,
        orElse: () => PrintDestination.screenOnly(),
      );
      if (pinned.kind == PrintDestinationKind.printer) {
        return (primary: pinned.printer, extras: const <PrinterConfig>[]);
      }
    }

    if (!context.mounted) {
      return (primary: null, extras: const <PrinterConfig>[]);
    }
    final chosen = await showPrintDestinationPicker(
      context,
      destinations: printerDestinations, // sin screen-only para receipt
      title: '¿Dónde imprimir el recibo?',
      recentlyUsedKey: pinnedKey,
    );
    if (chosen == null) {
      return (primary: null, extras: const <PrinterConfig>[]);
    }

    // Auto-fijar la elección para próximas facturas.
    unawaited(ReceiptPrinterPreference.save(deviceId, chosen.persistKey));
    return (primary: chosen.printer, extras: const <PrinterConfig>[]);
  }

  Future<void> _handlePrintFlow(
    BuildContext context,
    WidgetRef ref,
    String type,
    Map<String, dynamic> data, {
    Order? orderObj,
    List<OrderItem>? orderItems,
    List<Payment>? payments,
    String? tableName,
    String? waiterName,
    bool showSnackBar = true,
    PrinterConfig? forcedPrinter,
  }) async {
    try {
      final printRepo = ref.read(printingPrintersRepositoryProvider);
      final session = ref.read(sessionProvider);
      final businessId = session.activeBusinessId;
      if (businessId == null || businessId.isEmpty) {
        throw Exception('Negocio no resuelto.');
      }
      // Capturamos repos que necesitamos despues del await — si el cajero
      // navega fuera durante la impresion (~2-15s), el widget se dispone
      // y `ref.read` lanza StateError. Esto pasa con la marca de
      // precuenta-impresa que ocurre tras outcome exitoso.
      final zonesRepo = ref.read(zonesRepoProvider);

      // Si el usuario ya eligió impresora en el selector v2 (Printing v2),
      // usar esa y saltar la auto-resolución legacy.
      PrinterConfig? assignedPrinter = forcedPrinter;
      // Slice B: extras para fan-out de recibo (multi-copia). Solo se
      // popula si el business activó print_receipt_multi_copy y hay >1
      // impresora receipt-capable. Se imprime al final, después del primary.
      List<PrinterConfig> extraReceiptPrinters = const [];

      if (assignedPrinter == null) {
        // 1. Try register-specific printer first (each cash register can have its own)
        final registerId = ref.read(cashierViewModelProvider).currentRegisterId;
        if (registerId != null) {
          try {
            final regPrinterId = await ref
                .read(cashierRepositoryProvider)
                .getRegisterPrinterId(registerId);
            if (regPrinterId != null) {
              assignedPrinter = await printRepo.getPrinter(regPrinterId);
            }
          } catch (_) {}
        }

        // 2. Printing v2 (Slice 3 + B): selector de receipt al primer
        //    cobro o fan-out multi-copia si está activado.
        if (assignedPrinter == null && type == 'invoice' && context.mounted) {
          final resolved = await _resolveReceiptDestination(
            context,
            ref,
            businessId: businessId,
          );
          assignedPrinter = resolved.primary;
          extraReceiptPrinters = resolved.extras;
        }

        // 3. Fallback to global area-based printer (legacy auto-resolve)
        assignedPrinter ??= await printRepo.getAssignedPrinterForType(
          businessId: businessId,
          preferredAreaCodes: type == 'invoice'
              ? const ['fiscal', 'cashier']
              : const ['cashier', 'fiscal'],
          printsPrebills: type == 'precheck',
          printsReceipts: type == 'invoice',
        );
      }

      final receiptItemDisplayModeFuture = ref
          .read(posSettingsRepositoryProvider)
          .getReceiptItemDisplayMode(businessId);
      final discountDisplayModeFuture = ref
          .read(posSettingsRepositoryProvider)
          .getDiscountDisplayMode(businessId);
      final openDrawerOnCashFuture = ref
          .read(posSettingsRepositoryProvider)
          .getOpenDrawerOnCash(businessId);

      if (assignedPrinter == null) {
        throw Exception('Impresora no configurada para esta caja.');
      }
      final printer = assignedPrinter;

      final receiptItemDisplayMode = await receiptItemDisplayModeFuture;
      final discountDisplayMode = await discountDisplayModeFuture;
      final openDrawerOnCashEnabled = await openDrawerOnCashFuture;

      // Detectar si el pago incluyó efectivo. La gaveta se abre solo si:
      //   - el setting del business está ON,
      //   - es una factura (no precheck — precuentas no son cobro),
      //   - al menos un payment fue por método 'cash' (codes contienen
      //     "cash" o "efectivo").
      bool isCashPayment(Payment p) {
        final code =
            p.paymentMethodCode?.toLowerCase().trim() ??
            p.paymentMethodId.toLowerCase().trim();
        final name = p.paymentMethodName?.toLowerCase().trim() ?? '';
        return code.contains('cash') ||
            code.contains('efectivo') ||
            name.contains('efectivo');
      }

      final shouldOpenDrawer =
          openDrawerOnCashEnabled &&
          type == 'invoice' &&
          (payments?.any(isCashPayment) ?? false);

      // Preparación de datos (fuera del timeout para no penalizar generación)
      dynamic ticket;
      if ((type == 'precheck' || type == 'invoice') &&
          orderObj != null &&
          orderItems != null) {
        final title =
            data['title'] as String? ??
            (type == 'invoice' ? 'FACTURA' : 'PRECUENTA');

        // Compute per-tax breakdown for the printed receipt.
        // Usamos buildOrderTaxBreakdown (mismo camino que el cashier UI) para que
        // la absorcion del centavo quede identica: ITBIS/Propina vienen del
        // summary ya absorbido en vez de recalcular `subtotal * rate` redondeado
        // (que produce drift de 0.01 contra lo que ve el usuario en pantalla).
        final configuredBreakdown = ref
            .read(currentOrderProvider.notifier)
            .getTaxBreakdown(
              summarizeOrderPricing(orderObj, orderItems).subtotal,
            );
        final printTaxBreakdown = buildOrderTaxBreakdown(
          orderObj,
          orderItems,
          forcedOrigin: orderObj.origin,
          configuredBreakdown: configuredBreakdown,
        );

        // e-CF: pre-fetch del fiscal_document para resolver QR/estado.
        // Solo aplica al tipo 'invoice' (precheck no lleva NCF). El
        // fiscalDoc se resuelve por order_id; el trigger SQL lo crea
        // automáticamente al cobrar. Si la consulta o el render del QR
        // fallan, dejamos qrBytes/ecfStatusMessage en null y el ticket
        // sale igual que antes (sin QR) — fail-soft, no rompe el cobro.
        List<int>? ecfQrBytes;
        String? ecfStatusMsg;
        bool isElectronicCf = false;
        String? ecfSecurityCode;
        DateTime? ecfSignedAt;
        if (type == 'invoice') {
          try {
            // Cargar el fd del payment más reciente si está disponible
            // (split bill / multi-method tiene N fds por orden y
            // getOrderFiscalDocument no puede elegir el correcto solo
            // por order_id). Fallback al de la orden si no hay payments.
            final fdIdFromPayments = (payments != null && payments.isNotEmpty)
                ? payments.last.fiscalDocumentId
                : null;
            final fiscalDoc = fdIdFromPayments != null
                ? await ref
                      .read(salesRepositoryProvider)
                      .getFiscalDocumentById(fdIdFromPayments)
                : await ref
                      .read(salesRepositoryProvider)
                      .getOrderFiscalDocument(orderObj.id);
            if (fiscalDoc != null && fiscalDoc.isElectronic) {
              isElectronicCf = true;
              ecfSecurityCode = fiscalDoc.ecfSecurityCode;
              ecfSignedAt = fiscalDoc.ecfSignedAt;
              if (fiscalDoc.hasQrData) {
                // Preferimos publicUrl si Alanube ya nos lo dio (post-webhook
                // DGII). En estado `sent` típicamente publicUrl aún es null,
                // así que construimos la URL DGII localmente con los campos
                // del documento (security_code + RNC + NCF + fecha + total).
                // El QR sigue siendo válido — DGII permite consultas para
                // docs en proceso.
                //
                // RNC del emisor: source of truth es fiscal_settings.rnc.
                // businesses puede tener tax_id en lugar de rnc, o estar
                // vacio en setups legacy. Cascade: data.rnc → data.tax_id →
                // fiscal_settings.rnc del business activo.
                String emitterRnc = (data['rnc'] as String?)?.trim() ?? '';
                if (emitterRnc.isEmpty) {
                  emitterRnc = (data['tax_id'] as String?)?.trim() ?? '';
                }
                if (emitterRnc.isEmpty) {
                  try {
                    final fs = await Supabase.instance.client
                        .from('fiscal_settings')
                        .select('rnc')
                        .eq('business_id', businessId)
                        .maybeSingle();
                    emitterRnc = ((fs?['rnc'] as String?)?.trim()) ?? '';
                  } catch (_) {}
                }

                final qrUrl = fiscalDoc.publicUrl?.isNotEmpty == true
                    ? fiscalDoc.publicUrl!
                    : (fiscalDoc.buildDgiiVerifyUrl(
                            emitterRnc: emitterRnc,
                            sandbox: true,
                          ) ??
                          '');
                if (qrUrl.isNotEmpty) {
                  ecfQrBytes = await QrEscPosBuilder.build(data: qrUrl);
                } else {
                  ecfStatusMsg = fiscalDoc.ecfStatusMessage;
                }
              } else {
                ecfStatusMsg = fiscalDoc.ecfStatusMessage;
              }
            }
          } catch (_) {
            // No tumbar el cobro por un fallo de QR/estado e-CF.
          }
        }

        // BusinessProfile + logo pre-rasterizado para el header.
        // Si printLogoOnInvoice=false o no hay logo, logoEscPosBytes=null
        // y el ticket sale sin logo (preserva el behavior anterior).
        final businessProfileRepo = BusinessProfileRepository(
          Supabase.instance.client,
        );
        final profileForPrint = await businessProfileRepo
            .prepareForInvoicePrinting(businessId);

        // PRD 6: cargar settings de USD para el bloque "≈ US$X" debajo
        // del TOTAL. Si toggle off / tasa null, el helper salta sin
        // imprimir nada. Wrapping en try/catch + timeout para que un
        // fallo cargando las settings NUNCA bloquee la impresión —
        // el ticket en el peor caso sale sin el bloque USD.
        UsdDisplaySettings? usdSettings;
        try {
          usdSettings = await ref
              .read(posSettingsRepositoryProvider)
              .getUsdDisplaySettings(businessId)
              .timeout(const Duration(seconds: 2));
        } catch (e) {
          debugPrint('PRD 6: no se cargaron settings USD para print: $e');
          usdSettings = null;
        }

        // Modelo de factura (estándar vs compacto) elegido en ajustes.
        String invoiceTpl = PosSettingsRepository.invoiceTemplateStandard;
        try {
          invoiceTpl = await ref
              .read(posSettingsRepositoryProvider)
              .getInvoiceTemplate(businessId);
        } catch (_) {}

        // PRD F2: si algún payment fue por transferencia con cuenta
        // bancaria asignada, cargar el mapa para que el ticket muestre
        // banco/titular debajo de la línea de pago. Si no hay
        // transferencias, el helper devuelve mapa vacío sin pegar la red.
        final bankAccountsRepo = BankAccountsRepository();
        final bankAccountsByPaymentId = await bankAccountsRepo
            .fetchByPaymentIds(payments ?? const []);

        ticket = type == 'invoice'
            ? PrintTicketService.generateInvoice(
                order: orderObj,
                items: orderItems,
                payments: payments ?? [],
                tableName: tableName ?? 'Mesa',
                waiterName: waiterName,
                businessName: data['restaurantName'] as String?,
                legalName: data['legalName'] as String?,
                businessAddress: data['address'] as String?,
                businessPhone: data['phone'] as String?,
                businessRnc: data['rnc'] as String?,
                fiscalNcf: data['ncf'] as String?,
                fiscalType: data['fiscalType'] as String?,
                customerName: data['customerName'] as String?,
                customerLegalName: data['customerLegalName'] as String?,
                customerTaxId: data['customerTaxId'] as String?,
                deliveryAddress: data['deliveryAddress'] as String?,
                issuedAt: data['issuedAt'] == null
                    ? null
                    : DateTime.tryParse(data['issuedAt'].toString()),
                usdSettings: usdSettings, // PRD 6
                title: title,
                receiptItemDisplayMode: receiptItemDisplayMode,
                taxBreakdown: printTaxBreakdown,
                qrBytes: ecfQrBytes,
                ecfStatusMessage: ecfStatusMsg,
                isElectronicCf: isElectronicCf,
                ecfSecurityCode: ecfSecurityCode,
                ecfSignedAt: ecfSignedAt,
                // Branding desde BusinessProfile.
                logoBytes: profileForPrint.logoEscPosBytes,
                slogan: profileForPrint.profile?.slogan,
                branchName: profileForPrint.profile?.branchName,
                businessEmail: profileForPrint.profile?.email,
                footerMessage: profileForPrint.profile?.ticketFooterMessage,
                headerBlocks: profileForPrint.profile?.effectiveHeaderBlocks,
                footerBlocks: profileForPrint.profile?.effectiveFooterBlocks,
                bankAccountsByPaymentId: bankAccountsByPaymentId,
                discountDisplayMode: discountDisplayMode,
                template: invoiceTpl,
                openCashDrawer: shouldOpenDrawer,
              )
            : PrintTicketService.generatePrecheck(
                order: orderObj,
                items: orderItems,
                tableName: tableName ?? 'Mesa',
                waiterName: waiterName,
                customerName: data['customerName'] as String?,
                businessName:
                    (data['businessName'] as String?) ??
                    (data['restaurantName'] as String?),
                legalName: data['legalName'] as String?,
                businessAddress: data['address'] as String?,
                businessPhone: data['phone'] as String?,
                businessRnc: data['rnc'] as String?,
                usdSettings: usdSettings, // PRD 6
                title: title,
                receiptItemDisplayMode: receiptItemDisplayMode,
                taxBreakdown: printTaxBreakdown,
                discountDisplayMode: discountDisplayMode,
                template: invoiceTpl,
              );
      }

      // USB tipicamente confirma en <2s, pero algunos drivers (Star /
      // Bixolon viejas via USB-serial) tardan mas — damos 15s. Network
      // pasa por TCP directo en LAN: 2s alcanza para un ACK local. Si
      // no responde en 2s casi seguro está caída — printEscPos escala
      // al worker en background y le devolvemos el control rápido al
      // cajero.
      final isUsbPrinter = printer.printerType == PrinterType.usb;
      final tcpTimeout = isUsbPrinter
          ? const Duration(seconds: 15)
          : const Duration(seconds: 2);
      // Outer guard generoso: cubre directo + agent local + escalada a
      // cloud queue. ~5s alcanza para que printEscPos resuelva en todos
      // los escenarios sanos (no quiero que el outer mate la escalada
      // como pasaba con el 3s anterior).
      final outerTimeout = isUsbPrinter
          ? const Duration(seconds: 18)
          : const Duration(seconds: 5);

      // Sprint 1.3.b: armar idempotencyKey para que `printEscPos` pueda
      // escalar al cloud queue si todos los intentos directos fallan.
      // Sin esto, el comportamiento es legacy (error inmediato al
      // cajero). Con esto, el agent retoma el job en background.
      final orderIdForKey = orderObj?.id;
      final idempotencyKey = orderIdForKey != null && orderIdForKey.isNotEmpty
          ? 'print-$type-$orderIdForKey-${printer.id}'
          : null;

      // UX: snackbar INSTANTÁNEO al click, antes del await. El cajero
      // ve "Imprimiendo..." con spinner — sensación de respuesta
      // inmediata. Después actualizamos según el outcome real.
      if (showSnackBar && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 2),
            content: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(Colors.white),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text('Imprimiendo en ${printer.name}...')),
              ],
            ),
            backgroundColor: const Color(0xFF22C55E),
          ),
        );
      }

      final printFuture = Future<PrintOutcome>(() async {
        if (ticket != null) {
          return await printRepo.printEscPos(
            printer: printer,
            data: ticket.escPosCommands,
            timeout: tcpTimeout,
            idempotencyKey: idempotencyKey,
            kind: type,
            areaCode: 'cashier',
          );
        } else {
          if (!printer.isNetwork) {
            throw Exception(
              'La impresión ${printer.type} requiere generar el ticket ESC/POS antes de enviarlo.',
            );
          }
          final ip = printer.ipAddress?.trim();
          if (ip == null || ip.isEmpty) {
            throw Exception('La impresora de red no tiene IP configurada.');
          }
          await printRepo.printJobViaAgent({
            'id':
                '${type.toUpperCase()}-${DateTime.now().millisecondsSinceEpoch}',
            'printer': {
              'type': 'network',
              'ip': ip,
              'port': printer.port ?? 9100,
            },
            'content': {'type': type, 'data': data},
          });
          return PrintOutcome.directSuccess;
        }
      });

      // Tiramos timeout SIEMPRE — antes USB se "tragaba" el timeout y
      // el flujo continuaba como si hubiera impreso, mostrando el
      // dialog de exito sin que saliera el ticket. Resultado: el
      // cajero cerraba la mesa sin imprimir. Ahora si vence, el caller
      // muestra el dialog de "Reintentar / Continuar sin imprimir".
      final outcome = await printFuture.timeout(
        outerTimeout,
        onTimeout: () => throw TimeoutException(
          isUsbPrinter
              ? 'La impresora USB no respondio en ${outerTimeout.inSeconds}s'
              : 'La impresora de red no respondio en ${outerTimeout.inSeconds}s',
        ),
      );

      // Follow-up amigable si tuvo que escalar al worker. El cajero ya
      // vio "Imprimiendo..."; ahora le explicamos sin alarmas que la
      // impresora directa no respondió pero el sistema se encarga.
      if (outcome == PrintOutcome.escalatedToCloud &&
          showSnackBar &&
          context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 4),
            content: Text(
              'La impresora "${printer.name}" no respondió. El sistema '
              'lo está intentando de otra forma — el ticket saldrá en '
              'unos segundos.',
            ),
            backgroundColor: const Color(0xFFF59E0B),
          ),
        );
      }

      // Marca la mesa como "precuenta impresa" → la vista de zonas la
      // pinta azul (TableStatus.pagando). Fire-and-forget: no rompe el
      // flujo si la DB no responde. Cubre tanto directSuccess como
      // escalatedToCloud — en ambos casos el cajero ya pidió la cuenta.
      // Realtime sobre table_sessions repinta sin invalidaciones extra.
      // Usamos `zonesRepo` capturado al inicio para evitar StateError
      // si el widget se disposo durante la impresion.
      if (type == 'precheck') {
        final sessionId = orderObj?.sessionId ?? '';
        if (sessionId.isNotEmpty) {
          unawaited(zonesRepo.markPrecheckPrinted(sessionId));
        }
      }

      // Slice B — fan-out de multi-copia para recibo (paralelo). Solo
      // se popula cuando type='invoice' y el business activó la setting.
      // Errores individuales no abortan: el primario ya salió OK.
      if (extraReceiptPrinters.isNotEmpty) {
        unawaited(
          _fanOutExtraReceiptPrinters(
            context,
            ref,
            type: type,
            data: data,
            orderObj: orderObj,
            orderItems: orderItems,
            payments: payments,
            tableName: tableName,
            waiterName: waiterName,
            extras: extraReceiptPrinters,
          ),
        );
      }
    } catch (e) {
      rethrow;
    }
  }

  /// Slice B helper: dispara prints paralelos a las impresoras `extras`
  /// (siempre desde `_handlePrintFlow` con `forcedPrinter` para evitar
  /// re-auto-resolución). Fire-and-forget: el primario ya tuvo éxito,
  /// las copias son best-effort.
  Future<void> _fanOutExtraReceiptPrinters(
    BuildContext context,
    WidgetRef ref, {
    required String type,
    required Map<String, dynamic> data,
    Order? orderObj,
    List<OrderItem>? orderItems,
    List<Payment>? payments,
    String? tableName,
    String? waiterName,
    required List<PrinterConfig> extras,
  }) async {
    final futures = extras.map((p) async {
      try {
        await _handlePrintFlow(
          context,
          ref,
          type,
          data,
          orderObj: orderObj,
          orderItems: orderItems,
          payments: payments,
          tableName: tableName,
          waiterName: waiterName,
          showSnackBar: false,
          forcedPrinter: p,
        );
        return null;
      } catch (e) {
        return '${p.name}: $e';
      }
    });
    final errors = (await Future.wait(
      futures,
    )).whereType<String>().toList(growable: false);
    if (errors.isNotEmpty && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 4),
          backgroundColor: const Color(0xFFF59E0B),
          content: Text('Algunas copias no salieron:\n${errors.join('\n')}'),
        ),
      );
    }
  }

  String _getNcfLabel(String tipo) {
    switch (tipo) {
      case 'B01':
      case '01':
        return 'Crédito Fiscal';
      case 'B02':
      case '02':
        return 'Consumo';
      case 'B14':
      case '14':
        return 'Reg. Espec.';
      case 'B15':
      case '15':
        return 'Gubernamental';
      case 'E31':
      case '31':
        return 'Elect. Crédito Fiscal';
      case 'E32':
      case '32':
        return 'Elect. Consumidor';
      default:
        return tipo;
    }
  }

  String _normalizeFiscalType(String? raw) {
    final value = raw?.trim().toUpperCase() ?? '';
    if (value.isEmpty) return '';
    if (value.length >= 3 && (value.startsWith('B') || value.startsWith('E'))) {
      return value.substring(1);
    }
    return value;
  }

  bool _matchesFiscalSequenceType(FiscalNcfSequence sequence, String type) {
    final normalized = _normalizeFiscalType(type);
    if (normalized.isEmpty) return false;
    return sequence.activo &&
        (sequence.tipo.toUpperCase() == normalized ||
            sequence.ncfType.toUpperCase() == type.trim().toUpperCase());
  }

  String? _buildFiscalConfigError(CurrentOrderState orderState) {
    final activeSequences = orderState.fiscalSequences
        .where((sequence) => sequence.activo)
        .toList(growable: false);

    if (activeSequences.isEmpty) {
      final loadError = orderState.fiscalSequencesLoadError;
      if (loadError != null && loadError.isNotEmpty) {
        return 'No se pudieron cargar las secuencias fiscales: $loadError. Reintenta o revisa la conexión y permisos.';
      }
      return 'Este negocio no tiene secuencias fiscales activas configuradas. Revisa Ajustes > Fiscal antes de cobrar.';
    }

    final configuredType = _normalizeFiscalType(orderState.fiscalDefaultType);
    if (configuredType.isNotEmpty &&
        !activeSequences.any(
          (sequence) => _matchesFiscalSequenceType(sequence, configuredType),
        )) {
      return 'Este negocio esta configurado para ${_getNcfLabel(configuredType)} ($configuredType), pero no tiene una secuencia activa para ese tipo.';
    }

    final selectedType = _normalizeFiscalType(orderState.fiscalType);
    if (selectedType.isEmpty) {
      return 'No se pudo determinar el tipo de comprobante para este negocio.';
    }

    if (!activeSequences.any(
      (sequence) => _matchesFiscalSequenceType(sequence, selectedType),
    )) {
      return 'El tipo de comprobante seleccionado ${_getNcfLabel(selectedType)} ($selectedType) no tiene una secuencia activa configurada.';
    }

    return null;
  }

  /// Devuelve un Future que resuelve cuando el cajero decide
  /// definitivamente: imprimio con exito (Reintentar OK), o eligio
  /// "Continuar sin imprimir" para cerrar el flujo aceptando la
  /// perdida del ticket. Mientras el cajero siga reintentando, este
  /// Future NO resuelve — esto mantiene abierto el modal padre que lo
  /// awaitea (PaymentSplitDialog) y evita que la mesa se libere
  /// silenciosamente sin haber visto el ticket.
  Future<void> _showReimpresionDialog({
    required BuildContext context,
    required WidgetRef ref,
    required String type,
    required Map<String, dynamic> data,
    Order? orderObj,
    List<OrderItem>? orderItems,
    List<Payment>? payments,
    String? tableName,
    String? waiterName,
    required String errorMsg,
    VoidCallback? onFinish,
  }) {
    final retryPrintLockKey = _printActionKey(
      type,
      orderId: orderObj?.id,
      checkId: data['checkId']?.toString(),
    );
    final completer = Completer<void>();

    void resolve() {
      if (!completer.isCompleted) completer.complete();
    }

    void open() {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PopScope(
          // Bloqueamos Esc / back-button del SO. Si Flutter dejara
          // popear este dialog, el `completer` quedaria sin resolver
          // y el modal de pago padre — que esta awaiteando — se
          // quedaria con `isPrinting=true` para siempre. Las dos
          // unicas vias de salida deben ser los botones del dialog.
          canPop: false,
          child: Dialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            child: Container(
              width: 440,
              padding: const EdgeInsets.all(32.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFFFEE2E2),
                        width: 2,
                      ),
                    ),
                    child: const Icon(
                      Icons.print_disabled_rounded,
                      color: Color(0xFFEF4444),
                      size: 48,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Fallo de Impresión',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: _salesTextPrimary,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'El pago se proceso pero no pudimos imprimir el ticket. Reintenta — si sigue fallando, puedes continuar sin imprimir, pero la mesa se liberara igual.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: _salesTextSecondary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 32),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            onFinish?.call();
                            resolve();
                          },
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text(
                            'Continuar sin imprimir',
                            style: TextStyle(
                              color: _salesTextSecondary,
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: FilledButton(
                          onPressed: () async {
                            final now = DateTime.now().millisecondsSinceEpoch;
                            final ts = ref.read(
                              _salesActionLocksProvider,
                            )[retryPrintLockKey];
                            if (ts != null &&
                                now - ts < _kLockMaxAge.inMilliseconds) {
                              return;
                            }
                            Navigator.pop(ctx);
                            await _runLockedAction(
                              ref,
                              retryPrintLockKey,
                              () async {
                                try {
                                  await _handlePrintFlow(
                                    context,
                                    ref,
                                    type,
                                    data,
                                    orderObj: orderObj,
                                    orderItems: orderItems,
                                    payments: payments,
                                    tableName: tableName,
                                    waiterName: waiterName,
                                    showSnackBar: true,
                                  );
                                  onFinish?.call();
                                  resolve();
                                } catch (e) {
                                  if (!context.mounted) {
                                    resolve();
                                    return;
                                  }
                                  // Reabrir mismo dialog para otra
                                  // ronda. El completer NO resuelve
                                  // hasta que el cajero decida.
                                  open();
                                }
                              },
                            );
                          },
                          style: FilledButton.styleFrom(
                            backgroundColor: _salesTotalColor,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            elevation: 0,
                          ),
                          child: const Text(
                            'Reintentar',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    open();
    return completer.future;
  }
}

class _BigCheckSelector extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final double itemCount;
  final bool isGlobal;

  const _BigCheckSelector({
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.itemCount = 0,
    this.isGlobal = false,
  });

  String _formatQty(double qty) {
    final normalized = double.parse(qty.toStringAsFixed(2));
    if ((normalized - normalized.roundToDouble()).abs() < 0.001) {
      return normalized.toStringAsFixed(0);
    }
    return normalized.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    const primaryColor = Color(0xFFF97316);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 92,
        height: 82,
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: isSelected ? primaryColor : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: isSelected
              ? null
              : Border.all(color: const Color(0xFFE5E7EB), width: 1.5),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: primaryColor.withValues(alpha: 0.4),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Icons Row
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: isGlobal
                  ? [
                      _buildIconBox(isSelected),
                      const SizedBox(width: 4),
                      _buildIconBox(isSelected),
                      const SizedBox(width: 4),
                      _buildIconBox(isSelected),
                    ]
                  : [_buildIconBox(isSelected)],
            ),
            const SizedBox(height: 8),
            // Label
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : const Color(0xFF374151),
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 3),
            // Items Count
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _formatQty(itemCount),
                  style: TextStyle(
                    color: isSelected
                        ? Colors.white.withValues(alpha: 0.9)
                        : const Color(0xFF6B7280),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.shopping_cart_outlined,
                  size: 13,
                  color: isSelected
                      ? Colors.white.withValues(alpha: 0.9)
                      : const Color(0xFF6B7280),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIconBox(bool isSelected) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: isSelected
            ? Colors.white.withValues(alpha: 0.2)
            : const Color(0xFFFFF7ED), // Orange 50
        borderRadius: BorderRadius.circular(4),
        border: isSelected
            ? Border.all(color: Colors.white.withValues(alpha: 0.4), width: 1)
            : Border.all(color: const Color(0xFFFFEDD5), width: 1),
      ),
      child: Center(
        child: Text(
          '\$',
          style: TextStyle(
            color: isSelected ? Colors.white : const Color(0xFFF97316),
            fontSize: 9,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

/// Pestañas de carritos de venta rápida simultáneos — SOLO retail.
/// Se monta sobre el ticket: una pestaña por venta abierta + botón "+" para
/// crear otra. Permite al cajero atender varios clientes a la vez.
class _RetailCartTabs extends ConsumerWidget {
  const _RetailCartTabs();

  static const Color _accent = Color(0xFFF97316); // primaryOrange

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cartsState = ref.watch(retailCartsProvider);
    final carts = cartsState.carts;
    if (carts.isEmpty) {
      return const SizedBox.shrink();
    }
    final notifier = ref.read(currentOrderProvider.notifier);

    return Container(
      decoration: const BoxDecoration(
        color: _salesSurface,
        border: Border(bottom: BorderSide(color: _salesDivider)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final cart in carts)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _RetailCartChip(
                        label: cart.label,
                        selected: cart.slotId == cartsState.activeSlotId,
                        onTap: () => notifier.switchRetailCart(cart.slotId),
                        onClose: () => _confirmClose(context, ref, cart),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          Material(
            color: _accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => notifier.newRetailCart(),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add_rounded, size: 18, color: _accent),
                    SizedBox(width: 4),
                    Text(
                      'Nueva',
                      style: TextStyle(
                        color: _accent,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClose(
    BuildContext context,
    WidgetRef ref,
    RetailCart cart,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Cerrar venta'),
        content: Text(
          '¿Cerrar "${cart.label}"? Si tiene productos, se anularán.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red[700]),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref
          .read(currentOrderProvider.notifier)
          .closeRetailCart(cart.slotId);
    }
  }
}

class _RetailCartChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const _RetailCartChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    const accent = _RetailCartTabs._accent;
    return Material(
      color: selected ? accent : const Color(0xFFF3F4F6),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? Colors.white : const Color(0xFF32363F),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: onClose,
                child: Icon(
                  Icons.close_rounded,
                  size: 15,
                  color: selected
                      ? Colors.white.withValues(alpha: 0.9)
                      : const Color(0xFF9E9E9E),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SalesToolsRail extends StatelessWidget {
  final VoidCallback onBack;
  final bool showTableActions;
  final VoidCallback onReleaseTable;
  final VoidCallback onVoidOrder;
  final VoidCallback onApplyDiscount;
  final VoidCallback onApplyCourtesy;
  final VoidCallback onTransferSession;
  final VoidCallback onMarkAllTakeout;

  const _SalesToolsRail({
    required this.onBack,
    required this.showTableActions,
    required this.onReleaseTable,
    required this.onVoidOrder,
    required this.onApplyDiscount,
    required this.onApplyCourtesy,
    required this.onTransferSession,
    required this.onMarkAllTakeout,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 88,
      decoration: const BoxDecoration(
        color: _salesSurface,
        border: Border(right: BorderSide(color: _salesDivider)),
      ),
      child: CustomScrollView(
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Column(
              children: [
                const SizedBox(height: 16),
                _RailButton(
                  icon: Icons.arrow_back_ios_new_rounded,
                  label: 'Regresar',
                  isPrimary: true,
                  onTap: onBack,
                ),
                const SizedBox(height: 16),
                const Divider(height: 1, color: _salesDivider),
                const SizedBox(height: 12),
                if (showTableActions) ...[
                  const Text(
                    'OPCIONES',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _salesTextSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _RailButton(
                    icon: Icons.swap_horiz_rounded,
                    label: 'Transferir\ncuenta',
                    onTap: onTransferSession,
                  ),
                  _RailButton(
                    icon: Icons.logout_rounded,
                    label: 'Liberar\nmesa',
                    onTap: onReleaseTable,
                  ),
                  _RailButton(
                    icon: Icons.block_rounded,
                    label: 'Anular\norden',
                    onTap: onVoidOrder,
                  ),
                  _RailButton(
                    icon: Icons.percent_rounded,
                    label: 'Aplicar\ndescuento',
                    onTap: onApplyDiscount,
                  ),
                  _RailButton(
                    icon: Icons.card_giftcard_rounded,
                    label: 'Cortesía\nproducto',
                    onTap: onApplyCourtesy,
                  ),
                  _RailButton(
                    icon: Icons.takeout_dining_rounded,
                    label: 'Todo\npara llevar',
                    onTap: onMarkAllTakeout,
                  ),
                ],
                const Spacer(),
                const SizedBox(height: 16),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isPrimary;

  const _RailButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = isPrimary ? _salesTotalColor : _salesTextPrimary;
    final bg = isPrimary
        ? _salesTotalColor.withValues(alpha: 0.12)
        : _salesSurface;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 72,
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: color,
                fontWeight: isPrimary ? FontWeight.w700 : FontWeight.w500,
                height: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final FontWeight? valueWeight;

  const _SummaryRow({
    required this.label,
    required this.value,
    this.valueColor,
    this.valueWeight,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: _salesTextPrimary,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: valueWeight ?? FontWeight.w600,
            color: valueColor ?? _salesTextPrimary,
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final Color color;

  const _SectionLabel({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: color,
        letterSpacing: 0.3,
      ),
    );
  }
}

class _CartLineItem extends ConsumerWidget {
  final OrderItem item;
  final bool isDraft;
  final VoidCallback? onDelete;
  final VoidCallback? onTap;

  const _CartLineItem({
    required this.item,
    required this.isDraft,
    required this.onDelete,
    this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = item.productName;
    final qty = item.quantity.toStringAsFixed(1);
    final currentOrder = ref.watch(currentOrderProvider.select((s) => s.order));
    final totalItem = _uiItemDisplayAmount(
      currentOrder,
      item,
    ).toStringAsFixed(2);
    final modifiers = item.modifiers;

    return Tooltip(
      // Tooltip de auditoría: solo hover de mouse (~1s). triggerMode manual
      // desactiva long-press default; el hover lo maneja MouseRegion aparte.
      waitDuration: const Duration(seconds: 1),
      triggerMode: TooltipTriggerMode.manual,
      richMessage: _buildAuditTooltipSpan(currentOrder?.origin),
      preferBelow: false,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2C).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        height: 1.45,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          hoverColor: Colors.black.withValues(alpha: 0.04),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isDraft && onDelete != null)
                  SizedBox(
                    width: 36,
                    child: IconButton(
                      onPressed: onDelete,
                      icon: const Icon(
                        Icons.close,
                        color: Color(0xFFEF4444),
                        size: 18,
                      ),
                      splashRadius: 16,
                    ),
                  )
                else
                  const SizedBox(width: 36),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    qty,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: _salesTextPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                if (!isDraft)
                  const Padding(
                    padding: EdgeInsets.only(right: 6, top: 2),
                    child: Icon(
                      Icons.check_circle,
                      size: 16,
                      color: Color(0xFF22C55E),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE6F0FF),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'P',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF3B82F6),
                      ),
                    ),
                  ),
                ),
                if (item.isTakeout) ...[
                  const SizedBox(width: 6),
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF3E8),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(
                        Icons.shopping_bag_outlined,
                        size: 13,
                        color: Color(0xFFF97316),
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          color: _salesTextPrimary,
                        ),
                      ),
                      if (modifiers.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: modifiers
                              .map((modifier) {
                                final hasExtraCost = modifier.price > 0.009;
                                // qty efectiva = item.quantity * modifier.qty.
                                // Asi el chip muestra "7x Ceresa (+RD$ 1050.00)"
                                // cuando hay 7 items con 1 ceresa cada uno —
                                // alineado con la formula per-unit del backend.
                                final itemQty = item.quantity <= 0
                                    ? 1.0
                                    : item.quantity;
                                final effectiveQty = itemQty * modifier.qty;
                                final totalCost = modifier.price * effectiveQty;
                                final qtyLabel = effectiveQty > 1.0001
                                    ? '${effectiveQty.toStringAsFixed(effectiveQty % 1 == 0 ? 0 : 1)}x '
                                    : '';
                                final isComboChoice = modifier.name.contains(
                                  ': ',
                                );
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isComboChoice
                                        ? const Color(0xFFFFF7ED)
                                        : const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: isComboChoice
                                          ? const Color(0xFFFED7AA)
                                          : const Color(0xFFE2E8F0),
                                    ),
                                  ),
                                  child: Text(
                                    hasExtraCost
                                        ? '$qtyLabel${modifier.name} (+RD\$ ${totalCost.toStringAsFixed(2)})'
                                        : '$qtyLabel${modifier.name}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: isComboChoice
                                          ? const Color(0xFF9A3412)
                                          : const Color(0xFF475569),
                                    ),
                                  ),
                                );
                              })
                              .toList(growable: false),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'RD\$ $totalItem',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _salesTotalColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Tooltip de auditoría que aparece al pasar el mouse sobre el item:
  /// nombre del producto, fecha/hora exacta de cuando se agregó, mozo
  /// que lo metió, notas si hay, y origen de la orden + estado de
  /// impresión ("IMPR. SI" si pasó de draft a sent, "IMPR. NO" si sigue
  /// en draft).
  InlineSpan _buildAuditTooltipSpan(String? orderOrigin) {
    final dateFmt = DateFormat('dd-MM-yyyy HH:mm');
    final fechaHora = dateFmt.format(item.createdAt.toLocal());
    final mozo = item.createdByEmployeeName ?? 'Sin asignar';
    final notes = cleanOrderItemNote(item.notes);
    final origen = (orderOrigin == null || orderOrigin.isEmpty)
        ? '—'
        : orderOrigin;
    final impreso = item.status == 'draft' ? 'NO' : 'SI';

    const labelStyle = TextStyle(color: Color(0xFFCBD5E1), fontSize: 12);
    const valueStyle = TextStyle(color: Colors.white, fontSize: 12);

    return TextSpan(
      style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.5),
      children: [
        TextSpan(
          text: '${item.productName}\n',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const TextSpan(text: 'Agregado: ', style: labelStyle),
        TextSpan(text: '$fechaHora\n', style: valueStyle),
        const TextSpan(text: 'Mozo: ', style: labelStyle),
        TextSpan(text: '$mozo\n', style: valueStyle),
        if (notes.isNotEmpty) ...[
          const TextSpan(text: 'Notas: ', style: labelStyle),
          TextSpan(text: '$notes\n', style: valueStyle),
        ],
        const TextSpan(text: 'Origen: ', style: labelStyle),
        TextSpan(text: '$origen · IMPR. $impreso', style: valueStyle),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final Color background;
  final VoidCallback? onPressed;
  final IconData icon;

  const _ActionButton({
    required this.label,
    required this.background,
    required this.onPressed,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      // PRD 6 § 4.5 — primary touch target.
      constraints: const BoxConstraints(minHeight: TouchTargets.primary),
      child: ElevatedButton(
        onPressed: onPressed,
        style:
            ElevatedButton.styleFrom(
              backgroundColor: background,
              disabledBackgroundColor: background.withValues(alpha: 0.35),
              elevation: 0,
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.md,
                vertical: Insets.sm,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(_salesRadiusButton),
              ),
            ).copyWith(
              overlayColor: WidgetStateProperty.all(
                Colors.white.withValues(alpha: 0.08),
              ),
            ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: Colors.white),
            const SizedBox(width: Insets.sm),
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: FontSizes.body,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SecondaryActionButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final IconData icon;

  const _SecondaryActionButton({
    required this.label,
    required this.onPressed,
    required this.icon,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      // PRD 6 § 4.5 — primary touch target (mismo que _ActionButton para
      // mantener altura visual consistente al alinearse en una Row).
      constraints: const BoxConstraints(minHeight: TouchTargets.primary),
      child: OutlinedButton(
        onPressed: onPressed,
        onLongPress: onLongPress,
        style: OutlinedButton.styleFrom(
          backgroundColor: onPressed == null
              ? _salesTabActiveBg.withValues(alpha: 0.45)
              : _salesTabActiveBg,
          side: BorderSide(
            color: onPressed == null
                ? _salesDivider.withValues(alpha: 0.55)
                : _salesDivider,
          ),
          disabledForegroundColor: _salesTextPrimary.withValues(alpha: 0.45),
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.md,
            vertical: Insets.sm,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_salesRadiusButton),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: onPressed == null
                  ? _salesTextPrimary.withValues(alpha: 0.45)
                  : _salesTextPrimary,
            ),
            const SizedBox(width: Insets.sm),
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: FontSizes.body,
                  fontWeight: FontWeight.w700,
                  color: onPressed == null
                      ? _salesTextPrimary.withValues(alpha: 0.45)
                      : _salesTextPrimary,
                  height: 1.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pre-Cuenta Dialog
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Selector de impresora
// ---------------------------------------------------------------------------

class _SentLineItem extends StatelessWidget {
  final String name;
  final double qty;
  final double total;
  final bool isTakeout;
  final VoidCallback? onTap;

  /// Item de referencia para el tooltip de auditoría. Como un grupo
  /// puede tener varios items con distintos meseros/timestamps, usamos
  /// el primero del grupo y la etiqueta del tooltip aclara "Primero
  /// agregado" si hay más de uno.
  final OrderItem? auditItem;
  final String? orderOrigin;
  final int groupSize;

  const _SentLineItem({
    required this.name,
    required this.qty,
    required this.total,
    required this.isTakeout,
    this.onTap,
    this.auditItem,
    this.orderOrigin,
    this.groupSize = 1,
  });

  @override
  Widget build(BuildContext context) {
    final inkWell = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            // Cantidad
            // Cantidad: Centrada en 52px y más compacta
            SizedBox(
              width: 52,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _salesDivider),
                  ),
                  child: Text(
                    qty.toStringAsFixed(qty % 1 == 0 ? 0 : 1),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: _salesTextPrimary,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Iconos de estado
            const Icon(Icons.check_circle, size: 18, color: Color(0xFF22C55E)),
            const SizedBox(width: 6),
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFE6F0FF),
                borderRadius: BorderRadius.circular(7),
              ),
              child: const Text(
                'P',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF3B82F6),
                ),
              ),
            ),
            if (isTakeout) ...[
              const SizedBox(width: 6),
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E8),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: const Icon(
                  Icons.shopping_bag_outlined,
                  size: 14,
                  color: Color(0xFFF97316),
                ),
              ),
            ],
            const SizedBox(width: 10),
            // Nombre
            Expanded(
              child: Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: _salesTextPrimary,
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Precio
            Text(
              'RD\$ ${total.toStringAsFixed(2)}',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: _salesTotalColor,
              ),
            ),
          ],
        ),
      ),
    );

    final audit = auditItem;
    if (audit == null) return inkWell;

    return Tooltip(
      // Mismo patrón que `_CartLineItem`: solo hover (~1s), sin long-press.
      waitDuration: const Duration(seconds: 1),
      triggerMode: TooltipTriggerMode.manual,
      richMessage: _buildAuditTooltipSpan(audit, orderOrigin, groupSize),
      preferBelow: false,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2C).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        height: 1.45,
      ),
      child: inkWell,
    );
  }

  /// Tooltip de auditoría para items YA enviados a cocina.
  /// Diferencia con `_CartLineItem`:
  ///   - Si el grupo agrupa varios `order_items` con el mismo producto
  ///     (`groupSize > 1`), aclara "Primero agregado" en vez de
  ///     "Agregado" — porque los timestamps/mozos del resto del grupo
  ///     no se muestran.
  ///   - "IMPR." siempre es "SI" — por definición los items en este
  ///     widget ya salieron de draft.
  InlineSpan _buildAuditTooltipSpan(
    OrderItem item,
    String? orderOrigin,
    int groupSize,
  ) {
    final dateFmt = DateFormat('dd-MM-yyyy HH:mm');
    final fechaHora = dateFmt.format(item.createdAt.toLocal());
    final mozo = item.createdByEmployeeName ?? 'Sin asignar';
    final notes = cleanOrderItemNote(item.notes);
    final origen = (orderOrigin == null || orderOrigin.isEmpty)
        ? '—'
        : orderOrigin;
    final fechaLabel = groupSize > 1 ? 'Primero agregado: ' : 'Agregado: ';

    const labelStyle = TextStyle(color: Color(0xFFCBD5E1), fontSize: 12);
    const valueStyle = TextStyle(color: Colors.white, fontSize: 12);

    return TextSpan(
      style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.5),
      children: [
        TextSpan(
          text: '${item.productName}\n',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        TextSpan(text: fechaLabel, style: labelStyle),
        TextSpan(text: '$fechaHora\n', style: valueStyle),
        const TextSpan(text: 'Mozo: ', style: labelStyle),
        TextSpan(text: '$mozo\n', style: valueStyle),
        if (notes.isNotEmpty) ...[
          const TextSpan(text: 'Notas: ', style: labelStyle),
          TextSpan(text: '$notes\n', style: valueStyle),
        ],
        const TextSpan(text: 'Origen: ', style: labelStyle),
        TextSpan(text: '$origen · IMPR. SI', style: valueStyle),
      ],
    );
  }
}

class _OrderSyncStatusChip extends ConsumerWidget {
  final CurrentOrderState orderState;

  const _OrderSyncStatusChip({required this.orderState});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Color color = orderState.isOfflineMode
        ? const Color(0xFFF59E0B)
        : orderState.syncInFlight
        ? const Color(0xFF2563EB)
        : const Color(0xFF10B981);
    final IconData icon = orderState.isOfflineMode
        ? Icons.cloud_off_rounded
        : orderState.syncInFlight
        ? Icons.sync
        : Icons.cloud_done_rounded;
    final String text = orderState.isOfflineMode
        ? 'Offline'
        : orderState.syncInFlight
        ? 'Sincronizando'
        : orderState.pendingOfflineActions > 0
        ? 'Pendiente sync'
        : 'Al día';

    final lastSyncLabel = orderState.lastSyncAt == null
        ? null
        : '${orderState.lastSyncAt!.hour.toString().padLeft(2, '0')}:${orderState.lastSyncAt!.minute.toString().padLeft(2, '0')}';

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.30)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Text(
                orderState.pendingOfflineActions > 0
                    ? '$text • ${orderState.pendingOfflineActions}'
                    : text,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              if (lastSyncLabel != null) ...[
                const SizedBox(width: 6),
                Text(
                  '• $lastSyncLabel',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: color.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ],
          ),
        ),
        OutlinedButton.icon(
          onPressed: orderState.syncInFlight
              ? null
              : () async {
                  await ref
                      .read(currentOrderProvider.notifier)
                      .syncPendingOfflineActions(force: true);
                },
          icon: const Icon(Icons.sync_rounded, size: 15),
          label: const Text('Sync'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
        ),
      ],
    );
  }
}

class _GroupedSentItem {
  final String name;
  final double qty;
  final double total;
  final bool isTakeout;
  final List<OrderItem> items;

  const _GroupedSentItem({
    required this.name,
    required this.qty,
    required this.total,
    required this.isTakeout,
    required this.items,
  });

  _GroupedSentItem copyWith({
    String? name,
    double? qty,
    double? total,
    bool? isTakeout,
    List<OrderItem>? items,
  }) {
    return _GroupedSentItem(
      name: name ?? this.name,
      qty: qty ?? this.qty,
      total: total ?? this.total,
      isTakeout: isTakeout ?? this.isTakeout,
      items: items ?? this.items,
    );
  }
}

// -----------------------------------------------------------------------------
// 3. CATALOG AREA
// -----------------------------------------------------------------------------
class _CatalogArea extends ConsumerStatefulWidget {
  final OrderOrigin origin;
  final String tableCode;
  final Function(dynamic) onProductTap;
  const _CatalogArea({
    required this.origin,
    required this.tableCode,
    required this.onProductTap,
  });

  @override
  ConsumerState<_CatalogArea> createState() => _CatalogAreaState();
}

class _CatalogAreaState extends ConsumerState<_CatalogArea>
    with TickerProviderStateMixin {
  late TabController _mainTabController;
  final TextEditingController _searchController = TextEditingController();
  String? _activeCategoryId;

  @override
  void initState() {
    super.initState();
    // Tabs: Categorias, Menu, Ofertas, Favoritos
    _mainTabController = TabController(length: 4, vsync: this);
    _mainTabController.addListener(_handleTabChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(menuBrowserVmProvider.notifier).loadAll();
    });
  }

  void _handleTabChange() {
    if (_mainTabController.indexIsChanging) return;

    final menuState = ref.read(menuBrowserVmProvider);
    final notifier = ref.read(menuBrowserVmProvider.notifier);
    final selectedCategoryId = menuState.selectedCategoryId;
    final searchText = _searchController.text.trim();
    switch (_mainTabController.index) {
      case 0:
        if (menuState.categories.isEmpty) {
          notifier.loadAll();
        }
        break;
      case 1:
        if (searchText.isNotEmpty) {
          if (menuState.productsMode != MenuProductsMode.search ||
              menuState.search != searchText ||
              menuState.products.isEmpty) {
            notifier.searchProducts(searchText);
          }
        } else {
          if (selectedCategoryId != null && selectedCategoryId.isNotEmpty) {
            if (menuState.productsMode != MenuProductsMode.category ||
                menuState.loadedCategoryId != selectedCategoryId ||
                menuState.products.isEmpty) {
              notifier.loadProductsByCategory(selectedCategoryId);
            }
          } else {
            if (menuState.productsMode != MenuProductsMode.all ||
                menuState.products.isEmpty) {
              notifier.loadAllProducts();
            }
          }
        }
        break;
      case 2:
        if (menuState.productsMode != MenuProductsMode.offers ||
            menuState.products.isEmpty) {
          notifier.loadOffers();
        }
        break;
      case 3:
        if (menuState.productsMode != MenuProductsMode.favorites ||
            menuState.products.isEmpty) {
          notifier.loadFavoriteProducts();
        }
        break;
    }
  }

  @override
  void dispose() {
    _mainTabController.removeListener(_handleTabChange);
    _mainTabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isCompact = ResponsiveHelper.isMobile(context);
    final hPad = isCompact ? 12.0 : 24.0;
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(hPad, isCompact ? 12 : 24, hPad, 0),
          child: Row(
            children: [
              Expanded(
                child: _SearchField(
                  controller: _searchController,
                  onChanged: (value) {
                    final menuState = ref.read(menuBrowserVmProvider);
                    final notifier = ref.read(menuBrowserVmProvider.notifier);
                    if (value.trim().isEmpty) {
                      if (_mainTabController.index == 3) {
                        if (menuState.productsMode !=
                                MenuProductsMode.favorites ||
                            menuState.products.isEmpty) {
                          notifier.loadFavoriteProducts();
                        }
                      } else if (_mainTabController.index == 2) {
                        if (menuState.productsMode !=
                                MenuProductsMode.offers ||
                            menuState.products.isEmpty) {
                          notifier.loadOffers();
                        }
                      } else if (_mainTabController.index == 0) {
                        if (menuState.categories.isEmpty) {
                          notifier.loadAll();
                        }
                      } else {
                        final selectedCategoryId = menuState.selectedCategoryId;
                        if (selectedCategoryId != null &&
                            selectedCategoryId.isNotEmpty) {
                          if (menuState.productsMode !=
                                  MenuProductsMode.category ||
                              menuState.loadedCategoryId !=
                                  selectedCategoryId ||
                              menuState.products.isEmpty) {
                            notifier.loadProductsByCategory(selectedCategoryId);
                          }
                        } else {
                          if (menuState.productsMode != MenuProductsMode.all ||
                              menuState.products.isEmpty) {
                            notifier.loadAllProducts();
                          }
                        }
                      }
                      return;
                    }

                    final q = value.trim();
                    if (menuState.productsMode != MenuProductsMode.search ||
                        menuState.search != q) {
                      notifier.searchProducts(q);
                    }
                    if (_mainTabController.index != 1) {
                      _mainTabController.animateTo(1);
                    }
                  },
                ),
              ),
              if (!isCompact) ...[
                const SizedBox(width: 12),
                const SalesZoomControl(),
              ],
            ],
          ),
        ),
        SizedBox(height: isCompact ? 8 : 12),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: hPad),
          child: _SegmentedTabs(
            controller: _mainTabController,
            labels: const ['Categorias', 'Menu', 'Ofertas', 'Favoritos'],
          ),
        ),
        SizedBox(height: isCompact ? 10 : 16),
        Expanded(
          child: Container(
            color: _salesSurface,
            child: TabBarView(
              controller: _mainTabController,
              children: [
                // 1. Grid Categorias
                _CategoriesPane(
                  activeCategoryId: _activeCategoryId,
                  onCategoryTap: (catId) {
                    setState(() => _activeCategoryId = catId);
                    ref
                        .read(menuBrowserVmProvider.notifier)
                        .loadProductsByCategory(catId);
                  },
                  onBackToCategories: () {
                    setState(() => _activeCategoryId = null);
                  },
                  onProductTap: widget.onProductTap,
                ),
                // 2. Grid Productos
                _ProductsGrid(onProductTap: widget.onProductTap),
                // 3. Ofertas vendibles
                _ProductsGrid(
                  onProductTap: widget.onProductTap,
                  emptyText:
                      'No tienes ofertas activas para vender.\n'
                      'Crea una en Ajustes → Ofertas y Combos (auto-aplicar).',
                ),
                // 4. Favoritos
                _ProductsGrid(
                  onProductTap: widget.onProductTap,
                  emptyText: 'Todavía no hay productos frecuentes',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _AssignCustomerDialog extends ConsumerStatefulWidget {
  const _AssignCustomerDialog();

  @override
  ConsumerState<_AssignCustomerDialog> createState() =>
      _AssignCustomerDialogState();
}

class _AssignCustomerDialogState extends ConsumerState<_AssignCustomerDialog> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _customersScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(customersViewModelProvider).init();
    });
  }

  @override
  void dispose() {
    _customersScrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openCreateCustomerFlow() async {
    final created = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _CreateCustomerDialog(),
    );

    if (!mounted || created == null) return;
    Navigator.of(context).pop(created);
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(customersViewModelProvider);
    final media = MediaQuery.of(context);
    final dialogWidth = media.size.width < 980 ? media.size.width - 32 : 920.0;
    final dialogHeight = media.size.height < 760
        ? media.size.height - 32
        : 680.0;

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _salesTabActiveBg,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.person_search_rounded,
                      color: _salesTotalColor,
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Cliente de la venta',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: _salesTextPrimary,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Busca y asigna un cliente. Si no existe, créalo con el botón + sin salir del flujo.',
                          style: TextStyle(
                            fontSize: 13,
                            color: _salesTextSecondary,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: _salesSurface,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: _salesDivider),
                    boxShadow: _salesSoftShadow,
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Clientes guardados',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: _salesTextPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  const Text(
                                    'Vista limpia para ventas rápidas: buscador, lista y alta en un paso.',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _salesTextSecondary,
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  TextField(
                                    controller: _searchController,
                                    onChanged: (value) => ref
                                        .read(customersViewModelProvider)
                                        .search(value),
                                    decoration: InputDecoration(
                                      hintText:
                                          'Buscar por nombre, teléfono o correo',
                                      prefixIcon: const Icon(Icons.search),
                                      filled: true,
                                      fillColor: _salesSurface,
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(
                                          _salesRadiusField,
                                        ),
                                        borderSide: const BorderSide(
                                          color: _salesDivider,
                                        ),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(
                                          _salesRadiusField,
                                        ),
                                        borderSide: const BorderSide(
                                          color: _salesDivider,
                                        ),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(
                                          _salesRadiusField,
                                        ),
                                        borderSide: const BorderSide(
                                          color: _salesTotalColor,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 16),
                            Tooltip(
                              message: 'Crear cliente',
                              child: SizedBox(
                                width: 54,
                                height: 54,
                                child: FilledButton(
                                  onPressed: _openCreateCustomerFlow,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: _salesTotalColor,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                    padding: EdgeInsets.zero,
                                  ),
                                  child: const Icon(
                                    Icons.add_rounded,
                                    size: 28,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1, color: _salesDivider),
                      Expanded(
                        child: vm.isLoading
                            ? const Center(
                                child: CircularProgressIndicator(
                                  color: _salesTotalColor,
                                ),
                              )
                            : vm.customers.isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Container(
                                        width: 72,
                                        height: 72,
                                        decoration: BoxDecoration(
                                          color: _salesTabActiveBg,
                                          borderRadius: BorderRadius.circular(
                                            22,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.people_alt_outlined,
                                          color: _salesTotalColor,
                                          size: 34,
                                        ),
                                      ),
                                      const SizedBox(height: 14),
                                      const Text(
                                        'No se encontraron clientes',
                                        style: TextStyle(
                                          color: _salesTextPrimary,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 16,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      const Text(
                                        'Prueba con otra búsqueda o crea uno nuevo con el botón +.',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: _salesTextSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : Scrollbar(
                                controller: _customersScrollController,
                                child: ListView.separated(
                                  controller: _customersScrollController,
                                  padding: const EdgeInsets.all(14),
                                  itemCount: vm.customers.length,
                                  separatorBuilder: (context, index) =>
                                      const SizedBox(height: 10),
                                  itemBuilder: (context, index) {
                                    final customer = vm.customers[index];
                                    final name =
                                        customer['name']?.toString() ??
                                        'Cliente';
                                    final phone = customer['phone']?.toString();
                                    final email = customer['email']?.toString();
                                    final address = customer['address']
                                        ?.toString();
                                    final subtitleParts =
                                        [phone, email, address]
                                            .where(
                                              (value) =>
                                                  value != null &&
                                                  value.trim().isNotEmpty,
                                            )
                                            .cast<String>()
                                            .toList();

                                    return InkWell(
                                      borderRadius: BorderRadius.circular(16),
                                      onTap: () =>
                                          Navigator.of(context).pop(customer),
                                      child: Container(
                                        padding: const EdgeInsets.all(14),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFFFFBF6),
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                          border: Border.all(
                                            color: _salesDivider,
                                          ),
                                        ),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            CircleAvatar(
                                              radius: 22,
                                              backgroundColor:
                                                  _salesTabActiveBg,
                                              child: Text(
                                                name.isNotEmpty
                                                    ? name[0].toUpperCase()
                                                    : 'C',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  color: _salesTextPrimary,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    name,
                                                    style: const TextStyle(
                                                      fontSize: 14,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: _salesTextPrimary,
                                                    ),
                                                  ),
                                                  if (subtitleParts
                                                      .isNotEmpty) ...[
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      subtitleParts.join(' • '),
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 12,
                                                        color:
                                                            _salesTextSecondary,
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 6,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: _salesTabActiveBg,
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: const Text(
                                                'Seleccionar',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                  color: _salesTextPrimary,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateCustomerDialog extends ConsumerStatefulWidget {
  const _CreateCustomerDialog();

  @override
  ConsumerState<_CreateCustomerDialog> createState() =>
      _CreateCustomerDialogState();
}

class _CreateCustomerDialogState extends ConsumerState<_CreateCustomerDialog> {
  final TextEditingController _firstNameController = TextEditingController();
  final TextEditingController _lastNameController = TextEditingController();
  final TextEditingController _legalNameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _creditLimitController = TextEditingController();
  final TextEditingController _maxCreditController = TextEditingController();
  final TextEditingController _taxIdController = TextEditingController();
  final ScrollController _formScrollController = ScrollController();

  bool _isSaving = false;
  bool _isAdvancedMode = false;
  String _customerType = 'General';
  String _documentType = 'Cédula';
  DateTime? _birthDate;

  // DGII lookup state — espejo del flujo del editor de clientes en
  // ajustes. El cajero escribe el RNC, click "Buscar en DGII" → si
  // existe en el padrón, autocompleta nombre/apellido/razón social y
  // muestra estado, actividad económica y si es facturador electrónico.
  // Los indicadores se muestran (no se guardan): re-query si necesitas
  // data fresca.
  bool _isLookingUpDgii = false;
  String? _dgiiNote;
  String? _dgiiEstado;
  String? _dgiiActividad;
  bool? _dgiiFacturador;

  @override
  void dispose() {
    _formScrollController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _legalNameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _addressController.dispose();
    _creditLimitController.dispose();
    _maxCreditController.dispose();
    _taxIdController.dispose();
    super.dispose();
  }

  /// Consulta el RNC contra el padrón DGII (rnc.megaplus.com.do). Si
  /// existe, intenta llenar nombre/apellido (parsea la primera palabra
  /// como nombre y el resto como apellido — heurística simple, cajero
  /// puede ajustar manual). Para razones sociales (empresas), si el
  /// nombre vino en una sola pieza, lo deja todo en _firstNameController
  /// y _lastNameController vacío.
  Future<void> _lookupDgii() async {
    final raw = _taxIdController.text.trim();
    if (raw.isEmpty) {
      setState(() => _dgiiNote = 'Escribe el RNC primero.');
      return;
    }
    setState(() {
      _isLookingUpDgii = true;
      _dgiiNote = null;
      _dgiiEstado = null;
      _dgiiActividad = null;
      _dgiiFacturador = null;
    });
    try {
      final info = await DgiiLookupService().lookupByRnc(raw);
      if (!mounted) return;
      if (info == null) {
        setState(() => _dgiiNote = 'RNC no encontrado en el registro de DGII.');
        return;
      }
      // Nombre comercial (firstName/lastName): solo llenamos si está
      // vacío — no pisamos input manual del cajero.
      final fillName = info.displayName;
      if (fillName != null && fillName.isNotEmpty) {
        if (_firstNameController.text.trim().isEmpty &&
            _lastNameController.text.trim().isEmpty) {
          final parts = fillName.split(RegExp(r'\s+'));
          if (parts.length == 1) {
            _firstNameController.text = parts.first;
          } else {
            _firstNameController.text = parts.first;
            _lastNameController.text = parts.sublist(1).join(' ');
          }
        }
      }
      // Razón social: la sobreescribimos siempre que venga del padrón
      // DGII. Es data oficial que cambia poco; el cajero típicamente no
      // la modifica manual.
      final legal = info.nombreRazonSocial;
      if (legal != null && legal.isNotEmpty) {
        _legalNameController.text = legal;
      }
      setState(() {
        _dgiiNote = null;
        _dgiiEstado = info.estado;
        _dgiiActividad = info.actividadEconomica;
        _dgiiFacturador = info.esFacturadorElectronico;
      });
    } on InvalidRncException catch (e) {
      if (!mounted) return;
      setState(() => _dgiiNote = e.toString());
    } catch (e) {
      if (!mounted) return;
      setState(() => _dgiiNote = 'Error consultando DGII: $e');
    } finally {
      if (mounted) {
        setState(() => _isLookingUpDgii = false);
      }
    }
  }

  /// Badges no-persistidos del padrón DGII tras un lookup exitoso. Solo
  /// se muestran como info — DGII puede cambiar el estado del
  /// contribuyente, así que mantener una copia stale en DB confunde más
  /// que ayuda. Re-query si el cajero quiere data fresca.
  Widget _buildDgiiBadges() {
    final estado = _dgiiEstado;
    final actividad = _dgiiActividad;
    final facturador = _dgiiFacturador;
    if (estado == null && actividad == null && facturador == null) {
      return const SizedBox.shrink();
    }
    final children = <Widget>[];
    if (estado != null) {
      final isActivo = estado.trim().toUpperCase() == 'ACTIVO';
      children.add(
        _dgiiBadge(
          label: estado,
          color: isActivo ? const Color(0xFF22C55E) : Colors.red,
        ),
      );
    }
    if (facturador == true) {
      children.add(
        _dgiiBadge(
          label: 'Facturador Electrónico',
          color: const Color(0xFF3B82F6),
        ),
      );
    }
    if (actividad != null) {
      children.add(_dgiiBadge(label: actividad, color: _salesTextSecondary));
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(spacing: 6, runSpacing: 6, children: children),
    );
  }

  Widget _dgiiBadge({required String label, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Future<void> _pickBirthDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(1995),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );

    if (picked != null) {
      setState(() => _birthDate = picked);
    }
  }

  Widget _buildCreateField({
    required String label,
    required String hint,
    required TextEditingController controller,
    TextInputType? keyboardType,
    int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: _salesTextPrimary,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          maxLines: maxLines,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: _salesTextHint, fontSize: 13),
            filled: true,
            fillColor: _salesSurface,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(_salesRadiusField),
              borderSide: const BorderSide(color: _salesDivider),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(_salesRadiusField),
              borderSide: const BorderSide(color: _salesTotalColor),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDropdownField({
    required String label,
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: _salesTextPrimary,
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: value,
          items: items
              .map(
                (item) =>
                    DropdownMenuItem<String>(value: item, child: Text(item)),
              )
              .toList(),
          onChanged: onChanged,
          decoration: InputDecoration(
            filled: true,
            fillColor: _salesSurface,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(_salesRadiusField),
              borderSide: const BorderSide(color: _salesDivider),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(_salesRadiusField),
              borderSide: const BorderSide(color: _salesTotalColor),
            ),
          ),
        ),
      ],
    );
  }

  Map<String, dynamic> _buildPayload() {
    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final fullName = [
      firstName,
      lastName,
    ].where((value) => value.isNotEmpty).join(' ').trim();

    final advancedNotes = <String, dynamic>{
      'first_name': firstName,
      'last_name': lastName,
      'customer_type': _customerType,
      'document_type': _documentType,
      // business_name removido — la razón social legal ahora se guarda
      // en `legal_name` (columna top-level), no como nota.
      'birth_date': _birthDate == null
          ? null
          : DateFormat('yyyy-MM-dd').format(_birthDate!),
      'credit_limit': _creditLimitController.text.trim(),
      'max_credit': _maxCreditController.text.trim(),
      'mode': _isAdvancedMode ? 'advanced' : 'normal',
    };

    advancedNotes.removeWhere(
      (key, value) => value == null || value.toString().trim().isEmpty,
    );

    return {
      'name': fullName,
      'legal_name': _legalNameController.text.trim(),
      'phone': _phoneController.text.trim(),
      'email': _emailController.text.trim(),
      'address': _addressController.text.trim(),
      'tax_id': _taxIdController.text.trim(),
      'notes': advancedNotes.entries
          .map((entry) => '${entry.key}: ${entry.value}')
          .join(' | '),
    };
  }

  Future<void> _createCustomer() async {
    final payload = _buildPayload();
    if ((payload['name'] as String).isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('El nombre y apellido del cliente son obligatorios.'),
        ),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      final created = await ref
          .read(customersViewModelProvider)
          .addCustomer(payload);
      if (!mounted || created == null) return;
      Navigator.of(context).pop(created);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo crear el cliente: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final dialogWidth = media.size.width < 900 ? media.size.width - 32 : 820.0;
    final dialogHeight = media.size.height < 860
        ? media.size.height - 32
        : 760.0;

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFEDD5),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.person_add_alt_1_rounded,
                      color: _salesTotalColor,
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Nuevo cliente',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: _salesTextPrimary,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Crea el cliente sin salir de ventas. Puedes usar modo normal o avanzado.',
                          style: TextStyle(
                            fontSize: 13,
                            color: _salesTextSecondary,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _isSaving
                        ? null
                        : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: _salesTabActiveBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _salesDivider),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: _isSaving
                            ? null
                            : () => setState(() => _isAdvancedMode = false),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: !_isAdvancedMode
                                ? _salesSurface
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'Normal',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: !_isAdvancedMode
                                  ? _salesTextPrimary
                                  : _salesTextSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: InkWell(
                        onTap: _isSaving
                            ? null
                            : () => setState(() => _isAdvancedMode = true),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: _isAdvancedMode
                                ? _salesSurface
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'Avanzado',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: _isAdvancedMode
                                  ? _salesTextPrimary
                                  : _salesTextSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFBF6),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _salesDivider),
                  ),
                  child: Scrollbar(
                    controller: _formScrollController,
                    child: SingleChildScrollView(
                      controller: _formScrollController,
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: _buildCreateField(
                                  label: 'Nombre',
                                  hint: 'Ej. María',
                                  controller: _firstNameController,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: _buildCreateField(
                                  label: 'Apellido',
                                  hint: 'Ej. Pérez',
                                  controller: _lastNameController,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          _buildCreateField(
                            label: 'Teléfono',
                            hint: '809...',
                            controller: _phoneController,
                            keyboardType: TextInputType.phone,
                          ),
                          const SizedBox(height: 14),
                          // RNC + botón "Buscar en DGII". Mismo flujo que
                          // el editor de clientes en ajustes: el cajero
                          // escribe el RNC, click → autocompleta nombre
                          // y muestra estado del contribuyente.
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                child: _buildCreateField(
                                  label: 'RNC / Cédula',
                                  hint: 'Ej. 131234567',
                                  controller: _taxIdController,
                                  keyboardType: TextInputType.number,
                                ),
                              ),
                              const SizedBox(width: 12),
                              SizedBox(
                                height: 48,
                                child: ElevatedButton.icon(
                                  onPressed: _isLookingUpDgii
                                      ? null
                                      : _lookupDgii,
                                  icon: _isLookingUpDgii
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Icon(Icons.search, size: 16),
                                  label: const Text('Buscar en DGII'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: _salesTotalColor,
                                    foregroundColor: Colors.white,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (_dgiiNote != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              _dgiiNote!,
                              style: const TextStyle(
                                fontSize: 12,
                                color: _salesTextSecondary,
                              ),
                            ),
                          ],
                          _buildDgiiBadges(),
                          const SizedBox(height: 14),
                          // Razón social — usada en e-CF / facturas
                          // con NCF. Se autocompleta tras lookup DGII
                          // pero el cajero puede ajustarla manual.
                          _buildCreateField(
                            label: 'Razón Social',
                            hint: 'Ej. Banco Popular Dominicano S.A.',
                            controller: _legalNameController,
                          ),
                          if (_isAdvancedMode) ...[
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: _buildDropdownField(
                                    label: 'Tipo de cliente',
                                    value: _customerType,
                                    items: const [
                                      'General',
                                      'Frecuente',
                                      'Empresa',
                                      'Crédito',
                                    ],
                                    onChanged: (value) {
                                      if (value != null) {
                                        setState(() => _customerType = value);
                                      }
                                    },
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: _buildDropdownField(
                                    label: 'Tipo de documento',
                                    value: _documentType,
                                    items: const [
                                      'Cédula',
                                      'RNC',
                                      'Pasaporte',
                                      'Otro',
                                    ],
                                    onChanged: (value) {
                                      if (value != null) {
                                        setState(() => _documentType = value);
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Fecha de nacimiento',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: _salesTextPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      OutlinedButton.icon(
                                        onPressed: _pickBirthDate,
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: _salesTextPrimary,
                                          backgroundColor: _salesSurface,
                                          side: const BorderSide(
                                            color: _salesDivider,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 16,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              _salesRadiusField,
                                            ),
                                          ),
                                        ),
                                        icon: const Icon(Icons.cake_outlined),
                                        label: Text(
                                          _birthDate == null
                                              ? 'Seleccionar fecha (opcional)'
                                              : DateFormat(
                                                  'dd/MM/yyyy',
                                                ).format(_birthDate!),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: _buildCreateField(
                                    label: 'Correo',
                                    hint: 'cliente@correo.com',
                                    controller: _emailController,
                                    keyboardType: TextInputType.emailAddress,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            _buildCreateField(
                              label: 'Dirección',
                              hint: 'Dirección del cliente',
                              controller: _addressController,
                              maxLines: 2,
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: _buildCreateField(
                                    label: 'Límite de crédito',
                                    hint: '0.00',
                                    controller: _creditLimitController,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: _buildCreateField(
                                    label: 'Máximo de crédito',
                                    hint: '0.00',
                                    controller: _maxCreditController,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                          ] else ...[
                            const SizedBox(height: 14),
                            const Text(
                              'Modo normal: alta rápida con los datos mínimos para seguir la venta sin fricción.',
                              style: TextStyle(
                                fontSize: 12,
                                color: _salesTextSecondary,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isSaving
                          ? null
                          : () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _salesTextPrimary,
                        side: const BorderSide(color: _salesDivider),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            _salesRadiusButton,
                          ),
                        ),
                      ),
                      child: const Text('Cancelar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _isSaving ? null : _createCustomer,
                      style: FilledButton.styleFrom(
                        backgroundColor: _salesTotalColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            _salesRadiusButton,
                          ),
                        ),
                      ),
                      icon: _isSaving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check_circle_outline_rounded),
                      label: Text(
                        _isSaving ? 'Guardando...' : 'Crear y asignar cliente',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _SearchField({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: 'Buscar productos',
          hintStyle: const TextStyle(color: _salesTextHint, fontSize: 13),
          prefixIcon: const Icon(Icons.search, size: 18),
          filled: true,
          fillColor: _salesSurface,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(_salesRadiusField),
            borderSide: const BorderSide(color: _salesDivider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(_salesRadiusField),
            borderSide: const BorderSide(color: _salesDivider),
          ),
        ),
      ),
    );
  }
}

class _SegmentedTabs extends StatefulWidget {
  final TabController controller;
  final List<String> labels;

  const _SegmentedTabs({required this.controller, required this.labels});

  @override
  State<_SegmentedTabs> createState() => _SegmentedTabsState();
}

// PRD 8 Fase 2 fix #4 — antes era StatelessWidget con AnimatedBuilder
// sobre `controller`. Eso reconstruía el Row entero en cada frame de
// la animación entre tabs (~16 ms × 300 ms = ~18 rebuilds del Row),
// pero el visual solo cambia cuando `controller.index` cambia (1 vez
// por tap). Ahora escuchamos puntualmente el cambio de `index` con un
// listener y `setState` solo cuando cambia — el Row se rebuild una
// sola vez por tab switch, no 18.
class _SegmentedTabsState extends State<_SegmentedTabs> {
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.controller.index;
    widget.controller.addListener(_onTabChange);
  }

  void _onTabChange() {
    if (!mounted) return;
    if (widget.controller.index != _currentIndex) {
      setState(() => _currentIndex = widget.controller.index);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTabChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _salesTabActiveBg,
        borderRadius: BorderRadius.circular(_salesRadiusTab),
        border: Border.all(color: _salesDivider),
      ),
      child: Row(
        children: [
          for (int i = 0; i < widget.labels.length; i++) ...[
            Expanded(
              child: InkWell(
                onTap: () => widget.controller.animateTo(i),
                borderRadius: BorderRadius.circular(_salesRadiusTab - 2),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _currentIndex == i
                        ? _salesSurface
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(_salesRadiusTab - 2),
                  ),
                  child: Text(
                    widget.labels[i],
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: _currentIndex == i
                          ? _salesTextPrimary
                          : _salesTextSecondary,
                    ),
                  ),
                ),
              ),
            ),
            if (i < widget.labels.length - 1) const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

class _CategoriesPane extends ConsumerWidget {
  final String? activeCategoryId;
  final Function(String) onCategoryTap;
  final VoidCallback onBackToCategories;
  final Function(dynamic) onProductTap;

  const _CategoriesPane({
    required this.activeCategoryId,
    required this.onCategoryTap,
    required this.onBackToCategories,
    required this.onProductTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(menuBrowserVmProvider);
    final activeCategory = activeCategoryId == null
        ? null
        : state.categories.where((c) => c.id == activeCategoryId).firstOrNull;

    if (activeCategory == null) {
      return _CategoriesGrid(onCategoryTap: onCategoryTap);
    }

    return Column(
      children: [
        _SelectedCatalogCategoryHeader(
          categoryName: activeCategory.name,
          onBack: onBackToCategories,
        ),
        const Divider(height: 1),
        Expanded(
          child: _ProductsGrid(
            onProductTap: onProductTap,
            emptyText: 'No hay productos en esta categoría',
          ),
        ),
      ],
    );
  }
}

/// Grid shimmer para el catálogo (categorías/productos) mientras carga, en
/// vez de un spinner — da sensación de velocidad y mantiene el layout estable.
class _CatalogGridSkeleton extends StatelessWidget {
  const _CatalogGridSkeleton();

  @override
  Widget build(BuildContext context) {
    final isCompact = ResponsiveHelper.isMobile(context);
    return GridView.builder(
      padding: EdgeInsets.all(isCompact ? 12 : 16),
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: isCompact
          ? const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisExtent: 116,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            )
          : const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              mainAxisExtent: 150,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
      itemCount: 12,
      itemBuilder: (_, _) =>
          const SkeletonBox(height: double.infinity, borderRadius: 14),
    );
  }
}

class _CategoriesGrid extends ConsumerWidget {
  final Function(String) onCategoryTap;
  const _CategoriesGrid({required this.onCategoryTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(menuBrowserVmProvider);
    final categories = state.categories;

    if (categories.isEmpty && state.loading) {
      return const _CatalogGridSkeleton();
    }
    if (categories.isEmpty) {
      return const Center(
        child: Text(
          'No hay categorías activas',
          style: TextStyle(color: _salesTextSecondary),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final zoom = ref.watch(salesZoomProvider);
        final isCompact = ResponsiveHelper.isMobile(context);
        final categoryCardExtent = (190 + ((textScale - 1) * 24)).clamp(
          190,
          214,
        );
        // En móvil, forzamos 3 columnas con ancho calculado a partir del
        // viewport disponible. En desktop conservamos el comportamiento de
        // maxCrossAxisExtent.
        final mobileColumns = 3;
        final mobileSpacing = 8.0;
        final mobilePadding = 12.0;
        final mobileCardWidth =
            (constraints.maxWidth -
                (mobilePadding * 2) -
                (mobileSpacing * (mobileColumns - 1))) /
            mobileColumns;
        return Stack(
          children: [
            GridView.builder(
              padding: EdgeInsets.all(isCompact ? mobilePadding : 16),
              gridDelegate: isCompact
                  ? SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: mobileColumns,
                      mainAxisExtent: (mobileCardWidth * 0.95).clamp(96, 130),
                      crossAxisSpacing: mobileSpacing,
                      mainAxisSpacing: mobileSpacing,
                    )
                  : SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 220 * zoom,
                      mainAxisExtent: categoryCardExtent.toDouble() * zoom,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
              itemCount: categories.length,
              itemBuilder: (context, index) {
                final cat = categories[index];
                return InkWell(
                  onTap: () => onCategoryTap(cat.id),
                  borderRadius: BorderRadius.circular(_salesRadiusCard),
                  child: Container(
                    width: isCompact ? double.infinity : null,
                    height: isCompact ? double.infinity : null,
                    constraints: isCompact
                        ? const BoxConstraints()
                        : const BoxConstraints(minHeight: 140, minWidth: 160),
                    decoration: BoxDecoration(
                      color: _salesSurface,
                      borderRadius: BorderRadius.circular(_salesRadiusCard),
                      border: Border.all(
                        color: _parseHexColor(cat.color),
                        width: cat.color != null ? 2.5 : 1,
                      ),
                      boxShadow: _salesSoftShadow,
                    ),
                    padding: EdgeInsets.symmetric(
                      horizontal: isCompact ? 6 : 16,
                      vertical: isCompact ? 8 : 14,
                    ),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            cat.name,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: isCompact ? 12 : 16,
                              color: _salesTextPrimary,
                              height: 1.15,
                            ),
                          ),
                          if (!isCompact) ...[
                            const SizedBox(height: 6),
                            const Text(
                              'Ver items',
                              style: TextStyle(
                                fontSize: 13,
                                color: _salesTextSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            if (state.loading)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(
                  minHeight: 2,
                  color: _salesTotalColor,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _SelectedCatalogCategoryHeader extends StatelessWidget {
  final String categoryName;
  final VoidCallback onBack;

  const _SelectedCatalogCategoryHeader({
    required this.categoryName,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final isCompact = ResponsiveHelper.isMobile(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        isCompact ? 12 : 16,
        isCompact ? 10 : 14,
        isCompact ? 12 : 16,
        isCompact ? 10 : 14,
      ),
      decoration: BoxDecoration(
        color: _salesSurface,
        border: Border(
          top: BorderSide(
            color: _salesTotalColor.withValues(alpha: 0.18),
            width: 1.5,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              InkWell(
                onTap: onBack,
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  width: isCompact ? 34 : 42,
                  height: isCompact ? 34 : 42,
                  decoration: BoxDecoration(
                    color: _salesTotalColor.withValues(alpha: 0.10),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: _salesTotalColor,
                    size: isCompact ? 16 : 20,
                  ),
                ),
              ),
              SizedBox(width: isCompact ? 10 : 14),
              Expanded(
                child: Text(
                  categoryName.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: isCompact ? 17 : 28,
                    fontWeight: FontWeight.w800,
                    color: _salesTotalColor,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: isCompact ? 6 : 10),
          InkWell(
            onTap: onBack,
            borderRadius: BorderRadius.circular(10),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.home_rounded,
                    size: 18,
                    color: _salesTextSecondary,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Todas las categorías',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: _salesTextSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProductsGrid extends ConsumerWidget {
  final Function(dynamic) onProductTap;
  final String emptyText;
  const _ProductsGrid({
    required this.onProductTap,
    this.emptyText = 'Selecciona una categoria o busca productos',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(menuBrowserVmProvider);
    final products = state.products;

    if (products.isEmpty && state.loading) {
      return const _CatalogGridSkeleton();
    }
    if (products.isEmpty) {
      return Center(child: Text(emptyText));
    }

    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final zoom = ref.watch(salesZoomProvider);
    final productCardExtent = (206 + ((textScale - 1) * 32)).clamp(206, 238);
    final isCompact = ResponsiveHelper.isMobile(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        // En móvil: 3 columnas, ancho calculado a partir del viewport.
        const mobileColumns = 3;
        const mobileSpacing = 8.0;
        const mobilePadding = 12.0;
        final mobileCardWidth =
            (constraints.maxWidth -
                (mobilePadding * 2) -
                (mobileSpacing * (mobileColumns - 1))) /
            mobileColumns;
        final mobileCardHeight = mobileCardWidth + 50;

        return Stack(
          children: [
            GridView.builder(
              padding: EdgeInsets.all(isCompact ? mobilePadding : 16),
              gridDelegate: isCompact
                  ? SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: mobileColumns,
                      crossAxisSpacing: mobileSpacing,
                      mainAxisSpacing: mobileSpacing,
                      mainAxisExtent: mobileCardHeight,
                    )
                  : SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 220 * zoom,
                      mainAxisExtent: productCardExtent.toDouble() * zoom,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
              itemCount: products.length,
              itemBuilder: (context, index) {
                final product = products[index];
                final stockUnits = state.stockByProductId[product.id];
                // Bloqueo cliente: si el producto tracked está agotado y
                // NO permite venta en negativo, mostramos snackbar y no
                // dejamos agregar. Es la capa de seguridad cuando el
                // catálogo no se ha refrescado vía realtime.
                final blockedByStock =
                    product.isInventoryTracked &&
                    !product.allowNegativeSale &&
                    stockUnits != null &&
                    stockUnits <= 0;
                return GestureDetector(
                  onTap: blockedByStock
                      ? () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                '${product.name} está agotado. '
                                'Recibe stock o activa "Vender aunque '
                                'esté agotado" en el producto.',
                              ),
                              backgroundColor: const Color(0xFFB91C1C),
                              duration: const Duration(seconds: 3),
                            ),
                          );
                        }
                      : () => onProductTap(product),
                  child: Container(
                    width: isCompact ? double.infinity : null,
                    height: isCompact ? double.infinity : null,
                    constraints: isCompact
                        ? const BoxConstraints()
                        : BoxConstraints(
                            minHeight: 140 * zoom,
                            minWidth: 160 * zoom,
                            maxWidth: 220 * zoom,
                          ),
                    decoration: BoxDecoration(
                      color: _salesSurface,
                      borderRadius: BorderRadius.circular(_salesRadiusCard),
                      border: Border.all(color: _salesDivider),
                      boxShadow: _salesSoftShadow,
                    ),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: isCompact ? 6 : 16,
                              vertical: isCompact ? 8 : 14,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                _ProductAvatar(
                                  imageUrl: product.imageUrl,
                                  zoom: isCompact ? 0.7 : zoom,
                                ),
                                SizedBox(height: isCompact ? 6 : 10),
                                Text(
                                  product.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: isCompact ? 11 : 14,
                                    color: _salesTextPrimary,
                                    height: 1.15,
                                  ),
                                ),
                                SizedBox(height: isCompact ? 2 : 6),
                                Text(
                                  'RD\$ ${product.price.toStringAsFixed(0)}',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: _salesTotalColor,
                                    fontWeight: FontWeight.w700,
                                    fontSize: isCompact ? 11 : 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (stockUnits != null)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: _StockBadge(units: stockUnits),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
            if (state.loading)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(
                  minHeight: 2,
                  color: _salesTotalColor,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Pill compacta arriba a la derecha de la card de producto. Muestra "N"
/// con color según el nivel de stock. Solo aparece cuando el producto es
/// tracked y tiene receta resoluble (la vista `v_menu_items_stock`
/// devuelve un valor). Productos auto-86'd no aparecen en el catálogo
/// porque ya están filtrados por `is_active = true`.
class _StockBadge extends StatelessWidget {
  final num units;
  const _StockBadge({required this.units});

  @override
  Widget build(BuildContext context) {
    final n = units.toDouble();
    // Permitimos ventas con stock <= 0 (deuda de inventario). El badge
    // rojo "Agotado" señala al cajero que el conteo está en cero o
    // negativo; la próxima recepción de compra saldará la deuda.
    final Color bg;
    final Color fg;
    if (n <= 0) {
      bg = const Color(0xFFFEE2E2);
      fg = const Color(0xFFB91C1C);
    } else if (n <= 5) {
      bg = const Color(0xFFFFEDD5);
      fg = const Color(0xFFC2410C);
    } else if (n <= 20) {
      bg = const Color(0xFFFEF3C7);
      fg = const Color(0xFF92400E);
    } else {
      bg = const Color(0xFFDCFCE7);
      fg = const Color(0xFF15803D);
    }
    final String label;
    if (n <= 0) {
      label = 'Agotado';
    } else if (n == n.truncateToDouble()) {
      label = n.toInt().toString();
    } else {
      label = n.toStringAsFixed(1);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: fg.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inventory_2_outlined, size: 12, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProductAvatar extends StatelessWidget {
  final String? imageUrl;

  /// Factor de zoom que se aplica al avatar (default 1.0 = 96px).
  /// Se propaga desde el grid del catalogo via `salesZoomProvider`.
  final double zoom;

  const _ProductAvatar({this.imageUrl, this.zoom = 1.0});

  @override
  Widget build(BuildContext context) {
    final size = 96 * zoom;
    final hasUrl = imageUrl != null && imageUrl!.trim().isNotEmpty;
    final resolvedUrl = hasUrl
        ? imageUrl!.replaceAll(
            'sqdwjjewdqzxglvqerqt.supabase.co',
            'supabase.mangopos.do',
          )
        : null;

    // Fallback siempre listo: ícono centrado en círculo gris. Se usa cuando
    // no hay URL, cuando la imagen está cargando, o cuando falla la carga.
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: _salesTabActiveBg,
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.restaurant_rounded,
        color: _salesTextHint,
        size: 32 * zoom,
      ),
    );

    if (!hasUrl) return fallback;

    // Imagen real recortada en círculo. ClipOval + CachedNetworkImage da
    // placeholder y errorWidget garantizados — nunca queda círculo vacío.
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: CachedNetworkImage(
          imageUrl: resolvedUrl!,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          placeholder: (_, _) => fallback,
          errorWidget: (_, _, _) => fallback,
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 4. DIALOGO DE SELECCIÓN DE MESAS (MANUAL SALE)
// -----------------------------------------------------------------------------
class _SelectTableDialog extends ConsumerStatefulWidget {
  const _SelectTableDialog();

  @override
  ConsumerState<_SelectTableDialog> createState() => _SelectTableDialogState();
}

class _SelectTableDialogState extends ConsumerState<_SelectTableDialog> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final session = ref.read(sessionProvider);
      ref.read(byZoneVmProvider.notifier).load(session.activeBusinessId ?? '');
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(byZoneVmProvider);

    if (state.loading && state.zones.isEmpty) {
      return const Dialog(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Cargando mesas...'),
            ],
          ),
        ),
      );
    }

    // Aplanar mesas disponibles
    final availableTables = <TableStatus>[];
    for (final zone in state.zones) {
      final tablesInZone = state.statusByZone[zone.id] ?? [];
      for (final t in tablesInZone) {
        if (t.sessionId == null) {
          availableTables.add(t);
        }
      }
    }

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 600,
        height: 500,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Asignar a Mesa',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: availableTables.isEmpty
                  ? const Center(child: Text('No hay mesas disponibles'))
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 180,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 1.1,
                          ),
                      itemCount: availableTables.length,
                      itemBuilder: (context, index) {
                        final t = availableTables[index];
                        return InkWell(
                          onTap: () {
                            Navigator.pop(context, t);
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: _salesDivider),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.table_bar,
                                  color: _salesTextSecondary,
                                  size: 36,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  t.code,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                    color: _salesTextPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComboSelectionDialog extends StatefulWidget {
  final MenuProduct product;
  final List<Map<String, dynamic>> groups;

  const _ComboSelectionDialog({required this.product, required this.groups});

  @override
  State<_ComboSelectionDialog> createState() => _ComboSelectionDialogState();
}

class _ComboSelectionDialogState extends State<_ComboSelectionDialog> {
  final Map<String, String> _selectedByGroup = <String, String>{};

  @override
  void initState() {
    super.initState();
    for (final group in widget.groups) {
      final items = ((group['combo_group_items'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
      final defaultItem = items.cast<Map<String, dynamic>?>().firstWhere(
        (item) => item?['is_default'] == true,
        orElse: () => items.isEmpty ? null : items.first,
      );
      if (defaultItem != null) {
        final menuItemId = defaultItem['menu_item_id']?.toString();
        if (menuItemId != null && menuItemId.isNotEmpty) {
          _selectedByGroup[group['id']?.toString() ?? ''] = menuItemId;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Armar combo · ${widget.product.name}'),
      content: SizedBox(
        width: 700,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: widget.groups
                .map((group) {
                  final groupId = group['id']?.toString() ?? '';
                  final items =
                      ((group['combo_group_items'] as List?) ?? const [])
                          .map((e) => Map<String, dynamic>.from(e as Map))
                          .toList(growable: false)
                        ..sort(
                          (a, b) => ((a['sort_order'] as num?)?.toInt() ?? 0)
                              .compareTo(
                                (b['sort_order'] as num?)?.toInt() ?? 0,
                              ),
                        );
                  return Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group['name']?.toString() ?? 'Grupo',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 10),
                        ...items.map((item) {
                          final product = Map<String, dynamic>.from(
                            (item['menu_items'] as Map?) ?? const {},
                          );
                          final menuItemId =
                              item['menu_item_id']?.toString() ?? '';
                          final priceDelta =
                              (item['price_delta'] as num?)?.toDouble() ?? 0.0;
                          return RadioListTile<String>(
                            value: menuItemId,
                            groupValue: _selectedByGroup[groupId],
                            title: Text(
                              product['name']?.toString() ?? 'Opción',
                            ),
                            subtitle: priceDelta > 0
                                ? Text(
                                    'Extra RD\$ ${priceDelta.toStringAsFixed(2)}',
                                  )
                                : null,
                            onChanged: (value) {
                              if (value == null) return;
                              setState(() => _selectedByGroup[groupId] = value);
                            },
                          );
                        }),
                      ],
                    ),
                  );
                })
                .toList(growable: false),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            final result = <SelectedModifierInput>[];
            for (final group in widget.groups) {
              final groupId = group['id']?.toString() ?? '';
              final selectedId = _selectedByGroup[groupId];
              if (selectedId == null || selectedId.isEmpty) continue;
              final items = ((group['combo_group_items'] as List?) ?? const [])
                  .map((e) => Map<String, dynamic>.from(e as Map));
              Map<String, dynamic>? selected;
              for (final item in items) {
                if (item['menu_item_id']?.toString() == selectedId) {
                  selected = item;
                  break;
                }
              }
              if (selected == null) continue;
              final product = Map<String, dynamic>.from(
                (selected['menu_items'] as Map?) ?? const {},
              );
              final groupName = group['name']?.toString() ?? 'Grupo';
              result.add(
                SelectedModifierInput(
                  name: '$groupName: ${product['name'] ?? 'Opción'}',
                  qty: 1,
                  price: (selected['price_delta'] as num?)?.toDouble() ?? 0.0,
                  // Identidad del componente para el descuento de inventario.
                  menuItemId: selectedId,
                ),
              );
            }
            Navigator.of(context).pop(result);
          },
          child: const Text('Agregar combo'),
        ),
      ],
    );
  }
}

class _ModifiersSelectionDialog extends StatefulWidget {
  final MenuProduct product;
  final List<Map<String, dynamic>> groups;

  const _ModifiersSelectionDialog({
    required this.product,
    required this.groups,
  });

  @override
  State<_ModifiersSelectionDialog> createState() =>
      _ModifiersSelectionDialogState();
}

class _ModifiersSelectionDialogState extends State<_ModifiersSelectionDialog> {
  final Map<String, Set<String>> _selectedByGroup = <String, Set<String>>{};

  @override
  void initState() {
    super.initState();
    for (final row in widget.groups) {
      final group = Map<String, dynamic>.from(row['modifier_groups'] as Map);
      final groupId = group['id']?.toString() ?? '';
      final modifiers = ((group['modifiers'] as List?) ?? const [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .where((item) => item['is_active'] != false)
          .toList(growable: false);
      final defaults = modifiers
          .where((item) => item['default_selected'] == true)
          .map((item) => item['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      _selectedByGroup[groupId] = defaults;
    }
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );

    return Dialog(
      backgroundColor: _salesSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SalesModifierDialogHeader(
                title: widget.product.name,
                subtitle:
                    'Personaliza el producto antes de agregarlo a la orden.',
              ),
              const SizedBox(height: 18),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ...widget.groups.map((row) {
                        final group = Map<String, dynamic>.from(
                          row['modifier_groups'] as Map,
                        );
                        final groupId = group['id']?.toString() ?? '';
                        final groupName = group['name']?.toString() ?? 'Grupo';
                        final displayType =
                            group['display_type']?.toString() ?? 'multiple';
                        final minSelect =
                            (group['min_select'] as num?)?.toInt() ?? 0;
                        final maxSelect =
                            (group['max_select'] as num?)?.toInt() ?? 0;
                        final selected =
                            _selectedByGroup[groupId] ?? <String>{};
                        final modifiers =
                            ((group['modifiers'] as List?) ?? const [])
                                .map(
                                  (item) =>
                                      Map<String, dynamic>.from(item as Map),
                                )
                                .where((item) => item['is_active'] != false)
                                .toList(growable: false)
                              ..sort(
                                (a, b) =>
                                    ((a['sort_order'] as num?)?.toInt() ?? 0)
                                        .compareTo(
                                          (b['sort_order'] as num?)?.toInt() ??
                                              0,
                                        ),
                              );

                        return Container(
                          margin: const EdgeInsets.only(bottom: 14),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: _salesSurface,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: _salesDivider),
                            boxShadow: _salesSoftShadow,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      groupName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 15,
                                        color: _salesTextPrimary,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF3F0ED),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      displayType == 'single'
                                          ? '1 opción'
                                          : 'Múltiple',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: _salesTextSecondary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _groupHint(
                                  displayType: displayType,
                                  minSelect: minSelect,
                                  maxSelect: maxSelect,
                                ),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: _salesTextSecondary,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: modifiers
                                    .map((modifier) {
                                      final modifierId =
                                          modifier['id']?.toString() ?? '';
                                      final price =
                                          (modifier['price_delta'] as num?)
                                              ?.toDouble() ??
                                          0.0;
                                      final isSelected = selected.contains(
                                        modifierId,
                                      );
                                      return FilterChip(
                                        selected: isSelected,
                                        showCheckmark: false,
                                        selectedColor: const Color(0xFFFFEDD5),
                                        backgroundColor: const Color(
                                          0xFFF8FAFC,
                                        ),
                                        side: BorderSide(
                                          color: isSelected
                                              ? _salesTotalColor
                                              : _salesDivider,
                                          width: isSelected ? 1.5 : 1,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 10,
                                        ),
                                        labelStyle: TextStyle(
                                          color: isSelected
                                              ? const Color(0xFF9A3412)
                                              : _salesTextPrimary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        avatar: Icon(
                                          isSelected
                                              ? Icons.check_circle_rounded
                                              : Icons
                                                    .add_circle_outline_rounded,
                                          size: 18,
                                          color: isSelected
                                              ? _salesTotalColor
                                              : _salesTextHint,
                                        ),
                                        label: Text(
                                          price > 0
                                              ? '${modifier['name']} (+${currency.format(price)})'
                                              : '${modifier['name']}',
                                        ),
                                        onSelected: (_) => _toggleModifier(
                                          groupId: groupId,
                                          modifierId: modifierId,
                                          displayType: displayType,
                                          maxSelect: maxSelect,
                                        ),
                                      );
                                    })
                                    .toList(growable: false),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: _submit,
                    icon: const Icon(
                      Icons.add_shopping_cart_outlined,
                      size: 18,
                    ),
                    label: const Text('Agregar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _groupHint({
    required String displayType,
    required int minSelect,
    required int maxSelect,
  }) {
    if (displayType == 'single') {
      return minSelect > 0 ? 'Selecciona 1 opción' : 'Selecciona una opción';
    }
    if (maxSelect > 0) {
      return minSelect > 0
          ? 'Selecciona entre $minSelect y $maxSelect opciones'
          : 'Máximo $maxSelect opciones';
    }
    return minSelect > 0
        ? 'Selecciona al menos $minSelect opciones'
        : 'Opcional';
  }

  void _toggleModifier({
    required String groupId,
    required String modifierId,
    required String displayType,
    required int maxSelect,
  }) {
    setState(() {
      final selected = _selectedByGroup.putIfAbsent(groupId, () => <String>{});
      if (displayType == 'single') {
        if (selected.contains(modifierId)) {
          selected.clear();
        } else {
          selected
            ..clear()
            ..add(modifierId);
        }
        return;
      }

      if (selected.contains(modifierId)) {
        selected.remove(modifierId);
        return;
      }

      if (maxSelect > 0 && selected.length >= maxSelect) {
        return;
      }
      selected.add(modifierId);
    });
  }

  void _submit() {
    final result = <SelectedModifierInput>[];

    for (final row in widget.groups) {
      final group = Map<String, dynamic>.from(row['modifier_groups'] as Map);
      final groupId = group['id']?.toString() ?? '';
      final minSelect = (group['min_select'] as num?)?.toInt() ?? 0;
      final selected = _selectedByGroup[groupId] ?? <String>{};
      if (selected.length < minSelect) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Debes completar: ${group['name']}')),
        );
        return;
      }
      final modifiers = ((group['modifiers'] as List?) ?? const [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .where((item) => selected.contains(item['id']?.toString() ?? ''));
      for (final modifier in modifiers) {
        result.add(
          SelectedModifierInput(
            name: modifier['name']?.toString() ?? 'Modificador',
            qty: 1,
            price: (modifier['price_delta'] as num?)?.toDouble() ?? 0.0,
          ),
        );
      }
    }

    Navigator.of(context).pop(result);
  }
}

enum _DiscountScope { table, products }

class _SalesModifierDialogHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SalesModifierDialogHeader({
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: _salesTotalColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(Icons.tune_rounded, color: _salesTotalColor),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                  color: _salesTextPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 13,
                  color: _salesTextSecondary,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DiscountDialogResult {
  final _DiscountScope scope;
  final double percent;
  final List<String> selectedItemIds;

  const _DiscountDialogResult({
    required this.scope,
    required this.percent,
    required this.selectedItemIds,
  });
}

class _DiscountDialog extends StatefulWidget {
  final List<OrderItem> items;
  final Order? order;

  const _DiscountDialog({required this.items, this.order});

  @override
  State<_DiscountDialog> createState() => _DiscountDialogState();
}

class _DiscountDialogState extends State<_DiscountDialog> {
  _DiscountScope _scope = _DiscountScope.table;
  final TextEditingController _percentController = TextEditingController(
    text: '10',
  );
  final Set<String> _selectedItemIds = <String>{};
  String? _error;

  @override
  void dispose() {
    _percentController.dispose();
    super.dispose();
  }

  String _formatQty(double qty) {
    if ((qty - qty.roundToDouble()).abs() < 0.001) {
      return qty.toStringAsFixed(0);
    }
    return qty.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _salesSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 560,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Aplicar descuento',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 14),
              SegmentedButton<_DiscountScope>(
                segments: const [
                  ButtonSegment<_DiscountScope>(
                    value: _DiscountScope.table,
                    label: Text('Toda la mesa'),
                  ),
                  ButtonSegment<_DiscountScope>(
                    value: _DiscountScope.products,
                    label: Text('Productos'),
                  ),
                ],
                selected: <_DiscountScope>{_scope},
                onSelectionChanged: (selection) {
                  if (selection.isEmpty) return;
                  setState(() {
                    _scope = selection.first;
                    _error = null;
                  });
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _percentController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Porcentaje (%)',
                  hintText: 'Ejemplo: 10',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              if (_scope == _DiscountScope.products) ...[
                const SizedBox(height: 12),
                Container(
                  constraints: const BoxConstraints(maxHeight: 220),
                  decoration: BoxDecoration(
                    border: Border.all(color: _salesDivider),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: widget.items.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = widget.items[index];
                      final checked = _selectedItemIds.contains(item.id);
                      return CheckboxListTile(
                        value: checked,
                        title: Text(item.productName),
                        subtitle: Text(
                          'Cant: ${_formatQty(item.quantity)} • RD\$${_effectiveItemTotal(widget.order, item).toStringAsFixed(2)}',
                        ),
                        onChanged: (_) {
                          setState(() {
                            if (checked) {
                              _selectedItemIds.remove(item.id);
                            } else {
                              _selectedItemIds.add(item.id);
                            }
                            _error = null;
                          });
                        },
                      );
                    },
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(
                    color: Colors.red,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: _salesTotalColor,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      final percent = double.tryParse(
                        _percentController.text.trim().replaceAll(',', '.'),
                      );
                      if (percent == null || percent <= 0 || percent > 100) {
                        setState(() {
                          _error = 'Ingresa un porcentaje válido (0.01 - 100).';
                        });
                        return;
                      }

                      if (_scope == _DiscountScope.products &&
                          _selectedItemIds.isEmpty) {
                        setState(() {
                          _error = 'Selecciona al menos un producto.';
                        });
                        return;
                      }

                      Navigator.pop(
                        context,
                        _DiscountDialogResult(
                          scope: _scope,
                          percent: percent,
                          selectedItemIds: _selectedItemIds.toList(
                            growable: false,
                          ),
                        ),
                      );
                    },
                    child: const Text('Aplicar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CourtesyDialogResult {
  final List<String> selectedItemIds;
  final String reason;

  const _CourtesyDialogResult({
    required this.selectedItemIds,
    required this.reason,
  });
}

class _CourtesyDialog extends StatefulWidget {
  final List<OrderItem> items;
  final Order? order;

  const _CourtesyDialog({required this.items, this.order});

  @override
  State<_CourtesyDialog> createState() => _CourtesyDialogState();
}

class _CourtesyDialogState extends State<_CourtesyDialog> {
  final Set<String> _selectedItemIds = <String>{};
  final TextEditingController _reasonController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  String _formatQty(double qty) {
    if ((qty - qty.roundToDouble()).abs() < 0.001) {
      return qty.toStringAsFixed(0);
    }
    return qty.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _salesSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 620,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Cortesía por producto',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: _salesTextPrimary,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Selecciona productos y opcionalmente agrega el motivo.',
                style: TextStyle(fontSize: 13, color: _salesTextSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _reasonController,
                maxLength: 120,
                decoration: InputDecoration(
                  labelText: 'Motivo de cortesía (opcional)',
                  hintText: 'Ejemplo: atención de la casa',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 300),
                decoration: BoxDecoration(
                  border: Border.all(color: _salesDivider),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: widget.items.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = widget.items[index];
                    final checked = _selectedItemIds.contains(item.id);
                    return CheckboxListTile(
                      value: checked,
                      title: Text(item.productName),
                      subtitle: Text(
                        'Cant: ${_formatQty(item.quantity)} • RD\$${_effectiveItemTotal(widget.order, item).toStringAsFixed(2)}',
                      ),
                      onChanged: (_) {
                        setState(() {
                          if (checked) {
                            _selectedItemIds.remove(item.id);
                          } else {
                            _selectedItemIds.add(item.id);
                          }
                          _error = null;
                        });
                      },
                    );
                  },
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(
                    color: Colors.red,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: _salesTotalColor,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      if (_selectedItemIds.isEmpty) {
                        setState(() {
                          _error = 'Selecciona al menos un producto.';
                        });
                        return;
                      }
                      Navigator.pop(
                        context,
                        _CourtesyDialogResult(
                          selectedItemIds: _selectedItemIds.toList(
                            growable: false,
                          ),
                          reason: _reasonController.text.trim(),
                        ),
                      );
                    },
                    child: const Text('Aplicar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
