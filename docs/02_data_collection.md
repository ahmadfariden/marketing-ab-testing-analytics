# 02 — Data Collection

> Pendamping: `sql/02_data_collection.sql` · Tahap 2 (Jalur Inti)

## Input

| Item | Nilai |
|---|---|
| Sumber | [Marketing A/B Testing — Kaggle](https://www.kaggle.com/datasets/faviovaz/marketing-ab-testing) |
| File | `data/raw/marketing_AB.csv` |
| Tanggal pengambilan | 2026-10-12 |
| Lisensi | **Belum diverifikasi** — dicek di halaman Kaggle sebelum publish (lihat Assumptions) |
| Ukuran file | 21.980.992 byte (± 21 MB) |

## Proses Analisis

1. **Verifikasi file sumber:** `read_text()` menghitung ukuran file dan jumlah baris (jumlah newline, disesuaikan jika baris terakhir tanpa newline).
2. **Ingestion:** `CREATE OR REPLACE TABLE raw_marketing_ab` dari `read_csv(..., header = true, ALL_VARCHAR = TRUE)`. Semua kolom dimuat sebagai `VARCHAR`; nama kolom tidak diubah.
3. **Struktur:** `DESCRIBE raw_marketing_ab` untuk memeriksa nama dan tipe kolom.
4. **Rekonsiliasi:** jumlah baris data di file dibandingkan dengan jumlah baris tabel.
5. **Sampel:** 5 baris pertama untuk pengecekan bentuk data.

## Temuan

**Verifikasi file**

| Metrik | Nilai |
|---|---|
| Total baris di file (termasuk header) | 588.102 |
| Baris data di file | 588.101 |

**Rekonsiliasi file → tabel**

| Metrik | Nilai |
|---|---|
| Baris data di file | 588.101 |
| Baris di `raw_marketing_ab` | 588.101 |
| Jumlah kolom | 7 |
| Status | **MATCH** |

**Struktur kolom** (semua `VARCHAR`, nullable):

| # | Nama kolom di raw |
|---|---|
| 1 | `column0` |
| 2 | `user id` |
| 3 | `test group` |
| 4 | `converted` |
| 5 | `total ads` |
| 6 | `most ads day` |
| 7 | `most ads hour` |

**Catatan dari 5 baris sampel**

- Kolom pertama bernilai 0, 1, 2, 3, 4 (berurutan). Header kolom ini kosong di file, lalu diberi nama `column0` oleh DuckDB. Ini **row index** bawaan CSV, bukan `user_id`.
- Kolom `converted` pada sampel berisi teks `False` (bukan 0/1). Pemetaan ke tipe boolean dan validasi seluruh nilainya dikerjakan di Tahap 5.
- Semua baris di sampel berasal dari `test group = ad`. Sampel hanya 5 baris pertama, jadi **belum dapat disimpulkan** apa pun tentang komposisi grup (diverifikasi di Tahap 4).

## Output

- Tabel `raw_marketing_ab` di `ab_testing.duckdb` (588.101 baris × 7 kolom, semua `VARCHAR`).
- `sql/02_data_collection.sql`
- `docs/02_data_collection.md` (dokumen ini)
- `docs/data_dictionary_raw.md`

## Assumptions

- Baris pertama file adalah header, dan satu baris file = satu baris data (tidak ada nilai ber-newline di dalam tanda kutip). Asumsi ini didukung oleh rekonsiliasi MATCH.
- Kolom tanpa nama di file adalah row index, bukan identifier pengguna. `user id` dianggap kandidat identifier, **keunikannya belum diuji** (Tahap 4).
- Arti `ad` dan `psa` mengikuti dokumentasi dataset di Kaggle (diverifikasi ulang di Tahap 3).
- Lisensi dataset **belum dicek**. Wajib diverifikasi dan dicantumkan di README sebelum publish.

## Batasan data

- Semua kolom masih `VARCHAR`, belum ada validasi nilai, tipe, duplikasi, maupun null.
- Rekonsiliasi hanya membuktikan jumlah baris file = jumlah baris tabel, bukan kebenaran isi.
- Tidak ada metadata randomization, timestamp, data biaya, maupun karakteristik user (lihat Data Feasibility Check di Tahap 3).

## Kesimpulan

Ingestion berhasil dan lengkap: 588.101 baris dan 7 kolom masuk ke `raw_marketing_ab` tanpa selisih terhadap file sumber. Data mentah tersimpan apa adanya (semua `VARCHAR`) sebagai dasar untuk profiling di Tahap 4 dan cleaning di Tahap 5. Satu hal yang masih terbuka: verifikasi lisensi dataset.
