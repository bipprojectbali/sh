#!/usr/bin/env bash
# copas — clipboard get/set lintas-OS untuk teks, gambar, file.
# Smart: deteksi OS + backend; di sesi SSH/remote, teks dikirim lewat OSC 52
# ke terminal lokal, jadi Ctrl+V / Cmd+V di mesin kamu tetap jalan.
# ponytail: single-file (biar portable "copy 1 file ke mana saja"); lewat batas
#           soft util 200 baris — pecah per-backend kalau nanti terasa berat.
set -euo pipefail

COPAS_VERSION="1.0.0"

die()  { printf 'copas: %s\n' "$1" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
have_tty() { [[ -e /dev/tty ]]; }
is_remote() { [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]]; }
abspath() { printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"; }
TMP="${TMPDIR:-/tmp}"

case "$(uname -s)" in
  Darwin) OS=mac ;;
  Linux)  if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then OS=wsl; else OS=linux; fi ;;
  CYGWIN*|MINGW*|MSYS*) OS=windows ;;
  *) OS=unknown ;;
esac

resolve_backend() {
  [[ -n "${COPAS_BACKEND:-}" ]] && { echo "$COPAS_BACKEND"; return; }
  if is_remote && [[ -z "${COPAS_LOCAL:-}" ]] && have_tty; then echo osc52; return; fi
  case "$OS" in
    mac) echo mac ;;
    linux|wsl)
      if   [[ -n "${WAYLAND_DISPLAY:-}" ]] && have wl-copy; then echo wayland
      elif [[ -n "${DISPLAY:-}" ]] && have xclip; then echo xclip
      elif [[ -n "${DISPLAY:-}" ]] && have xsel;  then echo xsel
      elif [[ "$OS" == wsl ]] && { have clip.exe || have powershell.exe; }; then echo win
      elif have_tty; then echo osc52
      else echo none; fi ;;
    windows) echo win ;;
    *) if have_tty; then echo osc52; else echo none; fi ;;
  esac
}
BK=$(resolve_backend)

mime_of() {
  if have file; then file --mime-type -b "$1"; return; fi
  case "$1" in
    *.png) echo image/png ;; *.jpg|*.jpeg) echo image/jpeg ;;
    *.gif) echo image/gif ;; *.webp) echo image/webp ;; *) echo text/plain ;;
  esac
}

winpath() { if have wslpath; then wslpath -w "$1"; elif have cygpath; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

# percent-encode path untuk file:// (python3 bila ada; fallback bash ASCII)
uri_encode() {
  if have python3; then python3 -c 'import sys,urllib.parse as u; print(u.quote(sys.argv[1]))' "$1"; return; fi
  local s="$1" out="" i c
  for ((i=0;i<${#s};i++)); do c="${s:i:1}"
    case "$c" in [a-zA-Z0-9/._~-]) out+="$c" ;; *) out+=$(printf '%%%02X' "'$c") ;; esac
  done
  printf '%s\n' "$out"
}
# stdin baris path ber-encode → decode %XX (python3 bila ada; fallback printf)
uri_decode() {
  if have python3; then python3 -c 'import sys,urllib.parse as u;[sys.stdout.write(u.unquote(l)) for l in sys.stdin]'; return; fi
  local line; while IFS= read -r line || [[ -n "$line" ]]; do printf '%b\n' "${line//%/\\x}"; done
}
# keluarga Nautilus (GTK) butuh x-special/gnome-copied-files; sisanya text/uri-list
linux_de() {
  local d; d=$(printf ':%s:%s:%s:' "${XDG_CURRENT_DESKTOP:-}" "${XDG_SESSION_DESKTOP:-}" "${DESKTOP_SESSION:-}" | tr 'A-Z' 'a-z')
  case "$d" in *gnome*|*unity*|*cinnamon*|*mate*|*budgie*|*pantheon*) echo gnome ;; *) echo other ;; esac
}
payload_gnome()  { local out="copy" p; for p in "$@"; do out+=$'\n'"file://$(uri_encode "$p")"; done; printf '%s' "$out"; }
payload_urilist() { local p; for p in "$@"; do printf 'file://%s\r\n' "$(uri_encode "$p")"; done; }
win_set_files() {
  have powershell.exe || die "powershell.exe tak ada"
  local -a wp=(); local p; for p in "$@"; do wp+=("'$(winpath "$p")'"); done
  local joined; joined=$(IFS=,; echo "${wp[*]}")
  powershell.exe -NoProfile -Command "Set-Clipboard -LiteralPath $joined" >/dev/null 2>&1 || die "gagal set file (windows)"
}

