-- ============================================================================
-- FILE:        sql/06_eda.sql
-- TAHAP:       Tahap 7 (Inti)
-- TUJUAN:      Exploratory Data Analysis: ukuran grup, distribusi total_ads, distribusi hari/jam/bucket,
--              keseimbangan karakteristik antar grup, dan deteksi ekor panjang / anomali
-- ============================================================================
-- GRAIN:       eda_summary: 1 baris = 1 metrik untuk (section, grup, kategori).
--              Query tampilan: 1 baris = 1 grup / 1 kategori.
-- POPULATION:  Valid Analysis Population (is_valid_user = TRUE) untuk ukuran grup dan konversi;
--              Exposure Population (has_valid_exposure) untuk total_ads dan bucket;
--              Time Population (has_valid_time) untuk hari, blok waktu, dan jam.
-- DENOMINATOR: Persentase distribusi = share di dalam grup (pembagi = n grup pada populasi terkait).
--              n selalu ditampilkan di samping persentase.
-- ============================================================================
-- Jalankan (PowerShell, dari root folder proyek):
--   .\duckdb.exe ab_testing.duckdb -c ".read sql/06_eda.sql"
--
-- Prasyarat: Tahap 6 selesai (tag kpi-lock); marketing_ab_clean tersedia.
--
-- EDA GOVERNANCE (lihat docs/methodology.md):
--   * EDA tidak mengubah KPI, populasi, bucket, atau aturan D1-D9.
--   * Tidak ada CR per segmen (bucket, hari, blok waktu, jam) di file ini, agar segmen tidak
--     dipilih berdasarkan pola konversi (D4, D5). CR per segmen ada di Tahap 10-12.
--   * Hanya distribusi (jumlah dan persentase user). Tidak ada baris yang dibuang.
--   * Semua temuan berlabel EXPLORATORY dan bukan kesimpulan inferensial.
--   * total_ads, hari, dan jam adalah variabel post-treatment (D7): ketidakseimbangan antar grup
--     pada variabel ini BUKAN bukti pelanggaran randomization.
-- ============================================================================

.mode markdown
.maxrows 1000

-- ----------------------------------------------------------------------------
-- 0. Persiapan: view bantu (temporary)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW v_eda AS
SELECT * FROM marketing_ab_clean WHERE is_valid_user;

-- Ambang ekor (populasi gabungan, Exposure Population); dipakai sama untuk kedua grup
CREATE OR REPLACE TEMP VIEW v_eda_thr AS
SELECT
    q1, q3, p99,
    q3 - q1                  AS iqr,
    q3 + 1.5 * (q3 - q1)     AS tukey_upper_fence,
    q3 + 3.0 * (q3 - q1)     AS extreme_fence
FROM (
    SELECT
        quantile_cont(total_ads, 0.25) AS q1,
        quantile_cont(total_ads, 0.75) AS q3,
        quantile_cont(total_ads, 0.99) AS p99
    FROM v_eda
    WHERE has_valid_exposure
);

-- ----------------------------------------------------------------------------
-- 1. eda_summary (format panjang): satu sumber untuk tampilan dan Parquet
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE eda_summary (
    section     VARCHAR,
    test_group  VARCHAR,   -- ad / psa / ALL
    category    VARCHAR,
    metric      VARCHAR,
    value       DOUBLE,
    n_rows      BIGINT
);

-- 1a. Ukuran grup, konversi (jumlah dan persentase)
CREATE OR REPLACE TEMP VIEW v_u_group AS
SELECT
    CASE WHEN GROUPING(test_group) = 1 THEN 'ALL' ELSE test_group END       AS g,
    COUNT(*)                                                                AS n,
    COUNT(*)::DOUBLE                                                        AS n_users,
    (COUNT(*) FILTER (WHERE is_converted))::DOUBLE                          AS n_converted,
    100.0 * COUNT(*) FILTER (WHERE is_converted) / COUNT(*)                 AS conversion_rate_pct,
    100.0 * COUNT(*) / (SELECT COUNT(*) FROM v_eda)                         AS share_of_valid_pct
FROM v_eda
GROUP BY GROUPING SETS ((test_group), ());

INSERT INTO eda_summary
SELECT 'group_size', g, 'all', metric, value, n
FROM v_u_group
UNPIVOT (value FOR metric IN (n_users, n_converted, conversion_rate_pct, share_of_valid_pct));

