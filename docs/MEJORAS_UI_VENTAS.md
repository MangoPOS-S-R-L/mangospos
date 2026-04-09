# Mejoras UI - Flujo de Ventas MangoPOS

Fecha: 2026-04-09
Alcance: Modulos de ventas, cashier, pagos, split bill, tickets/billing, KDS

---

## RESUMEN EJECUTIVO

Se identificaron **23 mejoras** agrupadas en 4 categorias:
- **CRITICO** (6): Bugs visibles que el usuario percibe como flicker/parpadeo
- **ALTO** (8): Problemas de rendimiento que degradan la experiencia
- **MEDIO** (5): Oportunidades de mejora de UX
- **BAJO** (4): Optimizaciones de arquitectura a futuro

---

## 1. PROBLEMAS CRITICOS - Flicker y Rebuilds Innecesarios

### 1.1 CashierViewModel usa ChangeNotifier (rebuild total cada 30s)

**Archivo:** `lib/presentation/cashier/viewmodel/cashier_viewmodel.dart:20-29`
**Problema:** `CashierViewModel extends ChangeNotifier` con 18 propiedades mutables. Cada `notifyListeners()` reconstruye TODOS los widgets que observan el provider. Durante `init()` se llama `notifyListeners()` al menos 5 veces secuencialmente (lineas 72-150), causando 5 rebuilds completos del dashboard.
**Ademas:** El timer de 30s en `cashier_view.dart:39` ejecuta `init()` cada 30 segundos, repitiendo este ciclo.

**Mejora propuesta:**
```dart
// ANTES (ChangeNotifier - rebuild total)
final cashierViewModelProvider = ChangeNotifierProvider<CashierViewModel>((ref) {
  return CashierViewModel(...);
});

// DESPUES (StateNotifier con estado inmutable - rebuild granular)
final cashierViewModelProvider = StateNotifierProvider<CashierViewModel, CashierState>((ref) {
  return CashierViewModel(...);
});

class CashierState {
  final bool isLoading;
  final Map<String, dynamic>? lastSession;
  final Map<String, dynamic> todaySummary;
  final List<Map<String, dynamic>> recentMovements;
  final List<TableSession> activeSessions;
  final List<double> weeklySales;
  // ... demas campos
  
  const CashierState({...});
  CashierState copyWith({...});
}

// En init(), acumular todo y emitir UN solo state al final:
Future<void> init() async {
  state = state.copyWith(isLoading: true);
  final summary = await _loadTodaySummary();
  final movements = await _loadRecentMovements();
  final sessions = await _loadActiveSessions();
  final weekly = await _loadWeeklySales();
  state = state.copyWith(
    isLoading: false,
    todaySummary: summary,
    recentMovements: movements,
    activeSessions: sessions,
    weeklySales: weekly,
  );
}
```

**Impacto:** Reduce de 5+ rebuilds a 2 (loading=true, loading=false) por ciclo de refresh.

---

### 1.2 Auto-refresh de 30s sin verificar visibilidad

**Archivo:** `lib/presentation/cashier/view/cashier_view.dart:38-43`
**Problema:** El Timer.periodic corre incluso cuando el usuario esta en otra pantalla (ventas, productos, etc). Cada 30s ejecuta `init()` completo.

**Mejora propuesta:**
```dart
// Agregar WidgetsBindingObserver y RouteAware
class _CashierViewState extends ConsumerState<CashierView>
    with WidgetsBindingObserver {
  
  bool _isVisible = true;
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isVisible = state == AppLifecycleState.resumed;
  }
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _isVisible) {
        ref.read(cashierViewModelProvider).refreshSilent(); // Sin isLoading=true
      }
    });
  }
}
```

**Ademas:** Crear un metodo `refreshSilent()` que NO setee `isLoading = true` para evitar que el spinner aparezca cada 30s. Solo el refresh inicial o manual debe mostrar spinner.

---

### 1.3 SalesByZoneView: Timer de 12s + setState() + watch completo

**Archivo:** `lib/presentation/sales/view/sales_by_zone_view.dart:33,59-63,113,122-123`
**Problema Triple:**
1. Auto-refresh cada 12 segundos (linea 33) - muy agresivo
2. `setState(() {})` en el listener del TabController (linea 113)
3. `ref.watch(byZoneVmProvider)` observa TODO el estado (linea 122)
4. `ref.watch(cashierViewModelProvider)` observa TODO el cashier (linea 123)

