#!/usr/bin/env python3
# Arma los .sql de la carga del negocio b0bd6f20 a partir de catalogo.py y de
# las plantillas _tpl_*.sql. Para cambiar un precio, un nombre o una
# categoría: edita catalogo.py y vuelve a correr esto. No edites los .sql.

import csv
import json
import os

from catalogo import (BEBIDAS, CATEGORIAS, DELIVERY_PRESETS, GRUPO_EXTRAS,
                      GRUPOS_PREEXISTENTES, LEY_ORIGEN, _llave, armar)

HERE = os.path.dirname(os.path.abspath(__file__))


def q(s):
    return 'null' if s is None else "'" + s.replace("'", "''") + "'"


def claves_diagnostico(productos, extras, omitidas):
    """clave normalizada → (destino, producto). Si una clave cae en varias
    cosas, gana el producto cuyo nombre ES esa clave, y un producto le gana a
    una fila omitida."""
    cand = {}

    def add(k, destino, producto, peso):
        cand.setdefault(_llave(k), []).append((peso, destino, producto))

    for p in productos:
        if p['grupo']:
            for k in p['claves']:
                add(k, f'{p["name"]} (con modificador {p["grupo"]})', p['name'], 3)
            for o in p['opciones']:
                for k in o['claves']:
                    add(k, f'{p["name"]} · opción {o["name"]}', p['name'], 1)
        else:
            for k in p['claves']:
                add(k, f'{p["name"]} ({p["categoria"]}, ${p["price"]:g})', p['name'],
                    3 if _llave(k) == _llave(p['name']) else 2)
    for e in extras:
        for k in e['claves']:
            add(k, f'grupo {GRUPO_EXTRAS} · {e["name"]} +{e["delta"]:g}', None, 2)
    for o in omitidas:
        for k in o['claves']:
            add(k, f'NO SE CARGA (fila {o["code"]}: {o["motivo"]})', None, 0)

    out = []
    for k, cs in sorted(cand.items()):
        top = max(c[0] for c in cs)
        ganan = sorted({(d, p) for w, d, p in cs if w == top}, key=lambda x: x[0])
        for d, p in ganan:
            out.append((k, d, p))
    return out


def lista_diagnostico(productos, extras, omitidas):
    return ',\n'.join(f'    ({q(k)}, {q(d)}, {q(p)})'
                      for k, d, p in claves_diagnostico(productos, extras, omitidas))


def filas(rows):
    return ',\n'.join('  (' + ', '.join(r) + ')' for r in rows)


def n(x):
    return f'{x:.2f}'


def b(x):
    return 'true' if x else 'false'


def marcas_import(productos, extras, existentes):
    orden = {c[0]: c[1] for c in CATEGORIAS}
    ps = sorted(productos, key=lambda p: (orden[p['categoria']], p['posicion']))
    config = filas([[q(LEY_ORIGEN), q(json.dumps(DELIVERY_PRESETS)) + '::jsonb']])
    cats = filas([q(c), str(pos), q(a), b(c in BEBIDAS)] for c, pos, a in CATEGORIAS)
    prods = filas([q(p['name']), q(p['categoria']), q(p['area']), n(p['price']),
                   q(p['description']), q(p['grupo']), str(p['posicion']), q(p['impuestos'])]
                  for p in ps)
    claves = filas([q(p['name']), q(k)] for p in ps for k in p['claves'])
    prod_k = {k for p in ps for k in p['claves']}
    otras = {}
    for p in ps:
        for o in p['opciones']:
            for k in o['claves']:
                otras.setdefault(_llave(k), f'opción {o["name"]} de {p["grupo"]}')
    for e in extras:
        for k in e['claves']:
            otras.setdefault(_llave(k), f'opción {e["name"]} de {GRUPO_EXTRAS}')
    otras = filas([q(k), q(v)] for k, v in sorted(otras.items()) if k not in prod_k)
    opciones = filas([q(p['grupo']), q(o['name']), n(o['delta']), str(o['orden'])]
                     for p in ps for o in p['opciones'])
    ex = filas([q(e['name']), n(e['delta']), str(e['orden'])] for e in extras)
    exis = filas([q(e['existente']), q(e['accion']), q(e.get('producto')), q(e.get('area')),
                  b(e['extras']) if 'extras' in e else 'null', q(e.get('impuestos')),
                  n(e['precio_antes']) if e.get('precio_antes') is not None else 'null']
                 for e in existentes)

    nuevos = [p for p in ps if not p['existente']]
    por_area = {}
    for p in ps:
        por_area.setdefault(p['area'], []).append(p)
    cuenta = lambda a: sum(1 for e in existentes if e['accion'] == a)
    resumen = [
        f'--   {len(ps)} productos de la lista ({len(nuevos)} nuevos + {len(ps) - len(nuevos)} que ya '
        f'estaban subidos): {len(por_area.get("cocina", []))}',
        f'--   a la COCINA y {len(por_area.get("bar", []))} al BAR. '
        f'{sum(1 for p in ps if p["grupo"])} con modificador obligatorio y el grupo',
        f'--   opcional "{GRUPO_EXTRAS}" con {len(extras)} opciones.',
        f'--   De lo que ya estaba: {cuenta("ya_subido")} son de la lista, {cuenta("fuera_csv")} no están en el CSV',
        f'--   (se quedan), {cuenta("desactivar")} se desactivan (DELIVERY y extras sueltos) y '
        f'{cuenta("mantener")} no se toca.',
        '--   Crea la Ley 10% (copia de Ágora) y las áreas Cocina y Bar.',
        '--   No se cargan: 4 filas repetidas y los 8 "Delivery 100 … 450".',
        '--   Sin costo (el CSV lo trae en 0), sin insumos ni existencias.',
    ]
    return {
        'RESUMEN': '\n'.join(resumen), 'CONFIG': config, 'CATEGORIAS': cats,
        'PRODUCTOS': prods, 'CLAVES': claves, 'OTRAS': otras, 'OPCIONES': opciones,
        'EXTRAS': ex, 'EXISTENTES': exis,
    }


