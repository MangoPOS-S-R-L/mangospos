# PRD 5 — Módulo de Impresión Unificado

| Campo | Valor |
|---|---|
| **Programa** | Estabilización Operacional MangoPOS |
| **PRD** | 5 |
| **Versión** | 1.0 |
| **Fecha** | 2026-04-29 |
| **Autor** | Cristian (DRI) |
| **Estado** | Draft — listo para validar con DRI antes de F1 |
| **Prioridad** | P1 (no bloquea ventas, pero impacta UX/operación) |
| **Esfuerzo estimado** | 4-5 semanas full-time |
| **Riesgo** | Medio (toca hardware integration multi-plataforma) |

---

## 1. Executive Summary

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

## 3. Arquitectura objetivo

### 3.1 Capa de datos

Tablas existentes (mantener, ajustar columnas si es necesario):

- `printers`: agregar columnas opcionales `bluetooth_address` (MAC BT), `connection_kind` (enum más explícito).
- `print_areas`: ya soporta CRUD; nada que cambiar.
- `print_area_printers`: relación N:N, con `priority` y flags `prints_orders`/`prints_prebills`/`prints_receipts`. Bien.
- `print_jobs`: queue de jobs. Mantener.

Nueva enum sugerida (renombrar el actual o extender):

```sql
CREATE TYPE printer_connection_kind AS ENUM (
  'lan_tcp',         -- IP + puerto, protocolo TCP raw
  'usb_direct',      -- device path local
  'bluetooth_classic', -- RFCOMM
  'bluetooth_le',    -- BLE GATT
  'agent_proxy'      -- mediado por agent (cuando no se puede directo)
);
```

### 3.2 Capa de servicio (agente local)

- Mantener el agent Node.js para Windows/Mac/Linux desktop (printer_manager.js).
- Mantener `MobilePrintAgent` para Android/iOS.
- **Nueva responsabilidad**: heartbeat regular (30s) que actualiza `printers.online` y `last_seen` en DB. Si una impresora no reporta en 60s, marcarla offline.
- **Auto-discovery**: el agent escanea su LAN local y reporta candidatos (IPs que responden en 9100). UI los muestra como "sugeridos".

### 3.3 Capa de UI (Flutter)

Pantalla principal: **Ajustes > Impresión**, con 4 secciones:

1. **Impresoras** (CRUD): lista actual + botón "Agregar impresora" → wizard 3 pasos (tipo, descubrimiento/manual, prueba).
2. **Áreas**: CRUD de áreas con código auto (ej. nuevo "Bar 2do piso" → code `bar_2`). Cada área ve qué impresoras tiene asignadas.
3. **Asignar productos**: bulk picker. Por categoría seleccionable, asignar todos sus productos al área X.
4. **Diagnóstico**: estado del agent local + ping a cada impresora + último job exitoso + jobs fallidos del día.

### 3.4 Flujo de ruteo (existente, validar)

```
order_item.print_area_code → busca print_area por code →
print_area_printers join printers (enabled=true, prints_orders=true) →
ordenar por priority → enviar al primero, fallback al siguiente si falla.
```

Mantener este flow. Solo agregar **logging estructurado** y **retry con backoff** para jobs fallidos.

---

## 4. Plan por fases

### Fase 1 — Foundations: data model + agent heartbeat (1 semana)

#### F1.1 Migration SQL

- Agregar columnas `bluetooth_address`, `connection_kind`, `last_heartbeat_at` a `printers`.
- Renombrar enum `printer_type` a `printer_connection_kind` con backfill.
- Agregar índice único `(business_id, name)` para evitar duplicados.

#### F1.2 Agent heartbeat

- Modificar `agent/src/core/printer_manager.js`: cada 30s hace POST `/heartbeat` a Supabase Function que actualiza `printers.last_seen`.
- Modificar `MobilePrintAgent`: misma lógica vía RPC `fn_printer_heartbeat`.
- RPC nueva en backend:

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

#### F1.3 Marcar offline tras 60s

- Cron job (Supabase scheduled function) cada 30s: `UPDATE printers SET online=false WHERE last_seen < now() - interval '60 seconds'`.

**Riesgo F1**: bajo. Solo agrega columnas y triggers.

### Fase 2 — Conexión USB cross-platform (1.5 semanas)

#### F2.1 macOS USB

- Agregar paquete Flutter (`libserialport` o native channel custom) que enumere devices USB con vendor/product IDs comunes de impresoras térmicas.
- Implementar `MacUsbPrinter` en `lib/core/printing/platforms/mac_usb_printer.dart`.
- Test físico con impresora ESC/POS USB en Mac.

#### F2.2 Linux USB

- Usar `libusb` via FFI o package existente.
- Implementar `LinuxUsbPrinter`.

#### F2.3 UI: descubrimiento USB

- Wizard "Agregar impresora" → tipo USB → app enumera devices USB conectados → user selecciona uno → prueba print.

**Riesgo F2**: medio-alto. USB drivers son frágiles. Mitigación: tests con 3+ modelos comunes (Epson TM-T20, Star TSP143, Generic 80mm).

### Fase 3 — Bluetooth desktop + UI (1 semana)

#### F3.1 Bluetooth descubrimiento

- Paquete `flutter_blue_plus` o `bluetooth_low_energy` para Mac/Windows/Linux.
- Discovery muestra devices BT pareados que matchean perfil de impresora térmica (Generic Access, SPP).

#### F3.2 Bluetooth print

- Implementar `BluetoothPrinter` que envía bytes ESC/POS por RFCOMM.
- Si BLE: usar característica de transmisión raw.

#### F3.3 UI consolidada

- Wizard único de "Agregar impresora" con tabs: LAN | USB | Bluetooth.
- Cada tab: descubrimiento auto + manual entry + test.

