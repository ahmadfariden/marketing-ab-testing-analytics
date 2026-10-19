-- ============================================================================
-- FILE:        sql/13_parquet_export.sql
-- TAHAP:       Tahap 14 (Inti): Parquet Export & KPI Cross-check Gate (WAJIB, blocker sebelum Tahap 15)
-- TUJUAN:      (1) Export staging ke data/processed/ dan mart ke data/data_mart/, lalu verifikasi schema,
--                  isi, dan ukuran file dengan membaca kembali file Parquet.
--              (2) KPI Cross-check Gate: menghitung ulang secara INDEPENDEN KPI terkunci dan hasil uji dari
--                  file Parquet, lalu membandingkannya dengan nilai pada Parquet mart (yang dikonsumsi dashboard).
-- ============================================================================
-- GRAIN:       Tabel verifikasi: 1 baris = 1 file Parquet. Tabel gate: 1 baris = 1 KPI atau statistik.
-- POPULATION:  Valid Analysis Population (dihitung ulang dari exclusion_reason IS NULL, bukan flag is_valid_user).
-- DENOMINATOR: n_ad dan n_psa hasil hitung ulang dari file Parquet.
-- ============================================================================
-- Jalankan (PowerShell, dari root folder proyek):
--   .\duckdb.exe ab_testing.duckdb -c ".read sql/13_parquet_export.sql"
--
-- Prasyarat: sql/12_marts.sql sudah dijalankan dengan mart_gate = ALL PASS (skrip ini menolak lanjut jika tidak).
-- Folder data/processed dan data/data_mart harus ada (ada dari skeleton proyek).
--
-- PENGGANTI NOTEBOOK: roadmap semula memakai notebooks/kpi_crosscheck.ipynb (pandas dan statsmodels). Proyek ini
-- full DuckDB dan SQL, sehingga gate dijalankan di SQL. Rumus dan toleransi TIDAK diubah dari roadmap:
--
--   KPI / statistik            toleransi
--   Valid users per grup       persis sama
--   Konversi per grup          persis sama
--   CR per grup                <= 0,001 poin persentase
--   Absolute lift              <= 0,001 poin persentase
--   Relative lift              <= 0,001 poin persentase
--   p-value z-test             selisih mutlak <= 1e-6 (dua implementasi)
--   95% CI selisih proporsi    selisih batas <= 0,001 poin persentase
--   z-test dihitung DUA KALI: implementasi A = pooled z (macro ab_norm_sf, deret erf dan continued fraction);
--   implementasi B = chi-square rumus 2x2, z = akar chi-square, tail normal lewat integrasi numerik Simpson.
--   Kedua implementasi berbeda aljabar dan algoritma tail.
--
-- MDE retrospektif SENGAJA tidak termasuk gate (bukan KPI terkunci; dua metode sah bisa menghasilkan angka berbeda).
-- DILARANG mengubah toleransi atau rumus supaya lolos. Jika GATE = FAIL: jangan lanjut ke Tahap 15, telusuri lewat
-- Rollback Matrix (Tahap 6, 8, atau 13), perbaiki sumber, jalankan ulang skrip ini.
-- ============================================================================

.mode markdown
.maxrows 1000

-- ----------------------------------------------------------------------------
-- 0. Syarat awal: seluruh pemeriksaan mart (Tahap 13) harus PASS. Jika tidak, skrip berhenti sebelum export.
-- ----------------------------------------------------------------------------
SELECT 'G0. Syarat awal: mart_checks harus ALL PASS' AS section;

SELECT
    COUNT(*)                                     AS n_checks,
    COUNT(*) FILTER (WHERE status = 'PASS')      AS n_pass,
    COUNT(*) FILTER (WHERE status <> 'PASS')     AS n_fail,
    CASE WHEN COUNT(*) FILTER (WHERE status <> 'PASS') = 0 THEN 'OK, export dilanjutkan'
         ELSE error('BERHENTI: mart_checks tidak ALL PASS. Jalankan ulang tahap sumber dan sql/12_marts.sql sampai mart_gate = ALL PASS.') END AS precondition
FROM mart_checks;

