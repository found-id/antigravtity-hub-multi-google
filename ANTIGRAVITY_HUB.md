# Antigravity Hub — Dokumentasi Sistem, Arsitektur & Aturan

Dokumentasi lengkap untuk **Antigravity Hub** (`D:\Device\Apps\Antigravity Multi-Profile`), pengelola multi-akun / multi-profil terisolasi untuk **Antigravity IDE** di Windows berbasis **PowerShell + WPF + Native C# Win32**.

---

## 1. Ringkasan Sistem

Antigravity Hub memungkinkan beberapa akun Google/Antigravity berjalan secara bersamaan dan terisolasi penuh pada satu mesin Windows dengan memanfaatkan:

- **Isolasi Sesi User Windows Lokal** (`runas /savecred` + layanan `seclogon`): setiap akun sekunder memiliki `APPDATA`, sesi login, dan data Antigravity IDE terpisah (`C:\Users\<User>\AppData\Roaming\Antigravity IDE`).
- **Isolasi Browser OAuth & Web**: setiap akun memiliki `--user-data-dir` terpisah (`ChromeData\<User>`, `BraveData\<User>`, `EdgeData\<User>`) dan jembatan URL (`open-url.cmd` -> `pending_urls.txt` -> Host Hub) agar link OAuth dari akun sekunder terbuka di browser terisolasi yang tepat.
- **Penanda Judul Window Otomatis**: memodifikasi `window.title` pada `settings.json` milik setiap akun, termasuk opsi menyembunyikan nama file editor aktif.
- **Monitoring Resource Non-Blocking**: modul native C# pre-compiled (`AgyNative.v2.dll`) memantau jumlah window aktif, RAM, CPU, dan ukuran storage di background thread tanpa membekukan UI.

---

## 2. Struktur File & Direktori

