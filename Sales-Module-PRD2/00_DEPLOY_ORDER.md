# 00 — Orden de aplicación PRD 2 (F2.2 → F2.5)

> Este documento es el **runbook de deploy** del PRD 2. Lo seguimos al pie de la letra. Cada paso tiene precondiciones y postcondiciones explícitas.

---

## Pre-flight (obligatorio antes de empezar)

- [ ] Branch `prd/02-refactor-motor` creado (o el que corresponda) en local y pusheado.
- [ ] Backup completo de Supabase **producción** disparado y confirmado.
- [ ] Snapshot de tablas en `Sales-Module-PRD2/rollback/snapshots/` commiteado en git.
- [ ] Auditoría operativa de los 76 productos sin `menu_item_taxes` lista para enviar a operadores (no necesariamente recibida — sólo lista).
- [ ] Comunicación pre-deploy enviada a operadores piloto.
- [ ] Staging cargado con dump reciente de prod.

---

## F2.2 — Cómo aplicar (dos modos)

> **Modo A (todo junto, recomendado para STAGING):**
> Pegar TODO el contenido de [`ALL_IN_ONE_f2.2_apply.sql`](./ALL_IN_ONE_f2.2_apply.sql) en el SQL editor de Supabase y ejecutarlo de una vez. Está envuelto en `BEGIN; ... COMMIT;`, así que si cualquier bloque falla, la transacción se revierte automáticamente y el ambiente queda limpio.
>
> **Modo B (uno por uno, recomendado para PRODUCCIÓN):**
> Aplicar cada bloque del archivo consolidado por separado, verificando entre pasos. Para esto, **ignorar** el `BEGIN;` inicial y el `COMMIT;` final del consolidado, y dejar que cada bloque corra como su propia transacción implícita. O alternativamente, correr los archivos individuales `01_*` a `07_*` + `migrations/01_*` en el orden que se documenta abajo.

NO pasar a F2.4 sin que el parity test (`99_f2.2_parity_test.sql`) devuelva 100% PASS.

### Paso 1: schema nuevo (sin uso)
```
01_f2.2_create_order_item_tax_lines.sql
```
Crea la tabla, indexes, RLS policy. Inerte hasta que algo escriba en ella.

### Paso 2: configuración pre-código (link de propina)
```
migrations/01_link_service_fee_to_taxed_products.sql
```
Linkea la propina a productos que ya tributan, en `menu_item_taxes`. **Inerte con el código actual** (que filtra `is_service_fee=false`) hasta que se apliquen los SQL siguientes.

Pegar el resultado de los `SELECT count(*)` antes/después en la bitácora de deploy.

### Paso 3: trigger de tax_lines
```
02_f2.2_fn_populate_tax_lines.sql
```
Crea la función + el trigger AFTER en `order_items`. Empieza a popla `order_item_tax_lines` para nuevas inserciones. Todavía nadie lo lee.

### Paso 4: motor unificado
```
03_f2.2_fn_recalc_totals.sql
```
Crea `fn_recalc_totals`. No reemplaza nada todavía — sólo existe.

### Paso 5: wrappers
```
04_f2.2_calculate_totals_wrappers.sql
```
**Cambio observable**: `calculate_order_totals` y `calculate_check_totals` pasan a delegar a `fn_recalc_totals`. A partir de acá, los totales empiezan a calcularse con el motor nuevo. **`orders.service_fee` empieza a quedar en 0** (la propina vive dentro de `tax`).

### Paso 6: trigger orquestador
```
05_f2.2_trigger_update_order_totals.sql
```
Simplifica el trigger AFTER que llama a los recalculadores. Una sola pasada por orden.

### Paso 7: resolución de impuestos
```
06_f2.2_fn_resolve_order_item_tax_profile.sql
```
Sin filtro `is_service_fee=false`, sin valores fantasma del enum, fail-loud para `self_service` y origins desconocidos.

### Paso 8: alta de items
```
07_f2.2_fn_add_item_from_menu.sql
```
Reescritura sin lectura de `business_settings`, sin path paralelo de propina, fail-loud. **Punto de no retorno conceptual**: a partir de acá, ningún item nuevo puede crearse con la lógica vieja.

### Paso 9: parity test
```
99_f2.2_parity_test.sql
```
Corre los 5 tests. **Todos deben dar PASS**. Si alguno falla, NO avanzar a F2.4 en producción — investigar y corregir.

---

## F2.3 — Frontend en STAGING

Después de que F2.2 esté green en staging:

- Aplicar los cambios del frontend (PRD 2 §6.7-6.9):
  - Refactor `tax_engine.dart`
  - Refactor `order_pricing_utils.dart`
  - Eliminar lectura de `business_settings.service_fee_*` en `sales_viewmodel.dart`
  - Tests dorados nuevos
- Build de Flutter en staging y smoke test manual.

---

## F2.4 — UAT integrado en STAGING

- Ejecutar UAT-1 a UAT-6 del PRD 2 §7.3.
- Validar que las 6 cajas de prueba dan resultados esperados.
- Comparar reportes pre/post para órdenes ya existentes (totales no deben cambiar; cambia la composición interna pero el total final sí).

---

## F2.5 — Deploy a PRODUCCIÓN

> Sólo si F2.4 dio 100% PASS y hubo 24h de observación en staging sin sorpresas.

### Pre-deploy
- [ ] Backup nuevo de prod.
- [ ] Snapshot SQL: `SELECT business_id, SUM(total) FROM orders WHERE status='paid' GROUP BY business_id`. Guardar resultado en bitácora.
- [ ] Comunicación a operadores: "Vamos en X horas. Si bloquea cobros inesperadamente, avisame."

### Deploy SQL
Mismo orden que F2.2, en producción:
1. `01_f2.2_create_order_item_tax_lines.sql`
2. `migrations/01_link_service_fee_to_taxed_products.sql`
3. `02_f2.2_fn_populate_tax_lines.sql`
4. `03_f2.2_fn_recalc_totals.sql`
5. `04_f2.2_calculate_totals_wrappers.sql`
6. `05_f2.2_trigger_update_order_totals.sql`
7. `06_f2.2_fn_resolve_order_item_tax_profile.sql`
8. `07_f2.2_fn_add_item_from_menu.sql`

### Deploy frontend
- Push de `prd/02-refactor-motor` a main.
- Build + deploy a 1 negocio piloto.
- Observación 1 hora.
- Si OK → resto de pilotos.

### Post-deploy
- [ ] Snapshot SQL de checksum, comparar con pre.
- [ ] Verificar que `order_item_tax_lines` se está poblando.
- [ ] Comunicación a operadores: "Listo. Avisame cualquier irregularidad."
- [ ] 1 semana de observación antes de iniciar PRD 3.

---

## Rollback

### Si falla en STAGING
Revertir los SQL en orden inverso usando los archivos de `rollback/`:
```
07 → 06 → 05 → 04 → 03 → 02 → migrations/01 (unlink) → 01 (drop table)
```

### Si falla en PRODUCCIÓN
1. **Frontend**: revert del commit y redeploy.
2. **SQL**: ejecutar los rollbacks en orden inverso. Las funciones se restauran desde `snapshots/`.
3. **Tabla `order_item_tax_lines`**: NO se dropea inmediatamente — sus datos pueden ser útiles para diagnosticar. Drop sólo si la decisión es revertir el PRD 2 entero.
4. Comunicación a operadores: "Detectamos un problema, revertido. Estamos investigando."

---

## Bitácora de deploy (rellenar al ejecutar)

| Fecha | Ambiente | Paso | Resultado |
|---|---|---|---|
| _(pendiente)_ | staging | … | … |
