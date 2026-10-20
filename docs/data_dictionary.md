# Data Dictionary — Layer Clean dan Data Mart

> Melengkapi `docs/data_dictionary_raw.md` (tabel mentah). Dokumen ini mendeskripsikan tabel `marketing_ab_clean` (Tahap 5) dan keempat mart (Tahap 13). Tipe data mengikuti DuckDB dan diverifikasi saat export Parquet (Tahap 14: schema dibaca kembali dan dibandingkan dengan tabel sumber).

## 1. Lapisan data

| Lapisan | Objek | Tahap | Keterangan |
|---|---|---|---|
| Raw | `raw_marketing_ab` | 2 | Semua kolom `VARCHAR`, tidak diubah |
| Staging | `stg_marketing_ab` | 5 | Cast tipe dan rename snake_case, 1 baris per baris raw |
| Clean | `marketing_ab_clean` | 5 | Flag analitik dan aturan D3, 1 baris per baris raw (tidak ada baris dibuang) |
| Mart | `mart_experiment_summary`, `mart_exposure_frequency`, `mart_time_segments`, `mart_data_quality_summary` | 13 | Subjek-oriented untuk dashboard; hanya mengonsumsi hasil analisis |
| Parquet | `data/processed/*.parquet`, `data/data_mart/*.parquet` | 14 | Export dan verifikasi baca-kembali |

## 2. Konvensi

- Nama kolom dan tabel: `snake_case`.
- **Rate dan share di mart adalah proporsi (0 sampai 1)**, misalnya `conversion_rate`, `share_of_group_users`, `wilson_low`. Selisih dan lift memakai satuan eksplisit di nama kolom: `_pp` = poin persentase, `_pct` = persen.
- `test_group`: `ad` = treatment (iklan), `psa` = control (Public Service Announcement), `ALL` = gabungan (hanya di mart).
- Flag boolean berawalan `is_`, `has_`, atau `flag_`.
- Atribut tingkat segmen yang diulang pada setiap baris segmen **bukan ukuran aditif** (lihat bagian 5).

## 3. Tabel clean: `marketing_ab_clean` (588.101 baris × 20 kolom)

**Grain:** 1 baris = 1 baris raw (setelah aturan D3, 1 baris populasi valid = 1 user). **Kunci:** `row_index`; `user_id` unik di populasi valid.

| # | Kolom | Tipe | Arti | Aturan atau nilai |
|---:|---|---|---|---|
| 1 | `row_index` | BIGINT | Row index CSV (kolom pertama tanpa nama di file) | Bukan `user_id` |
| 2 | `user_id` | BIGINT | Identifier pengguna | Unik di populasi valid (588.101 user unik) |
| 3 | `test_group` | VARCHAR | Kelompok eksperimen | `ad` atau `psa`; nilai tidak diubah dari raw |
| 4 | `converted` | BOOLEAN | Outcome konversi | `True` dan `False` raw dipetakan ke boolean |
| 5 | `total_ads` | INTEGER | Jumlah paparan iklan | Variabel post-treatment (D7); minimum 1, maksimum 2.065 |
| 6 | `most_ads_day` | VARCHAR | Hari dengan paparan terbanyak | Nama hari bahasa Inggris; post-treatment, bukan hari konversi |
| 7 | `most_ads_hour` | INTEGER | Jam dengan paparan terbanyak | 0 sampai 23; post-treatment, bukan jam konversi |
| 8 | `is_treatment` | BOOLEAN | Grup treatment | `test_group = 'ad'` |
| 9 | `is_control` | BOOLEAN | Grup control | `test_group = 'psa'` |
| 10 | `is_converted` | BOOLEAN | Flag konversi | `converted = TRUE` |
| 11 | `dup_row_count` | BIGINT | Jumlah baris dengan `user_id` yang sama | 1 berarti unik |
| 12 | `flag_duplicate_user_id` | BOOLEAN | `user_id` muncul lebih dari sekali | `dup_row_count > 1` |
| 13 | `flag_group_conflict` | BOOLEAN | `user_id` berada di lebih dari satu grup | D3(b) |
| 14 | `is_selected_d3` | BOOLEAN | Baris terpilih menurut D3 | `row_index` terkecil per `user_id` |
| 15 | `exclusion_reason` | VARCHAR | Alasan baris tidak masuk analisis | NULL jika valid. Nilai: `missing_user_id`, `invalid_test_group`, `invalid_converted`, `d3b_group_conflict`, `d3ac_duplicate_row_not_selected` |
| 16 | `is_valid_user` | BOOLEAN | Masuk Valid Analysis Population | `exclusion_reason IS NULL` |
| 17 | `has_valid_exposure` | BOOLEAN | Paparan valid | `total_ads` tidak NULL dan ≥ 0 |
| 18 | `has_valid_time` | BOOLEAN | Hari dan jam valid | Hari standar dan jam bilangan bulat 0–23 |
| 19 | `exposure_bucket` | VARCHAR | Bucket paparan (D4) | `b1_le_p50` (≤ 13), `b2_p50_p75` (14–27), `b3_p75_p90` (28–57), `b4_p90_p99` (58–202), `b5_gt_p99` (> 202) |
| 20 | `time_block` | VARCHAR | Blok waktu (D4) | `00-05`, `06-11`, `12-17`, `18-23` |