-- 1b. Distribusi total_ads per grup
CREATE OR REPLACE TEMP VIEW v_u_stats AS
SELECT
    CASE WHEN GROUPING(test_group) = 1 THEN 'ALL' ELSE test_group END       AS g,
    COUNT(*)                                                                AS n,
    AVG(total_ads)::DOUBLE                                                  AS mean_ads,
    STDDEV_SAMP(total_ads)::DOUBLE                                          AS sd_ads,
    MIN(total_ads)::DOUBLE                                                  AS min_ads,
    quantile_cont(total_ads, 0.25)::DOUBLE                                  AS p25,
    quantile_cont(total_ads, 0.50)::DOUBLE                                  AS median_ads,
    quantile_cont(total_ads, 0.75)::DOUBLE                                  AS p75,
    quantile_cont(total_ads, 0.90)::DOUBLE                                  AS p90,
    quantile_cont(total_ads, 0.95)::DOUBLE                                  AS p95,
    quantile_cont(total_ads, 0.99)::DOUBLE                                  AS p99,
    MAX(total_ads)::DOUBLE                                                  AS max_ads,
    (AVG(total_ads) / quantile_cont(total_ads, 0.50))::DOUBLE               AS mean_to_median_ratio
FROM v_eda
WHERE has_valid_exposure
GROUP BY GROUPING SETS ((test_group), ());

INSERT INTO eda_summary
SELECT 'total_ads_stats', g, 'all', metric, value, n
FROM v_u_stats
UNPIVOT (value FOR metric IN (mean_ads, sd_ads, min_ads, p25, median_ads, p75, p90, p95, p99, max_ads, mean_to_median_ratio));

-- 1c. Ambang ekor (populasi gabungan)
CREATE OR REPLACE TEMP VIEW v_u_thr AS
SELECT 'ALL' AS g, (SELECT COUNT(*) FROM v_eda WHERE has_valid_exposure) AS n,
       q1::DOUBLE AS q1, q3::DOUBLE AS q3, iqr::DOUBLE AS iqr, p99::DOUBLE AS p99_pooled,
       tukey_upper_fence::DOUBLE AS tukey_upper_fence, extreme_fence::DOUBLE AS extreme_fence
FROM v_eda_thr;

INSERT INTO eda_summary
SELECT 'total_ads_thresholds', g, 'all', metric, value, n
FROM v_u_thr
UNPIVOT (value FOR metric IN (q1, q3, iqr, p99_pooled, tukey_upper_fence, extreme_fence));

-- 1d. Ekor panjang dan outlier total_ads (ditandai saja, tidak dibuang)
CREATE OR REPLACE TEMP VIEW v_u_tail AS
SELECT
    CASE WHEN GROUPING(e.test_group) = 1 THEN 'ALL' ELSE e.test_group END    AS g,
    COUNT(*)                                                                AS n,
    (COUNT(*) FILTER (WHERE e.total_ads > t.p99))::DOUBLE                   AS n_above_p99_pooled,
    100.0 * COUNT(*) FILTER (WHERE e.total_ads > t.p99) / COUNT(*)          AS pct_above_p99_pooled,
    (COUNT(*) FILTER (WHERE e.total_ads > t.tukey_upper_fence))::DOUBLE     AS n_above_tukey_fence,
    100.0 * COUNT(*) FILTER (WHERE e.total_ads > t.tukey_upper_fence) / COUNT(*) AS pct_above_tukey_fence,
    (COUNT(*) FILTER (WHERE e.total_ads > t.extreme_fence))::DOUBLE         AS n_above_extreme_fence,
    100.0 * (SUM(e.total_ads) FILTER (WHERE e.total_ads > t.p99))::DOUBLE
          / (SUM(e.total_ads))::DOUBLE                                      AS share_of_total_ads_above_p99_pct
FROM v_eda e
CROSS JOIN v_eda_thr t
WHERE e.has_valid_exposure
GROUP BY GROUPING SETS ((e.test_group), ());

INSERT INTO eda_summary
SELECT 'total_ads_tail', g, 'all', metric, value, n
FROM v_u_tail
UNPIVOT (value FOR metric IN (n_above_p99_pooled, pct_above_p99_pooled, n_above_tukey_fence,
                              pct_above_tukey_fence, n_above_extreme_fence, share_of_total_ads_above_p99_pct));

-- 1e. Distribusi kategori per grup: hari, blok waktu, jam, bucket paparan (jumlah dan share di dalam grup)
CREATE OR REPLACE TEMP VIEW v_cat_counts AS
SELECT 'day_distribution' AS section,
       CASE WHEN GROUPING(test_group) = 1 THEN 'ALL' ELSE test_group END AS g,
       most_ads_day AS cat,
       COUNT(*) AS n
