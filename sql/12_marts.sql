-- ============================================================================
-- FILE:        sql/12_marts.sql
-- TAHAP:       Tahap 13 (Inti)
-- TUJUAN:      Data Mart: empat mart berorientasi subjek untuk dashboard (Tahap 15):
--                mart_experiment_summary   -> Halaman 1, 2, 4
--                mart_exposure_frequency   -> Halaman 3 (Jalur Lanjutan)
--                mart_time_segments        -> Halaman 3 (Jalur Lanjutan)
--                mart_data_quality_summary -> Halaman 5
-- ============================================================================
-- GRAIN:       lihat katalog mart (bagian 6). Setiap mart memiliki kunci unik yang diperiksa.
-- POPULATION:  Mart HANYA mengonsumsi hasil analisis Tahap 5-12. TIDAK ADA definisi populasi baru di sini.
-- DENOMINATOR: Mengikuti tabel sumber (Valid / Exposure / Time Population per grup).
-- ============================================================================
-- Jalankan (PowerShell, dari root folder proyek):
--   .\duckdb.exe ab_testing.duckdb -c ".read sql/12_marts.sql"
--
-- Prasyarat: Tahap 5-12 sudah dijalankan di ab_testing.duckdb. Tabel sumber yang dibaca:
--   marketing_ab_clean, raw_marketing_ab, validation_summary                (Tahap 2, 5, 6)
--   ab_primary, ab_chi, ab_fisher, ab_excl_test, ab_effect, ab_effect_excl_dup,
--   ab_mde, ab_d8, ab_checks                                                 (Tahap 8)
--   overall_group_performance, overall_scorecard, overall_conclusion,
--   overall_checks                                                           (Tahap 9)
--   exposure_bucket_cells, exposure_bucket_compare, exposure_checks          (Tahap 10)
--   time_segment_cells, time_segment_wide, time_checks                       (Tahap 11)
--   robust_conclusion, robust_checks                                         (Tahap 12)
--   macro ab_wilson_low dan ab_wilson_high                                   (Tahap 10-11)
--
-- DASHBOARD METHODOLOGY DECISIONS (terkunci di roadmap, diwujudkan di desain mart):
--   1. CR selalu tersedia bersama n, jumlah konversi, absolute lift, dan relative lift.
--   2. CI, p-value, dan MDE tersedia di mart utama. Ketidakpastian tidak disembunyikan.
--   3. Sel kecil (is_small_segment) memiliki penanda dan interpretation_flag. p-value segmen yang ditampilkan
--      memakai versi terkoreksi Holm (D6). Jam (24) tidak memiliki p-value.
--   4. Mart segmen berlabel eksploratif (asosiasi, bukan kausal).
--   5. Data Quality: metrik kuantitatif ada di mart. Assumptions dan limitations adalah text box statis di dashboard.
--
-- KONVENSI KOLOM: seluruh rate dan share adalah PROPORSI (0 sampai 1). Selisih dan lift memakai satuan poin
-- persentase (kolom berakhiran _pp) atau persen (kolom berakhiran _pct). Nama kolom snake_case.
-- ============================================================================

.mode markdown
.maxrows 1000

-- ============================================================================
-- MART 1: mart_experiment_summary
-- GRAIN: 1 baris = 1 metrik untuk (section, entity). Kunci unik: (section, entity, metric).
-- Halaman 1 (overview), Halaman 2 (performa kampanye), Halaman 4 (keputusan bisnis).
-- ============================================================================
CREATE OR REPLACE TABLE mart_experiment_summary (
    section        VARCHAR,
    entity         VARCHAR,
    metric         VARCHAR,
    metric_label   VARCHAR,
    value          DOUBLE,
    ci_low         DOUBLE,
    ci_high        DOUBLE,
    unit           VARCHAR,
    value_text     VARCHAR,
    detail         VARCHAR,
    sort_order     INTEGER,
    source_table   VARCHAR
);

-- 1a. Performa per grup (ad, psa, ALL)
CREATE OR REPLACE TEMP VIEW v_mes_group AS
WITH g AS (
    SELECT test_group AS entity,
           n_users::DOUBLE AS n_users, n_converted::DOUBLE AS n_converted, n_not_converted::DOUBLE AS n_not_converted,
           share_of_users, share_of_conversions
    FROM overall_group_performance
    UNION ALL
    SELECT 'ALL', SUM(n_users)::DOUBLE, SUM(n_converted)::DOUBLE, SUM(n_not_converted)::DOUBLE,
           SUM(share_of_users), SUM(share_of_conversions)
    FROM overall_group_performance
)
SELECT
    entity, n_users, n_converted, n_not_converted,
    n_converted / n_users                       AS conversion_rate,
    share_of_users, share_of_conversions,
    ab_wilson_low(n_converted, n_users)         AS cr_ci_low,
    ab_wilson_high(n_converted, n_users)        AS cr_ci_high
FROM g;

CREATE OR REPLACE TEMP VIEW v_mes_group_long AS
SELECT entity, metric, value, cr_ci_low, cr_ci_high
FROM v_mes_group
UNPIVOT (value FOR metric IN (n_users, n_converted, n_not_converted, conversion_rate, share_of_users, share_of_conversions));

INSERT INTO mart_experiment_summary
SELECT
    'group', entity, metric,
    CASE metric
        WHEN 'n_users'              THEN 'Jumlah user valid'
        WHEN 'n_converted'          THEN 'Jumlah user konversi'
        WHEN 'n_not_converted'      THEN 'Jumlah user tidak konversi'
        WHEN 'conversion_rate'      THEN 'Conversion rate (CR)'
        WHEN 'share_of_users'       THEN 'Porsi dari seluruh user valid'
        WHEN 'share_of_conversions' THEN 'Porsi dari seluruh konversi' END,
    value,
    CASE WHEN metric = 'conversion_rate' THEN cr_ci_low END,
    CASE WHEN metric = 'conversion_rate' THEN cr_ci_high END,
    CASE metric WHEN 'n_users' THEN 'users' WHEN 'n_converted' THEN 'users' WHEN 'n_not_converted' THEN 'users'
                ELSE 'proportion' END,
    NULL,
    CASE WHEN metric = 'conversion_rate' THEN 'CI = interval Wilson 95% (K3)' END,
    (CASE entity WHEN 'ad' THEN 1 WHEN 'psa' THEN 2 ELSE 3 END) * 100
      + (CASE metric WHEN 'n_users' THEN 1 WHEN 'n_converted' THEN 2 WHEN 'n_not_converted' THEN 3
                     WHEN 'conversion_rate' THEN 4 WHEN 'share_of_users' THEN 5 ELSE 6 END),
    'overall_group_performance'
FROM v_mes_group_long;

-- 1b. Efek: absolute lift dan relative lift
INSERT INTO mart_experiment_summary
SELECT 'effect', 'ad_minus_psa', 'absolute_lift_pp', 'Absolute lift (ad dikurangi psa)',
       100.0 * abs_lift, 100.0 * ci_diff_low, 100.0 * ci_diff_high, 'pp', NULL,
       'CI 95% Wald tak-pooled (D2)', 1, 'ab_primary'
FROM ab_primary
UNION ALL
SELECT 'effect', 'ad_minus_psa', 'relative_lift_pct', 'Relative lift',
       100.0 * rel_lift, 100.0 * ci_rel_low, 100.0 * ci_rel_high, 'percent', NULL,
       'CI 95% log risk ratio (Katz, K5), deskriptif', 2, 'ab_primary'
