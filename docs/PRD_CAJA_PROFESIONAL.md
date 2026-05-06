# PRD — Modelo Profesional de Cajas

**Estado:** En backlog. Hay un fix preliminar aplicado (ver "Estado actual"); este PRD evoluciona el modelo a uno completo, comparable con Toast/Square/Lightspeed.

**Objetivo:** que MangoPOS soporte de forma robusta múltiples cajas físicas por negocio, autorización de cierre por gerencia y trazabilidad completa de ventas por sesión.

---

## 1. Contexto

### Problema operativo original (resuelto parcialmente)

- Cuando un cajero (rol `cashier`) abría caja, otros empleados del local (mesero, admin) veían "Caja cerrada" en la pantalla de Ventas y no podían agregar productos a mesas.
- Inconsistencia entre dashboard de Caja ("Abierta") y pantalla de Ventas ("Cerrada") por dos lógicas no coordinadas.
- Causa: la búsqueda de "caja activa" filtraba por `user_id` del usuario actual.

### Modelo de negocio confirmado por el cliente

- Un negocio puede tener **múltiples cash_registers** (ej. "Caja Principal", "Caja Bar").
- Cada caja **NO se comparte entre cajeros distintos** (un cajero no abre la caja de otro).
- Pero **mesero/admin pueden vender** si la caja del register al que están asociados está abierta.
- El cliente puede pagar al día siguiente: cuentas pueden mantenerse abiertas >24h por diseño.

### Estado actual (post-fix preliminar — 2026-05-04)

Aplicado en commits recientes:

