-- ============================================================================
-- FILE:        sql/08_overall_campaign_performance.sql
-- TAHAP:       Tahap 9 (Inti)
-- TUJUAN:      Overall Campaign Performance: membandingkan CR treatment vs control, absolute dan
--              relative lift, jumlah user dan konversi (denominator), efek vs CI dan MDE, serta menilai
--              kekuatan bukti untuk keputusan bisnis (D8, D9).
-- ============================================================================
-- GRAIN:       1 baris = 1 grup / 1 metrik / 1 pertanyaan bukti (lihat tiap bagian).
-- POPULATION:  Valid Analysis Population (is_valid_user = TRUE), per grup.
-- DENOMINATOR: n_ad = jumlah user valid is_treatment; n_psa = jumlah user valid is_control.
--              CR = jumlah user konversi / jumlah user valid dalam grup (KPI Lock, docs/methodology.md).
-- ============================================================================
-- Jalankan (PowerShell, dari root folder proyek):
--   .\duckdb.exe ab_testing.duckdb -c ".read sql/08_overall_campaign_performance.sql"
--
-- Prasyarat: sql/07_ab_testing.sql sudah dijalankan (tabel ab_primary, ab_mde, ab_d8, ab_checks, ab_chi, ab_fisher).
--
-- Skrip ini TIDAK menghitung ulang uji statistik: estimasi efek, CI, p-value, dan MDE dibaca dari hasil
-- Tahap 8 agar konsisten. Hitungan n, konversi, dan CR dihitung ulang dari marketing_ab_clean lalu
-- direkonsiliasi dengan Tahap 8 (bagian 5).
--
-- CATATAN INTERPRETASI: seluruh angka "konversi tambahan" (bagian 3) bersifat BERSYARAT. Angka itu hanya
-- bermakna sebagai efek iklan jika randomization valid, dan randomization tidak dapat diverifikasi dari
-- dataset ini. Tidak ada data biaya, sehingga tidak ada klaim ROI, ROAS, atau profit.
-- ============================================================================

.mode markdown
.maxrows 1000

-- ----------------------------------------------------------------------------
-- 1. Performa per grup: user, konversi, CR, dan kontribusi
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE overall_group_performance AS
WITH g AS (
    SELECT
        test_group,
        COUNT(*)                                     AS n_users,
        COUNT(*) FILTER (WHERE is_converted)         AS n_converted
    FROM marketing_ab_clean
    WHERE is_valid_user
    GROUP BY test_group
),
t AS (
    SELECT SUM(n_users) AS tot_users, SUM(n_converted) AS tot_conv FROM g
)
SELECT
    g.test_group,
    g.n_users,
    g.n_converted,
    g.n_users - g.n_converted                        AS n_not_converted,
    g.n_converted::DOUBLE / g.n_users                AS conversion_rate,
    g.n_users::DOUBLE / t.tot_users                  AS share_of_users,
    g.n_converted::DOUBLE / t.tot_conv               AS share_of_conversions
FROM g CROSS JOIN t;

SELECT 'P1. Performa per grup (Valid Analysis Population)' AS section;

SELECT test_group, n_users, n_converted, n_not_converted, conversion_rate_pct, pct_of_users, pct_of_conversions
FROM (
    SELECT 1 AS ord, test_group, n_users, n_converted, n_not_converted,
           round(100.0 * conversion_rate, 4)      AS conversion_rate_pct,
           round(100.0 * share_of_users, 2)       AS pct_of_users,
           round(100.0 * share_of_conversions, 2) AS pct_of_conversions
    FROM overall_group_performance WHERE test_group = 'ad'
    UNION ALL
    SELECT 2, test_group, n_users, n_converted, n_not_converted,
           round(100.0 * conversion_rate, 4), round(100.0 * share_of_users, 2), round(100.0 * share_of_conversions, 2)
    FROM overall_group_performance WHERE test_group = 'psa'
    UNION ALL
    SELECT 3, 'ALL', SUM(n_users)::BIGINT, SUM(n_converted)::BIGINT, SUM(n_not_converted)::BIGINT,
           round(100.0 * SUM(n_converted) / SUM(n_users), 4), 100.00, 100.00
    FROM overall_group_performance
)
ORDER BY ord;

