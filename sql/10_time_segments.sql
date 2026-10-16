-- ============================================================================
-- FILE:        sql/10_time_segments.sql
-- TAHAP:       Tahap 11 (Lanjutan, EKSPLORATIF)
-- TUJUAN:      Time Segments Analysis: CR per hari (family 7), per blok waktu (family 4), dan per jam (24, deskriptif),
--              per grup. Uji lift per hari dan per blok dengan koreksi Holm (D6). Penandaan sel kecil (D5).
-- ============================================================================
-- GRAIN:       1 baris = 1 sel (segmen x grup) atau 1 segmen (tabel lebar).
-- POPULATION:  Time Population = Valid Analysis Population AND has_valid_time.
-- DENOMINATOR: n = jumlah user valid di sel (segmen x grup). CR sel = konversi sel / n sel.
--              n dan jumlah konversi SELALU ditampilkan di samping setiap rate.
-- ============================================================================
-- Jalankan (PowerShell, dari root folder proyek):
--   .\duckdb.exe ab_testing.duckdb -c ".read sql/10_time_segments.sql"
--
-- Prasyarat: Tahap 5-9 selesai; macro ab_norm_sf (sql/07_ab_testing.sql) sudah tersimpan di
-- ab_testing.duckdb dan tabel ab_primary ada. Macro Wilson didefinisikan di bawah.
--
-- ATURAN YANG DIPAKAI (docs/methodology.md, TIDAK diubah di sini):
--   D4  blok waktu: 00-05, 06-11, 12-17, 18-23 (dari most_ads_hour)
--   D5  sel dengan < 500 user ATAU < 30 konversi = is_small_segment: rate ditampilkan tetapi TIDAK
--       diinterpretasikan dan tidak diuji
--   D6  uji lift per segmen HANYA untuk hari (family 7) dan blok waktu (family 4), masing-masing dengan
--       koreksi Holm. 24 jam = deskriptif saja (CR dan CI), tanpa uji per jam.
--   K2  ukuran family Holm tetap (hari = 7, blok = 4). Segmen yang tidak dapat diuji karena sel kecil diberi
--       p-value = 1 dalam perhitungan Holm (tidak pernah ditolak), sehingga koreksi tetap konservatif.
--   K3  CI deskriptif per segmen memakai interval Wilson. CI selisih pada segmen yang diuji memakai Wald
--       tak-pooled dan TIDAK disesuaikan untuk multiple testing.
--   D7  hari dan jam adalah variabel post-treatment: pola yang muncul bersifat asosiasi, bukan sebab-akibat.
--   Semua hasil di file ini berlabel EKSPLORATIF.
-- ============================================================================

.mode markdown
.maxrows 1000

-- Macro interval Wilson 95% (sama dengan sql/09, dengan batas dipaksa ke [0, 1] agar tidak muncul -0,000
-- pada sel dengan 0 konversi). Didefinisikan ulang di sini agar skrip ini tidak bergantung pada versi lama.
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

CREATE OR REPLACE TEMP VIEW v_const_t AS
SELECT 0.05 AS alpha, 1.959963984540054 AS z_a;

