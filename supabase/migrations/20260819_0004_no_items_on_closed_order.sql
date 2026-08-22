-- =============================================================================
-- 20260819_0004 — Candado: una orden CERRADA no acepta ítems nuevos en silencio
-- =============================================================================
--
-- EL CASO (Car City S.R.L, 19/08/2026, mesa SP07, orden 5a618117):
--
--   16:08:47  se abre la mesa y se captura el cliente. Orden creada VACÍA.
--   16:24:44  el barrendero de mesas fantasma (`fn_release_empty_tables`, que
--             la app dispara en CADA carga del salón con grace de 15 min, ver
--             sales_by_zone_viewmodel.dart) encuentra una orden de 15m57s SIN
--             ítems: la marca 'void', cierra la sesión y libera la mesa.
--             Legítimo por su lógica — pero el mesero seguía con la pantalla
--             abierta.
--   16:39:21  el mesero agrega LAVADO CARRO 500 sobre ESE order_id ya muerto.
--   16:39:23  sale la comanda y se descuentan los insumos.
--
--   Resultado: orden colgando de una sesión cerrada — invisible en el salón,
--   imposible de cobrar desde la POS, con el servicio ya prestado. RD$500 que
--   no entraron. El delator: `orders.closed_at` < `order_items.created_at`.
--
-- POR QUÉ NO LO TAPABA 20260814_0002
--   Ese arreglo pone un lock por mesa para la carrera "fn_open_table committea
--   después del snapshot del barrido". Aquí NO hubo carrera: la orden estaba
--   genuinamente vacía a las 16:24. El barrido hizo lo correcto; lo que falta
--   es que la escritura POSTERIOR no pueda caer al vacío.
--
-- EL CANDADO
--   Trigger BEFORE INSERT en `order_items` — el único cuello por donde pasan
--   TODOS los caminos de alta (fn_add_item_from_menu, ofertas, splits, replay
--   de la cola offline). Si la orden destino está cerrada:
--
--     · cerrada por el barrendero (sin pagos, sin NCF)  → se RESUCITA la orden
--       + su sesión + la mesa, bajo el mismo advisory lock que fn_open_table,
--       y el ítem entra. El mesero no se entera y la plata queda visible.
--     · cerrada por un COBRO (pagos o NCF activos)      → error MP401.
--     · la mesa ya la tomó otra sesión                  → error MP402.
--
--   Resucitar es lo correcto y no lo contrario: el ítem ya existe en la mano
--   del mesero y el servicio se va a prestar igual. La alternativa (rechazar
--   siempre) devuelve el error DESPUÉS de que el cocinero ya vio el plato.
--
--   Cada resurrección queda en `orphan_order_revivals` para poder medir si el
--   barrendero sigue mordiendo mesas vivas.
--
-- NO SE TOCA `fn_confirm_order_to_kitchen` a propósito: el barrido nunca puede
--   cerrar una orden que ya tiene ítems (su filtro exige que no haya ninguno
--   fuera de 'void'/'paid'), así que para cuando se confirma a cocina el
--   trigger ya reabrió. Y esa función SÍ recibe órdenes cerradas legítimas —
--   la venta rápida cobra primero y manda a cocina después.
--
-- IDEMPOTENTE: tabla con IF NOT EXISTS, funciones CREATE OR REPLACE, trigger
-- con DROP previo. No reescribe datos existentes.
-- =============================================================================

begin;

-- ─── Bitácora de resurrecciones ──────────────────────────────────────────────
-- Sin ella el candado es mudo: no habría forma de saber si el barrendero sigue
-- cerrando mesas que un mesero tenía abierta, ni en cuáles negocios.
create table if not exists public.orphan_order_revivals (
  id                  uuid primary key default gen_random_uuid(),
  order_id            uuid not null,
  session_id          uuid,
  table_id            uuid,
  business_id         uuid,
  closed_at_before    timestamptz,
  status_ext_before   text,
  source              text not null,
  revived_at          timestamptz not null default now()
);

create index if not exists idx_orphan_revivals_order
  on public.orphan_order_revivals (order_id);
create index if not exists idx_orphan_revivals_when
  on public.orphan_order_revivals (revived_at desc);

-- RLS activo y SIN policies: escribe la función SECURITY DEFINER (dueña de la
-- tabla, que salta RLS) y se consulta desde Studio con service_role. Ningún
-- cliente `authenticated` la lee ni la escribe.
alter table public.orphan_order_revivals enable row level security;


-- ─── El reanimador ───────────────────────────────────────────────────────────
-- Devuelve: 'not_closed' | 'revived' | 'settled' | 'table_taken' |
--           'order_not_found'. Decide el CALLER qué hacer con cada uno.
create or replace function public.fn_reopen_orphan_order(
  p_order_id uuid,
  p_source   text default 'unknown'
)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_closed_at     timestamptz;
  v_status_ext    public.order_status;
  v_session_id    uuid;
  v_table_id      uuid;
  v_business_id   uuid;
  v_paid          numeric;
  v_ncf           integer;
  v_other_session uuid;
