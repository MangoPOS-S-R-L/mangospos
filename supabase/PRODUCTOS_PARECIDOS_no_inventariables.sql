-- =============================================================================
-- Antes de crear los 38 insumos: ¿ya están en el MENÚ, sin inventario?
--
-- POR QUÉ IMPORTA:
--   Un producto del menú con `is_inventory_tracked = false` se vende pero no
--   descuenta nada. Si además creamos el insumo por separado, quedan dos
--   registros del mismo artículo: el que se vende y el que se cuenta, sin
--   relación entre ellos. El conteo cuadra y la venta no descuenta — o al
--   revés.
--
--   Lo correcto en ese caso NO es crear el insumo suelto: es prenderle el
--   inventario al producto que ya existe (el switch «Inventariable»), que
--   crea el insumo y lo deja enlazado.
--
-- Devuelve una fila por cada producto del menú parecido a alguno de los 38.
-- Si un renglón no aparece acá, no hay nada parecido en el menú.
-- =============================================================================

with nuevos(nombre) as (values
  ('Aceituna Gourmet con hueso'),('Anis Estrella'),
  ('Sazon completo baldom de 8 libras'),('Jengibre molido'),('Alcaparra'),
  ('Papicra'),('Ajo granulado'),('Trident Menta Fuerte'),
  ('Pasta Penne del bravo'),('Pasta de coditos del bravo'),
  ('Crema de leche Bravo pequena'),('Mostaza Frenchs'),('Nuez mocada bravo'),
  ('Azucar liquida blue agave'),('Lata de maiz dulce de 70 oz Linda'),
  ('Sesame Oil de 6.28 on'),('Chispas de chocolates NTD de 5 libras'),
  ('Pasta Penne'),('Pasta Linguine'),('Leche Condesada Nestle'),
  ('malagueta bravo'),('Tajin'),('Balsamic vinagre de 1 lt'),
  ('Cebolla granulada'),('Cocoa Amarga'),('Vainilla Blanca de 16 oz'),
  ('Pote de cinamon'),('Lata de tomatos triturados 6.6 lib'),
  ('bicarbonato barvo'),('Espaguetis Primavera'),('Azucar Pulverizada'),
  ('Leche Parmalat Sin lactorsa'),('Cocoa dulce'),('Gatorade Fresa Sandia'),
  ('Leche Condesada Condesada'),('Huevos Sorpresas'),
  ('Caja de sopita dona gallina'),('Sazon azafran ranchero')
),
n as (
  select nombre,
         regexp_replace(translate(lower(nombre),'áéíóúüñ','aeiouun'),
                        '[^a-z0-9]','','g') as norm
    from nuevos
),
p as (
  select mi.id, mi.name, mi.is_active,
         coalesce(mi.is_inventory_tracked, false) as inventariable,
         mi.inventory_item_id,
         regexp_replace(translate(lower(mi.name),'áéíóúüñ','aeiouun'),
                        '[^a-z0-9]','','g') as norm
    from public.menu_items mi
   where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
)
select
  n.nombre                    as insumo_a_crear,
  p.name                      as producto_en_el_menu,
  case when p.inventariable then 'SÍ' else 'NO ← revisar' end as inventariable,
  case when p.inventory_item_id is not null then 'sí' else 'no' end
                              as enlazado_a_insumo,
  case when p.is_active then '' else 'producto inactivo' end as ojo,
  case
    when not p.inventariable
      then 'Prenderle «Inventariable» al producto, NO crear el insumo suelto'
    when p.inventariable and p.inventory_item_id is null
      then 'Inventariable pero sin insumo enlazado: revisar'
    else 'Ya está inventariado: no crear nada'
  end                         as que_hacer
from n
join p
  -- ESTRICTO A PROPÓSITO. La versión anterior buscaba por la primera palabra
  -- larga y "Leche Condesada" casaba con TODOS los productos que dicen
  -- "leche": ochenta filas de ruido por un hallazgo. Ahora sólo entra un
  -- nombre igual, o uno contenido en el otro cuando además los largos son
  -- parecidos — así "MALAGUETA" sigue casando con "malagueta bravo" pero
  -- "CAFE CON LECHE" ya no casa con nada.
  on p.norm = n.norm
  or (
       (p.norm like '%' || n.norm || '%' or n.norm like '%' || p.norm || '%')
       and least(length(p.norm), length(n.norm)) >= 6
       and least(length(p.norm), length(n.norm))::numeric
           / greatest(length(p.norm), length(n.norm)) >= 0.6
     )
order by (p.inventariable), n.nombre, p.name;
