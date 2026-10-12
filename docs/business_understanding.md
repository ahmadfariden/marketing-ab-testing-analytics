# Business Understanding & Experiment Design

> Tahap 3 (Jalur Inti) · Tidak ada file SQL di tahap ini.
> Dokumen ini ditulis **sebelum** ada hasil konversi yang dilihat. Hipotesis, KPI, dan pertanyaan bisnis di bawah ditetapkan di muka; penguncian formal (D1–D9) dilakukan di Tahap 6.

## 1. Business Context

Sebuah perusahaan ingin mengevaluasi apakah kampanye iklan digital lebih efektif menghasilkan konversi dibandingkan kelompok kontrol yang menerima Public Service Announcement (PSA).

Dataset ([Marketing A/B Testing — Kaggle](https://www.kaggle.com/datasets/faviovaz/marketing-ab-testing)) berisi kelompok eksperimen, status konversi, jumlah paparan iklan, hari dengan paparan terbanyak, dan jam dengan paparan terbanyak.

## 2. Desain Eksperimen

| Elemen | Definisi |
|---|---|
| Treatment group | `test_group = 'ad'` (menerima iklan) |
| Control group | `test_group = 'psa'` (menerima PSA) |
| Unit analisis | **User** (`user_id`); keunikan diverifikasi di Tahap 4 |
| Outcome | `converted` (biner) |
| Variabel paparan | `total_ads`, `most_ads_day`, `most_ads_hour` (post-treatment) |

> Arti `ad` dan `psa` mengikuti dokumentasi dataset di Kaggle. Karena dokumentasi tidak memuat metadata randomization, pembagian grup **diasumsikan** sesuai deskripsi tersebut dan tidak dapat diverifikasi langsung.

## 3. Data Feasibility Check

| Aspek | Status | Catatan |
|---|---|---|
| Identifier pengguna (`user_id`) | ✅ | Unit analisis = user; keunikan diverifikasi di Tahap 4 |
| Label kelompok (`test_group`: `ad` / `psa`) | ✅ | Arti kelompok harus sesuai dokumentasi dataset |
| Outcome biner (`converted`) | ✅ | Pada raw berupa teks (mis. `False`); validasi nilai di Tahap 5 |
| Paparan iklan (`total_ads`) | ⚠️ | Variabel **post-treatment**; kelompok PSA juga menerima paparan PSA |
| Hari / jam paparan terbanyak | ⚠️ | Post-treatment; satu nilai per user, bukan log per paparan |
| Ukuran kedua kelompok | ⚠️ | Dugaan sangat tidak seimbang (grup `ad` lebih besar), **belum diverifikasi**; dicek di Tahap 4. Grup kecil membatasi daya uji dan ukuran sel segmen |
| Timestamp assignment / konversi | ❌ | Tidak ada time-to-convert, novelty effect, atau tren kalender |
| Metadata randomization | ❌ | Tidak dapat diverifikasi langsung |
| Data biaya / nilai transaksi | ❌ | Tidak ada ROI, ROAS, revenue, profit |
| Karakteristik user (demografi, device, channel) | ❌ | Tidak ada segmentasi selain paparan, hari, jam |

**Feasibility Conclusion:** dataset mendukung perbandingan conversion rate antar grup, uji proporsi, confidence interval, dan analisis deskriptif per bucket paparan, hari, dan blok waktu. Dataset **tidak** mendukung ROI/profit, bukti kausal untuk segmen post-treatment, analisis temporal kalender, dan verifikasi randomization yang kuat.

## 4. Primary Business Question

> Apakah kelompok pengguna yang menerima iklan memiliki conversion rate yang lebih tinggi dibandingkan kelompok kontrol PSA?

## 5. Hipotesis

- $H_0$: conversion rate kelompok iklan **sama dengan** kelompok PSA.
- $H_1$: conversion rate kelompok iklan **berbeda dari** kelompok PSA.

Pengujian **dua arah**; arah hipotesis tidak ditetapkan sebelum analisis. Pilihan ini dikunci formal sebagai D1 di Tahap 6 dan tidak boleh diganti ke satu arah setelah melihat hasil.

## 6. KPI

### Primary KPI

$$
CR=\frac{\text{Jumlah pengguna yang konversi}}{\text{Jumlah pengguna valid dalam grup}}
$$

Dihitung per grup (`ad` dan `psa`) pada Valid Analysis Population (didefinisikan di Tahap 5, dikunci di Tahap 6).

### Secondary / Supporting Metrics

| Metrik | Definisi |
|---|---|
| Absolute lift | $CR_{ad} - CR_{psa}$ (dalam poin persentase) |
| Relative lift | $(CR_{ad} - CR_{psa}) / CR_{psa}$ |
| Jumlah user dan konversi per grup | Denominator dan numerator CR |
| 95% CI selisih CR | Ketidakpastian estimasi efek |
| MDE retrospektif | Efek terkecil yang dapat dideteksi desain ini (Tahap 8) |
| Distribusi paparan | `total_ads` per grup (eksploratif) |

> **Primary KPI** dan metrik inferensial (z-test, CI, MDE) bersifat *confirmatory*. Analisis berdasarkan paparan, hari, dan blok waktu bersifat *exploratory* dan dibedakan secara eksplisit di semua output.

## 7. Business Questions

**Jalur Inti**
1. Berapa CR grup `ad` dan `psa`, serta absolute dan relative lift-nya?
2. Apakah perbedaannya signifikan secara statistik, dan berapa 95% CI-nya?
3. Apakah efeknya cukup berarti secara praktis (ambang D8), dan efek sekecil apa yang sebenarnya bisa dideteksi data ini (MDE)?

**Jalur Lanjutan (eksploratif)**
1. Apakah CR berasosiasi dengan frekuensi paparan?
2. Apakah CR berbeda menurut hari dan blok waktu dengan paparan terbanyak?
3. Apakah kesimpulan utama konsisten setelah pemeriksaan Simpson's paradox?

## 8. Scope

**In scope**
- Data quality dan validasi struktur eksperimen
- KPI definition dan KPI lock
- A/B testing dan statistical inference (termasuk retrospective MDE)
- Segment analysis berdasarkan paparan, hari, dan waktu (eksploratif, Jalur Lanjutan)
- Data mart, dashboard, business insights, dan recommendations

**Out of scope**
- Machine learning dan predictive modeling
- Klaim kausalitas pada variabel post-treatment
- Revenue, profit, ROI, dan ROAS (tidak ada data biaya maupun nilai transaksi)
- Customer lifetime value dan segmentation yang membutuhkan data tambahan
- Klaim signifikansi dari banyak pengujian tanpa koreksi multiple testing
- Perencanaan ukuran sampel ke depan dan observed power (yang dipakai adalah MDE)

## 9. Asumsi Desain & Keterbatasan

- Randomization **tidak dapat diverifikasi**; rasio desain grup tidak tersedia, sehingga Sample Ratio Mismatch hanya dapat dilaporkan secara deskriptif.
- `total_ads`, `most_ads_day`, `most_ads_hour` adalah variabel post-treatment; hubungannya dengan konversi tidak diklaim kausal.
- Tidak ada timestamp assignment atau konversi; novelty effect dan tren kalender tidak dapat dianalisis.
- Tidak ada data biaya atau nilai transaksi; evaluasi terbatas pada conversion rate, bukan profitabilitas.
- Satu eksperimen dalam satu periode; generalisasi terbatas.
- Ketidakseimbangan ukuran grup (dugaan) dapat memperbesar MDE; diverifikasi di Tahap 4.

## 10. Success Criteria

- Primary KPI dan hasil uji dapat direproduksi dari SQL **dan** notebook cross-check (gate PASS).
- Seluruh KPI dapat direkonsiliasi ke raw data.
- Dashboard 5 halaman (atau 4 halaman jika Jalur Lanjutan dilewati).
- Setiap temuan mengikuti kerangka *Finding → Evidence → Implication → Recommendation → Limitation*.
- Tidak ada klaim ROI, profit, atau kausalitas di luar yang didukung desain eksperimen.

## 11. Langkah Berikutnya

| Tahap | Aktivitas |
|---|---|
| 4 | Profiling `raw_marketing_ab`: keunikan `user_id`, ukuran grup, nilai `converted`, distribusi `total_ads`, kategori hari dan jam |
| 5 | Cleaning dan flag analitik; penetapan Valid Analysis Population |
| 6 | Validasi dan **KPI Lock** (D1–D9), git tag `kpi-lock` |