## 4. Mart

### 4.1 `mart_experiment_summary` (46 baris × 12 kolom)

**Dashboard:** Halaman 1 (overview), 2 (performa kampanye), 4 (keputusan bisnis).
**Grain:** 1 baris = 1 metrik untuk (`section`, `entity`). **Kunci unik:** `section`, `entity`, `metric`.

| Kolom | Tipe | Arti |
|---|---|---|
| `section` | VARCHAR | Kelompok metrik (lihat tabel di bawah) |
| `entity` | VARCHAR | Subjek: `ad`, `psa`, `ALL`, `ad_minus_psa`, `ad_vs_psa`, nama uji, atau ambang D8 |
| `metric` | VARCHAR | Kode metrik |
| `metric_label` | VARCHAR | Label bahasa Indonesia untuk tampilan |
| `value` | DOUBLE | Nilai numerik (NULL untuk baris teks) |
| `ci_low`, `ci_high` | DOUBLE | Batas 95% CI bila ada (NULL bila tidak) |
| `unit` | VARCHAR | `users`, `proportion`, `pp`, `percent`, `z`, `p_value`, `chi2`, `ratio`, atau `text` |
| `value_text` | VARCHAR | Teks (verdict D8, penilaian scorecard, kesimpulan) |
| `detail` | VARCHAR | Keterangan atau bukti |
| `sort_order` | INTEGER | Urutan tampilan di dalam section |
| `source_table` | VARCHAR | Tabel sumber di database (keterlacakan) |

| `section` | Baris | Isi | Sumber |
|---|---:|---|---|
| `group` | 18 | Untuk `ad`, `psa`, `ALL`: `n_users`, `n_converted`, `n_not_converted`, `conversion_rate` (dengan interval Wilson 95%), `share_of_users`, `share_of_conversions` | `overall_group_performance` |
| `effect` | 2 | `absolute_lift_pp` (CI Wald tak-pooled), `relative_lift_pct` (CI Katz) | `ab_primary` |
| `primary_test` | 3 | `z_pooled`, `p_value_two_sided`, `alpha` | `ab_primary` |
| `sensitivity` | 6 | chi-square (`chi2`, p-value), Fisher (`odds_ratio`, p-value), eksklusi duplikat (p-value, `rows_excluded`) | `ab_chi`, `ab_fisher`, `ab_excl_test` |
| `mde` | 4 | `mde_abs_pp`, `mde_rel_pct_of_cr_psa`, `mde_approx_pp`, `power_target` | `ab_mde` |
| `practical_significance` | 3 | Tiga ambang D8 (0,25 / 0,5 / 1,0 pp): `value` = ambang, `ci_low` dan `ci_high` = 95% CI selisih, `value_text` = verdict | `ab_d8` |
| `scorecard` | 8 | Delapan pertanyaan kekuatan bukti (`Q1` sampai `Q8`): `value_text` = penilaian, `detail` = bukti | `overall_scorecard` |
| `conclusion` | 2 | Kesimpulan utama dan kesimpulan robustness (`value_text`) | `overall_conclusion`, `robust_conclusion` |

