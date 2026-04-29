# PRD 5 — Módulo de Impresión Unificado (v1.1)

| Campo | Valor |
|---|---|
| **Programa** | Estabilización Operacional MangoPOS |
| **PRD** | 5 |
| **Versión** | **1.1** (incorpora hallazgos de auditoría 2026-04-29) |
| **Fecha** | 2026-04-29 |
| **Autor** | Cristian (DRI) |
| **Estado** | Listo para ejecutar F1.1 |
| **Prioridad** | P1 (no bloquea ventas, pero impacta UX/operación) |
| **Esfuerzo estimado** | 4-5 semanas full-time |
| **Riesgo** | Medio (toca hardware integration multi-plataforma) |
| **Risk Acceptance** | Sin staging real — mismo modelo que PRD 1/2/4. Validación contra negocio de prueba en producción. |

---

## CHANGELOG v1.0 → v1.1

Cambios en esta versión, derivados de las 4 queries de auditoría ejecutadas en producción:

1. **Schema real verificado:** la columna se llama `printers.type`, NO `printers.printer_type`. Todas las referencias del PRD se corrigen.
2. **Enum legacy `printer_type` confirmado** con valores: `network`, `bluetooth`, `usb`. Tres valores, no más.
3. **Cero RPCs SQL referencian el enum** (Q4 retornó vacío). El renombre no requiere recrear funciones.
4. **Solo una columna usa el enum:** `printers.type`. La migration es de alcance acotado.
5. **Decisión arquitectónica nueva:** **Strangler fig** en lugar de reemplazo limpio. Razón: sin staging real, additive es más seguro que destructivo. Patrón ya validado en PRD 2.
6. **Backfill BT confirmado:** todas las impresoras Bluetooth existentes son **Classic (RFCOMM)**. Mapeo `bluetooth → bluetooth_classic` es seguro.
7. **F1 dividida en 4 sub-fases** explícitas (F1.1 a F1.4) en lugar de bloque único, para facilitar cierre incremental.

---

## 1. Executive Summary

(Sin cambios respecto a v1.0)

El módulo de impresión existe parcialmente — soporta **LAN/TCP** completo, **USB en Windows** (vía PowerShell), y **Bluetooth en móviles Android/iOS** (vía agent móvil HTTP local). Falta cierre arquitectónico:

- **USB en Mac/Linux**: no implementado.
- **Bluetooth en desktop**: el código del agent lo acepta, no hay UI ni descubrimiento nativo.
- **Áreas**: 5 hardcodeadas (`kitchen_hot`, `kitchen_cold`, `bar`, `cashier`, `fiscal`); falta UI para crear áreas custom y asignar productos masivamente.
- **Cobertura de tests**: cero (solo `print_ticket_service_test.dart`).
- **Edición de impresora**: TODO sin terminar en `printer_configuration_screen.dart`.
- **UI Bluetooth desktop**: ausente.

Este PRD consolida todo en un sistema cross-platform donde:
1. Cualquier impresora ESC/POS conectada por **USB**, **LAN** o **Bluetooth** se descubre, configura y prueba desde la app sin hacks.
2. Las áreas de impresión son **datos editables**, no enums hardcodeados — el operador crea/renombra áreas desde Ajustes.
3. El agente local de impresión es transparente (auto-discovery, heartbeat, fallback a otro agente si el principal cae).
4. Hay tests dorados que validan el ruteo de jobs por área en cada plataforma.

---

## 2. Goals y Non-Goals

(Sin cambios respecto a v1.0)

### 2.1 Goals

1. **Tres tipos de conexión** funcionando end-to-end en **macOS, Windows, Linux, Android, iOS** (donde aplique):
   - **LAN/TCP** (puerto 9100 ESC/POS)
   - **USB** (vía device path / IOKit en macOS, PowerShell en Windows, libusb en Linux)
   - **Bluetooth** (BLE + RFCOMM, vía bluetooth_low_energy/flutter_bluetooth_serial)
