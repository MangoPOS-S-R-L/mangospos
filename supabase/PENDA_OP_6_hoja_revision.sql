-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 6: la hoja de revisión
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. UNA sola consulta. REQUIERE el PASO 6 (tabla _recetario_penda).
--
-- QUÉ ES: las 225 líneas del recetario, ordenadas por cuánto pesan, con los
-- TRES candidatos más parecidos del catálogo y tres columnas vacías para que
-- la cocina escriba la decisión. Se exporta a CSV desde Studio (botón
-- «Download CSV» del resultado) y se llena a mano.
--
-- CÓMO SE ELIGE EL CANDIDATO, y por qué costó tanto:
--
--   EL PROBLEMA DE FONDO NO ES EL MATCHER. El catálogo de La Penda son 2,325
--   insumos de TIENDA —snacks, dulces empacados, bebidas de reventa— porque se
--   armó de las compras del food shop. La cocina compra por fuera del sistema.
--   Por eso «Queso», «Leche», «Mantequilla» o «Aceite de oliva» de cocina NO
--   EXISTEN como insumo: lo que existe son productos que se revenden y llevan
--   esas palabras en el nombre. Para los ingredientes de cocina que más pesan,
--   la respuesta correcta casi siempre es CREAR, no mapear.
--
--   El orden de candidatos aplica, en este orden:
--     1. nombre idéntico después de normalizar
--     2. el nombre del catálogo CONTIENE el ingrediente como PALABRA COMPLETA
--        (con \m..\M, no con LIKE: «%AGUA%» matchea «AGUACATE»)
--     3. lo que SE VENDE tal cual se va al fondo — un quipe, una empanada,
--        un mofongo, un BON BON o una PERONI no son materia prima. Las
--        empanadas y los quipes SE COMPRAN HECHOS: entran como producto
--        terminado y se venden sin receta, así que jamás son ingrediente.
--        Se detectan de TRES formas: `menu_items.inventory_item_id` apunta al
--        insumo; el insumo se LLAMA igual que un producto del menú; o el
--        nombre es de una clase que se compra hecha (empanada, quipe,
--        mofongo, croqueta) — esta última porque el nombre del insumo y el
--        del producto no siempre coinciden exacto.
--     4. entre los que quedan, el que SE COMPRA de verdad (y más veces)
--     5. y de últimos, el que menos le agrega al nombre, y el trigrama
--
--   Cada paso se agregó porque el anterior fallaba con un caso real:
--     solo trigrama      Pepperoni → PERONI (una CERVEZA)
--     + contiene         Mantequilla → MANTEQUILLA DE MANI
--     + compras          Queso → QUIPE DE QUESO DE CABRA
--                        Leche → FLAN DE LECHE PEQUEÑO EMPACADO
--     + reventa          Queso → QUESO MOZZARELLA RICA lb   ✔
--                        Leche → LECHE CARNETION            ✔
--
--   Aun así NADA se acepta solo. `semaforo` dice qué tan firme es:
--     OK        nombre idéntico
--     PROBABLE  el nombre lo contiene — hay que confirmar
--     OJO       solo parecido — casi siempre hay que corregirlo
--   Y `compras_1/2/3` dice de dónde sale cada candidato:
--     «N compras · últ. fecha»                 se compra de verdad
--     «NUNCA se ha comprado»                   casi nunca es el bueno
--     «SE VENDE tal cual — producto terminado»  se compra hecho, descartarlo
--
-- LAS COLUMNAS QUE LLENA LA COCINA:
--   decision      MAPEAR | CREAR | DESCARTAR | PREPARACION | PARTIR
--   insumo_final  si es MAPEAR: pegar el UUID de la columna del candidato
--                 bueno (uuid_1/2/3), o buscar otro
--   equivalencia  si la unidad no convierte: «1 unidad = 500 g»
--
-- CÓMO LEER `convierte`:
--   SI   la receta pide g y el insumo está en lb  → se convierte sola
--   NO   la receta pide g y el insumo está en «unidad» → hace falta la
--        equivalencia, o cambiarle la unidad base al insumo
-- =============================================================================