### 4.2 `mart_exposure_frequency` (15 baris × 17 kolom)

**Dashboard:** Halaman 3 (Jalur Lanjutan). **Eksploratif.**
**Grain:** 1 baris = 1 sel (`exposure_bucket` × `test_group`). **Kunci unik:** `exposure_bucket`, `test_group`.

| Kolom | Tipe | Arti |
|---|---|---|
| `exposure_bucket` | VARCHAR | Bucket paparan (D4) |
| `bucket_order` | INTEGER | Urutan bucket 1–5 |
| `total_ads_range` | VARCHAR | Rentang `total_ads` bucket (mis. `1-13`) |
| `test_group` | VARCHAR | `ad`, `psa`, `ALL` |
| `n_users` | BIGINT | Jumlah user di sel |
| `n_converted` | BIGINT | Jumlah konversi di sel |
| `conversion_rate` | DOUBLE | `n_converted / n_users` (proporsi) |
| `wilson_low`, `wilson_high` | DOUBLE | Interval Wilson 95% (K3) |
| `share_of_group_users` | DOUBLE | Porsi user bucket di dalam grup |
| `share_of_group_conversions` | DOUBLE | Porsi konversi bucket di dalam grup |
| `is_small_segment` | BOOLEAN | Sel kecil (D5): < 500 user atau < 30 konversi |
| `interpretation_flag` | VARCHAR | `ok` atau `kecil (D5): tidak diinterpretasikan` |
| `bucket_diff_ad_minus_psa_pp` | DOUBLE | Selisih CR `ad` − `psa` (pp); atribut tingkat bucket, NULL bila salah satu sel kecil |
| `bucket_diff_interpretable` | BOOLEAN | Selisih dapat diinterpretasikan (kedua sel lolos D5) |
| `analysis_label` | VARCHAR | `EXPLORATORY: asosiasi, bukan kausal (D7)` |
| `source_table` | VARCHAR | `exposure_bucket_cells` |

### 4.3 `mart_time_segments` (105 baris × 23 kolom)

**Dashboard:** Halaman 3 (Jalur Lanjutan). **Eksploratif.**
**Grain:** 1 baris = 1 sel (`segment_type` × `segment` × `test_group`); 35 segmen (7 hari + 4 blok + 24 jam) × 3 grup. **Kunci unik:** `segment_type`, `segment`, `test_group`.

| Kolom | Tipe | Arti |
|---|---|---|
| `segment_type` | VARCHAR | `day`, `time_block`, `hour` |
| `segment` | VARCHAR | Nama hari, blok (`00-05`, dst.), atau jam dua digit (`00` sampai `23`) |
| `segment_order` | INTEGER | Urutan tampilan |
| `test_group` | VARCHAR | `ad`, `psa`, `ALL` |
| `n_users`, `n_converted` | BIGINT | Jumlah user dan konversi di sel |
| `conversion_rate` | DOUBLE | `n_converted / n_users` (proporsi) |
| `wilson_low`, `wilson_high` | DOUBLE | Interval Wilson 95% (K3) |
| `share_of_group_users` | DOUBLE | Porsi user segmen di dalam grup |
| `is_small_segment` | BOOLEAN | Sel kecil (D5) |
| `interpretation_flag` | VARCHAR | `ok` atau `kecil (D5): tidak diinterpretasikan` |
| `segment_diff_ad_minus_psa_pp` | DOUBLE | Selisih CR `ad` − `psa` (pp); atribut tingkat segmen, NULL bila salah satu sel kecil |
| `segment_diff_ci_low_pp`, `segment_diff_ci_high_pp` | DOUBLE | CI Wald tak-pooled selisih (pp), hanya segmen yang diuji; **tidak disesuaikan multiple testing** |
| `p_value_raw` | DOUBLE | p-value mentah (hanya hari dan blok yang diuji) |
| `p_value_holm` | DOUBLE | **p-value terkoreksi Holm (D6)**; nilai yang ditampilkan dashboard. Segmen tidak diuji bernilai 1 |
| `segment_tested` | BOOLEAN | Segmen diuji (hari dan blok yang lolos D5) |
| `significant_holm` | BOOLEAN | `p_value_holm < 0,05` untuk segmen yang diuji |
| `holm_family_size` | BIGINT | Ukuran family Holm: 7 (hari) atau 4 (blok) |
| `test_status` | VARCHAR | `diuji, koreksi Holm (D6)`, `tidak diuji (sel kecil, D5), p = 1 dalam Holm`, atau `deskriptif saja (D6), tanpa uji` (jam) |
| `analysis_label` | VARCHAR | `EXPLORATORY: asosiasi, bukan kausal (D7)` |
| `source_table` | VARCHAR | `time_segment_cells, time_segment_wide` |

