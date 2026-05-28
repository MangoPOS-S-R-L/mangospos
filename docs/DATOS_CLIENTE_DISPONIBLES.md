# Datos que tenemos del cliente al momento del registro

**Fecha:** 2026-05-27
**Contexto:** referencia rápida para diseñar el panel admin (PRD
`PRD_ADMIN_CUENTAS_PENDIENTES.md`) y cualquier reporte interno de
ventas / soporte.

Esto resume **qué información del dueño tenemos disponible** apenas
termina el registro (los 4 pasos del wizard del POS) y de qué tabla la
sacamos.

---

## 1. Identidad del dueño

| Dato | Tabla | Campo | Notas |
|---|---|---|---|
| User ID | `auth.users` / `profiles` | `id` (UUID) | Mismo ID en las dos tablas |
| Email | `auth.users` | `email` | Identidad real del usuario |
| Email | `profiles` | `email` | Copia para joins sin pasar por `auth` |
| Nombre completo | `profiles` | `full_name` | Lo escriben en Step 1 |
| Email confirmado | `auth.users` | `email_confirmed_at` | Null si no confirmó |
| Último login | `auth.users` | `last_sign_in_at` | |
| Fecha de signup | `auth.users` | `created_at` | |
| Avatar / foto | — | — | No lo pedimos en el registro |

---

## 2. Datos del negocio

Todo viene de la tabla `businesses` (insert que hace
[register_step2_viewmodel.dart:307-330](../lib/presentation/auth/register/register_step2_viewmodel.dart#L307-L330)):

| Dato | Campo | ¿Obligatorio en registro? |
|---|---|---|
| ID del negocio | `id` (UUID) | autogen |
| Owner | `owner_id` (FK → `profiles.id`) | sí |
| Nombre comercial | `business_name` | sí (Step 2) |
| Nombre de sucursal | `branch_name` | opcional, default "Sucursal Principal" |
| Tipo de negocio | `business_type` | sí (Step 2, dropdown: restaurante, bar, cafetería, etc.) |
| País | `country` | sí (Step 2) |
| Dirección | `address` | sí (Step 2) |
| Teléfono | `phone` | opcional |
| Subdominio | `domain` | autogen `{slug}.mangopos.do` (con sufijos `-2`, `-3` si choca) |
| Status | `status` | nuevo registro → `'pending'` (post 27-may-2026) |
| Created at | `created_at` | autogen |
| Updated at | `updated_at` | autogen |

**Lo que NO se captura en el registro** (queda como NULL o se llena
luego en Ajustes → Perfil del negocio):

- RNC / NIT / tax_id
- Logo del negocio
- Email de contacto del negocio (distinto al del dueño)
- Coordenadas / ubicación geográfica
- Horario de atención
- Sitio web / redes sociales

Esto vive en `business_profile` / extensiones; el dueño lo completa
después del primer login.

---

## 3. Membresía / plan elegido

`memberships` (insert que hace
[register_step2_viewmodel.dart:234-256](../lib/presentation/auth/register/register_step2_viewmodel.dart#L234-L256)):

| Dato | Campo | Notas |
|---|---|---|
| Plan elegido | `plan_id` (FK → `plans.id`) | viene de Step 1 |
| Plan type | `plan_type` | normalización legacy (basic/pro/etc.) |
| Status membership | `status` | siempre `'active'` al crear |
| Es la anchor? | `is_billing_anchor` | `true` para la membership raíz |
| Billing status | `billing_status` | `'trial'` al registrar |
| Trial vence | `trial_ends_at` | hoy + `plans.trial_days` (default 14) |
| Period start | `current_period_start` | hoy |
| Period end | `current_period_end` | = trial_ends_at |
| Próximo cobro | `next_billing_date` | trial_ends_at + 1 día |
| Consent | `consent_granted_at` | hoy (registró el aceptar términos) |
| Rol | `role` | `'owner'` |

Joineando a `plans` se obtiene nombre del plan, precio mensual, features
habilitadas.

---

## 4. Método de pago

`payment_methods` (se crea en Step 4 si el dueño completó el flow de
Azul):

| Dato | Campo | Notas |
|---|---|---|
| Business ID | `business_id` | FK |
| Brand | `brand` | visa / mastercard / amex |
| Últimos 4 | `last4` | mostrar como `**** 1234` |
| Status | `status` | `verified` / `pending` / `failed` |
| Token de Azul | `azul_token` | no exponerlo en UI |
| Creado | `created_at` | |

**Importante:** hoy puede no existir todavía esta fila porque Azul está
bloqueado por Incapsula (ver memory:
`project_azul_incapsula_blocker.md`). El registro ya **no permite
saltarse** el Step 4 desde el 27 de mayo (ver commits recientes —
"tarjeta obligatoria en Step 4"), pero las cuentas registradas antes
pueden tener `payment_methods` vacío.

---

## 5. Datos derivados / útiles para reporting

Cosas que podemos calcular a partir de lo anterior y mostrar en
dashboards internos:

- **Días desde el registro** = `now() - businesses.created_at`
- **Activación pendiente?** = `businesses.status='pending'`
- **Trial vigente?** = `memberships.trial_ends_at > now()`
- **Tiene tarjeta verificada?** = `EXISTS (SELECT 1 FROM payment_methods
  WHERE business_id=$1 AND status='verified')`
- **Riesgo de churn?** = trial vence en <3 días y no tiene tarjeta.
- **Sucursales adicionales** = `COUNT(*) FROM businesses WHERE
  owner_id=$1` (un mismo dueño puede tener varios businesses).

---

## 6. Lo que NO sabemos / hay que pedir aparte

- WhatsApp business / Instagram del negocio.
- Cuántos empleados tienen pensado crear.
- Si vienen de otro POS (migración) o son negocio nuevo.
- Volumen de transacciones esperado.
- Cómo nos conocieron (referido / Google / etc.).

Si soporte/marketing los necesitan, hay que agregar campos al Step 1 o
2 del registro, o pedirlos en el primer login con un onboarding modal.

---

## 7. Consulta SQL de ejemplo — "Lista para el admin"

Esta es básicamente la query base de la tabla "Cuentas pendientes" del
PRD del admin:

```sql
SELECT
  b.id                                  AS business_id,
  b.business_name,
  b.branch_name,
  b.business_type,
  b.country,
  b.address,
  b.phone,
  b.domain,
  b.status,
  b.created_at,
  p.email,
  p.full_name,
  u.email_confirmed_at,
  u.last_sign_in_at,
  pl.name                               AS plan_name,
  pl.code                               AS plan_code,
  pl.monthly_price,
  m.billing_status,
  m.trial_ends_at,
  m.next_billing_date,
  EXISTS (
    SELECT 1 FROM public.payment_methods pm
    WHERE pm.business_id = b.id AND pm.status = 'verified'
  )                                     AS has_verified_card
FROM public.businesses b
JOIN public.profiles  p  ON p.id = b.owner_id
JOIN auth.users       u  ON u.id = b.owner_id
LEFT JOIN public.memberships m
       ON m.business_id = b.id AND m.is_billing_anchor = TRUE
LEFT JOIN public.plans pl ON pl.id = m.plan_id
WHERE b.status = 'pending'
ORDER BY b.created_at DESC
LIMIT 50;
```