FROM ab_primary;

-- 1c. Uji primer
INSERT INTO mart_experiment_summary
SELECT 'primary_test', 'ad_vs_psa', 'z_pooled', 'Statistik z (two-proportion, pooled)', z, NULL, NULL, 'z', NULL,
       'Uji dua arah (D1, D2)', 1, 'ab_primary'
FROM ab_primary
UNION ALL
SELECT 'primary_test', 'ad_vs_psa', 'p_value_two_sided', 'p-value dua arah', p_value, NULL, NULL, 'p_value', NULL,
       'Dibandingkan dengan alpha 0,05', 2, 'ab_primary'
FROM ab_primary
UNION ALL
SELECT 'primary_test', 'ad_vs_psa', 'alpha', 'Taraf signifikansi (alpha)', alpha, NULL, NULL, 'proportion', NULL,
       'D1', 3, 'ab_primary'
FROM ab_primary;

-- 1d. Sensitivitas (D2, D3)
INSERT INTO mart_experiment_summary
SELECT 'sensitivity', 'chi_square', 'chi2', 'Statistik chi-square (tanpa koreksi kontinuitas)', chi2, NULL, NULL, 'chi2', NULL, 'df = 1', 1, 'ab_chi' FROM ab_chi
UNION ALL
SELECT 'sensitivity', 'chi_square', 'p_value_two_sided', 'p-value chi-square', p_value_chi2, NULL, NULL, 'p_value', NULL, NULL, 2, 'ab_chi' FROM ab_chi
UNION ALL
SELECT 'sensitivity', 'fisher_exact', 'odds_ratio', 'Odds ratio sampel', odds_ratio, NULL, NULL, 'ratio', NULL, NULL, 3, 'ab_fisher' FROM ab_fisher
UNION ALL
SELECT 'sensitivity', 'fisher_exact', 'p_value_two_sided', 'p-value Fisher exact (dua arah)', p_value_fisher, NULL, NULL, 'p_value', NULL, NULL, 4, 'ab_fisher' FROM ab_fisher
UNION ALL
SELECT 'sensitivity', 'excluding_duplicates', 'p_value_two_sided', 'p-value z-test tanpa duplikat (D3)', p_value_excl, NULL, NULL, 'p_value', NULL,
       'D3 tidak berlaku bila tidak ada duplikat', 5, 'ab_excl_test' FROM ab_excl_test
UNION ALL
SELECT 'sensitivity', 'excluding_duplicates', 'rows_excluded', 'Baris yang dikeluarkan karena duplikat',
       ((e.n_ad + e.n_psa) - (x.n_ad_excl_dup + x.n_psa_excl_dup))::DOUBLE, NULL, NULL, 'users', NULL, NULL, 6, 'ab_effect_excl_dup'
FROM ab_effect e, ab_effect_excl_dup x;

-- 1e. MDE retrospektif (K4)
INSERT INTO mart_experiment_summary
SELECT 'mde', 'retrospective', 'mde_abs_pp', 'MDE absolut (power 80%, alpha 0,05 dua arah)', 100.0 * mde, NULL, NULL, 'pp', NULL,
       'Baseline = CR psa. Observed power dilarang (D9)', 1, 'ab_mde' FROM ab_mde
UNION ALL
SELECT 'mde', 'retrospective', 'mde_rel_pct_of_cr_psa', 'MDE relatif terhadap CR psa', 100.0 * mde / p0, NULL, NULL, 'percent', NULL, NULL, 2, 'ab_mde' FROM ab_mde
UNION ALL
SELECT 'mde', 'retrospective', 'mde_approx_pp', 'Aproksimasi p1 ~ p0 (verifikasi silang)', 100.0 * mde_approx, NULL, NULL, 'pp', NULL, NULL, 3, 'ab_mde' FROM ab_mde
UNION ALL
SELECT 'mde', 'retrospective', 'power_target', 'Power target', power_target, NULL, NULL, 'proportion', NULL, 'K4', 4, 'ab_mde' FROM ab_mde;

-- 1f. Practical significance (D8): tiga ambang
INSERT INTO mart_experiment_summary
SELECT 'practical_significance', 'threshold_' || CAST(thr_pp AS VARCHAR) || '_pp', 'verdict',
       'Verdict pada ambang ' || CAST(thr_pp AS VARCHAR) || ' pp',
       thr_pp, ci_low_pp, ci_high_pp, 'pp', verdict,
       'Ambang D8 adalah asumsi eksplisit. value = ambang, CI = 95% CI selisih CR',
       CASE thr_pp WHEN 0.25 THEN 1 WHEN 0.5 THEN 2 ELSE 3 END, 'ab_d8'
FROM ab_d8;

-- 1g. Scorecard kekuatan bukti dan kesimpulan (Halaman 4)
INSERT INTO mart_experiment_summary
SELECT 'scorecard', 'overall', 'Q' || CAST(ord AS VARCHAR), pertanyaan, NULL, NULL, NULL, 'text', penilaian, bukti, ord, 'overall_scorecard'
FROM overall_scorecard;

INSERT INTO mart_experiment_summary
SELECT 'conclusion', 'overall', 'kesimpulan_utama', 'Kesimpulan utama (mengikuti D9)', NULL, NULL, NULL, 'text', kesimpulan, NULL, 1, 'overall_conclusion'
FROM overall_conclusion
UNION ALL
SELECT 'conclusion', 'robustness', 'kesimpulan_robustness', 'Kesimpulan robustness (Tahap 12)', NULL, NULL, NULL, 'text', kesimpulan, NULL, 2, 'robust_conclusion'
FROM robust_conclusion;

-- ============================================================================
-- MART 2: mart_exposure_frequency
-- GRAIN: 1 baris = 1 sel (exposure_bucket x test_group), test_group in (ad, psa, ALL). Kunci unik: (exposure_bucket, test_group).
-- Eksploratif. Kolom bucket_diff_* adalah atribut tingkat bucket yang diulang pada setiap baris bucket
-- (BUKAN ukuran aditif, jangan dijumlahkan).
-- ============================================================================
CREATE OR REPLACE TABLE mart_exposure_frequency AS
WITH rng AS (
    SELECT exposure_bucket, min_total_ads AS lo, max_total_ads AS hi
    FROM exposure_bucket_cells WHERE grp = 'ALL'
)
SELECT
    c.exposure_bucket,
    c.bucket_ord                                                  AS bucket_order,
    CAST(r.lo AS VARCHAR) || '-' || CAST(r.hi AS VARCHAR)         AS total_ads_range,
    c.grp                                                         AS test_group,
    c.n_users,
    c.n_converted,
    c.conversion_rate,
    c.wilson_low,
    c.wilson_high,
    c.pct_of_group_users / 100.0                                  AS share_of_group_users,
    c.pct_of_group_conversions / 100.0                            AS share_of_group_conversions,
    c.is_small_segment,
    CASE WHEN c.is_small_segment THEN 'kecil (D5): tidak diinterpretasikan' ELSE 'ok' END AS interpretation_flag,
    k.diff_pp                                                     AS bucket_diff_ad_minus_psa_pp,
    k.diff_interpretable                                          AS bucket_diff_interpretable,
    'EXPLORATORY: asosiasi, bukan kausal (D7)'                    AS analysis_label,
    'exposure_bucket_cells'                                       AS source_table
FROM exposure_bucket_cells c
JOIN rng r ON c.exposure_bucket = r.exposure_bucket
JOIN exposure_bucket_compare k ON c.exposure_bucket = k.exposure_bucket;

