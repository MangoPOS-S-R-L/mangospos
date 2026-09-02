-- =============================================================================
-- Verificacion del candado de H-3 (20260902_0010) — SOLO LECTURA
-- =============================================================================

-- A ─── ¿Quedo instalado? ─────────────────────────────────────────────────────
--     ESPERADO: una fila, 'before delete', habilitado.
select t.tgname, p.proname as ejecuta,
       case t.tgenabled when 'O' then 'habilitado' else t.tgenabled::text end as estado,
       pg_get_triggerdef(t.oid) as definicion
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_proc  p on p.oid = t.tgfoid
where c.relname = 'order_items'
  and t.tgname = 'trg_block_item_delete_on_invoiced'
  and not t.tgisinternal;


-- B ─── ¿fn_delete_item tiene el candado adentro? ─────────────────────────────
--     OJO: mirar `prosecdef` NO sirve. La funcion sigue siendo SECURITY DEFINER
--     a proposito (lo necesita para resolver permisos), asi que eso no dice
--     nada sobre si la migracion 20260902_0011 se aplico.
--
--     Lo que hay que mirar es si el CUERPO trae la verificacion.
--     ESPERADO: tiene_el_candado = true
select p.proname,
       (pg_get_functiondef(p.oid) like '%MP404%')              as tiene_el_candado,
       (pg_get_functiondef(p.oid) like '%fiscal_documents%')   as consulta_comprobantes,
       obj_description(p.oid, 'pg_proc')                       as comentario
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'fn_delete_item';
-- tiene_el_candado = false  ->  falta aplicar 20260902_0011 y la app sigue
--                               borrando items de cuentas facturadas.


-- C ─── Alcance: cuantos items quedan protegidos ──────────────────────────────
--     Los "protegidos" son los que ya no se van a poder borrar. Los demas
--     (subcuentas sin facturar, ordenes abiertas) siguen borrandose igual.
select
  count(*)                                          as items_de_agosto,
  count(*) filter (where fd.id is not null)         as protegidos,
  count(*) filter (where fd.id is null)             as siguen_borrables
from public.order_items oi
join public.orders o on o.id = oi.order_id
left join public.fiscal_documents fd
       on fd.order_id = oi.order_id
      and fd.status = 'active'
      and (fd.check_id is null or fd.check_id = oi.check_id)
where oi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and oi.created_at >= date '2026-08-01';


-- D ─── PRUEBA REAL — hay que hacerla EN LA APP, no aqui ──────────────────────
--     En Studio corres como `postgres`, y el candado se salta a proposito para
--     no romper la consolidacion de splits. Aqui NO se puede probar.
--
--     Como probarlo de verdad:
--       1. Cobrar una mesa (que emita NCF).
--       2. Intentar eliminar un producto de esa mesa desde la POS.
--       3. Tiene que salir: "Esta cuenta ya está facturada. Anula el producto
--          en vez de borrarlo, o anula la factura completa."
--       4. En una mesa SIN cobrar, eliminar un producto debe seguir funcionando.
--       5. Dividir una cuenta, cobrar UNA subcuenta, y borrar un producto de
--          OTRA subcuenta todavia sin cobrar: debe seguir permitido.
--
--     El paso 5 es el que mas importa: es el que se rompe si el candado quedo
--     mal acotado.
