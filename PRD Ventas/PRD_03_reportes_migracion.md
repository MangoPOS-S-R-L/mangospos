# PRD 3 — Reportes y Migración de Datos

| Campo | Valor |
|---|---|
| **Programa** | Estabilización Fiscal MangoPOS |
| **PRD** | 3 de 3 |
| **Versión** | 1.0 |
| **Fecha** | 2026-04-26 |
| **Autor** | Cristian (DRI) |
| **Estado** | Draft (validar al finalizar PRD 2) |
| **Prioridad** | P1 |
| **Esfuerzo estimado** | 2-3 semanas full-time |
| **Riesgo** | Medio |

---

## Tabla de Contenidos

1. [Executive Summary](#1-executive-summary)
2. [Antes de empezar (prerrequisitos)](#2-antes-de-empezar-prerrequisitos)
3. [Goals y Non-Goals](#3-goals-y-non-goals)
4. [Plan por fases](#4-plan-por-fases)
5. [Cambios técnicos detallados](#5-cambios-técnicos-detallados)
6. [Backfill de datos históricos](#6-backfill-de-datos-históricos)
7. [Test Plan](#7-test-plan)
8. [Rollout Plan](#8-rollout-plan)
9. [Rollback Plan](#9-rollback-plan)
10. [Risks](#10-risks)
11. [Definition of Done](#11-definition-of-done)
12. [Decision Log](#12-decision-log)

---

## 1. Executive Summary

PRD 1 detuvo el daño. PRD 2 unificó el motor. **PRD 3 cierra el círculo:** refactoriza el sistema de reportes para consumir el modelo unificado, hace backfill de datos históricos a `order_item_tax_lines`, y elimina las columnas legacy que quedaron deprecadas.

Al finalizar este PRD:
- Reportes fiscales muestran datos por impuesto configurado, dinámicamente
- Datos históricos completos en `order_item_tax_lines`
- Columnas deprecadas eliminadas del schema
- Sistema fiscal **completamente limpio**

---

## 2. Antes de empezar (prerrequisitos)

### 2.1 PRD 2 completado

- [ ] PRD 2 deployado a producción
- [ ] 1 semana mínima de observación post-PRD-2 sin regresiones
- [ ] `order_item_tax_lines` poblándose correctamente para ventas nuevas
- [ ] `fn_recalc_totals` funcionando como única fuente de cálculo
- [ ] Postmortem de PRD 2 escrito

### 2.2 Datos validados

- [ ] Snapshot de producción reciente en staging
- [ ] Verificado que las ventas nuevas (post-PRD-2) tienen entradas en `order_item_tax_lines`
- [ ] Volumen actual de datos confirmado (puede haber crecido desde los 4,382 items)

### 2.3 Backups

- [ ] Backup completo de producción inmediatamente antes de empezar
- [ ] Backup adicional antes del DROP COLUMN final
- [ ] Restore probado

---

## 3. Goals y Non-Goals

### 3.1 Goals

**G1.** Refactorizar `reports_repository.dart` para consumir `taxes` y `order_item_tax_lines` en vez de `business_settings.service_fee_*`.

**G2.** Refactorizar `tax_report_view.dart` para mostrar líneas dinámicas por impuesto configurado, no campos fijos de "ITBIS" y "Propina".

**G3.** Hacer backfill completo de `order_item_tax_lines` para todas las órdenes históricas (las 4,382+ existentes).

**G4.** Migrar las columnas históricas: mover el valor de `orders.service_fee` a `orders.tax` para mantener consistencia con el modelo unificado.

**G5.** Eliminar las columnas deprecadas:
- `business_settings.service_fee_enabled`
- `business_settings.service_fee_rate`
- `business_settings.service_fee_on_zone`
- `business_settings.service_fee_on_manual`
- `business_settings.service_fee_on_quick`
- `business_settings.service_fee_on_delivery`
- `business_settings.default_tax_rate`
- `taxes.is_service_fee` (ya deprecado en frontend)
- `orders.service_fee` (mover datos a `tax` antes)
- `order_checks.service_fee` (mover datos a `tax` antes)

**G6.** Actualizar reports_viewmodel y otros consumers para no esperar campo fijo `service_fee_rate` en el response.

**G7.** Documentar el cambio para los operadores: "El reporte ahora muestra cada impuesto separado dinámicamente, no agrupado en 'propina'."

### 3.2 Non-Goals

**N1.** **No** se eliminan `original_tax_rate` (sigue usándose para extracción inclusive).

**N2.** **No** se elimina `qty` ni `quantity` (esa es deuda B-11, otro proyecto).

**N3.** **No** se elimina `orders.status` ni `orders.status_ext` (deuda B-11).

**N4.** **No** se modifica el schema de `taxes` ni `menu_item_taxes`.

**N5.** **No** se implementa `self_service` (ya pospuesto).

---

## 4. Plan por fases

### F3.1 — Refactor de reportes en frontend (5 días)

- Modificar `reports_repository.dart` para nuevo modelo
- Modificar `reports_viewmodel.dart` para passthrough nuevo
- Modificar `tax_report_view.dart` para render dinámico
- Tests en staging contra negocio piloto restaurado

**Go/No-Go:** Reporte muestra datos correctos comparado con sumas SQL directas.

### F3.2 — Backfill de datos históricos (3 días)

- Script SQL idempotente que crea entries en `order_item_tax_lines` para todos los `order_items` existentes
- Validación de integridad: suma de tax en cada item = suma de líneas

**Go/No-Go:** Checksum total tax = total cobrado para todos los negocios.

### F3.3 — Migración de columnas (2 días)

- Mover `service_fee` a `tax` en `orders` y `order_checks`
- Validar checksums antes/después

**Go/No-Go:** Suma total de `total` por negocio idéntica antes/después.

### F3.4 — Cleanup (1 día)

- DROP de columnas deprecadas
- Validación final de schema limpio

**Go/No-Go:** Solo se hace con 4 semanas mínimas de estabilidad post F3.3.

### F3.5 — Documentación y comunicación (2-3 días)

- Documentar arquitectura final
- Comunicar a operadores los cambios visuales en reportes
- Cierre del programa

---

## 5. Cambios técnicos detallados

### 5.1 Frontend — `reports_repository.dart`

**Cambio principal:** Eliminar dependencia de `business_settings.service_fee_*`.

```dart
// ANTES: lectura de business_settings
// final businessSettings = await _client
//     .from('business_settings')
//     .select('service_fee_enabled, service_fee_rate')
//     ...
// final serviceFeeEnabled = businessSettings?['service_fee_enabled'] == true;
// final serviceFeeRate = _toDouble(businessSettings?['service_fee_rate']).clamp(0, 100);

// DESPUÉS: lectura de taxes y agrupación desde order_item_tax_lines
final taxes = await _client
    .from('taxes')
    .select('id, name, rate, is_active, '
            'apply_on_zone, apply_on_manual, apply_on_quick, apply_on_delivery')
    .eq('business_id', businessId)
    .eq('is_active', true);

// Obtener desglose real por impuesto desde order_item_tax_lines
final taxLines = await _client
    .from('order_item_tax_lines')
    .select('tax_id, tax_name, tax_rate, amount, order_item_id, created_at')
    .gte('created_at', fromIso)
    .lte('created_at', toIso);

// Agrupar por tax_id (no por nombre, no por tasa — tax_id es la identidad estable)
final taxBreakdown = <String, Map<String, dynamic>>{};
for (final line in taxLines) {
  final taxId = line['tax_id'] as String;
  taxBreakdown.putIfAbsent(taxId, () => {
    'tax_id': taxId,
    'tax_name': line['tax_name'],   // snapshot histórico
    'tax_rate': line['tax_rate'],   // snapshot histórico
    'amount': 0.0,
    'count': 0,
  });
  taxBreakdown[taxId]!['amount'] = 
    (taxBreakdown[taxId]!['amount'] as double) + 
    (line['amount'] as num).toDouble();
  taxBreakdown[taxId]!['count'] = 
    (taxBreakdown[taxId]!['count'] as int) + 1;
}

// Response del reporte: lista dinámica
return {
  'from': fromIso,
  'to': toIso,
  'total_tax_collected': taxBreakdown.values.fold<double>(
    0.0, (s, t) => s + (t['amount'] as double)
  ),
  'tax_breakdown': taxBreakdown.values.toList(),
  // ... resto del response (sin 'service_fee_rate' como campo fijo) ...
};
```

**Eliminaciones explícitas:**

```dart
// BORRAR (línea ~1101):
'service_fee_rate': 10.0,

// BORRAR del segundo reporte (línea ~1492):
'service_fee_rate': configuredServiceFeeRate,
'service_fee_label': configuredServiceFeeName,
'total_service_fee': totalServiceFee,
```

### 5.2 Frontend — `reports_viewmodel.dart`

```dart
// ANTES (línea ~1074):
final serviceFeeRate = (summary['service_fee_rate'] as num?)?.toDouble() ?? 0;

// DESPUÉS:
final taxBreakdown = (summary['tax_breakdown'] as List?) ?? [];

// Generar lista dinámica de cards/lines:
final taxMetrics = taxBreakdown.map((tax) {
  return SalesMetricCardData(
    title: '${tax['tax_name']} (${tax['tax_rate']}%)',
    value: 'RD\$${(tax['amount'] as num).toDouble().toStringAsFixed(2)}',
    subtitle: '${tax['count']} líneas en el rango',
    icon: Icons.receipt_outlined,
    color: const Color(0xFF2563EB),
  );
}).toList();
```

### 5.3 Frontend — `tax_report_view.dart`

```dart
// ANTES (línea ~71): lectura del campo fijo
// final serviceFeeRate = (fs['service_fee_rate'] as num?)?.toDouble() ?? 0;
// final serviceFeeLabel = fs['service_fee_label']?.toString() ?? 'Propina de ley';

// DESPUÉS: render dinámico de tax_breakdown
final taxBreakdown = (fs['tax_breakdown'] as List?) ?? [];

return ListView(
  padding: reportSectionPadding,
  children: [
    ReportHeroCard(
      title: 'Reporte de Impuestos',
      subtitle: 'Basado en comprobantes fiscales emitidos. Fuente oficial para DGII.',
      // ... resto del hero card ...
    ),
    
    // Mostrar una sección por cada impuesto activo
    ...taxBreakdown.map((tax) {
      return Card(
        child: ListTile(
          title: Text('${tax['tax_name']} (${tax['tax_rate']}%)'),
          trailing: Text(
            'RD\$${(tax['amount'] as num).toDouble().toStringAsFixed(2)}',
          ),
          subtitle: Text('${tax['count']} líneas'),
        ),
      );
    }).toList(),
    
    // ... otras secciones del reporte (totales, comprobantes, etc.) ...
  ],
);
```

### 5.4 Backend — Limpieza final de funciones

Una vez que las columnas estén deprecadas, eliminar referencias residuales:

```sql
-- En fn_add_item_from_menu, fn_resolve_order_item_tax_profile, etc.
-- Verificar que ninguna sigue leyendo business_settings.service_fee_*
-- (deberían haberse limpiado en PRD 2, validar acá)
```

---

## 6. Backfill de datos históricos

### 6.1 Estrategia

Para cada `order_item` existente con `tax > 0`:
1. Identificar qué impuestos aplicaban según `menu_item_taxes` y `order.origin`
2. Generar entries en `order_item_tax_lines` proporcional al tax total

### 6.2 Script SQL

```sql
-- Backfill idempotente: solo inserta si no existe ya
DO $$
DECLARE
  v_item record;
  v_origin text;
  v_biz_id uuid;
  v_total_rate numeric;
  v_tax record;
  v_amount numeric;
  v_count integer := 0;
BEGIN
  FOR v_item IN 
    SELECT 
      oi.id as item_id,
      oi.product_id,
      oi.subtotal,
      oi.tax,
      oi.tax_rate,
      ts.origin::text as origin,
      ts.business_id
    FROM public.order_items oi
    JOIN public.orders o ON o.id = oi.order_id
    JOIN public.table_sessions ts ON ts.id = o.session_id
    WHERE oi.tax > 0
      AND oi.status NOT IN ('void')
      AND NOT EXISTS (
        SELECT 1 FROM public.order_item_tax_lines oitl
        WHERE oitl.order_item_id = oi.id
      )
  LOOP
    -- Calcular suma de tasas aplicables al momento
    SELECT COALESCE(SUM(t.rate), 0) INTO v_total_rate
    FROM public.menu_item_taxes mit
    JOIN public.taxes t ON t.id = mit.tax_id
    WHERE mit.item_id = v_item.product_id
      AND t.business_id = v_item.business_id
      AND t.is_active = true
      AND (
        (v_item.origin = 'dine_in' AND t.apply_on_zone) OR
        (v_item.origin = 'manual' AND t.apply_on_manual) OR
        (v_item.origin = 'quick' AND t.apply_on_quick) OR
        (v_item.origin = 'delivery' AND t.apply_on_delivery)
      );
    
    -- Si v_total_rate = 0, este item no tiene impuestos asociados ahora.
    -- Para el backfill, distribuimos el tax existente proporcionalmente.
    -- Si no hay impuestos definidos, creamos una línea "legacy" sin tax_id válido.
    
    IF v_total_rate > 0 THEN
      -- Distribución proporcional
      FOR v_tax IN
        SELECT t.id, t.name, t.rate
        FROM public.menu_item_taxes mit
        JOIN public.taxes t ON t.id = mit.tax_id
        WHERE mit.item_id = v_item.product_id
          AND t.business_id = v_item.business_id
          AND t.is_active = true
          AND (
            (v_item.origin = 'dine_in' AND t.apply_on_zone) OR
            (v_item.origin = 'manual' AND t.apply_on_manual) OR
            (v_item.origin = 'quick' AND t.apply_on_quick) OR
            (v_item.origin = 'delivery' AND t.apply_on_delivery)
          )
      LOOP
        -- Proporción de este impuesto sobre el total
        v_amount := ROUND(v_item.tax * (v_tax.rate / v_total_rate), 2);
        
        INSERT INTO public.order_item_tax_lines(
          order_item_id, tax_id, tax_name, tax_rate, amount, created_at
        ) VALUES (
          v_item.item_id, v_tax.id, v_tax.name, v_tax.rate, v_amount, now()
        );
        
        v_count := v_count + 1;
      END LOOP;
    END IF;
    -- Si v_total_rate = 0: skip. El item tendrá tax > 0 pero no tax_lines.
    -- Esto es deuda histórica aceptable (los 7 items con tax_rate=0 que vimos).
  END LOOP;
  
  RAISE NOTICE 'Backfill complete: % tax lines created', v_count;
END $$;
```

### 6.3 Validación post-backfill

```sql
-- Validación 1: cada item con tax > 0 tiene al menos una línea
SELECT COUNT(*) as items_sin_lines
FROM public.order_items oi
WHERE oi.tax > 0
  AND oi.status NOT IN ('void')
  AND NOT EXISTS (
    SELECT 1 FROM public.order_item_tax_lines oitl
    WHERE oitl.order_item_id = oi.id
  );
-- Esperado: cantidad pequeña (los 7 con tax_rate=0, o sin menu_item_taxes)

-- Validación 2: suma de líneas ≈ tax persistido (tolerancia ±0.02 por redondeo)
SELECT 
  COUNT(*) as items_con_diff,
  AVG(ABS(oi.tax - line_sum.total_lines)) as avg_diff
FROM public.order_items oi
JOIN (
  SELECT order_item_id, SUM(amount) as total_lines
  FROM public.order_item_tax_lines
  GROUP BY order_item_id
) line_sum ON line_sum.order_item_id = oi.id
WHERE ABS(oi.tax - line_sum.total_lines) > 0.02;
-- Esperado: 0 (o pocos casos por redondeo acumulado)
```

---

## 6.4 Migración de service_fee → tax

```sql
-- Backup explícito de columnas a modificar
CREATE TABLE _backup_orders_service_fee AS
SELECT id, service_fee, tax, total FROM public.orders;

CREATE TABLE _backup_order_checks_service_fee AS
SELECT id, service_fee, tax, total FROM public.order_checks;

-- Capturar checksum ANTES
SELECT 
  business_id, 
  SUM(o.total) as total_check_before
FROM public.orders o
JOIN public.table_sessions ts ON ts.id = o.session_id
WHERE o.status_ext IN ('paid')
GROUP BY business_id;
-- Guardar este resultado

-- Migración: mover service_fee a tax
UPDATE public.orders 
SET tax = tax + service_fee, service_fee = 0
WHERE service_fee > 0;

UPDATE public.order_checks
SET tax = tax + service_fee, service_fee = 0
WHERE service_fee > 0;

-- Capturar checksum DESPUÉS
SELECT 
  business_id, 
  SUM(o.total) as total_check_after
FROM public.orders o
JOIN public.table_sessions ts ON ts.id = o.session_id
WHERE o.status_ext IN ('paid')
GROUP BY business_id;

-- ⚠️ AMBOS RESULTADOS DEBEN COINCIDIR
-- Si difieren: ROLLBACK con backup tables
```

---

## 7. Test Plan

### 7.1 Tests del refactor de reportes

```dart
group('Reportes refactorizados', () {
  test('R1: Reporte muestra una línea por impuesto activo', () {
    // Setup: negocio con ITBIS 18% y Propina 10%
    // Expectation: 2 líneas en breakdown
  });
  
  test('R2: Reporte sin business_settings.service_fee_rate funciona', () {
    // Eliminar service_fee_rate de business_settings
    // Expectation: reporte sigue mostrando datos correctos desde tax_breakdown
  });
  
  test('R3: Total reportado = SUM de tax_breakdown', () {
    expect(report['total_tax_collected'], 
      equals(report['tax_breakdown']
        .map((t) => t['amount']).reduce((a, b) => a + b)));
  });
});
```

### 7.2 Test de backfill

```sql
-- Pre-backfill: cantidad de tax lines = 0 para items históricos
SELECT COUNT(*) FROM public.order_item_tax_lines 
WHERE created_at < '<deploy_date_PRD_2>';
-- Esperado: 0

-- Post-backfill: cantidad de tax lines > 0
SELECT COUNT(*) FROM public.order_item_tax_lines;
-- Esperado: ~equivalente a items históricos con tax > 0

-- Validación checksum
WITH item_sums AS (
  SELECT order_item_id, SUM(amount) as total_lines
  FROM public.order_item_tax_lines
  GROUP BY order_item_id
)
SELECT COUNT(*) as items_inconsistentes
FROM public.order_items oi
LEFT JOIN item_sums s ON s.order_item_id = oi.id
WHERE oi.tax > 0
  AND oi.status NOT IN ('void')
  AND ABS(oi.tax - COALESCE(s.total_lines, 0)) > 0.02;
-- Esperado: 0 (o pocos casos por redondeo)
```

### 7.3 UAT

| Caso | Pasos | Esperado |
|---|---|---|
| UAT-1 | Abrir reporte fiscal de mes pasado | Líneas dinámicas por impuesto, total cuadra con orders |
| UAT-2 | Cambiar nombre de un impuesto, abrir reporte histórico | Datos viejos siguen mostrando nombre original (snapshot) |
| UAT-3 | DROP business_settings.service_fee_rate (en staging), abrir reporte | Funciona, no falla |
| UAT-4 | Comparar reporte mes anterior con archivo Excel del operador | Coincide con tolerancia de redondeo |

---

## 8. Rollout Plan

### Pre-deploy

- [ ] Backup completo
- [ ] Verificar backups en staging
- [ ] Comunicación: "Próxima semana actualizamos cómo se ven los reportes. Pueden notar el cambio visual; los totales son los mismos."

### Día 1-3: Frontend reportes

- [ ] Deploy frontend nuevo a 1 piloto, monitoreo
- [ ] Si OK, deploy al resto

### Día 4: Backfill

- [ ] Backup adicional
- [ ] Ejecutar script de backfill en staging primero
- [ ] Validar checksums
- [ ] Si OK, ejecutar en producción
- [ ] Validar checksums producción

### Día 5: Migración service_fee → tax

- [ ] Backup adicional
- [ ] Ejecutar migración en staging
- [ ] Validar checksums
- [ ] Si OK, ejecutar en producción
- [ ] Validar checksums

### Días 6-30: Observación

- [ ] Monitoreo 4 semanas
- [ ] Comparar reportes con expectativas de operadores
- [ ] Sin reportes negativos = listo para cleanup

### Día 30+: DROP COLUMN

```sql
ALTER TABLE public.business_settings 
  DROP COLUMN default_tax_rate,
  DROP COLUMN service_fee_enabled,
  DROP COLUMN service_fee_rate,
  DROP COLUMN service_fee_on_zone,
  DROP COLUMN service_fee_on_manual,
  DROP COLUMN service_fee_on_quick,
  DROP COLUMN service_fee_on_delivery;

ALTER TABLE public.taxes DROP COLUMN is_service_fee;

ALTER TABLE public.orders DROP COLUMN service_fee;
ALTER TABLE public.order_checks DROP COLUMN service_fee;
```

---

## 9. Rollback Plan

### Rollback del refactor frontend

`git revert` y redeploy. No afecta datos.

### Rollback del backfill

```sql
-- Eliminar las líneas del backfill (preservar las nuevas post PRD 2)
DELETE FROM public.order_item_tax_lines
WHERE created_at < '<fecha_inicio_backfill>';
```

### Rollback de migración service_fee → tax

```sql
-- Restaurar desde backup
UPDATE public.orders o
SET service_fee = b.service_fee, tax = b.tax
FROM _backup_orders_service_fee b
WHERE o.id = b.id;

UPDATE public.order_checks oc
SET service_fee = b.service_fee, tax = b.tax
FROM _backup_order_checks_service_fee b
WHERE oc.id = b.id;
```

### Rollback del DROP COLUMN

**No hay rollback simple.** Una vez droppeada la columna, los datos están perdidos. Por eso se hace **30 días después**, con backups múltiples, y solo si todo lo demás funcionó.

---

## 10. Risks

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| Backfill tarda mucho con datos grandes | Baja | Bajo | Volumen actual es chico (4,382 items) |
| Operador piloto se queja del nuevo formato del reporte | Media | Bajo | Comunicación previa + cambio gradual |
| Migración corrompe checksum | Baja | Alto | Backup obligatorio, validación pre/post |
| DROP COLUMN se hace antes de tiempo | Baja | Crítico | 4 semanas mínimas + backup adicional inmediatamente antes |
| Reportes con período mixed (pre/post backfill) muestran inconsistencia | Media | Medio | Documentar: el desglose por impuesto solo está disponible post-backfill |

---

## 11. Definition of Done

- [ ] Refactor frontend completado y deployado
- [ ] Backfill ejecutado y validado
- [ ] Migración service_fee → tax completada y validada
- [ ] 4 semanas de observación sin reportes negativos
- [ ] DROP COLUMN ejecutado
- [ ] Schema final limpio sin columnas deprecadas
- [ ] Documentación de arquitectura final escrita
- [ ] `PRD_03_POSTMORTEM.md` con lecciones del programa completo

**Cuando este PRD termine, el programa "Estabilización Fiscal MangoPOS" se cierra formalmente.**

---

## 12. Decision Log

| # | Fecha | Decisión | Razón |
|---|---|---|---|
| AD3-1 | 2026-04-26 | Backfill se hace en PRD 3, no PRD 2 | Reduce blast radius de PRD 2 |
| AD3-2 | 2026-04-26 | DROP COLUMN se hace 4 semanas después | Máxima seguridad antes de operación irreversible |
| AD3-3 | 2026-04-26 | Migración service_fee → tax preserva totales | El cliente ya pagó X; el modelo nuevo registra X igual |
| AD3-4 | 2026-04-26 | Backfill prorratea cuando hay múltiples impuestos | Sin info detallada histórica, prorratear es la mejor aproximación |
| AD3-5 | 2026-04-26 | Items legacy sin menu_item_taxes se dejan sin líneas | Honest data: no inventar lo que no se sabe |
| AD3-6 | 2026-04-26 | Reporte con período mixed muestra disclaimer | Honesty over completeness |

---

*PRD 3 generado el 2026-04-26. Activar al completar PRD 2 + 1 semana de observación.*
*Este es el último PRD del programa. Al cerrarse, el programa de Estabilización Fiscal queda completado.*
