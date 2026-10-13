# 05 — Data Validation & KPI Lock

> Pendamping: `sql/05_data_validation.sql` · Tahap 6 (Jalur Inti)
> Keputusan yang dikunci ada di `docs/methodology.md`.

## Input

- `marketing_ab_clean`, `stg_marketing_ab` (hasil Tahap 5) dan `raw_marketing_ab` (sumber independen untuk pembanding).
- Keputusan pre-lock D1–D9 dari roadmap, ditambah penyelesaian tiga butir terbuka dari Tahap 4–5 (C-02, C-03, C-04).

## Proses Analisis

1. Membuat tabel `validation_summary`: 18 pemeriksaan dengan kolom `expected`, `actual`, `status`. Nilai `expected` dihitung langsung dari `raw_marketing_ab`, nilai `actual` dari `marketing_ab_clean`, sehingga pemeriksaan tidak membandingkan tabel dengan dirinya sendiri.
2. Kuantil D4 dihitung ulang secara independen dari raw (tanpa `converted`), lalu dipakai untuk memverifikasi `exposure_bucket` di tabel clean baris per baris. `time_block` diverifikasi dengan cara yang sama.
3. Melaporkan ukuran grup, konversi mentah per grup, dan rasio `ad : psa` secara deskriptif (Sample Ratio Check).
4. Rekonsiliasi raw → valid + dikeluarkan.
5. Ekspor `validation_summary` ke `data/processed/05_validation_summary.parquet`.

CR per grup tidak dihitung di tahap ini (Tahap 7–9).

## Temuan

### Hasil pemeriksaan: 18 dari 18 PASS (gate = ALL PASS)

| Kategori | ID | Pemeriksaan | Expected | Actual | Status |
|---|---|---|---:|---:|---|
| Structural | S01 | Row count raw = stg | 588.101 | 588.101 | PASS |
| Structural | S02 | Row count raw = clean | 588.101 | 588.101 | PASS |
| Structural | S03 | Grain: `user_id` unik di Valid Analysis Population | 588.101 | 588.101 | PASS |
| Structural | S04 | Kegagalan cast tak terduga | 0 | 0 | PASS |
| Experiment | E01 | Tidak ada `user_id` di >1 kelompok | 0 | 0 | PASS |
| Experiment | E02 | Outcome `converted` lengkap (NULL) | 0 | 0 | PASS |
| Experiment | E03 | `test_group` di luar `ad`/`psa` | 0 | 0 | PASS |
| Experiment | E04 | Jumlah nilai `test_group` berbeda | 2 | 2 | PASS |
| Experiment | E05 | Denominator `ad`: raw = clean | 564.577 | 564.577 | PASS |
| Experiment | E06 | Denominator `psa`: raw = clean | 23.524 | 23.524 | PASS |
| Business | B01 | `SUM(is_treatment) + SUM(is_control)` = jumlah valid | 588.101 | 588.101 | PASS |
| Business | B02 | Konversi `ad`: raw = clean | 14.423 | 14.423 | PASS |
| Business | B03 | Konversi `psa`: raw = clean | 420 | 420 | PASS |
| Business | B04 | Raw = valid + dikeluarkan | 588.101 | 588.101 | PASS |
| Lock D3 | L01 | Baris dengan `user_id` berulang | 0 | 0 | PASS |
| Lock D3 | L02 | Baris dikeluarkan karena D3 | 0 | 0 | PASS |
| Lock D4 | L03 | Selisih `exposure_bucket` (clean vs hitung ulang dari raw) | 0 | 0 | PASS |
| Lock D4 | L04 | Selisih `time_block` (clean vs hitung ulang dari raw) | 0 | 0 | PASS |

### Ukuran grup dan Sample Ratio Check (deskriptif)

| Grup | n user | n konversi |
|---|---:|---:|
| `ad` | 564.577 | 14.423 |
| `psa` | 23.524 | 420 |
| **Total** | **588.101** | **14.843** |

- Rasio `ad : psa` = **24,0 : 1**; `psa` = 4,0% dari total.
- Rasio desain grup tidak tersedia di dokumentasi dataset, sehingga SRM **tidak dapat dinyatakan lulus atau gagal**. Rasio ini dicatat sebagai limitation.

### Batas kuantil D4 (dihitung dari raw, tanpa `converted`)

| P50 | P75 | P90 | P99 |
|---:|---:|---:|---:|
| 13 | 27 | 57 | 202 |

Sama dengan angka di Tahap 4 (profiling) dan Tahap 5 (cleaning).

### Ukuran bucket paparan per grup

| Bucket | Rentang `total_ads` | n `ad` | n `psa` | `psa` < 500 user |
|---|---|---:|---:|---|
| b1_le_p50 | 1–13 | 286.895 | 12.601 | tidak |
| b2_p50_p75 | 14–27 | 137.483 | 5.274 | tidak |
| b3_p75_p90 | 28–57 | 85.178 | 3.224 | tidak |
| b4_p90_p99 | 58–202 | 49.461 | 2.175 | tidak |
| b5_gt_p99 | 203–2.065 | 5.560 | **250** | **ya** |
| **Total** | | 564.577 | 23.524 | |

Sel `b5_gt_p99` × `psa` sudah pasti masuk `is_small_segment` (D5) berdasarkan jumlah user saja.

### Rekonsiliasi raw → valid

| Kategori | n baris |
|---|---:|
| Valid | 588.101 |
| Dikeluarkan | 0 |
| **Total (= raw)** | **588.101** |

## Output

- Tabel `validation_summary` di `ab_testing.duckdb`.
- `data/processed/05_validation_summary.parquet` (18 baris; verifikasi `MATCH`; tidak di-commit karena diabaikan `.gitignore`).
- `docs/05_data_validation.md` (dokumen ini).
- `docs/methodology.md` (KPI dictionary, KPI Lock, Decision Log D1–D9, Revision Log, reconciliation report).
- Git tag `kpi-lock` (dibuat setelah commit tahap ini).

## Assumptions

- Hitungan langsung dari `raw_marketing_ab` dianggap sumber kebenaran untuk pembanding.
- Karena Valid Analysis Population = Raw Population (0 baris dikeluarkan), kuantil D4 yang dihitung dari seluruh raw identik dengan kuantil dari populasi valid. Jika data berubah di masa depan, pemeriksaan L03 akan mendeteksi perbedaannya.
- Aturan D3 dicatat **tidak berlaku** karena 0 duplikat dan 0 konflik grup.
- Tiga butir terbuka dari Tahap 4–5 diputuskan sebelum output tahap ini dilihat, dan dikunci di `docs/methodology.md`.

## Batasan data

- Randomization tidak dapat diverifikasi; rasio desain grup tidak diketahui, sehingga SRM tidak dapat dinilai.
- Lolos validasi struktural tidak membuktikan kebenaran substantif nilai (mis. definisi konversi di sumber data).
- Grup `psa` kecil (4%), sehingga sel segmen `psa` rentan di bawah ambang D5.
- Variabel `total_ads`, `most_ads_day`, `most_ads_hour` adalah post-treatment (D7).

## Kesimpulan

Seluruh 18 pemeriksaan struktural, eksperimen, bisnis, dan lock lolos; gate = **ALL PASS**. Valid Analysis Population = 588.101 user (564.577 `ad`, 23.524 `psa`), grain 1 baris = 1 user terverifikasi, denominator dan konversi per grup cocok dengan hitungan independen dari raw, dan bucket serta blok waktu konsisten dengan perhitungan ulang. Populasi, KPI, dan keputusan statistik siap dikunci (`docs/methodology.md`, git tag `kpi-lock`).
