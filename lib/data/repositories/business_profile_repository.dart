// lib/data/repositories/business_profile_repository.dart
//
// Repo para gestionar el perfil editable de una sucursal: lectura/escritura
// de los campos identitarios + branding (businesses) y los toggles de
// impresion (business_settings), mas upload/delete del logo en Storage.
//
// Convenciones:
//   - Una row de `businesses` representa una sucursal (cada una tiene su
//     propio id, branch_name, logo, etc).
//   - Storage path del logo: "<business_id>/logo.<ext>". Politica RLS
//     valida que solo el dueño del business puede tocar su carpeta.
//   - Bucket: "business-logos" (publico, max 2MB, png/jpg).

import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/printing/logo_esc_pos_builder.dart';
import '../models/business_profile.dart';

class BusinessProfileRepository {
  final SupabaseClient _client;
  static const String logoBucket = 'business-logos';

  // Cache en memoria de los bytes del logo. Key = URL completa con
  // cache-buster (?v=timestamp), asi cuando el operador cambia el logo
  // la URL cambia y el cache miss naturalmente. Sin TTL — vive lo que
  // viva el proceso, suficiente para tickets.
  static final Map<String, Uint8List> _logoBytesCache = {};
  // Idem para los bytes ESC/POS pre-generados (resize + raster), evita
  // re-decodificar el PNG en cada impresion.
  static final Map<String, List<int>> _logoEscPosCache = {};

  BusinessProfileRepository(this._client);

  /// Trae el perfil agregado: combina businesses + business_settings en
  /// un único [BusinessProfile]. Si no existe row en business_settings,
  /// usa los defaults del modelo (logo off, slogan/branch on).
  Future<BusinessProfile?> getProfile(String businessId) async {
    final business = await _client
        .from('businesses')
        .select(
          'id, business_name, branch_name, fiscal_name, fiscal_rnc, '
          'address, phone, email, logo_url, logo_storage_path, slogan, '
          'ticket_footer_message',
        )
        .eq('id', businessId)
        .maybeSingle();
    if (business == null) return null;

    final settings = await _client
        .from('business_settings')
        .select(
          'print_logo_on_invoice, show_slogan_on_invoice, '
          'show_branch_name_on_invoice',
        )
        .eq('business_id', businessId)
        .maybeSingle();

    final merged = <String, dynamic>{
      ...business,
      if (settings != null) ...settings,
    };
    return BusinessProfile.fromMap(merged);
  }

  /// Persiste cambios al perfil. Acepta valores parciales — los nulos se
  /// ignoran, los strings vacíos se persisten como NULL en DB para que el
  /// usuario pueda "limpiar" un campo opcional.
  ///
  /// Toggles separados (printLogoOnInvoice, etc) van a business_settings
  /// via upsert por business_id (UNIQUE).
  Future<void> updateProfile({
    required String businessId,
    String? businessName,
    String? branchName,
    String? fiscalName,
    String? fiscalRnc,
    String? address,
    String? phone,
    String? email,
    String? slogan,
    String? ticketFooterMessage,
    bool? printLogoOnInvoice,
    bool? showSloganOnInvoice,
    bool? showBranchNameOnInvoice,
  }) async {
    String? normalize(String? v) {
      if (v == null) return null;
      final t = v.trim();
      return t.isEmpty ? null : t;
    }

    final businessPatch = <String, dynamic>{};
    if (businessName != null) businessPatch['business_name'] = normalize(businessName);
    if (branchName != null) businessPatch['branch_name'] = normalize(branchName);
    if (fiscalName != null) businessPatch['fiscal_name'] = normalize(fiscalName);
    if (fiscalRnc != null) businessPatch['fiscal_rnc'] = normalize(fiscalRnc);
    if (address != null) businessPatch['address'] = normalize(address);
    if (phone != null) businessPatch['phone'] = normalize(phone);
    if (email != null) businessPatch['email'] = normalize(email);
    if (slogan != null) businessPatch['slogan'] = normalize(slogan);
    if (ticketFooterMessage != null) {
      businessPatch['ticket_footer_message'] = normalize(ticketFooterMessage);
    }

    if (businessPatch.isNotEmpty) {
      await _client.from('businesses').update(businessPatch).eq('id', businessId);
    }

    final settingsPatch = <String, dynamic>{};
    if (printLogoOnInvoice != null) {
      settingsPatch['print_logo_on_invoice'] = printLogoOnInvoice;
    }
    if (showSloganOnInvoice != null) {
      settingsPatch['show_slogan_on_invoice'] = showSloganOnInvoice;
    }
    if (showBranchNameOnInvoice != null) {
      settingsPatch['show_branch_name_on_invoice'] = showBranchNameOnInvoice;
    }

    if (settingsPatch.isNotEmpty) {
      await _client.from('business_settings').upsert(
        {
          'business_id': businessId,
          ...settingsPatch,
        },
        onConflict: 'business_id',
      );
    }
  }

