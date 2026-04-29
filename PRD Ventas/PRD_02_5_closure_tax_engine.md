# PRD 2.5 — Closure: Tax Engine Consolidation

| Campo | Valor |
|---|---|
| **Programa** | Estabilización Fiscal MangoPOS |
| **PRD** | 2.5 (closure de PRD 2) |
| **Versión** | 1.0 |
| **Fecha** | 2026-04-29 |
| **Autor** | Cristian (DRI) |
| **Estado** | Aprobado para ejecución (sistema aislado) |
| **Prioridad** | P0 |
| **Esfuerzo estimado** | 9-13 horas (3 fases) |
| **Riesgo** | Alto (toca motor de pricing) |

---

## 1. Executive Summary

PRD 2 quedó parcialmente implementado. Las decisiones AD2-5, AD2-7 y la simplificación frontend nunca se ejecutaron, dejando un modelo dual `tax` vs `service_fee` que hoy genera bugs visibles:

- El 10% De Ley en Venta Rápida no aparece en el breakdown (aunque se cobra en el total).
- El frontend tiene paths separados para inclusive/exclusive con/sin service fee, multiplicando casos a mantener.
- El motor backend escribe en dos lugares (`oi.tax` + `orders.service_fee`) lo que conceptualmente es un solo número.
- Cualquier nuevo developer encuentra dos modelos coexistiendo y se confunde.

Este PRD **cierra PRD 2** de manera definitiva: una sola variable (`tax`), una sola tabla snapshot (`order_item_tax_lines`), un solo path de cálculo. `service_fee` queda deprecado a 0 siempre.

---

## 2. Goals y Non-Goals

### 2.1 Goals

1. `oi.tax_rate` consolida TODOS los impuestos aplicables (regulares + service fees), filtrados por `apply_on_<origin>`.
2. `oi.tax_lines` se popula con UNA fila por impuesto aplicado (incluyendo los service fees).
3. `orders.service_fee = 0` y `order_checks.service_fee = 0` siempre, para nuevas órdenes.
4. Frontend `summarizeItemPricing` simplificado: una sola rama de cálculo, sin distinción service_fee.
5. Tests dorados verifican paridad Quick = Zone = Manual = Delivery para mismos productos+impuestos.
6. `business_settings.service_fee_*` y `service_fee_enabled` quedan como columnas inertes (no se borran de DB para evitar romper queries históricas, pero ningún código las lee).

### 2.2 Non-Goals

- No se backfillean órdenes históricas (siguen el modelo viejo en sus snapshots).
- No se borran columnas de DB (`orders.service_fee`, `business_settings.service_fee_*`). Quedan como dead columns.
- No se refactorea `OfflinePosService` (deuda técnica separada).
- No se cambia la UI de Ajustes > Impuestos (el toggle per-area ya escribe a `taxes.apply_on_<origin>` que es la fuente correcta).

---

## 3. Arquitectura objetivo

### 3.1 Backend

**Antes (modelo dual)**:
```
fn_add_item_from_menu:
  - Resolver tax_rate solo de taxes regulares (excluye service fees)
  - Resolver service_fee_rate aparte
  - INSERT con oi.tax_rate = solo regulares
  - oi.tax = subtotal × oi.tax_rate / 100  (excluye service fee)

calculate_order_totals:
  - SUM(oi.tax) para tax
  - Calcular service_fee aparte (SUM subtotal × tasa)
  - orders.tax = sum
  - orders.service_fee = calculado
  - orders.total = subtotal + tax + service_fee - discounts
```

**Después (modelo unificado)**:
```
fn_add_item_from_menu:
  - Resolver tax_rate de TODOS los taxes aplicables (regulares + service fees)
    filtrados por apply_on_<origin>
  - INSERT con oi.tax_rate = total
  - oi.tax = subtotal × oi.tax_rate / 100  (incluye TODO)
  - INSERT en oi.tax_lines: una fila por cada tax aplicado

calculate_order_totals:
  - SUM(oi.tax) para tax
  - orders.tax = sum
  - orders.service_fee = 0  (siempre)
  - orders.total = subtotal + tax - discounts
```

