# 08 — Overall Campaign Performance

> Pendamping: `sql/08_overall_campaign_performance.sql` · Tahap 9 (Jalur Inti)
> Seluruh metrik memakai definisi KPI yang terkunci (`docs/methodology.md`, tag `kpi-lock`). Estimasi efek, CI, p-value, dan MDE dibaca dari Tahap 8 (`docs/07_ab_testing.md`) dan tidak dihitung ulang dengan metode lain.

## Input

- `marketing_ab_clean` (Valid Analysis Population = 588.101 user; 564.577 `ad` dan 23.524 `psa`).
- Tabel hasil Tahap 8: `ab_primary`, `ab_mde`, `ab_d8`, `ab_chi`, `ab_fisher`, `ab_excl_test`, `ab_checks`.

## Proses Analisis

1. Performa per grup: jumlah user, konversi, CR, dan kontribusi terhadap total user dan total konversi.
2. Estimasi efek (absolute dan relative lift) berdampingan dengan 95% CI, p-value, dan MDE; posisi CI terhadap MDE dan tiga ambang D8.
3. Terjemahan ke jumlah konversi tambahan (**bersyarat** pada validitas randomization).
4. Scorecard kekuatan bukti (8 pertanyaan, mengikuti D8 dan D9) dan kesimpulan otomatis yang tidak melampaui bukti.
5. Rekonsiliasi: 13 pemeriksaan konsistensi antara hitungan dari `marketing_ab_clean` dan hasil Tahap 8.

## Temuan

### 1. Performa per grup

| Grup | n user | % user | n konversi | % konversi | CR |
|---|---:|---:|---:|---:|---:|
| `ad` | 564.577 | 96,0% | 14.423 | 97,17% | 2,5547% |
| `psa` | 23.524 | 4,0% | 420 | 2,83% | 1,7854% |
| **Total** | **588.101** | 100% | **14.843** | 100% | **2,5239%** |

Kelompok `ad` berisi 96,0% user dan menghasilkan 97,17% konversi; kelompok `psa` berisi 4,0% user dan 2,83% konversi. Persentase konversi `psa` yang lebih kecil dari persentase user-nya konsisten dengan CR `psa` yang lebih rendah.

### 2. Efek, ketidakpastian, dan kepekaan desain

| Metrik | Nilai |
|---|---|
| CR `ad` / CR `psa` | 2,5547% / 1,7854% |
| Absolute lift (`ad` − `psa`) | **0,7692 pp** |
| 95% CI selisih | 0,5951 sampai 0,9434 pp |
| Relative lift | 43,09% (95% CI 29,97% sampai 57,52%) |
| p-value dua arah | 1,705 × 10⁻¹³ |
| MDE retrospektif (power 80%) | 0,2475 pp (13,86% relatif terhadap CR `psa`) |
| Selisih teramati dibanding MDE | 3,11 kali MDE; batas bawah CI (0,5951 pp) di atas MDE |

Posisi CI terhadap ambang D8 (asumsi eksplisit): di atas ambang 0,25 pp, di atas ambang 0,5 pp, dan di bawah ambang 1,0 pp.

![Selisih CR, CI, MDE, dan ambang D8](figures/ab_01_lift_ci.png)

### 3. Konversi tambahan (bersyarat)

| Metrik | Nilai | 95% CI |
|---|---:|---|
| Konversi teramati grup `ad` | 14.423 | |
| Konversi yang diharapkan jika grup `ad` berkonversi sebesar CR `psa` | 10.080 | |
| **Konversi tambahan** (= lift × n `ad`) | **4.343** | 3.360 sampai 5.326 |
| Porsi konversi `ad` di atas laju `psa` | 30,1% | |
| User per satu konversi tambahan (= 1 / lift) | 130 | 106 sampai 168 |

> **Bersyarat.** Angka ini hanya bermakna sebagai efek iklan jika randomization valid, yang tidak dapat diverifikasi. CI di atas hanya mencerminkan ketidakpastian sampling, bukan ketidakpastian akibat desain eksperimen. Ini bukan klaim ROI atau profit.

### 4. Scorecard kekuatan bukti (D8, D9)

