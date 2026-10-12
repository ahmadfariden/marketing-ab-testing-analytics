-- ============================================================================
-- FILE:        sql/04_data_cleaning.sql
-- TAHAP:       Tahap 5 (Inti)
-- TUJUAN:      Data Cleaning & Treatment: raw -> stg_marketing_ab -> marketing_ab_clean
-- ============================================================================
-- GRAIN:       1 baris = 1 baris raw (tidak ada baris dibuang; baris yang tidak masuk analisis
--              hanya diberi flag + exclusion_reason). Setelah aturan D3, tiap user_id valid = 1 baris.
-- POPULATION:  Raw Population (seluruh baris). Valid Analysis Population = is_valid_user = TRUE.
-- DENOMINATOR: Valid Analysis Population per grup (n_ad = is_treatment, n_psa = is_control)
--              untuk metrik rate di tahap berikutnya.
-- ============================================================================
-- Jalankan (PowerShell, dari root folder proyek):
--   .\duckdb.exe ab_testing.duckdb -c ".read sql/04_data_cleaning.sql"
--
-- Layering:
--   raw_marketing_ab (ALL_VARCHAR, TIDAK diubah)
--     -> stg_marketing_ab   (cast + rename snake_case, 1 baris per baris raw)
--     -> marketing_ab_clean (flag analitik + aturan duplikasi D3)
--
-- PRINSIP: flag, jangan hapus. Keputusan treatment berdasarkan aturan kualitas data;
--          TIDAK ADA keputusan yang melihat nilai converted. test_group dan converted
--          tidak diubah nilainya (hanya dipetakan ke tipe yang sesuai).
--
-- CATATAN exposure_bucket (D4): batas kuantil dihitung dari total_ads pada populasi
-- gabungan (kedua grup) SAJA, tanpa menyentuh converted. Angka batas dicatat dan
-- dikunci di Tahap 6 (docs/methodology.md); skrip Tahap 6 memverifikasi angka yang sama.
-- ============================================================================

.mode markdown
.maxrows 1000

-- ----------------------------------------------------------------------------
-- 1. STAGING: cast tipe + standardisasi nama kolom (1 baris per baris raw)
--    TRY_CAST: nilai tidak valid menjadi NULL (tidak membuang baris).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_marketing_ab AS
SELECT
    TRY_CAST(column0 AS BIGINT)            AS row_index,
    TRY_CAST("user id" AS BIGINT)          AS user_id,
    "test group"                           AS test_group,       -- nilai tidak diubah
    CASE lower(trim(converted))
        WHEN 'true'  THEN TRUE
        WHEN '1'     THEN TRUE
        WHEN 'false' THEN FALSE
        WHEN '0'     THEN FALSE
    END                                    AS converted,        -- dipetakan ke BOOLEAN
    TRY_CAST("total ads" AS INTEGER)       AS total_ads,
    "most ads day"                         AS most_ads_day,
    TRY_CAST("most ads hour" AS INTEGER)   AS most_ads_hour
FROM raw_marketing_ab;