-- ============================================================================
-- MART 3: mart_time_segments
-- GRAIN: 1 baris = 1 sel (segment_type x segment x test_group), segment_type in (day, time_block, hour),
--        test_group in (ad, psa, ALL). Kunci unik: (segment_type, segment, test_group).
-- Eksploratif. Kolom diff_*, p_value_*, significant_holm, segment_tested adalah atribut tingkat segmen yang
-- diulang pada setiap baris segmen. Jam (24) tidak memiliki p-value. Halaman menampilkan p_value_holm (D6).
-- ============================================================================
CREATE OR REPLACE TABLE mart_time_segments AS
SELECT
    CASE c.family WHEN 'block' THEN 'time_block' ELSE c.family END       AS segment_type,
    c.segment,
    c.seg_order                                                          AS segment_order,
    c.grp                                                                AS test_group,
    c.n_users,
    c.n_converted,
    c.conversion_rate,
    c.wilson_low,
    c.wilson_high,
    c.pct_of_group_users / 100.0                                         AS share_of_group_users,
    c.is_small_segment,
    CASE WHEN c.is_small_segment THEN 'kecil (D5): tidak diinterpretasikan' ELSE 'ok' END AS interpretation_flag,
    w.diff_pp                                                            AS segment_diff_ad_minus_psa_pp,
    CASE WHEN w.testable THEN 100.0 * w.ci_low END                       AS segment_diff_ci_low_pp,
    CASE WHEN w.testable THEN 100.0 * w.ci_high END                      AS segment_diff_ci_high_pp,
    CASE WHEN c.family IN ('day', 'block') THEN w.p_raw END              AS p_value_raw,
    CASE WHEN c.family IN ('day', 'block') THEN w.p_holm END             AS p_value_holm,
    CASE WHEN c.family IN ('day', 'block') THEN w.significant_holm END   AS significant_holm,
    CASE WHEN c.family IN ('day', 'block') THEN w.holm_m END             AS holm_family_size,
    CASE WHEN c.family = 'hour' THEN 'deskriptif saja (D6), tanpa uji'
         WHEN w.testable THEN 'diuji, koreksi Holm (D6)'
         ELSE 'tidak diuji (sel kecil, D5), p = 1 dalam Holm' END        AS test_status,
    'EXPLORATORY: asosiasi, bukan kausal (D7)'                           AS analysis_label,
    'time_segment_cells, time_segment_wide'                              AS source_table
FROM time_segment_cells c
JOIN time_segment_wide w ON c.family = w.family AND c.segment = w.segment;

-- ============================================================================
-- MART 4: mart_data_quality_summary
-- GRAIN: 1 baris = 1 metrik kualitas data. Kunci unik: (section, metric).
-- Halaman 5. Assumptions dan limitations adalah text box statis di dashboard (docs/assumptions.md, register keterbatasan).
-- ============================================================================
CREATE OR REPLACE TABLE mart_data_quality_summary (
    section        VARCHAR,
    metric         VARCHAR,
    metric_label   VARCHAR,
    value          DOUBLE,
    unit           VARCHAR,
    proportion     DOUBLE,
    status         VARCHAR,
    detail         VARCHAR,
    sort_order     INTEGER,
    source_table   VARCHAR
);

-- 4a. Jumlah baris dan populasi
INSERT INTO mart_data_quality_summary
SELECT 'row_counts', 'raw_rows', 'Baris pada data mentah', COUNT(*)::DOUBLE, 'rows', 1.0, 'INFO', NULL, 1, 'raw_marketing_ab' FROM raw_marketing_ab
UNION ALL
SELECT 'row_counts', 'raw_columns', 'Kolom pada data mentah',
       (SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'raw_marketing_ab')::DOUBLE, 'columns', NULL, 'INFO', NULL, 2, 'raw_marketing_ab'
UNION ALL
SELECT 'row_counts', 'valid_users', 'Valid Analysis Population (is_valid_user)',
       COUNT(*) FILTER (WHERE is_valid_user)::DOUBLE, 'users',
       (COUNT(*) FILTER (WHERE is_valid_user))::DOUBLE / COUNT(*), 'INFO', NULL, 3, 'marketing_ab_clean' FROM marketing_ab_clean
UNION ALL
SELECT 'row_counts', 'excluded_rows', 'Baris yang dikeluarkan dari populasi analisis',
       COUNT(*) FILTER (WHERE NOT is_valid_user)::DOUBLE, 'rows',
       (COUNT(*) FILTER (WHERE NOT is_valid_user))::DOUBLE / COUNT(*), 'INFO', NULL, 4, 'marketing_ab_clean' FROM marketing_ab_clean
UNION ALL
SELECT 'row_counts', 'exposure_population', 'Exposure Population (valid dan paparan valid)',
       COUNT(*) FILTER (WHERE is_valid_user AND has_valid_exposure)::DOUBLE, 'users',
       (COUNT(*) FILTER (WHERE is_valid_user AND has_valid_exposure))::DOUBLE / COUNT(*), 'INFO', NULL, 5, 'marketing_ab_clean' FROM marketing_ab_clean
UNION ALL
SELECT 'row_counts', 'time_population', 'Time Population (valid dan hari/jam valid)',
       COUNT(*) FILTER (WHERE is_valid_user AND has_valid_time)::DOUBLE, 'users',
       (COUNT(*) FILTER (WHERE is_valid_user AND has_valid_time))::DOUBLE / COUNT(*), 'INFO', NULL, 6, 'marketing_ab_clean' FROM marketing_ab_clean;

-- 4b. Missing values per kolom (NULL atau string kosong) pada data mentah
INSERT INTO mart_data_quality_summary
WITH r AS (SELECT COUNT(*)::DOUBLE AS n FROM raw_marketing_ab)
SELECT 'missing_values', 'column0', 'Missing: column0 (row index)',
       (SELECT COUNT(*) FROM raw_marketing_ab WHERE column0 IS NULL OR trim(column0) = '')::DOUBLE, 'rows',
       (SELECT COUNT(*) FROM raw_marketing_ab WHERE column0 IS NULL OR trim(column0) = '') / r.n,
       CASE WHEN (SELECT COUNT(*) FROM raw_marketing_ab WHERE column0 IS NULL OR trim(column0) = '') = 0 THEN 'OK' ELSE 'PERHATIAN' END,
       NULL, 1, 'raw_marketing_ab' FROM r
UNION ALL
SELECT 'missing_values', 'user_id', 'Missing: user id',
       (SELECT COUNT(*) FROM raw_marketing_ab WHERE "user id" IS NULL OR trim("user id") = '')::DOUBLE, 'rows',
       (SELECT COUNT(*) FROM raw_marketing_ab WHERE "user id" IS NULL OR trim("user id") = '') / r.n,
       CASE WHEN (SELECT COUNT(*) FROM raw_marketing_ab WHERE "user id" IS NULL OR trim("user id") = '') = 0 THEN 'OK' ELSE 'PERHATIAN' END,
       NULL, 2, 'raw_marketing_ab' FROM r
UNION ALL
SELECT 'missing_values', 'test_group', 'Missing: test group',
       (SELECT COUNT(*) FROM raw_marketing_ab WHERE "test group" IS NULL OR trim("test group") = '')::DOUBLE, 'rows',
       (SELECT COUNT(*) FROM raw_marketing_ab WHERE "test group" IS NULL OR trim("test group") = '') / r.n,
       CASE WHEN (SELECT COUNT(*) FROM raw_marketing_ab WHERE "test group" IS NULL OR trim("test group") = '') = 0 THEN 'OK' ELSE 'PERHATIAN' END,
       NULL, 3, 'raw_marketing_ab' FROM r