| File / Folder | Peran & Fungsi |
| :--- | :--- |
| `AntigravityHub.exe` | Launcher utama aplikasi Antigravity Hub. |
| `Launch Profiles.bat` | Entry point alternatif yang menjalankan `run-hidden.vbs` tanpa jendela konsol. |
| `run-hidden.vbs` | Menjalankan `AntigravityProfileManager.ps1` secara tersembunyi (`WindowStyle Hidden`). |
| `AntigravityProfileManager.ps1` | Core logic aplikasi: UI WPF, manajemen profil, edit inline, pengaturan, URL bridge, dan pemuatan `AgyNative.v2.dll`. |
| `MainWindow.xaml` | Definisi antarmuka WPF (tema dark monochrome, global stats bar, panel pengaturan collapsible, loading overlay, daftar kartu profil, bar tambah akun). |
| `AgyNative.v2.dll` | Assembly C# hasil pre-compile berisi kelas `AgyWin32` & `AgyBgMonitor` (otomatis dibuat ulang jika hilang). |
| `launch-antigravity.cmd` | Launcher sesi akun sekunder: mendaftarkan handler protokol `http`/`https` ke `open-url.cmd`, menjalankan `apply-window-tag.ps1`, lalu membuka `Antigravity IDE.exe`. |
| `apply-window-tag.ps1` | Script per-user saat akun sekunder diluncurkan: membaca `tags\<USERNAME>.txt` dan `hub_settings.json` lalu menulis `window.title` ke `%APPDATA%\Antigravity IDE\User\settings.json`. |
| `open-url.cmd` | Handler protokol `http`/`https` untuk akun sekunder; menulis `USERNAME|URL` ke `pending_urls.txt` secara aman (termasuk karakter `&` dan `=`). |
| `Setup-MultiUser.ps1` | Script elevated (UAC Admin) untuk mengaktifkan layanan `seclogon`, membuat akun Windows lokal baru, dan mengatur izin ACL (`icacls`) folder aplikasi untuk grup `Users`. |
| `savecred-helper.vbs` | Helper otomatis menyimpan kredensial `runas /savecred` akun lokal agar peluncuran berikutnya tanpa prompt password. |
| `profiles.json` | Daftar profil terdaftar, urutan, akun Windows (`BoxName`), dan catatan/tag (`Note`). |
| `hub_settings.json` | Konfigurasi global Hub (`TitleFormat`, `HideActiveEditor`, `BrowserMode`). |
| `ignored_users.json` | Daftar akun Windows lokal yang dihapus dari daftar Hub agar tidak muncul kembali saat sync otomatis. |
| `tags\<User>.txt` | Cache teks tag window per-user yang dibaca oleh `apply-window-tag.ps1`. |
| `ChromeData\`, `BraveData\`, `EdgeData\` | Direktori profil browser terisolasi per-user (`--user-data-dir`). |
| `app.ico`, `app.png` | Ikon aplikasi untuk taskbar (`AppUserModelID: Antigravity.Hub.MultiProfile`) dan header UI. |

---

## 3. Arsitektur & Alur Kerja

### 3.1 Startup Cepat & Loading Stabil
1. `AntigravityProfileManager.ps1` memuat `AgyNative.v2.dll` langsung dari disk (~50–70 ms, tanpa spawn `csc.exe`). Jika DLL belum ada, script mengompilasi `$NativeSource` satu kali ke `AgyNative.v2.dll`.
2. `SetCurrentProcessExplicitAppUserModelID` dipanggil sebelum pembuatan window agar taskbar Windows 11 memakai `app.ico`.
3. XAML dimuat dan jendela langsung ditampilkan dengan **`LoadingOverlay`** aktif (progress bar indeterminate + status *"Memuat profil & metrik..."*).
4. Pada event `ContentRendered`:
   - `AgyBgMonitor.Start()` memulai 2 background thread:
     - **Metrics Thread** (`BelowNormal`): memanggil `WTSEnumerateProcessesW` (pengganti WMI, ~15–20 ms), membaca RAM/CPU dari `Process.GetProcessesByName("Antigravity IDE")` (dengan `Dispose()` handle), dan menghitung window visible via `EnumWindows`.
     - **Storage Thread** (`Lowest`): menghitung ukuran direktori instalasi, `AppData\Roaming\Antigravity IDE`, dan data browser terisolasi menggunakan `Directory.EnumerateFiles` setiap 60 detik.
   - `DispatcherTimer` berjalan cepat (`120 ms`) sampai `AgyBgMonitor.HasMetrics == true`, lalu merender kartu profil, menyembunyikan `LoadingOverlay`, menjalankan `Sync-WindowTags`, dan menurunkan interval timer ke `1500 ms`.

### 3.2 Optimasi Performa & Efisiensi Resource
- **Zero UI-Thread Blocking**: Tidak ada `Get-ChildItem -Recurse`, `Get-CimInstance` (WMI), `Get-Process`, ataupun `Get-LocalUser` di timer UI thread.
- **In-Place Metric Updates**: `Render-Profiles` memisahkan *structural signature* (daftar profil, urutan, nama, catatan, status aktif/idle, pengaturan) dari metrik live. Pada tick normal, hanya `.Text` pada `TextBlock` yang diperbarui lewat `$script:CardUiRefs` tanpa `Children.Clear()`.
- **Version Gating**: `AgyBgMonitor.MetricsVersion` dan `StorageVersion` dicek di awal `Render-Profiles`; jika tidak berubah, tick langsung skip.
- **Minimize Throttling**: Event `StateChanged` memanggil `AgyBgMonitor.SetPaused($true)` saat window di-minimize (interval sampling melambat ke 5 detik dan render UI berhenti), lalu langsung aktif kembali saat window dibuka.
- **Frozen Brush Cache & Tanpa Blur Shader**: Seluruh `SolidColorBrush` di-cache dan di-`Freeze()` via `Get-FrozenBrush`; `DropShadowEffect` dihapus dan diganti border 1px (`#272734`) agar hemat GPU/CPU pada window `AllowsTransparency="True"`.
- **Clean Shutdown**: Event `Closed` menghentikan `DispatcherTimer` dan memanggil `AgyBgMonitor.Stop()`.

