-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 5: qué crear y qué mapear
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. UNA sola consulta. REQUIERE el PASO 6 (tabla _recetario_penda).
--
-- POR QUÉ HACE FALTA ESTE PASO:
--   El OP 4 empareja por nombre EXACTO (normalizado) y dio «212 no existen».
--   Ese número no es real: el papel dice «Queso» y el catálogo tiene «QUESO
--   MOZZARELLA RICA lb»; el papel dice «Limon» y el catálogo «LIMONES
--   FRESCOS». Crear 212 insumos así duplicaría medio catálogo.
--
--   Aquí cada ingrediente se clasifica y, si parece existir con otro nombre,
--   se busca el candidato más parecido con trigramas.
--
-- LAS CINCO CLASES:
--   DESCARTAR    no se descuenta: «c/n» (sal, hielo, aceite de freír), la
--                guarnición (es un modificador) y los genéricos del papel
--                («Producto principal», «Sabor segun receta»).
--   COMBINADO    una línea con varios insumos: «Lechuga y tomate», «Jamon y
--                salami». Hay que partirla en dos líneas antes de cargar.
--   PREPARACION  no se compra, se hace en casa: sofrito, caldo, espresso,
--                arroz cocido, salsa Penda. Estos llevan SU PROPIA receta
--                (sub-receta), no son un insumo de compra.
--   ¿YA EXISTE?  hay un insumo parecido en el catálogo → revisar y mapear.
--   CREAR        no aparece nada parecido → crear el insumo.
--
-- La columna `valor` de «¿YA EXISTE?» trae el candidato y su parecido (0-1).
-- Por encima de 0.60 casi siempre es el mismo; entre 0.45 y 0.60 hay que
-- mirarlo. Nada se decide solo: esto es para que la cocina lo revise.
-- =============================================================================

with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),

ing as (
  select min(r.ingrediente)        as ingrediente,
         public._norm(min(r.ingrediente)) as n,
         min(r.unidad)             as u_receta,
         count(distinct r.codigo)  as fichas
    from public._recetario_penda r
   group by public._norm(r.ingrediente)
),

clasificado as (
  select i.*,
         case
           -- sin cantidad utilizable, o es un modificador, o es un hueco
           when i.u_receta = 'c/n'                                  then 'DESCARTAR'
           when i.ingrediente ilike '%guarnic%'                     then 'DESCARTAR'
           when i.ingrediente ~* 'seg[uú]n receta|elegid|del d[ií]a|'
                                 'producto principal|sabor seg|'
                                 'syrup/topping|fruta o pulpa|'
                                 'pan seg[uú]n'                     then 'DESCARTAR'
           -- varios insumos en una sola linea
           when i.ingrediente ~* '\my\M|\mo\M|/'                    then 'COMBINADO'
           -- no se compra: se hace en casa
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

-- candidato mas parecido del catalogo vivo
match as (
  select c.*,
         x.name  as candidato,
         x.unit  as u_candidato,
         x.sim
    from clasificado c
    left join lateral (
      select i.name, i.unit,
             round(similarity(public._norm(i.name), c.n)::numeric, 2) as sim
        from public.inventory_items i, biz
       where i.business_id = biz.id and coalesce(i.is_active,true)
         and similarity(public._norm(i.name), c.n) > 0.30
       order by similarity(public._norm(i.name), c.n) desc, length(i.name)
       limit 1
    ) x on c.clase = 'BUSCAR'
),

final as (
  select m.*,
         case
           when m.clase <> 'BUSCAR'          then m.clase
           when m.candidato is null          then 'CREAR'
           when m.sim >= 0.45                then '¿YA EXISTE?'
           else 'CREAR'
         end as veredicto
    from match m
),

f1 as (
  select 1 as orden, 'F1 resumen' as seccion,
         veredicto as dato,
         count(*)::text || ' ingredientes · ' ||
         sum(fichas)::text || ' apariciones en fichas' as valor
    from final group by veredicto
),
f2 as (
  select case veredicto when 'CREAR' then 2 when '¿YA EXISTE?' then 3
                        when 'PREPARACION' then 4 when 'COMBINADO' then 5
                        else 6 end,
         'F2 ' || veredicto, ingrediente,
         'pide ' || u_receta || ' · ' || fichas || ' ficha(s)' ||
         case when candidato is not null and veredicto = '¿YA EXISTE?'
              then '  →  ' || candidato || ' (' || u_candidato || ', parecido ' || sim || ')'
              when candidato is not null
              then '  [lo más parecido: ' || candidato || ' ' || sim || ']'
              else '' end
    from final
)

select seccion, dato, valor from (
  select * from f1 union all select * from f2
) todo
order by orden, dato;