UNION ALL
SELECT 'missing_values', 'converted', 'Missing: converted',
       (SELECT COUNT(*) FROM raw_marketing_ab WHERE converted IS NULL OR trim(converted) = '')::DOUBLE, 'rows',
       (SELECT COUNT(*) FROM raw_marketing_ab WHERE converted IS NULL OR trim(converted) = '') / r.n,
       CASE WHEN (SELECT COUNT(*) FROM raw_marketing_ab WHERE converted IS NULL OR trim(converted) = '') = 0 THEN 'OK' ELSE 'PERHATIAN' END,
       NULL, 4, 'raw_marketing_ab' FROM r
UNION ALL
SELECT 'missing_values', 'total_ads', 'Missing: total ads',
       (SELECT COUNT(*) FROM raw_marketing_ab WHERE "total ads" IS NULL OR trim("total ads") = '')::DOUBLE, 'rows',
       (SELECT COUNT(*) FROM raw_marketing_ab WHERE "total ads" IS NULL OR trim("total ads") = '') / r.n,
       CASE WHEN (SELECT COUNT(*) FROM raw_marketing_ab WHERE "total ads" IS NULL OR trim("total ads") = '') = 0 THEN 'OK' ELSE 'PERHATIAN' END,
       NULL, 5, 'raw_marketing_ab' FROM r
UNION ALL
SELECT 'missing_values', 'most_ads_day', 'Missing: most ads day',
       (SELECT COUNT(*) FROM raw_marketing_ab WHERE "most ads day" IS NULL OR trim("most ads day") = '')::DOUBLE, 'rows',
       (SELECT COUNT(*) FROM raw_marketing_ab WHERE "most ads day" IS NULL OR trim("most ads day") = '') / r.n,
       CASE WHEN (SELECT COUNT(*) FROM raw_marketing_ab WHERE "most ads day" IS NULL OR trim("most ads day") = '') = 0 THEN 'OK' ELSE 'PERHATIAN' END,
       NULL, 6, 'raw_marketing_ab' FROM r
UNION ALL
SELECT 'missing_values', 'most_ads_hour', 'Missing: most ads hour',
       (SELECT COUNT(*) FROM raw_marketing_ab WHERE "most ads hour" IS NULL OR trim("most ads hour") = '')::DOUBLE, 'rows',
       (SELECT COUNT(*) FROM raw_marketing_ab WHERE "most ads hour" IS NULL OR trim("most ads hour") = '') / r.n,
       CASE WHEN (SELECT COUNT(*) FROM raw_marketing_ab WHERE "most ads hour" IS NULL OR trim("most ads hour") = '') = 0 THEN 'OK' ELSE 'PERHATIAN' END,
       NULL, 7, 'raw_marketing_ab' FROM r;

-- 4c. Baris yang ditandai (flag) dan alasan eksklusi
INSERT INTO mart_data_quality_summary
WITH n AS (SELECT COUNT(*)::DOUBLE AS total FROM marketing_ab_clean),
reasons(reason, ord) AS (
    VALUES ('missing_user_id', 1), ('invalid_test_group', 2), ('invalid_converted', 3),
           ('d3b_group_conflict', 4), ('d3ac_duplicate_row_not_selected', 5)
)
SELECT 'flags', 'exclusion_' || r.reason, 'Dikeluarkan: ' || r.reason,
       (SELECT COUNT(*) FROM marketing_ab_clean WHERE exclusion_reason = r.reason)::DOUBLE, 'rows',
       (SELECT COUNT(*) FROM marketing_ab_clean WHERE exclusion_reason = r.reason) / n.total,
       CASE WHEN (SELECT COUNT(*) FROM marketing_ab_clean WHERE exclusion_reason = r.reason) = 0 THEN 'OK' ELSE 'PERHATIAN' END,
       NULL, r.ord, 'marketing_ab_clean'
FROM reasons r CROSS JOIN n
UNION ALL
SELECT 'flags', 'flag_duplicate_user_id', 'user_id berulang (flag_duplicate_user_id)',
       COUNT(*) FILTER (WHERE flag_duplicate_user_id)::DOUBLE, 'rows',
       (COUNT(*) FILTER (WHERE flag_duplicate_user_id))::DOUBLE / COUNT(*),
       CASE WHEN COUNT(*) FILTER (WHERE flag_duplicate_user_id) = 0 THEN 'OK' ELSE 'PERHATIAN' END,
       'D3 tidak berlaku bila 0', 6, 'marketing_ab_clean' FROM marketing_ab_clean
UNION ALL
SELECT 'flags', 'no_valid_exposure', 'Tanpa paparan valid (has_valid_exposure = FALSE)',
       COUNT(*) FILTER (WHERE NOT has_valid_exposure)::DOUBLE, 'rows',
       (COUNT(*) FILTER (WHERE NOT has_valid_exposure))::DOUBLE / COUNT(*),
       CASE WHEN COUNT(*) FILTER (WHERE NOT has_valid_exposure) = 0 THEN 'OK' ELSE 'PERHATIAN' END,
       NULL, 7, 'marketing_ab_clean' FROM marketing_ab_clean
UNION ALL
SELECT 'flags', 'no_valid_time', 'Tanpa hari/jam valid (has_valid_time = FALSE)',
       COUNT(*) FILTER (WHERE NOT has_valid_time)::DOUBLE, 'rows',
       (COUNT(*) FILTER (WHERE NOT has_valid_time))::DOUBLE / COUNT(*),
       CASE WHEN COUNT(*) FILTER (WHERE NOT has_valid_time) = 0 THEN 'OK' ELSE 'PERHATIAN' END,
       NULL, 8, 'marketing_ab_clean' FROM marketing_ab_clean;

-- 4d. Rekonsiliasi (selisih harus 0)
INSERT INTO mart_data_quality_summary
SELECT 'reconciliation', 'raw_equals_valid_plus_excluded', 'Baris mentah = valid + dikeluarkan (selisih)',
       ((SELECT COUNT(*) FROM raw_marketing_ab)
        - (SELECT COUNT(*) FILTER (WHERE is_valid_user) FROM marketing_ab_clean)
        - (SELECT COUNT(*) FILTER (WHERE NOT is_valid_user) FROM marketing_ab_clean))::DOUBLE, 'rows', NULL,
       CASE WHEN (SELECT COUNT(*) FROM raw_marketing_ab)
                 = (SELECT COUNT(*) FROM marketing_ab_clean) THEN 'PASS' ELSE 'FAIL' END,
       NULL, 1, 'raw_marketing_ab, marketing_ab_clean'
UNION ALL
SELECT 'reconciliation', 'groups_equal_valid_users', 'User ad + user psa = user valid (selisih)',
       ((SELECT COUNT(*) FILTER (WHERE is_valid_user) FROM marketing_ab_clean)
        - (SELECT n_ad + n_psa FROM ab_primary))::DOUBLE, 'users', NULL,
       CASE WHEN (SELECT COUNT(*) FILTER (WHERE is_valid_user) FROM marketing_ab_clean)
                 = (SELECT n_ad + n_psa FROM ab_primary) THEN 'PASS' ELSE 'FAIL' END,
       NULL, 2, 'marketing_ab_clean, ab_primary'
