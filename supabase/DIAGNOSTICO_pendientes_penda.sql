-- =============================================================================
-- DIAGNÓSTICO — Pendientes de La Penda que dependen de migraciones
-- SOLO LECTURA. Una sola consulta: cada pieza → APLICADA / FALTA.
--
-- Complementa DIAGNOSTICO_sistema_listo_recetas.sql (que cubre inventario):
-- acá van las piezas fiscales y de caja de la lista enviada a Penda
-- («Mejoras generales del sistema, listas para instalar» y hallazgos H-2/H-3).
-- =============================================================================

with
fndef as (
  select p.proname, pg_get_functiondef(p.oid) as src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('fn_delete_item', 'fn_close_cash_session')
),
chk(orden, migracion, pieza, resultado) as (
  select 1, '20260902_0002', 'Abonos a crédito con número y recibo',
         exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'fn_register_credit_abono')
  union all
  select 2, '20260902_0008', 'H-2: conexión contable sin la Ley 10% inventada',
         coalesce((select pg_get_viewdef(to_regclass('analytics.documentos'), true)
                          not like '%order_item_tax_lines%'), false)
  union all
  select 3, '20260902_0010', 'H-3: no se pueden borrar ítems de una orden facturada (trigger)',
         exists (select 1 from pg_trigger
                  where tgname = 'trg_block_item_delete_on_invoiced' and not tgisinternal)
  union all
  select 4, '20260902_0011', 'H-3: fn_delete_item revisa el comprobante',
         coalesce((select bool_or(src like '%fiscal_documents%')
                     from fndef where proname = 'fn_delete_item'), false)
  union all
  select 5, '20260903_0001', 'Anulación con nota de crédito automática',
         exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'fn_issue_credit_note')
  union all
  select 6, '20260910_0001', 'Nota de venta (documento no fiscal)',
         exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'fn_issue_sales_note')
  union all
  select 7, '20260911_0001', 'Dueño/admin puede cerrar la caja de otro',
         coalesce((select bool_or(src like '%user_business_role%')
                     from fndef where proname = 'fn_close_cash_session'), false)
  union all
  select 8, '20260902_0005', 'Insumo nuevo entra a conteos abiertos (NO aplicar con conteos abiertos)',
         exists (select 1 from pg_trigger
                  where tgname = 'trg_inventory_items_join_open_counts' and not tgisinternal)
)
select orden, migracion, pieza,
       case when resultado then 'APLICADA' else 'FALTA' end as estado
  from chk
union all
-- Conteos físicos de La Penda que siguen abiertos (pendiente #1).
select 20, '—', 'Conteos físicos de La Penda en curso',
       coalesce(string_agg(s.code || ' (' || s.status || ')', ', ' order by s.code), 'ninguno')
  from public.physical_count_sessions s
 where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and s.status not in ('completed', 'cancelled', 'canceled')
order by orden;
