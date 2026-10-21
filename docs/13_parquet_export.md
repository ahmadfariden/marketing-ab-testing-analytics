# 13 — Parquet Export & KPI Cross-check Gate

> Pendamping: `sql/13_parquet_export.sql` · Tahap 14 (Jalur Inti, **wajib**; blocker sebelum Tahap 15)
> Gate masuk Tahap 15: `GATE = PASS`. Jika mart berubah setelah gate lolos, skrip ini dijalankan ulang.

## Input

- Empat mart dan tabel clean di `ab_testing.duckdb` (Tahap 5 dan 13), serta `mart_checks` (Tahap 13, harus `ALL PASS`).
- Nilai terkunci dan hasil uji Tahap 8 (`docs/methodology.md`).

## Proses Analisis

1. **Syarat awal (G0).** Skrip menolak berjalan jika `mart_checks` tidak `ALL PASS`; export tidak dilakukan sama sekali bila syarat ini gagal.
2. **Export.** Staging ke `data/processed/` (`04_marketing_ab_clean.parquet`) dan mart ke `data/data_mart/` (empat file), kompresi ZSTD, urutan baris deterministik.
3. **Verifikasi baca-kembali (G1).** Setiap file Parquet dibaca kembali dan dibandingkan dengan tabel sumbernya: jumlah baris, jumlah kolom, schema (nama dan tipe, dua arah), dan isi (`EXCEPT` dua arah, nol baris berbeda).
4. **KPI Cross-check Gate (G2).** KPI terkunci dan hasil uji **dihitung ulang secara independen dari file `04_marketing_ab_clean.parquet`**, lalu dibandingkan dengan nilai di **Parquet mart** (artefak yang dikonsumsi dashboard):
   - Populasi valid dihitung dari `exclusion_reason IS NULL`, grup dari `test_group`, dan konversi dari kolom `converted` (bukan flag `is_valid_user`, `is_treatment`, dan `is_converted` yang dipakai tahap sebelumnya).
   - **Z-test dihitung dua kali** dengan aljabar dan algoritma tail yang berbeda. Implementasi A: pooled $z$ dan p-value dari macro `ab_norm_sf` (deret erf dan continued fraction). Implementasi B: statistik chi-square rumus 2×2, $z = \sqrt{\chi^2}$, dan tail normal lewat integrasi numerik Simpson.
5. **Penyimpanan hasil dan hard stop (G3, G4).** Hasil gate disimpan ke `data/processed/14_kpi_crosscheck.parquet`, dibaca kembali, dan skrip berhenti dengan error jika ada verifikasi `MISMATCH` atau `GATE = FAIL` (pengganti `assert` di notebook).

**Toleransi (sama dengan roadmap, tidak diubah):** valid users dan konversi per grup persis sama; CR, absolute lift, relative lift, dan batas CI ≤ 0,001 poin persentase; p-value selisih mutlak ≤ 10⁻⁶. MDE retrospektif sengaja tidak termasuk gate (bukan KPI terkunci; dua metode sah dapat menghasilkan angka berbeda).

## Temuan

### 1. Syarat awal

`mart_checks`: 40 dari 40 PASS, export dilanjutkan. (Pada percobaan pertama, skrip berhenti di G0 karena `mart_checks` belum `ALL PASS` akibat sisa hasil Tahap 11 yang lama. Hard stop bekerja pada data asli sebelum ada file yang di-export. Setelah Tahap 11 diperbaiki dan dijalankan ulang, G0 lolos.)

### 2. Verifikasi file Parquet: 5 dari 5 MATCH

| File | Baris | Kolom | Selisih schema | Selisih isi | Ukuran | Status |
|---|---:|---:|---:|---:|---:|---|
| `data/processed/04_marketing_ab_clean.parquet` | 588.101 | 20 | 0 | 0 | 3,78 MB | MATCH |
| `data/data_mart/mart_experiment_summary.parquet` | 46 | 12 | 0 | 0 | 6,0 KB | MATCH |
| `data/data_mart/mart_exposure_frequency.parquet` | 15 | 17 | 0 | 0 | 4,0 KB | MATCH |
| `data/data_mart/mart_time_segments.parquet` | 105 | 23 | 0 | 0 | 9,6 KB | MATCH |
| `data/data_mart/mart_data_quality_summary.parquet` | 43 | 10 | 0 | 0 | 3,9 KB | MATCH |

### 3. KPI Cross-check Gate: GATE = PASS (16 dari 16 baris)

