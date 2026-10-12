-- ============================================================================
-- FILE:        sql/03_data_profiling.sql
-- TAHAP:       Tahap 4 (Inti)
-- TUJUAN:      Data Profiling raw_marketing_ab (kualitas data, duplikasi, ukuran grup,
--              distribusi variabel, ukuran sel awal untuk kelayakan D5/D6)
-- ============================================================================
-- GRAIN:       1 baris = 1 baris raw (kecuali dinyatakan lain per query: 1 kategori / 1 grup / 1 sel)
-- POPULATION:  Raw Population = seluruh baris raw_marketing_ab (belum ada baris dibuang)
-- DENOMINATOR: Persentase memakai seluruh baris raw sebagai pembagi, kecuali dinyatakan lain;
--              n (jumlah baris) selalu ditampilkan di samping persentase
-- ============================================================================
-- Jalankan (PowerShell, dari root folder proyek):
--   .\duckdb.exe ab_testing.duckdb -c ".read sql/03_data_profiling.sql"
--
-- File ini TIDAK membuat tabel permanen dan TIDAK mengubah raw_marketing_ab
-- (hanya TEMP VIEW). Aman dijalankan ulang.
--
-- Prinsip: belum ada baris yang dihapus. Semua anomali hanya dicatat.
-- Catatan: jumlah konversi per sel (bagian 10) dipakai HANYA untuk memeriksa
-- kelayakan ambang D5 (minimum volume), bukan untuk menilai efek iklan.
-- ============================================================================

.mode markdown
.maxrows 1000

-- ----------------------------------------------------------------------------
-- 0. Persiapan: view bantu (temporary)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW v_base AS
SELECT
    TRY_CAST(column0 AS BIGINT)            AS row_index,
    "user id"                              AS user_id_raw,
    ("user id" IS NULL OR trim("user id") = '') AS user_id_missing,
    TRY_CAST("user id" AS BIGINT)          AS user_id_num,
    "test group"                           AS test_group,
    converted                              AS converted_raw,
    CASE
        WHEN lower(trim(converted)) IN ('true', '1')  THEN TRUE
        WHEN lower(trim(converted)) IN ('false', '0') THEN FALSE
    END                                    AS converted_bool,
    "total ads"                            AS total_ads_raw,
    TRY_CAST("total ads" AS DOUBLE)        AS total_ads_num,
    "most ads day"                         AS day_raw,
    "most ads hour"                        AS hour_raw,
    TRY_CAST("most ads hour" AS DOUBLE)    AS hour_num
FROM raw_marketing_ab;

CREATE OR REPLACE TEMP VIEW v_profile AS
SELECT
    *,
    (day_raw IN ('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')) AS day_valid,
    (hour_num IS NOT NULL AND hour_num BETWEEN 0 AND 23 AND hour_num = floor(hour_num))   AS hour_valid,
    CASE
        WHEN hour_num IS NOT NULL AND hour_num BETWEEN 0 AND 23 AND hour_num = floor(hour_num) THEN
            CASE WHEN hour_num < 6  THEN '00-05'
                 WHEN hour_num < 12 THEN '06-11'
                 WHEN hour_num < 18 THEN '12-17'
                 ELSE '18-23' END
    END                                                                                    AS time_block,
    concat_ws('|',
        coalesce(test_group, '<NULL>'),
        coalesce(converted_raw, '<NULL>'),
        coalesce(total_ads_raw, '<NULL>'),
        coalesce(day_raw, '<NULL>'),
        coalesce(hour_raw, '<NULL>'))                                                      AS row_signature
FROM v_base;

-- Pengguna dengan user_id muncul lebih dari satu kali, diklasifikasi (kategori saling lepas):
--   c_group_conflict         : user_id muncul dengan >1 test_group
--   a_full_duplicate         : semua kolom (selain row index) identik
--   b_same_group_diff_values : grup sama, tapi nilai kolom lain berbeda
CREATE OR REPLACE TEMP VIEW v_dup_users AS
SELECT
    user_id_raw,
    COUNT(*)                          AS n_rows,
    COUNT(DISTINCT test_group)        AS n_groups,
    COUNT(DISTINCT row_signature)     AS n_signatures,
    CASE
        WHEN COUNT(DISTINCT test_group) > 1    THEN 'c_group_conflict'
        WHEN COUNT(DISTINCT row_signature) = 1 THEN 'a_full_duplicate'
        ELSE 'b_same_group_diff_values'
    END                               AS dup_category