-- ----------------------------------------------------------------------------
-- 1. Sel segmen x grup (dan ALL): n, konversi, CR, Wilson CI, distribusi, flag D5
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE time_segment_cells AS
WITH src AS (
    SELECT test_group, is_converted, most_ads_day, time_block, most_ads_hour
    FROM marketing_ab_clean
    WHERE is_valid_user AND has_valid_time
),
agg AS (
    SELECT 'day' AS family, most_ads_day AS segment,
           list_position(['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'], most_ads_day) AS seg_order,
           CASE WHEN GROUPING(test_group) = 1 THEN 'ALL' ELSE test_group END AS grp,
           COUNT(*) AS n_users, COUNT(*) FILTER (WHERE is_converted) AS n_converted
    FROM src
    GROUP BY GROUPING SETS ((most_ads_day, test_group), (most_ads_day))
    UNION ALL
    SELECT 'block', time_block,
           list_position(['00-05','06-11','12-17','18-23'], time_block),
           CASE WHEN GROUPING(test_group) = 1 THEN 'ALL' ELSE test_group END,
           COUNT(*), COUNT(*) FILTER (WHERE is_converted)
    FROM src
    GROUP BY GROUPING SETS ((time_block, test_group), (time_block))
    UNION ALL
    SELECT 'hour', lpad(most_ads_hour::VARCHAR, 2, '0'), most_ads_hour + 1,
           CASE WHEN GROUPING(test_group) = 1 THEN 'ALL' ELSE test_group END,
           COUNT(*), COUNT(*) FILTER (WHERE is_converted)
    FROM src
    GROUP BY GROUPING SETS ((most_ads_hour, test_group), (most_ads_hour))
)
SELECT
    family, segment, seg_order, grp, n_users, n_converted,
    n_converted::DOUBLE / n_users                                   AS conversion_rate,
    ab_wilson_low(n_converted, n_users)                             AS wilson_low,
    ab_wilson_high(n_converted, n_users)                            AS wilson_high,
    100.0 * n_users / SUM(n_users) OVER (PARTITION BY family, grp)  AS pct_of_group_users,
    (n_users < 500 OR n_converted < 30)                             AS is_small_segment
FROM agg;

