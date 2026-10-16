-- =============================================================================
-- El Nido: ¿los productos de las cuentas en revisión se reteclearon? (SOLO LECTURA)
-- =============================================================================
-- Las 4 cuentas en revisión (late_items_after_settle) traen productos POR
-- CONFIRMAR que un equipo con app 2.0.7 agregó a una cuenta ya cobrada (horas
-- o días antes). Si el mesero los volvió a teclear en la cuenta nueva de la
-- mesa y se cobraron, la cuenta en revisión es un DUPLICADO y se anula.
--
-- Una fila por producto en revisión. Busca el mismo producto en OTRAS cuentas
-- de la misma mesa, 3 h antes o después.
-- Hora en República Dominicana.
-- =============================================================================
with rev_items as (
  select dt.id as table_id,
         dt.code as mesa,
         o.id as review_order_id,
         oi.id as item_id,
         oi.product_name,
         oi.total,
         oi.created_at
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    join public.dining_tables dt on dt.id = ts.table_id
    join public.zones z on z.id = dt.zone_id
    join public.order_items oi on oi.order_id = o.id
   where coalesce(ts.business_id, z.business_id) = 'd2aea1c8-f927-479c-9581-b236d6df3955'
     and o.closed_at is null
     and o.status_ext::text not in ('paid', 'void')
     and to_jsonb(o) ->> 'review_reason' is not null
     and oi.status::text <> 'void'
),
matches as (
  select r.item_id,
         jsonb_agg(jsonb_build_object(
           'cuenta', left(o2.id::text, 8),
           'estado_cuenta', o2.status_ext::text,
           'estado_producto', oi2.status::text,
           'agregado', to_char(oi2.created_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
           'total', oi2.total
         ) order by oi2.created_at) as coincidencias,
         bool_or(o2.status_ext::text = 'paid' or oi2.status::text = 'paid') as cobrado
    from rev_items r
    join public.table_sessions ts2 on ts2.table_id = r.table_id
    join public.orders o2 on o2.session_id = ts2.id and o2.id <> r.review_order_id
    join public.order_items oi2 on oi2.order_id = o2.id
   where oi2.product_name = r.product_name
     and oi2.status::text <> 'void'
     and o2.status_ext::text <> 'void'
     and oi2.created_at between r.created_at - interval '3 hours'
                            and r.created_at + interval '3 hours'
   group by r.item_id
)
select r.mesa,
       left(r.review_order_id::text, 8) as cuenta_revision,
       r.product_name as producto,
       r.total,
       to_char(r.created_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI') as agregado,
       case
         when m.cobrado then 'Se retecleó y se COBRÓ en otra cuenta → duplicado, anular'
         when m.item_id is not null then 'Se retecleó en otra cuenta SIN cobrar → revisar esa cuenta'
         else 'NO aparece en otra cuenta de la mesa → preguntar si se sirvió'
       end as veredicto,
       m.coincidencias
  from rev_items r
  left join matches m on m.item_id = r.item_id
 order by r.mesa, r.created_at;