**Riesgo F3**: medio. Bluetooth es notoriamente flaky. Permitir fallback manual a "ingresar MAC" si descubrimiento falla.

### Fase 4 — Áreas + asignación masiva (0.5 semana)

#### F4.1 CRUD áreas

- UI completa para crear/editar/borrar áreas (hoy hay parcial).
- Code se auto-genera del name pero es editable.

#### F4.2 Bulk asignación productos

- Pantalla nueva: lista de áreas → seleccionar área → tabla de productos → checkbox masivo por categoría → guardar.
- Update batch: `UPDATE menu_items SET print_area_code='bar' WHERE category_id=X`.

**Riesgo F4**: bajo.

### Fase 5 — Edición + diagnóstico + tests (1 semana)

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

**Riesgo F5**: bajo (solo agrega tests y completa UI).

---

## 5. Test Plan

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

---

## 6. Rollout Plan

1. **Pre-deploy**: backup DB.
2. **F1 deploy**: migration columnas + heartbeat. Bajo riesgo, deploy ventana normal.
3. **F2 deploy**: USB Mac/Linux. Necesita binarios firmados (Mac), test físico.
4. **F3 deploy**: Bluetooth. Beta por una semana antes de release general.
5. **F4 deploy**: áreas + bulk. Bajo riesgo.
6. **F5 deploy**: tests + diagnóstico. CI gate desde aquí en adelante.

---

## 7. Rollback Plan

- F1 → migration es additive (solo columnas nuevas), no requiere rollback. Heartbeat se puede deshabilitar con feature flag.
- F2/F3 → si una plataforma falla, deshabilitar el tipo de conexión vía feature flag por business.
- F4/F5 → revert frontend commit + hot restart.

---

## 8. Risks

| # | Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|---|
| R1 | USB drivers en Mac requieren entitlements adicionales | Media | Alto | Plan B: agent intermediario para USB Mac (vía Node.js native module). |
| R2 | Bluetooth flaky en distintas impresoras | Alta | Medio | Whitelist de modelos certificados. Manual MAC entry como fallback. |
| R3 | Heartbeat agresivo carga el backend | Baja | Medio | Throttle: una sola RPC por agent cada 30s, no por impresora. |
| R4 | Migración rompe ruteo histórico | Baja | Alto | Validar con queries en staging antes de deploy producción. |
| R5 | UI confunde tipos de conexión | Media | Bajo | UAT con 2-3 operadores reales antes de release. |

---

## 9. Definition of Done

PRD 5 está completo cuando:

- [ ] Migration F1 aplicada en producción.
- [ ] Agent heartbeat reportando cada 30s.
- [ ] USB funcionando en macOS y Linux con al menos 1 modelo común probado.
- [ ] Bluetooth funcionando en al menos macOS y Android con 1 modelo probado.
- [ ] UI consolidada de Ajustes > Impresión con los 3 tipos.
- [ ] CRUD áreas + bulk asignación productos.
- [ ] Edición de impresora completa (TODO resuelto).
- [ ] Pantalla de diagnóstico operativa.
- [ ] Tests dorados pasando 100% en CI.
- [ ] UAT 5.2 ejecutado en 3 plataformas mínimas.
- [ ] 1 semana de observación post-deploy sin regresiones.
- [ ] `PRD_05_POSTMORTEM.md` con lecciones aprendidas.

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

---

## 11. Open Questions

1. **Soporte para impresoras seriales (RS-232)**? No común en POS modernos pero algunas cocinas viejas las usan. **Decisión preliminar**: NO en este PRD, escalar si surge.
2. **Cola persistente de jobs**: hoy `print_jobs` existe pero los jobs fallidos no se reintentan automáticamente. ¿Implementar retry con exponential backoff? **Probable scope de Fase 5**.
3. **¿Cuántas impresoras puede tener un negocio simultáneamente** (límite por plan)? Hoy no hay límite. Hablar con producto si aplica.

### 11.1 Resueltas (input DRI 2026-04-29)

| # | Pregunta | Decisión |
|---|---|---|
| RES-1 | ¿Una **comanda** (ticket de cocina/barra) puede ir a varias impresoras al mismo tiempo? | **SÍ.** Una comanda con items mixtos (bebida + comida) se splittea: items con `print_area_code='kitchen_hot'` van a la impresora de cocina, items con `print_area_code='bar'` van a barra. **Comportamiento existente, mantener.** |
| RES-2 | ¿Una **factura** (recibo del cliente / fiscal) puede ir a varias impresoras al mismo tiempo? | **NO.** La factura va a UNA sola impresora — la de mayor priority en el área `cashier` o `fiscal` según corresponda. Si esa cae, fallback al siguiente por priority. **Confirma comportamiento actual de `getReadyPrintersForArea`.** |
| RES-3 | ¿Fiscal debe ser una impresora exclusiva (solo facturas fiscales)? | **NO.** La impresora marcada como fiscal puede también imprimir todas las facturas regulares de caja. Es decir: una sola impresora puede pertenecer a las áreas `cashier` Y `fiscal` simultáneamente vía `print_area_printers`. **Implicación**: el wizard "Agregar impresora" debe permitir asignar la misma impresora a múltiples áreas, no obligar a duplicar registros. |

---

## 12. Próximos pasos

1. **Validar este PRD con DRI** (Cristian) antes de F1.
2. Resolver Open Questions §11.
3. Iniciar F1: escribir migration + heartbeat + RPC.
4. Reservar ventana de deploy de bajo tráfico para cada fase.

---

*PRD 5 generado el 2026-04-29 después de cerrar PRD 4 (Quick) y PRD 2.5 (tax engine consolidation).*
