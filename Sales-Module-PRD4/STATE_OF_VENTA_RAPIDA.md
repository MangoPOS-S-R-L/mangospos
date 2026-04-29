# Estado actual — Venta Rápida (PRD 4 / 2026-04-29)

**DRI**: Cristian Gomez
**Branch**: `prd/04-modulos-venta`
**Build verificada**: ✅ — Venta Rápida funcional end-to-end después de aplicar migrations 20260429_0001 + 20260430_0001 + 20260430_0002 y refactor frontend de `summarizeItemPricing`. Confirmado por usuario 2026-04-29.

> Documento honesto: separa lo que **funciona confirmado**, lo que **debería funcionar pero falta verificar**, y lo que **sigue roto**. Sin endulzar.

---

## 0. Resumen ejecutivo del cierre (2026-04-29)

**Venta Rápida está operativa.** El bug raíz que impedía agregar productos era **`fn_require_open_cash_session` con `LIMIT 1` no determinístico** sobre los businesses del user — cuando un user pertenece a múltiples businesses (caso admin@test.com), el `LIMIT 1` agarraba el business sin caja abierta y disparaba `CASH_SESSION_NOT_OPEN`. Migration `20260430_0002` lo refactorea para buscar caja en TODOS los businesses del user. Resuelto.

Otros fixes aplicados:
- **PRD 2.5 closure** (parcial): unified tax engine, todos los impuestos van a `oi.tax_lines`, `orders.service_fee=0` siempre.
- **Frontend pricing**: `summarizeItemPricing` simplificado, eliminada la rama hardcoded que excluía service fees en Quick.
- **State management**: cache offline rechaza snapshots con orden cerrada O con origin distinto. Sin fallback de cache para Quick/Manual (siempre RPC fresco).
- **Post-cobro**: cierre mandatorio + auto-reopen de sesión Quick para fluir directo a la próxima venta.