# --- OSC 52 (text → clipboard terminal lokal, nembus SSH) -------------------
osc52_copy() {  # stdin = bytes
  local b64; b64=$(base64 | tr -d '\n')
  [[ ${#b64} -gt 100000 ]] && printf 'copas: data besar, sebagian terminal memotong OSC52\n' >&2
  local e=$'\033' bel=$'\007'
  local seq="$e]52;c;${b64}${bel}"
  if [[ -n "${TMUX:-}" ]]; then seq="${e}Ptmux;${e}${seq}${e}\\"
  elif [[ "${TERM:-}" == screen* ]]; then seq="${e}P${seq}${e}\\"; fi
  { printf '%s' "$seq" > /dev/tty; } 2>/dev/null || printf '%s' "$seq"
  printf 'copas: dikirim ke clipboard terminal (OSC52) — Ctrl+V/Cmd+V di lokal\n' >&2
}

# --- macOS helpers ----------------------------------------------------------
mac_kind() {
  local i; i=$(osascript -e 'clipboard info' 2>/dev/null || true)
  if   [[ "$i" == *PNGf* || "$i" == *TIFF* || "$i" == *picture* ]]; then echo image
  elif [[ "$i" == *furl* ]]; then echo file
  elif [[ -n "$i" ]]; then echo text
  else echo empty; fi
}
mac_get_image() {  # $1 = out.png
  local out; out="$(abspath "$1")"
  osascript >/dev/null 2>&1 <<OSA && return 0
set f to (open for access (POSIX file "$out") with write permission)
set eof f to 0
write (the clipboard as «class PNGf») to f
close access f
OSA
  local tif="$TMP/copas-$$.tiff"
  osascript >/dev/null 2>&1 <<OSA || { rm -f "$tif"; die "clipboard tak berisi gambar"; }
set f to (open for access (POSIX file "$tif") with write permission)
set eof f to 0
write (the clipboard as «class TIFF») to f
close access f
OSA
  sips -s format png "$tif" --out "$out" >/dev/null 2>&1 || { rm -f "$tif"; die "gagal TIFF→PNG"; }
  rm -f "$tif"
}

# --- Windows/WSL helpers (best-effort gambar via .NET) ----------------------
win_set_image() {
  have powershell.exe || die "powershell.exe tak ada"
  local wp; wp=$(winpath "$(abspath "$1")")
  powershell.exe -NoProfile -STA -Command \
    "Add-Type -AssemblyName System.Windows.Forms,System.Drawing; [System.Windows.Forms.Clipboard]::SetImage([System.Drawing.Image]::FromFile('$wp'))" \
    >/dev/null 2>&1 || die "gagal set gambar (windows)"
}
win_get_image() {
  have powershell.exe || die "powershell.exe tak ada"
  local wp; wp=$(winpath "$(abspath "$1")")
  powershell.exe -NoProfile -STA -Command \
    "Add-Type -AssemblyName System.Windows.Forms,System.Drawing; \$i=[System.Windows.Forms.Clipboard]::GetImage(); if(\$i -ne \$null){\$i.Save('$wp')}else{exit 1}" \
    >/dev/null 2>&1 || die "clipboard bukan gambar (windows)"
}

# --- backend dispatch -------------------------------------------------------
set_text_be() {  # stdin
  case "$BK" in
    mac) pbcopy ;;
    wayland) wl-copy ;;
    xclip) xclip -selection clipboard ;;
    xsel) xsel -b -i ;;
    win) if have clip.exe; then clip.exe; else clip; fi ;;
    osc52) osc52_copy ;;
    none|*) die "tak ada backend clipboard (set COPAS_BACKEND / install wl-clipboard|xclip)" ;;
  esac
}
get_text_be() {
  case "$BK" in
    mac) pbpaste ;;
    wayland) wl-paste -n ;;
    xclip) xclip -selection clipboard -o ;;
    xsel) xsel -b -o ;;
    win) powershell.exe -NoProfile -Command Get-Clipboard | sed 's/\r$//' ;;
    osc52) die "get via OSC52 tak reliabel; jalankan 'copas get' di mesin lokal" ;;
    none|*) die "tak ada backend clipboard untuk get" ;;
  esac
}
set_image_be() {  # $1 = file gambar
  local src="$1" mime; mime=$(mime_of "$src")
  case "$BK" in
    mac)
      local png="$src"
      [[ "$mime" == image/png ]] || { png="$TMP/copas-$$.png"; sips -s format png "$src" --out "$png" >/dev/null 2>&1 || die "gagal konversi PNG"; }
      osascript -e "set the clipboard to (read (POSIX file \"$(abspath "$png")\") as «class PNGf»)" ;;
    wayland) wl-copy --type "$mime" < "$src" ;;
    xclip)   xclip -selection clipboard -t "$mime" -i "$src" ;;
    xsel)    die "xsel tak dukung gambar; install xclip/wl-clipboard" ;;
    win)     win_set_image "$src" ;;
    osc52)   die "gambar tak bisa via SSH/OSC52; simpan file lalu scp/croc, atau jalankan di lokal" ;;
    none|*)  die "tak ada backend untuk gambar" ;;
  esac
}
get_image_be() {  # $1 = out
  local out="$1" t
  case "$BK" in
    mac) mac_get_image "$out" ;;
    wayland)
      t=$(wl-paste --list-types 2>/dev/null | grep -m1 '^image/') || true
      [[ -n "$t" ]] || die "clipboard bukan gambar"; wl-paste --type "$t" > "$out" ;;
    xclip)
      t=$(xclip -selection clipboard -t TARGETS -o 2>/dev/null | grep -m1 'image/') || true
      [[ -n "$t" ]] || die "clipboard bukan gambar"; xclip -selection clipboard -t "$t" -o > "$out" ;;
    win) win_get_image "$out" ;;
    *) die "get gambar tak didukung di backend $BK" ;;
  esac
  [[ -s "$out" ]] || die "clipboard bukan gambar"
}
be_kind() {
  case "$BK" in
    mac) mac_kind ;;
    wayland)
      local t; t=$(wl-paste --list-types 2>/dev/null) || { echo empty; return; }
      [[ -z "$t" ]] && { echo empty; return; }
      if   grep -q '^image/' <<<"$t"; then echo image
      elif grep -qE 'uri-list|gnome-copied-files' <<<"$t"; then echo file
      else echo text; fi ;;
    xclip)
      local t; t=$(xclip -selection clipboard -t TARGETS -o 2>/dev/null) || { echo empty; return; }
      if   grep -q 'image/' <<<"$t"; then echo image
      elif grep -qE 'uri-list|gnome-copied-files' <<<"$t"; then echo file
      elif [[ -n "$t" ]]; then echo text
      else echo empty; fi ;;
    *) echo text ;;   # xsel/win/osc52: tak bisa introspeksi murah → asumsi teks
  esac
}

