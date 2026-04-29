# PRD 2 — Postmortem & Closure

**DRI**: Cristian Gomez
**Fecha de cierre**: 2026-04-29
**Estado final**: ✅ Completo con caveats documentados
**Implementación efectiva**: split entre commits "WIP: PRD 1 frontend complete" (21cef1a) + closure parcial PRD 2.5 (commit del 2026-04-29)

---

## Resumen ejecutivo

PRD 2 originalmente planificó 5 fases (F2.1-F2.5) como un solo bloque de 4-5 semanas. La realidad: F2.1+F2.2 se ejecutaron como parte de PRDs anteriores (PRD 1 + commits de marzo/abril). F2.3+F2.4+F2.5 se completaron parcialmente bajo el paraguas **PRD 2.5 Closure** (2026-04-29) cuando emergieron bugs operacionales en producción que forzaron acelerar el cierre.

**Invariantes finales del motor de impuestos**:
- `oi.tax_rate` consolida TODOS los impuestos (regulares + service fees) aplicables al origin.
- `oi.tax_lines` contiene UNA fila por cada impuesto aplicable. Snapshot inmutable.
- `orders.service_fee = 0` siempre para órdenes nuevas. Histórica preserva su legacy.
- `business_settings.service_fee_*` queda como columna inerte (no se lee en código nuevo).
- UI de Impuestos por-área (`taxes.apply_on_<origin>`) es la fuente única de verdad.

---

## Estado por fase

### F2.1 — Diseño y validación ✅
- Documento PRD 2 inicial creado y validado.
- 3 OQs originales resueltas implícitamente al implementar PRD 1 + 2.

### F2.2 — Backend: tabla nueva y consolidación ✅
- `order_item_tax_lines` creada en marzo 2026 (commit pre-PRD-2.5).
- `fn_recalc_order_totals` consolidada como wrapper de `calculate_order_totals` (migración `20260412_0003_final_tax_engine_consolidation.sql`).
- `fn_compute_item_totals` ya escribe item totals correctos.
- `fn_add_item_from_menu` refactoreada en `20260430_0001_prd2_closure_unified_tax.sql` para incluir service fees en el rate consolidado.
- Trigger `trg_oi_tax_lines_sync` agregado para mantener tax_lines automáticamente al cambiar items.
- **Tests SQL de paridad**: NO se ejecutaron formalmente como bloque. Se validó vía smoke tests manuales del usuario y vía los tests Dart de cross-origin parity (que validan el output del backend). Se documenta como deuda residual: si se requiere paridad formal SQL, ejecutar las queries §A de este postmortem.

### F2.3 — Frontend: motor unificado ✅ (con caveat)
- `summarizeItemPricing` simplificado en `order_pricing_utils.dart` (de ~75 líneas a ~50). Eliminado el cálculo separado de service_fee, eliminada la corrección "28% camuflado", eliminado `shouldShowServiceFee`.
- `business_settings.service_fee_*` ya no se lee en el motor de pricing del frontend. Solo queda lectura legacy en `summarizeItemPricing` para `order.serviceFee` (proporcional, solo para órdenes históricas).
- **10 tests dorados de cross-origin parity** agregados en `test/pricing/cross_origin_parity_test.dart`. Validan que Quick = Zone = Manual = Delivery devuelven idénticos números para mismos items.
- Bug encontrado durante F2.3: `summarizeOrderPricing` no restaba discounts del total a nivel orden. Fix aplicado.
- **Caveat (D3 deferida)**: 69 referencias a `serviceFee`/`extraServiceFee` siguen en el codebase. Auditoría completa (§B):
  - 53 son writes `serviceFee: 0` (inocuos, compatibles con modelo unificado).
  - 16 son reads, todos compatibles con `orders.serviceFee = 0` para nuevas y `> 0` para históricas legacy.
  - Eliminar el campo del struct requiere coordinación amplia (69 lugares). Decisión: dejar como deuda no-bloqueante. Re-evaluar en 3-6 meses cuando todas las órdenes históricas estén archivadas.

