#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Import FINAL del catalogo de ECOBAR (business fc3065c8), con las decisiones
tomadas el 2026-09-05:

  1. PRECIOS: se convierten x1.18/1.28. El archivo trae la Ley 10% metida en
     la base; MangoPOS cobra ITBIS y Ley por fuera. Sin convertir, todo subia
     8.47%. Verificado en 103 de 135 pares: arch x1.18 == actual x1.28.
  2. DUPLICADOS: 120 productos del archivo YA existen con otro nombre
     ("BRUGAL LEYENDA BOT" vs "Brugal Leyenda (Botella)"). Se ACTUALIZAN,
     no se insertan. El mapeo esta en mapping.json (103 confirmados por el
     ratio de precio + 17 revisados a mano).
  3. ALCANCE: entran los 625 del archivo.

CANDADO ANTI-DUPLICADOS (triple):
  a. Solo se INSERTA un nombre que no exista en el catalogo NI este mapeado.
  b. De los nombres repetidos DENTRO del archivo solo entra uno; el resto se
     reporta sin tocar.
  c. Al final, un check cuenta nombres normalizados repetidos en TODO el
     negocio: si aparece uno solo, raise exception y la transaccion se
     revierte entera. Es imposible que commitee un duplicado.

Uso: python3 scripts/build_import_final_fc3065c8.py
"""
import csv, json, os, re, sys, unicodedata

BID = "fc3065c8-cb40-45ad-bec1-aecb388001c1"
TAXES = ("ITBIS", "LEY")
CSV = os.path.expanduser("~/Desktop/productos.csv")
MAPPING = "/tmp/eco/mapping.json"
EXCLUIR = "/tmp/eco/excluir.json"
HERE = os.path.dirname(os.path.abspath(__file__))
FACTOR = 1.18 / 1.28          # 0.847  -> el cliente paga lo mismo que hoy

NORM_SQL = ("upper(btrim(regexp_replace(translate({0}, "
            "'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', "
            "'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\\s+', ' ', 'g')))")


def strip_acc(s):
    return "".join(c for c in unicodedata.normalize("NFD", s)
                   if unicodedata.category(c) != "Mn")


def norm(s):
    return re.sub(r"\s+", " ", strip_acc(s).upper()).strip()


def q(s):
    return "NULL" if s is None or s == "" else "'" + str(s).replace("'", "''") + "'"


def num(x):
    return "NULL" if x is None else "%.2f" % float(x)


def _sufijo(cat):
    """Sufijo desambiguador tomado de la categoria del propio archivo."""
    if not cat:
        return ""
    c = cat.upper()
    if "(BOT X COPA)" in c: return "(BOTELLA POR COPA)"
    if "(COPA)" in c:       return "(COPA)"
    if "(TRA)" in c or c.endswith(" TRA"):  return "(TRAGO)"
    if "(BOT)" in c or c.endswith(" BOT"):  return "(BOTELLA)"
    return "(%s)" % cat


def main():
    mapping = json.load(open(MAPPING, encoding="utf-8"))   # sku -> nombre exacto en el catalogo
    excluir = json.load(open(EXCLUIR, encoding="utf-8"))   # sku -> motivo (filas repetidas en el origen)
    rows = list(csv.DictReader(open(CSV, encoding="utf-8-sig")))

    items, seen_new = [], {}
    for r in rows:
        sku = r["Codigo del Producto"].strip()
        name = unicodedata.normalize("NFC", r["Descripcion del Producto"].strip())
        cat = unicodedata.normalize("NFC", (r["Categoria"] or "").strip()) or None
        cost = float(r["Costo"] or 0)
        price = float(r["Precio"] or 0)
        if not sku or not name or sku in excluir:
            continue
        items.append({
            "sku": sku,
            "name": name,
            "cat": cat,
            "price": round(price * FACTOR, 2),      # <- conversion de base fiscal
            "price_raw": price,
            "cost": cost if cost > 0 else None,
            "target": mapping.get(sku),             # nombre en el catalogo, o None
            "k": norm(name),
        })

    cats = sorted({i["cat"] for i in items if i["cat"]})
    mapped = [i for i in items if i["target"]]
    unmapped = [i for i in items if not i["target"]]

    # Entre los NO mapeados, los nombres repetidos DENTRO del archivo son casi
    # siempre el mismo articulo en presentaciones distintas (botella / trago /
    # copa) que el POS viejo nombraba igual. Descartarlos perderia productos
    # reales, asi que se desambiguan con su propia categoria; si aun asi chocan,
    # con el sku. Se listan todos en el encabezado del SQL.
    by_k = {}
    for i in unmapped:
        by_k.setdefault(i["k"], []).append(i)
    dup_in_file = {k: v for k, v in by_k.items() if len(v) > 1}

    renombrados = []
    for k, grupo in sorted(dup_in_file.items()):
        for i in grupo:
            suf = _sufijo(i["cat"])
            i["name_final"] = "%s %s" % (i["name"], suf) if suf else i["name"]
        # si el sufijo de categoria no basta, desempatar con el sku
        vistos = {}
        for i in grupo:
            vistos.setdefault(norm(i["name_final"]), []).append(i)
        for kk, g2 in vistos.items():
            if len(g2) > 1:
                for i in g2:
                    i["name_final"] = "%s (%s)" % (i["name"], i["sku"])
        for i in grupo:
            renombrados.append((i["sku"], i["name"], i["cat"], i["name_final"]))

    for i in items:
        i.setdefault("name_final", i["name"])
        i["k_final"] = norm(i["name_final"])

    _write(items, cats, mapped, unmapped, dup_in_file, excluir, renombrados)

    print("archivo               : %d" % len(items), file=sys.stderr)
    print("mapeados (actualizan) : %d" % len(mapped), file=sys.stderr)
    print("resto                 : %d" % len(unmapped), file=sys.stderr)
    print("  nombres repetidos en el archivo: %d nombres, %d filas"
          % (len(dup_in_file), sum(len(v) for v in dup_in_file.values())), file=sys.stderr)
    print("categorias del archivo: %d" % len(cats), file=sys.stderr)


def _write(items, cats, mapped, unmapped, dup_in_file, excluir, renombrados):
    o = []
    w = o.append
    w("-- =============================================================================")
    w("-- IMPORT FINAL — ECOBAR AND LOUNGE (%s)" % BID)
    w("-- Genera: scripts/build_import_final_fc3065c8.py   (NO editar a mano)")
    w("--")
    w("--   %d filas del archivo (de 625; se excluyen %d repetidas en el origen)"
      % (len(items), len(excluir)))
    for _sku, _mot in sorted(excluir.items()):
        w("--     excluida %s: %s" % (_sku, _mot))
    w("--   %d categorias" % len(cats))
    if renombrados:
        w("--")
        w("--   %d filas se RENOMBRARON: el archivo las nombraba igual que a otra" % len(renombrados))
        w("--   (misma bebida en botella y en trago, mismo vino en botella y copa).")
        w("--   Se les anade la presentacion tomada de su propia categoria:")
        for _s, _n, _c, _nf in renombrados:
            w("--     %-8s %-42s -> %s" % (_s, _n[:42], _nf))
    w("--")
    w("-- PRECIOS CONVERTIDOS x1.18/1.28. El archivo trae la Ley 10%% dentro de la")
    w("-- base; MangoPOS la cobra por fuera. Sin convertir todo subia 8.47%%.")
    w("--   Trapiche Malbec: archivo 1627.12 -> se carga 1500.00 -> cliente paga 1920.")
    w("-- El COSTO no se convierte: es costo de compra, no lleva Ley.")
    w("--")
    w("-- ANTI-DUPLICADOS, tres candados:")
    w("--   1. %d productos del archivo YA existen con otro nombre y se ACTUALIZAN" % len(mapped))
    w("--      (se les graba el sku y el precio; se RESPETA el nombre y la categoria")
    w("--      que ya tienen en MangoPOS, que estan mejor escritos que los del POS viejo).")
    w("--   2. Solo se INSERTA un nombre que no exista ya en el catalogo.")
    w("--   3. Al final se cuentan nombres repetidos en TODO el negocio: si aparece")
    w("--      uno, raise exception y se revierte la transaccion completa.")
    w("--")
    w("-- Correr en Supabase Studio -> SQL Editor. Devuelve 3 resultados.")
    w("-- =============================================================================")
    w("")
    w("begin;")
    w("")
    w("-- 0) Guarda de impuestos ------------------------------------------------------")
    w("create temp table _tax_cfg (name text primary key) on commit drop;")
    w("insert into _tax_cfg (name) values %s;" % ", ".join("(%s)" % q(t) for t in TAXES))
    w("")
    w("do $$")
    w("declare v_missing text; v_have text;")
    w("begin")
    w("  if not exists (select 1 from public.businesses where id = '%s') then" % BID)
    w("    raise exception 'El negocio no existe';")
    w("  end if;")
    w("  select string_agg(cfg.name, ', ') into v_missing from _tax_cfg cfg")
    w("  where not exists (select 1 from public.taxes t")
    w("    where t.business_id = '%s' and upper(btrim(t.name)) = upper(btrim(cfg.name))" % BID)
    w("      and coalesce(t.is_active, true));")
    w("  if v_missing is not null then")
    w("    select string_agg(t.name, ', ') into v_have from public.taxes t")
    w("     where t.business_id = '%s' and coalesce(t.is_active, true);" % BID)
    w("    raise exception 'Faltan impuestos: %. Hay: %.', v_missing, coalesce(v_have,'(ninguno)');")
    w("  end if;")
    w("end $$;")
    w("")
    w("-- 1) El archivo ---------------------------------------------------------------")
    w("--    price ya viene CONVERTIDO. target = nombre del producto que ya existe")
    w("--    en MangoPOS al que corresponde (NULL = no existe alla).")
    w("create temp table _f (")
    w("  sku text primary key, name text, cat text, price numeric, cost numeric,")
    w("  target text, precio_original numeric")
    w(") on commit drop;")
    w("")
    w("insert into _f (sku, name, cat, price, cost, target, precio_original) values")
    w(",\n".join(
        "  (%s, %s, %s, %s, %s, %s, %s)" % (
            q(i["sku"]), q(i["name_final"]), q(i["cat"]), num(i["price"]),
            num(i["cost"]), q(i["target"]), num(i["price_raw"]))
        for i in items) + ";")
    w("")
    w("create temp table _fk on commit drop as")
    w("select f.*, %s as k from _f f;" % NORM_SQL.format("f.name"))
    w("create index on _fk (k);")
    w("")
    w("-- 2) El catalogo actual -------------------------------------------------------")
    w("create temp table _c on commit drop as")
    w("select mi.id, mi.name, %s as k from public.menu_items mi" % NORM_SQL.format("mi.name"))
    w("where mi.business_id = '%s';" % BID)
    w("create index on _c (k);")
    w("")
    w("-- 3) Resolucion: a que fila del catalogo va cada linea del archivo -------------")
    w("--    a) las mapeadas a mano, por nombre exacto del catalogo")
    w("--    b) las que coinciden por nombre normalizado, si es 1:1 sin ambiguedad")
    w("create temp table _res on commit drop as")
    w("select f.sku, c.id as item_id")
    w("from _fk f join _c c on c.k = %s" % NORM_SQL.format("f.target"))
    w("where f.target is not null")
    w("union")
    w("select f.sku, c.id")
    w("from _fk f join _c c on c.k = f.k")
    w("where f.target is null")
    w("  and (select count(*) from _fk f2 where f2.k = f.k and f2.target is null) = 1")
    w("  and (select count(*) from _c  c2 where c2.k = f.k) = 1;")
    w("")
    w("-- Un producto del catalogo no puede recibir dos lineas del archivo.")
    w("do $$")
    w("declare n int;")
    w("begin")
    w("  select count(*) into n from (select item_id from _res group by item_id having count(*) > 1) d;")
    w("  if n > 0 then raise exception 'ABORTA: % productos del catalogo recibirian 2 lineas del archivo', n; end if;")
    w("end $$;")
    w("")
    w("-- 4) Categorias del archivo que faltan ----------------------------------------")
    w("--    Solo se usan para los productos NUEVOS. Los que ya existen conservan")
    w("--    la categoria que tienen hoy en MangoPOS.")
    w("insert into public.categories (id, business_id, name, position, is_active)")
    w("select gen_random_uuid(), '%s', v.name, v.pos, true" % BID)
    w("from (values")
    w(",\n".join("  (%s, %d)" % (q(c), n) for n, c in enumerate(cats, start=1)))
    w(") as v(name, pos)")
    w("where exists (")
    w("  select 1 from _fk f where f.cat = v.name and not exists (select 1 from _res r where r.sku = f.sku)")
    w(")")
    w("and not exists (select 1 from public.categories c")
    w("               where c.business_id = '%s' and c.name = v.name);" % BID)
    w("")
    w("-- 5) ACTUALIZA los que ya existen ---------------------------------------------")
    w("--    Se graba sku, precio (convertido) y costo. NO se toca el nombre ni la")
    w("--    categoria: los de MangoPOS estan mejor escritos que los del POS viejo.")
    w("update public.menu_items mi")
    w("set sku        = f.sku,")
    w("    price      = f.price,")
    w("    cost       = coalesce(f.cost, mi.cost),")
    w("    tax_mode   = 'exclusive',")
    w("    is_active  = true,")
    w("    updated_at = now()")
    w("from _res r join _fk f on f.sku = r.sku")
    w("where mi.id = r.item_id;")
    w("")
    w("-- 6) INSERTA los nuevos --------------------------------------------------------")
    w("--    Candado: solo si el nombre NO existe en el catalogo. Y de los nombres")
    w("--    repetidos dentro del propio archivo entra uno solo (el de sku menor).")
    w("insert into public.menu_items")
    w("  (business_id, category_id, name, price, cost, tax_mode, sku, is_active)")
    w("select '%s', c.id, f.name, f.price, f.cost, 'exclusive', f.sku, true" % BID)
    w("from _fk f")
    w("left join lateral (")
    w("  select c2.id from public.categories c2")
    w("  where c2.business_id = '%s' and c2.name = f.cat" % BID)
    w("  order by c2.created_at asc limit 1")
    w(") c on true")
    w("where not exists (select 1 from _res r where r.sku = f.sku)")
    w("  and not exists (select 1 from _c  x where x.k = f.k)")
    w("  and f.sku = (select min(f2.sku) from _fk f2")
    w("               where f2.k = f.k and not exists (select 1 from _res r2 where r2.sku = f2.sku));")
    w("")
    w("")
    w("-- 7) CANDADO FINAL -------------------------------------------------------------")
    w("--    Si quedo UN solo nombre repetido en el negocio, revierte todo.")
    w("do $$")
    w("declare n int; ejemplos text;")
    w("begin")
    w("  select count(*), string_agg(d.nombre, ' | ')")
    w("    into n, ejemplos")
    w("  from (")
    w("    select %s as nombre" % NORM_SQL.format("mi.name"))
    w("    from public.menu_items mi")
    w("    where mi.business_id = '%s'" % BID)
    w("    group by 1 having count(*) > 1")
    w("  ) d;")
    w("  if n > 0 then")
    w("    raise exception 'ABORTA: quedarian % nombres duplicados: %', n, left(coalesce(ejemplos,''), 400);")
    w("  end if;")
    w("end $$;")
    w("")
    w("-- 8) Impuestos ITBIS + LEY a todo el archivo ----------------------------------")
    w("insert into public.menu_item_taxes (item_id, tax_id)")
    w("select mi.id, tt.id")
    w("from public.menu_items mi")
    w("join _fk f on f.sku = mi.sku")
    w("cross join _tax_cfg cfg")
    w("join lateral (")
    w("  select t.id from public.taxes t")
    w("  where t.business_id = mi.business_id")
    w("    and upper(btrim(t.name)) = upper(btrim(cfg.name))")
    w("    and coalesce(t.is_active, true)")
    w("  order by t.created_at asc limit 1")
    w(") tt on true")
    w("where mi.business_id = '%s'" % BID)
    w("  and not exists (select 1 from public.menu_item_taxes x")
    w("                  where x.item_id = mi.id and x.tax_id = tt.id);")
    w("")
    w("-- 9) Menu ----------------------------------------------------------------------")
    w("insert into public.menu_item_links (menu_id, item_id, position)")
    w("select m.id, mi.id, row_number() over (order by mi.name)")
    w("from public.menu_items mi")
    w("join _fk f on f.sku = mi.sku")
    w("join lateral (select m2.id from public.menus m2")
    w("              where m2.business_id = mi.business_id and coalesce(m2.is_active, true)")
    w("              order by m2.created_at asc limit 1) m on true")
    w("where mi.business_id = '%s'" % BID)
    w("  and not exists (select 1 from public.menu_item_links l")
    w("                  where l.item_id = mi.id and l.menu_id = m.id);")
    w("")
    w("-- 10) Control ------------------------------------------------------------------")
    w("select")
    w("  (select count(*) from _fk)  as en_archivo,")
    w("  (select count(*) from _res) as actualizados,")
    w("  (select count(*) from _fk f where not exists (select 1 from _res r where r.sku = f.sku)")
    w("     and not exists (select 1 from _c x where x.k = f.k)) as candidatos_nuevos,")
    w("  (select count(*) from public.menu_items where business_id = '%s') as total_catalogo," % BID)
    w("  (select count(*) from public.categories where business_id = '%s') as categorias," % BID)
    w("  (select count(*) from public.menu_items mi join _fk f on f.sku = mi.sku")
    w("     where mi.business_id = '%s'" % BID)
    w("       and not exists (select 1 from public.menu_item_taxes x where x.item_id = mi.id)) as sin_impuesto,")
    w("  0 as duplicados;   -- el paso 7 aborta si hubiera alguno")
    w("")
    w("-- 11) Lineas del archivo que NO entraron (nombre repetido dentro del archivo) --")
    w("--     Ponles un nombre distinto en el CSV y vuelve a correr, o cargalas a mano.")
    w("select f.sku, f.name, f.cat, f.price, f.precio_original,")
    w("       'nombre repetido en el archivo' as motivo")
    w("from _fk f")
    w("where not exists (select 1 from _res r where r.sku = f.sku)")
    w("  and not exists (select 1 from public.menu_items mi")
    w("                  where mi.business_id = '%s' and mi.sku = f.sku)" % BID)
    w("order by f.name, f.sku;")
    w("")
    w("commit;")
    w("")
    path = os.path.join(HERE, "IMPORT_FINAL_fc3065c8.sql")
    open(path, "w", encoding="utf-8").write("\n".join(o))
    print("escrito: %s" % path, file=sys.stderr)


if __name__ == "__main__":
    main()
