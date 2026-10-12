# 04 — Data Cleaning

> Pendamping: `sql/04_data_cleaning.sql` · Tahap 5 (Jalur Inti)

## Input

- `raw_marketing_ab` (588.101 baris × 7 kolom, semua `VARCHAR`), tidak diubah.
- Temuan profiling (Tahap 4): tidak ada missing, tidak ada duplikat `user_id`, semua nilai grup, `converted`, hari, dan jam valid.

## Proses Analisis

Layering:

```
raw_marketing_ab  →  stg_marketing_ab  →  marketing_ab_clean  →  data/processed/04_marketing_ab_clean.parquet
(ALL_VARCHAR)        (cast + rename)      (flag + aturan D3)
```

1. **Staging** (`stg_marketing_ab`): `TRY_CAST` ke tipe sesuai, rename ke snake_case, 1 baris per baris raw. Nilai `test_group` tidak diubah; `converted` dipetakan `True`/`False` ke `BOOLEAN`.
2. **Clean** (`marketing_ab_clean`): menambahkan flag analitik, penerapan aturan duplikasi **D3**, kolom `exclusion_reason`, `exposure_bucket`, dan `time_block`. **Tidak ada baris yang dibuang** (prinsip *flag, jangan hapus*).
3. **Audit** (A1–A9): row count, kegagalan cast, kebenaran nilai grup dan outcome, rekonsiliasi, konsistensi flag, cleaning log, distribusi bucket, struktur tabel, verifikasi Parquet.

### Skema akhir `marketing_ab_clean`

| Kolom | Tipe | Keterangan |
|---|---|---|
| `row_index` | BIGINT | Row index dari CSV (`column0`) |
| `user_id` | BIGINT | Identifier pengguna |
| `test_group` | VARCHAR | `ad` / `psa` (nilai tidak diubah) |
| `converted` | BOOLEAN | Outcome konversi |
| `total_ads` | INTEGER | Jumlah paparan (post-treatment) |
| `most_ads_day` | VARCHAR | Hari paparan terbanyak (post-treatment) |
| `most_ads_hour` | INTEGER | Jam paparan terbanyak (post-treatment) |
| `is_treatment`, `is_control`, `is_converted` | BOOLEAN | Flag grup dan outcome |
| `dup_row_count`, `flag_duplicate_user_id`, `flag_group_conflict`, `is_selected_d3` | BIGINT / BOOLEAN | Penerapan D3 |
| `exclusion_reason` | VARCHAR | Alasan eksklusi (NULL jika valid) |
| `is_valid_user` | BOOLEAN | Masuk Valid Analysis Population |
| `has_valid_exposure`, `has_valid_time` | BOOLEAN | Validitas paparan dan hari/jam |
| `exposure_bucket`, `time_block` | VARCHAR | Bucket paparan (D4) dan blok waktu |

## Temuan

### Acceptance Criteria

| Kriteria | Hasil | Status |
|---|---|---|
| Row count raw = stg = clean | 588.101 = 588.101 = 588.101 | ✅ MATCH |
| Kegagalan cast (`user_id`, `converted`, `total_ads`, `most_ads_hour`, `row_index`) | 0 di semua kolom | ✅ |
| `test_group` berubah dibanding raw | 0 baris | ✅ |
| `converted` berubah dibanding raw | 0 baris (True 14.843 = 14.843; False 573.258 = 573.258) | ✅ |
| Rekonsiliasi raw → valid + flagged | 588.101 valid + 0 dikeluarkan = 588.101 | ✅ |
| `SUM(is_treatment) + SUM(is_control)` = jumlah `is_valid_user` | 564.577 + 23.524 = 588.101 | ✅ |
| Parquet = tabel | 588.101 = 588.101 | ✅ MATCH |

### Populasi analitik

| Populasi | Jumlah |
|---|---:|
| Raw Population | 588.101 |
| Valid Analysis Population (`is_valid_user`) | 588.101 |
| Treatment (`ad`) | 564.577 |
| Control (`psa`) | 23.524 |
| Exposure Population | 588.101 |
| Time Population | 588.101 |
| `user_id` unik di populasi valid | 588.101 |

### Cleaning log

| Aturan | Deskripsi | Baris terdampak |
|---|---|---:|
| R01 | Cast `user id` → BIGINT, rename `user_id` | 0 gagal |
| R02 | Map `converted` True/False → BOOLEAN | 0 tidak terpetakan |
| R03 | Cast `total ads` → INTEGER | 0 gagal |
| R04 | Cast `most ads hour` → INTEGER | 0 gagal |
| R05 | Rename kolom ke snake_case (`column0` → `row_index`, dst.) | 588.101 (semua baris; hanya nama kolom) |
| R06 | Eksklusi: `user_id` kosong | 0 |
| R07 | Eksklusi: `test_group` bukan `ad`/`psa` | 0 |
| R08 | Eksklusi: `converted` tidak valid | 0 |
| R09 | D3(b): `user_id` di >1 grup | 0 |
| R10 | D3(a)(c): baris duplikat tidak terpilih | 0 |
| R11 | Tanpa paparan valid (tidak dibuang dari Primary KPI) | 0 |
| R12 | Tanpa hari/jam valid (tidak dibuang dari Primary KPI) | 0 |