### 3.3 Jembatan URL OAuth (Secondary User -> Host Browser)
1. Akun sekunder mengklik link login OAuth di Antigravity IDE.
2. Protokol `http`/`https` HKCU akun sekunder memanggil `open-url.cmd "<URL>"`.
3. `open-url.cmd` menambahkan baris `<USERNAME>|<URL>` ke `pending_urls.txt`.
4. `DispatcherTimer` di Host Hub mendeteksi `pending_urls.txt`, menghapusnya, lalu membuka `<URL>` menggunakan `Open-ProfileBrowser` dengan `--user-data-dir` milik `<USERNAME>` sesuai `BrowserMode`.

---

## 4. Skema Konfigurasi JSON

### `hub_settings.json`
```json
{
    "TitleFormat": "paren",
    "HideActiveEditor": false,
    "BrowserMode": "chrome"
}
```
- `TitleFormat`: `"u_name"` (`[U1: Host]`) | `"u_only"` (`[U1]`) | `"paren"` (`(1)`) | `"bracket"` (`[1]`) | `"none"` (Tanpa Tag).
- `HideActiveEditor`:
  - `false` -> `${dirty}${activeEditorShort}${separator}${rootName}${separator}${appName}` (contoh: `(1) • footer.php - public_html - Antigravity IDE`).
  - `true` -> `${rootName}${separator}${appName}` (contoh: `(1) public_html - Antigravity IDE`).
- `BrowserMode`: `"chrome"` | `"brave"` | `"edge"` | `"host"`.

### `profiles.json`
```json
[
    {
        "Id": "default",
        "Name": "Akun Google 1 (Utama)",
        "IsDefault": true,
        "BoxName": "",
        "Note": "Akun utama / project produksi"
    }
]
```
- `Id`: ID unik profil (`"default"` untuk akun Host).
- `Name`: Nama tampilan profil pada kartu.
- `IsDefault`: `true` untuk akun Windows Host saat ini.
- `BoxName`: Nama akun Windows lokal untuk profil sekunder (kosong untuk Host).
- `Note`: Tag / deskripsi bebas per-profil (opsional, tampil di bawah statistik kartu).

---

## 5. Fitur Panel & Petunjuk Penggunaan

### Header & Kontrol Utama
- **Pengaturan (`⚙`)**: Membuka/menutup panel pengaturan:
  - **Format Penanda Window Antigravity**: memilih format prefix tag pada title bar IDE.
  - **Nama File Editor di Judul Window**: memilih **Tampilkan (file - project)** atau **Sembunyikan (project saja)**.
  - **Browser Pembuka Link Akun Sekunder**: memilih browser terisolasi (Chrome/Brave/Edge) atau Browser Host Default.
- **Sinkronkan (`⟳`)**: Memindai ulang akun Windows lokal (`Sync-WindowsUsers -IncludeIgnored`), memperbarui tag window, dan memicu scan ulang storage & metrik.
- **Drag Window**: Klik dan tahan area title bar untuk memindahkan jendela.

### Kartu Profil
- **Urutan (`▲` / `▼`)**: Mengubah urutan profil (otomatis memperbarui nomor tag `U1`, `U2`, dst.).
- **Edit Nama & Deskripsi (`✎` atau klik langsung area `+ Tambah tag / deskripsi` / badge catatan)**:
  - Membuka panel edit inline di dalam kartu untuk mengubah **Nama** dan **Deskripsi** sekaligus.
  - Tekan `Enter` atau klik **Simpan** untuk menyimpan; `Esc` atau **Batal** untuk membatalkan.
- **Tombol Aksi**:
  - **Buka** (saat `IDLE`): Menjalankan sesi Antigravity IDE untuk profil tersebut.
  - **Fokus** (saat `ACTIVE`): Membawa jendela Antigravity IDE profil tersebut ke depan.
  - **`+`** (saat `ACTIVE`): Membuka jendela Antigravity IDE baru pada profil yang sama.
  - **`🌐`**: Membuka browser terisolasi milik profil tersebut.
  - **`✕`** (merah, saat `ACTIVE`): Menutup semua proses Antigravity IDE khusus profil tersebut tanpa memengaruhi akun lain.
  - **Hapus** (profil sekunder): Menghapus profil dari daftar Hub dan memasukkannya ke `ignored_users.json` (tidak menghapus user Windows).

