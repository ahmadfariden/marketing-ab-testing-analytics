-- ============================================================================
-- FILE:        sql/11_segment_robustness.sql
-- TAHAP:       Tahap 12 (Lanjutan)
-- TUJUAN:      Segment Comparison & Robustness: (1) pemeriksaan Simpson's paradox dan pengaruh komposisi segmen
--              (lift gabungan vs lift terbobot per segmen), (2) sensitivitas eksklusi outlier total_ads ekstrem
--              (dilaporkan, TIDAK menggantikan hasil primer), (3) register analisis konfirmatori vs eksploratif
--              dan register keterbatasan.
-- ============================================================================
-- GRAIN:       Tabel strata: 1 baris = 1 segmen (dimensi x segmen). Tabel estimasi: 1 baris = 1 estimator.
-- POPULATION:  Valid Analysis Population (is_valid_user = TRUE); Time Population untuk hari/blok/jam;
--              Exposure Population untuk bucket paparan.
-- DENOMINATOR: n_ad dan n_psa per segmen. CR segmen = konversi segmen / n segmen.
-- ============================================================================
-- Jalankan (PowerShell, dari root folder proyek):
--   .\duckdb.exe ab_testing.duckdb -c ".read sql/11_segment_robustness.sql"
--
-- Prasyarat: Tahap 5-11 selesai (marketing_ab_clean, ab_primary, time_segment_cells, exposure_bucket_cells,
-- dan macro ab_norm_sf dari sql/07_ab_testing.sql tersimpan di ab_testing.duckdb).
--
-- ATURAN YANG DIPAKAI (docs/methodology.md, TIDAK diubah di sini):
--   D5  sel kecil (< 500 user atau < 30 konversi) tidak diinterpretasikan. Di sini ditangani dengan dua cakupan:
--       "all_strata" (semua segmen, agar populasi tetap utuh) dan "d5_ok_strata" (hanya segmen yang kedua selnya
--       lolos D5, bobot dinormalisasi ulang).
--   D6  tidak ada uji heterogenitas per segmen. Perbedaan antar segmen TIDAK otomatis dianggap efek interaksi.
--   D7  hari, jam, dan paparan adalah variabel post-treatment. Penstratifikasian di sini hanya untuk memeriksa
--       apakah KOMPOSISI segmen mempengaruhi selisih keseluruhan (Simpson's paradox). Ini BUKAN penyesuaian kausal.
--   Semua hasil di file ini berlabel sensitivitas atau eksploratif. Hasil primer tetap Tahap 8.
--
-- ESTIMATOR:
--   Crude                : CR_ad - CR_psa (Tahap 8)
--   Standardisasi        : sum_k w_k x RD_k dengan w_k = (n_ad,k + n_psa,k) / N (komposisi gabungan), RD_k = selisih CR
--                          segmen k. Varians (bobot tetap): sum_k w_k^2 x [CR_ad(1-CR_ad)/n_ad + CR_psa(1-CR_psa)/n_psa].
--   Mantel-Haenszel RD   : sum_k [x_ad n_psa - x_psa n_ad]/N_k / sum_k [n_ad n_psa / N_k]
--                          varians Greenland-Robins: sum_k [x_ad y_ad n_psa^3 + x_psa y_psa n_ad^3]/(n_ad n_psa N_k^2)
--                          dibagi (sum_k n_ad n_psa / N_k)^2, dengan y = n - x. (Rumus diverifikasi lewat simulasi.)
--
-- CATATAN CI: pada dimensi jam, 17 dari 24 sel psa adalah sel kecil dan beberapa memiliki 0 konversi. Varians Wald
-- untuk sel dengan laju 0 bernilai 0, sehingga CI terbobot pada dimensi jam (cakupan "all_strata") dapat terlalu
-- sempit dan hanya indikatif. Cakupan "d5_ok_strata" lebih dapat diandalkan untuk dimensi jam.
--
-- KRITERIA ROBUSTNESS (aturan pelaporan, ditetapkan sebelum membaca hasil):
--   C-arah : lift terbobot atau lift setelah eksklusi > 0 (arah sama dengan hasil primer)
--   C-sig  : batas bawah 95% CI > 0
--   C-D8   : batas bawah 95% CI >= 0,5 pp (verdict pada ambang D8 utama tidak berubah)
-- ============================================================================

.mode markdown
.maxrows 1000

CREATE OR REPLACE TEMP VIEW v_const_r AS
SELECT 0.05 AS alpha, 1.959963984540054 AS z_a;

CREATE OR REPLACE TEMP VIEW v_ab_r AS
SELECT * FROM marketing_ab_clean WHERE is_valid_user;

-- ----------------------------------------------------------------------------
-- 1. Strata per dimensi: day, block, hour, exposure_bucket, dan 'none' (satu strata = seluruh populasi,
--    dipakai sebagai uji konsistensi estimator)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE robust_strata AS
WITH u AS (
    SELECT 'day' AS dim, most_ads_day AS segment,
           list_position(['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'], most_ads_day) AS seg_order,
           test_group, is_converted
    FROM v_ab_r WHERE has_valid_time
    UNION ALL
    SELECT 'block', time_block, list_position(['00-05','06-11','12-17','18-23'], time_block), test_group, is_converted
    FROM v_ab_r WHERE has_valid_time
    UNION ALL
    SELECT 'hour', lpad(most_ads_hour::VARCHAR, 2, '0'), most_ads_hour + 1, test_group, is_converted
    FROM v_ab_r WHERE has_valid_time
    UNION ALL
    SELECT 'exposure_bucket', exposure_bucket,
           CASE exposure_bucket WHEN 'b1_le_p50' THEN 1 WHEN 'b2_p50_p75' THEN 2 WHEN 'b3_p75_p90' THEN 3
                                WHEN 'b4_p90_p99' THEN 4 WHEN 'b5_gt_p99' THEN 5 END,
           test_group, is_converted
    FROM v_ab_r WHERE has_valid_exposure
    UNION ALL
    SELECT 'none', 'all', 1, test_group, is_converted
    FROM v_ab_r
),
a AS (
    SELECT
        dim, segment, seg_order,
        COUNT(*) FILTER (WHERE test_group = 'ad')                          AS n_ad,
        COUNT(*) FILTER (WHERE test_group = 'ad'  AND is_converted)        AS x_ad,
        COUNT(*) FILTER (WHERE test_group = 'psa')                         AS n_psa,
        COUNT(*) FILTER (WHERE test_group = 'psa' AND is_converted)        AS x_psa
    FROM u
    GROUP BY dim, segment, seg_order
)
SELECT
    a.*,
    (n_ad + n_psa)                                                         AS n_total,
    x_ad::DOUBLE / n_ad                                                    AS cr_ad,
    x_psa::DOUBLE / n_psa                                                  AS cr_psa,
    (n_ad >= 500 AND x_ad >= 30 AND n_psa >= 500 AND x_psa >= 30)          AS d5_ok
FROM a;

-- ----------------------------------------------------------------------------
-- 2. Estimator terbobot: standardisasi (komposisi gabungan) dan Mantel-Haenszel
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE robust_estimates AS
WITH sc AS (
    SELECT dim, 'all_strata' AS scope, * EXCLUDE (dim) FROM robust_strata
    UNION ALL
    SELECT dim, 'd5_ok_strata' AS scope, * EXCLUDE (dim) FROM robust_strata WHERE d5_ok
),
k AS (
    SELECT
        dim, scope, segment, n_ad, x_ad, n_psa, x_psa, n_total, cr_ad, cr_psa,
        (cr_ad - cr_psa)                                                                 AS rd_k,
        cr_ad * (1 - cr_ad) / n_ad + cr_psa * (1 - cr_psa) / n_psa                       AS var_k,
        (x_ad::DOUBLE * n_psa - x_psa::DOUBLE * n_ad) / n_total                          AS mh_num_k,
        n_ad::DOUBLE * n_psa / n_total                                                   AS mh_den_k,
        (x_ad::DOUBLE * (n_ad - x_ad) * power(n_psa::DOUBLE, 3)
       + x_psa::DOUBLE * (n_psa - x_psa) * power(n_ad::DOUBLE, 3))
          / (n_ad::DOUBLE * n_psa * power(n_total::DOUBLE, 2))                           AS mh_varnum_k
    FROM sc
),
g AS (
    SELECT
        dim, scope,
        COUNT(*)                                                                         AS n_strata,
        SUM(n_total)                                                                     AS users_covered,
        SUM(n_total * rd_k) / SUM(n_total)                                               AS std_lift,
        SUM(power(n_total::DOUBLE, 2) * var_k) / power(SUM(n_total)::DOUBLE, 2)          AS std_var,
        SUM(mh_num_k) / SUM(mh_den_k)                                                    AS mh_lift,
        SUM(mh_varnum_k) / power(SUM(mh_den_k), 2)                                       AS mh_var
    FROM k
    GROUP BY dim, scope
)
SELECT dim, scope, 'standardized_pooled_weights' AS method, n_strata, users_covered,
       std_lift AS lift, sqrt(std_var) AS se,
       std_lift - (SELECT z_a FROM v_const_r) * sqrt(std_var) AS ci_low,
       std_lift + (SELECT z_a FROM v_const_r) * sqrt(std_var) AS ci_high
FROM g
UNION ALL
SELECT dim, scope, 'mantel_haenszel', n_strata, users_covered,
       mh_lift, sqrt(mh_var),
       mh_lift - (SELECT z_a FROM v_const_r) * sqrt(mh_var),
       mh_lift + (SELECT z_a FROM v_const_r) * sqrt(mh_var)
FROM g;

-- Crude (Tahap 8) sebagai pembanding
CREATE OR REPLACE TEMP VIEW v_crude AS
SELECT abs_lift AS lift, se_unpooled AS se, ci_diff_low AS ci_low, ci_diff_high AS ci_high,
       (SELECT SUM(n_total) FROM robust_strata WHERE dim = 'none') AS users_covered
FROM ab_primary;

SELECT 'R1. Lift gabungan (crude) vs lift terbobot per segmen, SEMUA segmen (sensitivitas, post-treatment)' AS section;

SELECT dim_label, method, n_strata, lift_pp, ci95_low_pp, ci95_high_pp, diff_vs_crude_pp, diff_vs_crude_pct
FROM (
    SELECT 0 AS ord, 'crude (Tahap 8)' AS dim_label, 'crude' AS method, 1 AS n_strata,
           round(100.0 * c.lift, 4) AS lift_pp, round(100.0 * c.ci_low, 4) AS ci95_low_pp, round(100.0 * c.ci_high, 4) AS ci95_high_pp,
           0.0 AS diff_vs_crude_pp, 0.0 AS diff_vs_crude_pct
    FROM v_crude c
    UNION ALL
    SELECT CASE e.dim WHEN 'day' THEN 1 WHEN 'block' THEN 2 WHEN 'hour' THEN 3 WHEN 'exposure_bucket' THEN 4 ELSE 5 END,
           e.dim, e.method, e.n_strata,
           round(100.0 * e.lift, 4), round(100.0 * e.ci_low, 4), round(100.0 * e.ci_high, 4),
           round(100.0 * (e.lift - c.lift), 4), round(100.0 * (e.lift - c.lift) / c.lift, 2)
    FROM robust_estimates e, v_crude c
    WHERE e.scope = 'all_strata' AND e.dim <> 'none'
)
ORDER BY ord, method;

SELECT 'R1b. Lift terbobot hanya pada segmen yang kedua selnya lolos D5 (bobot dinormalisasi ulang)' AS section;

SELECT
    e.dim, e.method, e.n_strata,
    round(100.0 * e.users_covered / c.users_covered, 2)  AS coverage_users_pct,
    round(100.0 * e.lift, 4)                             AS lift_pp,
    round(100.0 * e.ci_low, 4)                           AS ci95_low_pp,
    round(100.0 * e.ci_high, 4)                          AS ci95_high_pp,
    round(100.0 * (e.lift - c.lift), 4)                  AS diff_vs_crude_pp
FROM robust_estimates e, v_crude c
WHERE e.scope = 'd5_ok_strata' AND e.dim <> 'none'
ORDER BY CASE e.dim WHEN 'day' THEN 1 WHEN 'block' THEN 2 WHEN 'hour' THEN 3 ELSE 4 END, e.method;

-- ----------------------------------------------------------------------------
-- 3. Konsistensi arah selisih antar segmen (hanya segmen yang kedua selnya lolos D5)
--    Deskriptif: TIDAK ada uji heterogenitas dan perbedaan antar segmen bukan bukti efek interaksi.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE robust_direction AS
SELECT
    dim,
    COUNT(*)                                                           AS n_segments_total,
    COUNT(*) FILTER (WHERE d5_ok)                                      AS n_segments_readable,
    COUNT(*) FILTER (WHERE d5_ok AND cr_ad - cr_psa > 0)               AS n_positive,
    COUNT(*) FILTER (WHERE d5_ok AND cr_ad - cr_psa < 0)               AS n_negative,
    MIN(100.0 * (cr_ad - cr_psa)) FILTER (WHERE d5_ok)                 AS min_diff_pp,
    MAX(100.0 * (cr_ad - cr_psa)) FILTER (WHERE d5_ok)                 AS max_diff_pp,
    string_agg(segment, ', ' ORDER BY seg_order) FILTER (WHERE d5_ok AND cr_ad - cr_psa < 0) AS negative_segments
FROM robust_strata
WHERE dim <> 'none'
GROUP BY dim;

SELECT 'R2. Konsistensi arah selisih antar segmen (segmen yang dapat dibaca, D5)' AS section;

SELECT
    dim, n_segments_total, n_segments_readable, n_positive, n_negative,
    round(min_diff_pp, 4) AS min_diff_pp, round(max_diff_pp, 4) AS max_diff_pp,
    COALESCE(negative_segments, '-') AS segments_with_negative_diff
FROM robust_direction
ORDER BY CASE dim WHEN 'day' THEN 1 WHEN 'block' THEN 2 WHEN 'hour' THEN 3 ELSE 4 END;

-- ----------------------------------------------------------------------------
-- 4. Sensitivitas eksklusi outlier total_ads ekstrem (dilaporkan, TIDAK menggantikan hasil primer)
--    S0: tanpa eksklusi (harus sama dengan Tahap 8)
--    S1: eksklusi total_ads > P99 gabungan (bucket b5, D4)
--    S2: eksklusi total_ads > pagar ekstrem = Q3 + 3 x IQR (populasi gabungan, dihitung dari data)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE robust_outlier AS
WITH thr AS (
    SELECT
        quantile_cont(total_ads, 0.25) AS q1,
        quantile_cont(total_ads, 0.75) AS q3
    FROM v_ab_r WHERE has_valid_exposure
),
fence AS (SELECT q1, q3, q3 + 3.0 * (q3 - q1) AS extreme_fence FROM thr),
base AS (
    SELECT 'S0 tanpa eksklusi (hasil primer)' AS scenario, 0 AS ord, test_group, is_converted, total_ads FROM v_ab_r
    UNION ALL
    SELECT 'S1 eksklusi total_ads > P99 gabungan (bucket b5)', 1, test_group, is_converted, total_ads
    FROM v_ab_r WHERE exposure_bucket IS DISTINCT FROM 'b5_gt_p99'
    UNION ALL
    SELECT 'S2 eksklusi total_ads > pagar ekstrem (Q3 + 3 IQR)', 2, v.test_group, v.is_converted, v.total_ads
    FROM v_ab_r v, fence f WHERE v.total_ads <= f.extreme_fence
),
g AS (
    SELECT
        scenario, ord,
        COUNT(*) FILTER (WHERE test_group = 'ad')                          AS n_ad,
        COUNT(*) FILTER (WHERE test_group = 'ad'  AND is_converted)        AS x_ad,
        COUNT(*) FILTER (WHERE test_group = 'psa')                         AS n_psa,
        COUNT(*) FILTER (WHERE test_group = 'psa' AND is_converted)        AS x_psa
    FROM base
    GROUP BY scenario, ord
),
s AS (
    SELECT
        g.*,
        x_ad::DOUBLE / n_ad                                                AS cr_ad,
        x_psa::DOUBLE / n_psa                                              AS cr_psa
    FROM g
),
t AS (
    SELECT
        s.*,
        cr_ad - cr_psa                                                     AS lift,
        sqrt(cr_ad * (1 - cr_ad) / n_ad + cr_psa * (1 - cr_psa) / n_psa)   AS se_unp,
        (x_ad + x_psa)::DOUBLE / (n_ad + n_psa)                            AS p_pool
    FROM s
)
SELECT
    t.*,
    lift - (SELECT z_a FROM v_const_r) * se_unp                             AS ci_low,
    lift + (SELECT z_a FROM v_const_r) * se_unp                             AS ci_high,
    lift / sqrt(p_pool * (1 - p_pool) * (1.0 / n_ad + 1.0 / n_psa))         AS z,
    2.0 * ab_norm_sf(abs(lift / sqrt(p_pool * (1 - p_pool) * (1.0 / n_ad + 1.0 / n_psa)))) AS p_value,
    lift / cr_psa                                                           AS rel_lift,
    (SELECT extreme_fence FROM fence)                                       AS extreme_fence
FROM t;

SELECT 'R3a. Sensitivitas eksklusi outlier total_ads (dilaporkan, tidak menggantikan primer)' AS section;

SELECT
    scenario,
    n_ad, x_ad, n_psa, x_psa,
    round(100.0 * cr_ad, 4)        AS cr_ad_pct,
    round(100.0 * cr_psa, 4)       AS cr_psa_pct,
    round(100.0 * lift, 4)         AS lift_pp,
    round(100.0 * ci_low, 4)       AS ci95_low_pp,
    round(100.0 * ci_high, 4)      AS ci95_high_pp,
    p_value,
    round(100.0 * rel_lift, 2)     AS rel_lift_pct
FROM robust_outlier
ORDER BY ord;

SELECT 'R3b. Perubahan terhadap hasil primer' AS section;

SELECT
    o.scenario,
    (p.n_ad + p.n_psa) - (o.n_ad + o.n_psa)                        AS users_excluded,
    round(100.0 * ((p.n_ad + p.n_psa) - (o.n_ad + o.n_psa)) / (p.n_ad + p.n_psa), 2) AS pct_users_excluded,
    (p.conv_ad + p.conv_psa) - (o.x_ad + o.x_psa)                  AS conversions_excluded,
    round(100.0 * (o.lift - p.abs_lift), 4)                        AS lift_change_pp,
    round(100.0 * (o.lift - p.abs_lift) / p.abs_lift, 2)           AS lift_change_pct
FROM robust_outlier o, ab_primary p
ORDER BY o.ord;

SELECT 'R3c. Batas pagar ekstrem yang dipakai (S2)' AS section;

SELECT DISTINCT extreme_fence FROM robust_outlier WHERE ord = 2;

-- ----------------------------------------------------------------------------
-- 5. Verdict robustness (kriteria C-arah, C-sig, C-D8) dan kesimpulan
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE robust_verdict AS
SELECT name, lift, ci_low, ci_high,
       (lift > 0)                  AS c_arah,
       (ci_low > 0)                AS c_sig,
       (100.0 * ci_low >= 0.5)     AS c_d8
FROM (
    SELECT e.dim || ' / ' || e.method || ' / ' || e.scope AS name, e.lift, e.ci_low, e.ci_high
    FROM robust_estimates e
    WHERE e.dim <> 'none'
    UNION ALL
    SELECT scenario, lift, ci_low, ci_high FROM robust_outlier WHERE ord > 0
);

SELECT 'R4a. Verdict robustness per estimator dan skenario' AS section;

SELECT name, round(100.0 * lift, 4) AS lift_pp, round(100.0 * ci_low, 4) AS ci95_low_pp, round(100.0 * ci_high, 4) AS ci95_high_pp,
       c_arah, c_sig, c_d8
FROM robust_verdict
ORDER BY name;

CREATE OR REPLACE TABLE robust_conclusion AS
SELECT
    COUNT(*)                                       AS n_checks_total,
    COUNT(*) FILTER (WHERE c_arah)                 AS n_arah_ok,
    COUNT(*) FILTER (WHERE c_sig)                  AS n_sig_ok,
    COUNT(*) FILTER (WHERE c_d8)                   AS n_d8_ok,
    CASE
        WHEN COUNT(*) FILTER (WHERE c_arah AND c_sig AND c_d8) = COUNT(*)
        THEN 'Arah, signifikansi, dan kesimpulan practical significance (batas bawah CI >= 0,5 pp) tidak berubah pada seluruh estimator terbobot dan skenario eksklusi outlier.'
        WHEN COUNT(*) FILTER (WHERE c_arah AND c_sig) = COUNT(*)
        THEN 'Arah dan signifikansi tidak berubah pada seluruh estimator dan skenario. Kesimpulan practical significance (batas bawah CI >= 0,5 pp) berubah pada: '
             || COALESCE(string_agg(name, ' | ') FILTER (WHERE NOT c_d8), '-') || '.'
        ELSE 'Kesimpulan utama berubah pada: '
             || COALESCE(string_agg(name, ' | ') FILTER (WHERE NOT (c_arah AND c_sig)), '-') || '. Periksa sebelum menarik kesimpulan.'
    END                                            AS kesimpulan
FROM robust_verdict;

SELECT 'R4b. Kesimpulan robustness' AS section;

SELECT n_checks_total, n_arah_ok, n_sig_ok, n_d8_ok, kesimpulan FROM robust_conclusion;

-- ----------------------------------------------------------------------------
-- 6. Register analisis: konfirmatori vs eksploratif
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE analysis_register AS
SELECT * FROM (VALUES
    (1, 'Tahap 6',  'KPI Lock, validasi populasi dan struktur',                        'Konfirmatori (definisi terkunci)', 'D1-D9',            'sql/05_data_validation.sql'),
    (2, 'Tahap 8',  'Uji primer: z-test dua arah, CI 95% selisih, relative lift',      'Konfirmatori (primary)',           'D1, D2',           'sql/07_ab_testing.sql'),
    (3, 'Tahap 8',  'Sensitivitas: chi-square, Fisher exact, eksklusi duplikat',       'Konfirmatori (sensitivitas)',      'D2, D3',           'sql/07_ab_testing.sql'),
    (4, 'Tahap 8',  'MDE retrospektif dan practical significance',                      'Konfirmatori (kecukupan desain)',  'K4, D8, D9',       'sql/07_ab_testing.sql'),
    (5, 'Tahap 9',  'Ringkasan performa keseluruhan dan scorecard bukti',               'Ringkasan atas hasil konfirmatori', 'D8, D9',          'sql/08_overall_campaign_performance.sql'),
    (6, 'Tahap 7',  'EDA: distribusi, keseimbangan antar grup',                         'Eksploratif',                      'D7',               'sql/06_eda.sql'),
    (7, 'Tahap 10', 'CR per bucket paparan, tren, dekomposisi',                         'Eksploratif (post-treatment)',     'D4, D5, D6, D7',   'sql/09_exposure_frequency.sql'),
    (8, 'Tahap 11', 'Uji lift per hari (family 7) dan blok waktu (family 4), Holm',     'Eksploratif (dikoreksi Holm)',     'D5, D6, K2',       'sql/10_time_segments.sql'),
    (9, 'Tahap 11', 'CR per jam (24)',                                                  'Eksploratif (deskriptif, tanpa uji)', 'D5, D6, K3',     'sql/10_time_segments.sql'),
    (10, 'Tahap 12', 'Standardisasi, Mantel-Haenszel, konsistensi arah',                'Sensitivitas (pemeriksaan komposisi)', 'D5, D6, D7',   'sql/11_segment_robustness.sql'),
    (11, 'Tahap 12', 'Eksklusi outlier total_ads ekstrem',                              'Sensitivitas (tidak menggantikan primer)', 'D4, D9',    'sql/11_segment_robustness.sql')
) t(no, tahap, analisis, jenis, keputusan_terkait, file_sql);

SELECT 'R5. Register analisis: konfirmatori vs eksploratif' AS section;

SELECT no, tahap, analisis, jenis, keputusan_terkait, file_sql FROM analysis_register ORDER BY no;

-- ----------------------------------------------------------------------------
-- 7. Register keterbatasan (limitations register)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE limitations_register AS
SELECT * FROM (VALUES
    ('L01', 'Desain',       'Randomization tidak dapat diverifikasi dari dataset (tidak ada metadata randomization).',
                            'Interpretasi selisih CR sebagai efek penugasan grup bersyarat pada randomization yang valid.',
                            'Dinyatakan di setiap kesimpulan (Tahap 8, 9, 12).'),
    ('L02', 'Desain',       'Rasio ukuran grup ad : psa = ± 24 : 1 dan rasio desain tidak diketahui.',
                            'Sample Ratio Mismatch tidak dapat dinilai. Grup psa kecil (23.524) membuat MDE dan sel segmen psa terbatas.',
                            'Rasio dilaporkan deskriptif. MDE retrospektif (K4). Sel kecil (D5).'),
    ('L03', 'Data',         'Tidak ada data biaya atau nilai transaksi.',
                            'Tidak ada klaim ROI, ROAS, atau profit. Ambang practical significance tidak dapat diturunkan dari biaya.',
                            'Ambang D8 dinyatakan sebagai asumsi eksplisit.'),
    ('L04', 'Data',         'total_ads, most_ads_day, most_ads_hour adalah variabel post-treatment (satu nilai per user).',
                            'Hubungannya dengan konversi bersifat asosiasi, bukan sebab-akibat. Bukan jam atau hari konversi.',
                            'D7. Penstratifikasian hanya untuk memeriksa komposisi (Tahap 12).'),
    ('L05', 'Data',         'Tidak ada timestamp assignment atau konversi.',
                            'Tidak ada time-to-convert, novelty effect, tren kalender, atau urutan paparan dan konversi.',
                            'Dicatat sebagai limitation, tidak ada analisis temporal kalender.'),
    ('L06', 'Statistik',    'Banyak sel segmen psa kecil (mis. 17 dari 24 sel jam, blok 00-05, bucket b5).',
                            'Rate sel kecil tidak dapat diinterpretasikan dan tidak diuji.',
                            'D5, K1, K2. Cakupan "d5_ok_strata" pada Tahap 12.'),
    ('L07', 'Statistik',    'Pengujian berulang pada segmen (7 hari, 4 blok).',
                            'Risiko temuan positif palsu bila tidak dikoreksi. CI selisih per segmen tidak disesuaikan.',
                            'Holm per family (D6). Seluruhnya berlabel eksploratif. Tidak ada uji interaksi.'),
    ('L08', 'Statistik',    'Ambang practical significance D8 (0,25 / 0,5 / 1,0 pp) adalah asumsi.',
                            'Verdict practical significance bergantung pada ambang yang dipilih.',
                            'Tabel sensitivitas tiga ambang (Tahap 8, 9, 12).'),
    ('L09', 'Generalisasi', 'Satu eksperimen dalam satu periode pada populasi dataset.',
                            'Tidak menggeneralisasi ke populasi atau periode lain.',
                            'Dinyatakan di kesimpulan.'),
    ('L10', 'Data',         'Definisi operasional konversi dan sumber dataset tidak dapat diverifikasi di luar dokumentasi Kaggle.',
                            'Kebenaran substantif outcome tidak dapat diaudit.',
                            'Dicatat sebagai asumsi (docs/assumptions.md).'),
    ('L11', 'Publikasi',    'Lisensi dataset belum diverifikasi.',
                            'Risiko kepatuhan saat publikasi repositori.',
                            'Wajib dicek dan dicantumkan di README sebelum publish (Tahap 17-18).')
) t(id, kategori, keterbatasan, dampak, penanganan);

SELECT 'R6. Register keterbatasan (limitations register)' AS section;

SELECT id, kategori, keterbatasan, dampak, penanganan FROM limitations_register ORDER BY id;

-- ----------------------------------------------------------------------------
-- 8. Rekonsiliasi dan pemeriksaan (semua harus PASS)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE robust_checks AS
SELECT check_id, check_name, expected, actual,
       CASE WHEN abs(expected - actual) <= tolerance THEN 'PASS' ELSE 'FAIL' END AS status
FROM (
    SELECT 'R01' AS check_id, 'SUM(n_ad) setiap dimensi = n ad Tahap 8 (selisih terbesar)' AS check_name,
           0.0 AS expected,
           (SELECT MAX(abs(s - (SELECT n_ad FROM ab_primary))) FROM (SELECT dim, SUM(n_ad) AS s FROM robust_strata GROUP BY dim))::DOUBLE AS actual,
           0.0 AS tolerance
    UNION ALL
    SELECT 'R02', 'SUM(n_psa) setiap dimensi = n psa Tahap 8 (selisih terbesar)', 0.0,
           (SELECT MAX(abs(s - (SELECT n_psa FROM ab_primary))) FROM (SELECT dim, SUM(n_psa) AS s FROM robust_strata GROUP BY dim))::DOUBLE, 0.0
    UNION ALL
    SELECT 'R03', 'SUM(x_ad) setiap dimensi = konversi ad Tahap 8 (selisih terbesar)', 0.0,
           (SELECT MAX(abs(s - (SELECT conv_ad FROM ab_primary))) FROM (SELECT dim, SUM(x_ad) AS s FROM robust_strata GROUP BY dim))::DOUBLE, 0.0
    UNION ALL
    SELECT 'R04', 'SUM(x_psa) setiap dimensi = konversi psa Tahap 8 (selisih terbesar)', 0.0,
           (SELECT MAX(abs(s - (SELECT conv_psa FROM ab_primary))) FROM (SELECT dim, SUM(x_psa) AS s FROM robust_strata GROUP BY dim))::DOUBLE, 0.0
    UNION ALL
    SELECT 'R05', 'Dimensi satu strata: standardisasi = crude (selisih absolut)', 0.0,
           (SELECT abs(e.lift - c.lift) FROM robust_estimates e, v_crude c
             WHERE e.dim = 'none' AND e.scope = 'all_strata' AND e.method = 'standardized_pooled_weights')::DOUBLE, 1e-15
    UNION ALL
    SELECT 'R06', 'Dimensi satu strata: Mantel-Haenszel = crude (selisih absolut)', 0.0,
           (SELECT abs(e.lift - c.lift) FROM robust_estimates e, v_crude c
             WHERE e.dim = 'none' AND e.scope = 'all_strata' AND e.method = 'mantel_haenszel')::DOUBLE, 1e-15
    UNION ALL
    SELECT 'R07', 'Dimensi satu strata: SE Mantel-Haenszel = SE crude tak-pooled (selisih absolut)', 0.0,
           (SELECT abs(e.se - c.se) FROM robust_estimates e, v_crude c
             WHERE e.dim = 'none' AND e.scope = 'all_strata' AND e.method = 'mantel_haenszel')::DOUBLE, 1e-12
    UNION ALL
    SELECT 'R08', 'Dimensi satu strata: SE standardisasi = SE crude tak-pooled (selisih absolut)', 0.0,
           (SELECT abs(e.se - c.se) FROM robust_estimates e, v_crude c
             WHERE e.dim = 'none' AND e.scope = 'all_strata' AND e.method = 'standardized_pooled_weights')::DOUBLE, 1e-12
    UNION ALL
    SELECT 'R09', 'Skenario S0 = hasil primer Tahap 8 (selisih lift absolut)', 0.0,
           (SELECT abs(o.lift - p.abs_lift) FROM robust_outlier o, ab_primary p WHERE o.ord = 0)::DOUBLE, 1e-15
    UNION ALL
    SELECT 'R10', 'Skenario S0: p-value = p-value Tahap 8 (galat relatif)', 0.0,
           (SELECT abs(o.p_value - p.p_value) / p.p_value FROM robust_outlier o, ab_primary p WHERE o.ord = 0)::DOUBLE, 1e-12
    UNION ALL
    SELECT 'R11', 'Pengguna yang dieksklusi S1 = jumlah user bucket b5 di Tahap 10 (selisih)', 0.0,
           (SELECT abs(((p.n_ad + p.n_psa) - (o.n_ad + o.n_psa))
                       - (SELECT SUM(n_users) FROM exposure_bucket_cells WHERE exposure_bucket = 'b5_gt_p99' AND grp IN ('ad', 'psa')))
              FROM robust_outlier o, ab_primary p WHERE o.ord = 1)::DOUBLE, 0.0
    UNION ALL
    SELECT 'R12', 'n segmen per dimensi cocok dengan Tahap 10 dan 11 (selisih n terbesar, hari+blok+jam+bucket)', 0.0,
           COALESCE((SELECT MAX(abs(r.n_ad - c.n_users)) FROM robust_strata r
                       JOIN time_segment_cells c ON c.family = r.dim AND c.segment = r.segment AND c.grp = 'ad'
                      WHERE r.dim IN ('day', 'block', 'hour')), 0)::DOUBLE
         + COALESCE((SELECT MAX(abs(r.n_psa - c.n_users)) FROM robust_strata r
                       JOIN time_segment_cells c ON c.family = r.dim AND c.segment = r.segment AND c.grp = 'psa'
                      WHERE r.dim IN ('day', 'block', 'hour')), 0)::DOUBLE
         + COALESCE((SELECT MAX(abs(r.n_ad - c.n_users)) FROM robust_strata r
                       JOIN exposure_bucket_cells c ON c.exposure_bucket = r.segment AND c.grp = 'ad'
                      WHERE r.dim = 'exposure_bucket'), 0)::DOUBLE
         + COALESCE((SELECT MAX(abs(r.n_psa - c.n_users)) FROM robust_strata r
                       JOIN exposure_bucket_cells c ON c.exposure_bucket = r.segment AND c.grp = 'psa'
                      WHERE r.dim = 'exposure_bucket'), 0)::DOUBLE, 0.0
    UNION ALL
    SELECT 'R13', 'Identitas: SUM(n_ad_k / n_ad x CR_ad_k) = CR ad (selisih terbesar antar dimensi)', 0.0,
           (SELECT MAX(abs(s - (SELECT cr_ad FROM ab_primary))) FROM
               (SELECT dim, SUM(n_ad::DOUBLE / (SELECT n_ad FROM ab_primary) * cr_ad) AS s FROM robust_strata GROUP BY dim))::DOUBLE, 1e-12
    UNION ALL
    SELECT 'R14', 'Jumlah segmen: hari 7, blok 4, jam 24, bucket 5, none 1 (selisih total)', 0.0,
           (SELECT abs(SUM(CASE dim WHEN 'day' THEN 1 WHEN 'block' THEN 1 WHEN 'hour' THEN 1 WHEN 'exposure_bucket' THEN 1 WHEN 'none' THEN 1 ELSE 0 END) - (7 + 4 + 24 + 5 + 1))
              FROM robust_strata)::DOUBLE, 0.0
    UNION ALL
    SELECT 'R15', 'Batas CI: setiap estimator memuat estimasinya sendiri (pelanggaran)', 0.0,
           (SELECT COUNT(*) FROM robust_estimates WHERE lift < ci_low OR lift > ci_high)::DOUBLE, 0.0
);

SELECT 'R7. Rekonsiliasi dan pemeriksaan' AS section;

SELECT check_id, check_name, expected, actual, status FROM robust_checks ORDER BY check_id;

SELECT
    COUNT(*)                                     AS n_checks,
    COUNT(*) FILTER (WHERE status = 'PASS')      AS n_pass,
    COUNT(*) FILTER (WHERE status = 'FAIL')      AS n_fail,
    CASE WHEN COUNT(*) FILTER (WHERE status = 'FAIL') = 0 THEN 'ALL PASS' ELSE 'FAIL' END AS robust_gate
FROM robust_checks;
