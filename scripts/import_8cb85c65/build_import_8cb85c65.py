#!/usr/bin/env python3
# Arma los .sql de la carga del menú de EL RINCÓN DE ADDA a partir de
# catalogo.py y de las plantillas _tpl_*.sql. Para cambiar un precio, una
# categoría, un nombre o un modificador: edita catalogo.py y vuelve a correr
# esto. No edites los .sql.

import csv
import os
import unicodedata
from collections import Counter

from catalogo import CATEGORIAS, GRUPOS, productos

HERE = os.path.dirname(os.path.abspath(__file__))


def q(s):
    return "'" + s.replace("'", "''") + "'"


def norm(s):
    s = ' '.join(s.lower().split())
    return ''.join(c for c in unicodedata.normalize('NFD', s)
                   if unicodedata.category(c) != 'Mn')


def revisar(ps):
    # Ningún nombre (ni nombre impreso usado para emparejar) puede caer en
    # dos productos: el import abortaría.
    dueno = {}
    for p in ps:
        for k in {norm(p['name']), norm(p['alias'])}:
            assert k not in dueno, f'«{k}» es de {dueno[k]} y de {p["name"]}'
            dueno[k] = p['name']
    for g, _, ops in GRUPOS:
        c = Counter(norm(o[0]) for o in ops)
        assert max(c.values()) == 1, f'opción repetida en {g}'
    c = Counter(norm(g[0]) for g in GRUPOS)
    assert max(c.values()) == 1, 'grupo repetido'


def lista_diagnostico(ps):
    return ',\n'.join(f'    ({q(p["name"])}, {q(p["alias"])})' for p in ps)


def lista_categorias():
    return ',\n'.join(f'  ({q(n)}, {pos}, {q(area)})' for n, pos, area in CATEGORIAS)


def lista_productos(ps):
    filas = []
    for p in ps:
        desc = q(p['desc']) if p['desc'] else 'null'
        filas.append(f'  ({q(p["name"])}, {q(p["alias"])}, {q(p["categoria"])}, '
                     f'{p["price"]:.2f}, {desc}, {p["posicion"]})')
    return ',\n'.join(filas)


def lista_grupos():
    return ',\n'.join(f'  ({q(n)}, {q(t)}, {i})' for i, (n, t, _) in enumerate(GRUPOS, 1))


def lista_opciones():
    filas = []
    for g, _, ops in GRUPOS:
        for i, (n, d) in enumerate(ops, 1):
            filas.append(f'  ({q(g)}, {q(n)}, {d:.2f}, {i})')
    return ',\n'.join(filas)


def lista_asignaciones(ps):
    filas = []
    for p in ps:
        for i, g in enumerate(p['grupos'], 1):
            filas.append(f'  ({q(p["name"])}, {q(g)}, {i})')
    return ',\n'.join(filas)


def resumen(ps):
    por_cat = Counter(p['categoria'] for p in ps)
    cocina = sum(1 for p in ps if p['area'] == 'cocina')
    lineas = [f'--   {len(ps)} productos en {len(CATEGORIAS)} categorías: {cocina} de comida '
              f'(van a la COCINA) y {len(ps) - cocina} bebidas (van al BAR).',
              f'--   {len(GRUPOS)} grupos de modificadores, enlazados '
              f'{sum(len(p["grupos"]) for p in ps)} veces.']
    for n, _, area in CATEGORIAS:
        lineas.append(f'--     {n:<22} {por_cat[n]:>3}  → {area}')
    return '\n'.join(lineas)


def render(tpl, out, marcas):
    txt = open(os.path.join(HERE, tpl), encoding='utf-8').read()
    for marca, valor in marcas.items():
        linea = f'--@@{marca}@@'
        assert txt.count(linea) == 1, (tpl, marca)
        txt = txt.replace(linea, valor)
    assert '--@@' not in txt, (tpl, 'marca sin reemplazar')
    open(os.path.join(HERE, out), 'w', encoding='utf-8').write(txt)


def revision_csv(ps):
    with open(os.path.join(HERE, 'catalogo_revision.csv'), 'w', newline='',
              encoding='utf-8') as f:
        w = csv.writer(f)
        w.writerow(['categoria', 'area', 'nombre_caja', 'nombre_carta', 'precio',
                    'modificadores', 'descripcion', 'duda'])
        for p in ps:
            w.writerow([p['categoria'], p['area'], p['name'], p['impreso'],
                        f'{p["price"]:.2f}', ' + '.join(p['grupos']), p['desc'], p['duda']])


if __name__ == '__main__':
    ps = productos()
    revisar(ps)
    render('_tpl_diagnostico.sql', '00_diagnostico.sql', {'LISTA': lista_diagnostico(ps)})
    render('_tpl_import.sql', 'IMPORT_COMPLETO.sql', {
        'RESUMEN': resumen(ps),
        'CATEGORIAS': lista_categorias(),
        'PRODUCTOS': lista_productos(ps),
        'GRUPOS': lista_grupos(),
        'OPCIONES': lista_opciones(),
        'ASIGNACIONES': lista_asignaciones(ps),
    })
    render('_tpl_rollback.sql', '99_rollback.sql', {
        'NOMBRES': ',\n'.join('    ' + q(p['name']) for p in ps if not p['existente']),
        'NOMBRES_GRUPOS': ',\n'.join('    ' + q(g[0]) for g in GRUPOS),
        'NOMBRES_CATEGORIAS': ',\n'.join('    ' + q(c[0]) for c in CATEGORIAS),
    })
    revision_csv(ps)
    print(f'ok: {len(ps)} productos, {len(GRUPOS)} grupos → 00_diagnostico.sql, '
          f'IMPORT_COMPLETO.sql, 99_rollback.sql, catalogo_revision.csv')
