#!/usr/bin/env python3
"""Genera la carga de la TIENDA de Estancia Nueva (business 40b0fa9d): los 353
artículos deportivos que build_estancia_nueva.prepare() separó de la cafetería.

Uso:
    <python con openpyxl> build_import_tienda.py [--out CARPETA]

Escribe, desde _tpl_import_tienda.sql / _tpl_rollback_tienda.sql:
    IMPORT_TIENDA.sql            la carga, una transacción (re-ejecutable)
    99_rollback_tienda.sql       la deshace
    precios_tienda_revision.csv  un renglón por artículo, con la regla de precio

Precios: ProIsa_lista.csv con las MISMAS reglas acordadas para la cafetería
(sin ITBIS ×1.18 al peso; los redondos que ×1.18 no lo son ya son finales;
vacío o 1.00 = sin precio), más las correcciones de abajo. Sin precio → entra
inactivo en RD$0. Inventariable en cero todo menos los servicios del club.
"""

import argparse
import csv
import re
import sys
from pathlib import Path

from build_estancia_nueva import barcode_for, prepare
from build_import_cafeteria import leer_proisa, q

HERE = Path(__file__).resolve().parent
BID = '40b0fa9d-9ce6-4e17-902d-6f5f37cc58ab'   # Estancia Nueva Sport · TIENDA

CATEGORIAS = ['Pádel', 'Fútbol', 'Ropa y accesorios', 'Servicios del club']
SIN_INVENTARIO = {'Servicios del club'}