UNION ALL
SELECT 'reconciliation', 'conversions_ad_clean_vs_raw', 'Konversi ad: clean vs hitungan langsung raw (selisih)',
       ((SELECT conv_ad FROM ab_primary)
        - (SELECT COUNT(*) FROM raw_marketing_ab WHERE "test group" = 'ad' AND converted = 'True'))::DOUBLE, 'users', NULL,
       CASE WHEN (SELECT conv_ad FROM ab_primary)
                 = (SELECT COUNT(*) FROM raw_marketing_ab WHERE "test group" = 'ad' AND converted = 'True') THEN 'PASS' ELSE 'FAIL' END,
       NULL, 3, 'ab_primary, raw_marketing_ab'
UNION ALL
SELECT 'reconciliation', 'conversions_psa_clean_vs_raw', 'Konversi psa: clean vs hitungan langsung raw (selisih)',
       ((SELECT conv_psa FROM ab_primary)
        - (SELECT COUNT(*) FROM raw_marketing_ab WHERE "test group" = 'psa' AND converted = 'True'))::DOUBLE, 'users', NULL,
       CASE WHEN (SELECT conv_psa FROM ab_primary)
                 = (SELECT COUNT(*) FROM raw_marketing_ab WHERE "test group" = 'psa' AND converted = 'True') THEN 'PASS' ELSE 'FAIL' END,
       NULL, 4, 'ab_primary, raw_marketing_ab'
UNION ALL
SELECT 'reconciliation', 'grain_user_id_unique', 'user_id unik di populasi valid (selisih baris vs distinct)',
       ((SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user)
        - (SELECT COUNT(DISTINCT user_id) FROM marketing_ab_clean WHERE is_valid_user))::DOUBLE, 'users', NULL,
       CASE WHEN (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user)
                 = (SELECT COUNT(DISTINCT user_id) FROM marketing_ab_clean WHERE is_valid_user) THEN 'PASS' ELSE 'FAIL' END,
       NULL, 5, 'marketing_ab_clean';

-- 4e. Ukuran dan rasio grup
INSERT INTO mart_data_quality_summary
SELECT 'group_ratio', 'n_ad', 'User valid grup ad', n_ad::DOUBLE, 'users', n_ad::DOUBLE / (n_ad + n_psa), 'INFO', NULL, 1, 'ab_primary' FROM ab_primary
UNION ALL
SELECT 'group_ratio', 'n_psa', 'User valid grup psa', n_psa::DOUBLE, 'users', n_psa::DOUBLE / (n_ad + n_psa), 'INFO', NULL, 2, 'ab_primary' FROM ab_primary
UNION ALL
SELECT 'group_ratio', 'ratio_ad_to_psa', 'Rasio ukuran grup ad : psa', n_ad::DOUBLE / n_psa, 'ratio', NULL, 'INFO',
       'Rasio desain tidak tersedia, SRM tidak dapat dinilai. Dicatat sebagai limitation', 3, 'ab_primary' FROM ab_primary;

-- 4f. Hasil gate validasi dan pemeriksaan otomatis dari tahap sebelumnya
INSERT INTO mart_data_quality_summary
SELECT 'validation_gates', 'validation_summary', 'Validasi Tahap 6 (validation_summary)',
       COUNT(*)::DOUBLE, 'checks', (COUNT(*) FILTER (WHERE status = 'PASS'))::DOUBLE / COUNT(*),
       CASE WHEN COUNT(*) FILTER (WHERE status = 'FAIL') = 0 THEN 'ALL PASS' ELSE 'FAIL' END, NULL, 1, 'validation_summary'
FROM validation_summary
UNION ALL
SELECT 'validation_gates', 'ab_checks', 'Pemeriksaan A/B test Tahap 8 (ab_checks)',
       COUNT(*)::DOUBLE, 'checks', (COUNT(*) FILTER (WHERE status = 'PASS'))::DOUBLE / COUNT(*),
       CASE WHEN COUNT(*) FILTER (WHERE status = 'FAIL') = 0 THEN 'ALL PASS' ELSE 'FAIL' END, NULL, 2, 'ab_checks'
FROM ab_checks
UNION ALL
SELECT 'validation_gates', 'overall_checks', 'Pemeriksaan performa keseluruhan Tahap 9 (overall_checks)',
       COUNT(*)::DOUBLE, 'checks', (COUNT(*) FILTER (WHERE status = 'PASS'))::DOUBLE / COUNT(*),
       CASE WHEN COUNT(*) FILTER (WHERE status = 'FAIL') = 0 THEN 'ALL PASS' ELSE 'FAIL' END, NULL, 3, 'overall_checks'
FROM overall_checks
UNION ALL
SELECT 'validation_gates', 'exposure_checks', 'Pemeriksaan paparan Tahap 10 (exposure_checks)',
       COUNT(*)::DOUBLE, 'checks', (COUNT(*) FILTER (WHERE status = 'PASS'))::DOUBLE / COUNT(*),
       CASE WHEN COUNT(*) FILTER (WHERE status = 'FAIL') = 0 THEN 'ALL PASS' ELSE 'FAIL' END, NULL, 4, 'exposure_checks'
FROM exposure_checks
UNION ALL
SELECT 'validation_gates', 'time_checks', 'Pemeriksaan segmen waktu Tahap 11 (time_checks)',
       COUNT(*)::DOUBLE, 'checks', (COUNT(*) FILTER (WHERE status = 'PASS'))::DOUBLE / COUNT(*),
       CASE WHEN COUNT(*) FILTER (WHERE status = 'FAIL') = 0 THEN 'ALL PASS' ELSE 'FAIL' END, NULL, 5, 'time_checks'
FROM time_checks
UNION ALL
SELECT 'validation_gates', 'robust_checks', 'Pemeriksaan robustness Tahap 12 (robust_checks)',
       COUNT(*)::DOUBLE, 'checks', (COUNT(*) FILTER (WHERE status = 'PASS'))::DOUBLE / COUNT(*),
       CASE WHEN COUNT(*) FILTER (WHERE status = 'FAIL') = 0 THEN 'ALL PASS' ELSE 'FAIL' END, NULL, 6, 'robust_checks'
FROM robust_checks;

-- 4g. Sel kecil (D5) per family dan grup
INSERT INTO mart_data_quality_summary
SELECT 'small_cells', 'small_' || family || '_' || grp, 'Sel kecil D5: ' || family || ' / ' || grp,
       COUNT(*) FILTER (WHERE is_small_segment)::DOUBLE, 'cells',
       (COUNT(*) FILTER (WHERE is_small_segment))::DOUBLE / COUNT(*), 'INFO',
       'dari ' || CAST(COUNT(*) AS VARCHAR) || ' sel',
       (CASE family WHEN 'day' THEN 1 WHEN 'block' THEN 2 ELSE 3 END) * 10 + (CASE grp WHEN 'ad' THEN 1 ELSE 2 END),
       'time_segment_cells'
FROM time_segment_cells
WHERE grp IN ('ad', 'psa')
GROUP BY family, grp
UNION ALL
SELECT 'small_cells', 'small_exposure_bucket_' || grp, 'Sel kecil D5: exposure_bucket / ' || grp,
       COUNT(*) FILTER (WHERE is_small_segment)::DOUBLE, 'cells',
       (COUNT(*) FILTER (WHERE is_small_segment))::DOUBLE / COUNT(*), 'INFO',
       'dari ' || CAST(COUNT(*) AS VARCHAR) || ' sel',
       40 + (CASE grp WHEN 'ad' THEN 1 ELSE 2 END), 'exposure_bucket_cells'
