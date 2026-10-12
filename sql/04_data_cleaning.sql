-- ============================================================================
-- FILE:        sql/04_data_cleaning.sql
-- TAHAP:       Tahap 5 (Inti)
-- TUJUAN:      Data Cleaning: raw -> clean table
-- ============================================================================
-- GRAIN:       TODO (1 baris = 1 user / 1 segmen / 1 grup / 1 bucket ...)
-- POPULATION:  TODO (sebutkan flag yang dipakai, mis. is_valid_user = TRUE)
-- DENOMINATOR: TODO (Valid Analysis Population per grup: n_ad = ..., n_psa = ...)
-- ============================================================================
-- Jalankan (PowerShell, dari root folder proyek):
--   .\duckdb.exe ab_testing.duckdb -c ".read sql/04_data_cleaning.sql"
-- Gunakan: .mode markdown   (supaya semua tabel hasil terlihat isinya)
--
-- Guard wajib: tampilkan n + jumlah konversi di samping setiap rate;
-- rekonsiliasi SUM(n) tiap GROUP BY ke ukuran populasi per grup;
-- beri penanda is_small_segment untuk sel di bawah ambang D5.
-- ============================================================================

.mode markdown

-- TODO: casting eksplisit, flag is_valid_user, rekonsiliasi raw -> cleaned
