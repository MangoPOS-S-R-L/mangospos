import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/storage/image_upload_helper.dart';

class StorageRepository {
  final _sp = Supabase.instance.client;
  static const _bucket = 'menu-items';

  /// Sube bytes a /{businessId}/{itemId}{ext}  y retorna la URL pública.
  Future<String> uploadMenuItemImage({
    required String businessId,
    required String itemId,
    required Uint8List bytes,
    String? fileName,
  }) async {
    // PRD 7 Fase 2.2: comprimir antes de subir. Usamos preset de menú
    // (1024px, q=85, JPEG). El helper devuelve los bytes originales si
    // ya están chicos o si la compresión falla.
    final compressed = await ImageUploadHelper.compressForMenu(bytes);

    // detectar extensión por el nombre o por bytes
    String ext = '';
    if (fileName != null) {
      ext = p.extension(fileName); // .jpg, .png
    }
    // Si el helper comprimió a JPEG, forzamos `.jpg`. Si devolvió los
    // originales (compresión saltada/fallida), respetamos la extensión
    // del filename para que cached_network_image no se confunda.
    if (!identical(compressed, bytes)) {
      ext = '.jpg';
    }
    ext = (ext.isEmpty || ext == '.') ? '.jpg' : ext;

    final path = '$businessId/$itemId$ext';
    await _sp.storage.from(_bucket).uploadBinary(
          path,
          compressed,
          fileOptions: const FileOptions(upsert: true),
        );

    // pública:
    return _sp.storage.from(_bucket).getPublicUrl(path);
  }
}
