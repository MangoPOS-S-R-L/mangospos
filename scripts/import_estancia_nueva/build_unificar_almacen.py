#!/usr/bin/env python3
"""Unificar el inventario de la CAFETERÍA de Estancia Nueva en UNA bodega.

Lee inventario_estancia_nueva_2026-10-01.json (conteo del 01-oct: cafetería
del Excel + almacén del conteo PC-2026-000004) y genera:

  UNIF_0_diagnostico.sql  solo lee, UNA consulta (correr primero)
  UNIF_1_aplicar.sql      bodega única + existencia = contado − lo movido después
  UNIF_9_deshacer.sql     movimientos inversos + bodegas como estaban

Solo entran las líneas CON código que no son de la tienda deportiva (la
tienda es otro negocio, 40b0fa9d). Las 64 líneas «CREAR» no tienen código:
quedan fuera hasta que existan en el sistema.

Solo stdlib.  Uso:  python3 build_unificar_almacen.py [--out carpeta]
"""
import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'inventario_estancia_nueva_2026-10-01.json')
BUSINESS = '85924083-2e8e-4e64-8192-808ee24674ed'
PC_CORTE = 'PC-2026-000004'          # conteo del almacén (sus ajustes los reemplaza el JSON)
PC_ABANDONADO = 'PC-2026-000002'     # conteo de cafetería abandonado el 01-oct: se cancela
# Desde aquí se descuentan las ventas. El dueño (13-oct): la cafetería se contó
# en la mañana, antes de abrir; en la app se empezó a contar a las 11:55 y la
# primera venta fue 12:58.
CORTE = '2026-10-01 11:55:00-04'
NOMBRE_PRINCIPAL = 'Almacén Principal'
TIENDA = 'Tienda deportiva'
SALIDAS = {
    '_tpl_unif_0_diagnostico.sql': 'UNIF_0_diagnostico.sql',
    '_tpl_unif_1_aplicar.sql': 'UNIF_1_aplicar.sql',
    '_tpl_unif_9_deshacer.sql': 'UNIF_9_deshacer.sql',
}


def q(s):
    return "'" + str(s).replace("'", "''") + "'"


def num(x):
    x = float(x or 0)
    return str(int(x)) if x == int(x) else repr(x)


def lineas_cafeteria(items):
    filas = []
    for it in items:
        codigo = (it.get('codigo') or '').strip()
        if not codigo or TIENDA in (it.get('areas') or []):
            continue
        caf = float(it.get('cantidad_cafeteria') or 0)
        alm = float(it.get('cantidad_almacen') or 0)
        total = float(it.get('cantidad_total') or 0)
        assert abs(caf + alm - total) < 1e-9, f'{codigo}: {caf} + {alm} != {total}'
        assert total >= 0, f'{codigo}: total negativo'
        filas.append((codigo, it['descripcion'].strip(), caf, alm, total))
    codigos = [f[0] for f in filas]
    assert len(codigos) == len(set(codigos)), 'códigos repetidos en el JSON'
    return filas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=HERE)
    a = ap.parse_args()

    with open(SRC, encoding='utf-8') as f:
        data = json.load(f)
    filas = lineas_cafeteria(data['items'])

    values = ',\n'.join(
        f'    ({q(c)}, {q(d)}, {num(caf)}, {num(alm)}, {num(tot)})'
        for c, d, caf, alm, tot in filas)
    # Por debajo de esto el negocio no es el que se cree (o el catálogo cambió
    # de códigos): el aplicar se niega.
    min_match = int(len(filas) * 0.75)

    os.makedirs(a.out, exist_ok=True)
    for tpl, out in SALIDAS.items():
        with open(os.path.join(HERE, tpl), encoding='utf-8') as f:
            s = f.read()
        s = (s.replace('__CONTEO_VALUES__', values)
              .replace('__N_CONTEO__', str(len(filas)))
              .replace('__MIN_MATCH__', str(min_match))
              .replace('__BUSINESS__', BUSINESS)
              .replace('__PC_CORTE__', PC_CORTE)
              .replace('__PC_ABANDONADO__', PC_ABANDONADO)
              .replace('__CORTE__', CORTE)
              .replace('__NOMBRE_PRINCIPAL__', NOMBRE_PRINCIPAL))
        assert not re.search(r'__[A-Z_]+__', s.replace('__IN_TRANSIT__', '')), tpl
        with open(os.path.join(a.out, out), 'w', encoding='utf-8') as f:
            f.write(s)

    caf = sum(f[2] for f in filas)
    alm = sum(f[3] for f in filas)
    print(f'{len(filas)} códigos de cafetería · cafetería {num(caf)} u · '
          f'almacén {num(alm)} u · total {num(caf + alm)} u · mínimo encontrados {min_match}')
    print('→', ', '.join(SALIDAS.values()), 'en', a.out)


if __name__ == '__main__':
    sys.exit(main())