begin
  if p_order_id is null then
    return 'order_not_found';
  end if;

  select o.closed_at, o.status_ext, o.session_id, ts.table_id,
         coalesce(ts.business_id, z.business_id)
    into v_closed_at, v_status_ext, v_session_id, v_table_id,
         v_business_id
    from public.orders o
    left join public.table_sessions ts on ts.id = o.session_id
    left join public.dining_tables  dt on dt.id = ts.table_id
    left join public.zones          z  on z.id  = dt.zone_id
   where o.id = p_order_id;

  if not found then
    return 'order_not_found';
  end if;

  if v_closed_at is null then
    return 'not_closed';
  end if;

  -- ¿La cerró un COBRO? Entonces no se resucita ni de broma: hay dinero
  -- asentado y puede haber NCF emitido. Meterle un ítem a eso desbalancea la
  -- factura ya impresa y sub-declara a la DGII.
  select coalesce(sum(p.amount), 0)
    into v_paid
    from public.payments p
   where p.order_id = p_order_id
     and p.status = 'completed';

  select count(*)
    into v_ncf
    from public.fiscal_documents fd
   where fd.order_id = p_order_id
     and fd.status = 'active';

  if v_paid > 0 or v_ncf > 0
     or v_status_ext in ('paid'::public.order_status,
                         'partially_paid'::public.order_status) then
    return 'settled';
  end if;

  -- ─── El lock ───────────────────────────────────────────────────────────────
  -- MISMA expresión que fn_open_table y fn_release_empty_table(s): otra llave
  -- sería otro lock y no nos protegería de nada. Es xact-scoped.
  if v_table_id is not null then
    perform pg_advisory_xact_lock(hashtextextended(v_table_id::text, 0));

    -- Re-chequeo DENTRO del lock: si alguien ya reabrió la mesa, reabrir esta
    -- sesión reventaría el índice `uniq_open_session_per_table` con un 23505
    -- ilegible. Mejor un error propio que le dice al mesero qué hacer.
    select ts.id
      into v_other_session
      from public.table_sessions ts
     where ts.table_id = v_table_id
       and ts.closed_at is null
       and ts.id is distinct from v_session_id
     limit 1;

    if v_other_session is not null then
      return 'table_taken';
    end if;
  end if;

  -- `status_ext` vuelve de 'void' a 'open'; `status` solo si quedó 'canceled'.
  -- El resto se deja como estaba: hay consultas por todo el repo que filtran
  -- por esas columnas y no es este el lugar para reinterpretarlas.
  update public.orders
     set closed_at  = null,
         status_ext = case when status_ext = 'void'::public.order_status
                           then 'open'::public.order_status
                           else status_ext end,
         status     = case when status = 'canceled' then 'open' else status end
   where id = p_order_id;

  if v_session_id is not null then
    update public.table_sessions
       set closed_at = null
     where id = v_session_id
       and closed_at is not null;
  end if;

  if v_table_id is not null then
    update public.dining_tables
       set state = 'occupied'
     where id = v_table_id
       and state <> 'occupied';
  end if;

  insert into public.orphan_order_revivals(
    order_id, session_id, table_id, business_id,
    closed_at_before, status_ext_before, source
  ) values (
    p_order_id, v_session_id, v_table_id, v_business_id,
    v_closed_at, v_status_ext::text, coalesce(nullif(trim(p_source), ''), 'unknown')
  );

  return 'revived';
end;
$function$;

alter function public.fn_reopen_orphan_order(uuid, text) owner to postgres;
revoke all on function public.fn_reopen_orphan_order(uuid, text) from public;
-- Nadie la llama suelta desde el cliente: entra sola por el trigger.
grant execute on function public.fn_reopen_orphan_order(uuid, text) to service_role;


-- ─── El trigger ──────────────────────────────────────────────────────────────
create or replace function public.fn_block_items_on_closed_order()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_state text;
begin
  if new.order_id is null then
    return new;
  end if;

  -- Camino normal (99.99% de los inserts): una lectura por PK y afuera. El
  -- reanimador solo se invoca cuando la orden REALMENTE está cerrada, así el
  -- split de cuentas (que inserta decenas de filas) no paga nada extra.
  if not exists (
    select 1 from public.orders o
     where o.id = new.order_id
       and o.closed_at is not null
  ) then
    return new;
  end if;

  v_state := public.fn_reopen_orphan_order(new.order_id, 'order_item_insert');

  if v_state in ('revived', 'not_closed') then
    return new;
  elsif v_state = 'settled' then
    raise exception 'Esta cuenta ya fue cobrada. Abre la mesa otra vez para cargar productos nuevos.'
      using errcode = 'MP401';
  elsif v_state = 'table_taken' then
    raise exception 'La mesa ya se abrió en otra cuenta. Carga el producto en la cuenta activa.'
      using errcode = 'MP402';
  else
    raise exception 'La orden ya no existe.'
      using errcode = 'MP403';
  end if;
end;
$function$;

alter function public.fn_block_items_on_closed_order() owner to postgres;

drop trigger if exists trg_block_items_on_closed_order on public.order_items;
create trigger trg_block_items_on_closed_order
  before insert on public.order_items
  for each row
  execute function public.fn_block_items_on_closed_order();

commit;

-- =============================================================================
-- VERIFICACIÓN (correr después de aplicar)
-- =============================================================================
--   -- el trigger está montado
--   select tgname, tgenabled from pg_trigger
--    where tgrelid = 'public.order_items'::regclass and not tgisinternal;
--
--   -- ¿siguen apareciendo huérfanas nuevas? (debe quedar en 0 desde hoy)
--   select count(*) from public.orders o
--    where o.closed_at is not null
--      and o.created_at >= '2026-08-19'
--      and exists (select 1 from public.order_items oi
--                   where oi.order_id = o.id and oi.created_at > o.closed_at
--                     and oi.status <> 'void')
--      and not exists (select 1 from public.payments p
--                       where p.order_id = o.id and p.status = 'completed');
--
--   -- cuántas veces salvó la papeleta, por negocio
--   select b.business_name, count(*), max(r.revived_at)
--     from public.orphan_order_revivals r
--     left join public.businesses b on b.id = r.business_id
--    group by 1 order by 2 desc;
-- =============================================================================