**Jam (24) tidak memiliki p-value** (`p_value_raw`, `p_value_holm`, `segment_tested`, `significant_holm`, dan `holm_family_size` bernilai NULL).

### 4.4 `mart_data_quality_summary` (43 baris × 10 kolom)

**Dashboard:** Halaman 5 (data quality dan metodologi). Assumptions dan limitations adalah text box statis di dashboard (`docs/assumptions.md` dan register keterbatasan di `docs/11_segment_robustness.md`).
**Grain:** 1 baris = 1 metrik kualitas data. **Kunci unik:** `section`, `metric`.

| Kolom | Tipe | Arti |
|---|---|---|
| `section` | VARCHAR | Kelompok metrik |
| `metric` | VARCHAR | Kode metrik |
| `metric_label` | VARCHAR | Label tampilan |
| `value` | DOUBLE | Nilai (jumlah baris, user, pemeriksaan, atau selisih) |
| `unit` | VARCHAR | `rows`, `columns`, `users`, `checks`, `cells`, `ratio` |
| `proportion` | DOUBLE | Proporsi terhadap rujukan (0 sampai 1), bila relevan |
| `status` | VARCHAR | `OK`, `PERHATIAN`, `PASS`, `FAIL`, `ALL PASS`, atau `INFO` |
| `detail` | VARCHAR | Keterangan |
| `sort_order` | INTEGER | Urutan di dalam section |
| `source_table` | VARCHAR | Tabel sumber |

| `section` | Baris | Isi |
|---|---:|---|
| `row_counts` | 6 | Baris mentah, kolom mentah, populasi valid, baris dikeluarkan, Exposure Population, Time Population |
| `missing_values` | 7 | Jumlah dan proporsi missing (NULL atau kosong) per kolom raw |
| `flags` | 8 | Baris per alasan eksklusi (5), `user_id` berulang, tanpa paparan valid, tanpa hari/jam valid |
| `reconciliation` | 5 | Selisih rekonsiliasi (harus 0) dengan status `PASS` atau `FAIL` |
| `group_ratio` | 3 | `n_ad`, `n_psa`, rasio `ad : psa` (deskriptif; SRM tidak dapat dinilai) |
| `validation_gates` | 6 | Jumlah pemeriksaan dan status gate: `validation_summary`, `ab_checks`, `overall_checks`, `exposure_checks`, `time_checks`, `robust_checks` |
| `small_cells` | 8 | Jumlah sel kecil D5 per family dan grup |

## 5. Catatan penggunaan

- **Atribut tingkat segmen diulang pada setiap baris segmen** (`bucket_diff_*`, `segment_diff_*`, `p_value_*`, `significant_holm`, `holm_family_size`, `test_status`). Nilai ini **tidak boleh dijumlahkan atau dirata-rata** antar baris; di dashboard, ambil dari satu baris per segmen (mis. `test_group = 'ALL'`).
- Nilai `n_users` dan `n_converted` bersifat aditif antar segmen **di dalam satu `segment_type` dan satu `test_group`**: jumlahnya sama dengan ukuran grup (564.577, 23.524, 588.101 untuk `ad`, `psa`, `ALL`).
- **Jangan menjumlahkan baris `ALL` bersama baris `ad` dan `psa`** (akan menghitung ganda).
- Rate sel kecil tetap ditampilkan tetapi harus diberi penanda; jangan diinterpretasikan (D5).
- Seluruh isi mart segmen dan paparan adalah **asosiasi**, bukan sebab-akibat (D7).
