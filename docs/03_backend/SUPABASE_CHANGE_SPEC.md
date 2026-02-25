# SUPABASE_CHANGE_SPEC.md

Fecha: 2026-02-25
Ámbito: Sprint 1 (P0)
Estado: APROBADO Y APLICADO EN SUPABASE (confirmado por usuario)

## 1. Motivo del cambio

Se detectaron bloqueantes P0 que requieren ajuste en Supabase antes de implementación Flutter:

1. Fiscal (crítico)
- La función `create_fiscal_document` todavía inserta NCF mock (`B0200000001`) y selecciona negocio con `LIMIT 1`.
- Esto viola requisito fiscal y puede emitir comprobantes inválidos.

2. Seguridad/autorización de roles (alto)
- `user_businesses.role` restringe valores que no incluyen `delivery` y no está alineado con roles usados por app/enum (`manager`, `cook`, etc.).
- Riesgo de usuarios válidos rechazados o mapeos inconsistentes.

## 2. Cambios propuestos (DB)

## Cambio A — Reemplazar lógica mock en `create_fiscal_document`

Objetivo:
- Hacer `create_fiscal_document` idempotente y basada en emisión real (`issue_fiscal_document` + `generate_ncf`).
- Eliminar NCF hardcodeado y fallback de negocio inseguro.

Diseño:
- Si ya existe documento para `payment_id`/`order_id`, retornar el existente.
- Si no existe, emitir con `issue_fiscal_document`.
- Completar `customer_id`/`customer_rnc` cuando aplique.

Impacto esperado:
- Mantiene contrato de retorno (`public.fiscal_documents`) usado por Flutter.
- Evita duplicados funcionales por reintento de UI.

## Cambio B — Alinear constraint de `user_businesses.role`

Objetivo:
- Alinear roles permitidos de `user_businesses` con operación POS actual.

Diseño:
- Reemplazar check por set ampliado:
  - `owner, admin, manager, cashier, waiter, cook, chef, delivery`

Impacto esperado:
- Reduce rechazos por roles válidos en operación.
- No rompe filas existentes con `chef`.

## 3. No incluidos en este change-set

- Consolidación `memberships` vs `user_businesses` (solo planificada).
- Nuevas tablas de módulos P1/P2.
- Cambios de RLS masivos por tabla (se abordan en hardening/sprint dedicado).

## 4. Riesgos

1. Si existe lógica cliente que dependa de NCF mock, cambiará comportamiento (esperado y deseado).
2. Al ampliar roles permitidos, se debe mantener control real por RLS/permisos efectivos.

## 5. Plan de validación manual (post-migration)

1. Procesar pago y emitir fiscal:
- esperado: `fiscal_documents.ncf_number` secuencial, no fijo.
- esperado: negocio correcto (no `LIMIT 1` global).

2. Reintentar emisión para misma orden/pago:
- esperado: retorna documento existente (idempotente).

3. Insertar/actualizar `user_businesses.role = 'delivery'`:
- esperado: permitido.

4. Verificar que roles previos (`chef`) sigan válidos.

## 6. Rollback

- Restaurar definición previa de `create_fiscal_document` desde snapshot/tag de schema.
- Restaurar constraint anterior de `user_businesses.role`.
- No se elimina data en este cambio.

## 7. Archivos asociados

- Migration SQL: `/supabase/migrations/20260225_0001_sprint1_p0_fiscal_roles.sql`