FROM v_eda WHERE has_valid_time
GROUP BY GROUPING SETS ((test_group, most_ads_day), (most_ads_day))
UNION ALL
SELECT 'block_distribution',
       CASE WHEN GROUPING(test_group) = 1 THEN 'ALL' ELSE test_group END,
       time_block,
       COUNT(*)
FROM v_eda WHERE has_valid_time
GROUP BY GROUPING SETS ((test_group, time_block), (time_block))
UNION ALL
SELECT 'hour_distribution',
       CASE WHEN GROUPING(test_group) = 1 THEN 'ALL' ELSE test_group END,
       lpad(most_ads_hour::VARCHAR, 2, '0'),
       COUNT(*)
FROM v_eda WHERE has_valid_time
GROUP BY GROUPING SETS ((test_group, most_ads_hour), (most_ads_hour))
UNION ALL
SELECT 'bucket_distribution',
       CASE WHEN GROUPING(test_group) = 1 THEN 'ALL' ELSE test_group END,
       exposure_bucket,
       COUNT(*)
FROM v_eda WHERE has_valid_exposure
GROUP BY GROUPING SETS ((test_group, exposure_bucket), (exposure_bucket));

CREATE OR REPLACE TEMP VIEW v_u_cat AS
SELECT
    section, g, cat, n,
    n::DOUBLE                                                      AS n_users,
    100.0 * n / SUM(n) OVER (PARTITION BY section, g)              AS share_pct_within_group
FROM v_cat_counts;

INSERT INTO eda_summary
SELECT section, g, cat, metric, value, n
FROM v_u_cat
UNPIVOT (value FOR metric IN (n_users, share_pct_within_group));

-- 1f. Keseimbangan antar grup (deskriptif)
--     TVD (total variation distance) = 0,5 x jumlah |share_ad - share_psa| per dimensi (0 = identik, 100 = terpisah total)
INSERT INTO eda_summary
SELECT
    'balance',
    'ALL',
    replace(COALESCE(a.section, p.section), '_distribution', ''),
    'total_variation_distance_pct',
    0.5 * SUM(ABS(COALESCE(a.value, 0) - COALESCE(p.value, 0))),
    COUNT(*)
FROM (SELECT section, category, value FROM eda_summary
       WHERE test_group = 'ad'  AND metric = 'share_pct_within_group') a
FULL OUTER JOIN
     (SELECT section, category, value FROM eda_summary
       WHERE test_group = 'psa' AND metric = 'share_pct_within_group') p
  ON a.section = p.section AND a.category = p.category
GROUP BY COALESCE(a.section, p.section);

--     SMD (standardized mean difference) total_ads: (mean_ad - mean_psa) / sqrt((sd_ad^2 + sd_psa^2) / 2)
INSERT INTO eda_summary
SELECT
    'balance', 'ALL', 'total_ads', 'standardized_mean_difference',
    (MAX(value) FILTER (WHERE test_group = 'ad'  AND metric = 'mean_ads')
   - MAX(value) FILTER (WHERE test_group = 'psa' AND metric = 'mean_ads'))
    / sqrt((power(MAX(value) FILTER (WHERE test_group = 'ad'  AND metric = 'sd_ads'), 2)
          + power(MAX(value) FILTER (WHERE test_group = 'psa' AND metric = 'sd_ads'), 2)) / 2),
    NULL
FROM eda_summary
WHERE section = 'total_ads_stats';

-- ============================================================================
-- TAMPILAN HASIL (semua berasal dari eda_summary, yaitu isi yang sama dengan Parquet)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- E1. Ukuran grup, jumlah dan persentase konversi (deskriptif; BUKAN hasil uji, lihat Tahap 8)
-- ----------------------------------------------------------------------------
SELECT 'E1. Ukuran grup, jumlah dan persentase konversi (deskriptif)' AS section;

SELECT
    test_group,
    CAST(MAX(value) FILTER (WHERE metric = 'n_users')            AS BIGINT) AS n_users,
    CAST(MAX(value) FILTER (WHERE metric = 'n_converted')        AS BIGINT) AS n_converted,
    round(MAX(value) FILTER (WHERE metric = 'conversion_rate_pct'), 4)       AS conversion_rate_pct,
    round(MAX(value) FILTER (WHERE metric = 'share_of_valid_pct'), 2)        AS share_of_valid_pct