- `cashier_repository.getActiveSessionForRegister(registerId)` — busca la sesión abierta de un register sin filtrar por user.
- `cashier_viewmodel.init()` y `ensureCashOpenFast()` usan ese método.
- `init()` toma `registers.first` como register actual (limitación conocida — ver mejora #3).
- Cierre sigue restringido al dueño en cliente y RPC `fn_close_cash_session`.

Resultado: el bug visible está resuelto. Pero quedan 3 gaps profesionales documentados a continuación.

---

## 2. Mejoras propuestas

### Mejora #1 — Autorización de cierre por gerencia

**Problema:** Si el cajero termina su turno y se va sin cerrar, la caja queda zombie. Hoy nadie más puede cerrarla. Vimos en producción cajas abiertas hace 40+ días por este motivo.

**Solución:**

- Permitir cerrar caja ajena si el caller tiene rol `owner`, `admin` o `manager`.
- Registrar en `cash_register_sessions.notes` (o columna nueva `closed_by_user_id`) quién cerró si no es el dueño, para auditoría.
- En la UI: si caja no es del usuario actual, mostrar botón "Cerrar caja del cajero" con confirmación + opcional PIN supervisor.

**Archivos:**

- `supabase/migrations/<fecha>_close_cash_session_authorized_by_role.sql` — modificar `fn_close_cash_session` para aceptar caller con jerarquía superior. Posiblemente agregar columna `closed_by_user_id`.
- `lib/presentation/cashier/view/cashier_view.dart` — en línea ~165, relajar la validación si rol del caller es admin/manager/owner.
- `lib/presentation/cashier/viewmodel/cashier_viewmodel.dart` — método nuevo `closeForeignSession(sessionId)` con confirmación.

**Criterios de aceptación:**

- Owner/Admin/Manager puede cerrar caja de otro cajero, queda registrado en notas/columna.
- Cashier/Waiter no puede cerrar caja ajena (mismo error que hoy).
- Reporte de cierre muestra "cerrada por <admin> en nombre de <cajero>".

---

### Mejora #2 — Trazabilidad de ventas por sesión de caja

**Problema:** Cada venta debe atarse a la sesión de caja activa al momento del pago para que los reportes Z (cierre) sean correctos. Con el fix preliminar (caja por register), hay que verificar que las ventas se asocien correctamente.

**Investigación necesaria** (antes de implementar):

- ¿La tabla `orders` o `payments` tiene `cash_session_id`? Si sí, ¿se popula correctamente?
- ¿Cómo determina el RPC de pago a qué sesión asociarse? ¿Por `user_id` (mala) o por `register_id` (buena)?
- ¿Los reportes de cierre filtran por `session_id` o por `user_id` + rango de fechas?

**Solución (asumiendo el peor caso):**

- Asegurar que `payments.cash_session_id` (o equivalente) esté poblado al cobrar.
- Modificar RPC de pago para que tome el `cash_session_id` activo del register donde se cobra (no del user).
- Validar que el reporte de cierre (`fn_close_cash_session` o vista equivalente) sume todo lo cobrado en esa sesión, sin importar qué empleado lo procesó.

**Archivos a auditar:**

- `lib/data/repositories/sales_repository.dart` — RPC de pago atómico (`fn_process_payment_atomic`?).
- `supabase/migrations/<existing>` — buscar definición de columna `cash_session_id`.
- `lib/presentation/cashier/viewmodel/cashier_viewmodel.dart` — método de generación de reporte Z.

**Criterios de aceptación:**

- Si Maria abre Caja Principal, Jose vende a mesa SP01, Maria cobra → el pago aparece en el cierre Z de Maria.
- Si en el mismo register se cambia de cajero (ej. Maria cierra y Cristian abre), las ventas de cada turno quedan en su sesión correspondiente.
- Reportes contables cuadran sin manipulación manual.

---

### Mejora #3 — Vinculación device ↔ cash_register

**Problema:** Hoy `cashier_viewmodel.init()` toma `registers.first` como el register actual. Si hay múltiples cajas físicas, el sistema no sabe cuál usar y todos los terminales operan contra la misma. Los terminales del Bar venden por la caja del salón.

**Solución:**

- Nueva tabla `device_register_assignments`:
  ```
  device_id        text    PK
  cash_register_id uuid    FK -> cash_registers
  business_id      uuid    FK -> businesses
  assigned_at      timestamptz
  assigned_by      uuid    FK -> auth.users
  ```
- En settings: pantalla nueva "Asignar terminales a cajas" donde owner/admin asocia cada `device_id` con un register.
- En `cashier_viewmodel.init()`: en lugar de `registers.first`, leer `device_register_assignments` para `getDeviceId()` actual.
- Si un terminal no está asignado: usar el primer register como fallback + alertar al admin.

**Archivos:**

- `supabase/migrations/<fecha>_device_register_assignments.sql`
- `lib/presentation/settings/<nueva pantalla>` — UI de asignación.
- `lib/data/repositories/cashier_repository.dart` — método `getRegisterForDevice(deviceId)`.
- `lib/presentation/cashier/viewmodel/cashier_viewmodel.dart` — usar el register asignado.

**Criterios de aceptación:**

- Owner asigna Terminal A → Caja Principal, Terminal B → Caja Bar.
- Empleados en Terminal A operan solo contra Caja Principal.
- Empleados en Terminal B operan solo contra Caja Bar.
- Las ventas y cobros de cada terminal quedan en su register correcto.
- Funciona en web (donde `device_id` está en localStorage del navegador).

**Riesgos:**

- En web, cambiar de navegador genera nuevo device_id → asignación se pierde. Mitigación: permitir reasignar fácilmente desde settings, mostrar alerta en pantalla de Caja si terminal no está asignado.
- Múltiples meseros en el mismo Terminal: todos comparten el register asignado. OK.

---

## 3. Decisiones pendientes (a confirmar antes de implementar)

1. **Mejora #1 — autorización de cierre:** ¿requiere PIN del manager para cerrar caja ajena, o basta con que el manager esté logueado? Sugerencia: PIN supervisor (consistente con flujo de eliminación de items).
2. **Mejora #2 — RPC de pago:** ¿hay un `cash_session_id` en `payments` actualmente? Si no, agregarlo implica migrar histórico (decisión: ¿retroactivo o solo nuevas?).
3. **Mejora #3 — fallback:** si un terminal no está asignado, ¿bloqueamos las ventas o usamos el primer register? Sugerencia: bloquear con mensaje claro "Configura el register de este terminal en Settings".

---

## 4. Orden de implementación sugerido

1. **#1 (Autorización de cierre)** — alto valor operacional, bajo riesgo. Resuelve cajas zombie.
2. **#2 (Trazabilidad)** — auditoría y reportes correctos. Investigar primero, implementar según lo que falte.
3. **#3 (Device ↔ Register)** — cuando el cliente agregue una segunda caja física. Hasta entonces, fallback a `registers.first` funciona.

---

## 5. Riesgos generales

- **Compatibilidad con cierres en proceso:** los cambios al RPC `fn_close_cash_session` deben preservar comportamiento para cajeros que cierran su propia caja.
- **Auditoría legal/fiscal:** en RD el reporte Z toca DGII. Cualquier cambio a trazabilidad debe validarse con contador.
- **Migración de datos histórica:** si agregamos columnas (`closed_by_user_id`, `cash_session_id` en payments), decidir si poblamos histórico o solo nuevos.

---

## 6. Referencias a código actual

- Cashier viewmodel: `lib/presentation/cashier/viewmodel/cashier_viewmodel.dart`
- Cashier repository: `lib/data/repositories/cashier_repository.dart`
- Cashier view (validación de cierre): `lib/presentation/cashier/view/cashier_view.dart:155-176`
- RPC apertura/cierre: `supabase/migrations/20260401_0002_device_bound_cash_sessions.sql`
- Schema sessions: `supabase/schema.sql` (tabla `cash_register_sessions`)

---

**Última actualización:** 2026-05-04
**Autor:** sesión de fix con Claude
**Próximo paso:** validar mejora #1 con el cliente antes de implementar.