FROM v_profile
WHERE NOT user_id_missing
GROUP BY user_id_raw
HAVING COUNT(*) > 1;

-- ----------------------------------------------------------------------------
-- 1. Jumlah baris dan kolom
-- ----------------------------------------------------------------------------
SELECT '1. Jumlah baris dan kolom' AS section;

SELECT
    COUNT(*) AS n_rows,
    (SELECT COUNT(*) FROM information_schema.columns
      WHERE table_name = 'raw_marketing_ab') AS n_columns
FROM raw_marketing_ab;

-- ----------------------------------------------------------------------------
-- 2. Missing values per kolom (NULL atau string kosong)
-- ----------------------------------------------------------------------------
SELECT '2. Missing values per kolom' AS section;

SELECT 'column0' AS column_name, COUNT(*) AS n_rows,
       COUNT(*) FILTER (WHERE column0 IS NULL) AS n_null,
       COUNT(*) FILTER (WHERE trim(column0) = '') AS n_empty_string,
       COUNT(*) FILTER (WHERE column0 IS NULL OR trim(column0) = '') AS n_missing,
       round(100.0 * COUNT(*) FILTER (WHERE column0 IS NULL OR trim(column0) = '') / COUNT(*), 4) AS pct_missing
FROM raw_marketing_ab
UNION ALL
SELECT 'user id', COUNT(*),
       COUNT(*) FILTER (WHERE "user id" IS NULL),
       COUNT(*) FILTER (WHERE trim("user id") = ''),
       COUNT(*) FILTER (WHERE "user id" IS NULL OR trim("user id") = ''),
       round(100.0 * COUNT(*) FILTER (WHERE "user id" IS NULL OR trim("user id") = '') / COUNT(*), 4)
FROM raw_marketing_ab
UNION ALL
SELECT 'test group', COUNT(*),
       COUNT(*) FILTER (WHERE "test group" IS NULL),
       COUNT(*) FILTER (WHERE trim("test group") = ''),
       COUNT(*) FILTER (WHERE "test group" IS NULL OR trim("test group") = ''),
       round(100.0 * COUNT(*) FILTER (WHERE "test group" IS NULL OR trim("test group") = '') / COUNT(*), 4)
FROM raw_marketing_ab
UNION ALL
SELECT 'converted', COUNT(*),
       COUNT(*) FILTER (WHERE converted IS NULL),
       COUNT(*) FILTER (WHERE trim(converted) = ''),
       COUNT(*) FILTER (WHERE converted IS NULL OR trim(converted) = ''),
       round(100.0 * COUNT(*) FILTER (WHERE converted IS NULL OR trim(converted) = '') / COUNT(*), 4)
FROM raw_marketing_ab
UNION ALL
SELECT 'total ads', COUNT(*),
       COUNT(*) FILTER (WHERE "total ads" IS NULL),
       COUNT(*) FILTER (WHERE trim("total ads") = ''),
       COUNT(*) FILTER (WHERE "total ads" IS NULL OR trim("total ads") = ''),
       round(100.0 * COUNT(*) FILTER (WHERE "total ads" IS NULL OR trim("total ads") = '') / COUNT(*), 4)
FROM raw_marketing_ab
UNION ALL
SELECT 'most ads day', COUNT(*),
       COUNT(*) FILTER (WHERE "most ads day" IS NULL),
       COUNT(*) FILTER (WHERE trim("most ads day") = ''),
       COUNT(*) FILTER (WHERE "most ads day" IS NULL OR trim("most ads day") = ''),
       round(100.0 * COUNT(*) FILTER (WHERE "most ads day" IS NULL OR trim("most ads day") = '') / COUNT(*), 4)
FROM raw_marketing_ab
UNION ALL
SELECT 'most ads hour', COUNT(*),
       COUNT(*) FILTER (WHERE "most ads hour" IS NULL),
       COUNT(*) FILTER (WHERE trim("most ads hour") = ''),
       COUNT(*) FILTER (WHERE "most ads hour" IS NULL OR trim("most ads hour") = ''),
       round(100.0 * COUNT(*) FILTER (WHERE "most ads hour" IS NULL OR trim("most ads hour") = '') / COUNT(*), 4)
