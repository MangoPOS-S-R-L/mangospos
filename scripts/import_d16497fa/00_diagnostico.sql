-- MAX PÍCAME EL POLLO — DIAGNÓSTICO (solo lee). Business d16497fa.
with
biz as (select 'd16497fa-4853-41e3-8566-4d0565511f37'::uuid as id),
nk(k) as (values
  ('pollo frito 2 piezas'), ('pollo frito 3 piezas'), ('pollo frito 4 piezas'),
  ('pollo frito 6 piezas'), ('pollo frito 8 piezas'), ('pollo frito 10 piezas'),
  ('pollo frito 12 piezas'), ('pollo frito 16 piezas'),
  ('pechurrina 3 piezas'), ('pechurrina 4 piezas'), ('pechurrina 6 piezas'),
  ('pechurrina 8 piezas')),
prods as (
  select mi.*,
         translate(lower(regexp_replace(btrim(mi.name), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun') as k,
         exists (select 1 from public.order_items oi where oi.product_id = mi.id) as vendido
  from public.menu_items mi, biz
  where mi.business_id = biz.id
),
tx as (select t.*, to_jsonb(t) as j from public.taxes t, biz where t.business_id = biz.id),
r(orden, sub, seccion, detalle) as (
  select 1, 0, '1 Negocio',
         format('%s / %s · tipo %s · estado %s · creado %s',
                b.business_name, coalesce(b.branch_name, '—'), coalesce(b.business_type, '—'),
                coalesce(b.status, '—'), b.created_at::date)
  from public.businesses b, biz where b.id = biz.id
  union all
  select 1, 0, '1 Negocio', '✗ NO EXISTE'
  where not exists (select 1 from public.businesses b, biz where b.id = biz.id)

  union all
  select 2, 0, '2 Ajustes',
         format('service_fee_enabled=%s · kitchen_enabled=%s · printerless_kitchen=%s · '
                'auto_print_order=%s · moneda=%s · inventory_mode=%s',
                coalesce(s.j->>'service_fee_enabled', '—'), coalesce(s.j->>'kitchen_enabled', '—'),
                coalesce(s.j->>'printerless_kitchen', '—'), coalesce(s.j->>'auto_print_order', '—'),
                coalesce(s.j->>'currency_code', '—'), coalesce(s.j->>'inventory_mode', '—'))
  from (select to_jsonb(bs) as j from public.business_settings bs, biz
        where bs.business_id = biz.id) s
  union all
  select 2, 0, '2 Ajustes', '✗ sin fila en business_settings'
  where not exists (select 1 from public.business_settings bs, biz where bs.business_id = biz.id)

  union all
  select 3, 0, '3 Impuesto',
         format('%s %s%% · activo=%s · is_service_fee=%s · include_in_ecf=%s · '
                'zona=%s manual=%s rápida=%s llevar=%s delivery=%s · productos=%s',
                t.name, t.rate, coalesce(t.j->>'is_active', '—'),
                coalesce(t.j->>'is_service_fee', '—'), coalesce(t.j->>'include_in_ecf', '—'),
                coalesce(t.j->>'apply_on_zone', '—'), coalesce(t.j->>'apply_on_manual', '—'),
                coalesce(t.j->>'apply_on_quick', '—'), coalesce(t.j->>'apply_on_takeout', '—'),
                coalesce(t.j->>'apply_on_delivery', '—'),
                (select count(*) from public.menu_item_taxes x where x.tax_id = t.id))
  from tx t
  union all
  select 3, 0, '3 Impuesto', '✗ el negocio no tiene ningún impuesto'
  where not exists (select 1 from tx)

  union all
  select 4, 0, '4 Área de comanda',
         format('%s (code %s) · activa=%s · impresoras=%s · productos=%s',
                a.name, a.code, a.is_active,
                (select count(*) from public.print_area_printers p where p.area_id = a.id),
                (select count(*) from public.menu_item_print_areas x where x.print_area_id = a.id))
  from public.print_areas a, biz where a.business_id = biz.id
  union all
  select 4, 0, '4 Área de comanda', 'ninguna'
  where not exists (select 1 from public.print_areas a, biz where a.business_id = biz.id)

  union all
  select 5, 0, '5 Menú',
         format('%s · activo=%s · productos enlazados=%s', m.name, m.is_active,
                (select count(*) from public.menu_item_links l where l.menu_id = m.id))
  from public.menus m, biz where m.business_id = biz.id
  union all
  select 5, 0, '5 Menú', 'ninguno (la carga crea "Menú Principal")'
  where not exists (select 1 from public.menus m, biz where m.business_id = biz.id)

  union all
  select 6, 0, '6 Catálogo',
         format('categorías=%s · productos=%s (activos %s) · con ventas=%s · grupos de modificadores=%s',
                (select count(*) from public.categories c, biz where c.business_id = biz.id),
                (select count(*) from prods), (select count(*) from prods where is_active),
                (select count(*) from prods where vendido),
                (select count(*) from public.modifier_groups g, biz where g.business_id = biz.id))
  union all
  select 7, c.position, '7 Categoría',
         format('%s · posición %s · activa=%s · productos activos=%s', c.name, c.position, c.is_active,
                (select count(*) from prods p where p.category_id = c.id and p.is_active))
  from public.categories c, biz where c.business_id = biz.id

  union all
  select 8, 0, '8 Grupo de modificadores',
         format('%s · min=%s max=%s · activo=%s · opciones: %s · productos=%s',
                g.name, g.min_select, g.max_select, g.is_active,
                coalesce((select string_agg(m.name || ' $' || m.price_delta, ', ')
                          from public.modifiers m where m.group_id = g.id), '—'),
                (select count(*) from public.menu_item_groups y where y.group_id = g.id))
  from public.modifier_groups g, biz where g.business_id = biz.id

  union all
  select 9, 0, '9 Ya existe (mismo nombre)',
         format('%s · $%s · activo=%s · ventas=%s', p.name, p.price, p.is_active,
                case when p.vendido then 'sí' else 'no' end)
  from prods p where p.k in (select k from nk)

  union all
  select 10, 0, '10 Nombre parecido',
         format('%s · $%s · activo=%s', p.name, p.price, p.is_active)
  from prods p
  where p.k not in (select k from nk)
    and p.k ~ '(pollo|pechur|pieza|toston|papa|alita)'
)
select seccion, detalle from r order by orden, sub, detalle;