| No | Pertanyaan | Bukti | Penilaian |
|---:|---|---|---|
| 1 | Apakah selisih CR signifikan secara statistik? (D1, D2) | p = 1,705 × 10⁻¹³ (α = 0,05) | **Ya** |
| 2 | Apakah hasil konsisten antar metode? (D2, D3) | chi-square, Fisher exact, eksklusi duplikat vs z-test | **Ya**, kesimpulan sama |
| 3 | Apakah efek melampaui ambang practical significance 0,5 pp? (D8) | selisih 0,769 pp, 95% CI 0,595 sampai 0,943 pp | **Ya** (CI sepenuhnya di atas ambang). Ambang adalah asumsi eksplisit |
| 4 | Apakah desain cukup sensitif? (MDE vs D8) | MDE = 0,248 pp vs ambang 0,5 pp | **Ya** |
| 5 | Apakah asumsi statistik terpenuhi? | min(konversi, non-konversi) = 420, frekuensi harapan minimum = 593,7, user unik | **Ya** |
| 6 | Apakah implementasi uji lolos pemeriksaan otomatis? | 10 dari 10 PASS | **Ya** |
| 7 | Apakah randomization dapat diverifikasi? | tidak ada metadata randomization, rasio teramati ± 24 : 1 | **Tidak** |
| 8 | Apakah ada data biaya untuk menilai ROI? | tidak ada | **Tidak** |

**Kesimpulan (mengikuti D9):** bukti statistik dan praktis (ambang 0,5 pp) mendukung bahwa CR kelompok `ad` lebih tinggi daripada `psa`, dan desain cukup sensitif. Keputusan bisnis tetap bergantung pada dua hal yang tidak dapat dinilai dari data ini: validitas randomization dan data biaya.

### 5. Rekonsiliasi

13 dari 13 pemeriksaan **PASS** (ALL PASS): n dan konversi per grup, CR, absolute dan relative lift (dihitung ulang dari tabel grup), total user dan total konversi, jumlah porsi = 100%, dan konversi tambahan = konversi `ad` − (CR `psa` × n `ad`).

## Output

- Tabel `overall_group_performance`, `overall_effect`, `overall_incremental`, `overall_scorecard`, `overall_conclusion`, `overall_checks` di `ab_testing.duckdb`.
- `sql/08_overall_campaign_performance.sql` dan dokumen ini.
- Tidak ada ekspor Parquet di tahap ini; mart untuk dashboard dibuat di Tahap 13.

## Assumptions

- Ambang practical significance D8 (0,25 / 0,5 / 1,0 pp) adalah asumsi eksplisit, bukan fakta bisnis.
- "Konversi tambahan" dan "user per konversi tambahan" menafsirkan selisih CR sebagai efek penugasan grup; ini bersyarat pada randomization yang valid.
- Seluruh keputusan statistik adalah yang terkunci (D1–D9, K1–K5); tidak ada yang diubah.

## Batasan data

- Randomization tidak dapat diverifikasi dan rasio desain grup tidak diketahui (rasio teramati ± 24 : 1), sehingga SRM tidak dapat dinilai.
- Tidak ada data biaya atau nilai transaksi: tidak ada ROI, ROAS, atau profit, dan tidak ada ambang yang dapat diturunkan dari biaya.
- Satu eksperimen dalam satu periode; tidak ada timestamp assignment atau konversi, sehingga novelty effect dan durasi efek tidak dapat dinilai.
- Hasil ini pada level agregat; temuan per segmen (paparan, hari, jam) bersifat eksploratif dan merupakan bagian Jalur Lanjutan.

## Kesimpulan

Kelompok `ad` memiliki conversion rate 2,5547% dibandingkan 1,7854% pada kelompok `psa`: selisih 0,77 pp (95% CI 0,60 sampai 0,94 pp), relative lift sekitar 43%. Seluruh kriteria statistik dan practical significance (ambang 0,5 pp) terpenuhi, dan desain cukup sensitif (MDE 0,25 pp). Jika selisih ini mencerminkan efek iklan, estimasi konversi tambahan adalah sekitar 4.300 (CI 3.400 sampai 5.300), atau sekitar 130 user per satu konversi tambahan.

Yang tidak dapat disimpulkan dari data ini: apakah kampanye menguntungkan (tidak ada data biaya), dan apakah selisih ini benar-benar efek iklan (randomization tidak dapat diverifikasi). Kedua hal itu perlu dijawab dengan data tambahan sebelum keputusan investasi.