FROM raw_marketing_ab;

-- ----------------------------------------------------------------------------
-- 3. Row index (column0) dan format user id
-- ----------------------------------------------------------------------------
SELECT '3. Row index dan format user id' AS section;

SELECT
    COUNT(*)                                          AS n_rows,
    COUNT(DISTINCT row_index)                         AS n_distinct_row_index,
    COUNT(*) FILTER (WHERE row_index IS NULL)         AS n_row_index_cast_fail,
    MIN(row_index)                                    AS min_row_index,
    MAX(row_index)                                    AS max_row_index,
    (MAX(row_index) - MIN(row_index) + 1 = COUNT(*))  AS is_row_index_contiguous,
    COUNT(*) FILTER (WHERE NOT user_id_missing AND user_id_num IS NULL) AS n_user_id_cast_fail,
    MIN(user_id_num)                                  AS min_user_id,
    MAX(user_id_num)                                  AS max_user_id
FROM v_profile;

-- ----------------------------------------------------------------------------
-- 4. Duplikasi user_id
-- ----------------------------------------------------------------------------
SELECT '4a. Ringkasan keunikan user_id' AS section;

SELECT
    COUNT(*)                                                          AS n_rows,
    COUNT(*) FILTER (WHERE user_id_missing)                           AS n_missing_user_id,
    COUNT(DISTINCT user_id_raw) FILTER (WHERE NOT user_id_missing)    AS n_distinct_user_ids,
    (SELECT COUNT(*) FROM v_dup_users)                                AS n_user_ids_with_dups,
    (SELECT COALESCE(SUM(n_rows), 0) FROM v_dup_users)                AS n_rows_in_dup_user_ids
FROM v_profile;

SELECT '4b. Duplikasi per kategori (a/b/c sesuai aturan D3)' AS section;

WITH cats(dup_category) AS (
    VALUES ('a_full_duplicate'), ('b_same_group_diff_values'), ('c_group_conflict')
)
SELECT
    c.dup_category,
    COUNT(d.user_id_raw)                                         AS n_user_ids,
    COALESCE(SUM(d.n_rows), 0)                                   AS n_rows,
    COALESCE(SUM(d.n_rows), 0) - COUNT(d.user_id_raw)            AS n_excess_rows
FROM cats c
LEFT JOIN v_dup_users d ON d.dup_category = c.dup_category
GROUP BY c.dup_category
ORDER BY c.dup_category;

SELECT '4c. Contoh baris duplikat (maks 5 user_id; kosong jika tidak ada duplikat)' AS section;

SELECT p.row_index, p.user_id_raw, p.test_group, p.converted_raw,
       p.total_ads_raw, p.day_raw, p.hour_raw, d.dup_category
FROM v_profile p
JOIN (SELECT user_id_raw, dup_category FROM v_dup_users ORDER BY user_id_raw LIMIT 5) d
  ON p.user_id_raw = d.user_id_raw
ORDER BY p.user_id_raw, p.row_index;

-- ----------------------------------------------------------------------------
-- 5. Nilai unik test group dan ukuran kedua grup
-- ----------------------------------------------------------------------------
SELECT '5a. Nilai test group (apa adanya) dan ukuran grup' AS section;

SELECT
    COALESCE(test_group, '<NULL>')                      AS test_group_raw_value,
    COUNT(*)                                            AS n_rows,
    COUNT(DISTINCT user_id_raw) FILTER (WHERE NOT user_id_missing) AS n_distinct_user_ids,
    round(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 4)  AS pct_of_all_rows
FROM v_profile
GROUP BY test_group
ORDER BY n_rows DESC;

SELECT '5b. Rasio ukuran grup ad : psa (berdasarkan jumlah baris)' AS section;

SELECT
    COUNT(*) FILTER (WHERE test_group = 'ad')                       AS n_rows_ad,
    COUNT(*) FILTER (WHERE test_group = 'psa')                      AS n_rows_psa,
    round(1.0 * COUNT(*) FILTER (WHERE test_group = 'ad')
              / NULLIF(COUNT(*) FILTER (WHERE test_group = 'psa'), 0), 2) AS ratio_ad_to_psa,
    round(100.0 * COUNT(*) FILTER (WHERE test_group = 'psa')
              / NULLIF(COUNT(*) FILTER (WHERE test_group IN ('ad','psa')), 0), 2) AS pct_psa_of_ad_psa
