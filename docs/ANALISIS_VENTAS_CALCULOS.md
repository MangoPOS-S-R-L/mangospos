# Análisis Completo del Módulo de Ventas — MangoPOS

> Fecha: 2026-04-26  
> Versión analizada: rama `main`

---

## Tabla de Contenidos

1. [Arquitectura General de Ventas](#1-arquitectura-general-de-ventas)
2. [Ventas por Zona (Mesas)](#2-ventas-por-zona-mesas)
3. [Venta Rápida (Quick Sale)](#3-venta-rápida-quick-sale)
4. [Venta Manual](#4-venta-manual)
5. [Delivery / Express](#5-delivery--express)
6. [Self Checkout](#6-self-checkout)
7. [División de Cuenta (Split Bill)](#7-división-de-cuenta-split-bill)
8. [Flujo de Pago](#8-flujo-de-pago)
9. [Motor de Impuestos y Cálculos](#9-motor-de-impuestos-y-cálculos)
10. [Bug: Impuesto de Ley sin impuestos configurados](#10-bug-impuesto-de-ley-sin-impuestos-configurados)
11. [Cadena Completa de Cálculo Numérico](#11-cadena-completa-de-cálculo-numérico)
12. [Descuentos y Cortesías](#12-descuentos-y-cortesías)

---

## 1. Arquitectura General de Ventas

```
Router
  └─ SalesShellView (lib/presentation/sales/view/sales_shell_view.dart)
        ├─ SalesByZoneView       → Mesas/Zonas
        ├─ QuickSaleView         → Venta Rápida
        ├─ SaleManualView        → Venta Manual
        ├─ DeliveryExpressView   → Delivery
        └─ SelfServiceView       → Self Checkout (STUB)
```

### Providers principales

| Provider | Archivo | Rol |
|---|---|---|
| `currentOrderProvider` | `sales_viewmodel.dart` | Estado de la orden activa, cálculos, acciones |
| `byZoneVmProvider` | `sales_by_zone_viewmodel.dart` | Estado de zonas/mesas, realtime |
| `splitBillViewModelProvider` | `split_bill_viewmodel.dart` | División de cuenta |
| `salesRepositoryProvider` | `sales_viewmodel.dart` | Acceso a Supabase/RPCs |

### Estado global de orden (`CurrentOrderState`)

Almacena: `order`, `items`, `checks`, `origin`, `fiscalType`, flags de offline, sincronización pendiente.

---

## 2. Ventas por Zona (Mesas)

### Archivos clave
- `lib/presentation/sales/view/sales_by_zone_view.dart`
- `lib/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart`
- `lib/presentation/sales/view/table_order_screen.dart`
- `lib/data/repositories/zones_repository.dart`

### Cómo funciona

**Paso 1 — Carga de zonas (`ByZoneViewModel.load`)**

```dart
// Excluye zonas virtuales de rápida/manual/delivery
zones.where((z) {
  final name = z.name.toLowerCase();
  return name != 'ventas manuales' && 
         name != 'ventas rápidas' && 
         name != 'delivery';
})
// Ordena por sortIndex → nombre
```

**Paso 2 — Estado de mesas por zona (`loadZoneStatus`)**

Para cada zona, carga todas las mesas con su sesión activa:
- `state` → available / occupied / dirty
- `ordersCount`, `itemsCount`, `currentTotal`
- Detecta **sesiones huérfanas** (sesión abierta + 0 ítems) y las libera automáticamente en background via `_releaseStaleAndReload`

**Paso 3 — Ordenamiento natural**

Las mesas se ordenan con `SortingUtils.naturalCompare`:  
`Mesa 1 → Mesa 2 → ... → Mesa 10` (no lexicográfico)

**Paso 4 — Realtime (Supabase Realtime)**

Suscrito a 5 tablas con debounce de **450ms**:
- `table_sessions`
- `orders`
- `order_items`
- `order_checks`
- `payments`

Cuando llega un cambio, identifica la zona afectada vía índices internos (`_tableToZoneIndex`, `_sessionToZoneIndex`) y recarga solo esa zona. Si no puede resolver la zona, recarga todo.

**Paso 5 — Abrir mesa**

```
Usuario toca mesa
  → sales_viewmodel.openTable(tableId)
  → RPC fn_open_table (backend)
  → Crea/reutiliza TableSession + Order
  → _loadOrderDetail() → carga ítems, checks, fiscalType
  → UI muestra TableOrderScreen con orden activa
```

---

## 3. Venta Rápida (Quick Sale)

### Archivos clave
- `lib/presentation/sales/view/quick_sale_view.dart`
- `lib/presentation/sales/viewmodel/sales_viewmodel.dart` → `openQuick()`

### Diferencias respecto a zona

| Aspecto | Zona | Quick |
|---|---|---|
| Mesa física | Sí | No (mesa virtual) |
| Propina de ley | Según configuración | **No aplica** |
| Service fee | Sí | **No** |
| Origin | `zone` | `quick` |

### Cómo funciona

```dart
// sales_viewmodel.dart
openQuick() → RPC fn_open_manual_or_quick(origin: 'quick')
// Crea mesa virtual "ventas rápidas"
```

La venta rápida **salta** la propina de ley porque:

```dart
// order_pricing_utils.dart línea 90
bool shouldShowServiceFee = !item.isTakeout && 
    origin != SaleOrigin.quick &&   // ← aquí
    origin != SaleOrigin.delivery;
```

### Cálculo de totales en Quick

```
Precio catálogo → solo ITBIS (si aplica) → sin propina → Total
```

---

## 4. Venta Manual

### Archivos clave
- `lib/presentation/sales/view/sale_manual_view.dart`
- `lib/presentation/sales/viewmodel/sales_viewmodel.dart` → `openManual()`

### Cómo funciona

```dart
openManual() → RPC fn_open_manual_or_quick(origin: 'manual')
```

Comportamiento igual a zona en cuanto a impuestos (aplica propina de ley si está configurada para `apply_on_manual = true`).  
Sin mesa física, usa zona virtual "ventas manuales".

---

## 5. Delivery / Express

### Archivos clave
- `lib/presentation/sales/view/delivery_express_view.dart`
- `lib/presentation/sales/viewmodel/delivery_viewmodel.dart`

### Diferencias

| Aspecto | Zona | Delivery |
|---|---|---|
| Propina de ley | Sí | **No aplica** |
| Origin | `zone` | `delivery` |
| Dirección cliente | No | Sí |

La propina de ley se excluye igual que en Quick (mismo chequeo de `origin != SaleOrigin.delivery`).

---

## 6. Self Checkout

### Archivo
- `lib/presentation/sales/view/self_service_view.dart`

### Estado actual

**NO IMPLEMENTADO.** La pantalla es un stub:

```dart
class SelfServiceView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text('Self service no disponible'),
      ),
    );
  }
}
```

No existe lógica de negocio, cálculos ni flujo para self-checkout. Es una funcionalidad pendiente.

---

## 7. División de Cuenta (Split Bill)

### Archivos clave
- `lib/presentation/split_bill/viewmodel/split_bill_viewmodel.dart`
- `lib/presentation/sales/view/payment_split_screen.dart`
- `lib/data/models/sales_models.dart` → `OrderCheck`

### Estructura de datos

```dart
OrderCheck {
  id          // UUID (o temp_<timestamp> si es nuevo)
  orderId
  label       // "C1", "C2", "C3"...
  position    // orden numérico
  isClosed
  subtotal, discounts, serviceFee, tax, total
  customerId?, customerName?
  items       // ítems asignados a esta subcuenta
}
```

### Proceso paso a paso

**1. Inicialización (`initialize`)**

```
RPC getOrderBundle → order + items + checks
C1 = cuenta principal (pool de ítems sin asignar)
C2, C3... = subcuentas visibles al usuario

Items que NO pertenecen a subcuenta visible → forceCheckIdNull = true (van al pool C1)
_recalculateChecksTotals() → recalcula totales de cada check
```

**2. Crear nueva subcuenta (`createNewCheck`)**

```dart
newId = 'temp_${DateTime.now().millisecondsSinceEpoch}'
nextPosition = maxPosition + 1  // empieza en 2 (C1 es oculta)
label = 'C$nextPosition'
// Solo estado local hasta que se guarde
```

**3. Asignar ítems a subcuenta**

```
Usuario arrastra ítem → moveItemToCheck(itemId, position)
  → SalesRepository.moveItemToCheck()
  → RPC fn_move_item_to_check
  → Actualiza item.checkId
  → Backend llama fn_recalc_order_totals() → recalcula TODOS los checks
```

**4. Recálculo de totales por check (`_recalculateChecksTotals`)**

```dart
Para cada check:
  checkItems = items.where((i) => i.checkId == check.id)
  summary = summarizeOrderPricing(pricingOrder, checkItems)
  check = check.copyWith(
    subtotal: summary.subtotal,
    tax: summary.tax,
    serviceFee: summary.serviceFee,
    total: summary.total,
  )
```

**5. Asignar cliente a subcuenta**

```dart
assignCustomerToCheck(checkId, customerId, customerName)
  → Estado local inmediato
  → Si checkId es UUID real → persiste en DB
```

**6. Pago por subcuenta**

```
PaymentViewModel.initializeForCheck(order, check)
  → totalToPay = check.total
  → Procesa pago solo para ese check
  → Ítems del check marcados como 'paid'
```

---

## 8. Flujo de Pago

### Archivos clave
- `lib/presentation/sales/view/payment_dialog.dart`
- `lib/presentation/payments/viewmodel/payment_viewmodel.dart`
- `lib/data/repositories/sales_repository.dart`

### Inicialización

```dart
// Orden completa
initializeForOrder(order) → totalToPay = order.total

// Check específico
initializeForCheck(order, check) → totalToPay = check.total
```

### Pago en efectivo

```dart
setAmountReceived(amount) {
  change = amount - totalToPay   // vuelto
}

addToAmountReceived(amount) {    // botones de denominación
  setAmountReceived(amountReceived + amount)
}

setExactAmount() {               // botón "monto exacto"
  setAmountReceived(totalToPay)
}
```

### Procesamiento backend

```
SalesRepository.processPayment()
  → RPC fn_process_payment_v3
  → Valida sesión de caja abierta
  → Crea registro en tabla payments
  → Actualiza status order/check → 'paid'
  → Si pago en efectivo → registra en cashier_session cash flow
  → Si requiere documento fiscal → genera NCF
```

### Cambio (vuelto)

```
vuelto = amountReceived - totalToPay
Solo se muestra si > 0
Se registra en el pago para trazabilidad
```

---

## 9. Motor de Impuestos y Cálculos

### Archivos clave
- `lib/core/tax/tax_engine.dart`
- `lib/data/utils/order_pricing_utils.dart`

### Configuración por origen

Cada impuesto (`TaxDef`) tiene flags booleanos:
- `applyOnZone`, `applyOnManual`, `applyOnQuick`, `applyOnDelivery`

`resolveTaxRates(taxes, origin)` filtra cuáles aplican y retorna:

```dart
ResolvedTaxRates {
  effectiveTaxPct   // suma de impuestos (SIN propina)
  fullTaxPct        // suma de TODOS (CON propina)
  serviceFeePct     // tasa de propina de ley
  serviceFeeActive  // si aplica para este origin
}
```

### Identificación de "Propina de Ley"

Un impuesto se identifica como propina de ley si:
1. Tiene `isServiceFee = true`, **O**
2. Su tasa es ~10% Y su nombre contiene "propina" o "servicio"

```dart
bool get effectiveIsServiceFee {
  if (isServiceFee) return true;
  final n = name.toLowerCase();
  return (rate - 10).abs() < 0.001 &&
      (n.contains('propina') || n.contains('servicio'));
}
```

### Dos modos de impuesto

| Modo | Descripción |
|---|---|
| `inclusive` | El precio del catálogo **ya incluye** todos los impuestos |
| `exclusive` | Los impuestos se suman **por encima** del precio base |

---

## 10. Bug: Impuesto de Ley sin impuestos configurados

### Descripción del problema

La **Propina de Ley** (service fee) aparece calculada en la pantalla aunque no existan impuestos creados en la tabla `taxes`.

### Dónde ocurre

**Causa 1 — Defaults hardcodeados en `sales_viewmodel.dart`**

```dart
// línea 48-49
static const _defaultTaxRatePct = 18.0;      // ← default
static const _defaultServiceFeeRatePct = 10.0; // ← default
```

Si la carga de `business_settings` falla (catch), el viewmodel usa estos valores:

```dart
} catch (e) {
  _cachedTaxRatePct = _defaultTaxRatePct;         // 18%
  _cachedServiceFeeRatePct = _defaultServiceFeeRatePct; // 10%
  _cachedServiceFeeEnabled = false;               // ← pero aquí es false
  _cachedBusinessTaxes = const [];
}
```

**Causa 2 — `resolveOrderServiceRate` siempre retorna 10% por defecto**

```dart
// order_pricing_utils.dart línea 11-19
double resolveOrderServiceRate(Order? order) {
  if (order == null) return 0.10;         // ← 10% si no hay orden
  final subtotal = order.subtotal;
  final serviceFee = order.serviceFee;
  if (subtotal > 0 && serviceFee > 0) {
    return serviceFee / subtotal;         // calcula de la DB
  }
  return 0.10;                            // ← 10% si serviceFee=0
}
```

Esta función es llamada en `summarizeItemPricing` para el cálculo de modo `exclusive`. Si `order.serviceFee > 0` en la DB aunque no haya impuestos configurados en el frontend, la propina se calcula.

**Causa 3 — `fullTaxPct` asume 10% de propina cuando no hay `originalTaxRate`**

```dart
// order_pricing_utils.dart línea 66
double fullTaxPct = item.originalTaxRate ?? 
    (effectiveTaxPct + (item.isTakeout ? 0.0 : orderServicePct));
//                     ↑ Si originalTaxRate es null, suma la propina
```

Si el ítem viene de la DB sin `originalTaxRate` (null), el frontend asume que la propina **ya estaba incluida** en el precio y la extrae del desglose, creando la propina de la nada.

**Causa 4 — Heurística de emergencia**

```dart
// sales_viewmodel.dart línea 425-441
// Si backend devolvió service_fee = 0 pero debería tener propina:
if (pricingOrder.serviceFee == 0 && _isServiceFeeActiveForOrigin()) {
  // Estima y separa la propina del campo tax
  final estimatedService = totalTaxInOrder * (serviceRate / totalEffectiveRate);
  pricingOrder = pricingOrder.copyWith(
    tax: estimatedTax,
    serviceFee: estimatedService,   // ← genera propina aunque no exista
  );
}
```

### Ruta del bug más probable

```
1. Negocio sin impuestos en tabla `taxes`
2. `_cachedBusinessTaxes = []` → _isServiceFeeActiveForOrigin() = false
3. PERO order.serviceFee > 0 viene de la DB (valor histórico o default del backend)
4. resolveOrderServiceRate(order) = serviceFee/subtotal (ej: 10%)
5. En modo exclusive: serviceFee = subtotal * 10% → aparece propina
6. En modo inclusive: fullTaxPct = effectiveTaxPct + 10% (causa 3) → aparece propina
```

### Fix recomendado

En `summarizeItemPricing`, modo `exclusive`, no calcular service fee si `_isServiceFeeActiveForOrigin()` es false:

```dart
// Línea 106-107 en order_pricing_utils.dart (modo exclusive)
// ACTUAL:
final serviceFee = (serviceRate > 0 && !item.isTakeout) 
    ? _r(dbSubtotal * serviceRate) : 0.0;

// CORRECCIÓN: solo usar serviceRate si el negocio tiene propina activa
// Pasar un flag isServiceFeeActive desde el caller y validarlo aquí
```

En `resolveOrderServiceRate`, no retornar 10% por defecto si no hay propina configurada:

```dart
// ACTUAL: return 0.10  (línea 12 y 18)
// CORRECCIÓN: return 0.0 cuando no hay propina en la DB
```

---

## 11. Cadena Completa de Cálculo Numérico

### Función de redondeo

Todo cálculo usa `_r(v)` = `double.parse(v.toStringAsFixed(2))` — 2 decimales siempre.

---

### ETAPA 1: Selección de ítem (Frontend)

```
unitPrice (del catálogo)
quantity  (cantidad)
modifiers (lista con price y qty)

catalogGross = (unitPrice × quantity) + sum(mod.price × mod.qty)
```

Código: `lib/core/tax/tax_engine.dart` → `catalogGrossAmount()`

---

### ETAPA 2: Insert en BD (backend RPC `fn_compute_item_totals`)

**Modo INCLUSIVE** (precio ya incluye impuestos):

```
divisor = 1 + fullTaxRate/100          // ej: 1.28 para 18%+10%
base = grossAmount / divisor           // extrae la base neta
tax  = base × (effectiveTaxRate/100)   // solo ITBIS sobre la base
sf   = base × (serviceRate/100)        // propina sobre la base
```

**Modo EXCLUSIVE** (impuestos se suman al precio):

```
base = grossAmount
taxableBase = base - discounts
tax  = taxableBase × (taxRate/100)
sf   = taxableBase × (serviceRate/100)
total = taxableBase + tax + sf
```

---

### ETAPA 3: Pricing por ítem en Frontend (`summarizeItemPricing`)

**Modo INCLUSIVE:**

```dart
displayTotal = catalogGross - discounts  // lo que el cliente ve

// Corrección especial: si taxRate >= 27.9 (llegó 28% camuflado)
effectiveTaxPct = 18.0   // ITBIS real
fullTaxPct = 28.0        // 18% ITBIS + 10% propina

// Calcula propina real
serviceFeePct = fullTaxPct - effectiveTaxPct  // 10%

// Llama al motor
result = calculateItemTax(
  grossAmount: displayTotal + discounts,
  taxMode: 'inclusive',
  effectiveTaxPct: 18.0,
  fullTaxPct: 28.0,
  serviceFeePct: 10.0,
  isTakeout: false,
  discounts: discounts,
)

// Motor calcula:
divisor = 1 + 0.28 = 1.28
tax = netGross × (0.18 / 1.28)
sf  = netGross × (0.10 / 1.28)
base = netGross - tax - sf
// VERIFICACIÓN: base + tax + sf = netGross ✓

// Origen determina si se muestra propina:
shouldShowServiceFee = !isTakeout && origin != quick && origin != delivery
finalServiceFee = shouldShowServiceFee ? sf : 0.0
finalTotal = base + tax + finalServiceFee
```

**Modo EXCLUSIVE:**

```dart
serviceRate = resolveOrderServiceRate(order)  // de DB o default 10%
serviceFee = (serviceRate > 0 && !isTakeout)
    ? dbSubtotal × serviceRate
    : 0.0
total = dbSubtotal + dbTax + serviceFee - dbDiscounts
```

---

### ETAPA 4: Agregación de orden (`summarizeOrderPricing`)

```dart
Para cada item (excepto status == 'void'):
  s = summarizeItemPricing(order, item)
  subtotal     += s.subtotal
  tax          += s.tax
  serviceFee   += s.serviceFee
  discounts    += s.discounts

// Agrupar impuesto por tasa para desglose
taxGroups[item.taxRate] += s.tax

finalTotal = subtotal + tax + serviceFee  // discounts ya están en base
```

**IMPORTANTE:** Los descuentos ya están descontados en los componentes individuales (base, tax, serviceFee), por eso no se restan del total final.

---

### ETAPA 5: Desglose de impuestos para UI (`buildOrderTaxBreakdown`)

```dart
// Unifica ITBIS: rate 28 → displayRate 18 (evita duplicar ITBIS)
itbisByDisplayRate[28.0] → displayRate = 18.0

// Genera líneas:
"ITBIS (18%)" → suma de todos los items con ITBIS
"Propina Ley (10%)" → sum(serviceFee) si > 0.004
```

---

### ETAPA 6: Toggle por origen (última capa)

```
origin = quick   → serviceFee = 0, total = subtotal + tax
origin = delivery → serviceFee = 0, total = subtotal + tax
origin = zone    → serviceFee según configuración
origin = manual  → serviceFee según configuración
```

---

### Resumen de fórmulas finales

| Concepto | Fórmula |
|---|---|
| Gross de ítem | `(unitPrice × qty) + sum(mod.price × mod.qty)` |
| ITBIS inclusivo | `netGross × (0.18 / 1.28)` |
| Propina inclusiva | `netGross × (0.10 / 1.28)` |
| Base inclusiva | `netGross - ITBIS - Propina` |
| ITBIS exclusivo | `(gross - discounts) × 0.18` |
| Propina exclusiva | `(gross - discounts) × 0.10` |
| Total orden | `Σbase + Σtax + ΣserviceFee` |
| Vuelto | `amountReceived - totalToPay` |

---

## 12. Descuentos y Cortesías

### Archivos clave
- `lib/presentation/sales/viewmodel/sales_viewmodel.dart`

### Tipo A: Descuento por porcentaje (`applyDiscountPercentToItems`)

```dart
base = (item.subtotal + item.tax).clamp(0, ∞)
discountAmount = base × (percent / 100)
// → Llama SalesRepository.updateItemDiscountAndNotes()
// → RPC actualiza item.discounts en DB
// → Trigger fn_recalc_order_totals() recalcula todo
```

### Tipo B: Cortesía / Gratis (`applyCourtesyToItems`)

```dart
// Marca el ítem completo como $0
base = subtotal + tax  // precio completo del ítem
discount = base        // descuento = 100%
notes += "[CORTESIA: motivo]"
```

### Tipo C: Promos automáticas

Detectadas por prefijo `[PROMO_AUTO:` en notas del ítem.  
Se eliminan automáticamente antes de aplicar otros descuentos (línea ~1506) para evitar acumulación.  
Se conservan en DB para reportes.

### Efecto en cálculos

Los descuentos se almacenan en `item.discounts` y afectan el cálculo de esta forma:

**Modo INCLUSIVE:**
```
netGross = (catalogGross - discounts).clamp(0)
tax = netGross × (itbisRate / fullRate)   // tax se reduce
sf  = netGross × (sfRate / fullRate)      // sf se reduce
base = netGross - tax - sf
```

**Modo EXCLUSIVE:**
```
taxableBase = (gross - discounts).clamp(0)
tax = taxableBase × itbisRate             // tax se reduce
sf  = taxableBase × sfRate                // sf se reduce
total = taxableBase + tax + sf
```

El descuento **sí reduce los impuestos** porque se aplica antes del cálculo de tax.

---

*Documento generado a partir del análisis del código fuente de MangoPOS, rama `main`, 2026-04-26.*
