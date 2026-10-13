-- ============================================================================
-- FILE:        sql/05_data_validation.sql
-- TAHAP:       Tahap 6 (Inti)
-- TUJUAN:      Data Validation & KPI Lock: validasi struktur, desain eksperimen, dan konsistensi KPI
-- ============================================================================
-- GRAIN:       validation_summary: 1 baris = 1 pemeriksaan. Query detail: 1 baris = 1 grup / 1 bucket / 1 kategori.
-- POPULATION:  Valid Analysis Population (is_valid_user = TRUE) untuk pemeriksaan eksperimen dan KPI;
--              Raw Population untuk pemeriksaan rekonsiliasi.
-- DENOMINATOR: Valid Analysis Population per grup (n_ad = is_treatment, n_psa = is_control).
--              CR per grup TIDAK dihitung di sini (Tahap 7-9).
-- ============================================================================
-- Jalankan (PowerShell, dari root folder proyek):
--   .\duckdb.exe ab_testing.duckdb -c ".read sql/05_data_validation.sql"
--
-- Prasyarat: sql/04_data_cleaning.sql sudah dijalankan (marketing_ab_clean, stg_marketing_ab).
--
-- Pemeriksaan membandingkan hasil tabel clean dengan hitungan langsung dari raw_marketing_ab
-- (sumber independen), bukan membandingkan clean dengan dirinya sendiri.
--
-- Primary KPI (dikunci, lihat docs/methodology.md):
--   CR = jumlah user konversi / jumlah user valid dalam grup
-- ============================================================================

.mode markdown
.maxrows 1000

-- ----------------------------------------------------------------------------
-- 0. Persiapan: batas kuantil D4 dihitung independen dari RAW (tanpa converted)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW v_raw_cut AS
SELECT
    quantile_cont(TRY_CAST("total ads" AS DOUBLE), 0.50) AS p50,
    quantile_cont(TRY_CAST("total ads" AS DOUBLE), 0.75) AS p75,
    quantile_cont(TRY_CAST("total ads" AS DOUBLE), 0.90) AS p90,
    quantile_cont(TRY_CAST("total ads" AS DOUBLE), 0.99) AS p99
FROM raw_marketing_ab;