2. **Agente local mejorado**: detección automática, heartbeat con reconexión, una sola fuente de verdad para "qué impresoras están realmente disponibles".
3. **Áreas dinámicas**: CRUD completo desde UI, asignación masiva de productos por categoría/menu, código auto-generado.
4. **UI consolidada**: un solo flow de "Agregar impresora" que:
   - Pregunta el tipo de conexión.
   - Auto-detecta candidates en la red local (LAN), dispositivos USB conectados, devices Bluetooth pareados.
   - Test de impresión inline antes de guardar.
5. **Tests dorados**: cobertura del path de ruteo (item → área → impresora) y de generación de tickets ESC/POS para los casos comunes (cocina, fiscal, factura, pre-cuenta).
6. **Edición de impresora**: completar el TODO existente.

### 2.2 Non-Goals

- Soporte de impresoras térmicas no-ESC/POS (IPP, CUPS-only).
- Diseñador visual de tickets (drag-and-drop). Layout sigue codificado.
- Soporte de drivers Windows propietarios (Star, Epson SDK). Solo ESC/POS estándar.
- Cloud printing (Google Cloud Print, AirPrint pasivo).
- Gestión de papel/cartuchos/alertas hardware avanzadas.

---

## 3. Estado real del schema (verificado 2026-04-29)

### 3.1 Schema actual confirmado

```
Tabla: public.printers
Columna: type
Tipo: printer_type (enum)
Default: 'network'::printer_type
NOT NULL: sí

Enum: printer_type
Valores: network, bluetooth, usb
```

**Cero RPCs SQL referencian el enum.** Solo el código frontend Dart lo usa.

### 3.2 Schema objetivo (post-PRD 5)

```
Tabla: public.printers
  - type: printer_type (LEGACY, queda durante transición strangler fig)
  - connection_kind: printer_connection_kind (NUEVO, source of truth eventual)
  - bluetooth_address: text (NUEVO, opcional)
  - last_heartbeat_at: timestamp (NUEVO)
  - last_seen: timestamp (ya existía)
  - online: boolean (ya existía)

Enum nuevo: printer_connection_kind
Valores:
  - lan_tcp           (mapea de 'network')
  - usb_direct        (mapea de 'usb')
  - bluetooth_classic (mapea de 'bluetooth' — todas las existentes son Classic)
  - bluetooth_le      (nuevo, para devices BLE futuros)
  - agent_proxy       (nuevo, para casos donde agent local media)

Index nuevo: UNIQUE (business_id, name)
```

### 3.3 Decisión arquitectónica: Strangler Fig

**v1.0 proponía:** renombrar enum + columna en una sola migration.
**v1.1 decide:** strangler fig — agregar `connection_kind` paralelo, mantener `type` durante 2-3 semanas, dropear cuando sea seguro.

**Razón:**
- Sin staging real, additive es más seguro que destructivo
- Frontend Dart puede tener referencias a `type` no inventariadas
- Patrón ya validado en PRD 2 con `service_fee` columns
- Rollback trivial en cada paso

**Plan de eliminación de la columna legacy:**
- Migration F1.1: agrega `connection_kind`, mantiene `type`
- Trigger sincroniza `type → connection_kind` en INSERT/UPDATE
- Frontend (Fase 5) migra a leer/escribir `connection_kind`
- Migration final (post-Fase 5): drop column `type`, drop type `printer_type`

---

## 4. Plan por fases (v1.1)

### Fase 1 — Foundations: data model + agent heartbeat (1 semana)

**Cambio v1.1:** F1 dividida en 4 sub-fases con DoD explícito por cada una.

#### F1.1 — Strangler fig setup (0.5 día)