FROM exposure_bucket_cells
WHERE grp IN ('ad', 'psa')
GROUP BY grp;

-- ============================================================================
-- 5. Acceptance Criteria: row-count dan sum-check setiap mart terhadap sumbernya (semua harus PASS)
-- ============================================================================
CREATE OR REPLACE TABLE mart_checks AS
SELECT check_id, mart, check_name, expected, actual,
       CASE WHEN abs(expected - actual) <= tolerance THEN 'PASS' ELSE 'FAIL' END AS status
FROM (
    -- ---------- mart_experiment_summary ----------
    SELECT 'M01' AS check_id, 'mart_experiment_summary' AS mart, 'Kunci unik (section, entity, metric): baris - distinct' AS check_name,
           0.0 AS expected,
           ((SELECT COUNT(*) FROM mart_experiment_summary)
            - (SELECT COUNT(*) FROM (SELECT DISTINCT section, entity, metric FROM mart_experiment_summary)))::DOUBLE AS actual,
           0.0 AS tolerance
    UNION ALL
    SELECT 'M02', 'mart_experiment_summary', 'Jumlah user ad + psa = Valid Analysis Population',
           (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user)::DOUBLE,
           (SELECT SUM(value) FROM mart_experiment_summary WHERE section = 'group' AND metric = 'n_users' AND entity IN ('ad', 'psa')), 0.0
    UNION ALL
    SELECT 'M03', 'mart_experiment_summary', 'Baris ALL: n user = Valid Analysis Population',
           (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user)::DOUBLE,
           (SELECT value FROM mart_experiment_summary WHERE section = 'group' AND metric = 'n_users' AND entity = 'ALL'), 0.0
    UNION ALL
    SELECT 'M04', 'mart_experiment_summary', 'Konversi ad + psa = konversi populasi valid',
           (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND is_converted)::DOUBLE,
           (SELECT SUM(value) FROM mart_experiment_summary WHERE section = 'group' AND metric = 'n_converted' AND entity IN ('ad', 'psa')), 0.0
    UNION ALL
    SELECT 'M05', 'mart_experiment_summary', 'CR di mart = konversi / n (galat absolut terbesar, semua entitas)',
           0.0,
           (SELECT MAX(abs(c.value - n.value_c / n.value_n)) FROM
               (SELECT entity, value FROM mart_experiment_summary WHERE section = 'group' AND metric = 'conversion_rate') c
               JOIN (SELECT a.entity, a.value AS value_n, b.value AS value_c
                       FROM mart_experiment_summary a JOIN mart_experiment_summary b
                         ON a.entity = b.entity AND a.section = 'group' AND b.section = 'group'
                        AND a.metric = 'n_users' AND b.metric = 'n_converted') n
                 ON c.entity = n.entity)::DOUBLE, 1e-15
    UNION ALL
    SELECT 'M06', 'mart_experiment_summary', 'Absolute lift (pp) = hasil Tahap 8',
           (SELECT 100.0 * abs_lift FROM ab_primary),
           (SELECT value FROM mart_experiment_summary WHERE section = 'effect' AND metric = 'absolute_lift_pp'), 1e-12
    UNION ALL
    SELECT 'M07', 'mart_experiment_summary', 'Relative lift (%) = hasil Tahap 8',
           (SELECT 100.0 * rel_lift FROM ab_primary),
           (SELECT value FROM mart_experiment_summary WHERE section = 'effect' AND metric = 'relative_lift_pct'), 1e-10
    UNION ALL
    SELECT 'M08', 'mart_experiment_summary', 'p-value primer = hasil Tahap 8',
           (SELECT p_value FROM ab_primary),
           (SELECT value FROM mart_experiment_summary WHERE section = 'primary_test' AND metric = 'p_value_two_sided'), 0.0
    UNION ALL
    SELECT 'M09', 'mart_experiment_summary', 'CI selisih (batas bawah dan atas, pp) = hasil Tahap 8 (selisih absolut)',
           0.0,
           (SELECT abs(ci_low - 100.0 * (SELECT ci_diff_low FROM ab_primary)) + abs(ci_high - 100.0 * (SELECT ci_diff_high FROM ab_primary))
              FROM mart_experiment_summary WHERE section = 'effect' AND metric = 'absolute_lift_pp'), 1e-12
    UNION ALL
    SELECT 'M10', 'mart_experiment_summary', 'MDE (pp) = hasil Tahap 8',
           (SELECT 100.0 * mde FROM ab_mde),
           (SELECT value FROM mart_experiment_summary WHERE section = 'mde' AND metric = 'mde_abs_pp'), 1e-12
    UNION ALL
    SELECT 'M11', 'mart_experiment_summary', 'Baris tabel D8 = 3 (tiga ambang)',
           3.0, (SELECT COUNT(*) FROM mart_experiment_summary WHERE section = 'practical_significance')::DOUBLE, 0.0
    UNION ALL
    SELECT 'M12', 'mart_experiment_summary', 'Verdict D8 di mart = verdict ab_d8 (jumlah verdict berbeda)',
           0.0,
           (SELECT COUNT(*) FROM mart_experiment_summary m JOIN ab_d8 d ON m.entity = 'threshold_' || CAST(d.thr_pp AS VARCHAR) || '_pp'
             WHERE m.section = 'practical_significance' AND m.value_text <> d.verdict)::DOUBLE, 0.0
    UNION ALL
    SELECT 'M13', 'mart_experiment_summary', 'Baris scorecard = baris overall_scorecard',
           (SELECT COUNT(*) FROM overall_scorecard)::DOUBLE,
           (SELECT COUNT(*) FROM mart_experiment_summary WHERE section = 'scorecard')::DOUBLE, 0.0
    UNION ALL
    SELECT 'M14', 'mart_experiment_summary', 'Baris kesimpulan = 2 (utama dan robustness)',
           2.0, (SELECT COUNT(*) FROM mart_experiment_summary WHERE section = 'conclusion')::DOUBLE, 0.0

    -- ---------- mart_exposure_frequency ----------
    UNION ALL
    SELECT 'M20', 'mart_exposure_frequency', 'Jumlah baris = 5 bucket x 3 grup',
           15.0, (SELECT COUNT(*) FROM mart_exposure_frequency)::DOUBLE, 0.0
    UNION ALL
    SELECT 'M21', 'mart_exposure_frequency', 'Kunci unik (exposure_bucket, test_group): baris - distinct',
           0.0,
           ((SELECT COUNT(*) FROM mart_exposure_frequency)
            - (SELECT COUNT(*) FROM (SELECT DISTINCT exposure_bucket, test_group FROM mart_exposure_frequency)))::DOUBLE, 0.0
    UNION ALL
    SELECT 'M22', 'mart_exposure_frequency', 'SUM(n) grup ad = Exposure Population ad',
           (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND has_valid_exposure AND is_treatment)::DOUBLE,
           (SELECT SUM(n_users) FROM mart_exposure_frequency WHERE test_group = 'ad')::DOUBLE, 0.0
    UNION ALL
    SELECT 'M23', 'mart_exposure_frequency', 'SUM(n) grup psa = Exposure Population psa',
           (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND has_valid_exposure AND is_control)::DOUBLE,
           (SELECT SUM(n_users) FROM mart_exposure_frequency WHERE test_group = 'psa')::DOUBLE, 0.0
    UNION ALL
    SELECT 'M24', 'mart_exposure_frequency', 'SUM(konversi) grup ad = konversi ad Tahap 8',
           (SELECT conv_ad FROM ab_primary)::DOUBLE,
           (SELECT SUM(n_converted) FROM mart_exposure_frequency WHERE test_group = 'ad')::DOUBLE, 0.0
    UNION ALL
    SELECT 'M25', 'mart_exposure_frequency', 'SUM(konversi) grup psa = konversi psa Tahap 8',
           (SELECT conv_psa FROM ab_primary)::DOUBLE,
           (SELECT SUM(n_converted) FROM mart_exposure_frequency WHERE test_group = 'psa')::DOUBLE, 0.0
    UNION ALL
    SELECT 'M26', 'mart_exposure_frequency', 'Jumlah sel kecil = sumber exposure_bucket_cells',
           (SELECT COUNT(*) FROM exposure_bucket_cells WHERE is_small_segment)::DOUBLE,
           (SELECT COUNT(*) FROM mart_exposure_frequency WHERE is_small_segment)::DOUBLE, 0.0
    UNION ALL
    SELECT 'M27', 'mart_exposure_frequency', 'Setiap baris sama dengan sumber (n, konversi, CR): baris yang berbeda',
           0.0,
           (SELECT COUNT(*) FROM mart_exposure_frequency m JOIN exposure_bucket_cells c
              ON m.exposure_bucket = c.exposure_bucket AND m.test_group = c.grp
             WHERE m.n_users <> c.n_users OR m.n_converted <> c.n_converted
                OR abs(m.conversion_rate - c.conversion_rate) > 1e-15)::DOUBLE, 0.0
    UNION ALL
    SELECT 'M28', 'mart_exposure_frequency', 'SUM(share_of_group_users) = 1 per grup (selisih terbesar)',
           0.0,
           (SELECT MAX(abs(s - 1.0)) FROM (SELECT test_group, SUM(share_of_group_users) AS s FROM mart_exposure_frequency GROUP BY test_group))::DOUBLE, 1e-12

    -- ---------- mart_time_segments ----------
    UNION ALL
    SELECT 'M30', 'mart_time_segments', 'Jumlah baris = (7 + 4 + 24) segmen x 3 grup',
           105.0, (SELECT COUNT(*) FROM mart_time_segments)::DOUBLE, 0.0
    UNION ALL
    SELECT 'M31', 'mart_time_segments', 'Kunci unik (segment_type, segment, test_group): baris - distinct',
           0.0,
           ((SELECT COUNT(*) FROM mart_time_segments)
            - (SELECT COUNT(*) FROM (SELECT DISTINCT segment_type, segment, test_group FROM mart_time_segments)))::DOUBLE, 0.0
    UNION ALL
    SELECT 'M32', 'mart_time_segments', 'SUM(n) per tipe segmen = Time Population (selisih terbesar, grup ad)',
           0.0,
           (SELECT MAX(abs(s - (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND has_valid_time AND is_treatment)))
              FROM (SELECT segment_type, SUM(n_users) AS s FROM mart_time_segments WHERE test_group = 'ad' GROUP BY segment_type))::DOUBLE, 0.0
    UNION ALL
    SELECT 'M33', 'mart_time_segments', 'SUM(n) per tipe segmen = Time Population (selisih terbesar, grup psa)',
           0.0,
           (SELECT MAX(abs(s - (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND has_valid_time AND is_control)))
              FROM (SELECT segment_type, SUM(n_users) AS s FROM mart_time_segments WHERE test_group = 'psa' GROUP BY segment_type))::DOUBLE, 0.0
    UNION ALL
    SELECT 'M34', 'mart_time_segments', 'SUM(konversi) per tipe segmen = konversi Tahap 8 (selisih terbesar, ad dan psa)',
           0.0,
           (SELECT MAX(abs(s - (SELECT CASE WHEN test_group = 'ad' THEN (SELECT conv_ad FROM ab_primary) ELSE (SELECT conv_psa FROM ab_primary) END)))
              FROM (SELECT segment_type, test_group, SUM(n_converted) AS s FROM mart_time_segments
                     WHERE test_group IN ('ad', 'psa') GROUP BY segment_type, test_group))::DOUBLE, 0.0
    UNION ALL
    SELECT 'M35', 'mart_time_segments', 'Jumlah sel kecil = sumber time_segment_cells',
           (SELECT COUNT(*) FROM time_segment_cells WHERE is_small_segment)::DOUBLE,
           (SELECT COUNT(*) FROM mart_time_segments WHERE is_small_segment)::DOUBLE, 0.0
    UNION ALL
    SELECT 'M36', 'mart_time_segments', 'Jam tidak memiliki p-value (baris jam dengan p-value)',
           0.0,
           (SELECT COUNT(*) FROM mart_time_segments WHERE segment_type = 'hour' AND (p_value_raw IS NOT NULL OR p_value_holm IS NOT NULL))::DOUBLE, 0.0
    UNION ALL
    SELECT 'M37', 'mart_time_segments', 'Hari dan blok: p_value_holm >= p_value_raw bila diuji (pelanggaran)',
           0.0,
           (SELECT COUNT(*) FROM mart_time_segments WHERE segment_type IN ('day', 'time_block') AND segment_tested
                      AND p_value_holm < p_value_raw - 1e-15)::DOUBLE, 0.0
    UNION ALL
    SELECT 'M38', 'mart_time_segments', 'Ukuran family Holm: hari 7 dan blok 4 (selisih)',
           0.0,
           (SELECT abs(MAX(holm_family_size) FILTER (WHERE segment_type = 'day') - 7)
                 + abs(MAX(holm_family_size) FILTER (WHERE segment_type = 'time_block') - 4) FROM mart_time_segments)::DOUBLE, 0.0
    UNION ALL
    SELECT 'M39', 'mart_time_segments', 'Setiap baris sama dengan sumber (n, konversi, CR): baris yang berbeda',
           0.0,
           (SELECT COUNT(*) FROM mart_time_segments m JOIN time_segment_cells c
              ON m.segment = c.segment AND m.test_group = c.grp
             AND m.segment_type = CASE c.family WHEN 'block' THEN 'time_block' ELSE c.family END
             WHERE m.n_users <> c.n_users OR m.n_converted <> c.n_converted
                OR abs(m.conversion_rate - c.conversion_rate) > 1e-15)::DOUBLE, 0.0

    -- ---------- mart_data_quality_summary ----------
    UNION ALL
    SELECT 'M40', 'mart_data_quality_summary', 'Kunci unik (section, metric): baris - distinct',
           0.0,
           ((SELECT COUNT(*) FROM mart_data_quality_summary)
            - (SELECT COUNT(*) FROM (SELECT DISTINCT section, metric FROM mart_data_quality_summary)))::DOUBLE, 0.0
    UNION ALL
    SELECT 'M41', 'mart_data_quality_summary', 'Baris mentah di mart = COUNT(raw_marketing_ab)',
           (SELECT COUNT(*) FROM raw_marketing_ab)::DOUBLE,
           (SELECT value FROM mart_data_quality_summary WHERE section = 'row_counts' AND metric = 'raw_rows'), 0.0
    UNION ALL
    SELECT 'M42', 'mart_data_quality_summary', 'Baris mentah = valid + dikeluarkan (dari mart)',
           (SELECT value FROM mart_data_quality_summary WHERE section = 'row_counts' AND metric = 'raw_rows'),
           (SELECT SUM(value) FROM mart_data_quality_summary WHERE section = 'row_counts' AND metric IN ('valid_users', 'excluded_rows')), 0.0
    UNION ALL
    SELECT 'M43', 'mart_data_quality_summary', 'Baris rekonsiliasi dengan status bukan PASS',
           0.0,
           (SELECT COUNT(*) FROM mart_data_quality_summary WHERE section = 'reconciliation' AND status <> 'PASS')::DOUBLE, 0.0
    UNION ALL
    SELECT 'M44', 'mart_data_quality_summary', 'Baris validation_gates dengan status bukan ALL PASS',
           0.0,
           (SELECT COUNT(*) FROM mart_data_quality_summary WHERE section = 'validation_gates' AND status <> 'ALL PASS')::DOUBLE, 0.0
    UNION ALL
    SELECT 'M45', 'mart_data_quality_summary', 'Jumlah baris missing_values = 7 kolom',
           7.0, (SELECT COUNT(*) FROM mart_data_quality_summary WHERE section = 'missing_values')::DOUBLE, 0.0
    UNION ALL
    SELECT 'M46', 'mart_data_quality_summary', 'n_ad dan n_psa di mart = ab_primary (selisih)',
           0.0,
           (SELECT abs(MAX(value) FILTER (WHERE metric = 'n_ad') - (SELECT n_ad FROM ab_primary))
                 + abs(MAX(value) FILTER (WHERE metric = 'n_psa') - (SELECT n_psa FROM ab_primary))
              FROM mart_data_quality_summary WHERE section = 'group_ratio')::DOUBLE, 0.0
);