### 3.2 Frontend

**Antes**:
```dart
summarizeItemPricing → tiene rama inclusive con cálculo de service_fee separado
                    + rama exclusive con resolveOrderServiceRate desde order
                    + lógica de "shouldShowServiceFee = origin != quick"

OrderItemPricingSummary tiene: subtotal, tax, serviceFee, extraServiceFee, total
OrderPricingSummary tiene: subtotal, tax, serviceFee, extraServiceFee, total

buildOrderTaxBreakdown lee tax_lines (no incluye service_fee porque el motor no lo escribe ahí)
```

**Después**:
```dart
summarizeItemPricing → una sola rama: subtotal, tax (de oi.tax), discounts, total
                    Sin distinción inclusive/exclusive en el cálculo del total
                    (la diferencia es solo en cómo se EXTRAE subtotal del precio)

OrderItemPricingSummary tiene: subtotal, tax, total (sin serviceFee)
OrderPricingSummary tiene: subtotal, tax, total

buildOrderTaxBreakdown lee tax_lines (que ahora incluye service fees como una más)
```

---

## 4. Plan por fases

### Fase 1 — Backend: modelo unificado (4-5 horas)

#### F1.1 — Refactor `fn_resolve_order_item_tax_profile`
- Eliminar `coalesce(t.is_service_fee, false) = false` filter.
- Sumar TODOS los taxes activos asignados al producto, filtrados por `apply_on_<origin>`.

#### F1.2 — Refactor `fn_add_item_from_menu`
- Remover lógica separada de `v_service_fee_rate` y `v_full_tax_rate`.
- `oi.tax_rate` y `oi.original_tax_rate` ambos = la suma total filtrada por origin.
- Después del INSERT del item: poblar `order_item_tax_lines` con una fila por cada tax aplicado (regulares + service fees), via función helper nueva `fn_populate_item_tax_lines(p_item_id, p_origin)`.

#### F1.3 — Refactor `calculate_order_totals` y `calculate_check_totals`
- Borrar todo el bloque `IF _sf_enabled THEN...` y la lógica de `_has_per_tax_sf`/legacy.
- `_service_fee := 0` siempre.
- `orders.service_fee = 0`, `order_checks.service_fee = 0`.

#### F1.4 — Trigger `fn_compute_item_totals`
- Sin cambios funcionales (sigue calculando `oi.tax = subtotal × tax_rate / 100`). Pero ahora `tax_rate` ya incluye el 10% Ley, así que `oi.tax` cubre todo automáticamente.

#### F1.5 — Migration
Archivo: `supabase/migrations/20260430_0001_prd2_closure_unified_tax.sql`

Incluye:
- Las 4 funciones refactorizadas.
- Helper `fn_populate_item_tax_lines`.
- DO block que recalcula todas las órdenes abiertas (forzando re-poblar tax_lines + recompute totales).
- Set `orders.service_fee = 0` y `order_checks.service_fee = 0` para órdenes abiertas.

**Riesgo F1**: alto. Si hay un error en la refactorización, todas las órdenes en vuelo dan totales incorrectos. Mitigación: deploy en horario muerto + script de rollback.

### Fase 2 — Frontend: simplificación (4-6 horas)

#### F2.1 — Refactor `summarizeItemPricing` (`order_pricing_utils.dart`)
- Eliminar la rama completa `if (item.taxMode == 'inclusive') { ... }` que calcula serviceFee aparte.
- Para inclusive: solo extraer base. `tax = item.tax` (que ya viene del backend con todo incluido).
- Eliminar `serviceFee` como campo separado del retorno.
- Eliminar `resolveOrderServiceRate(order)` (ya no se necesita — `order.serviceFee` siempre será 0).
- Eliminar `extraServiceFee` (deprecado).