-- ----------------------------------------------------------------------------
-- 1. validation_summary: seluruh pemeriksaan (expected vs actual)
--    expected = hitungan independen dari raw / nilai yang seharusnya
--    actual   = nilai dari marketing_ab_clean
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE validation_summary AS
WITH chk(check_id, category, check_name, expected, actual) AS (

    -- ---------- STRUCTURAL ----------
    SELECT 'S01', 'Structural', 'Row count: raw = stg',
        (SELECT COUNT(*) FROM raw_marketing_ab)::BIGINT,
        (SELECT COUNT(*) FROM stg_marketing_ab)::BIGINT
    UNION ALL
    SELECT 'S02', 'Structural', 'Row count: raw = clean',
        (SELECT COUNT(*) FROM raw_marketing_ab)::BIGINT,
        (SELECT COUNT(*) FROM marketing_ab_clean)::BIGINT
    UNION ALL
    SELECT 'S03', 'Structural', 'Grain: user_id unik di Valid Analysis Population (distinct = jumlah baris)',
        (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user)::BIGINT,
        (SELECT COUNT(DISTINCT user_id) FROM marketing_ab_clean WHERE is_valid_user)::BIGINT
    UNION ALL
    SELECT 'S04', 'Structural', 'Kegagalan cast tak terduga (nilai raw terisi, hasil cast NULL) = 0',
        0::BIGINT,
        (SELECT COUNT(*)
           FROM raw_marketing_ab r
           JOIN stg_marketing_ab s ON TRY_CAST(r.column0 AS BIGINT) = s.row_index
          WHERE (trim(r."user id") <> '' AND s.user_id IS NULL)
             OR (trim(r.converted) <> '' AND s.converted IS NULL)
             OR (trim(r."total ads") <> '' AND s.total_ads IS NULL)
             OR (trim(r."most ads hour") <> '' AND s.most_ads_hour IS NULL))::BIGINT

    -- ---------- EXPERIMENT ----------
    UNION ALL
    SELECT 'E01', 'Experiment', 'Tidak ada user_id di lebih dari satu kelompok (Valid Analysis Population)',
        0::BIGINT,
        (SELECT COUNT(*) FROM (
            SELECT user_id FROM marketing_ab_clean WHERE is_valid_user
            GROUP BY user_id HAVING COUNT(DISTINCT test_group) > 1))::BIGINT
    UNION ALL
    SELECT 'E02', 'Experiment', 'Outcome converted lengkap (NULL di populasi valid) = 0',
        0::BIGINT,
        (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND converted IS NULL)::BIGINT
    UNION ALL
    SELECT 'E03', 'Experiment', 'test_group di populasi valid hanya ad/psa (baris di luar itu) = 0',
        0::BIGINT,
        (SELECT COUNT(*) FROM marketing_ab_clean
          WHERE is_valid_user AND (test_group IS NULL OR test_group NOT IN ('ad','psa')))::BIGINT
    UNION ALL
    SELECT 'E04', 'Experiment', 'Jumlah nilai test_group berbeda di populasi valid = 2',
        2::BIGINT,
        (SELECT COUNT(DISTINCT test_group) FROM marketing_ab_clean WHERE is_valid_user)::BIGINT
    UNION ALL
    SELECT 'E05', 'Experiment', 'Denominator grup ad: hitungan raw = SUM(is_treatment) populasi valid',
        (SELECT COUNT(*) FROM raw_marketing_ab WHERE "test group" = 'ad')::BIGINT,
        (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND is_treatment)::BIGINT
    UNION ALL
    SELECT 'E06', 'Experiment', 'Denominator grup psa: hitungan raw = SUM(is_control) populasi valid',
        (SELECT COUNT(*) FROM raw_marketing_ab WHERE "test group" = 'psa')::BIGINT,
        (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND is_control)::BIGINT

    -- ---------- BUSINESS ----------
    UNION ALL
    SELECT 'B01', 'Business', 'SUM(is_treatment) + SUM(is_control) = COUNT(is_valid_user = TRUE)',
        (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user)::BIGINT,
        (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND is_treatment)::BIGINT
        + (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND is_control)::BIGINT
    UNION ALL
    SELECT 'B02', 'Business', 'Konversi grup ad: hitungan raw (converted = True) = SUM(is_converted) clean',
        (SELECT COUNT(*) FROM raw_marketing_ab WHERE "test group" = 'ad' AND converted = 'True')::BIGINT,
        (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND is_treatment AND is_converted)::BIGINT
    UNION ALL
    SELECT 'B03', 'Business', 'Konversi grup psa: hitungan raw (converted = True) = SUM(is_converted) clean',
        (SELECT COUNT(*) FROM raw_marketing_ab WHERE "test group" = 'psa' AND converted = 'True')::BIGINT,
        (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND is_control AND is_converted)::BIGINT
    UNION ALL
    SELECT 'B04', 'Business', 'Rekonsiliasi: raw rows = valid + baris dikeluarkan',
        (SELECT COUNT(*) FROM raw_marketing_ab)::BIGINT,
        (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user)::BIGINT
        + (SELECT COUNT(*) FROM marketing_ab_clean WHERE NOT is_valid_user)::BIGINT

    -- ---------- LOCK: D3 ----------
    UNION ALL
    SELECT 'L01', 'Lock D3', 'Baris dengan user_id berulang (flag_duplicate_user_id) = 0 -> D3 tidak berlaku',
        0::BIGINT,
        (SELECT COUNT(*) FROM marketing_ab_clean WHERE flag_duplicate_user_id)::BIGINT
    UNION ALL
    SELECT 'L02', 'Lock D3', 'Baris dikeluarkan karena D3 (konflik grup atau duplikat tidak terpilih) = 0',
        0::BIGINT,
        (SELECT COUNT(*) FROM marketing_ab_clean
          WHERE exclusion_reason IN ('d3b_group_conflict', 'd3ac_duplicate_row_not_selected'))::BIGINT

    -- ---------- LOCK: D4 ----------
    UNION ALL
    SELECT 'L03', 'Lock D4', 'exposure_bucket di clean = bucket dari kuantil yang dihitung ulang dari raw (selisih)',
        0::BIGINT,
        (SELECT COUNT(*)
           FROM marketing_ab_clean c
           JOIN raw_marketing_ab r ON c.row_index = TRY_CAST(r.column0 AS BIGINT)
           CROSS JOIN v_raw_cut k
          WHERE c.exposure_bucket IS DISTINCT FROM
                CASE
                    WHEN TRY_CAST(r."total ads" AS DOUBLE) IS NULL OR TRY_CAST(r."total ads" AS DOUBLE) < 0 THEN NULL
                    WHEN TRY_CAST(r."total ads" AS DOUBLE) <= k.p50 THEN 'b1_le_p50'
                    WHEN TRY_CAST(r."total ads" AS DOUBLE) <= k.p75 THEN 'b2_p50_p75'
                    WHEN TRY_CAST(r."total ads" AS DOUBLE) <= k.p90 THEN 'b3_p75_p90'
                    WHEN TRY_CAST(r."total ads" AS DOUBLE) <= k.p99 THEN 'b4_p90_p99'
                    ELSE 'b5_gt_p99'
                END)::BIGINT
    UNION ALL
    SELECT 'L04', 'Lock D4', 'time_block di clean = blok waktu dari most ads hour raw (selisih)',
        0::BIGINT,
        (SELECT COUNT(*)
           FROM marketing_ab_clean c
           JOIN raw_marketing_ab r ON c.row_index = TRY_CAST(r.column0 AS BIGINT)
          WHERE c.time_block IS DISTINCT FROM
                CASE
                    WHEN TRY_CAST(r."most ads hour" AS DOUBLE) IS NULL
                      OR TRY_CAST(r."most ads hour" AS DOUBLE) NOT BETWEEN 0 AND 23 THEN NULL
                    WHEN TRY_CAST(r."most ads hour" AS DOUBLE) < 6  THEN '00-05'
                    WHEN TRY_CAST(r."most ads hour" AS DOUBLE) < 12 THEN '06-11'
                    WHEN TRY_CAST(r."most ads hour" AS DOUBLE) < 18 THEN '12-17'
                    ELSE '18-23'
                END)::BIGINT
)
SELECT
    check_id,
    category,
    check_name,
    CAST(expected AS VARCHAR) AS expected,
    CAST(actual   AS VARCHAR) AS actual,
    CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS status
