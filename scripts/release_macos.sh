#!/bin/bash
set -euo pipefail

# Asegurarse de que estamos en la raíz del proyecto
cd "$(dirname "$0")/.."

echo "🚀 Iniciando proceso de release para macOS..."

# ---------------------------------------------------------------------------
# Configuración por entorno (nada de secretos hardcodeados en el repo)
#
#   DEVELOPER_ID    Identidad de firma completa, ej:
#                   "Developer ID Application: Mi Empresa SRL (AB12CD34EF)"
#                   Si se deja vacío se autodetecta del llavero.
#
#   NOTARY_PROFILE  Nombre del perfil de notarytool guardado en el llavero.
#                   Se crea UNA vez con:
#                     xcrun notarytool store-credentials "mangopos-notary" \
#                       --apple-id "tu@correo.com" \
#                       --team-id "AB12CD34EF" \
#                       --password "clave-especifica-de-app"
#
#   SKIP_NOTARIZE=1 Firma pero no notariza (build de prueba rápido; el DMG
#                   resultante NO sirve para repartir a clientes).
# ---------------------------------------------------------------------------
DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-mangopos-notary}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"

ENTITLEMENTS="macos/Runner/Release.entitlements"

# 1. Extraer versión de pubspec.yaml
VERSION=$(grep "^version:" pubspec.yaml | awk '{print $2}' | cut -d'+' -f1)
echo "📦 Versión detectada: $VERSION"

# 2. Resolver identidad de firma ANTES de compilar, para avisar temprano.
#    Se busca "Developer ID Application", que es la única que sirve para
#    repartir fuera del App Store. Un certificado "Apple Development" NO
#    sirve: firma para correr en máquinas de desarrollo registradas, y
#    Gatekeeper igual bloquea la app en la Mac del cliente.
if [ -z "$DEVELOPER_ID" ]; then
    DEVELOPER_ID=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" \
        | head -1 \
        | sed -E 's/.*"(.+)"$/\1/') || true
fi

CAN_SIGN=0
if [ -n "$DEVELOPER_ID" ]; then
    CAN_SIGN=1
    echo "🔏 Identidad de firma: $DEVELOPER_ID"
else
    echo ""
    echo "⚠️  ============================================================"
    echo "⚠️  NO se encontró un certificado 'Developer ID Application'."
    echo "⚠️"
    echo "⚠️  El DMG se va a generar SIN FIRMAR y SIN NOTARIZAR. Sirve"
    echo "⚠️  para probar en ESTA Mac, pero Gatekeeper lo va a bloquear"
    echo "⚠️  en la Mac del cliente con 'la app está dañada'."
    echo "⚠️"
    echo "⚠️  Para poder repartirlo necesitas, en el Apple Developer"
    echo "⚠️  Program (cuenta de organización, US\$99/año):"
    echo "⚠️    1. Crear un certificado 'Developer ID Application'"
    echo "⚠️    2. Instalarlo en el llavero de esta Mac"
    echo "⚠️    3. Guardar credenciales de notarización:"
    echo "⚠️       xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
    echo "⚠️         --apple-id TU@CORREO --team-id TEAMID --password CLAVE-APP"
    echo "⚠️  ============================================================"
    echo ""
fi

# 3. Compilar la aplicación en modo Release
echo "🔨 Compilando Flutter app para macOS..."
flutter build macos --release

APP_PATH="build/macos/Build/Products/Release/mangopos.app"
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: No se encontró la aplicación compilada en $APP_PATH"
    exit 1
fi

# 4. Firmar la .app
#
#    Se firma de adentro hacia afuera: primero cada framework/dylib anidado,
#    después el bundle. NO se usa `codesign --deep` — Apple lo desaconseja
#    porque aplica los mismos entitlements a todo lo anidado y produce firmas
#    que la notarización rechaza.
#
#    --options runtime activa el Hardened Runtime, REQUISITO para notarizar.
if [ "$CAN_SIGN" -eq 1 ]; then
    echo "🔏 Firmando frameworks anidados..."
    if [ -d "$APP_PATH/Contents/Frameworks" ]; then
        # -print0/read -d evita romperse con rutas que traen espacios.
        while IFS= read -r -d '' nested; do
            codesign --force --timestamp --options runtime \
                --sign "$DEVELOPER_ID" "$nested"
        done < <(find "$APP_PATH/Contents/Frameworks" -maxdepth 1 \
            \( -name "*.framework" -o -name "*.dylib" -o -name "*.xpc" \) \
            -print0)
    fi

    echo "🔏 Firmando el bundle de la app..."
    codesign --force --timestamp --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$DEVELOPER_ID" "$APP_PATH"

    echo "🔍 Verificando la firma..."
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

