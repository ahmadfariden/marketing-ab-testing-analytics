# Data Dictionary — Raw (`raw_marketing_ab`)

> Dibuat di Tahap 2. Mendeskripsikan tabel **mentah** apa adanya. Kamus data versi cleaned (`docs/data_dictionary.md`) dibuat setelah cleaning di Tahap 5.

**Tabel:** `raw_marketing_ab` · **Baris:** 588.101 · **Kolom:** 7 · **Tipe semua kolom:** `VARCHAR`

**Sumber:** [Marketing A/B Testing — Kaggle](https://www.kaggle.com/datasets/faviovaz/marketing-ab-testing) (`marketing_AB.csv`, diambil 2026-10-12)

## Kolom

| # | Kolom di raw | Tipe raw | Arti (menurut dokumentasi dataset) | Contoh nilai (5 baris pertama) | Rencana nama clean | Catatan |
|---|---|---|---|---|---|---|
| 1 | `column0` | VARCHAR | Row index bawaan CSV (header kosong di file; dinamai `column0` oleh DuckDB) | 0, 1, 2, 3, 4 | `row_index` | **Bukan** `user_id`; tidak dipakai sebagai identifier analisis |
| 2 | `user id` | VARCHAR | Identifier pengguna | 1069124, 1119715, 1144181, 1435133, 1015700 | `user_id` | Kandidat unit analisis; **keunikan belum diuji** (Tahap 4) |
| 3 | `test group` | VARCHAR | Kelompok eksperimen: `ad` (melihat iklan) atau `psa` (melihat PSA / kontrol) | `ad` | `test_group` | Pada sampel hanya muncul `ad`; nilai lain dan ukuran grup diverifikasi di Tahap 4 |
| 4 | `converted` | VARCHAR | Status konversi pengguna (outcome biner) | `False` | `converted` | Berupa teks (`False`), bukan 0/1; pemetaan ke boolean dan validasi nilai di Tahap 5 |
| 5 | `total ads` | VARCHAR | Jumlah iklan yang dilihat pengguna | 130, 93, 21, 355, 276 | `total_ads` | Variabel **post-treatment**; di kelompok `psa` berarti paparan PSA; rentang nilai diprofiling di Tahap 4 |
| 6 | `most ads day` | VARCHAR | Hari dengan paparan iklan terbanyak | Monday, Tuesday, Friday | `most_ads_day` | Variabel **post-treatment**; satu nilai per user, bukan log per paparan |
| 7 | `most ads hour` | VARCHAR | Jam dengan paparan iklan terbanyak | 20, 22, 18, 10, 14 | `most_ads_hour` | Variabel **post-treatment**; diduga jam 0–23, diverifikasi di Tahap 4 |

## Keterangan

- Kolom **Arti** diambil dari dokumentasi dataset di Kaggle dan **belum diverifikasi terhadap data**. Verifikasi dilakukan di Tahap 3 (business understanding) dan Tahap 4 (profiling).
- Kolom **Contoh nilai** hanya berasal dari 5 baris pertama, **bukan** daftar lengkap nilai. Distribusi dan nilai unik diprofiling di Tahap 4.
- Kolom **Rencana nama clean** bersifat usulan mengikuti konvensi snake_case (Tahap 1). Keputusan final dan tipe data target dicatat di `docs/assumptions.md` (Tahap 5).
- Variabel post-treatment (`total ads`, `most ads day`, `most ads hour`) tidak boleh dipakai untuk klaim kausal (keputusan D7 di Tahap 6).
