-- =============================================================================
-- PASO 4 · BACKFILL DE AGOSTO — ESCRIBE EN fiscal_documents
-- La Penda Express · business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- MEDIDO EN EL SIMULACRO (paso 3):
--   6.007 comprobantes activos de agosto
--     16 la funcion no los toca (sin pagos o sin items vivos)
--      0 cambian de TOTAL          <- las ventas del mes no se mueven
--      2 cambian de BASE           <- los dos casos H-3, se excluyen
--      4 no cierran su identidad   <- datos corruptos previos, se excluyen
--   ITBIS  307.703,78  ->  794.566,14
--
-- QUE ESCRIBE:  subtotal, taxable_amount, itbis_amount, service_fee
-- QUE NO ESCRIBE:  total, NCF, status, fecha, cliente, pagos, items.
--                  El monto cobrado NO cambia.
--
-- SEGURIDAD:
--   * Todo en un unico bloque DO: o entra completo o no entra nada.
--     (En Studio `begin/rollback` NO funciona: commitea por sentencia.)
--   * Respaldo en _backup_fd_607_penda_agosto ANTES de escribir.
--   * Solo toca comprobantes cuya identidad cierra dentro de 1 peso.
--   * Si el ITBIS resultante se sale del rango, revierte TODO solo.
--
-- REQUISITO: la tabla _sim_607_penda del paso 3.1 tiene que estar recien
-- construida. Si paso tiempo, volver a correr el BLOQUE 1 del paso 3.1.
-- =============================================================================


-- ═══ 4.1 · EL BACKFILL ═══════════════════════════════════════════════════════
do $$
declare
  v_filas   int;
  v_itbis   numeric;
  v_ley     numeric;
  v_peor    numeric;
begin
  if to_regclass('public._sim_607_penda') is null then
    raise exception 'Falta _sim_607_penda: correr el BLOQUE 1 del paso 3.1 primero.';
  end if;

  if to_regclass('public._backup_fd_607_penda_agosto') is not null then
    raise exception 'Ya existe _backup_fd_607_penda_agosto: el backfill ya se corrio. '
                    'Revisar antes de repetir.';
  end if;

  -- 1. Respaldo de TODO el rango, no solo de lo que se toca.
  create table public._backup_fd_607_penda_agosto as
  select d.id, d.subtotal, d.discount, d.taxable_amount,
         d.itbis_amount, d.service_fee, d.total, now() as respaldado_en
  from public.fiscal_documents d
  where d.id in (select id from public._sim_607_penda);

  -- 2. Escribir SOLO los limpios.
  --    Se excluyen los 4 cuya identidad no cierra (lote roto del 13-ago y los
  --    casos H-3): esos van a mano, no por backfill.
  update public.fiscal_documents d
     set subtotal       = round(s.subtotal_nuevo, 2),
         taxable_amount = round(s.subtotal_nuevo, 2),
         itbis_amount   = round(s.itbis_nuevo, 2),
         service_fee    = round(s.ley_nuevo, 2)
  from public._sim_607_penda s
  where d.id = s.id
    and s.subtotal_nuevo is not null
    and abs(s.subtotal_nuevo + s.itbis_nuevo + s.ley_nuevo - s.total_hoy) <= 1.00;

  get diagnostics v_filas = row_count;

  -- 3. Verificar sobre lo realmente escrito.
  select round(sum(coalesce(itbis_amount,0)), 2),
         round(sum(coalesce(service_fee,0)), 2),
         round(max(abs(coalesce(subtotal,0) + coalesce(itbis_amount,0)
                     + coalesce(service_fee,0) - coalesce(total,0))), 2)
    into v_itbis, v_ley, v_peor
  from public.fiscal_documents
  where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and status = 'active'
    and (issued_at at time zone 'America/Santo_Domingo')::date
        between date '2026-08-01' and date '2026-08-31';

  -- 4. Guardas. Cualquiera que falle revierte el bloque entero, respaldo incluido.
  if v_filas < 5900 or v_filas > 5995 then
    raise exception 'Filas escritas % fuera de lo esperado (5900-5995). Se revirtio todo.', v_filas;
  end if;

  if v_itbis < 780000 or v_itbis > 810000 then
    raise exception 'ITBIS resultante % fuera del rango esperado (780k-810k). Se revirtio todo.', v_itbis;
  end if;

  raise notice 'OK — filas: %, ITBIS: %, LEY: %, peor descuadre: %',
    v_filas, v_itbis, v_ley, v_peor;
end
$$;


-- ═══ 4.2 · CONFIRMAR ═════════════════════════════════════════════════════════
--   ESPERADO: itbis ~794.566  ·  todavia_en_cero = 16 a 20  ·  peor_descuadre
--             solo grande en los 4 excluidos.
select
  count(*)                                                   as comprobantes,
  round(sum(coalesce(itbis_amount,0)), 2)                    as itbis,
  round(sum(coalesce(service_fee,0)), 2)                     as ley,
  count(*) filter (where coalesce(itbis_amount,0) = 0)       as todavia_en_cero,
  count(*) filter (where abs(coalesce(subtotal,0) + coalesce(itbis_amount,0)
                    + coalesce(service_fee,0) - coalesce(total,0)) > 1.00)
                                                             as no_cierran
from public.fiscal_documents
where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and status = 'active'
  and (issued_at at time zone 'America/Santo_Domingo')::date
      between date '2026-08-01' and date '2026-08-31';


-- ═══ 4.3 · DESHACER — solo si hace falta ═════════════════════════════════════
/*
do $$
begin
  update public.fiscal_documents d
     set subtotal = b.subtotal, discount = b.discount,
         taxable_amount = b.taxable_amount, itbis_amount = b.itbis_amount,
         service_fee = b.service_fee, total = b.total
    from public._backup_fd_607_penda_agosto b
   where d.id = b.id;
  raise notice 'Revertido desde el respaldo.';
end
$$;
*/

-- Limpieza, solo cuando DH ya haya declarado y no haga falta volver atras:
-- drop table public._sim_607_penda;
-- drop table public._backup_fd_607_penda_agosto;
