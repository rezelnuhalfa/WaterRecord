class SupabaseConfig {
  static const String supabaseUrl =
      'https://ohbklvwhfxuwfgextxuz.supabase.co';

  static const String supabasePublishableKey =
      'sb_publishable_D4-FgnwiUkFgRc-1apuF7Q_cGUzpBzJ';

  /// Pindahkan data lama (SharedPreferences di HP ini) ke Supabase satu kali.
  ///
  /// Nyalakan (true) HANYA di HP yang berisi data asli. Di HP lain yang
  /// datanya sama atau hanya data coba-coba, ubah ke false supaya data
  /// tidak terdobel.
  static const bool migrateLocalData = true;
}
