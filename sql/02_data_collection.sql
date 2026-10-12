-- ============================================================================
-- FILE:        sql/02_data_collection.sql
-- TAHAP:       Tahap 2 (Inti)
-- TUJUAN:      Data Collection: ingestion CSV mentah ke DuckDB sebagai raw_marketing_ab
-- ============================================================================
-- GRAIN:       1 baris = 1 baris file CSV mentah (belum dianggap 1 user; keunikan user_id diuji di Tahap 4)
-- POPULATION:  Seluruh baris file, tanpa filter apa pun (raw preserved)
-- DENOMINATOR: Tidak ada metrik rate di tahap ini; yang dicatat hanya jumlah baris dan kolom
-- ============================================================================
-- Jalankan (PowerShell, dari root folder proyek):
--   .\duckdb.exe ab_testing.duckdb -c ".read sql/02_data_collection.sql"
--
-- Prasyarat: file data/raw/marketing_AB.csv sudah ada (download manual dari Kaggle).
-- ============================================================================
-- RAW DATA GOVERNANCE
--   * File raw read-only; tidak pernah ditimpa proses cleaning.
--   * Semua kolom dimuat sebagai VARCHAR (ALL_VARCHAR = TRUE); casting eksplisit di Tahap 5.
--   * Nama kolom TIDAK diubah di sini (rename ke snake_case dilakukan di Tahap 5).
--   * Kolom pertama CSV (indeks bawaan, tanpa nama) adalah ROW INDEX, bukan user_id.
--   * Proses berikutnya membaca dari raw_marketing_ab, bukan dari CSV langsung.
-- ============================================================================
-- SUMBER DATA
--   URL     : https://www.kaggle.com/datasets/faviovaz/marketing-ab-testing
--   File    : marketing_AB.csv
--   Diambil : 2026-10-12
--   Lisensi : TODO - verifikasi di halaman Kaggle sebelum publish (isi di README)
-- ============================================================================

.mode markdown

-- ----------------------------------------------------------------------------
-- 1. Verifikasi file sumber: ukuran (byte) dan jumlah baris data
--    (jumlah baris file = jumlah newline, +1 jika baris terakhir tanpa newline;
--     dikurangi 1 baris header)
-- ----------------------------------------------------------------------------
SELECT
    'file_check'                                                              AS check_name,
    filename                                                                  AS file_name,
    size                                                                      AS file_size_bytes,
    (length(content) - length(replace(content, chr(10), '')))
        + CASE WHEN right(content, 1) = chr(10) THEN 0 ELSE 1 END             AS total_lines_in_file,
    (length(content) - length(replace(content, chr(10), '')))
        + CASE WHEN right(content, 1) = chr(10) THEN 0 ELSE 1 END - 1         AS data_rows_in_file
FROM read_text('data/raw/marketing_AB.csv');

-- ----------------------------------------------------------------------------
-- 2. Ingestion: semua kolom sebagai VARCHAR
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE raw_marketing_ab AS
SELECT *
FROM read_csv('data/raw/marketing_AB.csv', header = true, ALL_VARCHAR = TRUE);

-- ----------------------------------------------------------------------------
-- 3. Struktur tabel: nama kolom dan tipe (semua harus VARCHAR)
-- ----------------------------------------------------------------------------
DESCRIBE raw_marketing_ab;

-- ----------------------------------------------------------------------------
-- 4. Rekonsiliasi: jumlah baris tabel harus sama dengan jumlah baris data di file
-- ----------------------------------------------------------------------------
WITH f AS (
    SELECT
        (length(content) - length(replace(content, chr(10), '')))
            + CASE WHEN right(content, 1) = chr(10) THEN 0 ELSE 1 END - 1 AS data_rows_in_file
    FROM read_text('data/raw/marketing_AB.csv')
),
t AS (
    SELECT COUNT(*) AS rows_in_table FROM raw_marketing_ab
),
c AS (
    SELECT COUNT(*) AS n_columns
    FROM information_schema.columns
    WHERE table_name = 'raw_marketing_ab'
)
SELECT
    'row_reconciliation'                                   AS check_name,
    f.data_rows_in_file,
    t.rows_in_table,
    c.n_columns,
    CASE WHEN f.data_rows_in_file = t.rows_in_table
         THEN 'MATCH' ELSE 'MISMATCH' END                  AS status
FROM f, t, c;

-- ----------------------------------------------------------------------------
-- 5. Sampel 5 baris pertama (cek sekilas bentuk data & kolom row index)
-- ----------------------------------------------------------------------------
SELECT * FROM raw_marketing_ab LIMIT 5;