cmd_file() {
  local -a paths=(); local f p
  for f in "$@"; do p="$(abspath "$f")"; [[ -e "$p" ]] || die "file tidak ada: $f"; paths+=("$p"); done
  [[ ${#paths[@]} -ge 1 ]] || die "pemakaian: copas file <path>..."
  local de; de=$(linux_de)
  case "$BK" in
    mac)
      if [[ ${#paths[@]} -eq 1 ]]; then
        osascript -e "set the clipboard to (POSIX file \"${paths[0]}\")"
      else
        local lst; lst=$(printf '(POSIX file "%s"), ' "${paths[@]}"); lst="{${lst%, }}"
        osascript -e "set the clipboard to $lst" 2>/dev/null \
          || { osascript -e "set the clipboard to (POSIX file \"${paths[0]}\")"; printf 'copas: multi-file di macOS best-effort; hanya file pertama\n' >&2; }
      fi ;;
    wayland)
      if [[ "$de" == gnome ]]; then payload_gnome "${paths[@]}" | wl-copy --type x-special/gnome-copied-files
      else payload_urilist "${paths[@]}" | wl-copy --type text/uri-list; fi ;;
    xclip)
      if [[ "$de" == gnome ]]; then payload_gnome "${paths[@]}" | xclip -selection clipboard -t x-special/gnome-copied-files
      else payload_urilist "${paths[@]}" | xclip -selection clipboard -t text/uri-list; fi ;;
    win) win_set_files "${paths[@]}" ;;
    osc52|none)
      die "sesi remote/headless: file tak bisa masuk clipboard GUI lewat SSH. Transfer ke lokal: croc send '${paths[0]}'  (atau scp)" ;;
    *) die "referensi file tak didukung di backend $BK" ;;
  esac
}
get_file_path() {
  case "$BK" in
    mac) osascript -e 'POSIX path of (the clipboard as «class furl»)' ;;
    wayland)
      if wl-paste --list-types 2>/dev/null | grep -q gnome-copied-files; then
        wl-paste --type x-special/gnome-copied-files 2>/dev/null | sed '1d; s|^file://||' | uri_decode
      else wl-paste --type text/uri-list 2>/dev/null | sed 's|^file://||; s|\r$||' | uri_decode; fi ;;
    xclip)
      if xclip -selection clipboard -t TARGETS -o 2>/dev/null | grep -q gnome-copied-files; then
        xclip -selection clipboard -t x-special/gnome-copied-files -o 2>/dev/null | sed '1d; s|^file://||' | uri_decode
      else xclip -selection clipboard -t text/uri-list -o 2>/dev/null | sed 's|^file://||; s|\r$||' | uri_decode; fi ;;
    win) powershell.exe -NoProfile -Command "Get-Clipboard -Format FileDropList" 2>/dev/null | sed 's/\r$//' ;;
    *) die "get referensi file tak didukung di backend $BK" ;;
  esac
}