FROM v_profile;

-- ----------------------------------------------------------------------------
-- 6. Distribusi converted (nilai apa adanya dan pemetaan boolean)
-- ----------------------------------------------------------------------------
SELECT '6. Distribusi converted' AS section;

SELECT
    COALESCE(converted_raw, '<NULL>')                    AS converted_raw_value,
    converted_bool                                       AS mapped_boolean,
    COUNT(*)                                             AS n_rows,
    round(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 4)   AS pct_of_all_rows
FROM v_profile
GROUP BY converted_raw, converted_bool
ORDER BY n_rows DESC;

-- ----------------------------------------------------------------------------
-- 7. Distribusi total_ads (per grup dan gabungan)
--    Kuantil gabungan di sini bersifat informatif; batas bucket resmi (D4) dihitung di Tahap 6.
-- ----------------------------------------------------------------------------
SELECT '7. Distribusi total_ads' AS section;

SELECT
    CASE WHEN GROUPING(test_group) = 1 THEN 'ALL'
         ELSE COALESCE(test_group, '<NULL>') END                          AS test_group_scope,
    COUNT(*)                                                              AS n_rows,
    COUNT(*) FILTER (WHERE total_ads_raw IS NULL OR trim(total_ads_raw) = '') AS n_missing,
    COUNT(*) FILTER (WHERE total_ads_raw IS NOT NULL AND trim(total_ads_raw) <> ''
                       AND total_ads_num IS NULL)                         AS n_cast_fail,
    MIN(total_ads_num)                                                    AS min_ads,
    MAX(total_ads_num)                                                    AS max_ads,
    round(AVG(total_ads_num), 2)                                          AS mean_ads,
    quantile_cont(total_ads_num, 0.50)                                    AS p50,
    quantile_cont(total_ads_num, 0.75)                                    AS p75,
    quantile_cont(total_ads_num, 0.90)                                    AS p90,
    quantile_cont(total_ads_num, 0.95)                                    AS p95,
    quantile_cont(total_ads_num, 0.99)                                    AS p99,
    COUNT(*) FILTER (WHERE total_ads_num = 0)                             AS n_zero,
    COUNT(*) FILTER (WHERE total_ads_num < 0)                             AS n_negative,
    COUNT(*) FILTER (WHERE total_ads_num <> floor(total_ads_num))         AS n_non_integer
FROM v_profile
GROUP BY GROUPING SETS ((test_group), ())
ORDER BY test_group_scope;

-- ----------------------------------------------------------------------------
-- 8. Kategori most_ads_day
-- ----------------------------------------------------------------------------
SELECT '8. Kategori most_ads_day' AS section;

SELECT
    COALESCE(day_raw, '<NULL>')                          AS day_raw_value,
    day_valid                                            AS is_valid_day_name,
    COUNT(*)                                             AS n_rows,
    round(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 4)   AS pct_of_all_rows
FROM v_profile
GROUP BY day_raw, day_valid
ORDER BY day_valid DESC NULLS LAST,
         list_position(['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'], day_raw),
         n_rows DESC;

-- ----------------------------------------------------------------------------
-- 9. Kategori most_ads_hour
-- ----------------------------------------------------------------------------
SELECT '9. Kategori most_ads_hour (valid = bilangan bulat 0-23)' AS section;

SELECT
    COALESCE(hour_raw, '<NULL>')                         AS hour_raw_value,
    hour_valid                                           AS is_valid_hour,
    COUNT(*)                                             AS n_rows,
    round(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 4)   AS pct_of_all_rows
FROM v_profile
GROUP BY hour_raw, hour_num, hour_valid
ORDER BY hour_num NULLS LAST, hour_raw;

-- ----------------------------------------------------------------------------
-- 10. Ukuran sel awal (kelayakan D5/D6). Hanya grup ad/psa dan nilai hari/jam valid.
--     is_small_cell_d5 = n_rows < 500 ATAU n_converted < 30 (indikatif)
-- ----------------------------------------------------------------------------
SELECT '10a. Ukuran sel hari x grup' AS section;

