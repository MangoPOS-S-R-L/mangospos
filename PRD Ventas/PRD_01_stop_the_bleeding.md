# PRD 1 — Stop-the-Bleeding (Estabilización Fiscal Inmediata)

| Campo | Valor |
|---|---|
| **Programa** | Estabilización Fiscal MangoPOS |
| **PRD** | 1 de 3 |
| **Versión** | 1.0 |
| **Fecha** | 2026-04-26 |
| **Autor** | Cristian (DRI) |
| **Estado** | Listo para ejecución |
| **Prioridad** | **P0** — bug fiscal activo en producción |
| **Esfuerzo estimado** | 5 días full-time |
| **Riesgo** | Bajo |

---

## Tabla de Contenidos

1. [Executive Summary](#1-executive-summary)
2. [Antes de empezar (prerrequisitos)](#2-antes-de-empezar-prerrequisitos)
3. [Goals y Non-Goals](#3-goals-y-non-goals)
4. [Cambios concretos](#4-cambios-concretos)
5. [Test Plan](#5-test-plan)
6. [Rollout Plan](#6-rollout-plan)
7. [Rollback Plan](#7-rollback-plan)
8. [Definition of Done](#8-definition-of-done)
9. [Decision Log](#9-decision-log)

---

## 1. Executive Summary

Este PRD elimina los **defaults numéricos hardcodeados** y las **heurísticas de emergencia** que están causando que MangoPOS muestre datos fiscales incorrectos a operadores piloto. **No refactoriza la arquitectura** — solo detiene el daño inmediato mientras se planifica el refactor profundo (PRD 2).

**Cambio principal:** Donde antes el sistema decía "si no sé, asumo 10%", ahora dirá "si no sé, bloqueo el cobro y le aviso al operador". Esto es **fail-loud en lugar de fail-silent**.

**Resultado esperado al final de la semana:**
- Cero defaults numéricos en código de cálculo fiscal
- Cero heurísticas de emergencia
- Sistema bloquea pago si configuración fiscal no está disponible
- Reporte fiscal lee tasas reales en vez de mostrar `10.0` hardcodeado
- Tests dorados que congelan el comportamiento esperado

---

## 2. Antes de empezar (prerrequisitos)

**Estos prerrequisitos son obligatorios. Sin ellos, no se debe iniciar el PRD.**

### 2.1 Ambiente de staging funcional

- [ ] Existe instancia de Supabase paralela a producción (proyecto separado o branch)
- [ ] La app Flutter puede compilarse apuntando a staging (variable de entorno o config)
- [ ] Hay un dump reciente de producción restaurado en staging
- [ ] Se ha verificado que el dump funciona haciendo una venta de prueba en staging

### 2.2 Backups probados

- [ ] Existe un mecanismo de backup automático de producción (frecuencia conocida)
- [ ] Se ha hecho **al menos un restore exitoso** desde un backup en los últimos 30 días
- [ ] Existe un runbook de cómo restaurar un backup en caso de emergencia
- [ ] El runbook ha sido leído y entendido

### 2.3 Repositorio en estado limpio

- [ ] El branch `main` (o equivalente) está sin cambios sin commitear
- [ ] No hay PRs abiertos pendientes que afecten archivos de impuestos
- [ ] Existe un branch nuevo para este PRD: `prd/01-stop-the-bleeding`

### 2.4 Comunicación con operadores

- [ ] Mensaje pre-anuncio enviado: "Vamos a hacer ajustes técnicos esta semana. Si bloquea algún cobro inesperadamente, avisame inmediatamente."
- [ ] Canal directo establecido (WhatsApp/email) con cada piloto

**Si algún checkbox queda sin marcar, no se inicia el PRD.** No es opcional.

---

## 3. Goals y Non-Goals

### 3.1 Goals

**G1.** Eliminar el hardcode `'service_fee_rate': 10.0` en `reports_repository.dart:1101`.

**G2.** Eliminar las constantes `_defaultTaxRatePct = 18.0` y `_defaultServiceFeeRatePct = 10.0` en `sales_viewmodel.dart`.

**G3.** Implementar fail-loud cuando la configuración fiscal no se carga correctamente.

**G4.** Bloquear el procesamiento de pagos si `taxConfigError != null`.

**G5.** Eliminar la "heurística de emergencia" en `_normalizeHydratedState` que estima propina cuando el backend devuelve 0.

**G6.** Eliminar el getter `effectiveIsServiceFee` (heurística por nombre y tasa).

**G7.** Producir un suite básico de tests dorados que congele el comportamiento del sistema antes del refactor del PRD 2.

**G8.** Eliminar el trigger duplicado `tr_compute_item_totals` o `trg_compute_item_totals` en `order_items` (dejar solo uno).

### 3.2 Non-Goals

**N1.** **No** se va a refactorizar el motor de cálculo (`calculate_order_totals`, `calculate_check_totals`).

**N2.** **No** se va a tocar `business_settings` (las columnas siguen ahí, solo se deja de leer en el motor).

**N3.** **No** se va a crear `order_item_tax_lines`. Eso es PRD 2.

**N4.** **No** se va a hacer migración de datos.

**N5.** **No** se va a tocar la UI de reportes más allá de eliminar el hardcode 10.0.

**N6.** **No** se va a unificar el modelo de impuestos. Eso es PRD 2.

**N7.** **No** se va a tocar `fn_compute_item_totals`, `fn_add_item_from_menu`, ni ninguna RPC del backend.

---

## 4. Cambios concretos

### 4.1 Frontend — `sales_viewmodel.dart`

**Archivo:** `lib/presentation/sales/viewmodel/sales_viewmodel.dart`

#### 4.1.1 Eliminar constantes default

```dart
// BORRAR (líneas ~48-49):
static const _defaultTaxRatePct = 18.0;
static const _defaultServiceFeeRatePct = 10.0;
```

#### 4.1.2 Reemplazar el catch que silenciaba errores

```dart
// ANTES (líneas ~245-252):
try {
  final row = await Supabase.instance.client
      .from('business_settings')
      .select(...)
      .eq('business_id', businessId)
      .maybeSingle();
  _cachedTaxRatePct = (row?['default_tax_rate'] as num?)?.toDouble() ?? _defaultTaxRatePct;
  _cachedServiceFeeEnabled = row?['service_fee_enabled'] == true;
  _cachedServiceFeeRatePct = (row?['service_fee_rate'] as num?)?.toDouble() ?? _defaultServiceFeeRatePct;
  // ... continúa con taxes ...

// DESPUÉS:
try {
  final row = await Supabase.instance.client
      .from('business_settings')
      .select(...)
      .eq('business_id', businessId)
      .maybeSingle();
  
  // Validación: si row es null, no hay business_settings para este negocio
  if (row == null) {
    throw TaxConfigException(
      'No existe configuración fiscal para este negocio. '
      'Contactá al administrador.'
    );
  }
  
  // Lecturas sin defaults — si falta, fallar
  final defaultTaxRate = row['default_tax_rate'] as num?;
  if (defaultTaxRate == null) {
    throw TaxConfigException(
      'default_tax_rate no configurado para este negocio.'
    );
  }
  _cachedTaxRatePct = defaultTaxRate.toDouble();
  
  _cachedServiceFeeEnabled = row['service_fee_enabled'] == true;
  
  // service_fee_rate solo se valida si service_fee_enabled = true
  if (_cachedServiceFeeEnabled) {
    final sfRate = row['service_fee_rate'] as num?;
    if (sfRate == null) {
      throw TaxConfigException(
        'service_fee_rate no configurado pero service_fee_enabled = true.'
      );
    }
    _cachedServiceFeeRatePct = sfRate.toDouble();
  } else {
    _cachedServiceFeeRatePct = 0.0;  // explícito, no default
  }
  
  // ... continúa con taxes ...
  
  _cachedTaxConfigError = null;
  _state = _state.copyWith(taxConfigError: null);
} catch (e, st) {
  _logger.error('Falla al cargar configuración fiscal', e, st);
  _cachedBusinessTaxes = const [];
  _cachedTaxConfigError = e.toString();
  _state = _state.copyWith(taxConfigError: e.toString());
  rethrow;
}
```

#### 4.1.3 Crear excepción tipada

```dart
// Agregar al archivo o en un archivo de excepciones:
class TaxConfigException implements Exception {
  final String message;
  TaxConfigException(this.message);
  
  @override
  String toString() => 'TaxConfigException: $message';
}

class PaymentBlockedException implements Exception {
  final String message;
  PaymentBlockedException(this.message);
  
  @override
  String toString() => 'PaymentBlockedException: $message';
}
```

#### 4.1.4 Eliminar la heurística de emergencia

```dart
// BORRAR completamente el bloque (líneas ~425-441):
// if (pricingOrder.serviceFee == 0 && _isServiceFeeActiveForOrigin()) {
//   final estimatedService = totalTaxInOrder * (serviceRate / totalEffectiveRate);
//   pricingOrder = pricingOrder.copyWith(
//     tax: estimatedTax,
//     serviceFee: estimatedService,
//   );
// }
```

#### 4.1.5 Agregar campo `taxConfigError` al state

```dart
class CurrentOrderState {
  // ... campos existentes ...
  final String? taxConfigError;
  
  CurrentOrderState({
    // ... existentes ...
    this.taxConfigError,
  });
  
  CurrentOrderState copyWith({
    // ... existentes ...
    String? taxConfigError,
    bool clearTaxConfigError = false,
  }) {
    return CurrentOrderState(
      // ... existentes ...
      taxConfigError: clearTaxConfigError ? null : (taxConfigError ?? this.taxConfigError),
    );
  }
}
```

### 4.2 Frontend — `payment_viewmodel.dart`

**Archivo:** `lib/presentation/payments/viewmodel/payment_viewmodel.dart`

```dart
// Modificar processPayment para validar config:
Future<void> processPayment({
  required ...
}) async {
  // NUEVA validación al inicio:
  final salesState = ref.read(currentOrderProvider);
  if (salesState.taxConfigError != null) {
    throw PaymentBlockedException(
      'No se puede procesar el pago: ${salesState.taxConfigError}. '
      'Contactá al administrador.'
    );
  }
  
  // ... resto del código existente sin cambios ...
}
```

### 4.3 Frontend — UI banner de error

**Archivo nuevo:** `lib/presentation/sales/view/widgets/tax_config_error_banner.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class TaxConfigErrorBanner extends ConsumerWidget {
  const TaxConfigErrorBanner({super.key});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(currentOrderProvider);
    final error = state.taxConfigError;
    
    if (error == null) return const SizedBox.shrink();
    
    return MaterialBanner(
      backgroundColor: Colors.red.shade50,
      leading: Icon(Icons.error, color: Colors.red.shade700),
      content: Text(
        'Configuración fiscal no disponible. Los pagos están bloqueados.\n\n'
        'Detalle: $error',
        style: TextStyle(color: Colors.red.shade900),
      ),
      actions: [
        TextButton(
          onPressed: () {
            ref.read(currentOrderProvider.notifier)
              .reloadTaxConfiguration();
          },
          child: const Text('Reintentar'),
        ),
      ],
    );
  }
}
```

**Insertar el banner en las vistas de venta:**

```dart
// En sales_shell_view.dart o equivalente, en el Scaffold/Column:
Column(
  children: [
    const TaxConfigErrorBanner(),  // ← Agregar al inicio
    // ... resto del contenido existente
  ],
)
```

### 4.4 Frontend — `reports_repository.dart`

**Archivo:** `lib/data/repositories/reports_repository.dart`

#### 4.4.1 Eliminar el hardcode 10.0

```dart
// ANTES (línea ~1101):
'service_fee_rate': 10.0,

// DESPUÉS:
'service_fee_rate': serviceFeeRate, // ← variable real, no hardcoded
```

`serviceFeeRate` es la variable que ya se calcula arriba en la misma función (líneas 877-881). El bug es que se calculaba pero después se ignoraba. Solo hay que **usar la variable que ya existe**.

#### 4.4.2 Validación si configuración faltante

```dart
// En la lectura de business_settings (línea ~872):
final businessSettings = await _client
    .from('business_settings')
    .select('service_fee_enabled, service_fee_rate')
    .eq('business_id', businessId)
    .maybeSingle();

// Si no hay business_settings, esto NO debe romper el reporte
// pero sí debe ser visible al usuario:
if (businessSettings == null) {
  // En PRD 1: log + valor 0 explícito
  _logger.warn('business_settings no existe para business_id: $businessId');
  // Valores explícitos, no defaults mágicos
  serviceFeeEnabled = false;
  serviceFeeRate = 0.0;
}
```

#### 4.4.3 Eliminar el hardcode en línea 1101 (versión simple)

Si el contexto exacto del hardcode no permite la versión 4.4.1, alternativamente:

```dart
// Reemplazar:
'service_fee_rate': 10.0,
// Por:
'service_fee_rate': serviceFeeEnabled ? serviceFeeRate : 0.0,
```

### 4.5 Frontend — `taxes_view.dart`

**Archivo:** `lib/presentation/settings/more settings/system settings/tax/view/taxes_view.dart`

Verificar que no quede UI muerta del antiguo toggle "¿Es Propina de Ley?". Si todavía hay código del toggle (aunque oculto), eliminarlo completamente.

### 4.6 Frontend — Eliminar carpeta vacía duplicada

**Borrar:** `lib/presentation/settings/taxes/` (la carpeta vacía con archivos de 1 línea).

### 4.7 Backend — Drop trigger duplicado

**Migración SQL:**

```sql
-- Verificar primero qué triggers existen:
SELECT tgname FROM pg_trigger 
WHERE tgrelid = 'public.order_items'::regclass
  AND tgname LIKE '%compute_item_totals%';

-- Resultado esperado:
-- tr_compute_item_totals
-- trg_compute_item_totals
-- ↑ Duplicados

-- Drop el de nombre más viejo (mantener el más nuevo):
DROP TRIGGER IF EXISTS tr_compute_item_totals ON public.order_items;

-- Verificar que solo queda uno:
SELECT tgname FROM pg_trigger 
WHERE tgrelid = 'public.order_items'::regclass
  AND tgname LIKE '%compute_item_totals%';
-- Debe retornar solo: trg_compute_item_totals
```

---

## 5. Test Plan

### 5.1 Tests dorados (golden tests)

**Archivo nuevo:** `test/pricing/golden_test.dart`

Estos tests **congelan el comportamiento actual** del sistema. Algunos van a fallar (los que ejercen el bug), otros van a pasar. **Esto es esperado y deseado.** Los que fallan documentan el bug; los que pasan documentan el comportamiento correcto.

```dart
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Stop-the-bleeding: comportamiento congelado', () {
    
    test('B1: Producto 750 inclusive con ITBIS 18% en zone', () {
      // Documenta el comportamiento actual
      // Expectation: subtotal=635.59, tax=114.41, total=750
    });
    
    test('B2: Producto 750 inclusive con ITBIS 18% + Propina 10% en zone', () {
      // Expectation: subtotal=585.94, tax=105.47, serviceFee=58.59, total=750
    });
    
    test('B3: Producto 750 con ITBIS 18% en quick (sin propina)', () {
      // Expectation: NO debe haber propina aunque esté configurada
    });
    
    test('B4: Sin impuestos configurados, producto 750', () {
      // Expectation: subtotal=750, tax=0, serviceFee=0, total=750
      // ← Este test va a FALLAR si el sistema todavía aplica defaults
    });
    
    test('B5: Configuración fiscal corrupta lanza excepción', () {
      // Expectation: TaxConfigException al cargar config sin business_settings
    });
    
    test('B6: Pago bloqueado si taxConfigError no es null', () {
      // Expectation: PaymentBlockedException
    });
    
    test('B7: Reporte fiscal NO devuelve service_fee_rate hardcoded', () {
      // Expectation: si negocio tiene service_fee_rate = 8, reporte muestra 8
    });
  });
}
```

### 5.2 Tests manuales (UAT)

Antes del deploy a producción, ejecutar en staging con un negocio piloto restaurado:

| Caso | Pasos | Esperado |
|---|---|---|
| UAT-1 | Hacer venta normal con configuración válida | Funciona como hoy |
| UAT-2 | Borrar fila de `business_settings` para un negocio en staging, intentar venta | Banner de error visible, pago bloqueado |
| UAT-3 | Restaurar `business_settings`, hacer click en "Reintentar" | Banner desaparece, pago habilitado |
| UAT-4 | Configurar service_fee_rate = 8 en staging, ver reporte fiscal | Reporte muestra 8%, no 10% |
| UAT-5 | Verificar que las 4,382 órdenes históricas siguen mostrando los mismos totales | Sin cambios |

### 5.3 Test de regresión

```sql
-- En staging después del deploy, verificar:
-- Suma de totales antes y después debe ser idéntica para órdenes históricas

-- ANTES (capturar previo al deploy):
SELECT business_id, SUM(total) FROM orders WHERE status = 'paid' GROUP BY business_id;

-- DESPUÉS (post deploy):
SELECT business_id, SUM(total) FROM orders WHERE status = 'paid' GROUP BY business_id;

-- Resultado esperado: idénticos
```

---

## 6. Rollout Plan

### Día 1: Preparación

- [ ] Validar todos los prerrequisitos de Sección 2
- [ ] Crear branch `prd/01-stop-the-bleeding`
- [ ] Capturar línea base de métricas en producción:
  - Total de órdenes pagadas hoy
  - Total de service_fee cobrado hoy
  - Total de tax cobrado hoy
- [ ] Comunicar a operadores: "Esta semana habrá ajustes técnicos."

### Día 2: Implementación frontend

- [ ] Aplicar cambios 4.1 (sales_viewmodel.dart)
- [ ] Aplicar cambios 4.2 (payment_viewmodel.dart)
- [ ] Aplicar cambios 4.3 (banner UI)
- [ ] Tests unitarios pasan localmente
- [ ] Commit + push

### Día 3: Implementación reportes y limpieza

- [ ] Aplicar cambios 4.4 (reports_repository.dart)
- [ ] Aplicar cambios 4.5 (taxes_view.dart cleanup)
- [ ] Aplicar cambios 4.6 (borrar carpeta vacía)
- [ ] Aplicar cambios 4.7 (drop trigger duplicado en STAGING primero)
- [ ] Tests dorados (Sección 5.1) escritos
- [ ] Commit + push

### Día 4: QA en staging

- [ ] Deploy a staging
- [ ] Ejecutar todos los UATs (Sección 5.2)
- [ ] Test de regresión SQL (Sección 5.3)
- [ ] Validar que tests dorados pasan/fallan según lo esperado
- [ ] Si todo OK: PR para merge a main

### Día 5: Deploy a producción

- [ ] Merge a main
- [ ] **Pre-deploy:** snapshot SQL de `orders.total` para los 4-15 negocios
- [ ] Deploy a producción (orden: 1 piloto pequeño, 1 hora de observación, resto)
- [ ] Aplicar drop trigger duplicado en producción
- [ ] **Post-deploy:** snapshot SQL nuevamente, verificar checksum coincide
- [ ] Comunicar a operadores: "Listo. Avisame cualquier irregularidad."
- [ ] Monitoreo intensivo las primeras 4 horas

---

## 7. Rollback Plan

### Si falla en staging (Día 4)

- Revertir branch
- Investigar causa
- No bloquea cronograma del programa (semana 1 puede correrse a semana 2)

### Si falla en producción (Día 5+)

**Síntomas que disparan rollback inmediato:**
- 1 operador reporta "no puedo cobrar"
- Más de 3 errores de `PaymentBlockedException` en menos de 1 hora (puede indicar config rota generalizada)
- Cualquier discrepancia en el checksum SQL pre/post deploy

**Procedimiento:**

1. `git revert <commit>` en main
2. Re-deploy del revert
3. Re-ejecutar trigger SQL para restaurar el duplicado **si fue droppeado**:

```sql
-- Si fue necesario revertir, recrear el trigger duplicado para mantener comportamiento idéntico:
CREATE TRIGGER tr_compute_item_totals
BEFORE INSERT OR UPDATE ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.fn_compute_item_totals();
-- (Solo si fue necesario por alguna razón)
```

4. Comunicación inmediata a operadores: "Detectamos un problema, revertido. Estamos investigando."
5. Post-mortem dentro de 48 horas

---

## 8. Definition of Done

PRD 1 se considera completado cuando:

- [ ] Todos los cambios de Sección 4 aplicados
- [ ] Tests dorados de Sección 5.1 escritos y corriendo en CI
- [ ] UATs de Sección 5.2 ejecutados con éxito en staging
- [ ] Test de regresión de Sección 5.3 pasa
- [ ] Deploy a producción completado sin rollback
- [ ] Comunicación de cierre enviada a operadores
- [ ] 1 semana de observación sin regresiones reportadas
- [ ] Métricas comparadas (línea base vs post-deploy) sin desviaciones inexplicables
- [ ] Documento `PRD_01_POSTMORTEM.md` creado con lecciones aprendidas

Solo cuando todos estos checkboxes estén marcados, **PRD 2 puede iniciarse**.

---

## 9. Decision Log

| # | Fecha | Decisión | Razón |
|---|---|---|---|
| AD1-1 | 2026-04-26 | Fail-loud en vez de defaults silenciosos | Mejor bloquear que cobrar mal |
| AD1-2 | 2026-04-26 | NO refactorizar motor en este PRD | Scope discipline; eso es PRD 2 |
| AD1-3 | 2026-04-26 | Drop trigger duplicado incluido | Es low-risk y elimina overhead doble |
| AD1-4 | 2026-04-26 | Banner UI persistente para errores fiscales | Operador debe ver el problema, no solo el dev |
| AD1-5 | 2026-04-26 | Tests dorados antes de cambios, no después | Capturan el comportamiento "antes" para detectar regresiones |
| AD1-6 | 2026-04-26 | Comunicación previa a operadores obligatoria | Pueden notar el bloqueo inesperado y tener contexto |
| AD1-7 | 2026-04-26 | Rollback inmediato ante 1 reporte de operador | En P0 fiscal, mejor revertir y diagnosticar que insistir |

---

*PRD 1 generado el 2026-04-26.*
*Este documento es ejecutable. No improvisar fuera del scope definido.*