#### F2.2 — Eliminar `serviceFee` de structs
- `OrderItemPricingSummary`: borrar campos `serviceFee`, `extraServiceFee`.
- `OrderPricingSummary`: borrar campos `serviceFee`, `extraServiceFee`.

#### F2.3 — Grep y actualizar callers
- Buscar `summary.serviceFee`, `summary.extraServiceFee` en todo `lib/`.
- Cualquier UI que sumaba/mostraba serviceFee separado: simplificar para que el breakdown de impuestos se renderee directamente desde `tax_lines` (donde ahora aparece el 10% Ley naturalmente).

#### F2.4 — Eliminar `shouldShowServiceFee` flag
- Borrar `bool shouldShowServiceFee = ...` y todo el branching que filtraba service fee por origin en el frontend.

**Riesgo F2**: medio. Cualquier widget que lea `summary.serviceFee` rompe. Tests + grep cuidadoso lo mitigan.

### Fase 3 — Tests dorados (3-4 horas)

Nuevo archivo `test/sales/cross_origin_tax_parity_test.dart`:

```dart
group('Cross-origin tax parity (PRD 2.5 DoD)', () {
  // Setup: producto X con ITBIS 18% + Propina 10%, todos apply_on_*=true
  // Assert: precio idéntico en zone/manual/quick/delivery

  test('exclusive product, all origins return same total', () {...});
  test('inclusive product, all origins return same total', () {...});
  test('product with modifier, all origins return same total', () {...});
  test('apply_on_quick=false excludes tax in quick only', () {...});
  test('takeout flag excludes service fee in all origins', () {...});
  test('discount applied identically across origins', () {...});
});
```

Tests en SQL adicionales (en migration o aparte):
- `pgTAP` o asserts via DO block que verifican que para mismos productos, distintas sesiones (origin distinto) producen totales idénticos.

**Riesgo F3**: bajo. Solo agrega tests.

---

## 5. Test Plan

### 5.1 Tests dorados (CI gate)

```dart
// Caso 1: Agua Dasany (50, exclusive, ITBIS 18 + Ley 10), origin=quick
// Esperado: subtotal 50, tax 14, total 64
// tax_lines: [{ITBIS, 18, 9}, {10% De Ley, 10, 5}]

// Caso 2: Mismo producto, origin=dine_in
// Esperado: idéntico al caso 1

// Caso 3: Mismo producto, origin=delivery con apply_on_delivery=false para Ley
// Esperado: subtotal 50, tax 9, total 59 (sin Ley)
// tax_lines: [{ITBIS, 18, 9}]

// Caso 4: MARGARITAS (450 + chinola 600, exclusive, ITBIS 18 + Ley 10)
// Esperado: subtotal 1050, tax 294, total 1344
// tax_lines: [{ITBIS, 18, 189}, {10% De Ley, 10, 105}]

// Caso 5: Item takeout (no aplica Ley)
// Esperado: tax solo ITBIS
```

### 5.2 UAT manual

1. Habilitar 10% Ley en Quick (ya hecho).
2. Crear nueva Venta Rápida → agregar Agua Dasany.
3. **Esperado en cart**: Subtotal 50 + ITBIS (18%) 9 + 10% De Ley (10%) 5 + Total 64.
4. Cobrar.
5. Repetir en Zone, Manual: idénticos números.
6. Repetir en Delivery (con apply_on_delivery=false para Ley): solo ITBIS.

### 5.3 Tests de regresión

- Modal de pago: total mostrado coincide con cart.
- Factura impresa: breakdown coincide.
- Pre-cuenta impresa: breakdown coincide.
- Reportes financieros (PRD 3): suma de tax_lines = orders.tax.

---

## 6. Rollout Plan

1. **Pre-deploy**: backup completo de DB.
2. **Deploy backend (F1)** en horario muerto (recomendado: 3-5 AM hora local).
3. **Verificar migration**: query control que recalcule manualmente una orden y compare con lo que dejó la migration.
4. **Deploy frontend (F2)** después de F1 estable (mínimo 1 hora de observación).
5. **Aplicar tests dorados (F3)** en CI antes del próximo deploy a main.