with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),

-- CUANTO SE COMPRA CADA INSUMO. Es el mejor desempate que hay: entre
-- «MANTEQUILLA DE MANI» y «MANTEQUILLA PEQUEÑA» no hay metrica de texto que
-- decida, pero la que la cocina usa de verdad se compra todas las semanas y
-- la otra no se compra nunca. Un insumo sin compras casi nunca es el bueno.
compras as (
  select im.item_id,
         count(*)                                   as veces,
         max(im.created_at)::date                   as ultima
    from public.inventory_movements im, biz
   where im.business_id = biz.id and im.movement_type = 'purchase'
   group by im.item_id
),

-- INSUMOS QUE SON PRODUCTO DE REVENTA. Si un menu_item apunta a ese insumo
-- con `inventory_item_id`, ese insumo SE VENDE tal cual: es un quipe, una
-- empanada, un BON BON, una PERONI. No es materia prima de cocina.
-- Es la senal que separa de verdad: el catalogo de La Penda es de TIENDA
-- (2,325 insumos de snacks y bebidas) y la cocina compra por fuera, asi que
-- casi todo lo que empareja por nombre con «Queso» o «Leche» es reventa.
reventa as (
  -- (a) el insumo esta ligado a un producto: ese producto lo vende tal cual
  select distinct m.inventory_item_id as item_id
    from public.menu_items m, biz
   where m.business_id = biz.id and m.inventory_item_id is not null
  union
  -- (b) el insumo SE LLAMA igual que un producto del menu. Es el caso de las
  --     empanadas, los quipes y los mofongos: se COMPRAN HECHOS, entran al
  --     inventario como producto terminado y se venden sin receta. Nunca son
  --     ingrediente de otra receta, aunque el nombre lleve «QUESO» o «POLLO».
  --     Sin esto, «Queso» proponia EMPANADA DE QUESO (10 compras) y
  --     «Masa de pizza» proponia EMPANADA DE PIZZA.
  select distinct i.id
    from public.inventory_items i
   cross join biz
   where i.business_id = biz.id
     and exists (
       select 1 from public.menu_items m
        where m.business_id = biz.id
          and public._norm(m.name) = public._norm(i.name))
  union
  -- (c) POR CLASE, dicho por el dueño (22-09): «los productos como empanadas y
  --     quipes no tienen recetarios porque se compran hechos». Entran al
  --     inventario ya hechos y se venden sin receta, asi que NUNCA son
  --     ingrediente de otra ficha. Se agregan mofongo y croqueta por la misma
  --     razon: son platos terminados, no materia prima.
  --     La regla (b) no los cazaba porque el producto del menu se llama
  --     parecido pero no idéntico («EMPANADA DE QUESO» el insumo contra
  --     «EMPANADAS DE QUESO» el producto), y por eso EMPANADA DE QUESO seguia
  --     saliendo como mejor candidato de «Queso» con 10 compras.
  select distinct i.id
    from public.inventory_items i
   cross join biz
   where i.business_id = biz.id
     and public._norm(i.name) ~ '\m(EMPANADA|EMPANADAS|QUIPE|QUIPES|MOFONGO|MOFONGOS|CROQUETA|CROQUETAS)\M'
),

ing as (
  select min(r.ingrediente)                   as ingrediente,
         public._norm(min(r.ingrediente))     as n,
         min(r.unidad)                        as u_receta,
         count(distinct r.codigo)             as fichas,
         string_agg(distinct r.producto, ' · ' order by r.producto) as en_que_platos
    from public._recetario_penda r
   group by public._norm(r.ingrediente)
),

