# Methodology — KPI Lock & Decision Log

> Dokumen ini dikunci di Tahap 6 oleh git tag `kpi-lock`. Setelah tag dibuat, perubahan definisi KPI, populasi, atau keputusan statistik **hanya** lewat Revision Log (bagian 7) dengan hash commit.
> Bukti validasi: `docs/05_data_validation.md` (18 dari 18 pemeriksaan PASS).

## 1. Ringkasan Desain

| Elemen | Definisi |
|---|---|
| Treatment | `test_group = 'ad'` (`is_treatment`) |
| Control | `test_group = 'psa'` (`is_control`) |
| Unit analisis | User (`user_id`); 1 baris = 1 user di Valid Analysis Population |
| Outcome | `converted` (biner; `is_converted`) |
| Hipotesis | $H_0$: $CR_{ad} = CR_{psa}$ · $H_1$: $CR_{ad} \neq CR_{psa}$ (dua arah) |
| Jenis analisis | Primary test = **confirmatory**; analisis paparan, hari, blok waktu, dan jam = **exploratory** |

## 2. Populasi Analisis

| Populasi | Cakupan | Flag | Jumlah | Dipakai untuk |
|---|---|---|---:|---|
| Raw Population | seluruh baris `raw_marketing_ab` | — | 588.101 | Rekonsiliasi |
| Valid Analysis Population | `is_valid_user = TRUE` | `is_valid_user` | 588.101 | Primary KPI, A/B test, lift |
| Treatment Population | valid ∩ `ad` | `is_treatment` | 564.577 | Denominator CR `ad` |
| Control Population | valid ∩ `psa` | `is_control` | 23.524 | Denominator CR `psa` |
| Exposure Population | valid ∩ `has_valid_exposure` | `has_valid_exposure` | 588.101 | Analisis bucket paparan |
| Time Population | valid ∩ `has_valid_time` | `has_valid_time` | 588.101 | Analisis hari, blok waktu, jam |

**Aturan inklusi / eksklusi (terkunci).** Sebuah baris masuk Valid Analysis Population jika:
`user_id` terisi, `test_group ∈ {ad, psa}`, `converted` valid, bukan konflik grup (D3b), dan terpilih menurut D3. Validitas `total_ads`, hari, atau jam **tidak** mengeluarkan user dari Primary KPI. Flag tidak boleh dipertukarkan; setiap query wajib menyebut flag yang dipakai.

## 3. KPI Dictionary

| KPI / metrik | Definisi | Populasi / denominator | Jenis |
|---|---|---|---|
| **Primary KPI: Conversion Rate (CR)** | $CR = \dfrac{\text{jumlah user konversi}}{\text{jumlah user valid dalam grup}}$ | Valid Analysis Population per grup | Confirmatory |
| Absolute lift | $CR_{ad} - CR_{psa}$ (poin persentase). Arah: `ad` dikurangi `psa` | — | Confirmatory |
| Relative lift | $(CR_{ad} - CR_{psa}) / CR_{psa}$ | — | Confirmatory (point estimate; lihat K5) |
| 95% CI selisih CR | Interval Wald tak-pooled untuk $CR_{ad} - CR_{psa}$ | — | Confirmatory |
| p-value | Two-proportion z-test dua arah (D1, D2) | — | Confirmatory |
| MDE retrospektif | Efek absolut terkecil yang dapat dideteksi desain ini (lihat K4) | Ukuran grup final | Confirmatory (sensitivitas desain) |
| Jumlah user dan konversi per grup | $n_{ad}, n_{psa}$ dan konversi masing-masing | Valid Analysis Population | Supporting |
| CR per bucket paparan, hari, blok waktu, jam | CR dalam segmen × grup, selalu disertai $n$ dan jumlah konversi | Exposure / Time Population | **Exploratory** |

## 4. KPI Definition Lock

Yang dikunci:

- [x] Primary KPI dan denominator
- [x] Absolute dan relative lift (arah = `ad` dikurangi `psa`)
- [x] Aturan inklusi / eksklusi dan definisi populasi (bagian 2)
- [x] Metode uji dan α (D1, D2)
- [x] Bucket paparan dan blok waktu, termasuk angka batas (D4)
- [x] Ambang minimum volume dan koreksi multiple testing (D5, D6)
- [x] Ambang practical significance dan aturan membaca hasil (D8, D9)
- [x] Spesifikasi MDE (K4)