  /// Sube/sobrescribe el logo de la sucursal. [bytes] son los bytes del
  /// archivo (PNG o JPG, validar size ≤2MB y tipo en el caller).
  /// [extension] sin punto: 'png' o 'jpg'.
  ///
  /// Path final en Storage: `<business_id>/logo.<extension>`. Sobrescribe
  /// si existe (upsert=true). Devuelve la URL pública del logo y el path
  /// interno; ambos van a `businesses.logo_url` y `logo_storage_path`.
  Future<({String url, String path})> uploadLogo({
    required String businessId,
    required Uint8List bytes,
    required String extension,
  }) async {
    final ext = extension.toLowerCase().replaceAll('.', '');
    if (ext != 'png' && ext != 'jpg' && ext != 'jpeg') {
      throw Exception('Formato no soportado: $ext (solo png/jpg).');
    }
    final path = '$businessId/logo.$ext';
    final mime = ext == 'png' ? 'image/png' : 'image/jpeg';

    await _client.storage.from(logoBucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
            upsert: true,
            contentType: mime,
            // cacheControl bajo: cuando el operador cambie el logo,
            // queremos que el siguiente download lo agarre rapido sin
            // invalidaciones manuales. 60s es suficiente.
            cacheControl: '60',
          ),
        );

    final url = _client.storage.from(logoBucket).getPublicUrl(path);
    // Cache-buster para forzar refresh en consumidores que cachean por URL
    // (cached_network_image): cambiamos la query string en cada upload.
    final urlWithBuster = '$url?v=${DateTime.now().millisecondsSinceEpoch}';

    await _client
        .from('businesses')
        .update({'logo_url': urlWithBuster, 'logo_storage_path': path})
        .eq('id', businessId);

    return (url: urlWithBuster, path: path);
  }

  /// Borra el logo del bucket y limpia las columnas en businesses.
  /// Idempotente: si no hay logo, no falla.
  Future<void> deleteLogo(String businessId) async {
    final profile = await getProfile(businessId);
    final storagePath = profile?.logoStoragePath;
    if (storagePath != null && storagePath.isNotEmpty) {
      try {
        await _client.storage.from(logoBucket).remove([storagePath]);
      } catch (_) {
        // Silent fail: si el archivo no existe en Storage, igual limpiamos
        // las columnas de businesses para que el flujo de UI quede
        // consistente.
      }
    }
    await _client
        .from('businesses')
        .update({'logo_url': null, 'logo_storage_path': null})
        .eq('id', businessId);
  }

  /// Descarga los bytes del logo desde Storage. Util para impresion ESC/POS
  /// que necesita los bytes raw para convertir a raster. Retorna null si
  /// no hay logo configurado o si la descarga falla.
  ///
  /// Cachea por logo_url completo (incluye cache-buster). Cuando el
  /// operador cambia el logo, la URL cambia y la siguiente llamada
  /// re-descarga.
  Future<Uint8List?> downloadLogoBytes(String businessId) async {
    final profile = await getProfile(businessId);
    final url = profile?.logoUrl;
    final path = profile?.logoStoragePath;
    if (path == null || path.isEmpty) return null;

    if (url != null && _logoBytesCache.containsKey(url)) {
      return _logoBytesCache[url];
    }

    try {
      final bytes = await _client.storage.from(logoBucket).download(path);
      if (url != null) _logoBytesCache[url] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Helper de alto nivel para imprimir factura: trae profile + bytes
  /// ESC/POS del logo listos para `PrintTicketService.generateInvoice`.
  ///
  /// Si el negocio tiene `printLogoOnInvoice=false` o no tiene logo,
  /// `logoEscPosBytes` retorna null y la factura se imprime sin logo.
  /// Cachea los bytes ESC/POS por URL para evitar re-decodificar PNG en
  /// cada cobro/reimpresion del mismo logo.
  Future<({BusinessProfile? profile, List<int>? logoEscPosBytes})>
      prepareForInvoicePrinting(String businessId) async {
    final profile = await getProfile(businessId);
    if (profile == null) return (profile: null, logoEscPosBytes: null);

    final url = profile.logoUrl;
    if (!profile.printLogoOnInvoice || url == null || url.isEmpty) {
      return (profile: profile, logoEscPosBytes: null);
    }

    if (_logoEscPosCache.containsKey(url)) {
      return (profile: profile, logoEscPosBytes: _logoEscPosCache[url]);
    }

    final bytes = await downloadLogoBytes(businessId);
    if (bytes == null) return (profile: profile, logoEscPosBytes: null);

    final escPos = await LogoEscPosBuilder.build(bytes: bytes);
    if (escPos != null) _logoEscPosCache[url] = escPos;
    return (profile: profile, logoEscPosBytes: escPos);
  }
}
