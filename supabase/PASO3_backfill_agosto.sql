-- =============================================================================
-- PASO 3 · Backfill de agosto — La Penda Express
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- POR QUE ESTA ESCRITO ASI:
--   El SQL Editor de Studio NO respeta `begin; ... rollback;` — ejecuta y
--   commitea por sentencia. Comprobado en el paso 2: el rollback no revirtio
--   nada. Por eso TODO va dentro de un unico bloque DO.
--
--   Un bloque DO es UNA sola sentencia: o se aplica entero o no se aplica nada.
--   Y un `raise exception` adentro revierte todo lo que el bloque hizo,
--   incluida la tabla de respaldo. Eso si es atomico pase lo que pase.
--
--   Los numeros se reportan mediante el propio mensaje de la excepcion, porque
--   los `raise notice` pueden no mostrarse en Studio.
--
-- CORRER 3.1 PRIMERO. Es un simulacro: siempre aborta, nunca escribe.
-- =============================================================================


-- ─── 3.1 · SIMULACRO — calcula todo y aborta a proposito ─────────────────────
--
--   Escribe, mide, y despues se revierte solo con un raise exception.
--   Al terminar veras un ERROR: eso es lo esperado, es el informe.
--   NO QUEDA NADA ESCRITO.
--
--   Cotejar el "itbis_despues" con DH antes de correr 3.2.
do $$
declare
  v_filas   int;
  v_antes   numeric;
  v_despues numeric;
  v_ley     numeric;
  v_desc    numeric;
begin
  select round(sum(coalesce(itbis_amount,0)), 2) into v_antes
  from public.fiscal_documents
  where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and status = 'active'
    and (issued_at at time zone 'America/Santo_Domingo')::date
        between date '2026-08-01' and date '2026-08-31';

  -- Recomputa cada comprobante con la v6, igual que hara una venta nueva.
  -- Los que no tienen items vivos (H-3/H-4) los salta la propia funcion por su
  -- safeguard de v_item_count = 0.
  perform public.fn_recompute_fd_for_scope(d.id, d.order_id, d.check_id)
  from public.fiscal_documents d
  where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and d.status = 'active'
    and (d.issued_at at time zone 'America/Santo_Domingo')::date
        between date '2026-08-01' and date '2026-08-31';

  select round(sum(coalesce(itbis_amount,0)), 2),
         round(sum(coalesce(service_fee,0)), 2),
         round(sum(coalesce(subtotal,0) + coalesce(itbis_amount,0)
                 + coalesce(service_fee,0) - coalesce(total,0)), 2),
         count(*)
    into v_despues, v_ley, v_desc, v_filas
  from public.fiscal_documents
  where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and status = 'active'
    and (issued_at at time zone 'America/Santo_Domingo')::date
        between date '2026-08-01' and date '2026-08-31';

  raise exception E'=== SIMULACRO (no se escribio nada) ===\n'
    'comprobantes      : %\n'
    'ITBIS antes       : %\n'
    'ITBIS despues     : %   <-- cotejar con DH (~779,169)\n'
    'LEY despues       : %\n'
    'descuadre total   : %   <-- deben ser centavos, no miles',
    v_filas, v_antes, v_despues, v_ley, v_desc;
end
$$;


-- ─── 3.2 · EL BACKFILL DE VERDAD ─────────────────────────────────────────────
--
--   NO CORRER hasta cotejar el numero del simulacro con DH.
--
--   Toma respaldo, recomputa, verifica, y si el resultado se sale del rango
--   razonable REVIERTE TODO solo. Si termina sin error, quedo aplicado.
--
--   Descomentar para usar.
/*
do $$
declare
  v_filas   int;
  v_despues numeric;
  v_ley     numeric;
  v_desc    numeric;
begin
  -- 1. Respaldo. Si ya existe, el backfill ya se corrio: abortar.
  if to_regclass('public._backup_fd_607_penda_agosto') is not null then
    raise exception 'Ya existe _backup_fd_607_penda_agosto: el backfill ya se corrio. '
                    'Revisar antes de repetir.';
  end if;

  create table public._backup_fd_607_penda_agosto as
  select id, subtotal, discount, taxable_amount, itbis_amount, service_fee, total,
         now() as respaldado_en
  from public.fiscal_documents
  where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and status = 'active'
    and (issued_at at time zone 'America/Santo_Domingo')::date
        between date '2026-08-01' and date '2026-08-31';

  -- 2. Recomputar.
  perform public.fn_recompute_fd_for_scope(d.id, d.order_id, d.check_id)
  from public.fiscal_documents d
  where d.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and d.status = 'active'
    and (d.issued_at at time zone 'America/Santo_Domingo')::date
        between date '2026-08-01' and date '2026-08-31';

  -- 3. Verificar.
  select round(sum(coalesce(itbis_amount,0)), 2),
         round(sum(coalesce(service_fee,0)), 2),
         round(sum(coalesce(subtotal,0) + coalesce(itbis_amount,0)
                 + coalesce(service_fee,0) - coalesce(total,0)), 2),
         count(*)
    into v_despues, v_ley, v_desc, v_filas
  from public.fiscal_documents
  where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and status = 'active'
    and (issued_at at time zone 'America/Santo_Domingo')::date
        between date '2026-08-01' and date '2026-08-31';

  -- 4. Guarda: si el ITBIS no cae donde esperamos, revertir TODO.
  if v_despues < 700000 or v_despues > 850000 then
    raise exception 'ITBIS resultante % fuera del rango esperado (700k-850k). '
                    'Se revirtio todo, no se escribio nada.', v_despues;
  end if;

  raise notice 'OK: % comprobantes, ITBIS %, LEY %, descuadre %',
    v_filas, v_despues, v_ley, v_desc;
end
$$;

-- Confirmar despues de correr 3.2:
select count(*)                                      as comprobantes,
       round(sum(coalesce(itbis_amount,0)), 2)       as itbis,
       round(sum(coalesce(service_fee,0)), 2)        as ley,
       count(*) filter (where coalesce(itbis_amount,0) = 0) as todavia_en_cero
from public.fiscal_documents
where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and status = 'active'
  and (issued_at at time zone 'America/Santo_Domingo')::date
      between date '2026-08-01' and date '2026-08-31';
*/


-- ─── 3.3 · DESHACER (solo si hace falta, tras correr 3.2) ────────────────────
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
-- drop table public._backup_fd_607_penda_agosto;   -- solo cuando ya no haga falta
*/