def marcas_rollback(productos, existentes):
    grupos = [p['grupo'] for p in productos if p['grupo']] + [GRUPO_EXTRAS]
    grupos = [g for g in grupos if _llave(g) not in {_llave(x) for x in GRUPOS_PREEXISTENTES}]
    exis = ('insert into _b0_rb_existentes (existente, accion, precio_antes) values\n'
            + filas([q(e['existente']), q(e['accion']),
                     n(e['precio_antes']) if e.get('precio_antes') is not None else 'null']
                    for e in existentes) + ';')
    # Solo las categorías que la carga crea (las 7 primeras ya existían).
    nuevas = [c[0] for c in CATEGORIAS[7:]]
    return {
        'PRODUCTOS': filas([q(p['name'])] for p in productos if not p['existente']),
        'GRUPOS': filas([q(g)] for g in grupos),
        'CATEGORIAS': filas([q(c)] for c in nuevas),
        'EXISTENTES': exis,
    }


def render(tpl, out, marcas):
    txt = open(os.path.join(HERE, tpl), encoding='utf-8').read()
    for marca, valor in marcas.items():
        linea = f'--@@{marca}@@'
        assert txt.count(linea) == 1, (tpl, marca)
        txt = txt.replace(linea, valor)
    open(os.path.join(HERE, out), 'w', encoding='utf-8').write(txt)


def revision_csv(productos, extras, omitidas, existentes):
    antes = {e['existente']: e.get('precio_antes') for e in existentes}

    def ya(p):
        if not p['existente']:
            return 'nuevo'
        a = antes[p['existente']]
        cambio = '' if a == p['price'] else f', antes ${a:g}'
        return f'ya subido como "{p["existente"]}"{cambio}'

    with open(os.path.join(HERE, 'catalogo_revision.csv'), 'w', newline='',
              encoding='utf-8') as f:
        w = csv.writer(f)
        w.writerow(['filas_csv', 'que_es', 'en_la_caja', 'categoria', 'area', 'nombre',
                    'precio', 'modificador', 'opcion', 'precio_opcion', 'nota'])
        orden = {c[0]: c[1] for c in CATEGORIAS}
        for p in sorted(productos, key=lambda p: (orden[p['categoria']], p['posicion'])):
            nombre = p['existente'] or p['name']
            nota_imp = 'solo Ley (sin ITBIS)' if p['impuestos'] == 'ley' else ''
            if p['grupo']:
                for o in p['opciones']:
                    w.writerow([o['code'], 'producto con modificador', ya(p), p['categoria'],
                                p['area'], nombre, f'{p["price"]:.2f}', p['grupo'],
                                o['name'], f'{o["delta"]:.2f}', o['nota']])
            else:
                w.writerow([p['code'], 'producto', ya(p), p['categoria'], p['area'], nombre,
                            f'{p["price"]:.2f}', '', '', '',
                            '; '.join(x for x in (p['description'] and
                                                  f'descripción: {p["description"]}',
                                                  p['nota'], nota_imp) if x)])
        for e in extras:
            w.writerow([e['code'], 'opción de Extras', '', '', 'cocina', '', '', GRUPO_EXTRAS,
                        e['name'], f'{e["delta"]:.2f}',
                        'grupo opcional en los productos de cocina'
                        + ('' if e['code'] != '—' else '; no está en el CSV, lo subió el usuario')])
        for o in omitidas:
            w.writerow([o['code'], 'NO SE CARGA', '', '', '', o['producto_csv'],
                        f'{o["precio"]:.2f}', '', '', '', o['motivo']])
        textos = {'fuera_csv': 'no está en el CSV: se queda',
                  'desactivar': 'se DESACTIVA', 'mantener': 'no se toca'}
        for e in existentes:
            if e['accion'] == 'ya_subido':
                continue
            nota = textos[e['accion']]
            if e['accion'] == 'fuera_csv':
                nota += (f'; área {e["area"]}; impuestos {e["impuestos"]}'
                         + ('; con Extras' if e['extras'] else ''))
            w.writerow(['', 'ya estaba en la caja', e['existente'], '', e.get('area') or '',
                        e['existente'], '', '', '', '', nota])


if __name__ == '__main__':
    productos, extras, omitidas, existentes = armar()
    render('_tpl_diagnostico.sql', '00_diagnostico.sql',
           {'LISTA': lista_diagnostico(productos, extras, omitidas)})
    render('_tpl_import.sql', 'IMPORT_COMPLETO.sql', marcas_import(productos, extras, existentes))
    render('_tpl_rollback.sql', '99_rollback.sql', marcas_rollback(productos, existentes))
    revision_csv(productos, extras, omitidas, existentes)
    print(f'ok: {len(productos)} productos ({sum(1 for p in productos if p["grupo"])} con '
          f'modificador), {len(extras)} extras, {len(omitidas)} omitidas → '
          f'00_diagnostico.sql, IMPORT_COMPLETO.sql, 99_rollback.sql, catalogo_revision.csv')
