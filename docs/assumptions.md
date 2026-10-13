# Assumptions & Cleaning Rules

> Dokumen hidup: diperbarui setiap tahap. Versi ini mencakup Tahap 2–6.
> Keputusan statistik formal (D1–D9) dikunci di Tahap 6 dan dicatat di `docs/methodology.md`.

## A. Asumsi sumber data dan desain eksperimen

| ID | Asumsi | Dasar | Tahap |
|---|---|---|---|
| A-01 | `ad` = kelompok treatment (menerima iklan); `psa` = kelompok kontrol (menerima Public Service Announcement) | Dokumentasi dataset di Kaggle | 2–3 |
| A-02 | Unit analisis = user; 1 `user_id` = 1 user | Profiling: 588.101 `user_id` unik dari 588.101 baris | 4 |
| A-03 | Kolom pertama CSV (tanpa nama di header) adalah row index, **bukan** `user_id` | Nilai 0–588.100 berurutan tanpa celah | 2, 4 |
| A-04 | Pembagian grup diasumsikan sesuai dokumentasi; randomization **tidak dapat diverifikasi** dan rasio desain grup tidak tersedia | Tidak ada metadata randomization | 3, 4 |
| A-05 | Satu baris file = satu baris data (tidak ada nilai ber-newline di dalam tanda kutip) | Rekonsiliasi jumlah baris file = tabel (MATCH) | 2 |
| A-06 | Lisensi dataset **belum diverifikasi** | Harus dicek di halaman Kaggle sebelum publish | 2 |

## B. Aturan cleaning (Tahap 5)

Prinsip: **flag, jangan hapus**. Keputusan tidak boleh melihat nilai `converted`.

| Aturan | Perlakuan | Alasan | Baris terdampak |
|---|---|---|---:|
| R01 | `user id` → `user_id` BIGINT (`TRY_CAST`) | Identifier berupa angka (rentang 900.000–1.654.483) | 0 gagal |
| R02 | `converted` `True`/`False` (teks) → BOOLEAN | Hanya dua nilai di data (profiling); outcome biner | 0 tidak terpetakan |
| R03 | `total ads` → `total_ads` INTEGER | Semua nilai bilangan bulat ≥ 1 (profiling) | 0 gagal |
| R04 | `most ads hour` → `most_ads_hour` INTEGER | Semua nilai bilangan bulat 0–23 (profiling) | 0 gagal |
| R05 | Rename ke snake_case: `column0` → `row_index`, `test group` → `test_group`, `most ads day` → `most_ads_day` | Konvensi penamaan proyek | semua baris (nama kolom saja) |
| R06 | `user_id` kosong → `exclusion_reason = missing_user_id` | Unit analisis tidak dapat diidentifikasi | 0 |
| R07 | `test_group` bukan `ad`/`psa` → `invalid_test_group` | Tidak dapat dialokasikan ke treatment atau control | 0 |
| R08 | `converted` tidak valid → `invalid_converted` | Outcome tidak dapat dihitung | 0 |
| R09 | **D3(b):** `user_id` di >1 grup → eksklusi semua barisnya (`d3b_group_conflict`) | Alokasi grup ambigu; aturan outcome-blind | 0 |
| R10 | **D3(a)(c):** `user_id` berulang dengan grup sama → pertahankan baris `row_index` terkecil (`d3ac_duplicate_row_not_selected` untuk sisanya) | Deterministik dan tidak melihat `converted` | 0 |
| R11 | `total_ads` NULL atau negatif → `has_valid_exposure = FALSE` | Hanya memengaruhi Exposure Population; **tidak** membuang user dari Primary KPI | 0 |
| R12 | Hari atau jam tidak valid → `has_valid_time = FALSE` | Hanya memengaruhi Time Population; **tidak** membuang user dari Primary KPI | 0 |

**Definisi flag utama**

```
is_treatment       = test_group = 'ad'
is_control         = test_group = 'psa'
is_converted       = converted = TRUE
is_valid_user      = exclusion_reason IS NULL
                     (user_id terisi, grup ∈ {ad, psa}, converted valid,
                      bukan konflik grup, terpilih menurut D3)
has_valid_exposure = total_ads IS NOT NULL AND total_ads >= 0
has_valid_time     = hari valid AND jam bilangan bulat 0–23
```

