-- =============================================================================
-- F0 Almacenes por sección — cimientos.
--
-- CONTEXTO:
--   Un negocio con almacén central y áreas de producción separadas necesita
--   saber TRES cosas de cada almacén que hoy no puede guardar:
--     · qué clase de almacén es (general, producción, mermas, préstamos),
--     · a qué área de producción sirve (Cocina, Bar, Food Shop),
--     · quién responde por él.
--
-- ENTREGA (solo columnas y reglas — NADA de comportamiento):
--   1. `warehouses.warehouse_type`      general | production | waste | loan
--   2. `warehouses.production_area_id`  FK a print_areas (el área que ya
--      rutea las comandas — no se inventa un catálogo nuevo)
--   3. `warehouses.keeper_employee_id`  FK a employees
--   4. `warehouses.requires_requisition` para F2
--   5. `business_settings.warehouse_sections_enabled` — la bandera, APAGADA.
--
-- LO QUE ESTA MIGRACIÓN NO HACE:
--   No toca `consume_inventory_from_order` ni ninguna función que mueva
--   stock. Con la bandera apagada —y con un solo almacén— el sistema se
--   comporta EXACTAMENTE igual que antes de aplicarla. El cambio del motor
--   de consumo es F1 y va en su propia migración, para poder revertirlo
--   solo a él.
--
-- REGLAS QUE SE VUELVEN ÍNDICE (no buena intención):
--   · Un área de producción no puede tener dos almacenes: al vender, el
--     sistema no sabría de cuál descontar.
--   · Un solo almacén de mermas por negocio: si hay dos, el costo de la
--     merma del mes se parte y ningún reporte cuadra.
--
-- IDEMPOTENTE: sí (add column if not exists + create index if not exists).
-- REVERSIBLE: sí (ver _ROLLBACK).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Clase de almacén
-- ---------------------------------------------------------------------------

alter table public.warehouses
  add column if not exists warehouse_type text not null default 'general';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'warehouses_type_check'
  ) then
    alter table public.warehouses
      add constraint warehouses_type_check
      check (warehouse_type in ('general', 'production', 'waste', 'loan'));
  end if;
end $$;

comment on column public.warehouses.warehouse_type is
  'general = depósito común (el principal). production = sirve a un área de '
  'producción y de ahí sale el consumo de la venta cuando F1 esté activa. '
  'waste = destino de las mermas. loan = mercancía prestada a terceros. '
  'F0 Almacenes por sección.';

-- ---------------------------------------------------------------------------
-- 2. Área de producción a la que sirve
-- ---------------------------------------------------------------------------

alter table public.warehouses
  add column if not exists production_area_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'warehouses_production_area_fkey'
  ) then
    alter table public.warehouses
      add constraint warehouses_production_area_fkey
      foreign key (production_area_id)
      references public.print_areas(id)
      on delete set null;
  end if;
end $$;

comment on column public.warehouses.production_area_id is
  'Área de producción (print_areas) que este almacén abastece. NULL = no '
  'sirve a ningún área. Se apunta a print_areas a propósito: son las mismas '
  'áreas que ya rutean las comandas, así que un producto que sale por Cocina '
  'ya sabe de qué almacén consumir sin configurar nada dos veces.';

-- Un área, un almacén. Sin esto la venta tendría dos candidatos y elegiría
-- por orden de creación, que es como no elegir.
create unique index if not exists uq_warehouses_production_area
  on public.warehouses (business_id, production_area_id)
  where production_area_id is not null;

-- ---------------------------------------------------------------------------
-- 3. Responsable
-- ---------------------------------------------------------------------------

alter table public.warehouses
  add column if not exists keeper_employee_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'warehouses_keeper_employee_fkey'
  ) then
    alter table public.warehouses
      add constraint warehouses_keeper_employee_fkey
      foreign key (keeper_employee_id)
      references public.employees(id)
      on delete set null;
  end if;
end $$;

comment on column public.warehouses.keeper_employee_id is
  'Empleado que responde por este almacén. En F0 es informativo (se muestra '
  'y se imprime). El candado —solo él despacha, ajusta y aprueba— entra en '
  'F2 y vive en las funciones, no en la app: si viviera en Flutter, un '
  'cliente viejo lo saltaría.';

-- Un empleado puede tener varios almacenes (Jesús lleva Cocina, Bar y Food
-- Shop), así que acá NO va índice único. Sí conviene el de búsqueda.
create index if not exists idx_warehouses_keeper
  on public.warehouses (keeper_employee_id)
  where keeper_employee_id is not null;

-- ---------------------------------------------------------------------------
-- 4. Requisición obligatoria (lo consume F2)
-- ---------------------------------------------------------------------------

alter table public.warehouses
  add column if not exists requires_requisition boolean not null default false;

comment on column public.warehouses.requires_requisition is
  'Si es true, este almacén solo recibe mercancía por requisición aprobada, '
  'no por transferencia directa. Se declara en F0 y lo hace cumplir F2.';

-- ---------------------------------------------------------------------------
-- 5. Un solo almacén de mermas por negocio
-- ---------------------------------------------------------------------------

create unique index if not exists uq_warehouses_waste
  on public.warehouses (business_id)
  where warehouse_type = 'waste';

-- ---------------------------------------------------------------------------
-- 6. La bandera — APAGADA
-- ---------------------------------------------------------------------------

alter table public.business_settings
  add column if not exists warehouse_sections_enabled boolean
  not null default false;

comment on column public.business_settings.warehouse_sections_enabled is
  'Enciende el consumo de venta POR ÁREA (F1): el plato descuenta del '
  'almacén de su área en vez del principal. APAGADA por defecto. No '
  'prenderla hasta que los almacenes de producción tengan existencia real, '
  'o la primera venta los manda a negativo.';

commit;
