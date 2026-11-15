# TAUT – Salasilah Keluarga (PWA)

Berjauhan di bumi, Bersua di bawah langit.

## Isi folder
| Fail | Fungsi |
|---|---|
| `index.html` | Seluruh app (log masuk, salasilah, Memories, Admin Panel). Sudah diisi URL dan publishable key Supabase. |
| `manifest.webmanifest`, `sw.js` | Menjadikannya app boleh dipasang dan terbuka luar talian |
| `assets/logo.svg` | **Satu-satunya fail logo.** Tukar ini sahaja |
| `icons/` | Semua ikon (dijana daripada logo) |
| `make-icons.py`, `.github/workflows/icons.yml` | Menjana semula ikon daripada logo |
| `supabase/taut-schema.sql` | Jadual, peraturan akses dan storan gambar |

## 1. Supabase (sekali sahaja)
1. **SQL Editor** → tampal dan jalankan `supabase/taut-schema.sql`.
2. **Authentication → Providers → Email**: hidupkan **Confirm email**.
3. **Authentication → URL Configuration**: letak alamat GitHub Pages anda (cth `https://NAMA.github.io/REPO/`) sebagai **Site URL** dan tambah ia dalam **Redirect URLs**.
4. **Authentication → Users → Add user** (tanda *Auto Confirm User*) untuk akaun anda, kemudian di SQL Editor:
   `select public.bootstrap_family('emel-anda@contoh.com', 'Keluarga Saya');`

## 2. GitHub Pages
Muat naik **semua** isi folder ini (termasuk `.github`) ke repo, kemudian **Settings → Pages → Deploy from branch → main / (root)**.

## 3. Pasang pada telefon
- Android (Chrome): menu app → **Pasang app**, atau menu pelayar → *Install app*.
- iPhone (Safari): Kongsi → **Add to Home Screen**.

## Tukar logo
1. Ganti `assets/logo.svg` (atau letak `assets/logo.png` 1024×1024) pada GitHub.
2. GitHub Actions menjana semula semua ikon secara automatik (tab *Actions* → "Update icons"). Atau jalankan sendiri: `pip install pillow cairosvg && python make-icons.py`.
3. Warna latar ikon boleh ditukar pada baris `BG` dalam `make-icons.py`.
4. Ikon pada skrin utama telefon yang sudah dipasang tidak berubah sendiri. Buang dan pasang semula app itu.

## Kemas kini app
Pelayar mengambil `index.html` baharu setiap kali dalam talian. Untuk memaksa semua peranti membuang cache lama, naikkan nombor `V = "taut-v1"` dalam `sw.js`.

## Keselamatan
- `index.html` hanya mengandungi *publishable key* yang memang selamat didedahkan. Jangan sekali-kali letak *secret / service_role key* dalam repo.
- Akses dikawal oleh peraturan dalam pangkalan data (lihat `taut-schema.sql`), bukan oleh app.