FROM eda_summary
WHERE section = 'group_size'
GROUP BY test_group
ORDER BY CASE test_group WHEN 'ad' THEN 1 WHEN 'psa' THEN 2 ELSE 3 END;

-- ----------------------------------------------------------------------------
-- E2. Distribusi total_ads per grup
-- ----------------------------------------------------------------------------
SELECT 'E2. Distribusi total_ads per grup (Exposure Population)' AS section;

SELECT
    test_group,
    CAST(MAX(n_rows) AS BIGINT)                                          AS n_rows,
    round(MAX(value) FILTER (WHERE metric = 'mean_ads'), 2)              AS mean_ads,
    round(MAX(value) FILTER (WHERE metric = 'sd_ads'), 2)                AS sd_ads,
    MAX(value) FILTER (WHERE metric = 'min_ads')                         AS min_ads,
    MAX(value) FILTER (WHERE metric = 'p25')                             AS p25,
    MAX(value) FILTER (WHERE metric = 'median_ads')                      AS median_ads,
    MAX(value) FILTER (WHERE metric = 'p75')                             AS p75,
    MAX(value) FILTER (WHERE metric = 'p90')                             AS p90,
    round(MAX(value) FILTER (WHERE metric = 'p95'), 2)                   AS p95,
    MAX(value) FILTER (WHERE metric = 'p99')                             AS p99,
    MAX(value) FILTER (WHERE metric = 'max_ads')                         AS max_ads,
    round(MAX(value) FILTER (WHERE metric = 'mean_to_median_ratio'), 2)  AS mean_to_median
FROM eda_summary
WHERE section = 'total_ads_stats'
GROUP BY test_group
ORDER BY CASE test_group WHEN 'ad' THEN 1 WHEN 'psa' THEN 2 ELSE 3 END;

-- ----------------------------------------------------------------------------
-- E3. Ekor panjang dan outlier total_ads (ambang gabungan; hanya ditandai, tidak dibuang)
-- ----------------------------------------------------------------------------
SELECT 'E3a. Ambang ekor (populasi gabungan)' AS section;

SELECT
    MAX(value) FILTER (WHERE metric = 'q1')                 AS q1,
    MAX(value) FILTER (WHERE metric = 'q3')                 AS q3,
    MAX(value) FILTER (WHERE metric = 'iqr')                AS iqr,
    MAX(value) FILTER (WHERE metric = 'p99_pooled')         AS p99_pooled,
    MAX(value) FILTER (WHERE metric = 'tukey_upper_fence')  AS tukey_upper_fence,
    MAX(value) FILTER (WHERE metric = 'extreme_fence')      AS extreme_fence
FROM eda_summary
WHERE section = 'total_ads_thresholds';

SELECT 'E3b. Ekor panjang per grup' AS section;

SELECT
    test_group,
    CAST(MAX(n_rows) AS BIGINT)                                                      AS n_rows,
    CAST(MAX(value) FILTER (WHERE metric = 'n_above_p99_pooled') AS BIGINT)          AS n_above_p99,
    round(MAX(value) FILTER (WHERE metric = 'pct_above_p99_pooled'), 3)              AS pct_above_p99,
    CAST(MAX(value) FILTER (WHERE metric = 'n_above_tukey_fence') AS BIGINT)         AS n_above_tukey_fence,
    round(MAX(value) FILTER (WHERE metric = 'pct_above_tukey_fence'), 3)             AS pct_above_tukey_fence,
    CAST(MAX(value) FILTER (WHERE metric = 'n_above_extreme_fence') AS BIGINT)       AS n_above_extreme_fence,
    round(MAX(value) FILTER (WHERE metric = 'share_of_total_ads_above_p99_pct'), 2)  AS share_of_all_ads_from_above_p99_pct
FROM eda_summary
WHERE section = 'total_ads_tail'
GROUP BY test_group
ORDER BY CASE test_group WHEN 'ad' THEN 1 WHEN 'psa' THEN 2 ELSE 3 END;

SELECT 'E3c. Lima nilai total_ads tertinggi per grup (tanpa converted)' AS section;

SELECT test_group, rn AS rank_in_group, row_index, total_ads, most_ads_day, most_ads_hour
FROM (
    SELECT test_group, row_index, total_ads, most_ads_day, most_ads_hour,
           row_number() OVER (PARTITION BY test_group ORDER BY total_ads DESC, row_index) AS rn
    FROM v_eda
)
WHERE rn <= 5
ORDER BY test_group, rn;

