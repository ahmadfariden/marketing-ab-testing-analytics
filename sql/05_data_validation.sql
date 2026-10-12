-- ============================================================================
-- FILE:        sql/05_data_validation.sql
-- TAHAP:       Tahap 6 (Inti)
-- TUJUAN:      Data Validation & KPI Lock
-- ============================================================================
-- GRAIN:       TODO (1 baris = 1 user / 1 segmen / 1 grup / 1 bucket ...)
-- POPULATION:  TODO (sebutkan flag yang dipakai, mis. is_valid_user = TRUE)
-- DENOMINATOR: TODO (Valid Analysis Population per grup: n_ad = ..., n_psa = ...)
-- ============================================================================
-- Jalankan (PowerShell, dari root folder proyek):
--   .\duckdb.exe ab_testing.duckdb -c ".read sql/05_data_validation.sql"
-- Gunakan: .mode markdown   (supaya semua tabel hasil terlihat isinya)
--
-- Guard wajib: tampilkan n + jumlah konversi di samping setiap rate;
-- rekonsiliasi SUM(n) tiap GROUP BY ke ukuran populasi per grup;
-- beri penanda is_small_segment untuk sel di bawah ambang D5.
-- ============================================================================

.mode markdown

-- TODO: validasi populasi & KPI; hitung batas bucket; lock D1-D9 (lalu git tag kpi-lock)
