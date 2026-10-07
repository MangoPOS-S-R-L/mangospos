#!/usr/bin/env python3
# Arma los .sql de la carga de CAFETERIA MARICELA a partir de catalogo.py y
# de las plantillas _tpl_*.sql. Para cambiar un precio, una categoría o un
# nombre: edita catalogo.py y vuelve a correr esto. No edites los .sql.

import csv
import os

from catalogo import CATEGORIAS, productos

HERE = os.path.dirname(os.path.abspath(__file__))


def q(s):
    return "'" + s.replace("'", "''") + "'"


def lista_diagnostico(ps):
    filas = [f'    ({q(p["code"])}, {q(p["name"])}, {q(p["nombre_pdf"])})' for p in ps]
    return ',\n'.join(filas)


def lista_categorias():
    return ',\n'.join(f'  ({q(n)}, {pos}, {q(area)})' for n, pos, area in CATEGORIAS)


def lista_productos(ps):
    orden = {c[0]: c[1] for c in CATEGORIAS}
    filas = []
    for p in sorted(ps, key=lambda p: (orden[p['categoria']], p['posicion'])):
        filas.append(f'  ({q(p["code"])}, {q(p["name"])}, {q(p["nombre_pdf"])}, '
                     f'{q(p["categoria"])}, {p["price"]:.2f}, {p["cost"]:.2f}, {p["posicion"]})')
    return ',\n'.join(filas)


def render(tpl, out, marcas):
    txt = open(os.path.join(HERE, tpl), encoding='utf-8').read()
    for marca, valor in marcas.items():
        linea = f'--@@{marca}@@'
        assert txt.count(linea) == 1, (tpl, marca)
        txt = txt.replace(linea, valor)
    open(os.path.join(HERE, out), 'w', encoding='utf-8').write(txt)


def revision_csv(ps):
    with open(os.path.join(HERE, 'catalogo_revision.csv'), 'w', newline='',
              encoding='utf-8') as f:
        w = csv.writer(f)
        w.writerow(['codigo', 'nombre_pdf', 'nombre_caja', 'categoria', 'area',
                    'precio_pdf', 'precio_caja', 'nota_precio', 'costo', 'existencia_pdf'])
        for p in ps:
            nota = p['dudoso'] or ('neto del PDF subido al final' if p['precio_si_neto'] else '')
            w.writerow([p['code'], p['nombre_pdf'], p['name'], p['categoria'], p['area'],
                        f'{p["precio_pdf"]:.2f}', f'{p["price"]:.2f}', nota,
                        f'{p["cost"]:.2f}', f'{p["exist"]:g}'])


if __name__ == '__main__':
    ps = productos()
    render('_tpl_diagnostico.sql', '00_diagnostico.sql', {'LISTA': lista_diagnostico(ps)})
    render('_tpl_import.sql', 'IMPORT_COMPLETO.sql', {
        'CATEGORIAS': lista_categorias(),
        'PRODUCTOS': lista_productos(ps),
    })
    render('_tpl_rollback.sql', '99_rollback.sql', {
        'CODIGOS': ',\n'.join('    ' + q(p['code']) for p in ps),
        'NOMBRES_CATEGORIAS': ',\n'.join('    ' + q(c[0]) for c in CATEGORIAS),
    })
    revision_csv(ps)
    print(f'ok: {len(ps)} productos → 00_diagnostico.sql, IMPORT_COMPLETO.sql, '
          f'99_rollback.sql, catalogo_revision.csv')
