# 03 — Data Profiling

> Pendamping: `sql/03_data_profiling.sql` · Tahap 4 (Jalur Inti)

## Input

- Tabel `raw_marketing_ab` (588.101 baris × 7 kolom, semua `VARCHAR`) hasil Tahap 2.
- Skrip tidak membuat tabel permanen dan tidak mengubah data (hanya `TEMP VIEW`). Belum ada baris yang dihapus.

## Proses Analisis

1. Jumlah baris dan kolom.
2. Missing values per kolom (NULL dan string kosong).
3. Pemeriksaan row index (`column0`) dan format `user id`.
4. Duplikasi `user_id`, diklasifikasi menurut kategori aturan D3: (a) duplikat penuh, (b) grup sama dengan nilai berbeda, (c) `user_id` di lebih dari satu grup.
5. Nilai unik `test group`, ukuran kedua grup, dan rasio `ad : psa`.
6. Distribusi `converted` (nilai apa adanya dan pemetaan boolean).
7. Distribusi `total_ads` (min, max, rata-rata, P50/P75/P90/P95/P99, nilai nol, negatif, non-integer).
8. Kategori `most ads day` dan `most ads hour` (validasi nama hari dan bilangan bulat 0–23).
9. Ukuran sel awal hari × grup, blok waktu × grup, dan jam × grup terhadap ambang D5 (< 500 user atau < 30 konversi).
10. Ringkasan populasi awal (informatif).

## Temuan

### 1. Struktur dan kelengkapan

| Pemeriksaan | Hasil |
|---|---|
| Baris × kolom | 588.101 × 7 |
| Missing (NULL atau kosong) | **0** di semua 7 kolom |
| `column0` (row index) | 588.101 nilai unik, 0–588.100, berurutan tanpa celah, 0 gagal cast |
| `user id` | 0 missing, 0 gagal cast ke angka, rentang 900.000 – 1.654.483 |

### 2. Duplikasi `user_id`

| Pemeriksaan | Hasil |
|---|---|
| Jumlah `user_id` unik | 588.101 (= jumlah baris) |
| `user_id` yang muncul > 1 kali | **0** |
| Duplikat penuh / grup sama nilai beda / konflik grup | 0 / 0 / 0 |

Grain 1 baris = 1 user terpenuhi di data mentah. Aturan D3 **tidak berlaku** (0 duplikat).

### 3. Ukuran grup

| `test group` | n baris | n `user_id` unik | % baris |
|---|---:|---:|---:|
| `ad` | 564.577 | 564.577 | 96,0% |
| `psa` | 23.524 | 23.524 | 4,0% |

- Rasio `ad : psa` ≈ **24 : 1** (grup kontrol hanya 4% dari total).
- Hanya dua nilai grup yang muncul (`ad` dan `psa`); tidak ada variasi huruf besar/kecil atau spasi.
- Rasio desain grup tidak tersedia di dokumentasi, sehingga rasio ini hanya dilaporkan secara deskriptif (tidak dapat dinyatakan lulus atau gagal SRM).

### 4. Distribusi `converted`

| Nilai raw | Pemetaan | n baris | % |
|---|---|---:|---:|
| `False` | false | 573.258 | 97,4761% |
| `True` | true | 14.843 | 2,5239% |

Hanya dua nilai, keduanya terpetakan ke boolean tanpa sisa. Angka ini adalah proporsi gabungan kedua grup; CR per grup sengaja belum dihitung di tahap profiling.

### 5. Distribusi `total_ads`

| Cakupan | n | min | max | rata-rata | P50 | P75 | P90 | P95 | P99 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Gabungan | 588.101 | 1 | 2.065 | 24,82 | 13 | 27 | 57 | 88 | 202 |
| `ad` | 564.577 | 1 | 2.065 | 24,82 | 13 | 27 | 56 | 87 | 201 |
| `psa` | 23.524 | 1 | 907 | 24,76 | 12 | 26 | 59 | 92,85 | 206 |

- Tidak ada missing, gagal cast, nilai nol, negatif, maupun non-integer (nilai minimum = 1).
- Distribusi **sangat menjulur ke kanan**: rata-rata (24,8) hampir dua kali median (13), dan maksimum 2.065 jauh di atas P99 (202).
- Kuantil gabungan di atas bersifat **informatif**. Batas bucket resmi (D4) dihitung dan dikunci di Tahap 6.

### 6. Kategori hari dan jam

- `most ads day`: semua 7 nama hari valid, tanpa nilai lain. Terbanyak Friday (92.608; 15,75%), tersedikit Tuesday (77.479; 13,17%).
- `most ads hour`: semua nilai bilangan bulat 0–23, tanpa nilai di luar rentang. Puncak di jam 13 (47.655; 8,10%); terendah di jam 4 (722; 0,12%). Paparan terkonsentrasi pada siang hingga malam, dan sangat jarang pada dini hari (jam 3–6 masing-masing di bawah 0,5%).

### 7. Ukuran sel awal terhadap ambang D5 (< 500 user atau < 30 konversi)

**Hari × grup** (14 sel): tidak ada sel kecil.

