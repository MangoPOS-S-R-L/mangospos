import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mangopos/data/models/printing_models.dart';

class PrinterSelectionDialog extends StatelessWidget {
  final List<PrinterDevice> printers;

  const PrinterSelectionDialog({super.key, required this.printers});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 350,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Seleccionar Impresora',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF111111),
              ),
            ),
            const SizedBox(height: 16),
            if (printers.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    'No hay impresoras disponibles',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: printers.length,
                  separatorBuilder: (_, index) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final printer = printers[index];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.grey[100],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.print,
                          color: Color(0xFFF97316),
                        ),
                      ),
                      title: Text(
                        printer.name,
                        style: GoogleFonts.inter(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        printer.ip ?? 'Sin IP',
                        style: GoogleFonts.inter(fontSize: 12),
                      ),
                      trailing: printer.online
                          ? const Icon(
                              Icons.check_circle,
                              color: const Color(0xFF22C55E),
                              size: 16,
                            )
                          : const Icon(
                              Icons.error_outline,
                              color: Colors.grey,
                              size: 16,
                            ),
                      onTap: () {
                        Navigator.pop(context, printer);
                      },
                    );
                  },
                ),
              ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'Cancelar',
                  style: GoogleFonts.inter(
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
