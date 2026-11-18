import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'home_page.dart';
import 'supabase_config.dart';

/// Pengganti LocalDatabase. Datanya sekarang ada di Supabase,
/// jadi bisa dibaca dan disimpan dari beberapa HP.
class CloudDatabase {
  static const String residentsTable = 'residents';
  static const String recordsTable = 'water_records';
  static const String photoBucket = 'resident-photos';

  static const String _legacyKey = 'data_air_warga';
  static const String _migratedFlagKey = 'migrated_to_supabase_v1';
  static const String _migratedIdsKey = 'migrated_old_resident_ids_v1';

  /// Dipakai MaterialApp supaya pesan error bisa tampil dari mana saja.
  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  static SupabaseClient get _db => Supabase.instance.client;

  // ---------------------------------------------------------------------------
  // Inisialisasi + login anonim (tanpa halaman login)
  // ---------------------------------------------------------------------------

  static Future<void> init() async {
    await Supabase.initialize(
      url: SupabaseConfig.supabaseUrl,
      anonKey: SupabaseConfig.supabasePublishableKey,
    );

    try {
      await ensureSignedIn();
      await _migrateLocalDataIfNeeded();
    } catch (_) {
      // Tidak ada internet saat start: aplikasi tetap dibuka.
    }

    _startRealtime();
  }

  static Future<void> ensureSignedIn() async {
    if (_db.auth.currentSession != null) return;
    await _db.auth.signInAnonymously();
  }

  // ---------------------------------------------------------------------------
  // ID
  // ---------------------------------------------------------------------------

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static bool _isUuid(String value) => _uuidPattern.hasMatch(value);