**Alcance:**
- Crear enum `printer_connection_kind` con 5 valores
- Agregar columna `printers.connection_kind` (NOT NULL con default `lan_tcp`)
- Backfill: `network → lan_tcp`, `usb → usb_direct`, `bluetooth → bluetooth_classic`
- Trigger `trg_sync_printer_connection_kind` que mantiene la columna sincronizada al insertar/actualizar con valores de `type` legacy

**Definition of Done F1.1:**
- [ ] Migration aplicada en producción
- [ ] 100% de filas existentes tienen `connection_kind` poblado
- [ ] Trigger probado: INSERT con `type='usb'` → autopobla `connection_kind='usb_direct'`
- [ ] Rollback SQL preparado y testeado mentalmente
- [ ] Bitácora actualizada en STATE_OF_THE_PLATFORM

**Naturaleza:** ADDITIVE. No drop, no rename. Cero downtime.

#### F1.2 — Columnas adicionales + índice (0.5 día)

**Alcance:**
- `ALTER TABLE printers ADD COLUMN bluetooth_address text` (nullable)
- `ALTER TABLE printers ADD COLUMN last_heartbeat_at timestamptz`
- `CREATE UNIQUE INDEX idx_printers_business_name ON printers (business_id, name)`

**Definition of Done F1.2:**
- [ ] Columnas creadas
- [ ] Índice único creado
- [ ] No hay duplicados pre-existentes (auditar antes con query)
- [ ] Bitácora actualizada

**Riesgo:** si hay duplicados de `(business_id, name)` en data actual, el índice falla. **Auditar antes con:**

```sql
SELECT business_id, name, COUNT(*) 
FROM printers 
GROUP BY business_id, name 
HAVING COUNT(*) > 1;
```

Si retorna filas, resolver duplicados antes de crear el índice.

#### F1.3 — RPC heartbeat + cron offline (1 día)

**Alcance:**

```sql
CREATE FUNCTION fn_printer_heartbeat(p_printer_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE printers
  SET online = true,
      last_seen = now(),
      last_heartbeat_at = now()
  WHERE id = p_printer_id;
END;
$$;
```

Cron Supabase (o pg_cron) cada 30s:

```sql
UPDATE printers 
SET online = false 
WHERE last_seen < now() - interval '60 seconds';
```

**Definition of Done F1.3:**
- [ ] RPC creado y testeable manualmente
- [ ] Cron configurado y corriendo (o función equivalente vía Supabase scheduled functions)
- [ ] Test manual: invocar RPC → verificar `last_heartbeat_at` actualizado
- [ ] Test manual: simular pérdida de heartbeat → cron marca offline en 60s

#### F1.4 — Agents reportando heartbeat (1-2 días)

**Alcance:**
- **Agent Node.js (desktop):** modificar `agent/src/core/printer_manager.js` para hacer POST cada 30s al RPC
- **MobilePrintAgent (Android/iOS):** misma lógica vía cliente Supabase
- **Validación visual:** matar agent → impresora marca offline en 60s. Levantar → marca online en 30s.

**Definition of Done F1.4 (= DoD F1 completa):**
- [ ] Desktop agent reportando heartbeat cada 30s en producción
- [ ] Mobile agent reportando heartbeat cada 30s en producción
- [ ] Validación visual exitosa: ciclo offline/online funciona
- [ ] Métrica observable: query SQL que muestra última hora de heartbeats
- [ ] Bitácora actualizada con cierre de F1

**Riesgo F1:** bajo. Solo agrega columnas, índice, función, trigger. Nada destructivo. Rollback trivial en cada sub-fase.

---

### Fase 2 — Conexión USB cross-platform (1.5 semanas)

(Sin cambios significativos respecto a v1.0)

#### F2.1 macOS USB

- Agregar paquete Flutter (`libserialport` o native channel custom) que enumere devices USB con vendor/product IDs comunes de impresoras térmicas.
- Implementar `MacUsbPrinter` en `lib/core/printing/platforms/mac_usb_printer.dart`.
- Test físico con impresora ESC/POS USB en Mac.

