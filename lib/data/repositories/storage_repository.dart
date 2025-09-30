import 'dart:typed_data';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

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
    // detectar extensión por el nombre o por bytes
    String ext = '';
    if (fileName != null) {
      ext = p.extension(fileName); // .jpg, .png
    }
    ext = (ext.isEmpty || ext == '.') ? '.jpg' : ext;

    final path = '$businessId/$itemId$ext';
    await _sp.storage.from(_bucket).uploadBinary(path, bytes, fileOptions: const FileOptions(upsert: true));

    // pública:
    return _sp.storage.from(_bucket).getPublicUrl(path);
  }
}