  /// ID baru berbentuk UUID (aman untuk kolom bertipe uuid maupun text).
  static String newId() {
    final random = Random.secure();
    final b = List<int>.generate(16, (_) => random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;

    String hex(int start, int end) => b
        .sublist(start, end)
        .map((x) => x.toRadixString(16).padLeft(2, '0'))
        .join();

    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }

  // ---------------------------------------------------------------------------
  // Konversi baris database <-> model
  // ---------------------------------------------------------------------------

  static int _int(dynamic v) {
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static String? _nullIfEmpty(dynamic v) {
    final s = v?.toString();
    return (s == null || s.isEmpty) ? null : s;
  }

  static Map<String, dynamic> _residentRow(Resident r) => {
        'id': r.id,
        'name': r.name,
        'rt': r.rt,
        'photo_path': r.photoPath,
      };

  static Map<String, dynamic> _recordRow(String residentId, WaterRecord r) {
    final recorded = DateTime.tryParse(r.recordedAt);

    return {
      'resident_id': residentId,
      'month': r.month,
      'previous_meter': r.previousMeter,
      'current_meter': r.currentMeter,
      'usage': r.usage,
      'water_price': r.waterPrice,
      'monthly_fee': r.monthlyFee,
      'total': r.total,
      'paid_amount': r.paidAmount,
      'credit_used': r.creditUsed,
      'status': r.status,
      'recorded_at':
          recorded?.toUtc().toIso8601String() ?? r.recordedAt,
    };
  }

  static WaterRecord _recordFromRow(Map<String, dynamic> row) {
    final recorded = DateTime.tryParse(row['recorded_at']?.toString() ?? '');

    return WaterRecord.fromJson({
      'month': row['month'],
      'previousMeter': _int(row['previous_meter']),
      'currentMeter': _int(row['current_meter']),
      'usage': _int(row['usage']),
      'waterPrice': _int(row['water_price']),
      'monthlyFee': row['monthly_fee'] == null
          ? ABODEMEN
          : _int(row['monthly_fee']),
      'total': _int(row['total']),
      'paidAmount': _int(row['paid_amount']),
      'creditUsed': _int(row['credit_used']),
      'status': row['status'],
      'recordedAt': recorded?.toLocal().toIso8601String(),
    });
  }

  // ---------------------------------------------------------------------------
  // Baca data
  // ---------------------------------------------------------------------------

  static List<Resident>? _lastGood;

  static Future<List<Map<String, dynamic>>> _fetchAll(String table) async {
    // Supabase hanya mengirim maksimal 1000 baris per permintaan.
    const pageSize = 1000;
    final all = <Map<String, dynamic>>[];
    var from = 0;

    while (true) {
      final rows = await _db
          .from(table)
          .select()
          .order('id')
          .range(from, from + pageSize - 1);

      all.addAll(rows.map((e) => Map<String, dynamic>.from(e)));
      if (rows.length < pageSize) break;
      from += pageSize;
    }

    return all;
  }

  static Future<List<Resident>> getResidents() async {
    try {
      await ensureSignedIn();

      final residentRows = await _fetchAll(residentsTable);
      final recordRows = await _fetchAll(recordsTable);

      final recordsByResident = <String, List<WaterRecord>>{};
      for (final row in recordRows) {
        final residentId = row['resident_id']?.toString();
        if (residentId == null) continue;
        (recordsByResident[residentId] ??= []).add(_recordFromRow(row));
      }

      // Urutan sama seperti saat disimpan: yang lebih dulu dibuat di atas.
      residentRows.sort((a, b) {
        final ca = a['created_at']?.toString();
        final cb = b['created_at']?.toString();
        if (ca != null && cb != null) {
          final c = ca.compareTo(cb);
          if (c != 0) return c;
        }
        return (a['name'] ?? '')
            .toString()
            .toLowerCase()
            .compareTo((b['name'] ?? '').toString().toLowerCase());
      });

      final residents = residentRows.map((row) {
        final id = row['id'].toString();
        final records = recordsByResident[id] ?? <WaterRecord>[];
        records.sort((a, b) => a.month.compareTo(b.month));

        return Resident(
          id: id,
          name: row['name']?.toString() ?? '',
          rt: row['rt']?.toString() ?? '',
          photoPath: _nullIfEmpty(row['photo_path']),
          records: records,
        );
      }).toList();

      _lastGood = residents;
      return residents;
    } catch (e) {
      _notifyError('Tidak bisa mengambil data dari server.', e);
      return _lastGood ?? [];
    }
  }

  // ---------------------------------------------------------------------------
  // Simpan data
  // ---------------------------------------------------------------------------

  /// Menyimpan SATU warga beserta catatan meterannya.
  /// Foto lokal (path diawali "/") otomatis diunggah ke Storage.
  static Future<void> saveResident(Resident resident) async {
    try {
      await _saveResidentOrThrow(resident);
    } catch (e) {
      _notifyError('Gagal menyimpan ke server.', e);
    }
  }

  static Future<void> _saveResidentOrThrow(Resident resident) async {
    await ensureSignedIn();

    String? oldPhotoToRemove;
    final photo = resident.photoPath;

    if (photo != null && photo.startsWith('/')) {
      final file = File(photo);

      if (await file.exists()) {
        final storagePath =
            '${resident.id}/${DateTime.now().millisecondsSinceEpoch}.jpg';

        await _db.storage.from(photoBucket).upload(
              storagePath,
              file,
              fileOptions: const FileOptions(
                contentType: 'image/jpeg',
                upsert: true,
              ),
            );

        try {
          final old = await _db
              .from(residentsTable)
              .select('photo_path')
              .eq('id', resident.id)
              .maybeSingle();
          oldPhotoToRemove = _nullIfEmpty(old?['photo_path']);
        } catch (_) {}

        resident.photoPath = storagePath;
      } else {
        resident.photoPath = null;
      }
    }

    await _db.from(residentsTable).upsert(_residentRow(resident));

    if (resident.records.isNotEmpty) {
      await _db.from(recordsTable).upsert(
            resident.records
                .map((record) => _recordRow(resident.id, record))
                .toList(),
            onConflict: 'resident_id,month',
          );
    }

    if (oldPhotoToRemove != null &&
        oldPhotoToRemove != resident.photoPath &&
        !oldPhotoToRemove.startsWith('/')) {
      try {
        await _db.storage.from(photoBucket).remove([oldPhotoToRemove]);
      } catch (_) {}
    }
  }

  static Future<void> deleteRecord(String residentId, String month) async {
    try {
      await ensureSignedIn();
      await _db
          .from(recordsTable)
          .delete()
          .eq('resident_id', residentId)
          .eq('month', month);
    } catch (e) {
      _notifyError('Gagal menghapus di server.', e);
    }
  }

  static Future<void> deleteResident(Resident resident) async {
    try {
      await ensureSignedIn();

      await _db.from(recordsTable).delete().eq('resident_id', resident.id);
      await _db.from(residentsTable).delete().eq('id', resident.id);

      final photo = resident.photoPath;
      if (photo != null && !photo.startsWith('/')) {
        try {
          await _db.storage.from(photoBucket).remove([photo]);
        } catch (_) {}
      }
    } catch (e) {
      _notifyError('Gagal menghapus di server.', e);
    }
  }

  // ---------------------------------------------------------------------------
  // Foto (bucket private -> pakai signed URL)
  // ---------------------------------------------------------------------------

  static final Map<String, _CachedUrl> _urlCache = {};

  static Future<String?> photoUrl(String storagePath) {
    final cached = _urlCache[storagePath];
    if (cached != null &&
        DateTime.now().difference(cached.createdAt) <
            const Duration(hours: 5)) {
      return cached.future;
    }

    final future = () async {
      try {
        await ensureSignedIn();
        return await _db.storage
            .from(photoBucket)
            .createSignedUrl(storagePath, 6 * 60 * 60);
      } catch (_) {
        _urlCache.remove(storagePath);
        return null;
      }
    }();

    _urlCache[storagePath] = _CachedUrl(future, DateTime.now());
    return future;
  }

  // ---------------------------------------------------------------------------
  // Uang tunai hari ini (tetap disimpan di HP ini, tidak berubah)
  // ---------------------------------------------------------------------------

  static String get _todayCashKey {
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    return 'cash_tunai_$date';
  }

  static Future<int> getTodayCash() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_todayCashKey) ?? 0;
  }

