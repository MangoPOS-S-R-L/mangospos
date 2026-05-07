// lib/data/models/business_profile.dart
//
// Snapshot agregado del perfil editable de una sucursal: combina campos
// de `businesses` (datos identitarios + branding: logo, slogan, footer)
// con flags de `business_settings` (toggles de impresion).
//
// Source of truth para los headers/footers de la representacion impresa
// (factura y pre-cuenta). Mantener este modelo alineado con la migration
// 20260507_0001 y con BusinessProfileRepository.

class BusinessProfile {
  // ─── businesses ───────────────────────────────────────────────────────
  final String id;
  final String? businessName;
  final String? branchName;
  final String? fiscalName;
  final String? fiscalRnc;
  final String? address;
  final String? phone;
  final String? email;

  // Branding (ver migration 20260507_0001).
  final String? logoUrl;
  final String? logoStoragePath;
  final String? slogan;
  final String? ticketFooterMessage;

  // ─── business_settings ────────────────────────────────────────────────
  final bool printLogoOnInvoice;
  final bool showSloganOnInvoice;
  final bool showBranchNameOnInvoice;

  const BusinessProfile({
    required this.id,
    this.businessName,
    this.branchName,
    this.fiscalName,
    this.fiscalRnc,
    this.address,
    this.phone,
    this.email,
    this.logoUrl,
    this.logoStoragePath,
    this.slogan,
    this.ticketFooterMessage,
    this.printLogoOnInvoice = false,
    this.showSloganOnInvoice = true,
    this.showBranchNameOnInvoice = true,
  });

  /// Construye desde un map que combina columnas de businesses +
  /// business_settings (resultado del select join del repo).
  factory BusinessProfile.fromMap(Map<String, dynamic> m) => BusinessProfile(
        id: (m['id'] ?? '') as String,
        businessName: m['business_name'] as String?,
        branchName: m['branch_name'] as String?,
        fiscalName: m['fiscal_name'] as String?,
        fiscalRnc: m['fiscal_rnc'] as String?,
        address: m['address'] as String?,
        phone: m['phone'] as String?,
        email: m['email'] as String?,
        logoUrl: m['logo_url'] as String?,
        logoStoragePath: m['logo_storage_path'] as String?,
        slogan: m['slogan'] as String?,
        ticketFooterMessage: m['ticket_footer_message'] as String?,
        printLogoOnInvoice: (m['print_logo_on_invoice'] as bool?) ?? false,
        showSloganOnInvoice: (m['show_slogan_on_invoice'] as bool?) ?? true,
        showBranchNameOnInvoice:
            (m['show_branch_name_on_invoice'] as bool?) ?? true,
      );

  BusinessProfile copyWith({
    String? businessName,
    String? branchName,
    String? fiscalName,
    String? fiscalRnc,
    String? address,
    String? phone,
    String? email,
    String? logoUrl,
    String? logoStoragePath,
    String? slogan,
    String? ticketFooterMessage,
    bool? printLogoOnInvoice,
    bool? showSloganOnInvoice,
    bool? showBranchNameOnInvoice,
  }) {
    return BusinessProfile(
      id: id,
      businessName: businessName ?? this.businessName,
      branchName: branchName ?? this.branchName,
      fiscalName: fiscalName ?? this.fiscalName,
      fiscalRnc: fiscalRnc ?? this.fiscalRnc,
      address: address ?? this.address,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      logoUrl: logoUrl ?? this.logoUrl,
      logoStoragePath: logoStoragePath ?? this.logoStoragePath,
      slogan: slogan ?? this.slogan,
      ticketFooterMessage: ticketFooterMessage ?? this.ticketFooterMessage,
      printLogoOnInvoice: printLogoOnInvoice ?? this.printLogoOnInvoice,
      showSloganOnInvoice: showSloganOnInvoice ?? this.showSloganOnInvoice,
      showBranchNameOnInvoice:
          showBranchNameOnInvoice ?? this.showBranchNameOnInvoice,
    );
  }
}
