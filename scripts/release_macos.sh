#!/bin/bash
set -e

# Asegurarse de que estamos en la raíz del proyecto
cd "$(dirname "$0")/.."

echo "🚀 Iniciando proceso de release para macOS..."

# 1. Extraer versión de pubspec.yaml
VERSION=$(grep "^version:" pubspec.yaml | awk '{print $2}' | cut -d'+' -f1)
echo "📦 Versión detectada: $VERSION"

# 2. Compilar la aplicación en modo Release
echo "🔨 Compilando Flutter app para macOS..."
flutter build macos --release

APP_PATH="build/macos/Build/Products/Release/mangopos.app"
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: No se encontró la aplicación compilada en $APP_PATH"
    exit 1
fi

# 3. Crear DMG usando hdiutil
DMG_DIR="build/dmg_tmp"
DMG_NAME="MangoPOS-${VERSION}-macOS.dmg"
DMG_PATH="build/$DMG_NAME"

echo "💿 Creando imagen DMG..."
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -r "$APP_PATH" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create -volname "MangoPOS" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$DMG_DIR"

echo "✅ DMG creado exitosamente: $DMG_PATH"

# 4. Firmar el DMG con Sparkle
echo "🔑 Firmando el DMG para obtener EdDSA signature..."
if [ ! -f "sparkle_tools/bin/sign_update" ]; then
    echo "❌ Error: Herramienta sign_update no encontrada. Asegúrate de haber descargado sparkle_tools."
    exit 1
fi

# -p solo imprime la firma en stdout
SIGNATURE=$(./sparkle_tools/bin/sign_update -p "$DMG_PATH")
FILE_SIZE=$(stat -f%z "$DMG_PATH")

echo "=========================================="
echo "📝 Firma generada: $SIGNATURE"
echo "📏 Tamaño del archivo: $FILE_SIZE bytes"
echo "=========================================="

# 5. Actualizar appcast.xml con Python
echo "📄 Actualizando appcast.xml..."
python3 scripts/update_appcast.py "$VERSION" "$SIGNATURE" "$FILE_SIZE" "macos"

echo "🎉 ¡Proceso finalizado con éxito!"
echo "Siguientes pasos:"
echo "1. El archivo '$DMG_NAME' y el nuevo 'appcast.xml' están listos en la carpeta /build y en la raíz."
echo "2. Sube AMBOS archivos a tu servidor (https://mangopos.com/)."