-- ----------------------------------------------------------------------------
-- 2. Estimasi efek vs ketidakpastian (CI) dan kepekaan desain (MDE). Dibaca dari Tahap 8.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE overall_effect AS
SELECT
    p.cr_ad, p.cr_psa,
    p.abs_lift, p.ci_diff_low, p.ci_diff_high,
    p.rel_lift, p.ci_rel_low, p.ci_rel_high,
    p.z, p.p_value, p.alpha,
    m.mde, m.mde / m.p0 AS mde_rel
FROM ab_primary p CROSS JOIN ab_mde m;

SELECT 'P2. Efek: lift, CI 95%, p-value, dan MDE' AS section;

SELECT
    round(100.0 * cr_ad, 4)           AS cr_ad_pct,
    round(100.0 * cr_psa, 4)          AS cr_psa_pct,
    round(100.0 * abs_lift, 4)        AS abs_lift_pp,
    round(100.0 * ci_diff_low, 4)     AS ci95_low_pp,
    round(100.0 * ci_diff_high, 4)    AS ci95_high_pp,
    round(100.0 * rel_lift, 2)        AS rel_lift_pct,
    round(100.0 * ci_rel_low, 2)      AS rel_ci95_low_pct,
    round(100.0 * ci_rel_high, 2)     AS rel_ci95_high_pct,
    p_value                           AS p_value_two_sided,
    round(100.0 * mde, 4)             AS mde_pp,
    round(100.0 * mde_rel, 2)         AS mde_rel_pct
FROM overall_effect;

SELECT 'P2b. Posisi CI terhadap MDE dan ambang D8 (pp)' AS section;

SELECT
    round(100.0 * e.mde, 4)                                       AS mde_pp,
    round(100.0 * e.abs_lift, 4)                                  AS abs_lift_pp,
    round(e.abs_lift / e.mde, 2)                                  AS abs_lift_per_mde,
    (100.0 * e.ci_diff_low  > 100.0 * e.mde)                      AS ci_low_above_mde,
    MAX(d.verdict) FILTER (WHERE d.thr_pp = 0.25)                 AS vs_threshold_0_25,
    MAX(d.verdict) FILTER (WHERE d.thr_pp = 0.5)                  AS vs_threshold_0_5,
    MAX(d.verdict) FILTER (WHERE d.thr_pp = 1.0)                  AS vs_threshold_1_0
FROM overall_effect e, ab_d8 d
GROUP BY e.mde, e.abs_lift, e.ci_diff_low;

-- ----------------------------------------------------------------------------
-- 3. Terjemahan ke jumlah konversi (BERSYARAT pada validitas randomization)
--    konversi tambahan = absolute lift x n_ad
--    = konversi grup ad dikurangi konversi yang diharapkan jika grup ad berkonversi sebesar CR psa
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE overall_incremental AS
SELECT
    p.n_ad, p.conv_ad,
    p.cr_psa * p.n_ad                       AS expected_conv_at_psa_rate,
    p.abs_lift * p.n_ad                     AS incremental_conv,
    p.ci_diff_low * p.n_ad                  AS incremental_conv_low,
    p.ci_diff_high * p.n_ad                 AS incremental_conv_high,
    p.abs_lift / p.cr_ad                    AS share_of_ad_conv_above_psa_rate,
    1.0 / p.abs_lift                        AS users_per_incremental_conv,
    1.0 / p.ci_diff_high                    AS users_per_incremental_conv_low,
    1.0 / p.ci_diff_low                     AS users_per_incremental_conv_high
FROM ab_primary p;