clase as (
  select i.*,
         case
           when i.u_receta = 'c/n'                                  then 'DESCARTAR'
           when i.ingrediente ilike '%guarnic%'                     then 'DESCARTAR'
           when i.ingrediente ~* 'seg[uú]n receta|elegid|del d[ií]a|'
                                 'producto principal|sabor seg|'
                                 'syrup/topping|fruta o pulpa|'
                                 'pan seg[uú]n'                     then 'DESCARTAR'
           when i.ingrediente ~* '\my\M|\mo\M|/'                    then 'PARTIR'
           when i.ingrediente ~* 'sofrito|salsa penda|chimichurri|marinada|'
                                 'caldo|cocid|guisad|grillad|asado|confitad|'
                                 'espresso|base frappe|texturizada|espuma|'
                                 'empanizado|preparad|sazonad|crujiente|'
                                 'caramelizada|encurtida|frito|batida|'
                                 'sirope simple|syrup simple'       then 'PREPARACION'
           else 'BUSCAR'
         end as clase
    from ing i
),

-- los TRES mas parecidos, para poder comparar al revisar
cand as (
  select c.*, x.rn, x.id, x.name, x.unit, x.sim, x.porque, x.veces, x.ultima, x.reventa,
         public._penda_a_base(1, c.u_receta, x.id) is not null as convierte
    from clase c
    -- EL ORDEN NO ES POR TRIGRAMA SOLO. El trigrama mide letras compartidas y
    -- por eso pone «PERONI» (cerveza) antes que «Pepperoni Pedrollo». Aqui
    -- manda primero si el nombre del catalogo CONTIENE el ingrediente entero,
    -- y entre los que lo contienen gana el que menos le agrega. Con eso
    -- «Pepperoni Pedrollo» le pasa por delante a «PERONI», y
    -- «MANTEQUILLA PEQUEÑA» a «MANTEQUILLA DE MANI».
    left join lateral (
      select i.id, i.name, i.unit,
             coalesce(cp.veces, 0) as veces, cp.ultima,
             (rv.item_id is not null) as reventa,
             round(similarity(public._norm(i.name), c.n)::numeric, 2) as sim,
             case
               when public._norm(i.name) = c.n                    then 'exacto'
               when public._norm(i.name) ~ ('\m' || regexp_replace(c.n, '[^A-Z0-9 ]', '.', 'g') || '\M')   then 'lo contiene'
               else 'solo parecido'
             end as porque,
             row_number() over (
               order by
                 -- 1. exacto, 2. lo contiene, 3. solo parecido
                 case
                   when public._norm(i.name) = c.n                  then 0
                   when public._norm(i.name) ~ ('\m' || regexp_replace(c.n, '[^A-Z0-9 ]', '.', 'g') || '\M') then 1
                   else 2
                 end,
                 -- lo que se VENDE tal cual no es materia prima: al fondo.
                 (rv.item_id is not null),
                 -- luego, entre los que quedan, el que SE COMPRA.
                 (coalesce(cp.veces,0) = 0),
                 coalesce(cp.veces,0) desc,
                 -- y si los dos se compran, el que menos le agrega al nombre
                 length(public._norm(i.name)) - length(c.n),
                 -- y de ultimo el trigrama
                 similarity(public._norm(i.name), c.n) desc,
                 length(i.name)
             ) as rn
        from public.inventory_items i
        cross join biz
        left join compras cp on cp.item_id = i.id
        left join reventa rv on rv.item_id = i.id
       where i.business_id = biz.id and coalesce(i.is_active,true)
         and (similarity(public._norm(i.name), c.n) > 0.30
              or public._norm(i.name) ~ ('\m' || regexp_replace(c.n, '[^A-Z0-9 ]', '.', 'g') || '\M'))
       order by rn
       limit 3
    ) x on c.clase = 'BUSCAR'
),