### Bucket paparan (D4) dan blok waktu

Batas kuantil `total_ads` populasi gabungan (dihitung tanpa menyentuh `converted`): **P50 = 13, P75 = 27, P90 = 57, P99 = 202**.

| Bucket | Rentang `total_ads` | n `ad` | n `psa` | n total |
|---|---|---:|---:|---:|
| b1_le_p50 | 1–13 | 286.895 | 12.601 | 299.496 |
| b2_p50_p75 | 14–27 | 137.483 | 5.274 | 142.757 |
| b3_p75_p90 | 28–57 | 85.178 | 3.224 | 88.402 |
| b4_p90_p99 | 58–202 | 49.461 | 2.175 | 51.636 |
| b5_gt_p99 | 203–2.065 | 5.560 | **250** | 5.810 |
| **Total** | | 564.577 | 23.524 | 588.101 |

| Blok waktu | n `ad` | n `psa` | n total |
|---|---:|---:|---:|
| 00–05 | 19.102 | 735 | 19.837 |
| 06–11 | 136.526 | 5.727 | 142.253 |
| 12–17 | 246.925 | 10.914 | 257.839 |
| 18–23 | 162.024 | 6.148 | 168.172 |
| **Total** | 564.577 | 23.524 | 588.101 |

Jumlah per bucket dan per blok waktu merekonsiliasi ke ukuran grup (564.577 dan 23.524).

**Catatan:** bucket `b5_gt_p99` di grup `psa` hanya **250 user**, di bawah ambang D5 (< 500 user). Sel ini akan ditandai `is_small_segment` terlepas dari jumlah konversinya. Hal ini terjadi secara struktural: 4% (porsi `psa`) × 1% (porsi di atas P99) × 588.101 ≈ 235 user.

## Output

- Tabel `stg_marketing_ab` dan `marketing_ab_clean` di `ab_testing.duckdb`.
- `data/processed/04_marketing_ab_clean.parquet` (588.101 baris; tidak di-commit karena diabaikan `.gitignore`, dapat dibuat ulang dengan menjalankan skrip).
- `sql/04_data_cleaning.sql`, `docs/04_data_cleaning.md`, `docs/assumptions.md`.

## Assumptions

- Detail setiap aturan dan alasannya dicatat di `docs/assumptions.md`.
- `test_group` tidak di-trim atau diubah huruf; profiling menunjukkan hanya nilai `ad` dan `psa` yang persis.
- `is_valid_user` = `user_id` terisi, grup ∈ {`ad`, `psa`}, `converted` valid, bukan konflik grup, dan terpilih menurut D3. Validitas `total_ads`, hari, dan jam **tidak** memengaruhi `is_valid_user`.
- Batas bucket D4 dihitung di tahap ini (tanpa `converted`) agar kolom `exposure_bucket` tersedia. Angka resmi dicatat dan dikunci di Tahap 6.
- Karena tidak ada duplikat, aturan D3 tidak mengubah populasi (ditulis penuh agar tetap benar jika data berubah).

## Batasan data

- Pembersihan hanya menyentuh tipe dan struktur; kebenaran substantif nilai (mis. apakah `converted` mencerminkan konversi sesungguhnya) tidak dapat diverifikasi dari data.
- Kolom `total_ads`, `most_ads_day`, `most_ads_hour` adalah variabel post-treatment (D7).
- Randomization tidak dapat diverifikasi dan rasio desain grup tidak diketahui.
- Grup `psa` kecil (4%), sehingga sel segmen `psa` rentan jatuh di bawah ambang D5.

## Kesimpulan

Seluruh Acceptance Criteria terpenuhi: tidak ada kegagalan cast, nilai `test_group` dan `converted` identik dengan raw, dan 588.101 baris semuanya masuk Valid Analysis Population (564.577 `ad` dan 23.524 `psa`). Tidak ada baris dibuang maupun dikeluarkan. Tabel `marketing_ab_clean` dan Parquet-nya siap untuk validasi dan penguncian KPI di Tahap 6. Satu butir untuk diputuskan sebelum lock: sel `b5_gt_p99` × `psa` (250 user) yang secara struktural berada di bawah D5 (lihat `docs/assumptions.md`, bagian C).