#### F2.2 Linux USB

- Usar `libusb` via FFI o package existente.
- Implementar `LinuxUsbPrinter`.

#### F2.3 UI: descubrimiento USB

- Wizard "Agregar impresora" → tipo USB → app enumera devices USB conectados → user selecciona uno → prueba print.

**Riesgo F2:** medio-alto. USB drivers son frágiles. Mitigación: tests con 3+ modelos comunes (Epson TM-T20, Star TSP143, Generic 80mm).

**Nota v1.1:** macOS puede requerir entitlements de Apple Developer. Si bloquea, plan B = mediar USB Mac vía agent Node.js (que ya tiene acceso al filesystem). Documentar en F2.1.

---

### Fase 3 — Bluetooth desktop + UI (1 semana)

#### F3.1 Bluetooth descubrimiento

- Paquete `flutter_blue_plus` o `bluetooth_low_energy` para Mac/Windows/Linux.
- Discovery muestra devices BT pareados que matchean perfil de impresora térmica (Generic Access, SPP).

#### F3.2 Bluetooth print

- Implementar `BluetoothPrinter` que envía bytes ESC/POS por RFCOMM.
- Si BLE: usar característica de transmisión raw.

**Nota v1.1:** todas las impresoras BT existentes en producción son **Classic (RFCOMM)**. Priorizar Classic en F3.2; LE puede quedar como expansión futura si surge necesidad.

#### F3.3 UI consolidada

- Wizard único de "Agregar impresora" con tabs: LAN | USB | Bluetooth.
- Cada tab: descubrimiento auto + manual entry + test.

**Riesgo F3:** medio. Bluetooth es notoriamente flaky. Permitir fallback manual a "ingresar MAC" si descubrimiento falla.

---

### Fase 4 — Áreas + asignación masiva (0.5 semana)

#### F4.1 CRUD áreas

- UI completa para crear/editar/borrar áreas (hoy hay parcial).
- Code se auto-genera del name pero es editable.

#### F4.2 Bulk asignación productos

- Pantalla nueva: lista de áreas → seleccionar área → tabla de productos → checkbox masivo por categoría → guardar.
- Update batch: `UPDATE menu_items SET print_area_code='bar' WHERE category_id=X`.

**Riesgo F4:** bajo.

---

### Fase 5 — Edición + diagnóstico + tests + cleanup strangler fig (1 semana)

**Cambio v1.1:** Fase 5 ahora incluye el cierre del strangler fig.

#### F5.1 Completar edición de impresora

- Resolver el TODO en `printer_configuration_screen.dart`.
- Soportar cambio de IP/puerto/path/MAC sin perder asignaciones a áreas.

#### F5.2 Pantalla de diagnóstico

- Ver agent status (online/offline + última conexión).
- Ping a cada impresora (test sin imprimir).
- Tabla de últimos 20 jobs (estado, error si aplica, timestamp).

#### F5.3 Tests dorados

- `test/printing/`:
  - `routing_test.dart`: dado un menu_item con print_area_code='kitchen_hot', verificar que `_getOrderPrintersWithOfflineFallback` devuelve la impresora correcta y respeta priority.
  - `escpos_generation_test.dart`: ticket de cocina, factura, pre-cuenta — comparar bytes esperados con bytes generados.
  - `multi_area_test.dart`: orden con items en kitchen_hot + bar + cashier — verificar que se agrupan correctamente y se generan 3 jobs separados.

#### F5.4 — Cleanup strangler fig (NUEVO en v1.1)

**Alcance:**
- Migración a leer/escribir `connection_kind` en código Dart (eliminar referencias a `type` legacy)
- Validar 1 semana en producción que `connection_kind` es correcto
- Migration final: `DROP COLUMN type; DROP TYPE printer_type;`
- Drop trigger `trg_sync_printer_connection_kind` (ya no es necesario)