Resultado: La vista de zonas/mesas se reconstruye completamente cada 12s. Si el usuario esta navegando tabs, el parpadeo es visible.

**Mejora propuesta:**
```dart
// 1. Aumentar intervalo y usar refresh silencioso
static const Duration _refreshInterval = Duration(seconds: 30);

// 2. Usar .select() para observar solo lo necesario
final zones = ref.watch(byZoneVmProvider.select((s) => s.zones));
final isLoading = ref.watch(byZoneVmProvider.select((s) => s.loading));
final isCashOpen = ref.watch(
  cashierViewModelProvider.select((vm) => vm.isCashOpen),
);

// 3. Eliminar setState en tab listener - usar ValueNotifier local
final _selectedTabIndex = ValueNotifier<int>(0);
// En lugar de setState(() {}) usar ValueListenableBuilder
```

---

### 1.4 CurrentOrderState monolitico sin .select()

**Archivo:** `lib/presentation/sales/state/sales_state.dart` (21 propiedades)
**Observadores:** `quick_sale_view.dart`, `table_order_screen.dart`, `sales_sidebar.dart`, etc.
**Problema:** `ref.watch(currentOrderProvider)` observa las 21 propiedades. Cualquier cambio (ej: syncStatus, fiscalSequences) reconstruye la UI de items del pedido.

**Mejora propuesta:**
```dart
// ANTES - reconstruye todo al cambiar CUALQUIER campo
final s = ref.watch(currentOrderProvider);

// DESPUES - reconstruye solo cuando cambian items
final items = ref.watch(currentOrderProvider.select((s) => s.items));
final order = ref.watch(currentOrderProvider.select((s) => s.order));
final loading = ref.watch(currentOrderProvider.select((s) => s.loading));

// Para sidebar offline indicator - solo lo que necesita
final isOffline = ref.watch(currentOrderProvider.select((s) => s.isOfflineMode));
final pendingActions = ref.watch(currentOrderProvider.select((s) => s.pendingOfflineActions));
```

**Archivos a modificar:**
- `lib/presentation/sales/view/quick_sale_view.dart`
- `lib/presentation/sales/view/table_order_screen.dart`
- `lib/presentation/sales/widgets/sales_sidebar.dart`
- `lib/presentation/sales/widgets/catalog_column.dart`
- `lib/presentation/sales/view/sale_manual_view.dart`

---

### 1.5 Realtime sin debounce en SalesByZoneViewModel

**Archivo:** `lib/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart:129-260`
**Problema:** 5 listeners de Supabase realtime (table_sessions, orders, order_items, order_checks, payments). Si llegan cambios rapidos (ej: cocina marcando items), cada evento dispara un reload completo de todas las zonas incluso con debounce de 450ms. En horas pico, multiples eventos pueden acumularse.

**Mejora propuesta:**
```dart
// 1. Consolidar a un solo listener con filtro por tabla
// 2. Agregar coalescing - si ya hay un refresh pendiente, no encolar otro
// 3. Usar diff de estado - solo actualizar mesas que cambiaron
void _onRealtimeEvent(PostgresChangePayload payload) {
  final tableId = payload.newRecord?['table_id'];
  if (tableId != null) {
    _pendingTableUpdates.add(tableId);
  }
  _debouncedRefresh(); // Solo refresca las mesas en _pendingTableUpdates
}
```

---

### 1.6 Falta de optimistic updates al agregar/quitar items

**Archivo:** `lib/presentation/sales/viewmodel/sales_viewmodel.dart` (metodos addItem, deleteItem, updateQuantity)
**Problema:** Cuando el usuario agrega un item, el flujo es:
1. Llamada RPC al servidor
2. Espera respuesta
3. Refresca orden completa
4. UI se actualiza

Durante el paso 1-3 la UI queda "congelada" o el usuario no ve feedback inmediato.

