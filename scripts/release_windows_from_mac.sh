#!/bin/bash
set -e

# Asegurarse de que estamos en la raíz del proyecto
cd "$(dirname "$0")/.."

if [ -z "$1" ]; then
    echo "Uso: ./scripts/release_windows_from_mac.sh <ruta_al_archivo_exe>"
    echo "Ejemplo: ./scripts/release_windows_from_mac.sh ~/Downloads/mangospos.exe"
    exit 1
fi

EXE_PATH="$1"

if [ ! -f "$EXE_PATH" ]; then
    echo "❌ Error: El archivo '$EXE_PATH' no existe."
    exit 1
fi

echo "🚀 Iniciando proceso de firma para Windows (.exe) desde Mac..."

# 1. Extraer versión de pubspec.yaml
VERSION=$(grep "^version:" pubspec.yaml | awk '{print $2}' | cut -d'+' -f1)
echo "📦 Versión detectada: $VERSION"

FILE_SIZE=$(stat -f%z "$EXE_PATH")
echo "📏 Tamaño del archivo: $FILE_SIZE bytes"

# 2. Firmar el EXE
echo "🔑 Firmando el EXE con winsparkle_keys/dsa_priv.pem..."

if [ ! -f "winsparkle_keys/dsa_priv.pem" ]; then
    echo "❌ Error: Llave privada de Windows no encontrada en winsparkle_keys/dsa_priv.pem"
    exit 1
fi

SIGNATURE=$(openssl pkeyutl -sign -inkey winsparkle_keys/dsa_priv.pem -rawin -in "$EXE_PATH" | base64)

echo "=========================================="
echo "📝 Firma generada correctamente."
echo "=========================================="

# 3. Renombrar y copiar el archivo a una ubicación estándar si es necesario
FINAL_EXE_NAME="MangoPOS-${VERSION}-windows.exe"
FINAL_EXE_PATH="build/$FINAL_EXE_NAME"

mkdir -p build
cp "$EXE_PATH" "$FINAL_EXE_PATH"
echo "✅ Archivo ejecutado copiado a $FINAL_EXE_PATH"

# 4. Actualizar appcast.xml con Python
echo "📄 Actualizando appcast.xml..."
python3 scripts/update_appcast.py "$VERSION" "$SIGNATURE" "$FILE_SIZE" "windows"

echo "🎉 ¡Proceso finalizado con éxito!"
echo "Siguientes pasos:"
echo "1. El archivo '$FINAL_EXE_NAME' y el nuevo 'appcast.xml' están listos en la carpeta /build y en la raíz."
echo "2. Sube AMBOS archivos a tu servidor (https://mangopos.com/)."

# Aviso en la app (app_releases, 20261010_0025): después de subir el archivo a
# https://mangopos.com/, pegar esta fila en el SQL Editor para que los equipos
# windows vean «Actualización disponible».
BUILD=$(grep "^version:" pubspec.yaml | awk '{print $2}' | cut -d'+' -f2)
echo ""
echo "📣 Para avisar en la app, después de subir el archivo, corre en el SQL Editor:"
echo "insert into public.app_releases (platform, version, build, download_url, notes)"
echo "values ('windows', '$VERSION', $BUILD, 'https://mangopos.com/MangoPOS-${VERSION}-windows.exe', null)"
echo "on conflict (platform, build) do update set version = excluded.version,"
echo "  download_url = excluded.download_url, notes = excluded.notes, published_at = now();"
