-- =============================================================================
-- PASO 2 · LA PENDA EXPRESS — reconciliar el conteo de cocina contra el Excel
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Los 35 renglones que la cocina contó en papel, con el id que el Excel ya
-- les asignó. GENERADO desde el archivo, sin transcribir a mano.
--
-- QUÉ RESPONDE:
--   · ¿el insumo sigue existiendo y activo?
--   · ¿la unidad del sistema coincide con la que usó quien contó?
--   · ¿lo que está cargado en la sesión de cocina es lo que dice el papel?
--   · ¿cuánto se mueve el inventario si esto se cierra tal como está?
--
-- La columna `unidades_coinciden` es la importante: donde diga NO, el número
-- del papel y el del sistema hablan idiomas distintos y cerrar así mete un
-- ajuste falso.
-- =============================================================================

with papel(item_id, dice_la_hoja, cant, uni) as (values
  ('e7dc40a8-5100-4b38-8e40-88f053ac8a80'::uuid, 'Aji morron amarillo', 0.5, 'libras'),
  ('e3147d55-5633-45ee-ba9a-29f9b330a760'::uuid, 'CARNE SALADA 10 onzas', 1.0, 'bolsas'),
  ('1777df41-1169-4614-a6c7-470bc0d75af9'::uuid, 'SALSA BBQ', 1.0, 'unidad'),
  ('df112b8a-7458-416a-a666-db3036d994e1'::uuid, 'FILETE DE SALMON 8 onza', 1.0, 'unidad'),
  ('197d82fa-fe07-4552-93b4-849a8ce96eea'::uuid, 'MANTEQUILLA DORINA 45OZ', 2.0, 'unidad'),
  ('cdee569a-f603-4818-a0cf-5675ddb1d6bd'::uuid, 'Aji Cubanela', 2.5, 'libras'),
  ('6ba4e779-fceb-4143-b71b-e231bcbc334d'::uuid, 'TOMATE BARCELO', 2.93, 'libras'),
  ('cc01f726-1955-47e4-8060-fa5afa9a9e65'::uuid, 'Aji morron Rojo', 3.0, 'libras'),
  ('26697de2-775a-4e4f-9d28-2f76ca7190fa'::uuid, 'ZUCCHINI', 3.0, 'unidad'),
  ('122a3d3f-2e0e-4adf-891b-44f7672abd7e'::uuid, 'PUERRO ANCHO', 3.36, 'libras'),
  ('22c6c8f6-4237-407b-a954-0190d4596b43'::uuid, 'PIMIENTA NEGRA MOLIDA', 5.0, 'libras'),
  ('56da1160-5ff8-4224-b05c-634f99329432'::uuid, 'Apio', 5.0, 'libras'),
  ('8ec8627b-53fb-4a40-970e-6b081526469a'::uuid, 'ZANAHORIA', 5.0, 'libras'),
  ('e1890ea5-ef55-40da-9c5c-5cb00e281a1e'::uuid, 'JAMON DE PAVO CASERIO LBS', 6.5, 'LIBRAS'),
  ('68dff758-4461-49ec-b063-469cf3f8a1dd'::uuid, 'CEPA DE APIO 10 onzas', 8.0, 'bolsas'),
  ('777b31c5-301e-447b-ada1-de4013361f07'::uuid, 'MANTECA NUESTRA 50 libras', 10.0, 'caja'),
  ('d5b7e98b-cbd9-4e1f-9648-e14be92f805f'::uuid, 'QUIPE DE POLLO', 10.0, 'unidad'),
  ('eb3e5f70-a3be-43d5-9b1e-f99462e3f77b'::uuid, 'QUIPE DE QUESO DE  CABRA', 12.0, 'unidad'),
  ('d39590f7-c7d7-4fea-9e9e-b2e592fb940e'::uuid, 'PEPINO FRESCO', 13.0, 'unidad'),
  ('e0c7950e-f20e-44d6-8735-f4d02c0f36bd'::uuid, 'CHIVO GUISADO', 13.0, 'unidad'),
  ('b357c6d9-9735-4f0b-8f2a-d62abb25aa55'::uuid, 'SALAMI SUPER ESPECIAL 3.47 LB', 20.0, 'unidad'),
  ('fde57faa-b1b2-4708-9eba-ab24acad3529'::uuid, 'MORTADELA ALEGRIA', 20.0, 'LIBRAS'),
  ('3306a200-6105-456d-b1b7-54ea5603e8e7'::uuid, 'HUEVOS FRECOS', 29.0, 'cartones'),
  ('0cb23cb5-9d9f-4aa9-8796-d3d0d2b527a3'::uuid, 'Berengena', 30.0, 'unidad'),
  ('5fd1d147-6508-449e-a9c9-83c79c6a98bb'::uuid, 'FILETE DE PECHUGA DE POLLO FRESCO 10 onza', 32.0, 'bolsas'),
  ('6c892302-40bd-4543-a45d-4104cacfefa9'::uuid, 'PALITOS YUQUITAS BOLSA', 39.0, 'unidad'),
  ('ea915c9a-fd40-420b-bff9-31e338ae39a9'::uuid, 'ALITAS FRESCAS', 46.0, 'bolsas'),
  ('9e3008df-1f98-4b53-8729-03f58c7f2afb'::uuid, 'SANCOCHO PENDA', 53.0, 'unidad'),
  ('e27e130e-9506-452e-b837-dd145981fda0'::uuid, 'QUESO DE FREIR BLANCO', 60.0, 'LIBRAS'),
  ('67f5a7bd-e091-4e12-8ebf-fd460ebd82a8'::uuid, 'EMPANADA DE POLLO', 95.0, 'unidad'),
  ('17f6b501-628d-4a5e-ab39-a3e05310221f'::uuid, 'QUIPE DE RES', 100.0, 'unidad'),
  ('fb176a38-0946-4043-9f5a-991a133a0dbd'::uuid, 'EMPANADA QUESO BOTANA', 107.0, 'unidadd'),
  ('e0d2e3fc-bcf4-43b9-ba2c-356e5bfdf799'::uuid, 'EMPANADA BOTANA PIZZA BOTANA', 137.0, 'unidad'),
  ('f1aebda2-0464-46eb-b3f8-7fadce9f9c7c'::uuid, 'LONGANIZA CASERA ARTESANAL', 110.0, 'bolsas'),
  ('3f361492-a768-408f-bd72-0197010e7ee1'::uuid, 'LIMONES FRESCOS', 25.0, 'libras')
)
select
  p.dice_la_hoja,
  p.cant                                        as papel,
  p.uni                                         as unidad_papel,
  i.name                                        as en_el_sistema,
  i.unit                                        as unidad_sistema,
  round(coalesce(i.cost, 0), 2)                 as costo,
  coalesce((select sum(s.quantity) from public.inventory_stock s
             where s.item_id = i.id), 0)        as existencia,
  l.counted_quantity                            as cargado_en_conteo,
  case
    when i.id is null then '❌ el insumo ya no existe'
    when lower(p.uni) like 'libra%'  and lower(i.unit) in ('lb','libra','libras') then 'sí'
    when lower(p.uni) like 'unidad%' and lower(i.unit) = 'unidad'                 then 'sí'
    when lower(p.uni) like 'bolsa%'  and lower(i.unit) = 'bolsa'                  then 'sí'
    when lower(p.uni) like 'caja%'   and lower(i.unit) = 'caja'                   then 'sí'
    when lower(p.uni) like 'carton%' and lower(i.unit) = 'carton'                 then 'sí'
    else 'NO  ← ' || p.uni || ' vs ' || coalesce(i.unit,'?')
  end                                           as unidades_coinciden,
  case when l.counted_quantity is null then null
       when l.counted_quantity = p.cant then 'igual'
       else 'DIFIERE del papel' end             as vs_conteo,
  round((coalesce(l.counted_quantity, p.cant)
         - coalesce((select sum(s.quantity) from public.inventory_stock s
                      where s.item_id = i.id), 0))
        * coalesce(i.cost, 0), 2)               as impacto_rd,
  p.item_id
from papel p
left join public.inventory_items i
       on i.id = p.item_id
      and i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and coalesce(i.is_active, true)
left join lateral (
  select l.counted_quantity
    from public.physical_count_lines l
    join public.physical_count_sessions s on s.id = l.session_id
   where l.item_id = p.item_id
     and s.code = 'PC-2026-000003'
   limit 1
) l on true
order by
  (i.id is null) desc,
  (case when lower(p.uni) like 'libra%'  and lower(i.unit) in ('lb','libra','libras') then 0
        when lower(p.uni) like 'unidad%' and lower(i.unit) = 'unidad'                 then 0
        when lower(p.uni) like 'bolsa%'  and lower(i.unit) = 'bolsa'                  then 0
        else 1 end) desc,
  abs(round((coalesce(l.counted_quantity, p.cant)
             - coalesce((select sum(s.quantity) from public.inventory_stock s
                          where s.item_id = i.id), 0))
            * coalesce(i.cost, 0), 2)) desc;