-- ----------------------------------------------------------------------------
-- 1. Export: staging -> data/processed/ dan mart -> data/data_mart/
-- ----------------------------------------------------------------------------
COPY (SELECT * FROM marketing_ab_clean ORDER BY row_index)
TO 'data/processed/04_marketing_ab_clean.parquet' (FORMAT PARQUET, COMPRESSION ZSTD);

COPY (SELECT * FROM mart_experiment_summary ORDER BY section, entity, sort_order, metric)
TO 'data/data_mart/mart_experiment_summary.parquet' (FORMAT PARQUET, COMPRESSION ZSTD);

COPY (SELECT * FROM mart_exposure_frequency ORDER BY bucket_order, test_group)
TO 'data/data_mart/mart_exposure_frequency.parquet' (FORMAT PARQUET, COMPRESSION ZSTD);

COPY (SELECT * FROM mart_time_segments ORDER BY segment_type, segment_order, test_group)
TO 'data/data_mart/mart_time_segments.parquet' (FORMAT PARQUET, COMPRESSION ZSTD);

COPY (SELECT * FROM mart_data_quality_summary ORDER BY section, sort_order, metric)
TO 'data/data_mart/mart_data_quality_summary.parquet' (FORMAT PARQUET, COMPRESSION ZSTD);