### Tambah Akun Baru
- Ketik nama profil di kolom bawah lalu klik **`+ Tambah Akun`** (atau tekan `Enter`).
- Saat pertama kali dibuka, jika akun Windows lokal belum ada, Hub akan meminta izin UAC untuk menjalankan `Setup-MultiUser.ps1` secara otomatis.

---

## 6. Aturan Pengembangan & Maintenance (Rules)

Wajib diikuti setiap kali memodifikasi kode Antigravity Hub:

1. **Dilarang Menangkap Variabel Loop PowerShell di Event Handler WPF**:
   - PowerShell tidak melakukan capture by-value pada variabel loop `for`/`foreach` di dalam scriptblock `{ ... }`.
   - Selalu simpan konteks per-kartu (index, objek profil, referensi kontrol UI, warna hover) ke properti `$control.Tag` dan baca lewat `$sender.Tag` di dalam handler.
2. **Dilarang Menjalankan Operasi Blocking di UI Thread (`DispatcherTimer`)**:
   - Jangan pernah memanggil `Get-ChildItem -Recurse`, `Get-CimInstance` / WMI, `Get-LocalUser`, atau `Get-Process` secara sinkron di dalam timer UI.
   - Semua pemindaian proses, metrik, dan disk harus berjalan di background thread milik `AgyBgMonitor`.
3. **Update Native DLL (`AgyNative.v2.dll`)**:
   - Jika mengubah kode C# di dalam `$NativeSource` pada `AntigravityProfileManager.ps1`, **hapus `AgyNative.v2.dll`** (atau naikkan versi nama file DLL, misal `AgyNative.v3.dll`) agar perubahan C# terkompilasi ulang dan tidak memuat versi lama.
   - Kode C# di `$NativeSource` harus kompatibel dengan **C# 5 / .NET Framework 4.x** (compiler `Add-Type` bawaan Windows PowerShell 5.1 — hindari sintaks C# 8+ seperti `??=`, nullable reference types, atau target-typed `new()`).
4. **Pertahankan In-Place UI Updates**:
   - Jangan memasukkan nilai metrik yang terus berubah (RAM, CPU, jumlah window) ke dalam `$sig` struktural `Render-Profiles` agar kartu tidak dihancurkan dan dibuat ulang setiap detik.
   - Gunakan `Get-FrozenBrush` untuk semua warna agar tidak terjadi alokasi `BrushConverter` berulang.
5. **Sinkronisasi Dual-Path `window.title`**:
   - Setiap perubahan format `window.title` harus diterapkan konsisten di dua tempat:
     1. `Get-DesiredWindowTitle` di `AntigravityProfileManager.ps1` (update live Host & best-effort akun sekunder).
     2. `apply-window-tag.ps1` (dijalankan saat akun sekunder diluncurkan via `launch-antigravity.cmd`).
6. **Kompatibilitas Skema JSON**:
   - Penambahan field baru pada `profiles.json` atau `hub_settings.json` harus selalu memiliki nilai default aman (`Ensure-ProfileSchema` / `Load-HubSettings`) agar konfigurasi lama tetap berjalan tanpa error.
7. **Verifikasi Wajib Sebelum Selesai**:
   - Pastikan parser PowerShell menghasilkan `0` error pada `AntigravityProfileManager.ps1` dan `apply-window-tag.ps1`.
   - Pastikan XML `MainWindow.xaml` valid dan semua elemen `x:Name` yang dipanggil `FindName()` tersedia.

---

## 7. Troubleshooting Singkat

- **Judul window akun sekunder belum berubah setelah ubah pengaturan**: Tutup lalu buka kembali jendela Antigravity IDE akun sekunder tersebut (agar `apply-window-tag.ps1` berjalan dengan sesi user-nya), atau jalankan Antigravity Hub sebagai Administrator.
- **Akun Windows baru tidak muncul otomatis**: Klik tombol **Sync (`⟳`)** di pojok kanan atas Hub.
- **Storage masih menampilkan `...`**: Scan disk berjalan di background prioritas terendah agar tidak membuat UI lag; angka akan muncul otomatis begitu scan selesai.
- **Error setelah edit kode C# di script**: Hapus file `AgyNative.v2.dll` di folder aplikasi lalu buka ulang Antigravity Hub agar DLL dikompilasi ulang secara otomatis.