| Grup | n terkecil (hari) | konversi terkecil (hari) |
|---|---|---|
| `ad` | 74.572 (Tuesday) | 1.679 (Saturday) |
| `psa` | 2.858 (Saturday) | 40 (Saturday) |

**Blok waktu × grup** (8 sel): 7 lolos, **1 kecil**.

| Blok | Grup | n | konversi | Kecil (D5) |
|---|---|---:|---:|---|
| 00–05 | `ad` | 19.102 | 257 | tidak |
| 00–05 | `psa` | 735 | **1** | **ya** |
| 06–11 | `ad` / `psa` | 136.526 / 5.727 | 2.889 / 72 | tidak |
| 12–17 | `ad` / `psa` | 246.925 / 10.914 | 6.832 / 220 | tidak |
| 18–23 | `ad` / `psa` | 162.024 / 6.148 | 4.445 / 127 | tidak |

**Jam × grup** (24 sel per grup):

| Grup | Jumlah sel | Sel kecil (D5) | n terkecil | Konversi terkecil |
|---|---:|---:|---:|---:|
| `ad` | 24 | 3 (jam 3, 4, 5) | 694 | 11 |
| `psa` | 24 | **17** | 23 | 0 |

Pada grup `psa`, 17 dari 24 sel jam tidak memenuhi D5.

### 8. Rekonsiliasi

| Pemeriksaan | Hasil |
|---|---|
| Jumlah n seluruh sel hari = ukuran grup | `ad` 564.577 dan `psa` 23.524 (cocok) |
| Jumlah n seluruh sel blok waktu = ukuran grup | `ad` 564.577 dan `psa` 23.524 (cocok) |
| Jumlah konversi seluruh sel hari = total konversi | 14.843 (cocok dengan bagian 4) |
| Jumlah konversi seluruh sel blok waktu = total konversi | 14.843 (cocok) |

### 9. Ringkasan populasi awal (informatif)

| Metrik | Nilai |
|---|---:|
| Raw rows | 588.101 |
| Baris tanpa `user_id` | 0 |
| Baris dengan grup tidak valid | 0 |
| Baris dengan `converted` tidak valid | 0 |
| Baris pada `user_id` duplikat / konflik grup | 0 / 0 |
| Baris tanpa paparan valid (`total_ads` null atau negatif) | 0 |
| Baris dengan hari tidak valid / jam tidak valid | 0 / 0 |
| **Baris tanpa masalah inti** | **588.101** |

## Output

- Hasil profiling dan tabel di atas.
- `docs/profiling_findings.md` (data quality issue register, implikasi untuk tahap berikutnya).
- Tidak ada tabel baru di database dan tidak ada baris yang dihapus.

## Assumptions

- Nilai `converted` `True`/`False` dipetakan ke boolean; ini satu-satunya pemetaan di tahap ini.
- Duplikasi diukur pada `user id` dengan *signature* seluruh kolom selain row index (`column0`). Karena tidak ada duplikat, pemilihan baris menurut row index terkecil (D3c) tidak perlu dipakai.
- Hari dan jam dikategorikan valid jika nama hari standar bahasa Inggris dan jam bilangan bulat 0–23.
- Ambang D5 (< 500 user atau < 30 konversi) dipakai secara indikatif untuk menilai kelayakan; penandaan resmi `is_small_segment` terjadi di tahap analisis segmen.
- Jumlah konversi per sel dilihat **hanya** untuk memeriksa ambang D5, bukan untuk menilai efek iklan.

## Batasan data

- Tidak ada anomali kualitas data pada level baris, tetapi hasil bersih ini tidak membuktikan kebenaran substantif nilai (mis. apakah `converted` mencerminkan konversi yang sebenarnya).
- Randomization tidak dapat diverifikasi dan rasio desain grup tidak diketahui; rasio 24 : 1 hanya deskriptif.
- `total_ads`, `most ads day`, dan `most ads hour` adalah variabel post-treatment (satu nilai per user).
- Nilai jam pada detail sel tampil sebagai `0.0`–`23.0` karena di-cast ke `DOUBLE` untuk validasi. Ini kosmetik; nilai raw adalah bilangan bulat.
- Tidak ada timestamp, data biaya, atau karakteristik user.

## Kesimpulan

Data mentah sangat bersih: tidak ada missing, tidak ada duplikat `user_id`, nilai `test group`, `converted`, hari, dan jam seluruhnya valid, dan `total_ads` selalu ≥ 1. Seluruh 588.101 baris lolos pemeriksaan inti, sehingga Valid Analysis Population diperkirakan sama dengan Raw Population (dikonfirmasi di Tahap 5–6).

Tantangan utamanya ada pada **desain**, bukan kualitas data: grup `psa` hanya 23.524 user (4%) dan rasio `ad : psa` ≈ 24 : 1. Akibatnya sel kecil di grup `psa` (khususnya per jam, dan blok 00–05) tidak lolos D5. Hal ini mendukung keputusan D6 (jam hanya deskriptif) dan perlu dipertimbangkan saat Tahap 6 (lihat `docs/profiling_findings.md`).
