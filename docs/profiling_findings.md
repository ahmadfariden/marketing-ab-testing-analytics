# Profiling Findings

> Ringkasan temuan Tahap 4 (`sql/03_data_profiling.sql`). Detail angka ada di `docs/03_data_profiling.md`.

## 1. Initial Population Summary

| Populasi | Cakupan | Jumlah baris |
|---|---|---:|
| Raw Population | seluruh baris `raw_marketing_ab` | 588.101 |
| Baris tanpa masalah inti | `user_id` terisi, grup ∈ {`ad`, `psa`}, `converted` valid, tidak ada `user_id` duplikat | 588.101 |
| Treatment (`ad`) | | 564.577 (96,0%) |
| Control (`psa`) | | 23.524 (4,0%) |

Ini ringkasan **informatif**. Populasi analisis final (`is_valid_user`) ditetapkan di Tahap 5 dan divalidasi serta dikunci di Tahap 6. Dari profiling, Valid Analysis Population diperkirakan sama dengan Raw Population (tidak ada baris yang perlu dikeluarkan).

## 2. Data Quality Issue Register

### 2.1 Pemeriksaan kualitas data

| ID | Pemeriksaan | Hasil | Status | Tindakan |
|---|---|---|---|---|
| DQ-01 | Missing values (7 kolom) | 0 | Tidak ditemukan | — |
| DQ-02 | Row index `column0` unik dan berurutan | Ya (0–588.100) | Tidak ditemukan | — |
| DQ-03 | `user_id` bisa di-cast ke angka | Ya, 0 gagal | Tidak ditemukan | — |
| DQ-04 | Duplikat `user_id` (penuh / nilai beda / konflik grup) | 0 / 0 / 0 | Tidak ditemukan | D3 dicatat **tidak berlaku** di Tahap 6 |
| DQ-05 | Nilai `test group` selain `ad` / `psa` | 0 | Tidak ditemukan | — |
| DQ-06 | Nilai `converted` selain True/False | 0 | Tidak ditemukan | Petakan ke boolean di Tahap 5 |
| DQ-07 | `total_ads` nol, negatif, non-integer, gagal cast | 0 | Tidak ditemukan | — |
| DQ-08 | Nama hari tidak valid | 0 | Tidak ditemukan | — |
| DQ-09 | Jam di luar bilangan bulat 0–23 | 0 | Tidak ditemukan | — |

### 2.2 Temuan karakteristik data dan desain

Bukan cacat data, tetapi memengaruhi analisis.

| ID | Temuan | Dampak | Status |
|---|---|---|---|
| OBS-01 | Grup `psa` hanya 23.524 user (4%); rasio `ad : psa` ≈ 24 : 1 | Daya uji rendah, MDE retrospektif untuk grup kecil akan lebih besar; SRM tidak dapat dinilai karena rasio desain tidak tersedia | Dicatat sebagai limitation (Tahap 6, 17) |
| OBS-02 | `total_ads` sangat menjulur ke kanan (median 13, rata-rata 24,8, P99 202, maksimum 2.065) | Rata-rata sensitif terhadap ekor panjang; bucket berbasis kuantil (D4) sesuai untuk kondisi ini | Tidak ada baris dibuang (prinsip *flag, jangan hapus*) |
| OBS-03 | Sel jam × grup `psa`: 17 dari 24 sel tidak lolos D5 (n terkecil 23, beberapa sel 0 konversi); grup `ad`: 3 dari 24 | Uji per jam tidak layak | Sudah ditangani oleh D6 (24 jam hanya deskriptif) |
| OBS-03b | Pada sel jam dengan 0 konversi, CI Wald tidak terdefinisi dengan baik (lebar nol) | CI deskriptif per jam perlu metode yang valid untuk proporsi mendekati 0 | **Terbuka** (lihat bagian 3, butir 2) |
| OBS-04 | Blok waktu 00–05 × `psa`: n = 735 tetapi hanya **1 konversi** | Sel ini ditandai `is_small_segment` menurut D5 dan tidak boleh diinterpretasikan atau diuji | **Terbuka** (lihat bagian 3, butir 1) |
| OBS-05 | Paparan sangat terkonsentrasi pada siang hingga malam; jam 3–6 masing-masing < 0,5% baris | Sel dini hari kecil di kedua grup (jam 3–5 `ad` juga tidak lolos D5) | Informasi |
| OBS-06 | Hari × grup: semua 14 sel lolos D5 (konversi `psa` terkecil = 40, hari Saturday) | Uji lift per hari (family 7, Holm) layak dilakukan, tetapi sel `psa` per hari bersifat tipis (40–79 konversi), sehingga daya uji per hari rendah | Informasi |

## 3. Implikasi untuk Tahap 5–6 (keputusan sebelum lock)

Butir berikut bergantung pada **ukuran sel** (bukan pada hasil konversi), sehingga aman diputuskan sebelum `kpi-lock`.

1. **Family Holm untuk blok waktu (D5 vs D6).** D6 menetapkan family 4 blok waktu, sedangkan D5 mengecualikan sel kecil dari uji segmen. Blok 00–05 sudah pasti kecil di grup `psa` (1 konversi). Perlu ditulis eksplisit di `docs/methodology.md`: apakah family Holm tetap berukuran 4 (blok 00–05 dilaporkan sebagai `is_small_segment` dan tidak diuji, tetapi tetap dihitung dalam family, yang lebih konservatif) atau menjadi 3. **Usulan:** tetap 4, supaya konsisten dengan teks D6 dan tidak melonggarkan koreksi.
2. **Metode CI untuk analisis deskriptif jam.** Karena banyak sel `psa` punya konversi sangat sedikit atau nol, usulkan interval **Wilson** (bukan Wald) untuk CI per jam di Tahap 11. CI selisih untuk primary test tetap mengikuti D2 (unpooled/Wald; jumlah sampelnya besar sehingga aman).
3. **D3 tidak berlaku.** Profiling menemukan 0 duplikat; tidak ada baris yang perlu dikeluarkan atau dipilih menurut row index. Sensitivitas "eksklusi duplikat" di Tahap 8 akan identik dengan hasil utama dan dilaporkan sebagai "tidak berlaku".
4. **Batas bucket D4.** Kuantil gabungan hasil profiling (P50 = 13, P75 = 27, P90 = 57, P99 = 202) bersifat informatif. Angka resmi dihitung ulang dan dicatat di Tahap 6, **sebelum** melihat konversi per bucket.
5. **Tahap 5 cleaning** praktis terbatas pada: casting tipe (`BIGINT`, boolean, `INTEGER`), standardisasi nama kolom ke snake_case, dan pembuatan flag analitik. Tidak ada baris yang dikeluarkan atas dasar data quality.

## 4. Kesimpulan

Tidak ada masalah kualitas data yang ditemukan; tidak ada baris yang perlu dikeluarkan. Risiko terbesar proyek bersifat desain (grup kontrol kecil dan rasio 24 : 1), dan sebagian sudah diantisipasi oleh roadmap (D5, D6, D9, MDE). Dua butir terbuka (OBS-03b dan OBS-04) diselesaikan di Tahap 6 sebelum `kpi-lock`.
