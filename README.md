# Marketing Campaign A/B Testing & Conversion Analysis

> 🚧 **Status:** work in progress — skeleton (Tahap 0). Belum ada analisis yang dieksekusi.

## Ringkasan

Proyek portfolio Data Analyst untuk mengevaluasi apakah kampanye iklan digital (`ad`) menghasilkan conversion rate lebih tinggi dibandingkan kelompok kontrol PSA (`psa`).

**Primary business question:** Apakah kelompok pengguna yang menerima iklan memiliki conversion rate yang lebih tinggi dibandingkan kelompok kontrol PSA?

**Tools:** DuckDB, SQL, Python (SciPy/statsmodels, pandas), Power BI, Git & GitHub

## Dataset

- Sumber: [Marketing A/B Testing — Kaggle](https://www.kaggle.com/datasets/faviovaz/marketing-ab-testing)
- Tanggal pengambilan: _TODO (isi di Tahap 2)_
- Lisensi: _TODO (verifikasi di Kaggle sebelum publish)_
- Atribusi: _TODO_

### Cara download

1. Download dataset dari link Kaggle di atas.
2. Taruh file CSV (`marketing_AB.csv`) di `data/raw/`.
3. File raw bersifat read-only dan tidak boleh ditimpa proses apa pun.

> Keputusan apakah CSV raw di-commit ke repo: _TODO (catat di sini; default `.gitignore` mengabaikan `data/raw/*.csv`)_.

## Struktur Folder

```
.
├── data/
│   ├── raw/            # file mentah (read-only)
│   ├── processed/      # layer hasil cleaning / parquet
│   └── data_mart/      # data mart untuk dashboard
├── sql/                # 02_*.sql s.d. 13_*.sql (flat)
├── docs/               # dokumentasi pendamping tiap tahap
├── notebooks/          # uji statistik & KPI cross-check
├── dashboard/          # ab_testing.pbix
└── screenshots/        # screenshot tiap halaman dashboard
```

## Cara Reproduce

_TODO — diisi di Tahap 17 (requirements, urutan `.read` file SQL, notebook, dashboard)._

```powershell
.\duckdb.exe ab_testing.duckdb -c ".read sql/02_data_collection.sql"
```

## Catatan

- Nomor tahap (0–18) dan nomor file `.sql` (02–13) memiliki offset berbeda; lihat Traceability Matrix di roadmap.
- Temuan (Headline Findings) baru ditambahkan setelah profiling dieksekusi, berlabel *preliminary* sampai diverifikasi di Tahap 18.