-- ============================================================================
-- 6. Katalog mart
-- ============================================================================
CREATE OR REPLACE TABLE mart_catalog AS
SELECT
    t.mart, t.dashboard_page, t.grain, t.unique_key,
    c.n_rows, c.n_columns
FROM (VALUES
    ('mart_experiment_summary',   'Halaman 1, 2, 4', '1 baris = 1 metrik untuk (section, entity)',                       'section, entity, metric'),
    ('mart_exposure_frequency',   'Halaman 3',       '1 baris = 1 sel (exposure_bucket x test_group)',                   'exposure_bucket, test_group'),
    ('mart_time_segments',        'Halaman 3',       '1 baris = 1 sel (segment_type x segment x test_group)',            'segment_type, segment, test_group'),
    ('mart_data_quality_summary', 'Halaman 5',       '1 baris = 1 metrik kualitas data',                                 'section, metric')
) t(mart, dashboard_page, grain, unique_key)
JOIN (
    SELECT 'mart_experiment_summary' AS mart, (SELECT COUNT(*) FROM mart_experiment_summary) AS n_rows,
           (SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'mart_experiment_summary') AS n_columns
    UNION ALL
    SELECT 'mart_exposure_frequency', (SELECT COUNT(*) FROM mart_exposure_frequency),
           (SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'mart_exposure_frequency')
    UNION ALL
    SELECT 'mart_time_segments', (SELECT COUNT(*) FROM mart_time_segments),
           (SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'mart_time_segments')
    UNION ALL
    SELECT 'mart_data_quality_summary', (SELECT COUNT(*) FROM mart_data_quality_summary),
           (SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'mart_data_quality_summary')
) c ON t.mart = c.mart;