# 5. Crear DMG usando hdiutil
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

echo "✅ DMG creado: $DMG_PATH"

# 6. Firmar y notarizar el DMG
#
#    La notarización sube el DMG a Apple, que lo escanea y devuelve un
#    ticket. `stapler` pega ese ticket DENTRO del DMG para que la Mac del
#    cliente pueda validarlo SIN INTERNET — importante acá, donde los
#    locales instalan con conexión mala o nula.
if [ "$CAN_SIGN" -eq 1 ]; then
    echo "🔏 Firmando el DMG..."
    codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG_PATH"

    if [ "$SKIP_NOTARIZE" = "1" ]; then
        echo "⏭️  SKIP_NOTARIZE=1 — se omite la notarización."
        echo "⚠️  Este DMG NO se puede repartir: Gatekeeper lo bloqueará."
    elif ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "⚠️  No existe el perfil de notarytool '$NOTARY_PROFILE'."
        echo "⚠️  El DMG queda firmado pero SIN notarizar (no repartible)."
        echo "⚠️  Créalo con:"
        echo "⚠️    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
        echo "⚠️      --apple-id TU@CORREO --team-id TEAMID --password CLAVE-APP"
    else
        echo "📤 Enviando a notarizar (esto tarda: típicamente 2-15 min)..."
        xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait

        echo "📎 Adjuntando el ticket al DMG (stapler)..."
        xcrun stapler staple "$DMG_PATH"

        echo "🔍 Validando que Gatekeeper lo acepte..."
        xcrun stapler validate "$DMG_PATH"
        spctl --assess --type open --context context:primary-signature \
            --verbose=2 "$DMG_PATH"

        echo "✅ DMG firmado y notarizado — listo para repartir."
    fi
fi

# 7. Firmar el DMG con Sparkle (EdDSA) y publicar en el appcast
#
#    OJO — esto es OPCIONAL en macOS y por defecto se OMITE:
#
#    La app NO usa Sparkle en macOS. En lib/main.dart el auto-updater está
#    gateado a `Platform.isWindows` a propósito (el sandbox del Mac App Store
#    prohíbe un mecanismo de auto-update propio). O sea, un build de macOS
#    nunca lee appcast.xml: firmarlo con EdDSA y publicarlo no hace nada.
#
#    Por eso este paso NO puede tumbar el release: el entregable es el DMG.
#    Antes el script moría acá con "Signing key not found for account
#    ed25519" DESPUÉS de haber compilado y armado el DMG, y se perdía la
#    corrida entera por un paso que en macOS no sirve.
#
#    Si algún día se distribuye macOS fuera del App Store CON auto-update,
#    poner SPARKLE_APPCAST=1 y tener la llave EdDSA en el llavero.
#    IMPORTANTE: si ya hubo releases firmados, NO generes una llave nueva
#    con generate_keys — las apps instaladas traen la pública vieja en su
#    Info.plist y rechazarían la actualización. Hay que recuperar la
#    privada original.
SPARKLE_APPCAST="${SPARKLE_APPCAST:-0}"

if [ "$SPARKLE_APPCAST" != "1" ]; then
    echo "⏭️  Sparkle/appcast omitido (macOS no lo usa; ver lib/main.dart)."
    echo "    Fuérzalo con SPARKLE_APPCAST=1 si algún día hace falta."
elif [ ! -f "sparkle_tools/bin/sign_update" ]; then
    echo "⚠️  sign_update no encontrado — se omite el appcast. El DMG está listo."
elif ! SIGNATURE=$(./sparkle_tools/bin/sign_update -p "$DMG_PATH" 2>/dev/null); then
    echo "⚠️  No hay llave EdDSA de Sparkle en el llavero — se omite el appcast."
    echo "⚠️  El DMG está listo igual."
else
    FILE_SIZE=$(stat -f%z "$DMG_PATH")
    echo "=========================================="
    echo "📝 Firma generada: $SIGNATURE"
    echo "📏 Tamaño del archivo: $FILE_SIZE bytes"
    echo "=========================================="
    echo "📄 Actualizando appcast.xml..."
    python3 scripts/update_appcast.py "$VERSION" "$SIGNATURE" "$FILE_SIZE" "macos"
fi

DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
echo ""
echo "🎉 ¡Proceso finalizado!"
echo "📦 $DMG_PATH  ($DMG_SIZE)"
if [ "$CAN_SIGN" -eq 0 ]; then
    echo ""
    echo "⚠️  Este DMG NO está firmado ni notarizado: solo abre en esta Mac."
    echo "⚠️  Para repartirlo a clientes hace falta un certificado"
    echo "⚠️  'Developer ID Application' (ver el aviso del inicio)."
fi