SELECT 'P3. Konversi tambahan (BERSYARAT: hanya bermakna jika randomization valid)' AS section;

SELECT
    n_ad,
    conv_ad                                                  AS observed_conv_ad,
    round(expected_conv_at_psa_rate, 0)::BIGINT              AS expected_conv_if_psa_rate,
    round(incremental_conv, 0)::BIGINT                       AS incremental_conv,
    round(incremental_conv_low, 0)::BIGINT                   AS incremental_conv_ci_low,
    round(incremental_conv_high, 0)::BIGINT                  AS incremental_conv_ci_high,
    round(100.0 * share_of_ad_conv_above_psa_rate, 1)        AS pct_of_ad_conv_above_psa_rate,
    round(users_per_incremental_conv, 0)::BIGINT             AS users_per_incremental_conv,
    round(users_per_incremental_conv_low, 0)::BIGINT         AS users_per_inc_conv_low,
    round(users_per_incremental_conv_high, 0)::BIGINT        AS users_per_inc_conv_high
FROM overall_incremental;

-- ----------------------------------------------------------------------------
-- 4. Scorecard kekuatan bukti (D8, D9): setiap pertanyaan dijawab dengan angka dan penilaian
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE overall_scorecard AS
WITH k AS (
    SELECT
        p.p_value, p.alpha, p.abs_lift, p.ci_diff_low, p.ci_diff_high,
        m.mde,
        c.min_expected,
        (SELECT verdict FROM ab_d8 WHERE thr_pp = 0.5)                        AS d8_verdict,
        (SELECT COUNT(*) FILTER (WHERE status = 'PASS') FROM ab_checks)        AS checks_pass,
        (SELECT COUNT(*) FROM ab_checks)                                       AS checks_total,
        least(p.conv_ad, p.n_ad - p.conv_ad, p.conv_psa, p.n_psa - p.conv_psa) AS min_count,
        (f.p_value_fisher < p.alpha) AS sig_fisher,
        (c.p_value_chi2 < p.alpha)   AS sig_chi,
        (x.p_value_excl < p.alpha)   AS sig_excl
    FROM ab_primary p, ab_mde m, ab_chi c, ab_fisher f, ab_excl_test x
)
SELECT ord, pertanyaan, bukti, penilaian FROM (
    SELECT 1 AS ord, 'Apakah selisih CR signifikan secara statistik? (D1, D2)' AS pertanyaan,
           format('p = {:.3e} (alpha = {})', p_value, alpha) AS bukti,
           CASE WHEN p_value < alpha THEN 'Ya: ada bukti statistik untuk menolak H0'
                ELSE 'Tidak: bukti tidak cukup untuk menolak H0 (bukan bukti tidak ada efek, D9)' END AS penilaian
    FROM k
    UNION ALL
    SELECT 2, 'Apakah hasil konsisten antar metode? (D2, D3)',
           'chi-square, Fisher exact, dan eksklusi duplikat dibandingkan dengan z-test',
           CASE WHEN sig_chi = (p_value < alpha) AND sig_fisher = (p_value < alpha) AND sig_excl = (p_value < alpha)
                THEN 'Ya: seluruh metode memberi kesimpulan yang sama'
                ELSE 'Tidak seluruhnya: periksa sebelum menarik kesimpulan' END
    FROM k
    UNION ALL
    SELECT 3, 'Apakah efek melampaui ambang practical significance 0,5 pp? (D8)',
           format('selisih {:.3f} pp, 95% CI {:.3f} sampai {:.3f} pp', 100 * abs_lift, 100 * ci_diff_low, 100 * ci_diff_high),
           d8_verdict || ' (ambang adalah asumsi eksplisit, bukan fakta bisnis)'
    FROM k
    UNION ALL
    SELECT 4, 'Apakah desain cukup sensitif? (MDE vs D8)',
           format('MDE = {:.3f} pp vs ambang 0,5 pp', 100 * mde),
           CASE WHEN 100 * mde <= 0.5 THEN 'Ya: MDE <= ambang, desain cukup sensitif untuk efek seukuran ambang'
                ELSE 'Tidak: MDE > ambang, hasil non-signifikan akan inconclusive (D9)' END
    FROM k
    UNION ALL
    SELECT 5, 'Apakah asumsi statistik terpenuhi?',
           format('min(konversi, non-konversi) = {}, frekuensi harapan minimum = {:.1f}, user unik', min_count, min_expected),
           CASE WHEN min_count >= 10 AND min_expected >= 5 THEN 'Ya: aproksimasi normal dan chi-square valid'
                ELSE 'Tidak: periksa asumsi' END
    FROM k
    UNION ALL
    SELECT 6, 'Apakah implementasi uji lolos pemeriksaan otomatis?',
           format('{} dari {} pemeriksaan PASS', checks_pass, checks_total),
           CASE WHEN checks_pass = checks_total THEN 'Ya: ALL PASS' ELSE 'Tidak: ada pemeriksaan gagal' END
    FROM k
    UNION ALL
    SELECT 7, 'Apakah randomization dapat diverifikasi?',
           'tidak ada metadata randomization, rasio desain grup tidak tersedia (rasio teramati sekitar 24 : 1)',
           'Tidak: interpretasi efek penugasan grup bersyarat pada randomization yang valid'
    UNION ALL
    SELECT 8, 'Apakah ada data biaya untuk menilai ROI?',
           'tidak ada data biaya atau nilai transaksi',
           'Tidak: tidak ada klaim ROI, ROAS, atau profit'
)
ORDER BY ord;

