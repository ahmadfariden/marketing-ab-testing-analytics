-- ============================================================================
-- FILE:        sql/10_time_segments.sql
-- TAHAP:       Tahap 11 (Lanjutan)
-- TUJUAN:      Time Segments (hari & blok waktu)
-- ============================================================================
-- GRAIN:       TODO (1 baris = 1 user / 1 segmen / 1 grup / 1 bucket ...)
-- POPULATION:  TODO (sebutkan flag yang dipakai, mis. is_valid_user = TRUE)
-- DENOMINATOR: TODO (Valid Analysis Population per grup: n_ad = ..., n_psa = ...)
-- ============================================================================
-- Jalankan (PowerShell, dari root folder proyek):
--   .\duckdb.exe ab_testing.duckdb -c ".read sql/10_time_segments.sql"
-- Gunakan: .mode markdown   (supaya semua tabel hasil terlihat isinya)
--
-- Guard wajib: tampilkan n + jumlah konversi di samping setiap rate;
-- rekonsiliasi SUM(n) tiap GROUP BY ke ukuran populasi per grup;
-- beri penanda is_small_segment untuk sel di bawah ambang D5.
-- ============================================================================

.mode markdown

-- TODO: CR per hari, 4 blok waktu, pola 24 jam deskriptif (D6)