**Tidak dilakukan (disengaja)**
- Tidak ada baris dihapus, tidak ada imputasi, tidak ada winsorizing atau pembuangan outlier pada `total_ads` (maks 2.065 vs P99 202). Ekor panjang ditangani lewat bucket berbasis kuantil (D4), bukan dengan membuang data.
- Tidak ada perubahan nilai `test_group` dan `converted` (diverifikasi per baris terhadap raw: 0 selisih).

## C. Asumsi analitik dan butir keputusan (seluruhnya diselesaikan di Tahap 6, sebelum `kpi-lock`)

| ID | Butir | Sumber | Status |
|---|---|---|---|
| C-01 | **Bucket paparan (D4):** batas P50 = 13, P75 = 27, P90 = 57, P99 = 202 dihitung dari populasi gabungan tanpa `converted`; angka resmi dicatat dan dikunci di Tahap 6 | Tahap 5 (A7a) | Terkunci di Tahap 6 (D4); diverifikasi independen dari raw (L03) |
| C-02 | **Sel kecil struktural:** bucket `b5_gt_p99` × `psa` = 250 user (< 500, D5). Terjadi karena 4% × 1% × 588.101 ≈ 235. Opsi: (1) pertahankan lima bucket sesuai D4 dan tandai sel ini `is_small_segment` sesuai D5, atau (2) gabungkan b4 dan b5 menjadi satu bucket di atas P90 sebelum lock. **Usulan:** opsi (1), karena D4 dan D5 sudah menjawab situasi ini tanpa perlu mengubah definisi | Tahap 5 (A7b) | Diputuskan: opsi (1) = K1 di `methodology.md` |
| C-03 | **Family Holm blok waktu (D5 vs D6):** blok 00–05 × `psa` hanya 1 konversi (kena D5). Putuskan apakah family Holm tetap 4 atau menjadi 3. **Usulan:** tetap 4 (lebih konservatif, konsisten dengan teks D6) | Tahap 4 (OBS-04) | Diputuskan: family tetap 4 = K2 di `methodology.md` |
| C-04 | **CI deskriptif per jam:** sel `psa` dengan konversi sangat sedikit atau nol tidak cocok untuk CI Wald. **Usulan:** interval Wilson untuk analisis jam di Tahap 11 | Tahap 4 (OBS-03b) | Diputuskan: interval Wilson = K3 di `methodology.md` |
| C-05 | Ambang D5 (< 500 user atau < 30 konversi) dan ambang praktis D8 (0,5 poin persentase) adalah **asumsi**, bukan fakta bisnis | Roadmap | Terkunci di Tahap 6 (D5, D8) |
| C-06 | D3 dicatat **tidak berlaku** di `methodology.md` (0 duplikat); sensitivitas "eksklusi duplikat" di Tahap 8 akan identik dengan hasil utama | Tahap 4 (DQ-04) | Dicatat di Tahap 6: D3 tidak berlaku (L01, L02 PASS) |

## D. Keterbatasan yang terdokumentasi sejauh ini

- Tidak ada data biaya atau nilai transaksi (tanpa ROI/ROAS/profit).
- Randomization tidak dapat diverifikasi; rasio desain grup tidak tersedia, sehingga SRM hanya dilaporkan secara deskriptif (rasio `ad : psa` ≈ 24 : 1).
- Grup `psa` kecil (23.524; 4%) → MDE grup kecil, dan banyak sel segmen `psa` di bawah D5.
- `total_ads`, `most_ads_day`, `most_ads_hour` adalah variabel post-treatment (D7); tidak diklaim kausal.
- Tidak ada timestamp assignment atau konversi (tidak ada time-to-convert, novelty effect, atau tren kalender).
- Satu eksperimen, satu periode; generalisasi terbatas.

## E. Riwayat perubahan dokumen

| Tahap | Perubahan |
|---|---|
| 2 | Asumsi sumber data (A-01, A-03, A-05, A-06) |
| 3 | Asumsi desain eksperimen (A-01, A-02, A-04) |
| 4 | Verifikasi A-02, A-03; butir terbuka C-03, C-04 |
| 5 | Aturan cleaning R01–R12; butir C-01, C-02, C-05, C-06 |
| 6 | Semua butir C-01 sampai C-06 diselesaikan dan dikunci; keputusan dan klarifikasi K1–K5 dicatat di `docs/methodology.md` |