# ProIsa trae estas palas con el precio (y el costo) en DÓLARES: Head Radical
# Pro a 228.98, Babolat Contact a 93.38… En pesos se regalarían. Entran sin
# precio para que el dueño se los ponga.
PRECIO_EN_DOLARES = {
    '110000100497': 'BABOLAT COUNTER VERTUO',
    '110000100485': 'PALA BABOLAT CONTACT',
    '110000100487': 'PALA BABOLAT TECHNICAL VERTUO',
    '110000100482': 'PALA HEAD FLASH',
    '110000100489': 'PALA HEAD RADICAL PRO',
    '110000100490': 'PALA HEAD ZEPHYR UL',
    '110000100483': 'PALA SIUX SPIDER',
}
# Precio bien, pero el COSTO en dólares (119 y 88 por una pala de 7,000+):
# se carga sin costo para no falsear el margen ni el valor del inventario.
COSTO_EN_DOLARES = set(PRECIO_EN_DOLARES) | {
    '110000100488',   # PALA ADIDAS RX SERIES LIGHT, costo 119
    '110000100484',   # PALA HEAD DELTA JUNIOR, costo 88
}
# Cuántos precios de ProIsa ya son finales en la tienda (incluye la Zephyr,
# que igual se anula arriba). Si la lista cambia, el generador se detiene.
YA_FINALES = 9


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=str(HERE))
    args = ap.parse_args()

    productos, insumos, tienda, decidir, *_ = prepare()
    for r in tienda:
        r['clean'] = re.sub(r'\s+', ' ', r['name']).strip().upper()
        cost = r['cost']
        r['cost_out'] = None if (abs(cost - 1.0) < 1e-9 or cost <= 0
                                 or r['code'] in COSTO_EN_DOLARES) else cost
        r['barcode'] = barcode_for(r['code']) or None
        r['inventariable'] = r['group'] not in SIN_INVENTARIO

    conocidos = {r['code'] for r in productos + insumos + tienda + decidir}
    precios, _, revision, fuente = leer_proisa(HERE / 'ProIsa_lista.csv', tienda,
                                               conocidos, esperados=YA_FINALES)
    for code in PRECIO_EN_DOLARES:
        precios[code] = None
    for x in revision:
        if x['codigo'] in PRECIO_EN_DOLARES:
            x['precio_caja'] = ''
            x['regla'] = 'precio en DÓLARES en ProIsa: sin precio'
            x['nota'] = ''
        if x['codigo'] in COSTO_EN_DOLARES:
            x['costo'] = ''
            if x['codigo'] not in PRECIO_EN_DOLARES:
                x['nota'] = 'costo en dólares en ProIsa: se carga sin costo'
    for r in tienda:
        r['price'] = precios.get(r['code'])

    for cat in CATEGORIAS:
        grupo = sorted((r for r in tienda if r['group'] == cat), key=lambda r: (r['clean'], r['code']))
        for i, r in enumerate(grupo, 1):
            r['pos'] = i
    orden = {c: i for i, c in enumerate(CATEGORIAS)}
    tienda.sort(key=lambda r: (orden[r['group']], r['pos']))

    def num(x, dec):
        return 'null' if x is None else f'{x:.{dec}f}'

    lotes = []
    for i in range(0, len(tienda), 200):
        valores = ',\n'.join(
            '  ({}, {}, {}, {}, {}, {}, {}, {})'.format(
                q(r['code']), q(r['clean']), q(r['group']), num(r['price'], 2),
                num(r['cost_out'], 4), q(r['barcode']) if r['barcode'] else 'null',
                'true' if r['inventariable'] else 'false', r['pos'])
            for r in tienda[i:i + 200])
        lotes.append(
            f'-- filas {i + 1}–{min(i + 200, len(tienda))}\n'
            'insert into _tie (codigo, name, categoria, price, cost, barcode, '
            'inventariable, posicion) values\n' + valores + ';')

    con_precio = [r for r in tienda if r['price'] is not None]
    subs = {
        '__DATA__': '\n\n'.join(lotes),
        '__CATEGORIAS__': ',\n'.join(
            f'  ({q(c)}, {(i + 1) * 10})' for i, c in enumerate(CATEGORIAS)),
        '__CAT_NAMES_LOWER__': ', '.join(q(c.lower()) for c in CATEGORIAS),
        '__CODES__': ','.join(r['code'] for r in tienda),
        '__BID__': BID,
        '__FUENTE_PRECIOS__': f'{fuente} (sin ITBIS ×1.18 al peso; {YA_FINALES} ya finales; '
                              f'{len(PRECIO_EN_DOLARES)} en dólares sin precio)',
        '__N_TOTAL__': str(len(tienda)),
        '__N_CON_PRECIO__': str(len(con_precio)),
        '__N_INVENTARIABLES__': str(sum(r['inventariable'] for r in tienda)),
        '__N_BARCODE__': str(sum(1 for r in tienda if r['barcode'])),
        '__N_CATEGORIAS__': str(len(CATEGORIAS)),
    }

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for tpl, name in (('_tpl_import_tienda.sql', 'IMPORT_TIENDA.sql'),
                      ('_tpl_rollback_tienda.sql', '99_rollback_tienda.sql')):
        sql = (HERE / tpl).read_text(encoding='utf-8')
        for k, v in subs.items():
            sql = sql.replace(k, v)
        sobrantes = re.findall(r'__[A-Z_]+__', sql.replace('__IN_TRANSIT__', ''))
        if sobrantes:
            sys.exit(f'{tpl}: placeholders sin reemplazar: {sorted(set(sobrantes))}')
        (out / name).write_text(sql, encoding='utf-8')

    with open(out / 'precios_tienda_revision.csv', 'w', newline='', encoding='utf-8') as fh:
        w = csv.DictWriter(fh, fieldnames=list(revision[0]))
        w.writeheader()
        w.writerows(sorted(revision, key=lambda x: (orden[x['categoria']], x['nombre'])))

    print(f"{subs['__N_TOTAL__']} artículos ({subs['__N_CON_PRECIO__']} con precio → activos) · "
          f"{subs['__N_INVENTARIABLES__']} inventariables · {subs['__N_BARCODE__']} con código de barras · "
          + ' · '.join(f"{c} {sum(r['group'] == c for r in tienda)}" for c in CATEGORIAS))


if __name__ == '__main__':
    main()
