# Conexión: Configuración de Impuestos → Motor de Ventas

> Fecha: 2026-04-26  
> Rama: `main`

---

## Tabla de Contenidos

1. [Dónde están las pantallas de impuestos](#1-dónde-están-las-pantallas-de-impuestos)
2. [Qué guarda la tabla `taxes` en Supabase](#2-qué-guarda-la-tabla-taxes-en-supabase)
3. [Flujo completo: UI → DB → Motor de ventas](#3-flujo-completo-ui--db--motor-de-ventas)
4. [Cómo el motor de ventas carga los impuestos](#4-cómo-el-motor-de-ventas-carga-los-impuestos)
5. [Cómo se resuelven los impuestos por origen](#5-cómo-se-resuelven-los-impuestos-por-origen)
6. [Cuándo se aplican (y cuándo NO) los cambios](#6-cuándo-se-aplican-y-cuándo-no-los-cambios)
7. [Conflicto entre `business_settings` y tabla `taxes`](#7-conflicto-entre-business_settings-y-tabla-taxes)
8. [La heurística que puede causar propina inesperada](#8-la-heurística-que-puede-causar-propina-inesperada)
9. [Qué se quitó del formulario](#9-qué-se-quitó-del-formulario)
10. [Resumen visual del flujo](#10-resumen-visual-del-flujo)

---

## 1. Dónde están las pantallas de impuestos

Existen **dos carpetas** de impuestos en settings. Solo una funciona:

| Ruta | Estado |
|---|---|
| `lib/presentation/settings/taxes/` | **VACÍA** — archivos de 1 línea, no se usa |
| `lib/presentation/settings/more settings/system settings/tax/` | **ACTIVA** — esta es la real |

### Archivos de la versión activa

```
tax/
  view/taxes_view.dart          → UI: lista + formulario de crear/editar
  viewmodel/taxes_viewmodel.dart → TaxesVm: lógica de estado
  state/taxes_state.dart         → TaxesState: datos + filtro de búsqueda
```

### Clase del repositorio

```
lib/data/repositories/tax_repository.dart  → TaxRepository
lib/data/models/tax.dart                   → modelo Tax
```

---

## 2. Qué guarda la tabla `taxes` en Supabase

Cada fila de la tabla `taxes` representa un impuesto del negocio:

| Columna | Tipo | Descripción |
|---|---|---|
| `id` | UUID | Clave primaria |
| `business_id` | UUID | Negocio al que pertenece |
| `name` | text | Nombre visible (ej: "ITBIS") |
| `rate` | numeric | Porcentaje (ej: 18.0 para 18%) |
| `is_active` | bool | Si aplica o no |
| `apply_on_zone` | bool | Aplica en ventas por zona/mesas |
| `apply_on_manual` | bool | Aplica en venta manual |
| `apply_on_quick` | bool | Aplica en venta rápida |
| `apply_on_delivery` | bool | Aplica en delivery |
| `is_service_fee` | bool | Es propina de ley (comisión de servicio) |

### Modelo Dart (`Tax`)

```dart
class Tax {
  final String id;
  final String businessId;
  final String name;
  final double rate;       // 0..100
  final bool isActive;
  final bool applyOnZone;
  final bool applyOnManual;
  final bool applyOnQuick;
  final bool applyOnDelivery;
  final bool isServiceFee;
}
```

---

## 3. Flujo completo: UI → DB → Motor de ventas

```
╔══════════════════════════════╗
║  TaxesView (formulario UI)   ║
║  · nombre, porcentaje        ║
║  · estado activo             ║
║  · aplicar en: zona/manual/  ║
║    rápida/delivery           ║
╚══════════════╦═══════════════╝
               ↓
╔══════════════════════════════╗
║  TaxesVm                     ║
║  .create() / .update()       ║
║  .toggleActive()             ║
║  .remove()                   ║
╚══════════════╦═══════════════╝
               ↓
╔══════════════════════════════╗
║  TaxRepository               ║
║  INSERT / UPDATE / DELETE    ║
║  tabla: taxes                ║
╚══════════════╦═══════════════╝
               ↓
╔══════════════════════════════╗
║  Supabase tabla `taxes`      ║
╚══════════════╦═══════════════╝
               ↓  (en la próxima apertura de orden o addItem)
╔══════════════════════════════╗
║  SalesViewModel              ║
║  _ensureBusinessTaxSettings  ║
║  Loaded()                    ║
║  → lee taxes WHERE           ║
║    is_active = true          ║
║  → _cachedBusinessTaxes      ║
╚══════════════╦═══════════════╝
               ↓
╔══════════════════════════════╗
║  _taxDefs → List<TaxDef>     ║
║  (convierte Map → TaxDef)    ║
╚══════════════╦═══════════════╝
               ↓
╔══════════════════════════════╗
║  resolveTaxRates(            ║
║    taxDefs, origin)          ║
║  → effectiveTaxPct           ║
║  → fullTaxPct                ║
║  → serviceFeePct             ║
║  → serviceFeeActive          ║
╚══════════════╦═══════════════╝
               ↓
╔══════════════════════════════╗
║  calculateItemTax()          ║
║  summarizeItemPricing()      ║
║  → base, tax, serviceFee     ║
║     por ítem                 ║
╚══════════════════════════════╝
```

---

## 4. Cómo el motor de ventas carga los impuestos

### Método `_ensureBusinessTaxSettingsLoaded()` — `sales_viewmodel.dart`

Este método se llama cada vez que se abre una orden o se agrega un ítem. Lee de **dos fuentes**:

**Fuente 1 — tabla `business_settings`:**
```dart
Supabase.from('business_settings')
  .select('default_tax_rate, service_fee_enabled, service_fee_rate, ...')
  .eq('business_id', businessId)
  .maybeSingle()
```
Guarda: `_cachedTaxRatePct`, `_cachedServiceFeeEnabled`, `_cachedServiceFeeRatePct`

**Fuente 2 — tabla `taxes`:**
```dart
Supabase.from('taxes')
  .select('name, rate, is_active, is_service_fee,
           apply_on_zone, apply_on_manual, apply_on_quick, apply_on_delivery')
  .eq('business_id', businessId)
  .eq('is_active', true)
```
Guarda: `_cachedBusinessTaxes` (lista de Maps)

### Cache con TTL de 1 segundo

```dart
if (_taxSettingsBusinessId == businessId &&
    _lastTaxLoad != null &&
    DateTime.now().difference(_lastTaxLoad!) < const Duration(seconds: 1)) {
  return; // no recarga si fue hace menos de 1 segundo
}
```

Esto evita lecturas excesivas a Supabase cuando se agregan varios ítems seguidos.

### Conversión a `TaxDef`

```dart
List<TaxDef> get _taxDefs =>
    _cachedBusinessTaxes.map(TaxDef.fromMap).toList();
```

`TaxDef` es la clase interna del motor de impuestos (`lib/core/tax/tax_engine.dart`). Espeja exactamente los campos de la tabla `taxes`.

---

## 5. Cómo se resuelven los impuestos por origen

### Función `resolveTaxRates(taxes, origin)` — `tax_engine.dart`

Filtra los impuestos según el origen de la venta y calcula tres valores:

```dart
ResolvedTaxRates {
  effectiveTaxPct   // suma de impuestos REALES (excluye propina)
  fullTaxPct        // suma de TODOS (incluye propina) — para extraer base en modo inclusive
  serviceFeePct     // tasa de propina de ley para este origen
  serviceFeeActive  // true si hay propina activa para este origen
}
```

### Lógica de filtrado

```dart
for (final tx in taxes) {
  if (!tx.isActive || tx.rate <= 0) continue;

  fullPct += tx.rate;   // suma SIEMPRE al full

  if (tx.effectiveIsServiceFee) {
    if (tx.appliesTo(origin)) {
      serviceFeePct = tx.rate;
      serviceFeeActive = true;
    }
    continue;           // propina NO va a effectiveTaxPct
  }

  if (tx.appliesTo(origin)) {
    effectivePct += tx.rate;   // impuesto normal sí va
  }
}
```

### Tabla de resultados por origen

| Origin | Zona (`zone`) | Manual (`manual`) | Rápida (`quick`) | Delivery (`delivery`) |
|---|---|---|---|---|
| Usa flag | `apply_on_zone` | `apply_on_manual` | `apply_on_quick` | `apply_on_delivery` |
| Propina de ley en UI | Sí (si activa) | Sí (si activa) | **Forzado a 0** en pricing | **Forzado a 0** en pricing |

> **Nota:** Quick y Delivery tienen una exclusión adicional en `order_pricing_utils.dart` línea 90:
> ```dart
> bool shouldShowServiceFee = !item.isTakeout &&
>     origin != SaleOrigin.quick &&
>     origin != SaleOrigin.delivery;
> ```
> Esto ignora la propina aunque esté configurada para esos orígenes en la DB.

---

## 6. Cuándo se aplican (y cuándo NO) los cambios

### Los cambios en configuración SÍ aplican para:
- Nuevas órdenes abiertas después del cambio
- Nuevos ítems agregados a una orden existente (respeta el TTL de 1 segundo)

### Los cambios en configuración NO aplican para:
- Ítems ya guardados en la tabla `order_items`
- La DB es fuente de verdad para ítems existentes:

```dart
// sales_viewmodel.dart
// La DB debe ser la fuente de verdad para items ya guardados.
// Antes se reescribían taxRate/originalTaxRate con la configuración actual
// del negocio, lo que hacía que productos reaparecieran con precios incorrectos.
final normalizedItems = activeItems; // sin modificar las tasas del DB
```

Cada ítem guarda un snapshot fiscal:
- `order_items.tax_rate` — tasa efectiva al momento del insert
- `order_items.original_tax_rate` — tasa completa (incluyendo propina si aplica)

---

## 7. Conflicto entre `business_settings` y tabla `taxes`

El viewmodel lee de dos fuentes y **la tabla `taxes` tiene prioridad**:

```dart
// Si hay un tax marcado como service fee, sobreescribe business_settings
final serviceTax = _cachedBusinessTaxes.firstWhere(
  (tx) => TaxDef.fromMap(tx).effectiveIsServiceFee,
  orElse: () => null,
);
if (serviceTax != null) {
  _cachedServiceFeeEnabled = true;                     // SOBREESCRIBE
  _cachedServiceFeeRatePct = serviceTax['rate'];       // SOBREESCRIBE
}
```

### Tabla de escenarios

| Escenario | `_cachedServiceFeeEnabled` | `serviceFeeActive` en resolve | Resultado |
|---|---|---|---|
| `taxes` vacía + `service_fee_enabled=false` | `false` | `false` | Sin propina ✓ |
| `taxes` vacía + `service_fee_enabled=true` | `true` | `false` (lista vacía) | Sin propina ✓ |
| `taxes` tiene row con `is_service_fee=true` | `true` (sobreescrito) | `true` | Con propina |
| `taxes` tiene row con nombre "propina"/"servicio" y rate ~10% | `true` (sobreescrito) | `true` | Con propina (heurística) |

---

## 8. La heurística que puede causar propina inesperada

Un impuesto se identifica como propina de ley de **dos formas**:

**Forma 1 — flag explícito (recomendado):**
```dart
if (isServiceFee) return true;
```

**Forma 2 — heurística por nombre y tasa:**
```dart
final n = name.toLowerCase();
return (rate - 10).abs() < 0.001 &&
    (n.contains('propina') || n.contains('servicio'));
```

Si alguien crea un impuesto llamado **"Servicio"** o **"Propina"** al **10%**, el sistema lo tratará como propina de ley **aunque `is_service_fee` sea `false`** en la DB.

### Causas adicionales de propina inesperada

**Causa A — `resolveOrderServiceRate` retorna 10% por defecto:**
```dart
double resolveOrderServiceRate(Order? order) {
  if (order == null) return 0.10;         // ← 10% si no hay orden
  if (subtotal > 0 && serviceFee > 0) {
    return serviceFee / subtotal;
  }
  return 0.10;                            // ← 10% si serviceFee=0 en DB
}
```
Si `order.serviceFee > 0` viene de la DB (valor histórico), la propina se calcula aunque no haya impuestos configurados.

**Causa B — `fullTaxPct` asume propina cuando falta `originalTaxRate`:**
```dart
// order_pricing_utils.dart
double fullTaxPct = item.originalTaxRate ??
    (effectiveTaxPct + (item.isTakeout ? 0.0 : orderServicePct));
// Si originalTaxRate es null → asume que la propina ya estaba incluida
```

**Causa C — heurística de emergencia en `_normalizeHydratedState`:**
```dart
// Si service_fee = 0 en DB pero el origen debería tener propina:
if (pricingOrder.serviceFee == 0 && _isServiceFeeActiveForOrigin()) {
  // Estima la propina separándola del campo tax
  final estimatedService = totalTaxInOrder * (serviceRate / totalEffectiveRate);
  pricingOrder = pricingOrder.copyWith(serviceFee: estimatedService);
}
```

---

## 9. Qué se quitó del formulario

### Cambio realizado el 2026-04-26

Se eliminó el toggle **"¿Es Propina de Ley (10%)?"** del formulario de crear/editar impuesto.

**Archivo modificado:**
`lib/presentation/settings/more settings/system settings/tax/view/taxes_view.dart`

**Comportamiento después del cambio:**

| Acción | `is_service_fee` resultante |
|---|---|
| Crear nuevo impuesto | Siempre `false` (default del repositorio) |
| Editar impuesto existente | El campo **no se toca** en el UPDATE — queda como estaba en DB |
| Eliminar impuesto | Sin cambios en este campo |

**Por qué se hizo:** el campo causaba confusión al usuario y el sistema ya tiene una heurística automática para identificar la propina de ley por nombre y tasa.

---

## 10. Resumen visual del flujo

```
Configuración → tabla taxes
  ↓
  name="ITBIS", rate=18, is_active=true,
  apply_on_zone=true, apply_on_quick=false,
  is_service_fee=false

  name="LEY", rate=10, is_active=true,
  apply_on_zone=true, apply_on_manual=true,
  is_service_fee=true


Apertura de orden / addItem en ventas
  ↓ _ensureBusinessTaxSettingsLoaded()
  ↓ Lee business_settings + taxes WHERE is_active=true
  
  _cachedBusinessTaxes = [
    { name: "ITBIS", rate: 18, apply_on_zone: true, ... },
    { name: "LEY",   rate: 10, is_service_fee: true, apply_on_zone: true, ... }
  ]
  _cachedServiceFeeEnabled = true  (porque LEY tiene is_service_fee=true)
  _cachedServiceFeeRatePct = 10.0


Para origin = "zone":
  resolveTaxRates → effectiveTaxPct=18, fullTaxPct=28, serviceFeePct=10, active=true

  calculateItemTax(gross=100, mode='inclusive', effective=18, full=28, sf=10):
    divisor = 1.28
    tax  = 100 × (18/128) = 14.06   → "ITBIS (18%)"
    sf   = 100 × (10/128) =  7.81   → "Propina Ley (10%)"
    base = 100 - 14.06 - 7.81      = 78.13
    total = 78.13 + 14.06 + 7.81  = 100.00 ✓


Para origin = "quick":
  resolveTaxRates → effectiveTaxPct=0 (apply_on_quick=false para ITBIS),
                    serviceFeePct=10 pero shouldShowServiceFee=false (origin=quick)

  calculateItemTax(gross=100, mode='inclusive', effective=0, full=0, sf=0):
    total = 100.00 (sin impuestos)


Ítems ya guardados en order_items:
  → tax_rate y original_tax_rate son snapshot fijo
  → cambios en tabla taxes NO los afectan
  → la DB es fuente de verdad para ítems existentes
```

---

*Documento generado a partir del código fuente de MangoPOS — 2026-04-26*
