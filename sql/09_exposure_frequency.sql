-- ============================================================================
-- FILE:        sql/09_exposure_frequency.sql
-- TAHAP:       Tahap 10 (Lanjutan, EKSPLORATIF)
-- TUJUAN:      Exposure Frequency Analysis: CR per exposure_bucket (D4) PER GRUP, distribusi paparan antar
--              grup, tren CR menurut frekuensi paparan (hipotesis diminishing returns), dan penandaan sel
--              yang melanggar D5.
-- ============================================================================
-- GRAIN:       1 baris = 1 sel (bucket x grup) / 1 bucket / 1 langkah antar bucket (lihat tiap bagian).
-- POPULATION:  Exposure Population = Valid Analysis Population AND has_valid_exposure.
-- DENOMINATOR: n = jumlah user valid di sel (bucket x grup). CR sel = konversi sel / n sel.
--              n dan jumlah konversi SELALU ditampilkan di samping setiap rate.
-- ============================================================================
-- Jalankan (PowerShell, dari root folder proyek):
--   .\duckdb.exe ab_testing.duckdb -c ".read sql/09_exposure_frequency.sql"
--
-- Prasyarat: Tahap 5-8 selesai (marketing_ab_clean dengan exposure_bucket; ab_primary dari Tahap 8).
--
-- EDA / ANALISIS SEGMEN GOVERNANCE (docs/methodology.md):
--   * Seluruh isi file ini EKSPLORATIF. Bucket terkunci (D4): b1 <= 13, b2 14-27, b3 28-57, b4 58-202, b5 > 202.
--   * Tidak ada uji lift per bucket (D6 hanya untuk hari dan blok waktu). Hanya CR, interval Wilson (K3),
--     dan selisih titik antar grup.
--   * D5: sel dengan < 500 user ATAU < 30 konversi ditandai is_small_segment. Rate-nya ditampilkan
--     tetapi TIDAK diinterpretasikan, dan tidak dimasukkan ke selisih atau tren.
--   * total_ads adalah variabel post-treatment (D7). Hubungan paparan dan konversi bersifat observasional:
--     user yang lebih aktif cenderung terpapar lebih banyak iklan DAN lebih mungkin konversi, sehingga
--     hubungan ini bisa mencerminkan aktivitas user, bukan efek iklan. Tidak ada klaim sebab-akibat.
-- ============================================================================

.mode markdown
.maxrows 1000

-- ----------------------------------------------------------------------------
-- 0. Macro interval Wilson 95% untuk proporsi (K3). z_0,975 = 1,959963984540054
-- ----------------------------------------------------------------------------
CREATE OR REPLACE MACRO ab_wilson_center(x, n) AS
    ((x::DOUBLE / n::DOUBLE) + 1.959963984540054 * 1.959963984540054 / (2.0 * n::DOUBLE))
    / (1.0 + 1.959963984540054 * 1.959963984540054 / n::DOUBLE);

CREATE OR REPLACE MACRO ab_wilson_half(x, n) AS
    1.959963984540054
    * sqrt((x::DOUBLE / n::DOUBLE) * (1.0 - x::DOUBLE / n::DOUBLE) / n::DOUBLE
           + 1.959963984540054 * 1.959963984540054 / (4.0 * n::DOUBLE * n::DOUBLE))
    / (1.0 + 1.959963984540054 * 1.959963984540054 / n::DOUBLE);

CREATE OR REPLACE MACRO ab_wilson_low(x, n)  AS
    CASE WHEN x = 0 THEN 0.0 ELSE GREATEST(0.0, ab_wilson_center(x, n) - ab_wilson_half(x, n)) END;
CREATE OR REPLACE MACRO ab_wilson_high(x, n) AS
    CASE WHEN x = n THEN 1.0 ELSE LEAST(1.0, ab_wilson_center(x, n) + ab_wilson_half(x, n)) END;