**Mejora propuesta:**
```dart
Future<void> addItem(String menuItemId, {double qty = 1}) async {
  // 1. Optimistic: agregar item localmente de inmediato
  final tempItem = OrderItem(
    id: 'temp-${DateTime.now().millisecondsSinceEpoch}',
    menuItemId: menuItemId,
    name: itemName, // del catalogo local
    quantity: qty,
    unitPrice: itemPrice,
    isPending: true, // flag visual para mostrar como "guardando..."
  );
  state = state.copyWith(items: [...state.items, tempItem]);
  
  // 2. Llamada al servidor en background
  try {
    final realId = await _repo.addItemFromMenu(orderId, menuItemId, qty, ...);
    // 3. Reemplazar temp con item real
    final updated = state.items.map((i) => 
      i.id == tempItem.id ? i.copyWith(id: realId, isPending: false) : i
    ).toList();
    state = state.copyWith(items: updated);
  } catch (e) {
    // 4. Rollback: quitar item temporal y mostrar error
    state = state.copyWith(
      items: state.items.where((i) => i.id != tempItem.id).toList(),
      error: 'No se pudo agregar el item',
    );
  }
}
```

**Impacto:** El usuario ve el item aparecer inmediatamente. Si falla, se revierte con mensaje.

---

## 2. PROBLEMAS DE PRIORIDAD ALTA

### 2.1 CashierViewModel: init() secuencial en vez de paralelo

**Archivo:** `lib/presentation/cashier/viewmodel/cashier_viewmodel.dart:71-150`
**Problema:** Las 4 cargas de datos son secuenciales:
```dart
await _loadTodaySummary();      // ~200ms
await _loadRecentMovements();   // ~200ms
await _loadActiveSessions();    // ~200ms
await _loadWeeklySales();       // ~200ms
// Total: ~800ms de espera
```

**Mejora:**
```dart
final results = await Future.wait([
  _loadTodaySummary(),
  _loadRecentMovements(),
  _loadActiveSessions(),
  _loadWeeklySales(),
]);
// Total: ~200ms (paralelo)
```

---

### 2.2 Payment modal sin indicador de carga durante procesamiento

**Archivo:** `lib/presentation/payments/viewmodel/payment_viewmodel.dart`
**Problema:** Entre que el usuario toca "Pagar" y la respuesta del servidor, no hay feedback visual claro. El boton queda activo (posible doble-tap) y no hay animacion de progreso.

**Mejora propuesta:**
- Deshabilitar boton inmediatamente al tocar
- Mostrar overlay con spinner + "Procesando pago..."
- Agregar estado `processingPayment` al PaymentState
- Feedback haptico al completar (vibration)

---

### 2.3 Offline queue sin indicador visual para el usuario

**Archivo:** `lib/presentation/sales/state/sales_state.dart:19-23`
**Problema:** Existe `pendingOfflineActions` y `syncStatus` en el estado pero NO hay UI que lo muestre al usuario. El usuario puede hacer una venta offline sin saber que esta en cola.

**Mejora propuesta:**
- Agregar banner superior en la vista de ventas cuando `isOfflineMode == true`
- Mostrar badge con `pendingOfflineActions` count
- Chip de "Sincronizando..." cuando `syncInFlight == true`
- Notificacion toast cuando sync completa o falla

---

### 2.4 Errores silenciosos en CashierViewModel

**Archivo:** `lib/presentation/cashier/viewmodel/cashier_viewmodel.dart` (multiples catch blocks)
**Problema:** Los errores se tragan silenciosamente:
```dart
catch (e) {
  _todaySummary = { 'total_income': 0.0, ... }; // Finge que todo esta bien
}
```

**Mejora:** Agregar campo `_error` al estado y mostrarlo como SnackBar o banner de error en la UI. No asumir ceros cuando falla la carga.

---

### 2.5 SalesViewModel de 3000+ lineas

**Archivo:** `lib/presentation/sales/viewmodel/sales_viewmodel.dart`
**Problema:** Archivo monolitico con toda la logica de ventas. Dificil de mantener, testear, y cualquier cambio puede tener efectos secundarios.

**Mejora propuesta:** Extraer mixins o clases delegate:
```
SalesViewModel (orquestador)
  ├── SalesOfflineMixin     → logica offline/sync
  ├── SalesFiscalMixin      → logica fiscal/NCF
  ├── SalesRealtimeMixin    → subscripciones realtime
  ├── SalesItemsMixin       → CRUD de items
  └── SalesPaymentMixin     → procesamiento de pago
```

---

### 2.6 TableCache no sincronizado con UI