-- ----------------------------------------------------------------------------
-- 2. Tabel lebar ad vs psa + uji lift (hari dan blok) dengan Holm
--    uji: two-proportion z-test dua arah (statistik pooled), sama dengan uji primer
--    Holm: p diurutkan menaik, p_adj(i) = max_{j<=i} min(1, (m - j + 1) * p(j)); segmen yang tidak dapat
--          diuji (sel kecil) diberi p = 1 dan tetap dihitung dalam m (K2)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE time_segment_wide AS
WITH w AS (
    SELECT
        a.family, a.segment, a.seg_order,
        a.n_users AS n_ad,  a.n_converted AS x_ad,  a.conversion_rate AS cr_ad,
        a.wilson_low AS wl_ad, a.wilson_high AS wh_ad, a.is_small_segment AS small_ad, a.pct_of_group_users AS pct_ad,
        p.n_users AS n_psa, p.n_converted AS x_psa, p.conversion_rate AS cr_psa,
        p.wilson_low AS wl_psa, p.wilson_high AS wh_psa, p.is_small_segment AS small_psa, p.pct_of_group_users AS pct_psa
    FROM time_segment_cells a
    JOIN time_segment_cells p
      ON a.family = p.family AND a.segment = p.segment AND a.grp = 'ad' AND p.grp = 'psa'
),
t1 AS (
    SELECT
        w.*,
        (family IN ('day', 'block'))                                                  AS in_test_family,
        (family IN ('day', 'block') AND NOT small_ad AND NOT small_psa)               AS testable,
        (x_ad + x_psa)::DOUBLE / (n_ad + n_psa)                                       AS p_pool,
        cr_ad - cr_psa                                                                AS diff
    FROM w
),
t2 AS (
    SELECT
        t1.*,
        CASE WHEN testable THEN sqrt(p_pool * (1 - p_pool) * (1.0 / n_ad + 1.0 / n_psa)) END                 AS se_pool,
        CASE WHEN testable THEN sqrt(cr_ad * (1 - cr_ad) / n_ad + cr_psa * (1 - cr_psa) / n_psa) END         AS se_unp
    FROM t1
),
t3 AS (
    SELECT
        t2.*,
        CASE WHEN testable THEN diff / se_pool END                                    AS z
    FROM t2
),
t4 AS (
    SELECT
        t3.*,
        CASE WHEN testable THEN 2.0 * ab_norm_sf(abs(z)) END                          AS p_raw,
        CASE WHEN testable THEN diff - (SELECT z_a FROM v_const_t) * se_unp END       AS ci_low,
        CASE WHEN testable THEN diff + (SELECT z_a FROM v_const_t) * se_unp END       AS ci_high,
        -- chi-square dari frekuensi harapan (aljabar berbeda, untuk verifikasi z^2)
        CASE WHEN testable THEN
            (x_ad - n_ad * (x_ad + x_psa)::DOUBLE / (n_ad + n_psa)) ^ 2 / (n_ad * (x_ad + x_psa)::DOUBLE / (n_ad + n_psa))
          + ((n_ad - x_ad) - n_ad * ((n_ad + n_psa) - (x_ad + x_psa))::DOUBLE / (n_ad + n_psa)) ^ 2
              / (n_ad * ((n_ad + n_psa) - (x_ad + x_psa))::DOUBLE / (n_ad + n_psa))
          + (x_psa - n_psa * (x_ad + x_psa)::DOUBLE / (n_ad + n_psa)) ^ 2 / (n_psa * (x_ad + x_psa)::DOUBLE / (n_ad + n_psa))
          + ((n_psa - x_psa) - n_psa * ((n_ad + n_psa) - (x_ad + x_psa))::DOUBLE / (n_ad + n_psa)) ^ 2
              / (n_psa * ((n_ad + n_psa) - (x_ad + x_psa))::DOUBLE / (n_ad + n_psa))
        END                                                                           AS chi2_alt
    FROM t3
),
t5 AS (
    SELECT
        t4.*,
        CASE WHEN in_test_family THEN COALESCE(p_raw, 1.0) END                        AS p_for_holm,
        CASE WHEN in_test_family THEN COUNT(*) OVER (PARTITION BY family) END         AS holm_m
    FROM t4
),
t6 AS (
    SELECT
        t5.*,
        CASE WHEN in_test_family THEN
            ROW_NUMBER() OVER (PARTITION BY family ORDER BY p_for_holm, seg_order) END AS holm_rank
    FROM t5
),
t7 AS (
    SELECT
        t6.*,
        CASE WHEN in_test_family THEN LEAST(1.0, (holm_m - holm_rank + 1) * p_for_holm) END AS holm_step
    FROM t6
)
SELECT
    t7.*,
    CASE WHEN in_test_family THEN
        MAX(holm_step) OVER (PARTITION BY family ORDER BY holm_rank
                             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) END    AS p_holm,
    (testable AND
        MAX(holm_step) OVER (PARTITION BY family ORDER BY holm_rank
                             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        < (SELECT alpha FROM v_const_t))                                              AS significant_holm,
    CASE WHEN NOT small_ad AND NOT small_psa THEN 100.0 * diff END                    AS diff_pp,
    pct_ad - pct_psa                                                                  AS share_diff_pp
FROM t7;

-- ----------------------------------------------------------------------------
-- 3. HARI (family 7)
-- ----------------------------------------------------------------------------
SELECT 'T1. Hari (family 7): CR per grup, selisih, dan uji lift dengan Holm (EKSPLORATIF)' AS section;

SELECT
    segment AS most_ads_day,
    n_ad, x_ad AS conv_ad, round(100.0 * cr_ad, 4) AS cr_ad_pct,
    n_psa, x_psa AS conv_psa, round(100.0 * cr_psa, 4) AS cr_psa_pct,
    round(diff_pp, 4)                    AS diff_pp,
    round(100.0 * ci_low, 4)             AS ci95_low_pp,
    round(100.0 * ci_high, 4)            AS ci95_high_pp,
    p_raw                                AS p_raw,
    p_holm                               AS p_holm,
    CASE WHEN NOT testable THEN 'tidak diuji (sel kecil, D5), p = 1 dalam Holm'
         WHEN significant_holm THEN 'signifikan setelah Holm'
         ELSE 'tidak signifikan setelah Holm' END AS keterangan
FROM time_segment_wide
WHERE family = 'day'
ORDER BY seg_order;

SELECT 'T1b. Hari: interval Wilson 95% per grup dan distribusi antar grup' AS section;

SELECT
    segment AS most_ads_day,
    round(100.0 * wl_ad, 4)  AS wilson_ad_low_pct,  round(100.0 * wh_ad, 4)  AS wilson_ad_high_pct,
    round(100.0 * wl_psa, 4) AS wilson_psa_low_pct, round(100.0 * wh_psa, 4) AS wilson_psa_high_pct,
    round(pct_ad, 2) AS pct_users_ad, round(pct_psa, 2) AS pct_users_psa, round(share_diff_pp, 2) AS share_diff_pp
FROM time_segment_wide
WHERE family = 'day'
ORDER BY seg_order;

-- ----------------------------------------------------------------------------
-- 4. BLOK WAKTU (family 4)
-- ----------------------------------------------------------------------------
SELECT 'T2. Blok waktu (family 4): CR per grup, selisih, dan uji lift dengan Holm (EKSPLORATIF)' AS section;

SELECT
    segment AS time_block,
    n_ad, x_ad AS conv_ad, round(100.0 * cr_ad, 4) AS cr_ad_pct,
    n_psa, x_psa AS conv_psa, round(100.0 * cr_psa, 4) AS cr_psa_pct,
    round(diff_pp, 4)                    AS diff_pp,
    round(100.0 * ci_low, 4)             AS ci95_low_pp,
    round(100.0 * ci_high, 4)            AS ci95_high_pp,
    p_raw                                AS p_raw,
    p_holm                               AS p_holm,
    CASE WHEN NOT testable THEN 'tidak diuji (sel kecil, D5), p = 1 dalam Holm'
         WHEN significant_holm THEN 'signifikan setelah Holm'
         ELSE 'tidak signifikan setelah Holm' END AS keterangan
FROM time_segment_wide
WHERE family = 'block'
ORDER BY seg_order;

SELECT 'T2b. Blok waktu: interval Wilson 95% per grup dan distribusi antar grup' AS section;

SELECT
    segment AS time_block,
    round(100.0 * wl_ad, 4)  AS wilson_ad_low_pct,  round(100.0 * wh_ad, 4)  AS wilson_ad_high_pct,
    round(100.0 * wl_psa, 4) AS wilson_psa_low_pct, round(100.0 * wh_psa, 4) AS wilson_psa_high_pct,
    round(pct_ad, 2) AS pct_users_ad, round(pct_psa, 2) AS pct_users_psa, round(share_diff_pp, 2) AS share_diff_pp
FROM time_segment_wide
WHERE family = 'block'
ORDER BY seg_order;

-- ----------------------------------------------------------------------------
-- 5. JAM (24, DESKRIPTIF SAJA: tanpa uji per jam, D6)
-- ----------------------------------------------------------------------------
SELECT 'T3. Jam (24, deskriptif saja): CR dan interval Wilson per grup, tanpa uji' AS section;

SELECT
    segment AS most_ads_hour,
    n_ad, x_ad AS conv_ad, round(100.0 * cr_ad, 4) AS cr_ad_pct,
    round(100.0 * wl_ad, 3) AS wil_ad_low, round(100.0 * wh_ad, 3) AS wil_ad_high,
    n_psa, x_psa AS conv_psa, round(100.0 * cr_psa, 4) AS cr_psa_pct,
    round(100.0 * wl_psa, 3) AS wil_psa_low, round(100.0 * wh_psa, 3) AS wil_psa_high,
    CASE WHEN small_ad THEN 'ad kecil' ELSE '' END || CASE WHEN small_ad AND small_psa THEN ' + ' ELSE '' END
        || CASE WHEN small_psa THEN 'psa kecil (D5)' ELSE '' END AS sel_kecil
FROM time_segment_wide
WHERE family = 'hour'
ORDER BY seg_order;

SELECT 'T3b. Jam: distribusi user antar grup (persen di dalam grup)' AS section;

SELECT
    segment AS most_ads_hour,
    round(pct_ad, 2) AS pct_users_ad, round(pct_psa, 2) AS pct_users_psa, round(share_diff_pp, 2) AS share_diff_pp
FROM time_segment_wide
WHERE family = 'hour'
ORDER BY seg_order;

-- ----------------------------------------------------------------------------
-- 6. Ringkasan sel kecil (D5) per family dan grup
-- ----------------------------------------------------------------------------
SELECT 'T4. Ringkasan sel kecil (D5)' AS section;

SELECT
    family,
    grp                                          AS test_group,
    COUNT(*)                                     AS n_cells,
    COUNT(*) FILTER (WHERE is_small_segment)     AS n_small_cells
FROM time_segment_cells
WHERE grp IN ('ad', 'psa')
GROUP BY family, grp
ORDER BY CASE family WHEN 'day' THEN 1 WHEN 'block' THEN 2 ELSE 3 END, grp;

-- ----------------------------------------------------------------------------
-- 7. Rekonsiliasi dan pemeriksaan (semua harus PASS)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE time_checks AS
SELECT check_id, check_name, expected, actual,
       CASE WHEN abs(expected - actual) <= tolerance THEN 'PASS' ELSE 'FAIL' END AS status
FROM (
    SELECT 'T01' AS check_id, 'Hari: SUM(n) grup ad = Time Population ad' AS check_name,
           (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND has_valid_time AND is_treatment)::DOUBLE AS expected,
           (SELECT SUM(n_users) FROM time_segment_cells WHERE family = 'day' AND grp = 'ad')::DOUBLE AS actual, 0.0 AS tolerance
    UNION ALL
    SELECT 'T02', 'Hari: SUM(n) grup psa = Time Population psa',
           (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND has_valid_time AND is_control)::DOUBLE,
           (SELECT SUM(n_users) FROM time_segment_cells WHERE family = 'day' AND grp = 'psa')::DOUBLE, 0.0
    UNION ALL
    SELECT 'T03', 'Blok: SUM(n) grup ad = Time Population ad',
           (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND has_valid_time AND is_treatment)::DOUBLE,
           (SELECT SUM(n_users) FROM time_segment_cells WHERE family = 'block' AND grp = 'ad')::DOUBLE, 0.0
    UNION ALL
    SELECT 'T04', 'Blok: SUM(n) grup psa = Time Population psa',
           (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND has_valid_time AND is_control)::DOUBLE,
           (SELECT SUM(n_users) FROM time_segment_cells WHERE family = 'block' AND grp = 'psa')::DOUBLE, 0.0
    UNION ALL
    SELECT 'T05', 'Jam: SUM(n) grup ad = Time Population ad',
           (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND has_valid_time AND is_treatment)::DOUBLE,
           (SELECT SUM(n_users) FROM time_segment_cells WHERE family = 'hour' AND grp = 'ad')::DOUBLE, 0.0
    UNION ALL
    SELECT 'T06', 'Jam: SUM(n) grup psa = Time Population psa',
           (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND has_valid_time AND is_control)::DOUBLE,
           (SELECT SUM(n_users) FROM time_segment_cells WHERE family = 'hour' AND grp = 'psa')::DOUBLE, 0.0
    UNION ALL
    SELECT 'T07', 'Konversi ad di setiap family = konversi ad Tahap 8 (selisih terbesar antar family)',
           0.0,
           (SELECT MAX(abs(s - (SELECT conv_ad FROM ab_primary))) FROM
               (SELECT family, SUM(n_converted) AS s FROM time_segment_cells WHERE grp = 'ad' GROUP BY family))::DOUBLE, 0.0
    UNION ALL
    SELECT 'T08', 'Konversi psa di setiap family = konversi psa Tahap 8 (selisih terbesar antar family)',
           0.0,
           (SELECT MAX(abs(s - (SELECT conv_psa FROM ab_primary))) FROM
               (SELECT family, SUM(n_converted) AS s FROM time_segment_cells WHERE grp = 'psa' GROUP BY family))::DOUBLE, 0.0
    UNION ALL
    SELECT 'T09', 'Jumlah segmen: hari = 7',  7.0,  (SELECT COUNT(*) FROM time_segment_wide WHERE family = 'day')::DOUBLE, 0.0
    UNION ALL
    SELECT 'T10', 'Jumlah segmen: blok = 4',  4.0,  (SELECT COUNT(*) FROM time_segment_wide WHERE family = 'block')::DOUBLE, 0.0
    UNION ALL
    SELECT 'T11', 'Jumlah segmen: jam = 24',  24.0, (SELECT COUNT(*) FROM time_segment_wide WHERE family = 'hour')::DOUBLE, 0.0
    UNION ALL
    SELECT 'T12', 'Ukuran family Holm: hari m = 7 (K2)', 7.0,
           (SELECT MAX(holm_m) FROM time_segment_wide WHERE family = 'day')::DOUBLE, 0.0
    UNION ALL
    SELECT 'T13', 'Ukuran family Holm: blok m = 4 (K2)', 4.0,
           (SELECT MAX(holm_m) FROM time_segment_wide WHERE family = 'block')::DOUBLE, 0.0
    UNION ALL
    SELECT 'T14', 'Holm: p_holm >= p_raw untuk semua segmen yang diuji (pelanggaran)',
           0.0,
           (SELECT COUNT(*) FROM time_segment_wide WHERE testable AND p_holm < p_raw - 1e-15)::DOUBLE, 0.0
    UNION ALL
    SELECT 'T15', 'Holm: p_holm <= 1 (pelanggaran)',
           0.0,
           (SELECT COUNT(*) FROM time_segment_wide WHERE in_test_family AND p_holm > 1.0)::DOUBLE, 0.0
    UNION ALL
    SELECT 'T16', 'Segmen yang tidak diuji: p_holm = 1 dan tidak signifikan (pelanggaran)',
           0.0,
           (SELECT COUNT(*) FROM time_segment_wide WHERE in_test_family AND NOT testable
              AND (p_holm < 1.0 OR significant_holm))::DOUBLE, 0.0
    UNION ALL
    SELECT 'T17', 'Jam tidak memiliki uji: p_raw dan p_holm kosong (pelanggaran)',
           0.0,
           (SELECT COUNT(*) FROM time_segment_wide WHERE family = 'hour' AND (p_raw IS NOT NULL OR p_holm IS NOT NULL))::DOUBLE, 0.0
    UNION ALL
    SELECT 'T18', 'z^2 = chi-square dari frekuensi harapan (galat relatif terbesar)',
           0.0,
           COALESCE((SELECT MAX(abs(z * z - chi2_alt) / chi2_alt) FROM time_segment_wide WHERE testable), 0.0)::DOUBLE, 1e-9
    UNION ALL
    SELECT 'T19', 'Setiap CR sel berada di dalam interval Wilson-nya (pelanggaran)',
           0.0,
           (SELECT COUNT(*) FROM time_segment_cells WHERE conversion_rate < wilson_low - 1e-12 OR conversion_rate > wilson_high + 1e-12)::DOUBLE, 0.0
    UNION ALL
    SELECT 'T20', 'SUM(pct_of_group_users) = 100 per family dan grup (selisih terbesar)',
           0.0,
           (SELECT MAX(abs(s - 100.0)) FROM
               (SELECT family, grp, SUM(pct_of_group_users) AS s FROM time_segment_cells GROUP BY family, grp))::DOUBLE, 1e-9
);

SELECT 'T5. Rekonsiliasi dan pemeriksaan' AS section;

SELECT check_id, check_name, expected, actual, status FROM time_checks ORDER BY check_id;

SELECT
    COUNT(*)                                     AS n_checks,
    COUNT(*) FILTER (WHERE status = 'PASS')      AS n_pass,
    COUNT(*) FILTER (WHERE status = 'FAIL')      AS n_fail,
    CASE WHEN COUNT(*) FILTER (WHERE status = 'FAIL') = 0 THEN 'ALL PASS' ELSE 'FAIL' END AS time_gate
FROM time_checks;
