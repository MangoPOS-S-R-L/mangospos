-- =============================================================================
-- Costeo por ÚLTIMO PRECIO de compra (decisión de producto 2026-07-14).
--
-- CONTEXTO:
--   Existían DOS mecanismos de costo en conflicto:
--     1. App (purchases_repository.createPurchaseOrder con updateItemCost):
--        pisa inventory_items.cost con el último costo digitado, en TODOS
--        los modos de inventario, al momento de registrar la compra.
--     2. Trigger trg_inventory_movement_recost (mig 20260516_0004): costo
--        PROMEDIO PONDERADO al recibir, solo en inventory_mode='advanced'.
--
--   El (1) corría antes que el (2) y sobrescribía el costo viejo, así que
--   el promedio se calculaba con el precio nuevo en ambos términos → el
--   resultado era ≈ último precio igual. El promedio ponderado estaba
--   efectivamente roto desde que la app manda updateItemCost=true.
--
-- DECISIÓN:
--   Formalizar "último precio": el costo maestro del insumo SIEMPRE queda
--   en el costo de la última compra registrada. Este trigger reemplaza la
--   fórmula de promedio por una asignación directa y se convierte en la
--   única regla server-side, cubriendo también los caminos que NO pasaban
--   por el update de la app (recepciones directas, recepciones parciales).
--
-- CAMBIOS VS 20260516_0004:
--   - Fórmula: promedio ponderado → último precio (cost = cost_per_unit).
--   - Alcance: aplica a movement_type='purchase' solamente. transfer_in ya
--     no recostea (mover mercancía entre bodegas propias no cambia lo que
--     costó comprarla).
--   - Gate: se elimina el gate inventory_mode='advanced'. La app ya
--     actualizaba el costo sin mirar el modo; el trigger ahora es
--     consistente con eso. Sin cost_per_unit (>0) no hace nada.
--   - Se elimina fn_recompute_item_cost_weighted_avg (sin callers).
--
-- IDEMPOTENTE: CREATE OR REPLACE / DROP IF EXISTS.
-- =============================================================================

begin;

create or replace function public.fn_inventory_movement_recost()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Solo compras con costo conocido actualizan el costo maestro.
  if new.movement_type <> 'purchase' then
    return new;
  end if;
  if new.cost_per_unit is null or new.cost_per_unit <= 0 then
    return new;
  end if;
  if new.quantity is null or new.quantity <= 0 then
    return new;
  end if;

  -- Último precio: el costo maestro queda en el costo de esta compra.
  -- Redondeo a 4 decimales, igual que el resto del módulo.
  update public.inventory_items
     set cost = round(new.cost_per_unit::numeric, 4)
   where id = new.item_id
     and business_id = new.business_id;

  return new;
end;
$$;

comment on function public.fn_inventory_movement_recost() is
  'Costeo por último precio: al insertar un movimiento de compra con costo, '
  'inventory_items.cost queda en ese costo. Reemplaza el promedio ponderado '
  'de la mig 20260516_0004 (decisión de producto 2026-07-14).';

drop trigger if exists trg_inventory_movement_recost on public.inventory_movements;
create trigger trg_inventory_movement_recost
  after insert on public.inventory_movements
  for each row
  execute function public.fn_inventory_movement_recost();

comment on trigger trg_inventory_movement_recost on public.inventory_movements is
  'Actualiza el costo maestro del insumo al ÚLTIMO precio de compra.';

-- Sin callers desde este cambio.
drop function if exists public.fn_recompute_item_cost_weighted_avg(uuid, numeric, numeric);

commit;