SELECT 'P4. Scorecard kekuatan bukti (D8, D9)' AS section;

SELECT ord AS no, pertanyaan, bukti, penilaian FROM overall_scorecard ORDER BY ord;

-- Kesimpulan otomatis (mengikuti D9): tidak melampaui bukti
CREATE OR REPLACE TABLE overall_conclusion AS
SELECT
    CASE
        WHEN p.p_value < p.alpha
         AND 100 * p.ci_diff_low >= 0.5
         AND 100 * m.mde <= 0.5
        THEN 'Bukti statistik dan praktis (ambang 0,5 pp) mendukung bahwa CR kelompok ad lebih tinggi daripada psa, '
             || 'dan desain cukup sensitif. Keputusan bisnis tetap bergantung pada dua hal yang tidak dapat dinilai dari data ini: '
             || 'validitas randomization dan data biaya.'
        WHEN p.p_value < p.alpha
        THEN 'Ada bukti statistik perbedaan CR, tetapi tidak seluruh kriteria practical significance atau sensitivitas desain terpenuhi. '
             || 'Baca dengan hati-hati.'
        ELSE 'Bukti tidak cukup untuk menolak H0. Ini bukan bukti bahwa iklan tidak berpengaruh (D9).'
    END AS kesimpulan
FROM ab_primary p, ab_mde m;

SELECT 'P4b. Kesimpulan (mengikuti D9)' AS section;

SELECT kesimpulan FROM overall_conclusion;

-- ----------------------------------------------------------------------------
-- 5. Rekonsiliasi dan konsistensi metrik (harus PASS semua)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE overall_checks AS
SELECT check_id, check_name, expected, actual,
       CASE WHEN abs(expected - actual) <= tolerance THEN 'PASS' ELSE 'FAIL' END AS status