cmd_set() {
  local src="${1:-}" tmp=""
  if [[ -z "$src" ]]; then
    tmp="$TMP/copas-set-$$"; cat > "$tmp"; src="$tmp"
    [[ -s "$src" ]] || { rm -f "$tmp"; die "stdin kosong"; }
  else
    [[ -f "$src" ]] || die "file tidak ada: $src"
  fi
  local mime; mime=$(mime_of "$src")
  case "$mime" in
    image/*) set_image_be "$src" ;;
    text/*|application/json|application/*xml|application/javascript|inode/x-empty) set_text_be < "$src" ;;
    *)
      if [[ -n "$tmp" ]]; then rm -f "$tmp"; die "biner ($mime) via stdin tak didukung; pakai: copas file <path>"; fi
      cmd_file "$src" ;;
  esac
  [[ -n "$tmp" ]] && rm -f "$tmp" || true
}
cmd_get() {
  local out="${1:-}"
  case "$(be_kind)" in
    image)
      local tmp="$TMP/copas-get-$$.img"; get_image_be "$tmp"
      if [[ -n "$out" ]]; then mv "$tmp" "$out"; else cat "$tmp"; rm -f "$tmp"; fi ;;
    file)
      local p; p=$(get_file_path)
      if [[ -n "$out" ]]; then printf '%s\n' "$p" > "$out"; else printf '%s\n' "$p"; fi ;;
    text)
      if [[ -n "$out" ]]; then get_text_be > "$out"; else get_text_be; fi ;;
    empty) die "clipboard kosong" ;;
  esac
}

cmd_test() {
  printf 'env: OS=%s backend=%s remote=%s DE=%s\n' "$OS" "$BK" "$(is_remote && echo yes || echo no)" "$(linux_de)"
  [[ "$(uri_encode '/a b/c#d')" == "/a%20b/c%23d" ]] || die "SELF-TEST GAGAL: uri_encode"
  [[ "$(printf '/a%%20b/c%%23d' | uri_decode)" == "/a b/c#d" ]] || die "SELF-TEST GAGAL: uri_decode"
  if [[ "$BK" == osc52 || "$BK" == none || "$BK" == win ]]; then
    printf 'copas-selftest' | set_text_be
    echo "set text OK (backend $BK; get tak diverifikasi di sini)"; return
  fi
  local msg="copas-selftest-$$"
  printf '%s' "$msg" | set_text_be
  [[ "$(get_text_be)" == "$msg" ]] || die "SELF-TEST GAGAL: text roundtrip"
  local b64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='
  local png="$TMP/copas-t-$$.png" outp="$TMP/copas-to-$$.png"
  printf '%s' "$b64" | openssl base64 -d -A > "$png" 2>/dev/null || die "butuh openssl untuk decode test"
  set_image_be "$png"; get_image_be "$outp"
  [[ -s "$outp" ]] || { rm -f "$png" "$outp"; die "SELF-TEST GAGAL: image roundtrip"; }
  rm -f "$png" "$outp"
  echo "self-test OK (text + image) [$BK]"
}

cmd_install() {
  local self dir
  self="$(abspath "$0")"
  dir="${1:-$HOME/.local/bin}"
  mkdir -p "$dir" || die "gagal membuat $dir"
  ln -sf "$self" "$dir/copas" || die "gagal symlink ke $dir"
  printf 'copas v%s terpasang: %s/copas -> %s\n' "$COPAS_VERSION" "$dir" "$self"
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) printf 'catatan: %s belum di PATH. Tambahkan ke shell rc:\n  export PATH="%s:$PATH"\n' "$dir" "$dir" >&2 ;;
  esac
}
cmd_uninstall() {
  local dir="${1:-$HOME/.local/bin}"
  [[ -L "$dir/copas" || -f "$dir/copas" ]] || die "tak ada copas di $dir"
  rm -f "$dir/copas" && printf 'copas dihapus dari %s\n' "$dir"
}

usage() {
  cat <<EOF
copas v$COPAS_VERSION — clipboard lintas-OS: teks, gambar, file.
backend aktif: $BK (OS=$OS)

PENGGUNAAN
  copas <perintah> [argumen]

PERINTAH
  set [path]           salin ke clipboard (dari path, atau stdin)
  get [path]           keluarkan clipboard (ke file bila path, selain itu stdout)
  file <path>...       salin file sebagai REFERENSI (paste di Finder/Explorer/file manager)
  type                 jenis isi clipboard: text | image | file | empty
  clear                kosongkan clipboard
  env                  tampilkan OS, backend, status remote/tty, DE
  test                 self-test
  install [dir]        symlink ke PATH (default: ~/.local/bin)
  uninstall [dir]      hapus symlink
  version              tampilkan versi
  help                 tampilkan bantuan ini

OPSI GLOBAL
  -h, --help           bantuan ini
  -v, --version        tampilkan versi

VARIABEL LINGKUNGAN
  COPAS_BACKEND=mac|wayland|xclip|xsel|win|osc52   paksa backend tertentu
  COPAS_LOCAL=1                                    abaikan OSC52 saat SSH (pakai clipboard server)

CONTOH
  echo halo | copas set            # di SSH → Ctrl+V/Cmd+V di mesin lokal (OSC52)
  copas set a.png                  # salin gambar
  copas get > out.png              # simpan gambar dari clipboard
  cat a.png | copas set            # via pipe
  copas file laporan.pdf           # salin file, lalu paste di file manager
EOF
}

case "${1:-help}" in
  set)   shift; cmd_set "${1:-}" ;;
  get)   shift; cmd_get "${1:-}" ;;
  file)  shift; [[ $# -ge 1 ]] || die "pemakaian: copas file <path>..."; cmd_file "$@" ;;
  type)  be_kind ;;
  env)   printf 'OS=%s backend=%s remote=%s tty=%s DE=%s\n' "$OS" "$BK" "$(is_remote && echo yes || echo no)" "$(have_tty && echo yes || echo no)" "$(linux_de)" ;;
  clear) : | set_text_be ;;
  test)  cmd_test ;;
  install)   shift; cmd_install "${1:-}" ;;
  uninstall) shift; cmd_uninstall "${1:-}" ;;
  version|-v|--version) printf 'copas %s\n' "$COPAS_VERSION" ;;
  help|-h|--help) usage ;;
  *) die "perintah tak dikenal: $1 (coba: copas help)" ;;
esac