-- ----------------------------------------------------------------------------
-- 2. CLEAN: flag analitik + aturan duplikasi D3
--    D3: (a) duplikat penuh -> pertahankan 1; (b) user_id di >1 grup -> eksklusi semua barisnya;
--        (c) grup sama, nilai lain beda -> pertahankan row_index terkecil (outcome-blind).
--    (a) dan (c) sama-sama diimplementasikan sebagai: pertahankan baris dengan row_index terkecil.
--    Profiling (Tahap 4) menemukan 0 duplikat, sehingga D3 tidak mengubah populasi.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE marketing_ab_clean AS
WITH uc AS (
    SELECT
        user_id,
        COUNT(*)                    AS n_rows_user,
        COUNT(DISTINCT test_group)  AS n_groups_user,
        MIN(row_index)              AS min_row_index
    FROM stg_marketing_ab
    WHERE user_id IS NOT NULL
    GROUP BY user_id
),
f1 AS (
    SELECT
        s.*,
        COALESCE(u.n_rows_user, 1)                        AS dup_row_count,
        COALESCE(u.n_groups_user > 1, FALSE)              AS flag_group_conflict,
        COALESCE(u.n_rows_user > 1, FALSE)                AS flag_duplicate_user_id,
        (s.user_id IS NOT NULL AND s.row_index = u.min_row_index) AS is_selected_d3
    FROM stg_marketing_ab s
    LEFT JOIN uc u ON s.user_id = u.user_id
),
f2 AS (
    SELECT
        f1.*,
        (test_group = 'ad')                               AS is_treatment,
        (test_group = 'psa')                              AS is_control,
        (converted IS TRUE)                               AS is_converted,
        CASE
            WHEN user_id IS NULL                                  THEN 'missing_user_id'
            WHEN test_group IS NULL OR test_group NOT IN ('ad','psa') THEN 'invalid_test_group'
            WHEN converted IS NULL                                THEN 'invalid_converted'
            WHEN flag_group_conflict                              THEN 'd3b_group_conflict'
            WHEN NOT is_selected_d3                               THEN 'd3ac_duplicate_row_not_selected'
        END                                               AS exclusion_reason,
        (total_ads IS NOT NULL AND total_ads >= 0)        AS has_valid_exposure,
        (most_ads_day IN ('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
         AND most_ads_hour IS NOT NULL
         AND most_ads_hour BETWEEN 0 AND 23)              AS has_valid_time,
        CASE
            WHEN most_ads_hour IS NULL OR most_ads_hour NOT BETWEEN 0 AND 23 THEN NULL
            WHEN most_ads_hour < 6  THEN '00-05'
            WHEN most_ads_hour < 12 THEN '06-11'
            WHEN most_ads_hour < 18 THEN '12-17'
            ELSE '18-23'
        END                                               AS time_block
    FROM f1
),
f3 AS (
    SELECT f2.*, (exclusion_reason IS NULL) AS is_valid_user
    FROM f2
),
cut AS (
    -- Batas bucket D4: kuantil total_ads populasi gabungan (valid + exposure valid); tanpa converted
    SELECT
        quantile_cont(total_ads, 0.50) AS p50,
        quantile_cont(total_ads, 0.75) AS p75,
        quantile_cont(total_ads, 0.90) AS p90,
        quantile_cont(total_ads, 0.99) AS p99
    FROM f3
    WHERE is_valid_user AND has_valid_exposure
)
SELECT
    f3.row_index,
    f3.user_id,
    f3.test_group,
    f3.converted,
    f3.total_ads,
    f3.most_ads_day,
    f3.most_ads_hour,
    f3.is_treatment,
    f3.is_control,
    f3.is_converted,
    f3.dup_row_count,
    f3.flag_duplicate_user_id,
    f3.flag_group_conflict,
    f3.is_selected_d3,
    f3.exclusion_reason,
    f3.is_valid_user,
    f3.has_valid_exposure,
    f3.has_valid_time,
    CASE
        WHEN NOT f3.has_valid_exposure THEN NULL
        WHEN f3.total_ads <= c.p50 THEN 'b1_le_p50'
        WHEN f3.total_ads <= c.p75 THEN 'b2_p50_p75'
        WHEN f3.total_ads <= c.p90 THEN 'b3_p75_p90'
        WHEN f3.total_ads <= c.p99 THEN 'b4_p90_p99'
        ELSE 'b5_gt_p99'
    END                                                    AS exposure_bucket,
    f3.time_block
FROM f3
CROSS JOIN cut c
ORDER BY f3.row_index;

-- ============================================================================
-- AUDIT & ACCEPTANCE CRITERIA
-- ============================================================================

-- ----------------------------------------------------------------------------
-- A1. Row count: raw = stg = clean
-- ----------------------------------------------------------------------------
SELECT 'A1. Row count raw = stg = clean' AS section;

SELECT
    (SELECT COUNT(*) FROM raw_marketing_ab)   AS n_raw,
    (SELECT COUNT(*) FROM stg_marketing_ab)   AS n_stg,
    (SELECT COUNT(*) FROM marketing_ab_clean) AS n_clean,
    CASE WHEN (SELECT COUNT(*) FROM raw_marketing_ab) = (SELECT COUNT(*) FROM stg_marketing_ab)
          AND (SELECT COUNT(*) FROM stg_marketing_ab) = (SELECT COUNT(*) FROM marketing_ab_clean)
         THEN 'MATCH' ELSE 'MISMATCH' END     AS status;

-- ----------------------------------------------------------------------------
-- A2. Kegagalan cast (nilai raw terisi tetapi hasil cast NULL). Harus 0.
-- ----------------------------------------------------------------------------
SELECT 'A2. Kegagalan cast per kolom (harus 0)' AS section;

SELECT
    COUNT(*) FILTER (WHERE r."user id" IS NOT NULL AND trim(r."user id") <> '' AND s.user_id IS NULL)           AS user_id_cast_fail,
    COUNT(*) FILTER (WHERE r.converted IS NOT NULL AND trim(r.converted) <> '' AND s.converted IS NULL)         AS converted_map_fail,
    COUNT(*) FILTER (WHERE r."total ads" IS NOT NULL AND trim(r."total ads") <> '' AND s.total_ads IS NULL)     AS total_ads_cast_fail,
    COUNT(*) FILTER (WHERE r."most ads hour" IS NOT NULL AND trim(r."most ads hour") <> '' AND s.most_ads_hour IS NULL) AS most_ads_hour_cast_fail,
    COUNT(*) FILTER (WHERE s.row_index IS NULL)                                                                 AS row_index_cast_fail
FROM raw_marketing_ab r
JOIN stg_marketing_ab s ON TRY_CAST(r.column0 AS BIGINT) = s.row_index;

-- ----------------------------------------------------------------------------
-- A3. test_group dan converted TIDAK berubah (clean vs raw, per baris). Harus 0 selisih.
-- ----------------------------------------------------------------------------
SELECT 'A3. test_group dan converted tidak berubah (selisih harus 0)' AS section;

SELECT
    COUNT(*)                                                                    AS n_joined_rows,
    COUNT(*) FILTER (WHERE c.test_group IS DISTINCT FROM r."test group")        AS test_group_mismatch,
    COUNT(*) FILTER (WHERE c.converted IS DISTINCT FROM (r.converted = 'True')) AS converted_mismatch,
    COUNT(*) FILTER (WHERE r.converted = 'True')                                AS raw_true_rows,
    COUNT(*) FILTER (WHERE c.converted)                                         AS clean_true_rows,
    COUNT(*) FILTER (WHERE r.converted = 'False')                               AS raw_false_rows,
    COUNT(*) FILTER (WHERE c.converted = FALSE)                                 AS clean_false_rows
FROM raw_marketing_ab r
JOIN marketing_ab_clean c ON TRY_CAST(r.column0 AS BIGINT) = c.row_index;

-- ----------------------------------------------------------------------------
-- A4. Rekonsiliasi raw -> valid + dikeluarkan (per alasan)
-- ----------------------------------------------------------------------------
SELECT 'A4. Rekonsiliasi raw -> valid + flagged per alasan' AS section;

SELECT category, n_rows, pct_of_raw
FROM (
    SELECT
        COALESCE(exclusion_reason, '(valid)')                    AS category,
        COUNT(*)                                                 AS n_rows,
        round(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 4)       AS pct_of_raw,
        0                                                        AS sort_key
    FROM marketing_ab_clean
    GROUP BY exclusion_reason
    UNION ALL
    SELECT 'TOTAL (harus = raw rows)', COUNT(*), 100.0, 1 FROM marketing_ab_clean
)
ORDER BY sort_key, category;

-- ----------------------------------------------------------------------------
-- A5. Populasi analisis dan konsistensi flag grup
--     SUM(is_treatment) + SUM(is_control) harus = COUNT(is_valid_user = TRUE)
-- ----------------------------------------------------------------------------
SELECT 'A5. Populasi analisis' AS section;

SELECT
    COUNT(*)                                                             AS raw_rows,
    COUNT(*) FILTER (WHERE is_valid_user)                                AS valid_analysis_population,
    COUNT(*) FILTER (WHERE is_valid_user AND is_treatment)               AS n_ad,
    COUNT(*) FILTER (WHERE is_valid_user AND is_control)                 AS n_psa,
    (COUNT(*) FILTER (WHERE is_valid_user AND is_treatment)
     + COUNT(*) FILTER (WHERE is_valid_user AND is_control)
     = COUNT(*) FILTER (WHERE is_valid_user))                            AS group_flags_consistent,
    COUNT(*) FILTER (WHERE is_valid_user AND has_valid_exposure)         AS exposure_population,
    COUNT(*) FILTER (WHERE is_valid_user AND has_valid_time)             AS time_population,
    COUNT(DISTINCT user_id) FILTER (WHERE is_valid_user)                 AS distinct_valid_user_ids
FROM marketing_ab_clean;

-- ----------------------------------------------------------------------------
-- A6. Cleaning log: aturan, deskripsi, dan jumlah baris terdampak
-- ----------------------------------------------------------------------------
SELECT 'A6. Cleaning log' AS section;

SELECT 'R01' AS rule_id, 'Cast user id -> BIGINT; rename user_id' AS rule, COUNT(*) FILTER (WHERE r."user id" IS NOT NULL AND trim(r."user id") <> '' AND s.user_id IS NULL) AS n_rows_affected
FROM raw_marketing_ab r JOIN stg_marketing_ab s ON TRY_CAST(r.column0 AS BIGINT) = s.row_index
UNION ALL
SELECT 'R02', 'Map converted True/False -> BOOLEAN (nilai tidak terpetakan = NULL)', COUNT(*) FILTER (WHERE converted IS NULL) FROM stg_marketing_ab
UNION ALL
SELECT 'R03', 'Cast total ads -> INTEGER; rename total_ads (gagal cast = NULL)', COUNT(*) FILTER (WHERE total_ads IS NULL) FROM stg_marketing_ab
UNION ALL
SELECT 'R04', 'Cast most ads hour -> INTEGER; rename most_ads_hour (gagal cast = NULL)', COUNT(*) FILTER (WHERE most_ads_hour IS NULL) FROM stg_marketing_ab
UNION ALL
SELECT 'R05', 'Rename column0 -> row_index, test group -> test_group, most ads day -> most_ads_day', COUNT(*) FROM stg_marketing_ab
UNION ALL
SELECT 'R06', 'Eksklusi: user_id kosong', COUNT(*) FILTER (WHERE exclusion_reason = 'missing_user_id') FROM marketing_ab_clean
UNION ALL
SELECT 'R07', 'Eksklusi: test_group bukan ad/psa', COUNT(*) FILTER (WHERE exclusion_reason = 'invalid_test_group') FROM marketing_ab_clean
UNION ALL
SELECT 'R08', 'Eksklusi: converted tidak valid', COUNT(*) FILTER (WHERE exclusion_reason = 'invalid_converted') FROM marketing_ab_clean
UNION ALL
SELECT 'R09', 'D3(b): eksklusi user_id di >1 grup', COUNT(*) FILTER (WHERE exclusion_reason = 'd3b_group_conflict') FROM marketing_ab_clean
UNION ALL
SELECT 'R10', 'D3(a)(c): baris duplikat tidak terpilih (row_index terkecil dipertahankan)', COUNT(*) FILTER (WHERE exclusion_reason = 'd3ac_duplicate_row_not_selected') FROM marketing_ab_clean
UNION ALL
SELECT 'R11', 'Tanpa paparan valid (total_ads NULL/negatif); TIDAK dibuang dari Primary KPI', COUNT(*) FILTER (WHERE NOT has_valid_exposure) FROM marketing_ab_clean
UNION ALL
SELECT 'R12', 'Tanpa hari/jam valid; TIDAK dibuang dari Primary KPI', COUNT(*) FILTER (WHERE NOT has_valid_time) FROM marketing_ab_clean
ORDER BY rule_id;

-- ----------------------------------------------------------------------------
-- A7. Bucket paparan (D4): batas kuantil (tanpa converted) dan distribusi n per grup
-- ----------------------------------------------------------------------------
SELECT 'A7a. Batas kuantil total_ads (populasi gabungan, valid + exposure valid)' AS section;

SELECT
    COUNT(*)                            AS n_exposure_population,
    quantile_cont(total_ads, 0.50)      AS p50,
    quantile_cont(total_ads, 0.75)      AS p75,
    quantile_cont(total_ads, 0.90)      AS p90,
    quantile_cont(total_ads, 0.99)      AS p99
FROM marketing_ab_clean
WHERE is_valid_user AND has_valid_exposure;

SELECT 'A7b. Distribusi bucket paparan per grup (n saja)' AS section;

SELECT
    COALESCE(exposure_bucket, 'TOTAL')                       AS bucket_label,
    MIN(total_ads)                                           AS min_total_ads,
    MAX(total_ads)                                           AS max_total_ads,
    COUNT(*) FILTER (WHERE is_treatment)                     AS n_ad,
    COUNT(*) FILTER (WHERE is_control)                       AS n_psa,
    COUNT(*)                                                 AS n_total
FROM marketing_ab_clean
WHERE is_valid_user AND has_valid_exposure
GROUP BY ROLLUP (exposure_bucket)
ORDER BY (exposure_bucket IS NULL), exposure_bucket;

SELECT 'A7c. Distribusi blok waktu per grup (n saja)' AS section;

SELECT
    COALESCE(time_block, 'TOTAL')                            AS block_label,
    COUNT(*) FILTER (WHERE is_treatment)                     AS n_ad,
    COUNT(*) FILTER (WHERE is_control)                       AS n_psa,
    COUNT(*)                                                 AS n_total
FROM marketing_ab_clean
WHERE is_valid_user AND has_valid_time
GROUP BY ROLLUP (time_block)
ORDER BY (time_block IS NULL), time_block;

-- ----------------------------------------------------------------------------
-- A8. Struktur tabel akhir
-- ----------------------------------------------------------------------------
SELECT 'A8. Struktur marketing_ab_clean' AS section;

DESCRIBE marketing_ab_clean;

-- ----------------------------------------------------------------------------
-- 3. EXPORT: layer processed (Parquet)
-- ----------------------------------------------------------------------------
COPY (SELECT * FROM marketing_ab_clean ORDER BY row_index)
TO 'data/processed/04_marketing_ab_clean.parquet' (FORMAT PARQUET, COMPRESSION ZSTD);

SELECT 'A9. Verifikasi parquet' AS section;

SELECT
    COUNT(*)                                   AS n_rows_parquet,
    (SELECT COUNT(*) FROM marketing_ab_clean)  AS n_rows_table,
    CASE WHEN COUNT(*) = (SELECT COUNT(*) FROM marketing_ab_clean)
         THEN 'MATCH' ELSE 'MISMATCH' END      AS status
FROM read_parquet('data/processed/04_marketing_ab_clean.parquet');