**Definition of Done F5.4:**
- [ ] Cero referencias a `printers.type` o enum `printer_type` en código Dart
- [ ] 1 semana sin issues en producción tras migración Dart
- [ ] Migration final aplicada
- [ ] Bitácora cierra el ciclo strangler fig

**Riesgo F5:** bajo (solo agrega tests, completa UI, hace cleanup planificado).

---

## 5. Test Plan

(Sin cambios significativos respecto a v1.0)

### 5.1 Tests dorados (CI gate)

- Routing per-área, multi-área, sin impresora asignada (debe lanzar `NoAssignedKitchenPrinterException`).
- Generación ESC/POS para cada plantilla (cocina, factura, pre-cuenta, comanda agrupada).
- Caché de lookups (TTL 5 min) — no llamar repo cuando hay cache válido.

### 5.2 UAT manual por plataforma

Para cada plataforma (Mac, Win, Linux, Android, iOS):
- Agregar impresora LAN → test print → cobrar venta → verificar que la factura imprime.
- Agregar impresora USB → mismo ciclo.
- Agregar impresora Bluetooth (si aplica) → mismo ciclo.

### 5.3 Tests de regresión

- Flujo "Enviar a Cocina" no se rompe con esta migración.
- Items con `print_area_code` legacy (string vs enum) siguen funcionando.

### 5.4 Validación strangler fig (NUEVO en v1.1)

Por cada fase, antes de cerrarla:
- Query SQL: `SELECT type, connection_kind, COUNT(*) FROM printers GROUP BY type, connection_kind`
- Esperado: cada `type` legacy mapea consistentemente a su `connection_kind` correspondiente
- Si hay drift (filas con `type='usb'` pero `connection_kind='lan_tcp'` por error humano), investigar antes de avanzar

---

## 6. Rollout Plan

1. **Pre-deploy F1.1**: backup DB + auditar duplicados (business_id, name).
2. **F1.1 deploy**: strangler fig setup. Bajo riesgo, deploy ventana normal.
3. **F1.2 deploy**: columnas adicionales + índice.
4. **F1.3 deploy**: RPC heartbeat + cron.
5. **F1.4 deploy**: agents reportando.
6. **F2 deploy**: USB Mac/Linux. Necesita binarios firmados (Mac), test físico.
7. **F3 deploy**: Bluetooth. Beta por una semana antes de release general.
8. **F4 deploy**: áreas + bulk. Bajo riesgo.
9. **F5.1-F5.3 deploy**: tests + diagnóstico. CI gate desde aquí en adelante.
10. **F5.4 deploy**: cleanup final strangler fig (drop column + enum legacy).

---

## 7. Rollback Plan

(Refinado en v1.1 con sub-fases)

- **F1.1** → Migration es additive. Rollback: drop trigger + drop column `connection_kind` + drop type `printer_connection_kind`. Cero impacto en código existente.
- **F1.2** → drop columnas + drop índice. Trivial.
- **F1.3** → drop function + drop cron. Trivial.
- **F1.4** → revert agent code. Heartbeat se puede deshabilitar con feature flag.
- **F2/F3** → si una plataforma falla, deshabilitar el tipo de conexión vía feature flag por business.
- **F4** → revert frontend commit + hot restart.
- **F5.1-F5.3** → revert frontend commit.
- **F5.4** → **NO TIENE ROLLBACK SIMPLE** (drop de columna y enum legacy es irreversible sin backup). Por eso F5.4 solo se aplica después de 1 semana de validación en producción de Fase 5.1-5.3 sin issues.

---

## 8. Risks

| # | Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|---|
| R1 | USB drivers en Mac requieren entitlements adicionales | Media | Alto | Plan B: agent intermediario para USB Mac (vía Node.js native module). |
| R2 | Bluetooth flaky en distintas impresoras | Alta | Medio | Whitelist de modelos certificados. Manual MAC entry como fallback. v1.1: priorizar Classic, LE como expansión futura. |
| R3 | Heartbeat agresivo carga el backend | Baja | Medio | Throttle: una sola RPC por agent cada 30s, no por impresora. |
| R4 | Migración rompe ruteo histórico | Baja | Alto | Validar con queries en staging antes de deploy producción. v1.1: strangler fig elimina este riesgo en F1. |
| R5 | UI confunde tipos de conexión | Media | Bajo | UAT con 2-3 operadores reales antes de release. |
| **R6 (NUEVO)** | **Frontend Dart tiene referencias a `printers.type` no inventariadas** | **Media** | **Medio** | **Strangler fig: trigger mantiene `type` sincronizado durante toda la migración. Drop final solo después de 1 semana sin uso.** |
| **R7 (NUEVO)** | **Duplicados de `(business_id, name)` bloquean F1.2** | **Baja** | **Bajo** | **Auditar con query antes de crear índice. Resolver duplicados manualmente si aparecen.** |

---

## 9. Definition of Done

PRD 5 está completo cuando:

- [ ] Todas las migrations F1.1 a F1.4 aplicadas en producción
- [ ] Agent heartbeat reportando cada 30s (desktop + mobile)
- [ ] USB funcionando en macOS y Linux con al menos 1 modelo común probado
- [ ] Bluetooth Classic funcionando en al menos macOS y Android con 1 modelo probado
- [ ] UI consolidada de Ajustes > Impresión con los 3 tipos
- [ ] CRUD áreas + bulk asignación productos
- [ ] Edición de impresora completa (TODO resuelto)
- [ ] Pantalla de diagnóstico operativa
- [ ] Tests dorados pasando 100% en CI
- [ ] UAT 5.2 ejecutado en 3 plataformas mínimas
- [ ] **Strangler fig cerrado: `printers.type` y enum `printer_type` eliminados (F5.4)**
- [ ] 1 semana de observación post-deploy sin regresiones
- [ ] `PRD_05_POSTMORTEM.md` con lecciones aprendidas

---

## 10. Decision Log

| # | Fecha | Decisión | Razón |
|---|---|---|---|
| AD5-1 | 2026-04-29 | Mantener arquitectura agent-based, no eliminar el Node.js agent | Permite USB en Windows sin reescribir todo en Dart. |
| AD5-2 | 2026-04-29 | Áreas como datos en DB, no enum hardcodeado | Operador necesita crear áreas custom (ej. "Bar 2do piso"). |
| AD5-3 | 2026-04-29 | NO soportar drivers Windows propietarios | Aumentaría blast radius sin valor proporcional para nuestra base. |
| AD5-4 | 2026-04-29 | Bluetooth con whitelist de modelos certificados | BT cross-vendor ESC/POS es un campo minado, mejor whitelist explícita. |
| AD5-5 | 2026-04-29 | Heartbeat cada 30s vía RPC dedicada (no DB direct write) | Permite agregar lógica futura (alertas, métricas) sin tocar agent. |
| AD5-6 | 2026-04-29 | Comandas se splittean por área (kitchen_hot, bar, etc.); facturas/recibos NO se splittean | Operativa real: cocina y barra tienen impresoras separadas; al cliente se le da UNA factura. |
| AD5-7 | 2026-04-29 | Una impresora puede asignarse a múltiples áreas (ej. cashier + fiscal en el mismo device) | Reduce costos para negocios pequeños. UI debe permitir multi-asignación, no forzar duplicados. |
| AD5-8 | 2026-04-29 | Para facturas: 1 impresora elegida por priority en el área (con fallback) | Confirma comportamiento actual de `getReadyPrintersForArea`. Sin paralelo. |
| **AD5-9** (v1.1) | 2026-04-29 | **Strangler fig en lugar de reemplazo limpio para enum** | **Sin staging real, additive es más seguro. Patrón ya validado en PRD 2 con service_fee.** |
| **AD5-10** (v1.1) | 2026-04-29 | **Backfill `bluetooth → bluetooth_classic` automático** | **Auditoría confirmó: todas las impresoras BT existentes son Classic (RFCOMM).** |
| **AD5-11** (v1.1) | 2026-04-29 | **F1 dividida en 4 sub-fases con DoD explícito por cada una** | **Lección de PRD 2: cierre incremental reduce blast radius si algo sale mal.** |
| **AD5-12** (v1.1) | 2026-04-29 | **Drop final de columna `type` y enum `printer_type` recién en F5.4** | **Solo después de 1 semana de validación de Fase 5.1-5.3 sin issues.** |

