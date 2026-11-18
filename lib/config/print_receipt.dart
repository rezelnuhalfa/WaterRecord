import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_classic_bluetooth/flutter_classic_bluetooth.dart';

import 'home_page.dart';

/// Cetak nota langsung ke printer thermal Bluetooth ESC/POS.
/// Printer CODESOFT HPM-200E menggunakan kertas 58 mm (area cetak 48 mm).
Future<void> printWaterReceipt(
  BuildContext context,
  Resident resident,
  WaterRecord record,
) async {
  final bluetooth = FlutterClassicBluetooth();

  try {
    final permission = await bluetooth.requestPermissions(
      permissions: {BtcPermission.scan, BtcPermission.connect},
    );

    if (permission != BtcPermissionStatus.granted &&
        permission != BtcPermissionStatus.notRequired) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Izin Perangkat di sekitar (Bluetooth) belum diberikan. Izinkan SCAN dan CONNECT, lalu coba cetak lagi.'),
          ),
        );
      }
      return;
    }

    final pairedDevices = await bluetooth.getPairedDevices();
    if (!context.mounted) return;

    if (pairedDevices.isEmpty) {
      _showMessage(
        context,
        'Printer belum dipasangkan',
        'Pasangkan CODESOFT HPM-200E terlebih dahulu melalui Pengaturan Bluetooth Android. Setelah statusnya Paired, kembali ke aplikasi dan tekan Cetak Nota.',
      );
      return;
    }

    final selectedDevice = await showDialog<dynamic>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Pilih Printer Bluetooth'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: pairedDevices.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final device = pairedDevices[index];
              final displayName = device.displayName?.toString().isNotEmpty == true
                  ? device.displayName.toString()
                  : 'Perangkat Bluetooth';
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.print_outlined),
                title: Text(displayName),
                subtitle: Text(device.address.toString()),
                onTap: () => Navigator.of(dialogContext).pop(device),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Batal'),
          ),
        ],
      ),
    );

    if (selectedDevice == null || !context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Menghubungkan ke printer...')),
    );

    final connection = await bluetooth.connect(
      address: selectedDevice.address.toString(),
      uuid: BtcUuid.spp,
      timeout: const Duration(seconds: 12),
    );

    try {
      final bytes = _buildHpm200eReceipt(resident, record);
      await connection.output.writeBytes(bytes);
      await connection.output.allSent;
      await connection.finish();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nota berhasil dikirim ke printer.')),
        );
      }
    } catch (_) {
      await connection.close();
      rethrow;
    }
  } on BtcTimeoutException {
    if (context.mounted) {
      _showMessage(
        context,
        'Koneksi timeout',
        'Printer tidak merespons. Pastikan HPM-200E menyala, sudah dipasangkan, berada dekat ponsel, dan tidak sedang terhubung ke perangkat lain.',
      );
    }
  } catch (error) {
    if (context.mounted) {
      _showMessage(
        context,
        'Gagal mencetak nota',
        'Periksa koneksi Bluetooth dan pastikan printer menyala. Detail: $error',
      );
    }
  }
}

List<int> _buildHpm200eReceipt(Resident resident, WaterRecord record) {
  const width = 32; // Font A pada printer 58 mm umumnya 32 karakter/baris.
  final bytes = <int>[
    0x1B, 0x40, // ESC @: initialize printer
    0x1B, 0x61, 0x01, // center alignment
    0x1B, 0x45, 0x01, // bold on
  ];

  _addText(bytes, 'NOTA PEMBAYARAN AIR\n');
  bytes.addAll([0x1B, 0x45, 0x00]); // bold off
  _addText(bytes, '${monthName(record.month)}\n');
  _addText(bytes, '${'='.padRight(width, '=')}\n');
  bytes.addAll([0x1B, 0x61, 0x00]); // left alignment

  _addWrappedField(bytes, 'ID', resident.id, width);
  _addWrappedField(bytes, 'Nama', resident.name, width);
  _addWrappedField(bytes, 'Alamat RT', 'RT ${resident.rt}', width);
  _addWrappedField(bytes, 'Bulan tagihan', monthName(record.month), width);
  _addWrappedField(bytes, 'Stan bulan lalu', '${record.previousMeter}', width);
  _addWrappedField(bytes, 'Stan bulan ini', '${record.currentMeter}', width);
  _addWrappedField(bytes, 'Pemakaian', '${record.usage} m3', width);

  _addText(bytes, '${'-'.padRight(width, '-')}\n');
  _addWrappedField(
    bytes,
    'TOTAL TAGIHAN',
    formatRupiah(record.total),
    width,
    bold: true,
  );
  _addWrappedField(bytes, 'Saldo digunakan', formatRupiah(record.creditUsed), width);
  _addWrappedField(bytes, 'Sudah dibayar', formatRupiah(record.paidAmount), width);
  _addWrappedField(bytes, 'Sisa tagihan', formatRupiah(record.remainingAmount), width);
  _addText(bytes, '${'-'.padRight(width, '-')}\n');

  bytes.addAll([0x1B, 0x61, 0x01]); // center alignment
  bytes.addAll([0x1B, 0x45, 0x01]);
  _addText(bytes, 'Terima kasih\n');
  bytes.addAll([0x1B, 0x45, 0x00]);
  _addText(bytes, '085607274272\n');
  _addText(bytes, '\n\n\n'); // feed paper; HPM-200E uses manual tear-off

  return bytes;
}

void _addWrappedField(
  List<int> output,
  String label,
  String value,
  int width, {
  bool bold = false,
}) {
  final safeLabel = _printerSafe(label);
  final safeValue = _printerSafe(value);
  final prefix = '$safeLabel: ';
  final available = width - prefix.length;
  final lines = <String>[];
  var remaining = safeValue;

  if (remaining.isEmpty) remaining = '-';
  if (remaining.length <= available) {
    lines.add(prefix + remaining);
  } else {
    lines.add(prefix + remaining.substring(0, available));
    remaining = remaining.substring(available);
    while (remaining.isNotEmpty) {
      final take = remaining.length > width ? width : remaining.length;
      lines.add('  ${remaining.substring(0, take)}');
      remaining = remaining.substring(take);
    }
  }

  if (bold) output.addAll([0x1B, 0x45, 0x01]);
  for (final line in lines) {
    _addText(output, '$line\n');
  }
  if (bold) output.addAll([0x1B, 0x45, 0x00]);
}

String _printerSafe(String value) {
  return value
      .replaceAll('³', '3')
      .replaceAll('–', '-')
      .replaceAll('—', '-')
      .replaceAll('’', "'")
      .replaceAll('“', '"')
      .replaceAll('”', '"');
}

void _addText(List<int> output, String text) {
  // Isi nota Indonesia umumnya ASCII. Latin-1 menjaga karakter dasar tetap
  // kompatibel dengan printer ESC/POS; karakter di luar Latin-1 diganti '?'.
  final safe = text.runes
      .map((rune) => rune <= 255 ? String.fromCharCode(rune) : '?')
      .join();
  output.addAll(latin1.encode(safe));
}

void _showMessage(BuildContext context, String title, String message) {
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