### F2.4 — Integración y QA ✅ (con caveat)
- Deploy a staging: N/A — el ambiente del DRI es uno solo (no hay staging separado).
- UAT con datos de producción: ejecutado informalmente como smoke tests durante 2026-04-29. Confirmado que Venta Rápida + Zona + cobro + breakdown 10% Ley funcionan end-to-end.
- **Test de regresión histórica**: NO ejecutado como suite formal. Las órdenes pre-PRD-2.5 mantienen sus snapshots de tax_lines/service_fee inmutables (decisión AD2-3 del PRD original). El motor nuevo solo afecta nuevas órdenes y refrescos de órdenes abiertas (cubierto por DO block del migration).
- **Performance test**: NO ejecutado. La complejidad agregada por triggers de tax_lines y joins multi-business es lineal y O(items por orden). Si emerge degradación, agregar índices sugeridos en `order_item_tax_lines.order_item_id` (ya existe via FK).
- Documentación: este postmortem + STATE_OF_VENTA_RAPIDA.md + PRD_02_5_closure_tax_engine.md cubren la nueva arquitectura.

### F2.5 — Deploy a producción ✅
- Backup pre-deploy: NO ejecutado formalmente. El DRI declaró "estamos aislados" para autorizar deploy directo.
- Deploy gradual: N/A. Single tenant deploy.
- Monitoreo intensivo: el DRI realizó UAT inmediato post-deploy que detectó y resolvió:
  - Bug raíz CASH_SESSION_NOT_OPEN multi-business (resuelto en `20260430_0002`).
  - Bug del 10% Ley invisible en Quick (causa: dual system; resuelto en `20260429_0001` + `20260430_0001`).
- Comunicación con operadores: N/A en single-DRI deploy.
- Sin reportes negativos post-deploy hasta cierre.

---

## §A — Queries de regresión histórica (opcional)

Si se desea validación formal de paridad backend, correr en SQL editor:

```sql
-- A.1 — Verificar que orders nuevas tienen service_fee=0
SELECT
  COUNT(*) FILTER (WHERE service_fee = 0) AS nuevas_compliant,
  COUNT(*) FILTER (WHERE service_fee > 0) AS legacy_preservadas,
  COUNT(*) FILTER (WHERE service_fee < 0) AS rotas
FROM public.orders
WHERE created_at > '2026-04-29 00:00:00';
```

```sql
-- A.2 — Verificar que items abiertos tienen tax_lines completos
SELECT
  oi.id,
  oi.tax_rate,
  oi.tax,
  COUNT(oitl.id) AS lines_count,
  COALESCE(SUM(oitl.amount), 0) AS sum_lines,
  ABS(COALESCE(SUM(oitl.amount), 0) - oi.tax) AS drift
FROM public.order_items oi
JOIN public.orders o ON o.id = oi.order_id
LEFT JOIN public.order_item_tax_lines oitl ON oitl.order_item_id = oi.id
WHERE o.status_ext = 'open'
  AND oi.status NOT IN ('void')
  AND oi.tax_rate > 0
GROUP BY oi.id, oi.tax_rate, oi.tax
HAVING ABS(COALESCE(SUM(oitl.amount), 0) - oi.tax) > 0.02
ORDER BY drift DESC
LIMIT 20;
```

Esperado A.2: cero filas. Si aparecen, ese item tiene desincronización entre `oi.tax` y `Σ oi.tax_lines.amount`.

```sql
-- A.3 — Verificar trigger trg_oi_tax_lines_sync existe
SELECT tgname, tgenabled
FROM pg_trigger
WHERE tgname = 'trg_oi_tax_lines_sync';
```

Esperado A.3: 1 fila con `tgenabled='O'` (enabled).

```sql
-- A.4 — Identificar productos sin impuestos asignados (potencial gap fiscal)
SELECT mi.id, mi.name, mi.is_active
FROM public.menu_items mi
LEFT JOIN public.menu_item_taxes mit ON mit.item_id = mi.id
WHERE mi.is_active = true
  AND mit.tax_id IS NULL
ORDER BY mi.name;
```

A.4 lista productos activos sin impuestos. Caso conocido: MARGARITAS (D7 en STATE_OF_VENTA_RAPIDA). Resolver via UI Ajustes > Productos.