-- ----------------------------------------------------------------------------
-- 1. Sel bucket x grup (dan gabungan ALL): n, konversi, CR, Wilson CI, kontribusi, flag D5
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE exposure_bucket_cells AS
WITH base AS (
    SELECT
        CASE WHEN GROUPING(test_group) = 1 THEN 'ALL' ELSE test_group END   AS grp,
        exposure_bucket,
        CASE exposure_bucket
            WHEN 'b1_le_p50'  THEN 1 WHEN 'b2_p50_p75' THEN 2 WHEN 'b3_p75_p90' THEN 3
            WHEN 'b4_p90_p99' THEN 4 WHEN 'b5_gt_p99'  THEN 5 END           AS bucket_ord,
        COUNT(*)                                                            AS n_users,
        COUNT(*) FILTER (WHERE is_converted)                                AS n_converted,
        MIN(total_ads)                                                      AS min_total_ads,
        MAX(total_ads)                                                      AS max_total_ads
    FROM marketing_ab_clean
    WHERE is_valid_user AND has_valid_exposure
    GROUP BY GROUPING SETS ((exposure_bucket, test_group), (exposure_bucket))
)
SELECT
    grp, exposure_bucket, bucket_ord, n_users, n_converted, min_total_ads, max_total_ads,
    n_converted::DOUBLE / n_users                                           AS conversion_rate,
    ab_wilson_low(n_converted, n_users)                                     AS wilson_low,
    ab_wilson_high(n_converted, n_users)                                    AS wilson_high,
    100.0 * n_users / SUM(n_users) OVER (PARTITION BY grp)                  AS pct_of_group_users,
    100.0 * n_converted / SUM(n_converted) OVER (PARTITION BY grp)          AS pct_of_group_conversions,
    (n_users < 500 OR n_converted < 30)                                     AS is_small_segment
FROM base;

SELECT 'X1. CR per bucket paparan per grup (EKSPLORATIF, n dan konversi di samping setiap rate)' AS section;

SELECT
    exposure_bucket,
    grp                                          AS test_group,
    n_users,
    n_converted,
    round(100.0 * conversion_rate, 4)            AS cr_pct,
    round(100.0 * wilson_low, 4)                 AS wilson95_low_pct,
    round(100.0 * wilson_high, 4)                AS wilson95_high_pct,
    round(pct_of_group_users, 2)                 AS pct_of_group_users,
    round(pct_of_group_conversions, 2)           AS pct_of_group_conv,
    is_small_segment,
    CASE WHEN is_small_segment THEN 'kecil (D5): rate tidak diinterpretasikan' ELSE 'ok' END AS keterangan
FROM exposure_bucket_cells
ORDER BY bucket_ord, CASE grp WHEN 'ad' THEN 1 WHEN 'psa' THEN 2 ELSE 3 END;

-- ----------------------------------------------------------------------------
-- 2. Distribusi paparan antar grup dan rentang bucket
-- ----------------------------------------------------------------------------
SELECT 'X2. Distribusi bucket antar grup dan rentang total_ads (verifikasi D4)' AS section;

SELECT
    exposure_bucket,
    MIN(min_total_ads) FILTER (WHERE grp = 'ALL')                        AS min_total_ads,
    MAX(max_total_ads) FILTER (WHERE grp = 'ALL')                        AS max_total_ads,
    MAX(n_users) FILTER (WHERE grp = 'ad')                               AS n_ad,
    round(MAX(pct_of_group_users) FILTER (WHERE grp = 'ad'), 2)          AS pct_ad,
    MAX(n_users) FILTER (WHERE grp = 'psa')                              AS n_psa,
    round(MAX(pct_of_group_users) FILTER (WHERE grp = 'psa'), 2)         AS pct_psa,
    round(MAX(pct_of_group_users) FILTER (WHERE grp = 'ad')
        - MAX(pct_of_group_users) FILTER (WHERE grp = 'psa'), 2)         AS diff_pp
FROM exposure_bucket_cells
GROUP BY exposure_bucket, bucket_ord
ORDER BY bucket_ord;

-- ----------------------------------------------------------------------------
-- 3. Selisih CR ad vs psa per bucket (titik, tanpa uji; hanya jika kedua sel lolos D5)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE exposure_bucket_compare AS
SELECT
    a.exposure_bucket, a.bucket_ord,
    a.n_users AS n_ad,  a.n_converted AS conv_ad,  a.conversion_rate AS cr_ad,  a.is_small_segment AS small_ad,
    p.n_users AS n_psa, p.n_converted AS conv_psa, p.conversion_rate AS cr_psa, p.is_small_segment AS small_psa,
    (NOT a.is_small_segment AND NOT p.is_small_segment)                  AS diff_interpretable,
    CASE WHEN NOT a.is_small_segment AND NOT p.is_small_segment
         THEN 100.0 * (a.conversion_rate - p.conversion_rate) END        AS diff_pp
FROM exposure_bucket_cells a
JOIN exposure_bucket_cells p
  ON a.exposure_bucket = p.exposure_bucket AND a.grp = 'ad' AND p.grp = 'psa';

