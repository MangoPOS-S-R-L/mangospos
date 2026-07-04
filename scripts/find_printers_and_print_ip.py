#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Buscar impresoras en la LAN y hacer que CADA UNA imprima su propia IP.

Uso (desde la Mac, en la MISMA red que las impresoras):

    # 1) Solo escanear y listar (no imprime nada):
    python3 scripts/find_printers_and_print_ip.py --scan-only

    # 2) Escanear y mandar a cada impresora un ticket con su IP:
    python3 scripts/find_printers_and_print_ip.py

    # 3) Forzar una subred especifica (si tienes varias interfaces):
    python3 scripts/find_printers_and_print_ip.py --subnet 192.168.1

Como funciona:
  - Detecta tu /24 local (o el que pases con --subnet).
  - Escanea .1-.254 buscando el puerto 9100 (RAW / JetDirect, el estandar
    de impresion cruda ESC/POS).
  - A cada IP que responde le envia un ticket ESC/POS que imprime, en
    grande, su propia direccion IP. Asi caminas por las cajas y ves que
    impresora saco cada IP para poder agregarlas por RED en MangoPOS.

Requisitos: solo Python 3 (ya viene en macOS). No instala nada.
"""

import argparse
import socket
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed

RAW_PORT = 9100
SCAN_TIMEOUT = 0.4   # seg por host durante el escaneo
SEND_TIMEOUT = 5.0   # seg para enviar el ticket


def detect_local_subnet():
    """Devuelve el prefijo /24 de la IP local (ej. '192.168.1'). Truco UDP:
    no envia nada real, solo fuerza al SO a elegir la interfaz de salida."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = "127.0.0.1"
    finally:
        s.close()
    return ".".join(ip.split(".")[:3]), ip


def check_port(ip, port=RAW_PORT, timeout=SCAN_TIMEOUT):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        return ip if s.connect_ex((ip, port)) == 0 else None
    except Exception:
        return None
    finally:
        s.close()


def scan_subnet(subnet):
    print(f"Escaneando {subnet}.1 - {subnet}.254 en el puerto {RAW_PORT} ...")
    found = []
    with ThreadPoolExecutor(max_workers=128) as pool:
        futs = {pool.submit(check_port, f"{subnet}.{i}"): i for i in range(1, 255)}
        for fut in as_completed(futs):
            ip = fut.result()
            if ip:
                found.append(ip)
                print(f"  ✅ Impresora en {ip}:{RAW_PORT}")
    found.sort(key=lambda x: int(x.split(".")[-1]))
    return found


def build_ip_slip(ip):
    """Ticket ESC/POS que imprime la IP en grande + corte."""
    ESC = b"\x1b"
    GS = b"\x1d"
    out = bytearray()
    out += ESC + b"@"                    # init
    out += ESC + b"a" + b"\x01"          # centrar
    out += ESC + b"!" + b"\x38"          # bold + doble alto/ancho
    out += b"MangoPOS\n"
    out += ESC + b"!" + b"\x00"          # normal
    out += b"IP de esta impresora:\n\n"
    out += GS + b"!" + b"\x11"           # doble alto + doble ancho
    out += ip.encode("ascii", "replace") + b"\n"
    out += GS + b"!" + b"\x00"           # tamano normal
    out += ESC + b"!" + b"\x00"
    out += ESC + b"a" + b"\x00"          # alinear izq
    out += f"\npuerto {RAW_PORT} (RAW)\n".encode("ascii", "replace")
    out += b"\n\n\n\n"
    out += GS + b"V" + b"\x00"           # corte total
    return bytes(out)


def send_slip(ip):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(SEND_TIMEOUT)
    try:
        s.connect((ip, RAW_PORT))
        s.sendall(build_ip_slip(ip))
        return True, None
    except Exception as e:
        return False, str(e)
    finally:
        s.close()


def main():
    ap = argparse.ArgumentParser(description="Buscar impresoras y hacer que cada una imprima su IP.")
    ap.add_argument("--subnet", help="Prefijo /24 a escanear, ej. 192.168.1 (por defecto: autodetectado).")
    ap.add_argument("--scan-only", action="store_true", help="Solo listar; no enviar impresiones.")
    ap.add_argument("--yes", "-y", action="store_true", help="No preguntar; imprimir en todas las encontradas.")
    args = ap.parse_args()

    if args.subnet:
        subnet = args.subnet.rstrip(".")
        print(f"Subred forzada: {subnet}.0/24")
    else:
        subnet, my_ip = detect_local_subnet()
        print(f"Tu Mac: {my_ip}  ->  escaneando subred {subnet}.0/24")
        print("(si tus impresoras estan en otra subred, usa --subnet)")

    printers = scan_subnet(subnet)
    if not printers:
        print("\nNo se encontro ninguna impresora con el puerto 9100 abierto.")
        print("Verifica que la Mac este en la MISMA red que las impresoras, o prueba --subnet.")
        return 1

    print(f"\nEncontradas {len(printers)} impresora(s): {', '.join(printers)}")

    if args.scan_only:
        print("(--scan-only: no se envio nada)")
        return 0

    if not args.yes:
        resp = input(f"\n¿Enviar un ticket con su IP a las {len(printers)} impresoras? [y/N] ").strip().lower()
        if resp not in ("y", "s", "yes", "si"):
            print("Cancelado. (usa --scan-only para solo listar)")
            return 0

    print()
    ok = 0
    for ip in printers:
        good, err = send_slip(ip)
        if good:
            ok += 1
            print(f"  🖨️  {ip}: ticket enviado")
        else:
            print(f"  ❌ {ip}: fallo -> {err}")
    print(f"\nListo: {ok}/{len(printers)} impresoras imprimieron su IP.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nInterrumpido.")
        sys.exit(130)
