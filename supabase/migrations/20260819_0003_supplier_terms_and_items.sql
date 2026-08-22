-- =============================================================================
-- Fase 3 Proveedores — de agenda de contactos a relación comercial.
--
-- CONTEXTO:
--   La ficha del proveedor cubre bien los 9 campos que tiene (`name`, `rnc`,
--   contacto, `payment_terms`…). El problema es lo que NO guarda:
--
--     1. Las condiciones son TEXTO LIBRE. En la misma columna conviven
--        «30 dias», «contado», «15 dias fin de mes» y «50% anticipo»: cuatro
--        formatos escritos a mano. Nada puede calcular un vencimiento, avisar
--        de un atraso ni ordenar la lista por deuda.
--     2. No hay vínculo proveedor↔insumo. Por eso «Sugerencias de reorden»
--        sabe que faltan 3 botellas de ron pero no a quién comprarlas, y la
--        lista no puede decir qué provee cada uno.
--     3. El código con el que el PROVEEDOR llama al insumo no existe. Sin él
--        la orden de compra sale con el nombre interno, que el proveedor no
--        reconoce.
--
-- ENTREGA (todo ADITIVO — ninguna columna existente cambia ni se borra):
--   1. suppliers.payment_terms_type   contado | credito | anticipo
--   2. suppliers.payment_terms_from   invoice | receipt  (base de cómputo)
--   3. suppliers.payment_terms_days   (ya podría existir: 20260811_0001 /
--                                      20260814_0003 la agregan)
--   4. suppliers.min_order_amount     mínimo de orden
--   5. suppliers.lead_time_days       entrega prometida
--   6. supplier_items                 el vínculo que falta, con el código del
--                                     proveedor y su unidad de compra
--   7. Backfill del tipo/plazo SOLO donde el texto es INEQUÍVOCO. Adivinar
--      produciría vencimientos falsos, que es peor que no tenerlos.
--   8. Índice único de RNC por negocio, y SOLO si hoy no hay duplicados: una
--      migración que falla a mitad del despliegue por datos viejos es peor
--      que una regla que se activa cuando el negocio limpia sus fichas.
--
-- `payment_terms` (texto) NO se toca ni se vacía: cubre los casos que no son
-- un plazo simple («2/10 neto 30», «50% anticipo y resto contra entrega») y
-- sigue siendo lo que el negocio escribió.
--
-- IDEMPOTENTE: sí (`if not exists` en todo; el backfill ignora lo ya escrito).
-- REVERSIBLE: sí (ver _ROLLBACK).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Condiciones comerciales estructuradas
-- ---------------------------------------------------------------------------
alter table public.suppliers
  add column if not exists payment_terms_type text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.suppliers'::regclass
       and conname  = 'suppliers_payment_terms_type_check'
  ) then
    alter table public.suppliers
      add constraint suppliers_payment_terms_type_check
      check (payment_terms_type in ('contado', 'credito', 'anticipo')
             or payment_terms_type is null);
  end if;
end $$;

comment on column public.suppliers.payment_terms_type is
  'Tipo de condición: contado | credito | anticipo. NULL = sin definir, y la '
  'pantalla lo dice así en vez de asumir contado. Con crédito, el plazo vive '
  'en payment_terms_days.';

-- `payment_terms_days` la agregan 20260811_0001 (int not null default 0) y
-- 20260814_0003 (smallint nullable). Se declara acá también para que esta
-- migración funcione sola, sin asumir qué se aplicó antes.
alter table public.suppliers
  add column if not exists payment_terms_days smallint;

alter table public.suppliers
  add column if not exists payment_terms_from text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.suppliers'::regclass
       and conname  = 'suppliers_payment_terms_from_check'
  ) then
    alter table public.suppliers
      add constraint suppliers_payment_terms_from_check
      check (payment_terms_from in ('invoice', 'receipt')
             or payment_terms_from is null);
  end if;
end $$;

comment on column public.suppliers.payment_terms_from is
  'Desde cuándo cuentan los días: invoice = fecha de factura (default del '
  'mercado), receipt = fecha de recepción de la mercancía. Cambia el '
  'vencimiento cuando la factura llega antes que el camión.';

alter table public.suppliers
  add column if not exists min_order_amount numeric;

comment on column public.suppliers.min_order_amount is
  'Monto mínimo que el proveedor exige por orden. Sirve para avisar antes de '
  'enviar una OC que va a rebotar.';

alter table public.suppliers
  add column if not exists lead_time_days smallint;

comment on column public.suppliers.lead_time_days is
  'Días de entrega PROMETIDOS por el proveedor. Se compara contra el promedio '
  'real de las órdenes recibidas: la diferencia es lo que se le puede '
  'reclamar.';

-- ---------------------------------------------------------------------------
-- 2. El vínculo proveedor ↔ insumo
--
--    `inventory_items.preferred_supplier_id` (20260813_0001) dice quién es el
--    preferido de un insumo: UNA relación por insumo. Esto es lo inverso y es
--    N:M — un insumo se le puede comprar a tres proveedores, cada uno con su
--    código y su precio. El preferido sigue mandando para el reorden.
-- ---------------------------------------------------------------------------
create table if not exists public.supplier_items (
  id                uuid not null default gen_random_uuid() primary key,
  business_id       uuid not null references public.businesses(id) on delete cascade,
  supplier_id       uuid not null references public.suppliers(id) on delete cascade,
  inventory_item_id uuid not null references public.inventory_items(id) on delete cascade,
  -- Cómo llama el PROVEEDOR a este insumo en su catálogo. Va en la OC para
  -- que del otro lado sepan qué se está pidiendo.
  supplier_code     text,
  -- Unidad y empaque de COMPRA a este proveedor: el mismo aceite se compra en
  -- lata de 5 L a uno y en galón a otro.
  purchase_unit     text,
  pack_size         numeric check (pack_size is null or pack_size > 0),
  -- Último precio ACORDADO (lista del proveedor). El precio realmente pagado
  -- sale de purchase_order_items; este es la referencia para armar la OC.
  last_price        numeric check (last_price is null or last_price >= 0),
  min_order_qty     numeric check (min_order_qty is null or min_order_qty > 0),
  notes             text,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint supplier_items_unique unique (supplier_id, inventory_item_id)
);