---

## 7. Rollback Plan

Si F1 falla post-deploy:

```sql
-- Revertir las funciones a la versión pre-PRD-2.5 (= versión actual de hoy)
-- Disponible en supabase/migrations/20260429_0001_unify_service_fee_per_tax.sql
-- Re-aplicar ese archivo restaura el modelo dual.
```

Si F2 falla post-deploy:
```bash
git revert <commit-hash-frontend>
flutter clean && flutter run
```

Las órdenes ya cobradas con el modelo nuevo NO se afectan por el rollback (sus tax_lines persisten correctos).

---

## 8. Risks

| # | Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|---|
| R1 | Migration F1 corrompe órdenes en vuelo | Media | Alto | Deploy en horario muerto. Backup DB previo. |
| R2 | `summarizeItemPricing` simplificado rompe inclusive math | Media | Alto | Tests dorados + UAT con productos inclusive antes de merge. |
| R3 | Algún caller olvidado de `summary.serviceFee` rompe la UI | Alta | Medio | Grep exhaustivo + flutter analyze. |
| R4 | Reportes de PRD 3 (si ya están deployados) leen `orders.service_fee` esperando valor | Media | Alto | Verificar antes de F1: si reportes leen ese campo, agregar fallback `COALESCE(o.service_fee, 0) + SUM(tax_lines de service fees)`. |
| R5 | Customers que ya esperaban ver "Propina" como línea separada en factura ahora la ven dentro de "ITBIS" o agrupada | Baja | Bajo | El breakdown desde tax_lines mantiene el nombre del impuesto ("10% De Ley") como línea propia. |

---

## 9. Definition of Done

PRD 2.5 está completo cuando:

- [ ] Migration F1 aplicada sin error en producción.
- [ ] `orders.service_fee = 0` para todas las órdenes nuevas.
- [ ] `oi.tax_lines` contiene service fees como filas regulares (verificar con SQL).
- [ ] Frontend deployado con `summarizeItemPricing` simplificado.
- [ ] `summary.serviceFee` y `summary.extraServiceFee` borrados del codebase.
- [ ] Tests dorados de paridad cross-origin pasando 100%.
- [ ] UAT 5.2 ejecutado con éxito.
- [ ] 1 semana de observación post-deploy sin regresiones.
- [ ] Update STATE_OF_THE_PLATFORM.md marcando PRD 2 como cerrado.

---

## 10. Decision Log

| # | Fecha | Decisión | Razón |
|---|---|---|---|
| AD2.5-1 | 2026-04-29 | NO borrar columnas DB `orders.service_fee`, `business_settings.service_fee_*` | Reportes históricos pueden depender. Las dejamos inertes en 0. |
| AD2.5-2 | 2026-04-29 | NO backfillear órdenes históricas | Inmutabilidad — sus snapshots quedan como están. |
| AD2.5-3 | 2026-04-29 | Service fees pasan a tax_lines como filas regulares | Una fuente de verdad para el breakdown. |
| AD2.5-4 | 2026-04-29 | Helper `fn_populate_item_tax_lines` separado | Reutilizable: hoy lo llama add_item, mañana lo puede llamar update_item o cualquier otro path. |
| AD2.5-5 | 2026-04-29 | Tests dorados son CI gate, no opcional | Sin tests no hay garantía de que Quick = Zone se mantenga. |

---

## 11. Próximos pasos inmediatos

1. **F1**: escribir migration `supabase/migrations/20260430_0001_prd2_closure_unified_tax.sql`. Aplicar.
2. **F2**: refactorear `order_pricing_utils.dart` + actualizar callers via grep. Hot restart.
3. **Smoke test manual** Quick: verificar 10% Ley aparece en breakdown.
4. **F3**: escribir tests dorados. Correr `flutter test`.
5. **Commit + PR** con todos los cambios. Revisión cuidadosa antes de merge.

---

*PRD 2.5 generado el 2026-04-29 como closure de PRD 2 que quedó parcialmente implementado.*