## 5. Decision Log (D1–D9)

Seluruh keputusan adalah aturan final yang tidak bergantung pada hasil uji.

| ID | Keputusan | Alasan / dampak | Status |
|---|---|---|---|
| D1 | Uji **dua arah**, $\alpha = 0{,}05$ | Arah hipotesis tidak ditetapkan sebelum analisis; tidak boleh diganti ke satu arah setelah melihat hasil | Terkunci |
| D2 | **Primary test = two-proportion z-test** (pooled untuk statistik uji, unpooled/Wald untuk CI selisih). Sensitivitas: chi-square tanpa koreksi kontinuitas dan Fisher exact | Sampel besar, outcome biner; ketiganya dilaporkan, hasil primary tetap z-test | Terkunci |
| D3 | **Aturan duplikasi `user_id`:** (a) duplikat penuh → pertahankan 1; (b) `user_id` di grup berbeda → eksklusi semua barisnya; (c) grup sama, nilai lain beda → pertahankan `row_index` terkecil | Aturan outcome-blind. **Hasil penerapan: tidak berlaku.** Profiling menemukan 0 duplikat dan 0 konflik grup (0 baris dikeluarkan). Sensitivitas "eksklusi duplikat" di Tahap 8 identik dengan hasil utama dan dilaporkan sebagai "tidak berlaku" | Terkunci |
| D4 | **Bucket paparan:** 5 bucket dari kuantil `total_ads` populasi gabungan. **Angka batas (dihitung dari raw tanpa `converted`):** P50 = **13**, P75 = **27**, P90 = **57**, P99 = **202**. Bucket: b1 ≤ 13 · b2 14–27 · b3 28–57 · b4 58–202 · b5 > 202. **Blok waktu:** `most_ads_hour` → 00–05, 06–11, 12–17, 18–23 | Mencegah bucket dipilih agar efek terlihat; blok waktu mengatasi sel jam yang terlalu kecil di `psa`. Diverifikasi independen (L03, L04) | Terkunci |
| D5 | **Minimum volume:** sel (segmen × grup) dengan **< 500 user atau < 30 konversi** ditandai `is_small_segment`; rate-nya tidak diinterpretasikan dan tidak dimasukkan ke uji segmen | Berlaku seragam untuk bucket, hari, blok waktu, dan jam | Terkunci |
| D6 | **Multiple testing:** uji lift per segmen hanya untuk **hari (family 7)** dan **blok waktu (family 4)**, masing-masing dengan koreksi **Holm**; p-value mentah dan terkoreksi dilaporkan. **24 jam penuh = deskriptif saja** (CR per grup + CI), tanpa uji per jam. Semua analisis segmen berlabel *exploratory*. Rincian pelaksanaan: K2 dan K3 | Mengurangi beban multiple testing dan menghindari uji pada sel yang hampir pasti di bawah D5 | Terkunci |
| D7 | `total_ads`, `most_ads_day`, `most_ads_hour` = **variabel post-treatment**; hubungannya dengan konversi **tidak diklaim kausal** dan tidak dipakai sebagai kovariat penyesuai efek utama | Desain dataset | Terkunci |
| D8 | **Practical significance:** absolute lift ≥ **0,5 poin persentase** (**asumsi eksplisit**, bukan fakta bisnis). Verdict dilaporkan sebagai tabel sensitivitas pada ambang 0,25 / 0,5 / 1,0 pp dengan membandingkan batas bawah dan atas 95% CI | Tidak ada data biaya, sehingga ambang tidak dapat diturunkan dari ROI | Terkunci |
| D9 | **Membaca hasil non-signifikan:** jika p ≥ α, simpulkan "bukti tidak cukup untuk menolak $H_0$", **bukan** "tidak ada efek". Selalu dampingi dengan CI dan MDE retrospektif. **Dilarang:** *observed power* | Mencegah kesimpulan keliru dari grup kontrol yang kecil | Terkunci |

### Klarifikasi pre-lock

