# PRD — Cuentas pendientes en Mango Administrador

**Estado:** propuesta / por implementar en el panel admin
**Owner:** Cristian
**Fecha:** 2026-05-27
**Relacionado con:**
- Migration `20260527_0005_businesses_status_pending.sql` (POS)
- Cambio en `register_step2_viewmodel.dart` (POS, `status='pending'` en alta)
- `PendingApprovalGuard` + `PendingApprovalScreen` (POS)

---

## 1. Problema

Hasta ahora, cualquier persona que completaba el registro en la app del POS
quedaba con `businesses.status='active'` y entraba directo al panel. Esto nos
deja sin control de:

- Verificar que el negocio existe y los datos son reales (filtra spam y
  cuentas de prueba accidentales).
- Verificar pago / método de cobro / plan asignado antes de habilitar.
- Onboarding "guiado" — llamar al dueño antes de que use mal el sistema y
  pida soporte.

A partir del 27 de mayo de 2026, las cuentas **nuevas** nacen con
`status='pending'` y la app del POS las bloquea con una pantalla "Tu cuenta
está en revisión". El equipo interno tiene que activarlas manualmente desde
Mango Administrador.

**Las cuentas legacy** (creadas antes de esa migration) siguen como
`'active'` — no se las toca. El admin puede pasarlas a `'inactive'` si hace
falta.

---

## 2. Objetivo

Que el equipo de operaciones tenga una pantalla en Mango Administrador
para:

1. **Ver** todas las cuentas que están en `status='pending'`.
2. **Aprobar** una cuenta (cambia el status a `'active'` → la app se
   desbloquea sola en el próximo poll del guard).
3. **Rechazar / suspender** una cuenta (cambia el status a `'inactive'`).
4. **Comunicar** al dueño por correo cuando se aprueba o rechaza.

---

## 3. Quién lo usa

- Equipo de soporte / onboarding de MangoPOS.
- Probablemente con rol `admin` o `superadmin` en el panel administrativo
  (no es para clientes finales).

---

## 4. Pantalla / Flujo propuesto

### 4.1 Lista "Cuentas pendientes"

Una tab o sección nueva en Mango Administrador, idealmente como primer
ítem del menú de soporte (es la cola de trabajo del día).

**Columnas:**

| Columna | Fuente | Notas |
|---|---|---|
| Negocio | `businesses.business_name` | |
| Sucursal | `businesses.branch_name` | "Sucursal Principal" si no se especificó |
| Dueño | `profiles.full_name` | join por `businesses.owner_id = profiles.id` |
| Email | `profiles.email` (o `auth.users.email`) | el que usaron para registrarse |
| Teléfono | `businesses.phone` | opcional, puede ser null |
| País | `businesses.country` | |
| Plan | `plans.name` o `plans.code` | join `memberships.plan_id → plans.id` filtrando `memberships.is_billing_anchor=true` |
| Trial hasta | `memberships.trial_ends_at` | mostrar "vence en X días" |
| Tiene tarjeta | `payment_methods.status='verified'` existe | join por `business_id`. Sí/No |
| Registrada | `businesses.created_at` | "hace 2 horas", "ayer", etc. |

**Filtros / orden:**
- Default: `status='pending'` ordenado por `created_at DESC` (más
  recientes primero).
- Filtro rápido "Con tarjeta verificada" vs "Sin tarjeta" — útil para
  priorizar a quienes ya pagaron.
- Búsqueda por nombre de negocio, email o ID.

### 4.2 Detalle de la cuenta

Al hacer click en una fila, abrir un panel lateral o modal con:

- **Bloque "Cuenta"**
  - Email del dueño + nombre + teléfono
  - Negocio, sucursal, tipo de negocio, dirección
  - Subdominio asignado (`businesses.domain`)
  - Fecha de registro
  - País
- **Bloque "Plan & billing"**
  - Plan elegido, monto, trial_ends_at
  - Estado de billing (`memberships.billing_status`)
  - Si hay método de pago: marca, últimos 4, status (`verified` / `pending` /
    `failed`)
  - Link a "Ver historial de cobros" (si aplica)
- **Bloque "Acciones"** (ver 4.3)

### 4.3 Acciones

**1. Activar cuenta**
- Botón principal, color verde / primario.
- Confirmación: "¿Activar la cuenta de **Negocio X**? El dueño podrá
  entrar inmediatamente."
- Backend: `UPDATE businesses SET status='active', updated_at=now() WHERE id=$1`.
- Side effect: enviar correo al dueño ("¡Tu cuenta ya está activa!",
  link al POS). Plantilla nueva en el provider de correo.
- Telemetría: insertar fila en `business_status_audit` (ver 5.3) con
  `actor_user_id`, `from_status`, `to_status`, `reason='approved'`.

**2. Rechazar cuenta**
- Botón secundario, color rojo.
- Pedir motivo (textarea obligatoria, mínimo 10 caracteres).
- Confirmación con preview del correo que va a recibir el dueño.
- Backend: `UPDATE businesses SET status='inactive', updated_at=now() WHERE id=$1`.
- Side effect: enviar correo al dueño con el motivo redactado.
- Telemetría: igual que activar, con `reason='rejected: <motivo>'`.