SELECT 'X3. Selisih CR ad - psa per bucket (titik, tanpa uji lift, D6)' AS section;

SELECT
    exposure_bucket,
    n_ad, conv_ad, round(100.0 * cr_ad, 4)   AS cr_ad_pct,
    n_psa, conv_psa, round(100.0 * cr_psa, 4) AS cr_psa_pct,
    round(diff_pp, 4)                         AS diff_pp,
    CASE WHEN diff_interpretable THEN 'ok'
         ELSE 'tidak diinterpretasikan (sel kecil, D5)' END AS keterangan
FROM exposure_bucket_compare
ORDER BY bucket_ord;

-- ----------------------------------------------------------------------------
-- 4. Tren CR menurut frekuensi paparan dalam grup (hipotesis diminishing returns, EKSPLORATIF)
--    delta_pp   = CR bucket - CR bucket sebelumnya (hanya jika kedua sel lolos D5)
--    cr_index   = CR bucket / CR b1 (b1 = bucket paparan terendah)
--    gain_shrinking = delta saat ini lebih kecil dari delta sebelumnya (indikasi diminishing returns)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE exposure_trend AS
WITH c AS (
    SELECT grp, exposure_bucket, bucket_ord, n_users, n_converted, conversion_rate, is_small_segment
    FROM exposure_bucket_cells
    WHERE grp IN ('ad', 'psa', 'ALL')
),
d AS (
    SELECT
        c.*,
        LAG(conversion_rate)    OVER (PARTITION BY grp ORDER BY bucket_ord) AS prev_cr,
        LAG(is_small_segment)   OVER (PARTITION BY grp ORDER BY bucket_ord) AS prev_small,
        FIRST_VALUE(conversion_rate) OVER (PARTITION BY grp ORDER BY bucket_ord) AS cr_b1
    FROM c
),
e AS (
    SELECT
        d.*,
        CASE WHEN prev_cr IS NOT NULL AND NOT is_small_segment AND NOT prev_small
             THEN 100.0 * (conversion_rate - prev_cr) END AS delta_pp
    FROM d
)
SELECT
    e.*,
    conversion_rate / cr_b1                                                  AS cr_index,
    LAG(delta_pp) OVER (PARTITION BY grp ORDER BY bucket_ord)                AS prev_delta_pp,
    CASE WHEN delta_pp IS NOT NULL
          AND LAG(delta_pp) OVER (PARTITION BY grp ORDER BY bucket_ord) IS NOT NULL
         THEN delta_pp < LAG(delta_pp) OVER (PARTITION BY grp ORDER BY bucket_ord) END AS gain_shrinking
FROM e;

SELECT 'X4. Tren CR menurut frekuensi paparan dalam grup (EKSPLORATIF)' AS section;

SELECT
    grp                                        AS test_group,
    exposure_bucket,
    n_users, n_converted,
    round(100.0 * conversion_rate, 4)          AS cr_pct,
    round(cr_index, 3)                         AS cr_index_vs_b1,
    round(delta_pp, 4)                         AS delta_pp_vs_prev_bucket,
    gain_shrinking,
    CASE WHEN is_small_segment THEN 'sel kecil (D5): tidak diinterpretasikan' ELSE 'ok' END AS keterangan
FROM exposure_trend
ORDER BY CASE grp WHEN 'ad' THEN 1 WHEN 'psa' THEN 2 ELSE 3 END, bucket_ord;

-- ----------------------------------------------------------------------------
-- 5. Rekonsiliasi dan pemeriksaan (semua harus PASS)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE exposure_checks AS
SELECT check_id, check_name, expected, actual,
       CASE WHEN abs(expected - actual) <= tolerance THEN 'PASS' ELSE 'FAIL' END AS status