SELECT
    day_raw                                              AS most_ads_day,
    test_group,
    COUNT(*)                                             AS n_rows,
    COUNT(*) FILTER (WHERE converted_bool)               AS n_converted,
    (COUNT(*) < 500 OR COUNT(*) FILTER (WHERE converted_bool) < 30) AS is_small_cell_d5
FROM v_profile
WHERE day_valid AND test_group IN ('ad', 'psa')
GROUP BY day_raw, test_group
ORDER BY list_position(['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'], day_raw),
         test_group;

SELECT '10b. Ukuran sel blok waktu x grup (blok dari D4: 00-05, 06-11, 12-17, 18-23)' AS section;

SELECT
    time_block,
    test_group,
    COUNT(*)                                             AS n_rows,
    COUNT(*) FILTER (WHERE converted_bool)               AS n_converted,
    (COUNT(*) < 500 OR COUNT(*) FILTER (WHERE converted_bool) < 30) AS is_small_cell_d5
FROM v_profile
WHERE time_block IS NOT NULL AND test_group IN ('ad', 'psa')
GROUP BY time_block, test_group
ORDER BY time_block, test_group;

CREATE OR REPLACE TEMP VIEW v_hour_cells AS
SELECT
    hour_num                                             AS most_ads_hour,
    test_group,
    COUNT(*)                                             AS n_rows,
    COUNT(*) FILTER (WHERE converted_bool)               AS n_converted,
    (COUNT(*) < 500 OR COUNT(*) FILTER (WHERE converted_bool) < 30) AS is_small_cell_d5
FROM v_profile
WHERE hour_valid AND test_group IN ('ad', 'psa')
GROUP BY hour_num, test_group;

SELECT '10c. Ringkasan sel jam x grup' AS section;

SELECT
    test_group,
    COUNT(*)                                             AS n_cells,
    COUNT(*) FILTER (WHERE is_small_cell_d5)             AS n_small_cells_d5,
    MIN(n_rows)                                          AS min_n_rows,
    median(n_rows)                                       AS median_n_rows,
    MIN(n_converted)                                     AS min_n_converted
FROM v_hour_cells
GROUP BY test_group
ORDER BY test_group;

SELECT '10d. Detail sel jam x grup' AS section;

SELECT * FROM v_hour_cells ORDER BY most_ads_hour, test_group;

-- ----------------------------------------------------------------------------
-- 11. Ringkasan populasi awal (informatif; BUKAN populasi analisis final).
--     Penerapan aturan D3 dan penetapan is_valid_user dilakukan di Tahap 5-6.
-- ----------------------------------------------------------------------------
SELECT '11. Ringkasan populasi awal (informatif)' AS section;

SELECT
    COUNT(*)                                                                    AS raw_rows,
    COUNT(*) FILTER (WHERE p.user_id_missing)                                   AS rows_missing_user_id,
    COUNT(*) FILTER (WHERE p.test_group IS NULL OR p.test_group NOT IN ('ad','psa')) AS rows_invalid_group,
    COUNT(*) FILTER (WHERE p.converted_bool IS NULL)                            AS rows_invalid_converted,
    COUNT(*) FILTER (WHERE d.user_id_raw IS NOT NULL)                           AS rows_in_dup_user_ids,
    COUNT(*) FILTER (WHERE d.dup_category = 'c_group_conflict')                 AS rows_in_group_conflict_user_ids,
    COUNT(*) FILTER (WHERE p.total_ads_num IS NULL OR p.total_ads_num < 0)      AS rows_without_valid_exposure,
    COUNT(*) FILTER (WHERE NOT p.day_valid OR p.day_valid IS NULL)              AS rows_invalid_day,
    COUNT(*) FILTER (WHERE NOT p.hour_valid)                                    AS rows_invalid_hour,
    COUNT(*) FILTER (WHERE NOT p.user_id_missing
                       AND p.test_group IN ('ad','psa')
                       AND p.converted_bool IS NOT NULL
                       AND d.user_id_raw IS NULL)                               AS rows_no_core_issue
FROM v_profile p
LEFT JOIN v_dup_users d ON p.user_id_raw = d.user_id_raw;