**Archivo:** `lib/presentation/sales/viewmodel/sales_viewmodel.dart:49`
**Problema:** `_tableCache` guarda estados por mesa pero el provider `currentOrderProvider` es global. Al cambiar de mesa, se reemplaza TODO el estado causando un flash completo de la UI.

**Mejora propuesta:**
```dart
// Transicion suave al cambiar de mesa:
Future<void> switchToTable(String tableId) async {
  // 1. Guardar estado actual en cache
  _tableCache[currentTableId] = state;
  
  // 2. Si hay cache de la mesa destino, restaurar inmediatamente
  if (_tableCache.containsKey(tableId)) {
    state = _tableCache[tableId]!;
    // 3. Refrescar en background sin loading=true
    _silentRefresh(tableId);
  } else {
    // 4. Solo mostrar loading si no hay cache
    state = state.copyWith(loading: true);
    await _loadTable(tableId);
  }
}
```

---

### 2.7 Tab reset en SalesByZoneView durante refresh

**Archivo:** `lib/presentation/sales/view/sales_by_zone_view.dart:89-118`
**Problema:** `_updateTabController()` puede recrear el TabController si el count de zonas cambia durante un refresh, reseteando la posicion del usuario.

**Mejora:** Verificar que el count realmente cambio antes de recrear. Actualmente compara `_previousZoneCount != currentZoneCount` lo cual es correcto, pero el TabController se recrea aunque el count no cambie si `_tabController == null`. Agregar guard:
```dart
if (_tabController != null && _previousZoneCount == currentZoneCount) return;
```

---

### 2.8 Multiples ref.watch sin scope en table_order_screen

**Archivo:** `lib/presentation/sales/view/table_order_screen.dart`
**Problema:** Multiples `ref.watch(currentOrderProvider)` sin `.select()`, cada propiedad accedida causa rebuild de todo el screen.

**Mejora:** Aplicar `.select()` para cada seccion de la pantalla:
- Header: solo `order.status`, `order.tableNumber`
- Items list: solo `items`
- Totals: solo `items` (para calcular), `checks`
- Offline banner: solo `isOfflineMode`, `pendingOfflineActions`

---

## 3. MEJORAS DE PRIORIDAD MEDIA

### 3.1 Skeleton loading en lugar de CircularProgressIndicator

**Archivos:** Multiples vistas usan `CircularProgressIndicator` centrado
**Problema:** Al cargar datos, el usuario ve una pantalla vacia con spinner. Esto se siente lento y causa "layout shift" cuando los datos aparecen.

**Mejora:** Implementar shimmer/skeleton placeholders:
```dart
// Ejemplo para CashierView
if (isLoading && session == null) {
  return CashierSkeletonView(); // Cards grises animados en la misma posicion
}
```

Archivos sugeridos:
- `cashier_view.dart` - Skeleton para cards de resumen
- `sales_by_zone_view.dart` - Skeleton para grid de mesas
- `sales_history_view.dart` - Skeleton para lista de ventas

---

### 3.2 Pull-to-refresh en vistas de lista

**Archivos:** `cashier_view.dart`, `sales_history_view.dart`, `cash_closures_view.dart`
**Estado actual:** Existe `_handleRefresh` en cashier pero no todas las vistas lo implementan consistentemente.

**Mejora:** Estandarizar `RefreshIndicator` en todas las vistas de lista con callback al refresh del viewmodel.

---

### 3.3 Animaciones de transicion entre estados de mesa

**Archivo:** `lib/presentation/sales/widgets/table_card.dart`
**Problema:** Cuando una mesa cambia de estado (libre→ocupada→pagada), el cambio es instantaneo. En vista de zonas esto causa un "pop" visual.

**Mejora:**
```dart
AnimatedContainer(
  duration: const Duration(milliseconds: 300),
  curve: Curves.easeInOut,
  decoration: BoxDecoration(
    color: _colorForStatus(table.status),
    borderRadius: BorderRadius.circular(12),
  ),
  child: ...
)
```

---

### 3.4 Error auto-dismiss en split bill

**Archivo:** `lib/presentation/split_bill/viewmodel/split_bill_viewmodel.dart`
**Problema:** Los errores persisten hasta que se limpian manualmente con `error: null`.