SELECT 'M1. Katalog mart' AS section;

SELECT mart, dashboard_page, grain, unique_key, n_rows, n_columns FROM mart_catalog ORDER BY mart;

SELECT 'M2. Acceptance Criteria: row-count dan sum-check tiap mart' AS section;

SELECT check_id, mart, check_name, expected, actual, status FROM mart_checks ORDER BY check_id;

SELECT
    COUNT(*)                                     AS n_checks,
    COUNT(*) FILTER (WHERE status = 'PASS')      AS n_pass,
    COUNT(*) FILTER (WHERE status = 'FAIL')      AS n_fail,
    CASE WHEN COUNT(*) FILTER (WHERE status = 'FAIL') = 0 THEN 'ALL PASS' ELSE 'FAIL' END AS mart_gate
FROM mart_checks;

-- ----------------------------------------------------------------------------
-- 7. Pratinjau isi mart (untuk verifikasi manual)
-- ----------------------------------------------------------------------------
SELECT 'M3. mart_experiment_summary (seluruh baris numerik)' AS section;

SELECT
    section, entity, metric,
    round(value, 6)    AS value,
    round(ci_low, 6)   AS ci_low,
    round(ci_high, 6)  AS ci_high,
    unit
FROM mart_experiment_summary
WHERE section NOT IN ('scorecard', 'conclusion')
ORDER BY CASE section WHEN 'group' THEN 1 WHEN 'effect' THEN 2 WHEN 'primary_test' THEN 3 WHEN 'sensitivity' THEN 4
                      WHEN 'mde' THEN 5 ELSE 6 END, sort_order;

SELECT 'M4. mart_experiment_summary: D8, scorecard, dan kesimpulan (teks)' AS section;

SELECT section, entity, metric, value_text
FROM mart_experiment_summary
WHERE section IN ('practical_significance', 'scorecard', 'conclusion')
ORDER BY CASE section WHEN 'practical_significance' THEN 1 WHEN 'scorecard' THEN 2 ELSE 3 END, sort_order;

SELECT 'M5. mart_exposure_frequency' AS section;

SELECT exposure_bucket, total_ads_range, test_group, n_users, n_converted,
       round(conversion_rate, 6) AS conversion_rate, round(share_of_group_users, 6) AS share_of_group_users,
       is_small_segment, round(bucket_diff_ad_minus_psa_pp, 4) AS bucket_diff_pp, bucket_diff_interpretable
FROM mart_exposure_frequency
ORDER BY bucket_order, CASE test_group WHEN 'ad' THEN 1 WHEN 'psa' THEN 2 ELSE 3 END;

SELECT 'M6. mart_time_segments: ringkasan per tipe segmen dan grup' AS section;

SELECT
    segment_type, test_group,
    COUNT(*)                                    AS n_segments,
    SUM(n_users)                                AS sum_n_users,
    SUM(n_converted)                            AS sum_n_converted,
    COUNT(*) FILTER (WHERE is_small_segment)    AS n_small_segments
FROM mart_time_segments
GROUP BY segment_type, test_group
ORDER BY CASE segment_type WHEN 'day' THEN 1 WHEN 'time_block' THEN 2 ELSE 3 END,
         CASE test_group WHEN 'ad' THEN 1 WHEN 'psa' THEN 2 ELSE 3 END;

SELECT 'M7. mart_time_segments: hasil uji per hari dan blok (grup ALL, 1 baris per segmen)' AS section;

SELECT segment_type, segment,
       round(segment_diff_ad_minus_psa_pp, 4) AS diff_pp,
       p_value_raw, p_value_holm, significant_holm, holm_family_size, test_status
FROM mart_time_segments
WHERE test_group = 'ALL' AND segment_type IN ('day', 'time_block')
ORDER BY CASE segment_type WHEN 'day' THEN 1 ELSE 2 END, segment_order;

SELECT 'M8. mart_data_quality_summary' AS section;

SELECT section, metric, value, unit, round(proportion, 6) AS proportion, status
FROM mart_data_quality_summary
ORDER BY CASE section WHEN 'row_counts' THEN 1 WHEN 'missing_values' THEN 2 WHEN 'flags' THEN 3
                      WHEN 'reconciliation' THEN 4 WHEN 'group_ratio' THEN 5 WHEN 'validation_gates' THEN 6 ELSE 7 END,
         sort_order;