plano as (
  select ingrediente, u_receta, fichas, clase, en_que_platos,
         max(sim) filter (where rn=1)        as sim_1,
         max(porque) filter (where rn=1)     as porque_1,
         max(name) filter (where rn=1)       as cand_1,
         max(unit) filter (where rn=1)       as u_1,
         max(veces) filter (where rn=1)      as veces_1,
         bool_or(reventa) filter (where rn=1) as rev_1,
         max(ultima::text) filter (where rn=1) as ult_1,
         max(id::text) filter (where rn=1)   as uuid_1,
         bool_or(convierte) filter (where rn=1) as conv_1,
         max(name) filter (where rn=2)       as cand_2,
         max(unit) filter (where rn=2)       as u_2,
         max(veces) filter (where rn=2)      as veces_2,
         bool_or(reventa) filter (where rn=2) as rev_2,
         max(ultima::text) filter (where rn=2) as ult_2,
         max(id::text) filter (where rn=2)   as uuid_2,
         max(name) filter (where rn=3)       as cand_3,
         max(unit) filter (where rn=3)       as u_3,
         max(veces) filter (where rn=3)      as veces_3,
         bool_or(reventa) filter (where rn=3) as rev_3,
         max(ultima::text) filter (where rn=3) as ult_3,
         max(id::text) filter (where rn=3)   as uuid_3
    from cand
   group by ingrediente, u_receta, fichas, clase, en_que_platos
)

select
  row_number() over (order by
      case clase when 'BUSCAR' then 1 when 'PREPARACION' then 2
                 when 'PARTIR' then 3 else 4 end,
      fichas desc, ingrediente)                                  as "#",
  ingrediente                                                    as "ingrediente_del_papel",
  u_receta                                                       as "pide",
  fichas                                                         as "fichas",
  case
    when clase <> 'BUSCAR'          then clase
    when porque_1 = 'exacto'        then 'MAPEAR (seguro)'
    when cand_1 is null             then 'CREAR'
    else 'REVISAR'
  end                                                            as "sugerencia",
  case
    when clase <> 'BUSCAR'          then ''
    when porque_1 = 'exacto'        then 'OK  nombre idéntico'
    when cand_1 is null             then 'no hay nada parecido'
    when porque_1 = 'lo contiene'   then 'PROBABLE  el nombre lo contiene — confirmar'
    else 'OJO  solo parecido ' || sim_1 || ' — confirmar que es el mismo'
  end                                                            as "semaforo",
  coalesce(cand_1,'')                                            as "candidato_1",
  coalesce(u_1,'')                                               as "unidad_1",
  case when cand_1 is null then ''
       when rev_1 then 'SE VENDE tal cual — producto terminado'
       when coalesce(veces_1,0) = 0 then 'NUNCA se ha comprado'
       else veces_1 || ' compras · últ. ' || ult_1
  end                                                            as "compras_1",
  case when cand_1 is null then ''
       when conv_1 then 'SI' else 'NO — falta equivalencia' end  as "convierte",
  coalesce(cand_2,'')                                            as "candidato_2",
  coalesce(u_2,'')                                               as "unidad_2",
  case when cand_2 is null then ''
       when rev_2 then 'SE VENDE tal cual — producto terminado'
       when coalesce(veces_2,0) = 0 then 'NUNCA se ha comprado'
       else veces_2 || ' compras · últ. ' || ult_2
  end                                                            as "compras_2",
  coalesce(cand_3,'')                                            as "candidato_3",
  coalesce(u_3,'')                                               as "unidad_3",
  case when cand_3 is null then ''
       when rev_3 then 'SE VENDE tal cual — producto terminado'
       when coalesce(veces_3,0) = 0 then 'NUNCA se ha comprado'
       else veces_3 || ' compras · últ. ' || ult_3
  end                                                            as "compras_3",
  ''                                                             as "DECISION_cocina",
  ''                                                             as "INSUMO_FINAL_uuid",
  ''                                                             as "EQUIVALENCIA",
  coalesce(uuid_1,'')                                            as "uuid_1",
  coalesce(uuid_2,'')                                            as "uuid_2",
  coalesce(uuid_3,'')                                            as "uuid_3",
  left(en_que_platos, 180)                                       as "en_que_platos"
from plano
order by 1;