FROM chk
ORDER BY check_id;

SELECT '1. validation_summary (semua pemeriksaan)' AS section;

SELECT * FROM validation_summary ORDER BY check_id;

SELECT '2. Ringkasan status (gate: semua harus PASS)' AS section;

SELECT
    COUNT(*)                                        AS n_checks,
    COUNT(*) FILTER (WHERE status = 'PASS')         AS n_pass,
    COUNT(*) FILTER (WHERE status = 'FAIL')         AS n_fail,
    CASE WHEN COUNT(*) FILTER (WHERE status = 'FAIL') = 0
         THEN 'ALL PASS' ELSE 'FAIL' END            AS validation_gate
FROM validation_summary;

-- ----------------------------------------------------------------------------
-- 3. Ukuran grup, konversi (angka mentah), dan Sample Ratio Check (deskriptif)
--    Rasio desain grup tidak tersedia di dokumentasi, sehingga SRM TIDAK dapat dinyatakan
--    lulus atau gagal; rasio hanya dilaporkan dan dicatat sebagai limitation.
--    CR per grup sengaja tidak dihitung di sini (Tahap 7-9).
-- ----------------------------------------------------------------------------
SELECT '3. Ukuran grup, konversi, dan rasio ad : psa (deskriptif)' AS section;

SELECT
    COUNT(*) FILTER (WHERE is_treatment)                        AS n_ad,
    COUNT(*) FILTER (WHERE is_treatment AND is_converted)       AS n_converted_ad,
    COUNT(*) FILTER (WHERE is_control)                          AS n_psa,
    COUNT(*) FILTER (WHERE is_control AND is_converted)         AS n_converted_psa,
    round(1.0 * COUNT(*) FILTER (WHERE is_treatment)
              / COUNT(*) FILTER (WHERE is_control), 2)          AS ratio_ad_to_psa,
    round(100.0 * COUNT(*) FILTER (WHERE is_control)
                / COUNT(*), 2)                                  AS pct_psa