| KPI atau statistik | Nilai di Parquet mart | Hitung ulang independen | Selisih | Toleransi | Status |
|---|---:|---:|---:|---:|---|
| Valid users `ad` | 564.577 | 564.577 | 0 | 0 | PASS |
| Valid users `psa` | 23.524 | 23.524 | 0 | 0 | PASS |
| Konversi `ad` | 14.423 | 14.423 | 0 | 0 | PASS |
| Konversi `psa` | 420 | 420 | 0 | 0 | PASS |
| CR `ad` (pp) | 2,554656 | 2,554656 | 0 | 0,001 | PASS |
| CR `psa` (pp) | 1,785411 | 1,785411 | 0 | 0,001 | PASS |
| Absolute lift (pp) | 0,769245 | 0,769245 | 0 | 0,001 | PASS |
| Relative lift (%) | 43,085064 | 43,085064 | 7,1 × 10⁻¹⁵ | 0,001 | PASS |
| 95% CI batas bawah (pp) | 0,595093 | 0,595093 | 0 | 0,001 | PASS |
| 95% CI batas atas (pp) | 0,943397 | 0,943397 | 0 | 0,001 | PASS |
| $z$, implementasi A | 7,370078 | 7,370078 | 0 | 10⁻⁶ | PASS |
| $z$, implementasi B | 7,370078 | 7,370078 | 1,8 × 10⁻¹⁵ | 10⁻⁶ | PASS |
| p-value, implementasi A | 1,7052807 × 10⁻¹³ | 1,7052807 × 10⁻¹³ | 0 | 10⁻⁶ | PASS |
| p-value, implementasi B | 1,7052807 × 10⁻¹³ | 1,7052807 × 10⁻¹³ | 2,2 × 10⁻²² | 10⁻⁶ | PASS |
| p-value A vs B | 1,7052807 × 10⁻¹³ | 1,7052807 × 10⁻¹³ | 2,2 × 10⁻²² | 10⁻⁶ | PASS |
| Selisih relatif p-value A vs B (tambahan) | 0 | 1,28 × 10⁻⁹ | 1,28 × 10⁻⁹ | 10⁻⁶ | PASS |

Kedua implementasi z-test (aljabar dan algoritma tail berbeda) menghasilkan p-value yang sama sampai sekitar 9 digit signifikan (selisih relatif 1,3 × 10⁻⁹). Hasil gate tersimpan di `data/processed/14_kpi_crosscheck.parquet` (17 baris termasuk baris `GATE`; terverifikasi baca-kembali, 0 baris `FAIL`).

### 4. Hard stop

`n_parquet_mismatch = 0`, `gate = PASS`: **GATE = PASS, boleh lanjut ke Tahap 15.**

## Perubahan implementasi terhadap roadmap

Roadmap semula menjalankan gate di `notebooks/kpi_crosscheck.ipynb` dengan pandas dan `statsmodels` (kolom `value_pandas`). Karena proyek ini full DuckDB dan SQL, gate dijalankan di SQL:

| Aspek | Roadmap | Implementasi |
|---|---|---|
| Alat | notebook Python (pandas, statsmodels) | SQL DuckDB (`read_parquet`) |
| Kolom hitung ulang | `value_pandas` | `value_recomputed` |
| Jalur independen | pandas dari file Parquet | SQL dari file Parquet, dengan flag dan kolom berbeda dari tahap sebelumnya |
| z-test dua kali | manual dan `statsmodels` | pooled $z$ (macro erf dan continued fraction) dan chi-square rumus 2×2 (integrasi Simpson) |
| Tolerance dan rumus KPI | sesuai roadmap | **tidak berubah** |

Perubahan ini dicatat di Revision Log `docs/methodology.md`.

## Output

- `data/data_mart/mart_experiment_summary.parquet`, `mart_exposure_frequency.parquet`, `mart_time_segments.parquet`, `mart_data_quality_summary.parquet` (kecil; di-commit; dibaca Power BI).
- `data/processed/04_marketing_ab_clean.parquet` (3,78 MB; diabaikan `.gitignore`, dibuat ulang lewat `sql/04_data_cleaning.sql` dan `sql/13_parquet_export.sql`).
- `data/processed/14_kpi_crosscheck.parquet` (hasil gate; di-commit sesuai pengecualian `.gitignore`).
- Tabel `parquet_verification` dan `kpi_crosscheck` di `ab_testing.duckdb`; macro `ab_norm_sf_simpson`.
- `sql/13_parquet_export.sql` dan dokumen ini.

### Urutan membuat ulang seluruh pipeline (untuk README)

`sql/02` → `sql/04` → `sql/05` → `sql/06` → `sql/07` → `sql/08` → `sql/09` → `sql/10` → `sql/11` → `sql/12` → `sql/13`, semuanya lewat `.\duckdb.exe ab_testing.duckdb -c ".read sql/<file>.sql"`. (`sql/03` bersifat profiling dan tidak mengubah data.) Data mentah `marketing_AB.csv` diletakkan di `data/raw/`.

## Assumptions

- Gate memverifikasi **konsistensi artefak ekspor dengan perhitungan ulang independen** dari file yang sama, bukan kebenaran definisi KPI; definisi dijaga oleh KPI Lock (Tahap 6).
- Konstanta kuantil normal baku ($z_{0,975}$) dipakai sama pada hitung ulang CI, karena DuckDB tidak memiliki fungsi kuantil normal.
- Toleransi dan rumus tidak boleh diubah supaya lolos; jika gate gagal, penelusuran lewat Rollback Matrix.

## Batasan data

- Sumber hitung ulang dan nilai mart berasal dari satu dataset dan satu pipeline; gate mendeteksi kesalahan transformasi, ekspor, dan implementasi, bukan kesalahan pada data sumber.
- Gate hanya mencakup KPI terkunci dan hasil uji primer; analisis segmen (eksploratif) diperiksa lewat `mart_checks` dan pemeriksaan tiap tahap.

## Kesimpulan

Kelima file Parquet terbaca kembali dengan jumlah baris, schema, dan isi yang identik dengan tabel sumber. KPI terkunci dan hasil uji primer pada Parquet mart sama dengan perhitungan ulang independen dari file Parquet, dengan toleransi sesuai roadmap, dan dua implementasi z-test (aljabar dan algoritma tail berbeda) menghasilkan p-value yang sama. **GATE = PASS**: Tahap 15 (dashboard Power BI) boleh dimulai.