-- ----------------------------------------------------------------------------
-- 2. Verifikasi: baca kembali setiap file. Jumlah baris, schema (nama dan tipe), dan isi (EXCEPT dua arah)
--    harus sama dengan tabel sumber.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE parquet_verification AS
WITH v AS (
    SELECT 'data/processed/04_marketing_ab_clean.parquet' AS file_path, 'marketing_ab_clean' AS table_name,
        (SELECT COUNT(*) FROM marketing_ab_clean) AS rows_table,
        (SELECT COUNT(*) FROM read_parquet('data/processed/04_marketing_ab_clean.parquet')) AS rows_parquet,
        (SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'marketing_ab_clean') AS cols_table,
        (SELECT COUNT(*) FROM (DESCRIBE SELECT * FROM read_parquet('data/processed/04_marketing_ab_clean.parquet'))) AS cols_parquet,
        (SELECT COUNT(*) FROM (SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'marketing_ab_clean'
                               EXCEPT SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_parquet('data/processed/04_marketing_ab_clean.parquet')))) AS schema_diff_a,
        (SELECT COUNT(*) FROM (SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_parquet('data/processed/04_marketing_ab_clean.parquet'))
                               EXCEPT SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'marketing_ab_clean')) AS schema_diff_b,
        (SELECT COUNT(*) FROM (SELECT * FROM marketing_ab_clean EXCEPT SELECT * FROM read_parquet('data/processed/04_marketing_ab_clean.parquet'))) AS content_diff_a,
        (SELECT COUNT(*) FROM (SELECT * FROM read_parquet('data/processed/04_marketing_ab_clean.parquet') EXCEPT SELECT * FROM marketing_ab_clean)) AS content_diff_b
    UNION ALL
    SELECT 'data/data_mart/mart_experiment_summary.parquet', 'mart_experiment_summary',
        (SELECT COUNT(*) FROM mart_experiment_summary),
        (SELECT COUNT(*) FROM read_parquet('data/data_mart/mart_experiment_summary.parquet')),
        (SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'mart_experiment_summary'),
        (SELECT COUNT(*) FROM (DESCRIBE SELECT * FROM read_parquet('data/data_mart/mart_experiment_summary.parquet'))),
        (SELECT COUNT(*) FROM (SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'mart_experiment_summary'
                               EXCEPT SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_parquet('data/data_mart/mart_experiment_summary.parquet')))),
        (SELECT COUNT(*) FROM (SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_parquet('data/data_mart/mart_experiment_summary.parquet'))
                               EXCEPT SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'mart_experiment_summary')),
        (SELECT COUNT(*) FROM (SELECT * FROM mart_experiment_summary EXCEPT SELECT * FROM read_parquet('data/data_mart/mart_experiment_summary.parquet'))),
        (SELECT COUNT(*) FROM (SELECT * FROM read_parquet('data/data_mart/mart_experiment_summary.parquet') EXCEPT SELECT * FROM mart_experiment_summary))
    UNION ALL
    SELECT 'data/data_mart/mart_exposure_frequency.parquet', 'mart_exposure_frequency',
        (SELECT COUNT(*) FROM mart_exposure_frequency),
        (SELECT COUNT(*) FROM read_parquet('data/data_mart/mart_exposure_frequency.parquet')),
        (SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'mart_exposure_frequency'),
        (SELECT COUNT(*) FROM (DESCRIBE SELECT * FROM read_parquet('data/data_mart/mart_exposure_frequency.parquet'))),
        (SELECT COUNT(*) FROM (SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'mart_exposure_frequency'
                               EXCEPT SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_parquet('data/data_mart/mart_exposure_frequency.parquet')))),
        (SELECT COUNT(*) FROM (SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_parquet('data/data_mart/mart_exposure_frequency.parquet'))
                               EXCEPT SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'mart_exposure_frequency')),
        (SELECT COUNT(*) FROM (SELECT * FROM mart_exposure_frequency EXCEPT SELECT * FROM read_parquet('data/data_mart/mart_exposure_frequency.parquet'))),
        (SELECT COUNT(*) FROM (SELECT * FROM read_parquet('data/data_mart/mart_exposure_frequency.parquet') EXCEPT SELECT * FROM mart_exposure_frequency))
    UNION ALL
    SELECT 'data/data_mart/mart_time_segments.parquet', 'mart_time_segments',
        (SELECT COUNT(*) FROM mart_time_segments),
        (SELECT COUNT(*) FROM read_parquet('data/data_mart/mart_time_segments.parquet')),
        (SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'mart_time_segments'),
        (SELECT COUNT(*) FROM (DESCRIBE SELECT * FROM read_parquet('data/data_mart/mart_time_segments.parquet'))),
        (SELECT COUNT(*) FROM (SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'mart_time_segments'
                               EXCEPT SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_parquet('data/data_mart/mart_time_segments.parquet')))),
        (SELECT COUNT(*) FROM (SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_parquet('data/data_mart/mart_time_segments.parquet'))
                               EXCEPT SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'mart_time_segments')),
        (SELECT COUNT(*) FROM (SELECT * FROM mart_time_segments EXCEPT SELECT * FROM read_parquet('data/data_mart/mart_time_segments.parquet'))),
        (SELECT COUNT(*) FROM (SELECT * FROM read_parquet('data/data_mart/mart_time_segments.parquet') EXCEPT SELECT * FROM mart_time_segments))
    UNION ALL
    SELECT 'data/data_mart/mart_data_quality_summary.parquet', 'mart_data_quality_summary',
        (SELECT COUNT(*) FROM mart_data_quality_summary),
        (SELECT COUNT(*) FROM read_parquet('data/data_mart/mart_data_quality_summary.parquet')),
        (SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'mart_data_quality_summary'),
        (SELECT COUNT(*) FROM (DESCRIBE SELECT * FROM read_parquet('data/data_mart/mart_data_quality_summary.parquet'))),
        (SELECT COUNT(*) FROM (SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'mart_data_quality_summary'
                               EXCEPT SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_parquet('data/data_mart/mart_data_quality_summary.parquet')))),
        (SELECT COUNT(*) FROM (SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM read_parquet('data/data_mart/mart_data_quality_summary.parquet'))
                               EXCEPT SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'mart_data_quality_summary')),
        (SELECT COUNT(*) FROM (SELECT * FROM mart_data_quality_summary EXCEPT SELECT * FROM read_parquet('data/data_mart/mart_data_quality_summary.parquet'))),
        (SELECT COUNT(*) FROM (SELECT * FROM read_parquet('data/data_mart/mart_data_quality_summary.parquet') EXCEPT SELECT * FROM mart_data_quality_summary))
)
SELECT
    v.file_path, v.table_name, v.rows_table, v.rows_parquet, v.cols_table, v.cols_parquet,
    v.schema_diff_a + v.schema_diff_b                                   AS schema_diff,
    v.content_diff_a + v.content_diff_b                                 AS content_diff,
    s.size                                                              AS size_bytes,
    CASE WHEN v.rows_table = v.rows_parquet AND v.cols_table = v.cols_parquet
          AND v.schema_diff_a = 0 AND v.schema_diff_b = 0
          AND v.content_diff_a = 0 AND v.content_diff_b = 0
         THEN 'MATCH' ELSE 'MISMATCH' END                               AS status
