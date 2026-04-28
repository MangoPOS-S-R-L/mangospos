# PRD 2 — Refactor del Motor de Impuestos

| Campo | Valor |
|---|---|
| **Programa** | Estabilización Fiscal MangoPOS |
| **PRD** | 2 de 3 |
| **Versión** | 1.0 |
| **Fecha** | 2026-04-26 |
| **Autor** | Cristian (DRI) |
| **Estado** | Draft (validar al finalizar PRD 1) |
| **Prioridad** | P0 |
| **Esfuerzo estimado** | 4-5 semanas full-time |
| **Riesgo** | **Alto** |

---

## Tabla de Contenidos

1. [Executive Summary](#1-executive-summary)
2. [Antes de empezar (prerrequisitos)](#2-antes-de-empezar-prerrequisitos)
3. [Goals y Non-Goals](#3-goals-y-non-goals)
4. [Arquitectura objetivo](#4-arquitectura-objetivo)
5. [Plan por fases](#5-plan-por-fases)
6. [Cambios técnicos detallados](#6-cambios-técnicos-detallados)
7. [Test Plan](#7-test-plan)
8. [Rollout Plan](#8-rollout-plan)
9. [Rollback Plan](#9-rollback-plan)
10. [Risks](#10-risks)
11. [Open Questions](#11-open-questions)
12. [Definition of Done](#12-definition-of-done)
13. [Decision Log](#13-decision-log)

---

## 1. Executive Summary

PRD 1 detuvo el daño inmediato eliminando defaults peligrosos. Este PRD ataca la **causa raíz arquitectónica**: existen tres sistemas paralelos calculando propina (frontend, RPCs backend, sistema de reportes), cada uno con su propia lógica.

Este PRD consolida todo en **un solo motor unificado** con la regla simple: **la tabla `taxes` es la única fuente de verdad para impuestos**. Cualquier impuesto se filtra por origin según sus flags. No hay heurísticas. No hay defaults. No hay tres caminos.

**Cambios estructurales:**

1. **Backend:** `calculate_order_totals` y `calculate_check_totals` se consolidan en una función. La lectura de `business_settings.service_fee_*` se elimina. Los CASE statements con valores fantasma del enum se eliminan.

2. **Frontend:** `summarizeItemPricing` se simplifica. El concepto de `service_fee` separado de `tax` desaparece — todos son impuestos.

3. **Datos:** se crea `order_item_tax_lines` para auditoría detallada por impuesto. **No se backfillea** en este PRD (es PRD 3).

**Resultado al final:** un sistema donde cualquier impuesto futuro se agrega configurándolo en la UI, sin tocar código.

---

## 2. Antes de empezar (prerrequisitos)

### 2.1 PRD 1 completado

- [ ] PRD 1 deployado a producción
- [ ] 1 semana mínima de observación post-PRD-1 sin regresiones
- [ ] Postmortem de PRD 1 escrito con lecciones aprendidas
- [ ] Tests dorados de PRD 1 pasando en CI

### 2.2 Datos al día

- [ ] Snapshot completo de producción restaurado en staging
- [ ] Datos de los 4-15 negocios piloto disponibles para testing realista

### 2.3 Backups y rollback

- [ ] Backup automático de producción funcionando
- [ ] Restore probado en los últimos 14 días
- [ ] Plan de rollback de este PRD revisado

### 2.4 Decisiones pendientes resueltas

- [ ] Decisión sobre `self_service` origin (ver Open Questions)
- [ ] Decisión sobre los 47 productos sin `menu_item_taxes`
- [ ] Decisión sobre los 7 items históricos con `tax_rate = 0`

### 2.5 Espacio mental

- [ ] Sin compromisos de WFM o personales mayores en las próximas 5 semanas
- [ ] Disponibilidad real full-time confirmada

---

## 3. Goals y Non-Goals

### 3.1 Goals

**G1.** Consolidar `calculate_order_totals` y `calculate_check_totals` en una sola función con la misma lógica.

**G2.** Eliminar la lectura de `business_settings.service_fee_enabled/rate/on_zone/on_manual/on_quick/on_delivery` en backend (RPCs) y frontend (sales_viewmodel).

**G3.** Eliminar los CASE statements en SQL que referencian valores que no existen en el enum `order_origin` (`'table'`, `'zone'`, `'manual_order'`, etc.).

**G4.** Eliminar los fallbacks de 10% en `fn_add_item_from_menu`.

**G5.** Crear tabla `order_item_tax_lines` y poblarla **prospectivamente** desde el momento del deploy (sin backfill de históricos).

**G6.** Modelo unificado: en frontend, todos los impuestos se tratan igual. El concepto separado de "service fee" deja de existir como path de código diferente.

**G7.** Eliminar el getter `effectiveIsServiceFee` y la heurística por nombre/tasa.

**G8.** Estandarizar precisión a 2 decimales en todos los outputs persistidos.

**G9.** Tests dorados completos del motor nuevo, cubriendo modo inclusive, exclusive, y todos los origins.

**G10.** Documentar la nueva arquitectura para devs futuros.

### 3.2 Non-Goals

**N1.** **No** se hace backfill de `order_item_tax_lines` para órdenes históricas. Esto es PRD 3.

**N2.** **No** se elimina la columna `service_fee` de `orders` y `order_checks` en este PRD (queda deprecada, drop en PRD 3).

**N3.** **No** se eliminan las columnas de `business_settings` (`service_fee_*`, `default_tax_rate`). Quedan deprecadas, drop en PRD 3.

**N4.** **No** se refactoriza el sistema de reportes (PRD 3).

**N5.** **No** se cambia el schema de `taxes` (queda como está).

**N6.** **No** se implementa `self_service`. Queda con comportamiento indefinido (origin no debe llegar a producción hasta que se diseñe).

**N7.** **No** se migra `original_tax_rate`. Sigue usándose para cálculo inclusive como mecanismo válido.

---

## 4. Arquitectura objetivo

### 4.1 Estado actual (problema)

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│   FRONTEND (sales_viewmodel.dart)                                │
│   ├─ Lee business_settings.service_fee_*                         │
│   ├─ Lee taxes                                                   │
│   ├─ summarizeItemPricing tiene path para service_fee separado   │
│   └─ Heurística effectiveIsServiceFee                            │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                                                                    
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│   BACKEND RPCS                                                   │
│   ├─ fn_compute_item_totals (trigger por item) ✓ OK              │
│   ├─ fn_add_item_from_menu                                       │
│   │   ├─ Lee menu_item_taxes ✓ OK                                │
│   │   ├─ Lee taxes con is_service_fee=true                       │
│   │   └─ FALLBACK a business_settings.service_fee_*              │
│   ├─ fn_resolve_order_item_tax_profile                           │
│   │   └─ Lee menu_item_taxes ✓ OK                                │
│   ├─ calculate_order_totals                                      │
│   │   └─ Lee business_settings.service_fee_rate                  │
│   └─ calculate_check_totals                                      │
│       └─ Lee business_settings.service_fee_*                     │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘

PROBLEMA: Tres lugares pueden calcular service_fee con lógicas diferentes.
```

### 4.2 Estado objetivo

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│   FRONTEND (sales_viewmodel.dart)                                │
│   ├─ Lee SOLO taxes                                              │
│   ├─ summarizeItemPricing trata todos los impuestos uniformemente│
│   └─ Sin heurísticas                                             │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                                                                    
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│   BACKEND RPCS                                                   │
│   ├─ fn_compute_item_totals (sin cambios)                        │
│   ├─ fn_add_item_from_menu                                       │
│   │   ├─ Lee menu_item_taxes                                     │
│   │   └─ Lee taxes con is_service_fee=true (sin fallback)        │
│   ├─ fn_resolve_order_item_tax_profile (sin cambios)             │
│   └─ fn_recalc_totals (NUEVA, consolida las 2 anteriores)        │
│       └─ Lee SOLO taxes                                          │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│   NUEVA TABLA: order_item_tax_lines                              │
│   ├─ Trazabilidad por impuesto y por item                        │
│   ├─ Snapshot de tax_name y tax_rate al momento de la venta      │
│   └─ Poblada por trg_compute_item_totals (modificado)            │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘

Una sola fuente de verdad: taxes.
Una sola función de recálculo: fn_recalc_totals.
Una sola lógica: la del enum order_origin (5 valores reales).
```

---

## 5. Plan por fases

PRD 2 se ejecuta en 5 sub-fases, cada una con su criterio go/no-go.

### F2.1 — Diseño y validación (3 días)

- [ ] Diagrama detallado de cambios
- [ ] Schema de `order_item_tax_lines` finalizado
- [ ] Casos de uso de los 5 origins documentados
- [ ] OQ-1, OQ-2, OQ-3 (sección 11) resueltas
- [ ] Validación de plan con vos mismo (relectura crítica del documento)

**Go/No-Go:** Si alguna OQ queda sin resolver, no avanzar.

### F2.2 — Backend: tabla nueva y consolidación (5 días)

- [ ] Crear `order_item_tax_lines` en staging
- [ ] Crear `fn_recalc_totals` que reemplaza las 2 anteriores
- [ ] Modificar `fn_compute_item_totals` para escribir a `order_item_tax_lines`
- [ ] Modificar `fn_add_item_from_menu` (eliminar fallback business_settings)
- [ ] Tests SQL de paridad (resultados nuevo vs viejo)

**Go/No-Go:** Test de paridad debe pasar al 100%.

### F2.3 — Frontend: motor unificado (5 días)

- [ ] Refactor de `tax_engine.dart` (resolveTaxRates simplificado)
- [ ] Refactor de `order_pricing_utils.dart` (summarizeItemPricing simplificado)
- [ ] Eliminación de `effectiveIsServiceFee` y heurísticas
- [ ] Eliminación de lectura de `business_settings.service_fee_*`
- [ ] Tests dorados frontend pasando

**Go/No-Go:** Tests dorados pasan + paridad frontend↔backend al 100%.

### F2.4 — Integración y QA (5 días)

- [ ] Deploy a staging completo
- [ ] UAT con datos de producción restaurados
- [ ] Test de regresión histórica (totales no cambian para órdenes viejas)
- [ ] Performance test (queries no más lentas que antes)
- [ ] Documentación de la nueva arquitectura

**Go/No-Go:** UAT exitoso + sin regresiones detectadas.

### F2.5 — Deploy a producción (3 días)

- [ ] Backup de producción
- [ ] Deploy gradual (1 negocio piloto, luego resto)
- [ ] Monitoreo intensivo
- [ ] Comunicación con operadores

**Go/No-Go:** 48 horas sin reportes negativos = éxito.

---

## 6. Cambios técnicos detallados

### 6.1 Schema: nueva tabla `order_item_tax_lines`

```sql
CREATE TABLE public.order_item_tax_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_item_id uuid NOT NULL REFERENCES public.order_items(id) ON DELETE CASCADE,
  tax_id uuid NOT NULL REFERENCES public.taxes(id) ON DELETE RESTRICT,
  tax_name text NOT NULL,
  tax_rate numeric(7,4) NOT NULL,
  amount numeric(12,2) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_oitl_item ON public.order_item_tax_lines(order_item_id);
CREATE INDEX idx_oitl_tax ON public.order_item_tax_lines(tax_id);
CREATE INDEX idx_oitl_created ON public.order_item_tax_lines(created_at);

-- RLS policy: heredada del business_id vía join con order_items → orders → table_sessions
ALTER TABLE public.order_item_tax_lines ENABLE ROW LEVEL SECURITY;

CREATE POLICY oitl_select ON public.order_item_tax_lines
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.order_items oi
      JOIN public.orders o ON o.id = oi.order_id
      JOIN public.table_sessions ts ON ts.id = o.session_id
      WHERE oi.id = order_item_tax_lines.order_item_id
        AND ts.business_id IN (
          SELECT business_id FROM public.user_businesses 
          WHERE user_id = auth.uid()
        )
    )
  );
```

**Decisión de diseño:** `tax_name` y `tax_rate` son **snapshot al momento de la venta**. Si después cambia el nombre o tasa del impuesto, los datos históricos no cambian.

### 6.2 Backend: nueva función `fn_recalc_totals`

```sql
CREATE OR REPLACE FUNCTION public.fn_recalc_totals(_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  _origin text;
  _biz_id uuid;
BEGIN
  -- Obtener contexto
  SELECT 
    ts.origin::text,
    ts.business_id
  INTO _origin, _biz_id
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE o.id = _order_id;

  -- Recalcular totales de cada check de la orden
  -- Usando una sola lógica unificada
  WITH check_totals AS (
    SELECT 
      oi.check_id,
      SUM(oi.subtotal) as subtotal,
      SUM(oi.tax) as tax,
      SUM(oi.discounts) as discounts,
      SUM(oi.subtotal + oi.tax - oi.discounts) as total
    FROM public.order_items oi
    WHERE oi.order_id = _order_id
      AND oi.status NOT IN ('void')
      AND oi.check_id IS NOT NULL
    GROUP BY oi.check_id
  )
  UPDATE public.order_checks oc SET
    subtotal = ROUND(ct.subtotal, 2),
    tax = ROUND(ct.tax, 2),
    discounts = ROUND(ct.discounts, 2),
    service_fee = 0,  -- ← Siempre 0; los service fees están en tax ahora
    total = ROUND(ct.total, 2)
  FROM check_totals ct
  WHERE oc.id = ct.check_id;

  -- Recalcular totales de la orden
  UPDATE public.orders o SET
    subtotal = COALESCE(ROUND((
      SELECT SUM(oi.subtotal) FROM public.order_items oi
      WHERE oi.order_id = _order_id AND oi.status NOT IN ('void')
    ), 2), 0),
    tax = COALESCE(ROUND((
      SELECT SUM(oi.tax) FROM public.order_items oi
      WHERE oi.order_id = _order_id AND oi.status NOT IN ('void')
    ), 2), 0),
    discounts = COALESCE(ROUND((
      SELECT SUM(oi.discounts) FROM public.order_items oi
      WHERE oi.order_id = _order_id AND oi.status NOT IN ('void')
    ), 2), 0),
    service_fee = 0,  -- ← Siempre 0 en modelo unificado
    total = COALESCE(ROUND((
      SELECT SUM(oi.subtotal + oi.tax - oi.discounts) FROM public.order_items oi
      WHERE oi.order_id = _order_id AND oi.status NOT IN ('void')
    ), 2), 0)
  WHERE o.id = _order_id;
END;
$function$;
```

**Notas importantes:**
- Una sola pasada por orden; sin lógica por canal/origin (eso ya lo hace `fn_add_item_from_menu`)
- `service_fee` siempre 0 en columna porque ahora está sumado en `tax`
- Precisión consistente: 2 decimales en todos los campos persistidos

### 6.3 Backend: deprecar `calculate_order_totals` y `calculate_check_totals`

```sql
-- NO se borran (riesgo de romper algo). Se hacen no-op:
CREATE OR REPLACE FUNCTION public.calculate_order_totals(_order_id uuid)
RETURNS void AS $$
BEGIN
  -- DEPRECATED: usar fn_recalc_totals
  PERFORM public.fn_recalc_totals(_order_id);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.calculate_check_totals(_check_id uuid)
RETURNS void AS $$
DECLARE
  _order_id uuid;
BEGIN
  -- DEPRECATED: el cálculo se hace a nivel orden ahora
  SELECT order_id INTO _order_id FROM public.order_checks WHERE id = _check_id;
  IF _order_id IS NOT NULL THEN
    PERFORM public.fn_recalc_totals(_order_id);
  END IF;
END;
$$ LANGUAGE plpgsql;
```

**Beneficio:** cualquier código que llame a las funciones viejas sigue funcionando, solo redirecciona.

### 6.4 Backend: modificar `trigger_update_order_totals`

```sql
CREATE OR REPLACE FUNCTION public.trigger_update_order_totals()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM public.fn_recalc_totals(OLD.order_id);
    RETURN OLD;
  END IF;
  
  PERFORM public.fn_recalc_totals(COALESCE(NEW.order_id, OLD.order_id));
  RETURN NEW;
END;
$function$;
```

### 6.5 Backend: modificar `fn_compute_item_totals` (escribir a tabla nueva)

```sql
CREATE OR REPLACE FUNCTION public.fn_compute_item_totals()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  -- ... variables existentes ...
  v_origin text;
  v_biz_id uuid;
  v_tax record;
BEGIN
  -- ... lógica existente de cálculo de subtotal/tax/total ...
  
  -- NUEVA SECCIÓN: poblar order_item_tax_lines
  IF TG_OP IN ('INSERT', 'UPDATE') AND NEW.tax > 0 THEN
    -- Borrar tax lines previas si es UPDATE
    DELETE FROM public.order_item_tax_lines 
    WHERE order_item_id = NEW.id;
    
    -- Obtener origin
    SELECT ts.origin::text, ts.business_id
    INTO v_origin, v_biz_id
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    WHERE o.id = NEW.order_id;
    
    -- Insertar una línea por cada impuesto aplicable al item
    FOR v_tax IN
      SELECT t.id, t.name, t.rate
      FROM public.menu_item_taxes mit
      JOIN public.taxes t ON t.id = mit.tax_id
      WHERE mit.item_id = NEW.product_id
        AND t.business_id = v_biz_id
        AND t.is_active = true
        AND (
          (v_origin = 'dine_in' AND t.apply_on_zone) OR
          (v_origin = 'manual' AND t.apply_on_manual) OR
          (v_origin = 'quick' AND t.apply_on_quick) OR
          (v_origin = 'delivery' AND t.apply_on_delivery)
        )
    LOOP
      INSERT INTO public.order_item_tax_lines(
        order_item_id, tax_id, tax_name, tax_rate, amount
      ) VALUES (
        NEW.id, 
        v_tax.id, 
        v_tax.name, 
        v_tax.rate,
        ROUND(NEW.subtotal * (v_tax.rate / 100.0), 2)
      );
    END LOOP;
  END IF;
  
  RETURN NEW;
END;
$function$;
```

### 6.6 Backend: simplificar `fn_add_item_from_menu`

Ver el código actual (que vimos en el chunk del backend). Cambios principales:

```sql
-- ELIMINAR el fallback completo a business_settings (líneas con bs.service_fee_*)
-- ELIMINAR los CASE statements con valores fantasma del enum
-- DEJAR solo lectura de taxes con filtro por origin real:

  IF coalesce(p_is_takeout, false) = false THEN
    SELECT coalesce(max(t.rate), 0)::numeric
      INTO v_service_fee_rate
    FROM public.taxes t
    WHERE t.business_id = v_biz_id
      AND coalesce(t.is_active, true)
      AND coalesce(t.is_service_fee, false)
      AND (
        (v_origin = 'dine_in' AND t.apply_on_zone = true) OR
        (v_origin = 'manual' AND t.apply_on_manual = true) OR
        (v_origin = 'quick' AND t.apply_on_quick = true) OR
        (v_origin = 'delivery' AND t.apply_on_delivery = true)
      );
    -- Si v_service_fee_rate sigue siendo 0, NO HACER FALLBACK.
    -- Si no hay tax con is_service_fee=true que aplique al origin, no hay propina. Punto.
  END IF;
```

### 6.7 Frontend: simplificar `tax_engine.dart`

```dart
class ResolvedTaxRates {
  final double effectiveTaxPct;        // suma de tasas aplicables
  final List<AppliedTax> appliedTaxes; // detalle por impuesto
  
  const ResolvedTaxRates({
    required this.effectiveTaxPct,
    required this.appliedTaxes,
  });
  
  static const empty = ResolvedTaxRates(
    effectiveTaxPct: 0.0,
    appliedTaxes: [],
  );
}

class AppliedTax {
  final String id;
  final String name;
  final double rate;
}

ResolvedTaxRates resolveTaxRates(List<TaxDef> taxes, SaleOrigin origin) {
  double total = 0.0;
  final applied = <AppliedTax>[];
  
  for (final tx in taxes) {
    if (!tx.isActive || tx.rate <= 0) continue;
    if (!tx.appliesTo(origin)) continue;
    
    total += tx.rate;
    applied.add(AppliedTax(id: tx.id, name: tx.name, rate: tx.rate));
  }
  
  return ResolvedTaxRates(effectiveTaxPct: total, appliedTaxes: applied);
}
```

**Eliminar completamente:** `effectiveIsServiceFee` getter en `TaxDef` y `Tax`.

### 6.8 Frontend: simplificar `order_pricing_utils.dart`

```dart
ItemPricingSummary summarizeItemPricing({
  required Order order,
  required OrderItem item,
  required ResolvedTaxRates resolved,
}) {
  final catalogGross = catalogGrossAmount(item);
  final discounts = item.discounts;
  final netGross = (catalogGross - discounts).clamp(0.0, double.infinity);
  
  if (item.taxMode == 'inclusive') {
    final divisor = 1 + (resolved.effectiveTaxPct / 100);
    final tax = _r(netGross * (resolved.effectiveTaxPct / 100) / divisor);
    final base = _r(netGross - tax);
    return ItemPricingSummary(
      subtotal: base, 
      tax: tax, 
      serviceFee: 0.0,  // deprecado, siempre 0
      discounts: discounts, 
      total: _r(base + tax),
    );
  }
  
  // EXCLUSIVE
  final base = netGross;
  final tax = _r(base * (resolved.effectiveTaxPct / 100));
  return ItemPricingSummary(
    subtotal: base, 
    tax: tax, 
    serviceFee: 0.0, 
    discounts: discounts, 
    total: _r(base + tax),
  );
}
```

**Eliminar:** `resolveOrderServiceRate`, `_isServiceFeeActiveForOrigin`, y todos los paths que tratan service_fee como concepto separado.

### 6.9 Frontend: eliminar lectura de business_settings

En `sales_viewmodel.dart`, modificar `_ensureBusinessTaxSettingsLoaded`:

```dart
// ELIMINAR la lectura de business_settings:
// final row = await Supabase.instance.client
//     .from('business_settings')
//     .select('default_tax_rate,service_fee_enabled,service_fee_rate,'
//             'service_fee_on_zone,service_fee_on_manual,service_fee_on_quick,service_fee_on_delivery')
//     .eq('business_id', businessId)
//     .maybeSingle();

// DEJAR solo lectura de taxes:
try {
  final taxRows = await Supabase.instance.client
      .from('taxes')
      .select(
        'id, name, rate, is_active, is_service_fee,'
        'apply_on_zone, apply_on_manual, apply_on_quick, apply_on_delivery'
      )
      .eq('business_id', businessId)
      .eq('is_active', true);
  
  _cachedBusinessTaxes = List<Map<String, dynamic>>.from(taxRows);
  
  // Si no hay impuestos configurados, NO ES un error (el negocio puede ser exento)
  // pero el banner del PRD 1 ya alerta si la configuración es claramente incompleta
  
  _cachedTaxConfigError = null;
  _state = _state.copyWith(taxConfigError: null);
} catch (e, st) {
  _logger.error('Falla al cargar taxes', e, st);
  _cachedBusinessTaxes = const [];
  _cachedTaxConfigError = e.toString();
  _state = _state.copyWith(taxConfigError: e.toString());
  rethrow;
}
```

---

## 7. Test Plan

### 7.1 Tests dorados extendidos

Sumar a los tests del PRD 1:

```dart
group('Motor unificado: comportamiento esperado', () {
  
  test('U1: Producto 750 inclusive con ITBIS 18% en zone, sin propina', () {
    expect(result.subtotal, 635.59);
    expect(result.tax, 114.41);
    expect(result.serviceFee, 0.0);  // ← siempre 0 en modelo unificado
    expect(result.total, 750.00);
  });
  
  test('U2: Producto 750 inclusive con ITBIS 18% + LEY 10% en zone', () {
    expect(result.subtotal, 585.94);
    expect(result.tax, 164.06);  // ← suma de ambos: 105.47 + 58.59
    expect(result.serviceFee, 0.0);
    expect(result.total, 750.00);
  });
  
  test('U3: Producto 750 con ITBIS 18% + LEY 10% pero LEY no apply_on_quick', () {
    // origin = quick
    expect(result.tax, 114.41);  // solo ITBIS
    expect(result.total, 750.00);
  });
  
  test('U4: Modo exclusive con ITBIS 18% + LEY 10% en zone, producto 750', () {
    expect(result.subtotal, 750.00);
    expect(result.tax, 210.00);
    expect(result.total, 960.00);
  });
  
  test('U5: AppliedTax detail correcto', () {
    expect(resolved.appliedTaxes.length, 2);
    expect(resolved.appliedTaxes[0].name, 'ITBIS');
    expect(resolved.appliedTaxes[0].rate, 18);
    expect(resolved.appliedTaxes[1].name, 'LEY');
    expect(resolved.appliedTaxes[1].rate, 10);
  });
  
  test('U6: Suma exacta: base + tax = total', () {
    // Para todos los casos U1-U5
    expect(
      (result.subtotal + result.tax - result.discounts - result.total).abs(),
      lessThan(0.02),
    );
  });
  
  test('U7: Sin impuestos configurados, total = catalog price', () {
    // Negocio exento
    expect(result.tax, 0.0);
    expect(result.total, 750.00);
  });
});
```

### 7.2 Test de paridad backend

```sql
-- Comparar fn_recalc_totals nuevo con calculate_order_totals viejo
-- Ejecutar en staging con orden histórica:

-- Capturar valores actuales
CREATE TEMP TABLE before_recalc AS
SELECT id, subtotal, tax, service_fee, discounts, total
FROM orders WHERE id = '<test_order_id>';

-- Forzar recálculo con función nueva
SELECT fn_recalc_totals('<test_order_id>');

-- Comparar
SELECT 
  b.subtotal as before_sub, o.subtotal as after_sub,
  b.tax as before_tax, o.tax as after_tax,
  b.service_fee as before_sf, o.service_fee as after_sf,
  b.total as before_tot, o.total as after_tot,
  -- Diferencias:
  ABS(b.total - o.total) as diff_total
FROM before_recalc b
JOIN orders o ON o.id = b.id;

-- En modelo unificado:
-- after_tax = before_tax + before_service_fee  (por la consolidación)
-- after_service_fee = 0
-- after_total = before_total (debe coincidir!)
```

### 7.3 UAT

| Caso | Pasos | Esperado |
|---|---|---|
| UAT-1 | Venta nueva en zone con ITBIS+Propina | `order_item_tax_lines` poblada con 2 filas |
| UAT-2 | Venta nueva en quick con LEY no aplicable | `order_item_tax_lines` solo ITBIS |
| UAT-3 | Cambiar configuración (desactivar LEY), nueva venta | Solo ITBIS |
| UAT-4 | Eliminar `business_settings` para un negocio en staging | Sistema sigue funcionando (no depende ya) |
| UAT-5 | Restaurar orden histórica, verificar totales | Totales no cambian |
| UAT-6 | Performance: 100 ventas seguidas | Sin degradación detectable |

---

## 8. Rollout Plan

### Pre-deploy (1 día antes)

- [ ] Backup completo de producción
- [ ] Verificar restore en staging
- [ ] Comunicación: "Mañana hacemos refactor mayor. Si notás algo raro, avisame."
- [ ] Capturar línea base de métricas

### Deploy día

**Hora 0:** Aplicar migrations SQL en producción:
1. `CREATE TABLE order_item_tax_lines`
2. `CREATE FUNCTION fn_recalc_totals`
3. Modificar `trigger_update_order_totals`
4. Modificar `fn_compute_item_totals`
5. Modificar `fn_add_item_from_menu`
6. Hacer no-op a `calculate_order_totals` y `calculate_check_totals`

**Hora 1:** Deploy del frontend nuevo a 1 negocio piloto.

**Hora 2:** Si todo bien, deploy al resto.

### Post-deploy (primeras 48 horas)

- Monitoreo continuo
- Comparar totales de ventas día a día (debe seguir cuadrando)
- Verificar que `order_item_tax_lines` se está poblando

---

## 9. Rollback Plan

### Si falla el día del deploy

1. **Revert frontend:** redeploy de la versión anterior
2. **Revert SQL:**
```sql
-- Restaurar funciones viejas (si fueron modificadas):
-- (los snapshots de las funciones se guardan antes del deploy)

-- NO drop la tabla order_item_tax_lines (no rompe nada existente)
```
3. Comunicación inmediata a operadores
4. Post-mortem en 48 horas

### Si falla días después

- Mismo procedimiento
- Especial atención a `order_item_tax_lines`: si se rolledback, las filas insertadas durante el deploy quedan huérfanas — pero no causan daño porque nada las lee aún (PRD 3 las consume)

---

## 10. Risks

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| `fn_recalc_totals` da números diferentes a las funciones viejas | Media | Crítico | Test de paridad obligatorio en F2.4 |
| Trigger de `order_item_tax_lines` causa lentitud | Baja | Medio | Performance test en F2.4 |
| Frontend nuevo da diferente que backend nuevo | Media | Alto | Tests dorados frontend + paridad fe↔be |
| Operador piloto reporta cuenta cambiada | Media | Alto | UAT exhaustivo en staging con datos reales |
| Self_service no contemplado causa crash | Baja | Medio | Validar que `order_origin = 'self_service'` no llegue a producción |
| 47 productos sin menu_item_taxes generan tax=0 | Alta | Bajo | Documentado: si producto no tiene taxes asociados, no se cobra impuesto. Es comportamiento correcto. |

---

## 11. Open Questions

**OQ2-1.** ¿Qué hacer con `self_service` origin en `fn_add_item_from_menu`?
- **Opción A:** Tratar como quick (sin propina, todos los flags como quick)
- **Opción B:** Lanzar excepción si llega
- **Opción C:** Comportamiento indefinido (no validar, dejar fallar naturalmente)
- **Recomendación:** Opción B durante PRD 2 (fail-loud), revisitar cuando se implemente self-checkout
- **Decidir antes de:** F2.2

**OQ2-2.** ¿Qué hacer con los 47 productos sin `menu_item_taxes`?
- **Opción A:** Hacerlos exentos explícitamente (no cobran impuesto)
- **Opción B:** Asociarlos al ITBIS por default
- **Opción C:** Bloquear venta hasta que el operador configure
- **Recomendación:** Opción A si son legítimamente exentos. Validar con cada operador piloto cuáles son.
- **Decidir antes de:** F2.2

**OQ2-3.** ¿Tabla `order_item_tax_lines` debe tener constraint check de same business_id?
- Como vimos, ni `menu_item_taxes` lo tiene
- **Opción A:** Agregar constraint que valide vía trigger
- **Opción B:** Sin constraint, confiar en lógica de aplicación
- **Recomendación:** Opción B en PRD 2 (consistencia con resto del schema), evaluar para PRD 3
- **Decidir antes de:** F2.2

**OQ2-4.** ¿`menu_item_taxes` necesita `created_at`?
- Hoy es deuda visible (mencionada en hallazgos)
- **Opción A:** Agregarlo en este PRD (cambio aditivo, low risk)
- **Opción B:** Posponerlo a PRD futuro
- **Recomendación:** Opción A — es 1 ALTER TABLE
- **Decidir antes de:** F2.2

---

## 12. Definition of Done

PRD 2 se considera completado cuando:

- [ ] Todos los cambios de Sección 6 aplicados
- [ ] `order_item_tax_lines` poblándose correctamente para nuevas ventas
- [ ] Tests dorados de Sección 7.1 pasando 100%
- [ ] Test de paridad de Sección 7.2 pasando
- [ ] UAT de Sección 7.3 ejecutado con éxito
- [ ] Deploy a producción completado sin rollback
- [ ] 1 semana de observación sin regresiones reportadas
- [ ] Documentación de la nueva arquitectura escrita
- [ ] `PRD_02_POSTMORTEM.md` con lecciones aprendidas

Solo cuando todos estos checkboxes estén marcados, **PRD 3 puede iniciarse**.

---

## 13. Decision Log

| # | Fecha | Decisión | Razón |
|---|---|---|---|
| AD2-1 | 2026-04-26 | Consolidar `calculate_*` en una sola `fn_recalc_totals` | Una función = una lógica = un punto de verdad |
| AD2-2 | 2026-04-26 | NO borrar `service_fee` columnas en este PRD | Reduce blast radius, las columnas quedan inertes |
| AD2-3 | 2026-04-26 | NO backfill de `order_item_tax_lines` | PRD 2 ya es alto riesgo; backfill es PRD 3 |
| AD2-4 | 2026-04-26 | Snapshot de tax_name/tax_rate en cada línea | Inmutabilidad histórica; cambios futuros no afectan datos viejos |
| AD2-5 | 2026-04-26 | Modelo unificado: service_fee siempre 0 a nivel orden/check | Todo va a tax; servce_fee es deprecado conceptualmente |
| AD2-6 | 2026-04-26 | `calculate_order_totals` y `calculate_check_totals` quedan como wrappers | Backward compatibility con código que las llame |
| AD2-7 | 2026-04-26 | Eliminar fallbacks a business_settings sin reemplazo | Si no hay tax configurado, no se cobra. Punto. |

---

*PRD 2 generado el 2026-04-26. Activar al completar PRD 1 + 1 semana de observación.*
