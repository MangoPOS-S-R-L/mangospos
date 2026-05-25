// Helper centralizado para compresión client-side de imágenes antes de
// subir a Supabase Storage.
//
// PRD 7 Fase 2.2 — hallazgo: ningún path de upload comprimía. Un iPhone
// foto de 5MB se persistía raw, multiplicando consumo de Storage y
// degradando performance de las pantallas que las descargan después.
//
// Política de compresión:
//   - Productos del menú: 1024px max lado mayor, calidad 85, JPEG.
//     Resultado típico: 5 MB → 80-150 KB (30-60× reducción).
//   - Logos del business: 512px max, calidad 90, preserva PNG si
//     el original era PNG (logos suelen tener transparencia).
//   - Genérico: parámetros configurables.
//
// Si la compresión falla (formato no soportado, plataforma exótica),
// el helper devuelve los bytes originales con un warning en debugPrint.
// Es preferible subir algo grande a fallar el upload entero.

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

class ImageUploadHelper {
  ImageUploadHelper._();

  /// Comprime una foto de producto del menú para subir a Supabase Storage.
  ///
  /// [bytes] son los bytes del archivo original (lo que devuelve
  /// FilePicker/image_picker). Output: bytes comprimidos en JPEG.
  ///
  /// Si la compresión falla, devuelve los bytes originales (fallback
  /// silencioso) — preferimos subir algo grande a fallar el upload.
  static Future<Uint8List> compressForMenu(Uint8List bytes) {
    return _compress(
      bytes,
      maxDimension: 1024,
      quality: 85,
      format: CompressFormat.jpeg,
    );
  }

  /// Comprime un logo de business. Output más pequeño (512px) y calidad
  /// más alta (90). Preserva PNG cuando hay transparencia.
  ///
  /// [isPng]: si true, devuelve PNG comprimido (lossless, mantiene
  /// canal alpha). Si false, JPEG.
  static Future<Uint8List> compressForLogo(
    Uint8List bytes, {
    required bool isPng,
  }) {
    return _compress(
      bytes,
      maxDimension: 512,
      quality: 90,
      format: isPng ? CompressFormat.png : CompressFormat.jpeg,
    );
  }

  /// API genérica para casos no estándar. Usa los presets cuando puedas.
  static Future<Uint8List> compress(
    Uint8List bytes, {
    int maxDimension = 1024,
    int quality = 85,
    CompressFormat format = CompressFormat.jpeg,
  }) {
    return _compress(
      bytes,
      maxDimension: maxDimension,
      quality: quality,
      format: format,
    );
  }

  static Future<Uint8List> _compress(
    Uint8List bytes, {
    required int maxDimension,
    required int quality,
    required CompressFormat format,
  }) async {
    // Bypass si ya es chiquito (no vale la pena el round-trip de
    // decode/encode para algo bajo 100 KB).
    if (bytes.length < 100 * 1024) return bytes;

    try {
      final compressed = await FlutterImageCompress.compressWithList(
        bytes,
        minWidth: maxDimension,
        minHeight: maxDimension,
        quality: quality,
        format: format,
        // keepExif=false: removemos metadata (GPS, modelo de cámara, etc.)
        // por privacidad. No necesitamos esos campos en un POS y suman peso.
        keepExif: false,
      );
      if (compressed.isEmpty) {
        debugPrint('[image_upload] compressWithList devolvió vacío, '
            'fallback a bytes originales (${bytes.length} bytes)');
        return bytes;
      }
      // Sanity check: si el "comprimido" es más grande que el original
      // (puede pasar con PNGs ya optimizados), usar el original.
      if (compressed.length >= bytes.length) {
        debugPrint('[image_upload] compresión no redujo tamaño '
            '(${bytes.length}→${compressed.length}), usando original');
        return bytes;
      }
      debugPrint('[image_upload] ${bytes.length} → ${compressed.length} bytes '
          '(${((1 - compressed.length / bytes.length) * 100).toStringAsFixed(0)}% reducción)');
      return Uint8List.fromList(compressed);
    } catch (e) {
      // Plataforma sin soporte de compresión (web sin polyfill, etc.) o
      // formato exótico. Subimos raw para no romper el flujo.
      debugPrint('[image_upload] compresión falló: $e. Subiendo raw.');
      return bytes;
    }
  }
}