Penyelesaian butir terbuka dari Tahap 4–5 dan pelengkap yang tidak mengubah D1–D9. Seluruhnya diputuskan **sebelum** hasil CR dihitung, hanya berdasarkan ukuran sel dan desain.

| ID | Butir | Keputusan |
|---|---|---|
| K1 (C-02) | Sel `b5_gt_p99` × `psa` hanya 250 user (< 500) | Lima bucket **dipertahankan** sesuai D4. Sel ini ditandai `is_small_segment` oleh D5, rate-nya tidak diinterpretasikan. Tidak ada penggabungan bucket |
| K2 (C-03) | Family Holm blok waktu (D5 vs D6) | Ukuran family **tetap 4**. Blok 00–05 × `psa` (1 konversi di Tahap 4 → kena D5) dilaporkan sebagai `is_small_segment` dan **tidak diuji**; dalam perhitungan Holm blok tersebut diberi p-value = 1 (tidak pernah ditolak) sehingga koreksi tetap konservatif ($m = 4$). Berlaku serupa untuk segmen kecil lain pada family hari |
| K3 (C-04) | CI deskriptif per jam (sel `psa` dengan konversi sangat sedikit atau nol) | Interval **Wilson** untuk CR per jam dan per segmen deskriptif. CI selisih untuk primary test tetap Wald tak-pooled (D2) |
| K4 | Spesifikasi MDE retrospektif (melengkapi D9) | Pendekatan normal untuk dua proporsi independen, $\alpha = 0{,}05$ dua arah, **power 80%**, baseline $p_0$ = CR grup `psa`, ukuran grup = $n_{ad}$ dan $n_{psa}$ final. Dilaporkan dalam poin persentase dan relatif terhadap $p_0$. Implementasi di notebook (statsmodels), diverifikasi silang dengan aproksimasi $(z_{1-\alpha/2} + z_{0{,}8})\sqrt{p_0(1-p_0)(1/n_{ad} + 1/n_{psa})}$. *Observed power* tetap dilarang |
| K5 | Relative lift | Dilaporkan sebagai point estimate. Jika CI ditampilkan, memakai pendekatan log risk ratio (Katz) dan hanya deskriptif |

## 6. Reconciliation Report

| Pemeriksaan | Hasil |
|---|---|
| Raw → stg → clean | 588.101 → 588.101 → 588.101 (MATCH) |
| Raw = valid + dikeluarkan | 588.101 = 588.101 + 0 |
| Grain `user_id` unik di populasi valid | 588.101 distinct = 588.101 baris |
| Denominator `ad` / `psa` (raw = clean) | 564.577 / 23.524 (MATCH) |
| Konversi `ad` / `psa` (raw = clean) | 14.423 / 420 (MATCH) |
| `SUM(is_treatment) + SUM(is_control)` | 564.577 + 23.524 = 588.101 |
| `exposure_bucket` dan `time_block` vs hitung ulang dari raw | 0 selisih |
| Hasil gate validasi | **18/18 PASS (ALL PASS)** |

**Sample Ratio Check (deskriptif):** $n_{ad} : n_{psa}$ = 24,0 : 1 (`psa` = 4,0%). Rasio desain tidak tersedia, sehingga SRM tidak dapat dinyatakan lulus atau gagal. Dicatat sebagai limitation.

**Limitations yang terkunci bersama dokumen ini:** tidak ada data biaya (tanpa ROI/ROAS/profit); randomization tidak dapat diverifikasi; grup `psa` kecil (MDE lebih besar, banyak sel segmen `psa` di bawah D5); variabel paparan, hari, dan jam adalah post-treatment; tidak ada timestamp assignment atau konversi; satu eksperimen dalam satu periode.

## 7. Revision Log

Diisi jika definisi KPI, populasi, atau keputusan statistik berubah setelah git tag `kpi-lock`.

| Tanggal | Commit hash | Definisi yang berubah | Alasan | Ditemukan di tahap mana |
|---|---|---|---|---|
| — | — | — | — | — |

## 8. Cara Memverifikasi Lock

```powershell
git show kpi-lock --stat
git diff kpi-lock HEAD -- docs/methodology.md
```

Perintah kedua menampilkan perubahan pada dokumen ini sejak lock; setiap perbedaan harus memiliki entri Revision Log dengan hash commit-nya.