  static Future<void> setTodayCash(int amount) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_todayCashKey, amount);
  }

  // ---------------------------------------------------------------------------
  // Realtime: perubahan dari HP lain muncul otomatis
  // ---------------------------------------------------------------------------

  static final StreamController<void> _changes =
      StreamController<void>.broadcast();

  static Stream<void> get changes => _changes.stream;

  static Timer? _debounce;
  static RealtimeChannel? _channel;

  static void _startRealtime() {
    if (_channel != null) return;

    void onChange(PostgresChangePayload payload) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 700), () {
        _changes.add(null);
      });
    }

    _channel = _db
        .channel('data-air-changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: residentsTable,
          callback: onChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: recordsTable,
          callback: onChange,
        )
        .subscribe();
  }

  // ---------------------------------------------------------------------------
  // Pindah data lama (SharedPreferences) ke Supabase, satu kali
  // ---------------------------------------------------------------------------

  static Future<void> _migrateLocalDataIfNeeded() async {
    if (!SupabaseConfig.migrateLocalData) return;

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_migratedFlagKey) == true) return;

    final raw = prefs.getString(_legacyKey);
    if (raw == null || raw.isEmpty) {
      await prefs.setBool(_migratedFlagKey, true);
      return;
    }

    List<Resident> legacy;
    try {
      legacy = (jsonDecode(raw) as List)
          .map((e) => Resident.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return;
    }

    final doneIds = (prefs.getStringList(_migratedIdsKey) ?? <String>[]).toSet();

    for (final resident in legacy) {
      final oldId = resident.id;
      if (doneIds.contains(oldId)) continue;

      if (!_isUuid(resident.id)) resident.id = newId();

      await _saveResidentOrThrow(resident);

      doneIds.add(oldId);
      await prefs.setStringList(_migratedIdsKey, doneIds.toList());
    }

    // Data lama sengaja tidak dihapus dari HP, sebagai cadangan.
    await prefs.setBool(_migratedFlagKey, true);
  }

  // ---------------------------------------------------------------------------

  static void _notifyError(String message, [Object? error]) {
    debugPrint('CloudDatabase error: $message $error');

    final messenger = messengerKey.currentState;
    if (messenger == null) return;

    final detail = error == null ? '' : '\n$error';

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('$message$detail'),
          duration: const Duration(seconds: 12),
        ),
      );
  }
}

class _CachedUrl {
  final Future<String?> future;
  final DateTime createdAt;

  _CachedUrl(this.future, this.createdAt);
}