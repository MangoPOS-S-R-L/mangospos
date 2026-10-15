#!/usr/bin/env python3
"""Datos de ensayo para UNIF_*: imita la cafetería de Estancia Nueva el 13-oct
(sacado del diagnóstico de producción del 13-oct).

Bodegas: CAFETERIA (principal, ahí cae la venta), ALMACEN (donde se aplicó
PC-2026-000004), Almacen Cocina (producción, área COCINA, vacía), BARRA (en POS,
extra para ejercitar consumo fuera de la principal), VIEJA (ya apagada),
__IN_TRANSIT__. Conteos: PC-0001 cancelado, PC-0002 en curso (abandonado,
congelado 11:55), PC-0003 cancelado, PC-0004 en ALMACEN (14:24 → 15:49).
La parte de CAFETERÍA del conteo NO está cargada. Costeo UEPS (lifo).
Corte del aplicar: 01-oct 11:55.

Ítems especiales (los demás de los 196 solo existen, con sus ajustes del PC):
  BARRAS 016000264694   53 contado · −2 a las 11:00 (ANTES del corte, no cuenta)
                        · −1 a las 13:00 (cuenta) · −5 BARRA · −2 principal
                        · +10 compra → 55
  STOLI 4750021000157   solo por código de barras · recepción directa +6 y su
                        anulación −6 (ajuste direct_receipt_cancel: NO es manual)
                        · −1 → 5
  CHIVA 5000299225028   1 contado · −3 → −2 (negativo)
  GOMITAS 034856008187  141 · orden ABIERTA −4 en BARRA, pagada −1 → 136
  MICHELOB 01833225     546 · transferencia ALMACEN→BARRA 10 (recibida) → 546
  BEEFEATER 5000329002230  NO existe en el negocio
  ZZ-U1 (no contado)    +7 BARRA, −2 principal → 5
  ZZ-U2 (no contado)    −3 ALMACEN → −3
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import build_unificar_almacen as b  # noqa: E402

B = b.BUSINESS
filas = b.lineas_cafeteria(json.load(open(b.SRC, encoding='utf-8'))['items'])

AREA = 'f0000000-0000-0000-0000-000000000001'
W = {
    'P': ('a0000000-0000-0000-0000-000000000001', 'CAFETERIA', True, True, False, '2026-09-21 11:13-04', None, 'general'),
    'A': ('a0000000-0000-0000-0000-000000000002', 'ALMACEN', False, True, False, '2026-10-01 14:21-04', None, 'general'),
    'C': ('a0000000-0000-0000-0000-000000000003', 'BARRA', False, True, True, '2026-10-01 11:00-04', None, 'general'),
    'K': ('a0000000-0000-0000-0000-000000000006', 'Almacen Cocina', False, True, False, '2026-10-01 11:54-04', AREA, 'production'),
    'V': ('a0000000-0000-0000-0000-000000000004', 'VIEJA', False, False, False, '2026-09-25', None, 'general'),
    'T': ('a0000000-0000-0000-0000-000000000005', '__IN_TRANSIT__', False, True, False, '2026-10-02', None, 'general'),
}
PC = 'c0000000-0000-0000-0000-000000000004'
PC2 = 'c0000000-0000-0000-0000-000000000002'
out = []
w = out.append

w(f"insert into business_settings values ('{B}', 'advanced', false, false, 'lifo');")
w(f"insert into print_areas (id, business_id, name, code) values ('{AREA}', '{B}', 'COCINA', 'cocina');")
for k, (wid, name, main, active, pos, ts, area, tipo) in W.items():
    w(f"insert into warehouses (id, business_id, name, is_main, is_active, shows_in_pos, created_at,"
      f" production_area_id, warehouse_type) values ('{wid}', '{B}', '{name}', {main}, {active}, {pos}, '{ts}',"
      f" {b.q(area) if area else 'null'}, '{tipo}');")

ids = {}
for i, (codigo, desc, caf, alm, tot) in enumerate(filas):
    if codigo == '5000329002230':
        continue  # BEEFEATER: no existe
    iid = f'b0000000-0000-0000-0000-{i:012d}'
    ids[codigo] = iid
    sku, bc = (('X-STOLI', codigo) if codigo == '4750021000157' else (codigo, None))
    w(f"insert into inventory_items (id, business_id, sku, barcode, name, cost) values "
      f"('{iid}', '{B}', {b.q(sku)}, {b.q(bc) if bc else 'null'}, {b.q(desc)}, 10);")
U1, U2 = 'b1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000002'
w(f"insert into inventory_items (id, business_id, sku, name, cost) values ('{U1}', '{B}', 'ZZ-U1', 'NO CONTADO 1', 5),"
  f" ('{U2}', '{B}', 'ZZ-U2', 'NO CONTADO 2', 5);")
# Un insumo de OTRO negocio con el mismo código: no debe estorbar.
w("insert into inventory_items (business_id, sku, name) values "
  "('40b0fa9d-9ce6-4e17-902d-6f5f37cc58ab', '016000264694', 'OTRO NEGOCIO');")

# Conteos de la mañana: uno cancelado, el abandonado (congelado, 14 contados) y otro cancelado.
w(f"insert into physical_count_sessions (business_id, warehouse_id, code, status, started_at) values"
  f" ('{B}', '{W['P'][0]}', 'PC-2026-000001', 'cancelled', '2026-10-01 11:50-04');")
w(f"insert into physical_count_sessions (id, business_id, warehouse_id, code, status, started_at, frozen_at) values"
  f" ('{PC2}', '{B}', '{W['P'][0]}', 'PC-2026-000002', 'in_progress', '2026-10-01 11:54-04', '2026-10-01 11:55-04');")
for codigo in list(ids)[:14]:
    w(f"insert into physical_count_lines (session_id, item_id, snapshot_quantity, counted_quantity)"
      f" values ('{PC2}', '{ids[codigo]}', 0, 3);")
w(f"insert into physical_count_sessions (business_id, warehouse_id, code, status, started_at, frozen_at) values"
  f" ('{B}', '{W['P'][0]}', 'PC-2026-000003', 'cancelled', '2026-10-01 12:04-04', '2026-10-01 12:05-04');")

# Conteo del almacén: congelado 14:24, aplicado 15:49, foto en 0.
w(f"insert into physical_count_sessions (id, business_id, warehouse_id, code, status, started_at, frozen_at, completed_at)"
  f" values ('{PC}', '{B}', '{W['A'][0]}', 'PC-2026-000004', 'completed', '2026-10-01 14:22-04',"
  f" '2026-10-01 14:24-04', '2026-10-01 15:49-04');")
for codigo, desc, caf, alm, tot in filas:
    if alm <= 0 or codigo not in ids:
        continue
    iid = ids[codigo]
    w(f"with m as (insert into inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity,"
      f" cost_per_unit, reference_id, reference_type, notes, created_at) values ('{B}', '{W['A'][0]}', '{iid}',"
      f" 'adjustment', {alm}, 10, '{PC}', 'physical_count', 'Ajuste por conteo físico PC-2026-000004',"
      f" '2026-10-01 15:49-04') returning id)"
      f" insert into physical_count_lines (session_id, item_id, snapshot_quantity, counted_quantity, applied_adjustment_id)"
      f" select '{PC}', '{iid}', 0, {alm}, id from m;")


def mov(wk, item, tipo, q, ts, ref=None, rtype=None, reason=None, cost=None):
    w(f"insert into inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity,"
      f" cost_per_unit, reference_id, reference_type, reason_code, created_at) values ('{B}', '{W[wk][0]}',"
      f" '{item}', '{tipo}', {q}, {cost if cost is not None else 'null'},"
      f" {b.q(ref) if ref else 'null'}, {b.q(rtype) if rtype else 'null'}, {b.q(reason) if reason else 'null'}, '{ts}');")


BARRAS, STOLI, CHIVA = ids['016000264694'], ids['4750021000157'], ids['5000299225028']
GOM, MICH = ids['034856008187'], ids['01833225']
mov('P', BARRAS, 'sale', -2, '2026-10-01 11:00-04')          # antes del corte: no cuenta
mov('P', BARRAS, 'sale', -1, '2026-10-01 13:00-04')          # entre 11:55 y 14:24: cuenta
mov('C', BARRAS, 'sale', -5, '2026-10-03 12:00-04')
mov('P', BARRAS, 'sale', -2, '2026-10-05 12:00-04')
mov('P', BARRAS, 'purchase', 10, '2026-10-06 09:00-04', cost=12)
DR = 'e1000000-0000-0000-0000-000000000001'
mov('P', STOLI, 'purchase', 6, '2026-10-05 09:00-04', DR, 'direct_receipt', cost=900)
mov('P', STOLI, 'adjustment', -6, '2026-10-05 09:30-04', DR, 'direct_receipt_cancel', 'correction')
mov('C', STOLI, 'sale', -1, '2026-10-04 20:00-04')
mov('C', CHIVA, 'sale', -3, '2026-10-07 20:00-04')
O1, O2 = 'd0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000002'
w(f"insert into orders (id, status, status_ext) values ('{O1}', 'open', 'open'), ('{O2}', 'paid', 'paid');")
mov('C', GOM, 'sale', -4, '2026-10-12 21:00-04', O1, 'order')
mov('C', GOM, 'sale', -1, '2026-10-11 21:00-04', O2, 'order')
TR = 'e0000000-0000-0000-0000-000000000001'
w(f"insert into stock_transfers (id, business_id, from_warehouse_id, to_warehouse_id, transfer_number, status)"
  f" values ('{TR}', '{B}', '{W['A'][0]}', '{W['C'][0]}', 'TR-1', 'received');")
mov('A', MICH, 'transfer_out', -10, '2026-10-08 10:00-04', TR, 'stock_transfer')
mov('T', MICH, 'transfer_in', 10, '2026-10-08 10:00-04', TR, 'stock_transfer')
mov('T', MICH, 'transfer_out', -10, '2026-10-08 10:05-04', TR, 'stock_transfer')
mov('C', MICH, 'transfer_in', 10, '2026-10-08 10:05-04', TR, 'stock_transfer')
mov('C', U1, 'purchase', 7, '2026-09-28')
mov('P', U1, 'sale', -2, '2026-10-09')
mov('A', U2, 'sale', -3, '2026-10-09')
w(f"insert into purchase_orders (business_id, warehouse_id, status) values ('{B}', '{W['A'][0]}', 'sent');")

print('\n'.join(out))