FROM (
    SELECT 'O01' AS check_id, 'n_ad: clean = Tahap 8' AS check_name,
           (SELECT n_users FROM overall_group_performance WHERE test_group = 'ad')::DOUBLE AS expected,
           (SELECT n_ad FROM ab_primary)::DOUBLE AS actual, 0.0 AS tolerance
    UNION ALL
    SELECT 'O02', 'n_psa: clean = Tahap 8',
           (SELECT n_users FROM overall_group_performance WHERE test_group = 'psa')::DOUBLE,
           (SELECT n_psa FROM ab_primary)::DOUBLE, 0.0
    UNION ALL
    SELECT 'O03', 'konversi ad: clean = Tahap 8',
           (SELECT n_converted FROM overall_group_performance WHERE test_group = 'ad')::DOUBLE,
           (SELECT conv_ad FROM ab_primary)::DOUBLE, 0.0
    UNION ALL
    SELECT 'O04', 'konversi psa: clean = Tahap 8',
           (SELECT n_converted FROM overall_group_performance WHERE test_group = 'psa')::DOUBLE,
           (SELECT conv_psa FROM ab_primary)::DOUBLE, 0.0
    UNION ALL
    SELECT 'O05', 'CR ad: konversi / n = CR Tahap 8',
           (SELECT conversion_rate FROM overall_group_performance WHERE test_group = 'ad'),
           (SELECT cr_ad FROM ab_primary), 1e-15
    UNION ALL
    SELECT 'O06', 'CR psa: konversi / n = CR Tahap 8',
           (SELECT conversion_rate FROM overall_group_performance WHERE test_group = 'psa'),
           (SELECT cr_psa FROM ab_primary), 1e-15
    UNION ALL
    SELECT 'O07', 'absolute lift = CR ad - CR psa (hitung ulang dari tabel grup)',
           (SELECT conversion_rate FROM overall_group_performance WHERE test_group = 'ad')
         - (SELECT conversion_rate FROM overall_group_performance WHERE test_group = 'psa'),
           (SELECT abs_lift FROM ab_primary), 1e-15
    UNION ALL
    SELECT 'O08', 'relative lift = absolute lift / CR psa (hitung ulang)',
           ((SELECT conversion_rate FROM overall_group_performance WHERE test_group = 'ad')
          - (SELECT conversion_rate FROM overall_group_performance WHERE test_group = 'psa'))
          / (SELECT conversion_rate FROM overall_group_performance WHERE test_group = 'psa'),
           (SELECT rel_lift FROM ab_primary), 1e-12
    UNION ALL
    SELECT 'O09', 'total user = SUM(user per grup) = jumlah user valid',
           (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user)::DOUBLE,
           (SELECT SUM(n_users) FROM overall_group_performance)::DOUBLE, 0.0
    UNION ALL
    SELECT 'O10', 'total konversi = SUM(konversi per grup) = SUM(is_converted) populasi valid',
           (SELECT COUNT(*) FROM marketing_ab_clean WHERE is_valid_user AND is_converted)::DOUBLE,
           (SELECT SUM(n_converted) FROM overall_group_performance)::DOUBLE, 0.0
    UNION ALL
    SELECT 'O11', 'SUM(share_of_users) = 1',
           1.0, (SELECT SUM(share_of_users) FROM overall_group_performance), 1e-12
    UNION ALL
    SELECT 'O12', 'SUM(share_of_conversions) = 1',
           1.0, (SELECT SUM(share_of_conversions) FROM overall_group_performance), 1e-12
    UNION ALL
    SELECT 'O13', 'konversi tambahan = konversi ad - (CR psa x n_ad)',
           (SELECT conv_ad - cr_psa * n_ad FROM ab_primary),
           (SELECT incremental_conv FROM overall_incremental), 1e-6
);

SELECT 'P5. Rekonsiliasi dan konsistensi metrik' AS section;

SELECT check_id, check_name, expected, actual, status FROM overall_checks ORDER BY check_id;

SELECT
    COUNT(*)                                     AS n_checks,
    COUNT(*) FILTER (WHERE status = 'PASS')      AS n_pass,
    COUNT(*) FILTER (WHERE status = 'FAIL')      AS n_fail,
    CASE WHEN COUNT(*) FILTER (WHERE status = 'FAIL') = 0 THEN 'ALL PASS' ELSE 'FAIL' END AS overall_gate
FROM overall_checks;