**Venta Manual deshabilitada temporalmente** en el sidebar ([sales_shell_view.dart:124](lib/presentation/sales/view/sales_shell_view.dart#L124) — `disabled: !isCashOpen || true`) hasta completar F4.4 (TableSelectorModal + flujo de asignación post-cobro).

---

## 1. Qué es Venta Rápida (intención)

POS express sin selección de mesa. El operador inicia, agrega productos, cobra, y arranca de cero para la próxima venta. Debe comportarse **funcionalmente idéntico a Venta por Zona** salvo que:

- No selecciona mesa (usa una mesa virtual `quick` en zona "Ventas rapidas").
- Post-cobro vuelve a estado vacío para próxima venta (Zone vuelve al grid de mesas).

Todo lo demás (impuestos, NCF, split bill, descuentos, cobro fiscal, modifiers, etc.) **debe funcionar igual que Zone**.

---

## 2. Arquitectura actual

### 2.1 Entrada al modo
- Sidebar → "Venta rápida" → `context.go('/ventas?mode=rapida')`
- Router (`app_router.dart:298-299`) renderiza `OrderScreen(origin: OrderOrigin.quick)`.
- Mismo widget `OrderScreen` que Zone/Manual/Delivery — diferenciado por el enum `OrderOrigin`.

### 2.2 Apertura de sesión
- `_initializeOrder()` → `ensureQuickOrder()` → `openQuick(forceRestart=true)` → `_openManualOrQuick('quick')`.
- Llama RPC `fn_open_manual_or_quick('quick', user_id)`.
- El RPC:
  1. Resuelve mesa virtual `quick` en zona "Ventas rapidas" (la crea si no existe via `fn_get_or_create_virtual_table`).
  2. Cierra cualquier sesión abierta previa en esa mesa virtual.
  3. Crea nueva `table_session` con `origin='quick'` y nueva `order` con `status_ext='open'`.
  4. Devuelve `{session_id, order_id}`.
- Frontend hace `_loadOrderDetail(order_id)` que pobla state con la nueva orden.

### 2.3 Persistencia local
- `OfflinePosService.saveSnapshot` guarda el state en SharedPreferences/storage local con `slotId='quick'`.
- Se rehidrata SOLO en el catch de `_openManualOrQuick` cuando el RPC falla (modo offline).

### 2.4 Cobro
- Pagar → `PaymentSplitDialog` → repo `processPayment` → RPC `fn_process_payment_v2`.
- `processPayment` cierra la orden + sesión cuando el pago cubre el total.
- Frontend `onFinish` (post-PRD-4): ejecuta cleanup mandatorio:
  1. `closeOrder(orderId, 'paid')` explícito (red de seguridad).
  2. `refreshOrder(clearIfPaid=true)` — limpia state si `order.isPaid`.
  3. `openQuick(forceRestart=true)` — abre sesión nueva inmediatamente para próxima venta.

### 2.5 Impuestos
**Diseño actual (post-migración `20260429_0001_unify_service_fee_per_tax.sql`)**:
- Cada producto define qué impuestos lo afectan via `menu_item_taxes`.
- Los impuestos NO service-fee se aplican al item directamente (`oi.tax_rate`, `oi.tax`).
- Los impuestos service-fee (`is_service_fee=true`) se aplican a nivel orden (`orders.service_fee`).
- Para CADA tipo de impuesto, los toggles per-área (`apply_on_zone`, `apply_on_manual`, `apply_on_quick`, `apply_on_delivery`) deciden si aplica en ese modo.
- **Fuente única de verdad**: la tabla `taxes` (lo que el usuario ve y modifica en Ajustes > Impuestos).

---

## 3. Lo que funciona — confirmado por SQL/análisis

| Item | Estado | Evidencia |
|---|---|---|
| RPC `fn_open_manual_or_quick` crea sesión + orden Quick correctamente | ✅ | Schema SQL line 1244-1320 inspeccionado. |
| Mesa virtual + zona "Ventas rapidas" existen para el business de prueba | ✅ | Query 11: zona `e4a60bf4...` con sort_index 901, name "Ventas rapidas". |
| RLS sobre `order_item_tax_lines` permite leer si business pertenece al user | ✅ | Política `oitl_select` validada (query 3). |
| NCF B02 (Consumo) activa con stock para Quick | ✅ | Query 2: 8011 NCFs restantes. |
| Backend escribe `tax_lines` correctamente para items con tax asignado | ✅ | Query 25 (Agua Dasany): `tax_line_count=2`, ITBIS + 10% Ley con amounts correctos. |
| Modifiers se incluyen en `oi.subtotal` cuando el motor recalcula | ✅ | Query 19: MARGARITAS con chinola muestra `subtotal=1050` (450 base + 600 modifier). |
| Sesiones zombie de Quick limpiadas | ✅ | Query 28 ejecutada, query 29 verificó 0 zombies. |

---

## 4. Fixes aplicados en esta sesión

### 4.1 Frontend (Dart) — TODOS aplicados al código pero pendientes de validar en build limpia

| # | Fix | Archivo | Estado |
|---|---|---|---|
| F1 | Surface real fiscal load error en vez de mensaje engañoso | `sales_viewmodel.dart:1996-2008` + `sales_state.dart` | aplicado |
| F2 | Borrado de `quick_order_screen.dart` no usado por router | `quick_order_screen.dart` | borrado |
| F3 | `ensureQuickOrder/ensureManualOrder` solo reusa órdenes con `status='open'` | `sales_viewmodel.dart:561-583` | aplicado |
| F4 | `addItem` defensivo: rechaza items en orden `paid/void` y reabre sesión | `sales_viewmodel.dart:768-786` | aplicado |
| F5 | Post-cobro Quick/Manual: closeOrder + refresh + auto-reopen sesión nueva | `table_order_screen.dart:1110-1136` | aplicado |
| F6 | Subtotal de items draft con modifiers usa `_itemGross` cuando backend no recalculó | `order_pricing_utils.dart:68-79` | aplicado |
| F7 | Cache offline rechaza snapshots con orden cerrada (closedAt o status terminal) | `sales_viewmodel.dart:719-748` | aplicado |
| F8 | TableSelectorModal para flujo Manual (origin: manual → assign mesa al final) | `table_selector_modal.dart` + `table_order_screen.dart:1180-1198` | aplicado |

### 4.2 Backend (SQL) — todas APLICADAS

| # | Cambio | Archivo / Query | Estado |
|---|---|---|---|
| B1 | Cleanup de sesiones zombie en mesas virtuales | Query 28 (SQL editor) | ✅ aplicada |
| B2 | `service_fee_on_quick=true` en `business_settings` (legacy data fix) | Query 32 | ✅ aplicada |
| B3 | Refactor `calculate_order_totals/check_totals` per-tax `apply_on_<origin>` | `migrations/20260429_0001_unify_service_fee_per_tax.sql` | ✅ aplicada |
| B4 | **PRD 2.5 F1**: unified tax engine. `oi.tax_rate` incluye TODOS los taxes (regulares + service fees), tax_lines incluye una fila por cada uno, `orders.service_fee=0` siempre. Trigger `trg_oi_tax_lines_sync` mantiene tax_lines automáticamente. | `migrations/20260430_0001_prd2_closure_unified_tax.sql` | ✅ aplicada |
| B5 | **Bug fix multi-business**: `fn_require_open_cash_session` busca caja en TODOS los businesses del user (antes hacía `LIMIT 1` sobre primer business arbitrario, fallando si era un business sin caja). Causa raíz del bug intermitente CASH_SESSION_NOT_OPEN. | `migrations/20260430_0002_fix_require_cash_session_multi_business.sql` | ✅ aplicada |

### 4.3 Datos de tenant — pendientes del usuario (no son bugs de código)

| # | Item | Acción |
|---|---|---|
| D1 | MARGARITAS sin impuestos asignados | INSERT en `menu_item_taxes` (provisto en mensaje anterior) o asignar via UI Ajustes > Productos |
| D2 | Agente local de impresión `online=false`, `last_seen=null` | Arrancar agente y conectar a internet para que reporte heartbeat. Sin esto: "Enviar a Cocina" falla con "No hay impresoras cacheadas para kitchen_hot" |

---

## 5. Cierre y deudas restantes

### 5.1 Cerrado ✅
- ~~Bug zombie de state que mostraba "Cerrada 28/04 23:52"~~ → resuelto al eliminar cache fallback en `_openManualOrQuick` y al fixear el bug raíz multi-business.
- ~~10% Ley en Quick~~ → resuelto vía migration B4 (per-tax + tax_lines).
- ~~CASH_SESSION_NOT_OPEN~~ → resuelto vía migration B5 (multi-business).
- ~~Subtotal con modifiers en draft~~ → resuelto vía F6 frontend.
- ~~Items se quedan post-cobro~~ → resuelto vía onFinish con closeOrder + refresh + auto-reopen.

### 5.2 Deuda técnica diferida (PRD aparte)

| # | Item | Por qué se difiere |
|---|---|---|
| D1 | Venta Manual: completar TableSelectorModal + flujo asignación post-cobro | F4.4 quedó pendiente. UI bloqueada en sidebar mientras tanto. |
| D2 | Refactor de `OfflinePosService`: Quick no debe usar el path "mesa virtual" del modelo Zone | Dejamos cache deshabilitado para Quick. Limpieza pendiente. |
| D3 | PRD 2.5 F2 más profundo: borrar `serviceFee`/`extraServiceFee` de `OrderItemPricingSummary` y `OrderPricingSummary` | Hoy quedan inertes. 69 callers a actualizar — riesgo medio, agendar. |
| D4 | PRD 2.5 F3: tests dorados cross-origin parity (Quick = Zone = Manual = Delivery) | Sin tests no hay garantía contra regresiones. CI gate pendiente. |
| D5 | UI de Impuestos: documentar que el toggle "Venta rápida" en cada tax ahora SÍ surte efecto via per-tax `apply_on_quick` | Pequeño update visual. |
| D6 | Agente local de impresión `online=false` para el business de prueba | Operacional, fuera del scope PRD. |
| D7 | MARGARITAS sin impuestos asignados (data del tenant) | INSERT manual en `menu_item_taxes`. |
| D8 | Limpiar zombie session de marzo (`4db46120...` user `cristian@mangopos.do`) | UPDATE manual con `closed_at = now()`. No bloqueante. |

---

## 6. Pasos para validar (orden estricto)

### Paso 1: Aplicar migración SQL

```bash
# Opción A: si usás Supabase CLI
supabase db push

# Opción B: copiar contenido de
# supabase/migrations/20260429_0001_unify_service_fee_per_tax.sql
# y pegarlo en el SQL editor de Supabase, dale Run.
```

### Paso 2: Build limpia del frontend

```bash
# En la terminal donde corre flutter, apretar 'q' para salir.
flutter clean
flutter pub get
flutter run -d <tu-device>
```

### Paso 3: Verificación visual

1. Abrir app → ir a Venta Rápida.
2. **Esperado**: cart vacío, sin "Cerrada DD/MM", sin "John Peralta" cargado, NCF "Consumo (02)" por default.
3. Si seguís viendo "Cerrada 28/04..." → escalar bug §5.1 con logs específicos.
4. Si arranca limpio → agregar Agua Dasany (RD$50).
5. **Esperado en cart**:
   - Subtotal: RD$ 50.00
   - 10% De Ley (10%): RD$ 5.00
   - ITBIS (18%): RD$ 9.00
   - Total: RD$ 64.00
6. Cobrar completo → factura imprime (si agente local funciona).
7. Después del cobro → cart debe quedar limpio automáticamente.
8. Agregar otro producto → cobrar.
9. **Esperado**: factura solo trae el segundo item, no acumula items de la cobranza anterior.

### Paso 4: Validación específica de paridad con Zone

Replicar el mismo test (agregar 1 Agua Dasany, cobrar) en Venta por Zona en la misma mesa. Comparar:
- Subtotal y breakdown de impuestos deben dar **idéntico resultado**.
- Si Zone muestra diferentes números → falta más alineación per-tax.

---

## 7. Lo que NO está en scope

- Asignar mesa post-cobro en Quick (concept "Manual" cubre eso).
- Self-service / Delivery — fuera del perímetro de este PRD.
- Refactor del `OfflinePosService` (deuda técnica que arrastra Quick desde su origen como mesa virtual). Lo dejamos como follow-up.
- UI separada para Quick distinta a `OrderScreen`. Mantenemos paridad arquitectónica con Zone.

---

## 8. Decisiones tomadas (decision log)

| Fecha | Decisión | Razón |
|---|---|---|
| 2026-04-29 | Mantener Quick usando `OrderScreen` con `OrderOrigin.quick` | Paridad de comportamiento con Zone, evita fork de UI. |
| 2026-04-29 | Cleanup mandatorio post-cobro en Quick (closeOrder + refresh + reopen) | Operador necesita arrancar venta siguiente sin clicks extra. |
| 2026-04-29 | Per-tax `apply_on_<origin>` como fuente única de verdad | UI mostraba un toggle que no surtía efecto — convergemos backend al modelo per-tax. |
| 2026-04-29 | `business_settings.service_fee_on_<origin>` queda como fallback solo si no hay tax con `is_service_fee=true` | Evita romper negocios viejos que no migraron a per-tax. |
| 2026-04-29 | Cache offline rechaza snapshots con orden cerrada | Sin esta validación el state se rehidrata con basura zombie cuando el RPC falla. |

---

## 9. Riesgos abiertos

- **Migración SQL puede romper cobros activos** si hay órdenes en `processPayment` mientras se aplica. Mitigación: aplicar en horario de baja actividad.
- **Cache offline persistente del device**: si `flutter clean` no es suficiente, puede ser necesario reinstalar la app del device para borrar SharedPreferences.
- **Backend RPC `fn_open_manual_or_quick` puede fallar por razones que no vimos**: si el bug zombie persiste tras build limpia, hay que loggear el error real del RPC en `_openManualOrQuick` catch para identificar la causa.

---

## 10. Próximos pasos en orden de prioridad

1. **Aplicar migración SQL** (`20260429_0001_unify_service_fee_per_tax.sql`).
2. **`flutter clean` + `flutter run`** del frontend.
3. **Smoke test §6** end-to-end.
4. Si falla §5.1 (bug zombie persiste): instrumentar `_openManualOrQuick` con `debugPrint` del error real del RPC para identificar causa raíz.
5. Si pasa: commit con todos los fixes, abrir PR contra main.
6. Asignar impuestos a MARGARITAS (D1) y arrancar agente de impresión (D2).
7. Pendiente PRD aparte: refactor `OfflinePosService` para que Quick no use el mismo path que Zone (eliminar deuda de "mesa virtual").