FROM (
    SELECT 'X01' AS check_id, 'SUM(n) bucket grup ad = Exposure Population grup ad' AS check_name,
           (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND has_valid_exposure AND is_treatment)::DOUBLE AS expected,
           (SELECT SUM(n_users) FROM exposure_bucket_cells WHERE grp = 'ad')::DOUBLE AS actual, 0.0 AS tolerance
    UNION ALL
    SELECT 'X02', 'SUM(n) bucket grup psa = Exposure Population grup psa',
           (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND has_valid_exposure AND is_control)::DOUBLE,
           (SELECT SUM(n_users) FROM exposure_bucket_cells WHERE grp = 'psa')::DOUBLE, 0.0
    UNION ALL
    SELECT 'X03', 'SUM(n) bucket ALL = Exposure Population',
           (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND has_valid_exposure)::DOUBLE,
           (SELECT SUM(n_users) FROM exposure_bucket_cells WHERE grp = 'ALL')::DOUBLE, 0.0
    UNION ALL
    SELECT 'X04', 'SUM(konversi) bucket grup ad = konversi ad Tahap 8',
           (SELECT conv_ad FROM ab_primary)::DOUBLE,
           (SELECT SUM(n_converted) FROM exposure_bucket_cells WHERE grp = 'ad')::DOUBLE, 0.0
    UNION ALL
    SELECT 'X05', 'SUM(konversi) bucket grup psa = konversi psa Tahap 8',
           (SELECT conv_psa FROM ab_primary)::DOUBLE,
           (SELECT SUM(n_converted) FROM exposure_bucket_cells WHERE grp = 'psa')::DOUBLE, 0.0
    UNION ALL
    SELECT 'X06', 'Setiap sel ALL = sel ad + sel psa (n)',
           0.0,
           (SELECT COUNT(*) FROM exposure_bucket_cells a
              JOIN exposure_bucket_cells p ON a.exposure_bucket = p.exposure_bucket AND a.grp = 'ad' AND p.grp = 'psa'
              JOIN exposure_bucket_cells t ON a.exposure_bucket = t.exposure_bucket AND t.grp = 'ALL'
             WHERE a.n_users + p.n_users <> t.n_users)::DOUBLE, 0.0
    UNION ALL
    SELECT 'X07', 'Setiap CR sel berada di dalam interval Wilson-nya (pelanggaran)',
           0.0,
           (SELECT COUNT(*) FROM exposure_bucket_cells
             WHERE conversion_rate < wilson_low - 1e-12 OR conversion_rate > wilson_high + 1e-12)::DOUBLE, 0.0
    UNION ALL
    SELECT 'X08', 'Batas Wilson berada di dalam [0, 1] (pelanggaran)',
           0.0,
           (SELECT COUNT(*) FROM exposure_bucket_cells
             WHERE wilson_low < 0 OR wilson_high > 1)::DOUBLE, 0.0
    UNION ALL
    SELECT 'X09', 'Rentang bucket tidak tumpang tindih (max bucket k < min bucket k+1)',
           0.0,
           (SELECT COUNT(*) FROM exposure_bucket_cells a
              JOIN exposure_bucket_cells b ON a.grp = 'ALL' AND b.grp = 'ALL' AND b.bucket_ord = a.bucket_ord + 1
             WHERE a.max_total_ads >= b.min_total_ads)::DOUBLE, 0.0
    UNION ALL
    SELECT 'X10', 'Jumlah bucket = 5 (D4)',
           5.0, (SELECT COUNT(DISTINCT exposure_bucket) FROM exposure_bucket_cells)::DOUBLE, 0.0
    UNION ALL
    SELECT 'X11', 'SUM(pct_of_group_users) = 100 per grup (selisih terbesar)',
           0.0,
           (SELECT MAX(abs(s - 100.0)) FROM (SELECT grp, SUM(pct_of_group_users) AS s FROM exposure_bucket_cells GROUP BY grp))::DOUBLE,
           1e-9
);

SELECT 'X5. Rekonsiliasi dan pemeriksaan' AS section;

SELECT check_id, check_name, expected, actual, status FROM exposure_checks ORDER BY check_id;

SELECT
    COUNT(*)                                     AS n_checks,
    COUNT(*) FILTER (WHERE status = 'PASS')      AS n_pass,
    COUNT(*) FILTER (WHERE status = 'FAIL')      AS n_fail,
    CASE WHEN COUNT(*) FILTER (WHERE status = 'FAIL') = 0 THEN 'ALL PASS' ELSE 'FAIL' END AS exposure_gate
FROM exposure_checks;

SELECT 'X6. Ringkasan sel kecil (D5)' AS section;

SELECT
    grp                                          AS test_group,
    COUNT(*)                                     AS n_cells,
    COUNT(*) FILTER (WHERE is_small_segment)     AS n_small_cells,
    string_agg(exposure_bucket, ', ' ORDER BY bucket_ord) FILTER (WHERE is_small_segment) AS small_buckets
FROM exposure_bucket_cells
GROUP BY grp
ORDER BY CASE grp WHEN 'ad' THEN 1 WHEN 'psa' THEN 2 ELSE 3 END;
