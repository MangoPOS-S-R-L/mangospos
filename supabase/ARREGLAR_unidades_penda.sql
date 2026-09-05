-- =============================================================================
-- LA PENDA EXPRESS — sacar las libras de adentro de los «litros»
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- POR QUÉ PASÓ: el selector de unidades del formulario no tenía libra
-- (`baseUnitOptions` = unidad · ml · L · oz · g · kg). Quien creó el pastrami
-- necesitaba libras, vio la «L» y la escogió. Es lo lógico: la L está
-- exactamente donde debería estar la libra.
--
-- YA SE ARREGLÓ EN LA APP: `lib/core/inventory/unit_conversion.dart` ahora
-- conoce la libra (1 lb = 453.59237 g) y la ofrece en el selector. Esto de
-- acá arregla los datos que se crearon mientras el hueco existía.
--
-- ES UN RE-ETIQUETADO, NO UNA CONVERSIÓN. La cocina contó 6 de pastrami
-- pensando en libras y el sistema lo guardó diciendo «litros». El número es
-- correcto; la palabra no. Por eso NO se toca `quantity` en ningún lado: si
-- multiplicáramos, estaríamos inventando mercancía que nadie contó.
--
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. ANTES DE TOCAR NADA — los 52 insumos que dicen «litro», con una pista de
--    cuáles lo son de verdad. Revisá la columna `pista` y bajá a mano
--    cualquier fila que la heurística haya clasificado mal.
-- ---------------------------------------------------------------------------
select
  i.id,
  i.name                                          as articulo,
  round(coalesce(i.cost, 0), 2)                   as costo_por_L,
  coalesce((select sum(s.quantity) from public.inventory_stock s
             where s.item_id = i.id), 0)          as existencia,
  round(coalesce((select sum(s.quantity) from public.inventory_stock s
                   where s.item_id = i.id), 0)
        * coalesce(i.cost, 0), 2)                 as valor,
  (select count(*) from public.recipe_ingredients ri
    where ri.inventory_item_id = i.id)            as en_recetas,
  case
    when i.name ~* '\m(aceite|vinagre|jugo|leche|agua|salsa|sirope|jarabe|crema|refresco|vino|ron|whisky|cerveza|licor|almibar|caldo|soda|te|cafe)\M'
      then 'líquido — dejar en L'
    when i.name ~* '\m(pastrami|salami|pepperoni|jamon|jam[oó]n|queso|carne|pollo|res|cerdo|salm[oó]n|pescado|tocineta|chuleta|costilla|pavo|embutido|longaniza|chorizo)\M'
      then 'PESO — pasar a lb'
    else 'revisar a mano'
  end                                             as pista
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
  and lower(btrim(i.unit)) in ('l', 'lt', 'litro', 'litros')
order by 5 desc;


-- ---------------------------------------------------------------------------
-- 2. RE-ETIQUETAR los cinco que ya están confirmados por nombre y por costo.
--
--    El costo es la prueba: RD$354 la libra de pastrami es un precio de
--    charcutería; RD$354 el litro de pastrami no significa nada. Igual con el
--    salami, el pepperoni y el salmón. Ninguno tiene recetas todavía
--    (`en_recetas = 0`), así que el cambio no arrastra descuentos viejos.
--
--    Se listan por ID para que no haya forma de que agarre otra fila.
-- ---------------------------------------------------------------------------
update public.inventory_items
   set unit = 'lb'
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and id in (
     'd6c63496-fd67-42ce-9cd6-b4d99e1b2d92',  -- PASTRAMI            · contado 6
     '485d54f4-8499-4de5-a683-0c7f9e1ff1bb',  -- Salami Genoa        · contado 9
     '6fcd25a7-f89d-4e32-b3c2-72139c65b15d',  -- Pepperoni Pedrollo  · contado 3.3
     '914856c3-dfb0-42f2-a984-01a36498a1a3'   -- Salmón penca        · sin contar
   )
   and lower(btrim(unit)) = 'l';
-- Debe decir UPDATE 4.


-- ---------------------------------------------------------------------------
-- 3. QUESO GEO — este NO se toca todavía.
--
--    Dice unidad «L», unidad de compra «CAJA» y cuesta RD$3,094.58. Una caja
--    de queso no es un litro, pero tampoco sabemos cuántas libras trae, y sin
--    ese dato el `pack_size` quedaría inventado. Es pregunta para la cocina:
--    ¿cuántas libras trae la caja de queso Geo?
--
--    Cuando lo sepas:
--        update public.inventory_items
--           set unit = 'lb', purchase_unit = 'Caja', pack_size = <libras>
--         where id = '50ca7ec4-48b8-4421-a10f-80af73ed7cfa';
--
--    OJO con la existencia: hoy dice 1. Si esa 1 es UNA CAJA y el pack_size
--    pasa a ser 40 libras, la existencia en unidad base tiene que pasar a 40
--    también, o el inventario se encoge de golpe. Ese SÍ es un ajuste de
--    cantidad y va por `fn_inventory_adjust`, no por update directo.
select id, name, unit, purchase_unit, pack_size, cost,
       (select sum(quantity) from public.inventory_stock
         where item_id = inventory_items.id) as existencia
from public.inventory_items
where id = '50ca7ec4-48b8-4421-a10f-80af73ed7cfa';


-- ---------------------------------------------------------------------------
-- 4. LOS OCHO A MEDIAS — declaran su unidad de compra pero con contenido 1,
--    que es lo mismo que no declararla. Quedan a la espera del dato real:
--
--      JUGO DE CEREZA        · GALON   · 742 en existencia · falta: ml por galón
--      GAS COCINA            · GALONES · 144.3             · ¿se cuenta por galón?
--      MCCAIN FLAVORLAST     · LIBRA   · 300 lb            · ya está en lb, OK
--      QUESO GEO             · CAJA    · 1                 · ver punto 3
--      SACO DE REFRISAL      · SACO    · 4                 · falta: libras por saco
--      leche de almendra     · botella · 2                 · falta: ml por botella
--      TEQUILA DON JULIO     · BOTELLA · 0                 · falta: ml por botella
--      cigarro unkind        · unidad  · 1                 · unidad = unidad, OK
--
--    Los tres últimos con «unidad de compra = la misma unidad base» no son un
--    problema real: comprar por unidad y contar por unidad es coherente.
-- ---------------------------------------------------------------------------
select i.id, i.name, i.unit, i.purchase_unit, i.pack_size,
       round(coalesce(i.cost, 0), 2) as costo,
       coalesce((select sum(s.quantity) from public.inventory_stock s
                  where s.item_id = i.id), 0) as existencia
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
  and i.purchase_unit is not null
  and coalesce(i.pack_size, 1) <= 1
order by i.name;


-- ---------------------------------------------------------------------------
-- 5. VERIFICAR — el censo después del arreglo.
-- ---------------------------------------------------------------------------
select
  coalesce(nullif(btrim(i.unit), ''), '(vacía)')     as unidad,
  count(*)                                           as insumos,
  round(100.0 * count(*) / sum(count(*)) over (), 1) as porcentaje
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
group by 1
order by count(*) desc;