---

## 11. Open Questions

### 11.1 Resueltas (input DRI 2026-04-29)

| # | Pregunta | Decisión |
|---|---|---|
| RES-1 | ¿Una **comanda** (ticket de cocina/barra) puede ir a varias impresoras al mismo tiempo? | **SÍ.** Una comanda con items mixtos (bebida + comida) se splittea: items con `print_area_code='kitchen_hot'` van a la impresora de cocina, items con `print_area_code='bar'` van a barra. **Comportamiento existente, mantener.** |
| RES-2 | ¿Una **factura** (recibo del cliente / fiscal) puede ir a varias impresoras al mismo tiempo? | **NO.** La factura va a UNA sola impresora — la de mayor priority en el área `cashier` o `fiscal` según corresponda. Si esa cae, fallback al siguiente por priority. |
| RES-3 | ¿Fiscal debe ser una impresora exclusiva (solo facturas fiscales)? | **NO.** La impresora marcada como fiscal puede también imprimir todas las facturas regulares de caja. Una sola impresora puede pertenecer a `cashier` Y `fiscal` simultáneamente vía `print_area_printers`. |
| **RES-4** (v1.1) | **¿Renombrar enum o agregar valores?** | **Strangler fig: nuevo enum `printer_connection_kind` paralelo al `printer_type` legacy. Migración gradual via trigger.** |
| **RES-5** (v1.1) | **¿Backfill de `bluetooth` legacy a Classic o LE?** | **Classic. Auditoría confirma todas las BT existentes son Classic (RFCOMM).** |

### 11.2 Pendientes

1. **Soporte para impresoras seriales (RS-232)**? No común en POS modernos pero algunas cocinas viejas las usan. **Decisión preliminar**: NO en este PRD, escalar si surge.
2. **Cola persistente de jobs**: hoy `print_jobs` existe pero los jobs fallidos no se reintentan automáticamente. ¿Implementar retry con exponential backoff? **Probable scope de Fase 5**.
3. **¿Cuántas impresoras puede tener un negocio simultáneamente** (límite por plan)? Hoy no hay límite. Hablar con producto si aplica.

---

## 12. Próximos pasos

1. ✅ ~~Auditoría de schema actual~~ (completada 2026-04-29, ver §3.1)
2. **Crear branch `prd/05-printing-unified`**
3. **Ejecutar F1.1**: strangler fig setup (migration additive + trigger)
4. **Validar F1.1** con queries de verificación
5. Si F1.1 OK → proceder a F1.2

---

## 13. Bitácora

| Fecha | Evento |
|---|---|
| 2026-04-29 | PRD 5 v1.0 redactado por DRI. |
| 2026-04-29 | Auditoría de schema ejecutada. Hallazgos: columna `printers.type` (no `printer_type`); enum legacy con 3 valores; cero RPCs lo referencian; todas las BT existentes son Classic. |
| 2026-04-29 | PRD 5 v1.1 publicado. Cambios: strangler fig en lugar de reemplazo limpio (AD5-9); F1 dividida en 4 sub-fases (AD5-11); F5.4 cleanup agregada (AD5-12). |
| _por completar_ | F1.1 ejecutada |

---

*PRD 5 v1.1 generado el 2026-04-29 incorporando auditoría de schema actual.*
*Próxima revisión: tras cierre de F1.1.*