-- ----------------------------------------------------------------------------
-- E4-E7. Distribusi hari, blok waktu, jam, dan bucket per grup (share di dalam grup)
--        diff_pp = pct_ad - pct_psa (poin persentase); deskriptif, bukan uji
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW v_dist_wide AS
SELECT
    section,
    category,
    CAST(MAX(value) FILTER (WHERE test_group = 'ad'  AND metric = 'n_users') AS BIGINT) AS n_ad,
    round(MAX(value) FILTER (WHERE test_group = 'ad'  AND metric = 'share_pct_within_group'), 2)  AS pct_ad,
    CAST(MAX(value) FILTER (WHERE test_group = 'psa' AND metric = 'n_users') AS BIGINT) AS n_psa,
    round(MAX(value) FILTER (WHERE test_group = 'psa' AND metric = 'share_pct_within_group'), 2)  AS pct_psa,
    round(MAX(value) FILTER (WHERE test_group = 'ad'  AND metric = 'share_pct_within_group')
        - MAX(value) FILTER (WHERE test_group = 'psa' AND metric = 'share_pct_within_group'), 2)  AS diff_pp
FROM eda_summary
WHERE section LIKE '%_distribution'
GROUP BY section, category;

SELECT 'E4. Distribusi hari paparan terbanyak per grup' AS section;

SELECT category AS most_ads_day, n_ad, pct_ad, n_psa, pct_psa, diff_pp
FROM v_dist_wide
WHERE section = 'day_distribution'
ORDER BY list_position(['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'], category);

SELECT 'E5. Distribusi blok waktu per grup' AS section;

SELECT category AS time_block, n_ad, pct_ad, n_psa, pct_psa, diff_pp
FROM v_dist_wide
WHERE section = 'block_distribution'
ORDER BY category;

SELECT 'E6. Distribusi jam paparan terbanyak per grup' AS section;

SELECT category AS most_ads_hour, n_ad, pct_ad, n_psa, pct_psa, diff_pp
FROM v_dist_wide
WHERE section = 'hour_distribution'
ORDER BY category;

SELECT 'E7. Distribusi bucket paparan per grup' AS section;

SELECT category AS exposure_bucket, n_ad, pct_ad, n_psa, pct_psa, diff_pp
FROM v_dist_wide
WHERE section = 'bucket_distribution'
ORDER BY category;

-- ----------------------------------------------------------------------------
-- E8. Keseimbangan antar grup (deskriptif; variabel post-treatment, bukan uji randomization)
-- ----------------------------------------------------------------------------
SELECT 'E8. Keseimbangan antar grup (TVD dan SMD)' AS section;

SELECT
    category                                   AS dimension,
    metric,
    round(value, 4)                            AS value,
    n_rows                                     AS n_categories
FROM eda_summary
WHERE section = 'balance'
ORDER BY metric, category;

-- ----------------------------------------------------------------------------
-- E9. Rekonsiliasi: jumlah per kategori = ukuran grup (harus MATCH)
-- ----------------------------------------------------------------------------
SELECT 'E9. Rekonsiliasi distribusi terhadap ukuran grup' AS section;

SELECT
    c.section,
    c.test_group,
    CAST(SUM(c.value) AS BIGINT)                          AS sum_n_categories,
    CAST(g.value AS BIGINT)                               AS group_n,
    CASE WHEN SUM(c.value) = g.value THEN 'MATCH' ELSE 'MISMATCH' END AS status
FROM eda_summary c
JOIN eda_summary g
  ON g.section = 'group_size' AND g.metric = 'n_users' AND g.test_group = c.test_group
WHERE c.section LIKE '%_distribution' AND c.metric = 'n_users'
GROUP BY c.section, c.test_group, g.value
ORDER BY c.section, c.test_group;

-- ----------------------------------------------------------------------------
-- 2. Export: eda_summary (Parquet) + verifikasi
-- ----------------------------------------------------------------------------
COPY (SELECT * FROM eda_summary ORDER BY section, test_group, category, metric)
TO 'data/processed/06_eda_summary.parquet' (FORMAT PARQUET, COMPRESSION ZSTD);

SELECT 'E10. Verifikasi parquet eda_summary' AS section;

SELECT
    COUNT(*)                                   AS n_rows_parquet,
    (SELECT COUNT(*) FROM eda_summary)         AS n_rows_table,
    CASE WHEN COUNT(*) = (SELECT COUNT(*) FROM eda_summary)
         THEN 'MATCH' ELSE 'MISMATCH' END      AS status
FROM read_parquet('data/processed/06_eda_summary.parquet');