**3. Suspender (para cuentas ya activas, no pending)**
- Misma acción que rechazar, pero desde el detalle de una cuenta
  `active`. Útil para cortar acceso por mora, fraude, etc.

**4. Reactivar (para cuentas inactive)**
- Vuelve a `active`. Mismo audit log.

**5. Editar contacto del dueño / cambiar contraseña**
- Reset de contraseña: dispara
  `auth.admin.generateLink({ type: 'recovery', email })` y muestra el
  link al admin (o se lo envía por correo directamente).
- Edición de email: requiere usar la API admin de Supabase
  (`auth.admin.updateUserById`). Side effect: invalida sesiones activas.

### 4.4 UX adicional

- Badge en el menú con el contador de cuentas pendientes
  (`SELECT count(*) FROM businesses WHERE status='pending'`).
- Notificación / email diario al equipo de soporte si hay >5 pendientes.
- Export CSV de la lista (para reportes / seguimiento).

---

## 5. Modelo de datos

### 5.1 Lo que ya existe

```
businesses
  id              uuid PK
  owner_id        uuid → profiles.id / auth.users.id
  business_name   text
  branch_name     text
  business_type   text
  country         text
  address         text
  phone           text NULL
  domain          text UNIQUE
  status          text   ← CHECK in ('active','inactive','pending')
  created_at      timestamptz
  updated_at      timestamptz

profiles
  id              uuid PK (= auth.users.id)
  email           text
  full_name       text
  created_at      timestamptz
  updated_at      timestamptz

memberships
  user_id         uuid → auth.users.id
  business_id     uuid → businesses.id
  plan_id         uuid → plans.id
  plan_type       text
  status          text          ← 'active' / 'inactive' (membership-level)
  is_billing_anchor bool        ← TRUE para la membership "raíz" del business
  billing_status  text          ← 'trial' / 'active' / 'past_due' / 'suspended' / etc.
  trial_ends_at   timestamptz
  next_billing_date date
  consent_granted_at timestamptz
  ...

plans
  id, code, name, trial_days, monthly_price, ...

payment_methods
  id, business_id, brand, last4, status ('verified'/'pending'/'failed'), ...
```

**`auth.users`** (managed por Supabase Auth) tiene `email`,
`email_confirmed_at`, `last_sign_in_at`, `created_at`. Útil para mostrar
en el detalle.

### 5.2 Migration ya aplicada (POS, ya en BD)

```sql
ALTER TABLE public.businesses DROP CONSTRAINT IF EXISTS businesses_status_check;
ALTER TABLE public.businesses
  ADD CONSTRAINT businesses_status_check
  CHECK (status IN ('active', 'inactive', 'pending'));
```

### 5.3 Migration propuesta para el admin (nueva)

Tabla de audit log para no perder trazabilidad de quién aprobó/rechazó
qué y cuándo:

```sql
CREATE TABLE public.business_status_audit (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id     uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  actor_user_id   uuid REFERENCES auth.users(id),   -- quién hizo el cambio
  from_status     text,
  to_status       text NOT NULL,
  reason          text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_business_status_audit_business
  ON public.business_status_audit(business_id, created_at DESC);
```

---

## 6. Endpoints / RPCs sugeridos para el admin

| RPC | Args | Devuelve | Rol requerido |
|---|---|---|---|
| `fn_admin_list_pending_businesses` | `p_limit int, p_offset int, p_search text` | rows con todos los joins de la tabla en 4.1 | superadmin / admin |
| `fn_admin_approve_business` | `p_business_id uuid` | nuevo status | superadmin / admin |
| `fn_admin_reject_business` | `p_business_id uuid, p_reason text` | nuevo status | superadmin / admin |
| `fn_admin_pending_count` | — | int | superadmin / admin (para el badge) |

Cada RPC debe:
- Validar el rol con `auth.uid()` + check en `admin_users` (o similar).
- Insertar fila en `business_status_audit`.
- (Activar / rechazar) disparar el correo al dueño via Edge Function o
  webhook al provider de email (Resend / Postmark / SES).

---

## 7. Out of scope (no hacer en esta iteración)

- Auto-aprobación con reglas (ej: "si tarjeta verificada + email
  corporativo, aprobar solo"). Por ahora todo manual.
- Onboarding chat / asignación a un agente. Solo lista + acciones.
- Métricas (tiempo promedio de aprobación, % rechazadas, etc.). En otra
  fase si la cola crece.

---

## 8. Riesgos / consideraciones

- **Email obligatorio**: el guard de POS asume que el correo del dueño
  es el de `auth.users.email`. Si en algún momento queremos permitir
  signup por teléfono / OAuth sin email, hay que ajustar la
  `PendingApprovalScreen` (botón "Cambiar contraseña" no funcionaría).
- **Realtime para desbloqueo automático**: hoy `PendingApprovalGuard` re-
  fetchea el status cuando se invalida el provider. Si queremos que la
  app del POS se desbloquee inmediatamente al activar desde el admin,
  hay que suscribirse via Realtime a `businesses` (mismo patrón que
  `billingStateProvider`). Por ahora un refresh manual (recargar la app)
  basta para el caso de uso.
- **Rate limit del reset de contraseña**: Supabase Auth tiene un
  rate-limit propio (~3-4 por hora por email). Comunicarlo en la UI del
  admin si el botón "resetear contraseña" se usa varias veces.
