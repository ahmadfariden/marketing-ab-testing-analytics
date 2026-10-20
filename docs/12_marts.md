# 12 — Data Mart Design

> Pendamping: `sql/12_marts.sql` · Tahap 13 (Jalur Inti)
> Kamus kolom lengkap ada di `docs/data_dictionary.md`.

## Input

- Hasil analisis Tahap 5–12 di `ab_testing.duckdb`: `marketing_ab_clean`, `ab_primary`, `ab_chi`, `ab_fisher`, `ab_excl_test`, `ab_mde`, `ab_d8`, `overall_group_performance`, `overall_scorecard`, `overall_conclusion`, `exposure_bucket_cells`, `exposure_bucket_compare`, `time_segment_cells`, `time_segment_wide`, `robust_conclusion`, dan tabel pemeriksaan tiap tahap.
- Mart **hanya mengonsumsi** hasil analisis tersebut. Tidak ada definisi populasi, KPI, atau keputusan statistik baru.

## Proses Analisis

Empat mart berorientasi subjek, masing-masing dengan grain dan kunci unik yang diperiksa:

| Mart | Halaman dashboard | Grain | Kunci unik | Baris × kolom |
|---|---|---|---|---|
| `mart_experiment_summary` | 1, 2, 4 | 1 metrik per (section, entity) | `section`, `entity`, `metric` | 46 × 12 |
| `mart_exposure_frequency` | 3 | 1 sel (bucket × grup) | `exposure_bucket`, `test_group` | 15 × 17 |
| `mart_time_segments` | 3 | 1 sel (tipe segmen × segmen × grup) | `segment_type`, `segment`, `test_group` | 105 × 23 |
| `mart_data_quality_summary` | 5 | 1 metrik kualitas data | `section`, `metric` | 43 × 10 |

**Keputusan metodologi dashboard yang diwujudkan di desain mart:**

1. CR selalu tersedia bersama $n$, jumlah konversi, absolute lift, dan relative lift.
2. CI, p-value, dan MDE tersedia di mart utama; ketidakpastian tidak disembunyikan.
3. Sel kecil memiliki penanda (`is_small_segment`, `interpretation_flag`); p-value segmen yang ditampilkan adalah versi terkoreksi Holm (D6); **jam (24) tidak memiliki p-value**.
4. Mart segmen dan paparan diberi label `EXPLORATORY: asosiasi, bukan kausal (D7)`.
5. Data quality: metrik kuantitatif di mart; assumptions dan limitations adalah text box statis di dashboard.

**Konvensi:** seluruh rate dan share disimpan sebagai **proporsi (0–1)**; lift dan selisih memakai satuan eksplisit (`_pp`, `_pct`). Atribut tingkat segmen yang diulang pada baris segmen bukan ukuran aditif (didokumentasikan di kamus data).

## Temuan

### Acceptance Criteria: 40 dari 40 pemeriksaan PASS

| Kelompok | Pemeriksaan | Hasil |
|---|---|---|
| Kunci unik | Setiap mart: baris = jumlah kombinasi kunci | PASS (M01, M21, M31, M40) |
| `mart_experiment_summary` | Jumlah user `ad` + `psa` = 588.101; konversi = 14.843; CR = konversi / $n$; lift, relative lift, p-value, CI, dan MDE sama dengan Tahap 8; 3 baris D8 dan verdict sama dengan `ab_d8`; 8 baris scorecard; 2 baris kesimpulan | PASS (M02–M14) |
| `mart_exposure_frequency` | 15 baris (5 × 3); SUM(n) per grup = Exposure Population (564.577 dan 23.524); SUM(konversi) = Tahap 8 (14.423 dan 420); jumlah sel kecil = sumber (1); setiap baris sama dengan sumber; SUM(share) = 1 | PASS (M20–M28) |
| `mart_time_segments` | 105 baris (35 segmen × 3); SUM(n) dan SUM(konversi) per tipe segmen = Tahap 8; jumlah sel kecil = sumber (24); jam tidak memiliki p-value; $p_{Holm} \ge p_{mentah}$; ukuran family Holm 7 dan 4; setiap baris sama dengan sumber | PASS (M30–M39) |
| `mart_data_quality_summary` | Baris mentah = COUNT(raw) = valid + dikeluarkan; seluruh baris rekonsiliasi `PASS`; seluruh gate tahap sebelumnya `ALL PASS`; 7 kolom missing; $n_{ad}$ dan $n_{psa}$ = Tahap 8 | PASS (M40–M46) |

