-- =============================================================================
-- 20260907_0002 — order_item_modifiers.modifier_id: identidad del modificador
--
-- PROBLEMA:
--   Cuando se vende «Sin queso», la venta guarda una fila en
--   `order_item_modifiers` con `name = 'Sin queso'` y nada más. El texto no
--   sirve para descontar inventario: dos negocios (y dos grupos del mismo
--   negocio) pueden tener modificadores con el mismo nombre, y renombrar uno
--   dejaría de empatar. Para descontar hace falta la IDENTIDAD: qué fila de
--   `modifiers` fue.
--
--   Es exactamente el mismo problema —y la misma solución— que 20260605_0002
--   resolvió para los componentes de combo con `menu_item_id`.
--
-- FIX:
--   Columna `order_item_modifiers.modifier_id uuid` (FK a `modifiers`), que la
--   app puebla al guardar la selección. El consumo (20260907_0003) la usa para
--   encontrar las líneas de `modifier_ingredients` del modificador vendido.
--
-- NOTAS DE SEGURIDAD:
--   - 100% ADITIVA: columna NULLABLE. Las ventas históricas quedan en NULL y
--     no descuentan nada por modificador (correcto: nunca se configuró).
--   - FK ON DELETE SET NULL: borrar un modificador NO rompe ventas históricas.
--   - FK NOT VALID: sin scan ni lock del histórico (todo NULL hoy). Las filas
--     NUEVAS sí se validan.
--   - La app degrada sola: si esta migración no está aplicada, el insert cae
--     al reintento sin la columna y la venta se guarda igual (sin descuento
--     por modificador). Ver SalesRepository.addOrderItemModifiers.
--
-- IDEMPOTENTE: sí. REVERSIBLE: sí (ver _ROLLBACK).
-- =============================================================================

begin;

alter table public.order_item_modifiers
  add column if not exists modifier_id uuid;

comment on column public.order_item_modifiers.modifier_id is
  'Modificador (modifiers.id) que originó esta línea. NULL en ventas '
  'históricas y en los componentes de combo (esos usan menu_item_id). Es la '
  'fuente para descontar inventario por modificador vía modifier_ingredients.';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'order_item_modifiers_modifier_id_fkey'
  ) then
    alter table public.order_item_modifiers
      add constraint order_item_modifiers_modifier_id_fkey
      foreign key (modifier_id) references public.modifiers(id)
      on delete set null
      not valid;
  end if;
end$$;

-- Índice parcial: solo las filas que sí son modificadores de catálogo.
create index if not exists idx_order_item_modifiers_modifier_id
  on public.order_item_modifiers (modifier_id)
  where modifier_id is not null;

commit;