FROM v
JOIN (SELECT replace(filename, '\', '/') AS fname, size
        FROM read_blob(['data/processed/04_marketing_ab_clean.parquet', 'data/data_mart/*.parquet'])) s
  ON s.fname LIKE '%' || v.file_path;

SELECT 'G1. Verifikasi file Parquet: jumlah baris, schema, dan isi dibaca kembali' AS section;

SELECT
    file_path, rows_table, rows_parquet, cols_table, cols_parquet, schema_diff, content_diff,
    round(size_bytes / 1024.0, 1) AS size_kb,
    status
FROM parquet_verification
ORDER BY file_path;

SELECT 'G1b. Ukuran file dan perlakuan Git' AS section;

SELECT
    file_path,
    round(size_bytes / 1024.0 / 1024.0, 3) AS size_mb,
    CASE WHEN file_path LIKE 'data/processed/%' THEN 'diabaikan .gitignore, regenerasi lewat sql/04 dan sql/13 (catat di README)'
         ELSE 'di-commit (mart kecil, dibaca Power BI)' END AS git_treatment
FROM parquet_verification
ORDER BY file_path;

-- ----------------------------------------------------------------------------
-- 3. Macro tail normal independen untuk implementasi B (integrasi Simpson, bukan deret atau continued fraction)
--    sf(z) = integral dari z sampai z + 12 dari pdf normal baku, z >= 0. N = 4000 interval (genap).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE MACRO ab_norm_sf_simpson(z) AS
    (12.0 / 4000.0 / 3.0) * list_sum(list_transform(range(0, 4001),
        lambda i: (CASE WHEN i = 0 OR i = 4000 THEN 1.0 WHEN i % 2 = 1 THEN 4.0 ELSE 2.0 END)
                  * exp(-power(z + i * (12.0 / 4000.0), 2) / 2.0) / sqrt(2.0 * pi())));

-- ----------------------------------------------------------------------------
-- 4. KPI Cross-check Gate
--    value_sql        : nilai pada Parquet mart (artefak yang dikonsumsi dashboard)
--    value_recomputed : dihitung ulang INDEPENDEN dari file 04_marketing_ab_clean.parquet
--                       (populasi valid = exclusion_reason IS NULL, konversi = kolom converted, grup = test_group)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW v_gate_sql AS
SELECT
    MAX(value) FILTER (WHERE section = 'group' AND entity = 'ad'  AND metric = 'n_users')          AS n_ad,
    MAX(value) FILTER (WHERE section = 'group' AND entity = 'psa' AND metric = 'n_users')          AS n_psa,
    MAX(value) FILTER (WHERE section = 'group' AND entity = 'ad'  AND metric = 'n_converted')      AS x_ad,
    MAX(value) FILTER (WHERE section = 'group' AND entity = 'psa' AND metric = 'n_converted')      AS x_psa,
    MAX(value) FILTER (WHERE section = 'group' AND entity = 'ad'  AND metric = 'conversion_rate')  AS cr_ad,
    MAX(value) FILTER (WHERE section = 'group' AND entity = 'psa' AND metric = 'conversion_rate')  AS cr_psa,
    MAX(value) FILTER (WHERE section = 'effect' AND metric = 'absolute_lift_pp')                   AS lift_pp,
    MAX(value) FILTER (WHERE section = 'effect' AND metric = 'relative_lift_pct')                  AS rel_pct,
    MAX(ci_low)  FILTER (WHERE section = 'effect' AND metric = 'absolute_lift_pp')                 AS ci_low_pp,
    MAX(ci_high) FILTER (WHERE section = 'effect' AND metric = 'absolute_lift_pp')                 AS ci_high_pp,
    MAX(value) FILTER (WHERE section = 'primary_test' AND metric = 'z_pooled')                     AS z_stat,
    MAX(value) FILTER (WHERE section = 'primary_test' AND metric = 'p_value_two_sided')            AS p_value
FROM read_parquet('data/data_mart/mart_experiment_summary.parquet');

CREATE OR REPLACE TEMP VIEW v_gate_rec AS
WITH c AS (
    SELECT
        COUNT(*) FILTER (WHERE test_group = 'ad'  AND exclusion_reason IS NULL)                      AS n_ad,
        COUNT(*) FILTER (WHERE test_group = 'psa' AND exclusion_reason IS NULL)                      AS n_psa,
        COUNT(*) FILTER (WHERE test_group = 'ad'  AND exclusion_reason IS NULL AND converted)        AS x_ad,
        COUNT(*) FILTER (WHERE test_group = 'psa' AND exclusion_reason IS NULL AND converted)        AS x_psa
    FROM read_parquet('data/processed/04_marketing_ab_clean.parquet')
),
r AS (
    SELECT
        c.*,
        x_ad::DOUBLE / n_ad                                                                          AS cr_ad,
        x_psa::DOUBLE / n_psa                                                                        AS cr_psa
    FROM c
),
t AS (
    SELECT
        r.*,
        (x_ad + x_psa)::DOUBLE / (n_ad + n_psa)                                                      AS p_hat,
        sqrt(cr_ad * (1 - cr_ad) / n_ad + cr_psa * (1 - cr_psa) / n_psa)                             AS se_unp
    FROM r
),
a AS (
    SELECT
        t.*,
        (cr_ad - cr_psa) / sqrt(p_hat * (1 - p_hat) * (1.0 / n_ad + 1.0 / n_psa))                    AS z_a
    FROM t
),
b AS (
    SELECT
        a.*,
        -- chi-square rumus 2x2: N (ad - bc)^2 / ((a+b)(c+d)(a+c)(b+d)), sel: a = x_ad, b = n_ad - x_ad, c = x_psa, d = n_psa - x_psa
        (n_ad + n_psa)::DOUBLE
          * power(x_ad::DOUBLE * (n_psa - x_psa) - (n_ad - x_ad)::DOUBLE * x_psa, 2)
          / (n_ad::DOUBLE * n_psa * (x_ad + x_psa) * ((n_ad + n_psa) - (x_ad + x_psa)))             AS chi2_b
    FROM a
)
SELECT
    b.*,
    100.0 * (cr_ad - cr_psa)                                                                         AS lift_pp,
    100.0 * (cr_ad - cr_psa) / cr_psa                                                                AS rel_pct,
    100.0 * ((cr_ad - cr_psa) - 1.959963984540054 * se_unp)                                          AS ci_low_pp,
    100.0 * ((cr_ad - cr_psa) + 1.959963984540054 * se_unp)                                          AS ci_high_pp,
    2.0 * ab_norm_sf(abs(z_a))                                                                       AS p_a,
    sqrt(chi2_b)                                                                                     AS z_b,
    2.0 * ab_norm_sf_simpson(sqrt(chi2_b))                                                           AS p_b
FROM b;

CREATE OR REPLACE TABLE kpi_crosscheck AS
WITH rows_ AS (
    SELECT 1 AS ord, 'n_users_ad' AS kpi, s.n_ad AS value_sql, r.n_ad::DOUBLE AS value_recomputed, 0.0 AS tolerance FROM v_gate_sql s, v_gate_rec r
    UNION ALL SELECT 2, 'n_users_psa', s.n_psa, r.n_psa::DOUBLE, 0.0 FROM v_gate_sql s, v_gate_rec r
    UNION ALL SELECT 3, 'n_converted_ad', s.x_ad, r.x_ad::DOUBLE, 0.0 FROM v_gate_sql s, v_gate_rec r
    UNION ALL SELECT 4, 'n_converted_psa', s.x_psa, r.x_psa::DOUBLE, 0.0 FROM v_gate_sql s, v_gate_rec r
    UNION ALL SELECT 5, 'cr_ad_pp', 100.0 * s.cr_ad, 100.0 * r.cr_ad, 0.001 FROM v_gate_sql s, v_gate_rec r
    UNION ALL SELECT 6, 'cr_psa_pp', 100.0 * s.cr_psa, 100.0 * r.cr_psa, 0.001 FROM v_gate_sql s, v_gate_rec r
    UNION ALL SELECT 7, 'absolute_lift_pp', s.lift_pp, r.lift_pp, 0.001 FROM v_gate_sql s, v_gate_rec r
    UNION ALL SELECT 8, 'relative_lift_pct', s.rel_pct, r.rel_pct, 0.001 FROM v_gate_sql s, v_gate_rec r
    UNION ALL SELECT 9, 'ci95_low_pp', s.ci_low_pp, r.ci_low_pp, 0.001 FROM v_gate_sql s, v_gate_rec r
    UNION ALL SELECT 10, 'ci95_high_pp', s.ci_high_pp, r.ci_high_pp, 0.001 FROM v_gate_sql s, v_gate_rec r
    UNION ALL SELECT 11, 'z_statistic_impl_A', s.z_stat, r.z_a, 1e-6 FROM v_gate_sql s, v_gate_rec r
    UNION ALL SELECT 12, 'z_statistic_impl_B', s.z_stat, r.z_b, 1e-6 FROM v_gate_sql s, v_gate_rec r
    UNION ALL SELECT 13, 'p_value_impl_A', s.p_value, r.p_a, 1e-6 FROM v_gate_sql s, v_gate_rec r
    UNION ALL SELECT 14, 'p_value_impl_B', s.p_value, r.p_b, 1e-6 FROM v_gate_sql s, v_gate_rec r
    UNION ALL SELECT 15, 'p_value_impl_A_vs_impl_B', r.p_a, r.p_b, 1e-6 FROM v_gate_rec r
    UNION ALL SELECT 16, 'p_value_relative_diff_A_vs_B (tambahan)', 0.0, abs(r.p_a - r.p_b) / r.p_a, 1e-6 FROM v_gate_rec r
)
SELECT kpi, value_sql, value_recomputed, abs(value_sql - value_recomputed) AS abs_diff, tolerance,
       CASE WHEN abs(value_sql - value_recomputed) <= tolerance THEN 'PASS' ELSE 'FAIL' END AS status
FROM rows_
UNION ALL
SELECT 'GATE', NULL, NULL, NULL, NULL,
       CASE WHEN (SELECT COUNT(*) FROM (
                    SELECT 1 FROM rows_ WHERE abs(value_sql - value_recomputed) > tolerance)) = 0
            THEN 'PASS' ELSE 'FAIL' END;

SELECT 'G2. KPI Cross-check Gate (SQL-only, independen dari file Parquet)' AS section;

SELECT
    kpi, value_sql, value_recomputed, abs_diff, tolerance, status
FROM kpi_crosscheck
ORDER BY CASE kpi WHEN 'GATE' THEN 1 ELSE 0 END, kpi;

-- ----------------------------------------------------------------------------
-- 5. Simpan hasil gate dan verifikasi baca-kembali
-- ----------------------------------------------------------------------------
COPY (SELECT * FROM kpi_crosscheck ORDER BY CASE kpi WHEN 'GATE' THEN 1 ELSE 0 END, kpi)
TO 'data/processed/14_kpi_crosscheck.parquet' (FORMAT PARQUET, COMPRESSION ZSTD);

SELECT 'G3. Verifikasi 14_kpi_crosscheck.parquet' AS section;

SELECT
    COUNT(*)                                              AS n_rows_parquet,
    (SELECT COUNT(*) FROM kpi_crosscheck)                 AS n_rows_table,
    COUNT(*) FILTER (WHERE status = 'FAIL')               AS n_fail_rows,
    MAX(status) FILTER (WHERE kpi = 'GATE')               AS gate
FROM read_parquet('data/processed/14_kpi_crosscheck.parquet');

-- ----------------------------------------------------------------------------
-- 6. Hard stop (pengganti assert di notebook): gagal keras bila ada verifikasi MISMATCH atau gate FAIL
-- ----------------------------------------------------------------------------
SELECT 'G4. Hard stop' AS section;

SELECT
    (SELECT COUNT(*) FROM parquet_verification WHERE status <> 'MATCH')             AS n_parquet_mismatch,
    (SELECT status FROM kpi_crosscheck WHERE kpi = 'GATE')                          AS gate,
    CASE WHEN (SELECT COUNT(*) FROM parquet_verification WHERE status <> 'MATCH') = 0
          AND (SELECT status FROM kpi_crosscheck WHERE kpi = 'GATE') = 'PASS'
         THEN 'GATE = PASS: boleh lanjut ke Tahap 15'
         ELSE error('GATE FAIL atau verifikasi Parquet MISMATCH. JANGAN lanjut ke Tahap 15. Telusuri lewat Rollback Matrix, perbaiki sumber, jalankan ulang. Dilarang mengubah toleransi atau rumus.') END AS hasil;