> **Catatan run pertama.** Pada run pertama, 39 dari 40 pemeriksaan lolos. M44 (seluruh gate tahap sebelumnya harus `ALL PASS`) gagal karena `time_checks` di database masih berisi hasil lama Tahap 11 (19 dari 20; pemeriksaan T19 gagal akibat galat floating point pada batas bawah Wilson untuk sel dengan 0 konversi). Setelah skrip Tahap 11 yang sudah diperbaiki dijalankan ulang, seluruh 40 pemeriksaan lolos. Gate tidak dilonggarkan.

### Isi mart yang tervalidasi (nilai kunci)

- Grup: `ad` 564.577 user, 14.423 konversi, CR 2,5547% (Wilson 2,514–2,596%); `psa` 23.524 user, 420 konversi, CR 1,7854% (Wilson 1,624–1,963%); `ALL` 588.101 user, 14.843 konversi, CR 2,5239%.
- Efek: absolute lift 0,7692 pp (95% CI 0,5951–0,9434); relative lift 43,09% (95% CI 29,97–57,52%); $z$ = 7,3701; p = 1,705 × 10⁻¹³.
- MDE retrospektif 0,2475 pp; tiga verdict D8 (≥ 0,25 pp dan ≥ 0,5 pp: CI di atas ambang; < 1,0 pp: CI di bawah ambang).
- Sel kecil: bucket paparan 1 sel (`b5` × `psa`); segmen waktu `psa`: 1 blok dan 17 jam; `ad`: 3 jam.
- Kesimpulan robustness otomatis menyebut tiga kasus C-D8 yang berubah (jam D5-ok × 2 estimator dan eksklusi S2), konsisten dengan Tahap 12.

## Output

- Tabel `mart_experiment_summary`, `mart_exposure_frequency`, `mart_time_segments`, `mart_data_quality_summary`, `mart_checks`, dan `mart_catalog` di `ab_testing.duckdb`.
- `sql/12_marts.sql`, dokumen ini, dan `docs/data_dictionary.md`.
- Export Parquet dilakukan di Tahap 14 (`docs/13_parquet_export.md`).

## Assumptions

- Mart tidak mendefinisikan ulang populasi, KPI, atau keputusan statistik; seluruh nilai dibaca dari tabel hasil tahap sebelumnya.
- Pada atribut tingkat segmen yang diulang, nilai diambil dari satu sumber per segmen dan dianggap konstan untuk seluruh baris segmen tersebut.
- Status gate pada `mart_data_quality_summary` dibaca dari tabel pemeriksaan di database; mart akan gagal bila salah satu gate sumber tidak `ALL PASS` (perilaku yang disengaja).

## Batasan data

- Mart mewarisi seluruh keterbatasan analisis: randomization tidak dapat diverifikasi, rasio grup ± 24 : 1, tidak ada data biaya, variabel segmen adalah post-treatment, dan banyak sel `psa` kecil.
- Mart tidak berisi data tingkat user; seluruh isi berupa agregat.

## Kesimpulan

Empat mart berhasil dibangun dengan grain dan kunci unik yang jelas, tanpa definisi baru, dan seluruh 40 pemeriksaan Acceptance Criteria lolos (row-count dan sum-check ke sumbernya, tidak ada double counting). Mart siap diekspor ke Parquet dan diuji lewat KPI Cross-check Gate (Tahap 14).