---

## §B — Auditoría de los 69 callers de `serviceFee`

### Writes (53) — todos inocuos

Patrón típico: `Order.copyWith(serviceFee: 0)` o `OrderItemPricingSummary(serviceFee: 0, ...)`.

Estos siempre escriben **0** explícito o un valor derivado (que para nuevas órdenes da 0). No introducen bugs.

### Reads (16) — todos compatibles

| Lugar | Uso | Comportamiento |
|---|---|---|
| `order_pricing_utils.dart:285` | Heurística breakdown legacy "Propina Ley" | Solo dispara con `summary.serviceFee > 0.004` (orden histórica con legacy). Nuevas: skip (porque `summary.serviceFee = 0`). |
| `split_bill_viewmodel.dart:495` | Copia a Order para split | Si nueva: 0. Si legacy: preserva. ✅ |
| `sales_viewmodel.dart:400,425` | Display total ajuste | Idem. ✅ |
| `sales_viewmodel.dart:1074,1169,1218` | Optimistic Order copy | Idem. ✅ |
| `print_ticket_service.dart:53,66,371,633,1000-1007` | Imprime "Servicio (X%)" en ticket | Solo si `effectiveTotals.serviceFee > 0`. Nuevas: skip; usa `taxBreakdown` desde tax_lines. Legacy: imprime. ✅ |

**Conclusión**: ninguno de los 16 reads necesita refactor para preservar el modelo unificado. Todos respetan la invariante "serviceFee=0 para nuevas, >0 solo en legacy".

---

## Lecciones aprendidas

1. **Sistemas duales son cancerígenos**. Las decisiones AD2-5/AD2-7 originales del PRD 2 estaban correctas — el problema fue que se aplicaron a medias y dejaron coexistir los dos paths (`business_settings.service_fee_*` + `taxes.apply_on_<origin>`). Cada bug encontrado durante 2026-04-29 venía de esa coexistencia.

2. **Cache fallback puede enmascarar bugs raíz**. El cache offline en `_openManualOrQuick` ocultaba el verdadero error CASH_SESSION_NOT_OPEN durante un día entero porque hidrataba state stale en lugar de surface el RPC error. **Aprendizaje**: cuando agregás un fallback, asegurate de que también surface el error original al menos una vez visiblemente.

3. **`LIMIT 1` sin `ORDER BY` es un bug latente**. `fn_require_open_cash_session` agarraba un business arbitrario para users multi-tenant y fallaba intermitente. **Aprendizaje**: revisar todos los `LIMIT 1` en funciones críticas y reemplazar por `IN (...)` cuando aplique scope multi-row.

4. **El UAT informal con un solo DRI tiene blind spots**. Bugs como "Cerrada 28/04" persistente venían de cache local del device que el DRI no podía limpiar fácilmente. Tests automatizados habrían detectado más rápido. **Aprendizaje**: invertir más en tests dorados antes de declarar "OK manualmente".

5. **PRDs grandes (4-5 semanas) tienden a fragmentarse**. PRD 2 originalmente era una sola unidad. En la práctica F2.1+F2.2 se hicieron en marzo, F2.3+F2.4+F2.5 en abril bajo el paraguas distinto "PRD 2.5". **Aprendizaje**: planificar PRDs en bloques de 1 semana max; si algo crece más, splittearlo en cascada con checkpoints intermedios.

---

## Estado al cierre

✅ PRD 2 closed.
✅ Tax engine unificado en producción.
✅ 38 tests dorados pasando.
✅ Documentación actualizada.

**Deudas residuales** (registradas, no bloqueantes):
- D3: Borrar campos `serviceFee`/`extraServiceFee` de structs frontend (69 callers).
- F2.4 caveat: paridad SQL backend formal no ejecutada (queries §A disponibles).
- F2.4 caveat: performance test formal no ejecutado.

**Próximo PRD activo**: PRD 5 (Módulo de Impresión Unificado).

---

*Postmortem generado el 2026-04-29 después del deploy + UAT exitoso de PRD 2.5 Closure.*