comment on table public.supplier_items is
  'Qué insumos provee cada proveedor, con su código, su unidad de compra y su '
  'último precio de lista. Es lo que le falta a Sugerencias de reorden para '
  'generar la orden sola.';

create index if not exists idx_supplier_items_supplier
  on public.supplier_items (supplier_id) where is_active;

create index if not exists idx_supplier_items_item
  on public.supplier_items (inventory_item_id) where is_active;

create index if not exists idx_supplier_items_business
  on public.supplier_items (business_id);

alter table public.supplier_items enable row level security;

-- Misma forma que `suppliers`: cualquier miembro LEE, owner/admin ESCRIBEN.
drop policy if exists "si_select" on public.supplier_items;
create policy "si_select" on public.supplier_items
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "si_admin" on public.supplier_items;
create policy "si_admin" on public.supplier_items
  to authenticated
  using (public.user_business_role(auth.uid(), business_id)
           = any (array['owner'::text, 'admin'::text]))
  with check (public.user_business_role(auth.uid(), business_id)
           = any (array['owner'::text, 'admin'::text]));

grant all on table public.supplier_items to anon;
grant all on table public.supplier_items to authenticated;
grant all on table public.supplier_items to service_role;

-- ---------------------------------------------------------------------------
-- 3. Backfill: solo lo INEQUÍVOCO
--
--    Misma regla que `PaymentTerms._daysFromText` en la app, para que el
--    servidor y la pantalla no discrepen:
--      - «50% anticipo» trae un porcentaje  → no es un plazo.
--      - «2/10 neto 30» trae dos números    → no se sabe cuál manda.
--      - «30 días» / «Neto 30» / «30»       → un solo número, plazo válido.
--    Todo lo demás queda con type NULL y la pantalla muestra el texto crudo.
-- ---------------------------------------------------------------------------

-- 3a. Contado explícito.
update public.suppliers
   set payment_terms_type = 'contado',
       payment_terms_days = 0
 where payment_terms_type is null
   and payment_terms is not null
   and lower(trim(payment_terms)) in
       ('contado', 'de contado', 'al contado', 'efectivo', 'cash', '0');

-- 3b. Anticipo: hay un porcentaje y la palabra. No lleva plazo.
update public.suppliers
   set payment_terms_type = 'anticipo'
 where payment_terms_type is null
   and payment_terms is not null
   and payment_terms like '%\%%'
   and lower(payment_terms) ~ '(anticipo|adelanto|avance)';

-- 3c. Crédito: exactamente UN número entre 1 y 365 y ningún porcentaje.
update public.suppliers
   set payment_terms_type = 'credito',
       payment_terms_days = (regexp_match(payment_terms, '\d+'))[1]::smallint,
       payment_terms_from = coalesce(payment_terms_from, 'invoice')
 where payment_terms_type is null
   and payment_terms is not null
   and payment_terms not like '%\%%'
   and (select count(*) from regexp_matches(payment_terms, '\d+', 'g')) = 1
   -- ::numeric y no ::int a propósito. Hay fichas con el número de factura
   -- escrito en las condiciones («Ref 20260814000123»): un solo grupo de
   -- dígitos, pero no entra en un int y el cast ABORTA LA MIGRACIÓN ENTERA
   -- con 22003. numeric aguanta cualquier largo y el `between` lo descarta.
   and (regexp_match(payment_terms, '\d+'))[1]::numeric between 1 and 365;

-- 3d. El plazo numérico que ya existía (20260811_0001 / 20260814_0003) sin
--     tipo: un plazo > 0 ES crédito; un 0 no distingue «contado» de «sin
--     configurar» (esa columna nació con default 0), así que se deja intacto.
update public.suppliers
   set payment_terms_type = 'credito',
       payment_terms_from = coalesce(payment_terms_from, 'invoice')
 where payment_terms_type is null
   and payment_terms_days is not null
   and payment_terms_days between 1 and 365;

-- ---------------------------------------------------------------------------
-- 4. RNC único por negocio — condicional
--
--    Ese número va a la factura fiscal y al 606: dos fichas con el mismo RNC
--    son el mismo contribuyente cargado dos veces. Pero si el negocio YA
--    tiene duplicados, crear el índice a ciegas aborta el despliegue entero.
--    Se crea únicamente cuando los datos lo permiten; si no, se avisa y la
--    validación queda del lado de la app hasta que se limpien las fichas.
-- ---------------------------------------------------------------------------
do $$
declare
  dupes int;
begin
  select count(*) into dupes from (
    select business_id, upper(regexp_replace(rnc, '[^0-9A-Za-z]', '', 'g')) as k
      from public.suppliers
     where rnc is not null and trim(rnc) <> ''
     group by 1, 2
    having count(*) > 1
  ) d;

  if dupes > 0 then
    raise notice
      'suppliers: % RNC duplicado(s) por negocio — el índice único NO se creó. '
      'Depurá las fichas y volvé a correr esta migración.', dupes;
  else
    create unique index if not exists idx_suppliers_business_rnc_unique
      on public.suppliers (business_id,
                           upper(regexp_replace(rnc, '[^0-9A-Za-z]', '', 'g')))
      where rnc is not null and trim(rnc) <> '';
  end if;
end $$;

commit;