**Mejora:** Timer de auto-dismiss de 5s para errores no criticos:
```dart
state = state.copyWith(error: 'Mensaje');
Future.delayed(const Duration(seconds: 5), () {
  if (mounted && state.error == 'Mensaje') {
    state = state.copyWith(error: null);
  }
});
```

---

### 3.5 Feedback haptico en acciones clave

**Archivos:** Vistas de ventas, pagos
**Problema:** No hay feedback tactil al completar acciones importantes.

**Mejora:** Agregar `HapticFeedback.mediumImpact()` en:
- Agregar item al pedido
- Completar pago
- Abrir/cerrar caja
- Cambiar de mesa

---

## 4. MEJORAS DE PRIORIDAD BAJA

### 4.1 PaymentViewModel: falta cleanup de connectivity

**Archivo:** `lib/presentation/payments/viewmodel/payment_viewmodel.dart:22`
**Problema:** Es `.autoDispose` pero no implementa `ref.onDispose()` para cancelar la inicializacion de connectivity.

---

### 4.2 Connectivity subscription leak en SalesViewModel.build()

**Archivo:** `lib/presentation/sales/viewmodel/sales_viewmodel.dart:98`
**Problema:** Usa `??=` para lazy init del subscription. Si `build()` se ejecuta multiples veces, la primera subscription persiste pero si se pierde la referencia podria haber leak.

---

### 4.3 KDS timer de 30s deberia pausarse cuando no visible

**Archivo:** `lib/presentation/kds/viewmodel/kds_viewmodel.dart`
**Problema:** Similar al cashier, el periodic refresh corre sin verificar visibilidad.

---

### 4.4 Considerar AsyncNotifier para carga inicial

**Archivos:** Providers que hacen fetch en build()
**Problema:** Los providers actuales mezclan estado de carga con datos. `AsyncNotifier` maneja esto nativamente con `AsyncValue<T>`.

---

## PLAN DE IMPLEMENTACION SUGERIDO

### Fase 1 - Fixes criticos (eliminar flicker visible)
1. Migrar CashierViewModel a StateNotifier con estado inmutable
2. Agregar `.select()` a los 5 archivos que observan currentOrderProvider
3. Agregar `.select()` en sales_by_zone_view.dart
4. Crear `refreshSilent()` que no muestre spinner

### Fase 2 - Mejoras de rendimiento
5. Paralelizar cargas en CashierViewModel.init()
6. Implementar optimistic updates para add/delete item
7. Agregar verificacion de visibilidad a timers
8. Consolidar listeners realtime en byZoneViewModel

### Fase 3 - Mejoras de UX
9. Skeleton loading views
10. Banner de modo offline
11. Indicador de carga durante pago
12. Animaciones de transicion en table cards

### Fase 4 - Arquitectura
13. Extraer SalesViewModel en mixins
14. Limpiar subscriptions/dispose leaks
15. Estandarizar manejo de errores

---

## ARCHIVOS AFECTADOS (RESUMEN)

| Archivo | Mejoras Aplicables |
|---------|-------------------|
| `presentation/cashier/viewmodel/cashier_viewmodel.dart` | 1.1, 2.1, 2.4 |
| `presentation/cashier/view/cashier_view.dart` | 1.2, 3.1, 3.2 |
| `presentation/sales/view/sales_by_zone_view.dart` | 1.3, 2.7 |
| `presentation/sales/viewmodel/sales_viewmodel.dart` | 1.6, 2.5, 2.6, 4.2 |
| `presentation/sales/state/sales_state.dart` | 1.4 |
| `presentation/sales/view/quick_sale_view.dart` | 1.4 |
| `presentation/sales/view/table_order_screen.dart` | 1.4, 2.8 |
| `presentation/sales/widgets/sales_sidebar.dart` | 1.4 |
| `presentation/sales/widgets/catalog_column.dart` | 1.4 |
| `presentation/sales/view/sale_manual_view.dart` | 1.4 |
| `presentation/sales/viewmodel/sales_by_zone_viewmodel.dart` | 1.5 |
| `presentation/payments/viewmodel/payment_viewmodel.dart` | 2.2, 4.1 |
| `presentation/sales/widgets/table_card.dart` | 3.3 |
| `presentation/split_bill/viewmodel/split_bill_viewmodel.dart` | 3.4 |
| `presentation/kds/viewmodel/kds_viewmodel.dart` | 4.3 |