FROM marketing_ab_clean
WHERE is_valid_user;

-- ----------------------------------------------------------------------------
-- 4. D4: batas kuantil (dihitung dari raw, tanpa converted) dan ukuran bucket per grup
--    psa_n_below_500 / ad_n_below_500: indikasi sel kecil berdasarkan n saja (D5)
-- ----------------------------------------------------------------------------
SELECT '4a. Batas kuantil D4 (dari raw, tanpa converted)' AS section;

SELECT * FROM v_raw_cut;

SELECT '4b. Ukuran bucket paparan per grup (n saja)' AS section;

SELECT
    COALESCE(exposure_bucket, 'TOTAL')                       AS bucket_label,
    MIN(total_ads)                                           AS min_total_ads,
    MAX(total_ads)                                           AS max_total_ads,
    COUNT(*) FILTER (WHERE is_treatment)                     AS n_ad,
    COUNT(*) FILTER (WHERE is_control)                       AS n_psa,
    (COUNT(*) FILTER (WHERE is_treatment) < 500)             AS ad_n_below_500,
    (COUNT(*) FILTER (WHERE is_control) < 500)               AS psa_n_below_500
FROM marketing_ab_clean
WHERE is_valid_user AND has_valid_exposure
GROUP BY ROLLUP (exposure_bucket)
ORDER BY (exposure_bucket IS NULL), exposure_bucket;

-- ----------------------------------------------------------------------------
-- 5. Rekonsiliasi raw -> valid + dikeluarkan (per alasan)
-- ----------------------------------------------------------------------------
SELECT '5. Rekonsiliasi raw -> valid + dikeluarkan' AS section;

SELECT category, n_rows
FROM (
    SELECT COALESCE(exclusion_reason, '(valid)') AS category, COUNT(*) AS n_rows, 0 AS sort_key
    FROM marketing_ab_clean
    GROUP BY exclusion_reason
    UNION ALL
    SELECT 'TOTAL (harus = raw rows)', COUNT(*), 1 FROM marketing_ab_clean
)
ORDER BY sort_key, category;

-- ----------------------------------------------------------------------------
-- 6. Export: validation summary (Parquet) + verifikasi
-- ----------------------------------------------------------------------------
COPY (SELECT * FROM validation_summary ORDER BY check_id)
TO 'data/processed/05_validation_summary.parquet' (FORMAT PARQUET, COMPRESSION ZSTD);

SELECT '6. Verifikasi parquet validation_summary' AS section;

SELECT
    COUNT(*)                                       AS n_rows_parquet,
    (SELECT COUNT(*) FROM validation_summary)      AS n_rows_table,
    CASE WHEN COUNT(*) = (SELECT COUNT(*) FROM validation_summary)
         THEN 'MATCH' ELSE 'MISMATCH' END          AS status
FROM read_parquet('data/processed/05_validation_summary.parquet');
