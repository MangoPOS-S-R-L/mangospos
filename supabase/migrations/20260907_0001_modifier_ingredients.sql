-- =============================================================================
-- 20260907_0001 — modifier_ingredients: el modificador también descuenta stock
--
-- EL PROBLEMA (de piso):
--   Hoy la receta vive SOLO en el producto (`recipes` → `recipe_ingredients`).
--   Pero el plato real no siempre es el mismo: el mismo sándwich sale con pan
--   sobao o con pan integral, con queso o sin queso, y eso se escoge con un
--   MODIFICADOR al vender. Como los modificadores solo guardan nombre y precio,
--   el inventario descuenta siempre la receta base: el pan integral nunca baja,
--   el queso baja aunque el cliente lo haya pedido sin queso.
--
-- ENTREGA:
--   `modifier_ingredients` — las líneas de insumo de un modificador. Mismo
--   modelo que `recipe_ingredients` (insumo + cantidad + unidad), pero colgando
--   de `modifiers`. Un modificador puede tener varias líneas.
--
-- LA CANTIDAD LLEVA SIGNO (esto es lo importante):
--   +  suma consumo   → «Queso extra» = +0.05 kg de queso.
--   −  resta consumo  → «Sin queso»   = −0.05 kg de queso, que ANULA lo que
--      la receta base del producto ya iba a descontar.
--   Un cambio de pan son dos líneas en el MISMO modificador:
--      «Pan integral» = +1 pan integral, −1 pan sobao.
--   Sin el signo no hay forma de expresar la sustitución, que es justo el caso
--   que pidió el negocio.
--
--   RED DE SEGURIDAD: el consumo (20260907_0003) recorta el total esperado de
--   cada par (insumo, bodega) a un mínimo de 0. Un negativo mal configurado
--   deja de descontar, pero NUNCA inventa stock que nadie compró.
--
-- LA UNIDAD SE GUARDA EN UNIDAD BASE DEL INSUMO, igual que las recetas: la
--   app convierte al guardar (ver core/inventory/unit_conversion.dart) y el
--   SQL lee la cantidad cruda.
--
-- 100% ADITIVA: tabla nueva. Sin filas, el comportamiento del POS y del
--   inventario es exactamente el de hoy.
-- IDEMPOTENTE: sí. REVERSIBLE: sí (ver _ROLLBACK).
-- REQUIERE: nada. El consumo lo activa 20260907_0003.
-- =============================================================================

begin;

create table if not exists public.modifier_ingredients (
  id                uuid primary key default gen_random_uuid(),
  modifier_id       uuid not null references public.modifiers(id) on delete cascade,
  inventory_item_id uuid not null references public.inventory_items(id),
  quantity          numeric not null,
  unit              text not null,
  created_at        timestamptz not null default now()
);

comment on table public.modifier_ingredients is
  'Insumos que descuenta (o devuelve) un modificador al venderse. Misma forma '
  'que recipe_ingredients pero colgando de modifiers. La cantidad va en la '
  'unidad base del insumo y LLEVA SIGNO: positiva suma consumo (queso extra), '
  'negativa lo resta de la receta base (sin queso / cambio de pan).';

comment on column public.modifier_ingredients.quantity is
  'Cantidad CON SIGNO en la unidad base del insumo. + descuenta, − anula lo '
  'que la receta base del producto descontaría.';

-- Un insumo no se repite dentro del mismo modificador: dos líneas del mismo
-- insumo son siempre un error de captura (o se suman, o se contradicen).
create unique index if not exists ux_modifier_ingredients_modifier_item
  on public.modifier_ingredients (modifier_id, inventory_item_id);

create index if not exists idx_modifier_ingredients_item
  on public.modifier_ingredients (inventory_item_id);

alter table public.modifier_ingredients enable row level security;

-- Lectura: quien tenga acceso al negocio dueño del modificador.
drop policy if exists "mi_ing_select" on public.modifier_ingredients;
create policy "mi_ing_select" on public.modifier_ingredients
  for select to authenticated
  using (
    exists (
      select 1
      from public.modifiers m
      where m.id = modifier_ingredients.modifier_id
        and public.user_has_business_access(auth.uid(), m.business_id)
    )
  );

-- Escritura: owner/admin, igual que recipe_ingredients. El WITH CHECK además
-- exige que el insumo sea del MISMO negocio que el modificador (sin eso se
-- podría colar un insumo de otro tenant por id).
drop policy if exists "mi_ing_write" on public.modifier_ingredients;
create policy "mi_ing_write" on public.modifier_ingredients
  for all to authenticated
  using (
    exists (
      select 1
      from public.modifiers m
      where m.id = modifier_ingredients.modifier_id
        and public.user_business_role(auth.uid(), m.business_id)
            = any (array['owner'::text, 'admin'::text])
    )
  )
  with check (
    exists (
      select 1
      from public.modifiers m
      join public.inventory_items ii
        on ii.id = modifier_ingredients.inventory_item_id
      where m.id = modifier_ingredients.modifier_id
        and ii.business_id = m.business_id
        and public.user_business_role(auth.uid(), m.business_id)
            = any (array['owner'::text, 'admin'::text])
    )
  );

grant all on table public.modifier_ingredients to anon;
grant all on table public.modifier_ingredients to authenticated;
grant all on table public.modifier_ingredients to service_role;

commit;
