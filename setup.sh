#!/usr/bin/env bash
#
# ============================================================================
#  Hermes Agent — Installer & Manager Menu
#  Target: Ubuntu 24.04 (jalankan sebagai root)
# ============================================================================
#
#  Menu:
#    1. Setup DeepSeek        → pilih Pro-0813 / V4.1-Flash
#    2. Setup Custom Model    → base URL + model + API key (endpoint OpenAI-compatible)
#    3. Change model          → ganti model di instalasi yang sudah ada
#    4. Status & model aktif  → lihat model, provider, status gateway
#    5. Restart gateway
#    6. Lihat log
#    7. Backup                → seluruh ~/.hermes (config, token, skills, memory) → backup.zip
#    8. Restore               → pulihkan dari backup.zip (untuk pindah ke VPS baru)
#    9. Keluar
#
#  Cara pakai:  bash hermes-menu.sh
#
#  Catatan: saat instalasi Hermes kadang muncul wizard setup.
#  Kalau muncul, tekan ESC — config ditulis otomatis oleh script ini.
# ============================================================================

set -uo pipefail

c_ok()   { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
c_info() { printf "\033[1;36m•\033[0m %s\n" "$*"; }
c_warn() { printf "\033[1;33m⚠\033[0m %s\n" "$*"; }
c_err()  { printf "\033[1;31m✗\033[0m %s\n" "$*" >&2; }
c_head() { printf "\n\033[1;35m== %s ==\033[0m\n" "$*"; }

HERMES_DIR="/root/.hermes"
HERMES_VENV_PY="/usr/local/lib/hermes-agent/venv/bin/python"
PYBIN=""
HERMES_BIN=""

# ---------------------------------------------------------------------------
require_root() {
  [[ $EUID -ne 0 ]] && { c_err "Harus root. Coba: sudo bash $0"; exit 1; }
}

# Cari Python yang punya modul yaml (utamakan venv Hermes)
resolve_python() {
  if [[ -x "$HERMES_VENV_PY" ]] && "$HERMES_VENV_PY" -c "import yaml" >/dev/null 2>&1; then
    PYBIN="$HERMES_VENV_PY"; return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    if ! python3 -c "import yaml" >/dev/null 2>&1; then
      c_info "Memasang PyYAML untuk python3..."
      apt-get install -y python3-yaml >/dev/null 2>&1 \
        || pip3 install --break-system-packages pyyaml >/dev/null 2>&1 || true
    fi
    if python3 -c "import yaml" >/dev/null 2>&1; then PYBIN="python3"; return 0; fi
  fi
  c_err "Tidak menemukan Python dengan modul yaml. Tidak bisa menulis config dengan aman."
  return 1
}

install_deps() {
  c_head "Install dependency sistem"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || c_warn "apt update ada peringatan"
  apt-get install -y curl ca-certificates git zip unzip >/dev/null 2>&1 || true
  # Dependency inti untuk Node.js (dipakai Hermes) — libatomic1 WAJIB,
  # tanpa ini instalasi Hermes gagal: "libatomic.so.1: cannot open shared object file".
  apt-get install -y libatomic1 libstdc++6 >/dev/null 2>&1 \
    || c_warn "libatomic1/libstdc++6 gagal dipasang — instalasi Hermes bisa gagal di tahap Node."
  # Library untuk Chromium headless (browser automation Hermes)
  apt-get install -y \
    libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
    libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    libgbm1 libasound2t64 libpango-1.0-0 fonts-liberation \
    >/dev/null 2>&1 || c_warn "Sebagian library Chromium gagal (browser mungkin perlu diperbaiki nanti)"
  c_ok "Dependency siap"
}

install_hermes() {
  c_head "Install Hermes Agent"
  if command -v hermes >/dev/null 2>&1; then
    c_ok "Hermes sudah ada: $(command -v hermes)"
  else
    c_warn "Jika muncul wizard setup selama instalasi, tekan ESC (config ditulis oleh script)."
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
    export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"; hash -r
  fi
  command -v hermes >/dev/null 2>&1 || { c_err "'hermes' tidak ditemukan setelah instal."; return 1; }
  HERMES_BIN="$(command -v hermes)"
  c_ok "Hermes: $HERMES_BIN"
}

gather_telegram() {
  c_head "Kredensial Telegram"
  TG_USER_ID="${HERMES_TG_USER_ID:-}"
  TG_BOT_TOKEN="${HERMES_TG_BOT_TOKEN:-}"
  [[ -z "$TG_USER_ID" ]] && read -rp "Telegram User ID (angka, dari @userinfobot): " TG_USER_ID
  if [[ -z "$TG_BOT_TOKEN" ]]; then
    read -rsp "Telegram Bot Token (dari @BotFather, tersembunyi): " TG_BOT_TOKEN; echo
  fi
  [[ "$TG_USER_ID" =~ ^[0-9]+$ ]] || { c_err "User ID harus angka: '$TG_USER_ID'"; return 1; }
  [[ "$TG_BOT_TOKEN" =~ ^[0-9]+:.+ ]] || { c_err "Format bot token salah (harus 'angka:huruf')."; return 1; }
  c_ok "Telegram diterima (user_id=$TG_USER_ID)"
}

verify_deepseek_key() {
  local key="$1" r
  c_info "Verifikasi API key DeepSeek..."
  r="$(curl -sS -m 15 https://api.deepseek.com/user/balance -H "Authorization: Bearer ${key}" 2>/dev/null || true)"
  if echo "$r" | grep -q '"is_available":true'; then
    c_ok "Key valid & ada saldo"
  else
    c_warn "Key belum terverifikasi (mungkin salah/saldo habis/jaringan). Lanjut — betulkan kalau nanti 401."
  fi
}

# Verifikasi kemampuan tool-calling di level API (deteksi model yang tidak cocok untuk agent)
verify_tool_calling() {
  local base="$1" key="$2" model="$3" r
  if ! command -v curl >/dev/null 2>&1; then
    c_warn "curl belum terpasang — lewati verifikasi tool-calling (akan dites lewat bot nanti)."
    return 0
  fi
  c_info "Verifikasi tool-calling model (level API)..."
  r="$(curl -sS -m 30 "${base%/}/chat/completions" \
        -H "Content-Type: application/json" -H "Authorization: Bearer ${key}" \
        -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"Panggil tool run untuk cek disk\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"run\",\"description\":\"run cmd\",\"parameters\":{\"type\":\"object\",\"properties\":{\"cmd\":{\"type\":\"string\"}},\"required\":[\"cmd\"]}}}],\"tool_choice\":\"auto\",\"max_tokens\":100}" 2>/dev/null || true)"
  if echo "$r" | grep -q '"tool_calls"'; then
    c_ok "Tool-calling JALAN — model cocok untuk agent"
    return 0
  elif echo "$r" | grep -q '"content"'; then
    c_warn "Model membalas TAPI tidak memanggil tool — kemungkinan TIDAK cocok untuk agent."
    c_warn "Model chat-only (label 'chat'/'vision') sering begini. Pilih model ber-label 'tools'/'coding'."
    return 1
  else
    c_warn "Endpoint tidak membalas seperti diharapkan. Respons: ${r:0:200}"
    return 1
  fi
}

# Backup config.yaml sebelum diubah
backup_config() {
  if [[ -f "$HERMES_DIR/config.yaml" ]]; then
    cp "$HERMES_DIR/config.yaml" "$HERMES_DIR/config.yaml.bak.$(date +%Y%m%d_%H%M%S)" \
      && c_ok "Backup config dibuat"
  fi
  return 0
}

# Tulis .env dengan aman. Arg1 = baris rahasia model tambahan (boleh kosong).
write_env() {
  local model_secret_line="$1" tmp="$HERMES_DIR/.env.tmp"
  mkdir -p "$HERMES_DIR"
  if [[ -f "$HERMES_DIR/.env" ]]; then
    grep -vE '^(DEEPSEEK_API_KEY|TELEGRAM_BOT_TOKEN)=' "$HERMES_DIR/.env" > "$tmp" 2>/dev/null || true
  else
    : > "$tmp"
  fi
  [[ -n "$model_secret_line" ]] && echo "$model_secret_line" >> "$tmp"
  echo "TELEGRAM_BOT_TOKEN=${TG_BOT_TOKEN}" >> "$tmp"
  mv "$tmp" "$HERMES_DIR/.env"
  chmod 600 "$HERMES_DIR/.env"
  c_ok "Tulis .env (chmod 600)"
}

# Terapkan blok model + Telegram + fix tampilan, MEMUAT config yang ada dulu.
# Env: HMODE(deepseek|custom) HMODEL HBASE HKEY HTGUSER
apply_config() {
  mkdir -p "$HERMES_DIR"
  backup_config
  local out
  out="$(HCFG="$HERMES_DIR/config.yaml" "$PYBIN" <<'PYEOF'
import os, yaml
p = os.environ["HCFG"]
try:
    with open(p) as f:
        c = yaml.safe_load(f) or {}
except FileNotFoundError:
    c = {}
except yaml.YAMLError:
    # config.yaml rusak/tidak bisa di-parse → bangun ulang dari nol.
    # Aman: backup_config sudah menyimpan salinan asli sebelum ini,
    # dan Setup memang menulis ulang semua key yang diperlukan.
    c = {}
if not isinstance(c, dict):
    c = {}

mode = os.environ["HMODE"]
if mode == "deepseek":
    c["model"] = {"default": os.environ["HMODEL"], "provider": "auto"}
else:
    c["model"] = {
        "provider": "custom",
        "default": os.environ["HMODEL"],
        "base_url": os.environ["HBASE"],
        "api_key": os.environ["HKEY"],
    }
# Tanpa fallback: buang fallback_providers jika ada dari config lama
c.pop("fallback_providers", None)

uid = int(os.environ["HTGUSER"])
c["TELEGRAM_ALLOWED_USERS"] = uid
c["TELEGRAM_HOME_CHANNEL"] = uid
c.setdefault("platforms", {}).setdefault("telegram", {})["enabled"] = True
c.setdefault("terminal", {})["backend"] = "local"
c.setdefault("onboarding", {}).setdefault("seen", {})["profile_build_offered"] = True
# Cegah pesan dobel di Telegram + tampilan lebih bersih
c.setdefault("streaming", {})["enabled"] = False
disp = c.setdefault("display", {})
disp["interim_assistant_messages"] = False
disp["tool_progress"] = "off"

with open(p, "w") as f:
    yaml.safe_dump(c, f, sort_keys=False, allow_unicode=True)
print("CONFIG_OK")
PYEOF
)"
  if [[ "$out" == *CONFIG_OK* ]]; then
    chmod 600 "$HERMES_DIR/config.yaml"
    c_ok "config.yaml diperbarui (default Hermes dipertahankan)"
    return 0
  else
    c_err "Gagal menulis config.yaml. Output: ${out:-<kosong>}"
    return 1
  fi
}

# Ubah HANYA blok model (untuk Change model). Env: HMODE HMODEL HBASE HKEY
apply_config_modelonly() {
  backup_config
  local out
  out="$(HCFG="$HERMES_DIR/config.yaml" "$PYBIN" <<'PYEOF'
import os, yaml
p = os.environ["HCFG"]
try:
    with open(p) as f:
        c = yaml.safe_load(f) or {}
except FileNotFoundError:
    c = {}
if not isinstance(c, dict):
    c = {}
mode = os.environ["HMODE"]
if mode == "deepseek":
    c["model"] = {"default": os.environ["HMODEL"], "provider": "auto"}
else:
    c["model"] = {
        "provider": "custom",
        "default": os.environ["HMODEL"],
        "base_url": os.environ["HBASE"],
        "api_key": os.environ["HKEY"],
    }
c.pop("fallback_providers", None)
with open(p, "w") as f:
    yaml.safe_dump(c, f, sort_keys=False, allow_unicode=True)
print("CONFIG_OK")
PYEOF
)"
  if [[ "$out" == *CONFIG_OK* ]]; then
    chmod 600 "$HERMES_DIR/config.yaml"
    return 0
  else
    c_err "Gagal menulis config.yaml. Output: ${out:-<kosong>}"
    return 1
  fi
}

install_service() {
  c_head "Pasang gateway sebagai systemd service"
  cat > /etc/systemd/system/hermes-gateway.service <<EOF
[Unit]
Description=Hermes Agent Gateway - Messaging Platform Integration
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=HOME=/root
WorkingDirectory=/root
ExecStart=${HERMES_BIN} gateway run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now hermes-gateway >/dev/null 2>&1 || systemctl start hermes-gateway
  sleep 4
  if systemctl is-active --quiet hermes-gateway; then
    c_ok "Service hermes-gateway: AKTIF"
  else
    c_warn "Service belum aktif. Cek: journalctl -u hermes-gateway -n 40 --no-pager"
  fi
  local connected=0
  for _ in $(seq 1 20); do
    if journalctl -u hermes-gateway -n 80 --no-pager 2>/dev/null | grep -q "Connected to Telegram"; then
      c_ok "Telegram: terhubung (polling mode)"; connected=1; break
    fi
    sleep 2
  done
  [[ $connected -eq 0 ]] && c_warn "Belum terlihat 'Connected to Telegram' dalam ~40s (mungkin hanya lambat). Pantau: journalctl -u hermes-gateway -f"
}

final_note() {
  c_head "SELESAI — langkah terakhir & uji definitif"
  cat <<'EOF'

  1. Buka bot di Telegram, tekan START (atau kirim /start).
     >> Tanpa ini bot tidak bisa membalas ("Chat not found").

  2. Kirim "halo" — harusnya dibalas oleh model yang kamu pilih.

  3. UJI ANTI-HALUSINASI (penting untuk model baru/custom):
     Kirim ke bot:  bikin file /root/tes.txt berisi RAHASIA-123 lalu cat
     Lalu cek di VPS:  cat /root/tes.txt
     - File ADA berisi RAHASIA-123  -> tool beneran dieksekusi ✓
     - File TIDAK ADA padahal bot bilang sukses -> model HALUSINASI ⚠ (ganti model)

  Manajemen: jalankan lagi  bash hermes-menu.sh  (opsi 4/5/6).

EOF
  c_ok "Selesai."
}

# ===========================================================================
#  OPSI 1 — Setup DeepSeek
# ===========================================================================
setup_deepseek() {
  c_head "Setup DeepSeek — pilih model"
  echo "  1. DeepSeek-V4-Pro-0813   (paling kuat, untuk coding/reasoning)"
  echo "  2. DeepSeek-V4.1-Flash    (cepat & murah, tugas ringan)"
  local ch; read -rp "Pilih [1/2, default 1]: " ch
  local MODEL
  case "${ch:-1}" in
    2) MODEL="deepseek/deepseek-flash" ;;
    *) MODEL="deepseek/deepseek-v4-pro" ;;
  esac
  c_ok "Model: $MODEL"

  local KEY="${HERMES_DEEPSEEK_KEY:-}"
  if [[ -z "$KEY" ]]; then read -rsp "DeepSeek API Key (sk-..., tersembunyi): " KEY; echo; fi
  [[ -n "$KEY" ]] || { c_err "API key DeepSeek wajib diisi."; return 1; }
  [[ "${KEY:0:3}" == "sk-" ]] || c_warn "Key biasanya diawali 'sk-' — lanjut."
  verify_deepseek_key "$KEY"

  gather_telegram || return 1
  install_deps
  install_hermes || return 1
  resolve_python || return 1

  write_env "DEEPSEEK_API_KEY=${KEY}"
  HMODE=deepseek HMODEL="$MODEL" HTGUSER="$TG_USER_ID" HBASE="" HKEY="" apply_config || return 1
  install_service
  final_note
}

# ===========================================================================
#  OPSI 2 — Setup Custom Model & Base URL
# ===========================================================================
setup_custom() {
  c_head "Setup Custom Model & Base URL"
  echo "Untuk endpoint OpenAI-compatible apa pun (gateway/router, model API, vLLM/Ollama lokal, dll)."
  echo "Base URL = root OpenAI-compatible, diakhiri /v1 (JANGAN pakai /chat/completions)."
  echo "Contoh format:  https://<host-provider>/v1   atau lokal  http://192.168.1.x:8000/v1"
  echo "Tips: untuk agent, pilih model yang mendukung tool/function calling."
  echo
  local BASE_URL MODEL KEY
  read -rp "Base URL (…/v1): " BASE_URL
  read -rp "Nama model (mis. deepseek/deepseek-v4-pro): " MODEL
  read -rsp "API Key (tersembunyi): " KEY; echo
  [[ -n "$BASE_URL" && -n "$MODEL" && -n "$KEY" ]] || { c_err "Base URL, model, dan API key wajib diisi."; return 1; }

  # Verifikasi tool-calling sebelum commit (deteksi model tidak cocok untuk agent)
  if ! verify_tool_calling "$BASE_URL" "$KEY" "$MODEL"; then
    read -rp "Model mungkin tidak cocok untuk agent. Tetap lanjut? [y/N]: " go
    [[ "${go,,}" == "y" ]] || { c_warn "Dibatalkan. Coba model lain."; return 1; }
  fi

  gather_telegram || return 1
  install_deps
  install_hermes || return 1
  resolve_python || return 1

  write_env ""   # token telegram saja; api_key model di config.yaml (chmod 600)
  HMODE=custom HMODEL="$MODEL" HBASE="$BASE_URL" HKEY="$KEY" HTGUSER="$TG_USER_ID" apply_config || return 1
  install_service
  final_note
}

# ===========================================================================
#  OPSI 3 — Change model
# ===========================================================================
change_model() {
  c_head "Change Model (instalasi yang sudah ada)"
  command -v hermes >/dev/null 2>&1 || { c_err "Hermes belum terpasang. Pakai opsi 1 atau 2 dulu."; return 1; }
  [[ -f "$HERMES_DIR/config.yaml" ]] || { c_err "config.yaml tidak ada. Pakai opsi 1 atau 2 dulu."; return 1; }
  resolve_python || return 1

  echo "  1. DeepSeek-V4-Pro-0813"
  echo "  2. DeepSeek-V4.1-Flash"
  echo "  3. Custom (base URL + model + API key)"
  local ch; read -rp "Pilih [1/2/3]: " ch

  case "$ch" in
    1|2)
      local MODEL KEY
      if [[ "$ch" == "2" ]]; then MODEL="deepseek/deepseek-flash"; else MODEL="deepseek/deepseek-v4-pro"; fi
      read -rsp "DeepSeek API Key (ENTER = pakai yang lama, tersembunyi): " KEY; echo
      if [[ -n "$KEY" ]]; then
        touch "$HERMES_DIR/.env"; chmod 600 "$HERMES_DIR/.env"
        grep -v '^DEEPSEEK_API_KEY=' "$HERMES_DIR/.env" > "$HERMES_DIR/.env.tmp" 2>/dev/null || true
        echo "DEEPSEEK_API_KEY=${KEY}" >> "$HERMES_DIR/.env.tmp"
        mv "$HERMES_DIR/.env.tmp" "$HERMES_DIR/.env"; chmod 600 "$HERMES_DIR/.env"
        c_ok "DEEPSEEK_API_KEY diperbarui"
      elif ! grep -q '^DEEPSEEK_API_KEY=' "$HERMES_DIR/.env" 2>/dev/null; then
        c_err "Tidak ada DEEPSEEK_API_KEY di .env dan kamu tidak memasukkan yang baru. Bot akan 401."
        return 1
      else
        c_info "Pakai DEEPSEEK_API_KEY yang sudah ada"
      fi
      HMODE=deepseek HMODEL="$MODEL" HBASE="" HKEY="" apply_config_modelonly || return 1
      c_ok "Model diganti ke: $MODEL"
      ;;
    3)
      local BASE_URL MODEL KEY
      read -rp "Base URL (…/v1): " BASE_URL
      read -rp "Nama model: " MODEL
      read -rsp "API Key (tersembunyi): " KEY; echo
      [[ -n "$BASE_URL" && -n "$MODEL" && -n "$KEY" ]] || { c_err "Semua field wajib diisi."; return 1; }
      if ! verify_tool_calling "$BASE_URL" "$KEY" "$MODEL"; then
        read -rp "Model mungkin tidak cocok untuk agent. Tetap lanjut? [y/N]: " go
        [[ "${go,,}" == "y" ]] || { c_warn "Dibatalkan."; return 1; }
      fi
      HMODE=custom HMODEL="$MODEL" HBASE="$BASE_URL" HKEY="$KEY" apply_config_modelonly || return 1
      c_ok "Model diganti ke custom: $MODEL @ $BASE_URL"
      ;;
    *) c_err "Pilihan tidak valid."; return 1 ;;
  esac

  if systemctl restart hermes-gateway 2>/dev/null; then
    c_ok "Gateway di-restart"
  else
    c_warn "Gagal restart otomatis — jalankan: systemctl restart hermes-gateway"
  fi
  c_info "Uji: kirim pesan ke bot. Untuk model baru, pakai uji file rahasia (lihat catatan setup)."
}

# ===========================================================================
#  OPSI 4/5/6 — Manajemen
# ===========================================================================
status_and_model() {
  c_head "Status & Model Aktif"
  if [[ -f "$HERMES_DIR/config.yaml" ]]; then
    if resolve_python >/dev/null 2>&1 && [[ -n "$PYBIN" ]]; then
      HCFG="$HERMES_DIR/config.yaml" "$PYBIN" - <<'PYEOF'
import os, yaml
c = yaml.safe_load(open(os.environ["HCFG"])) or {}
m = c.get("model", {})
print("  Model      :", m.get("default", "?"))
print("  Provider   :", m.get("provider", "?"))
print("  Base URL   :", m.get("base_url", "(default provider)"))
print("  Telegram ID:", c.get("TELEGRAM_ALLOWED_USERS", "?"))
PYEOF
    else
      grep -A3 "^model:" "$HERMES_DIR/config.yaml" 2>/dev/null
    fi
  else
    c_warn "config.yaml belum ada — belum ada instalasi."
  fi
  echo
  if systemctl is-active --quiet hermes-gateway; then c_ok "Gateway: AKTIF"; else c_warn "Gateway: TIDAK aktif"; fi
}

restart_gateway() {
  c_head "Restart Gateway"
  if systemctl restart hermes-gateway; then
    c_ok "Gateway di-restart"
  else
    c_err "Gagal restart"
  fi
}

view_logs() {
  c_head "Log terakhir (40 baris)"
  journalctl -u hermes-gateway -n 40 --no-pager 2>/dev/null || c_warn "Tidak bisa membaca log"
  echo
  c_info "Untuk log real-time:  journalctl -u hermes-gateway -f  (Ctrl+C untuk keluar)"
}

# Pastikan sebuah tool ada; kalau tidak, pasang via apt. ensure_tool <cmd> <paket>
ensure_tool() {
  command -v "$1" >/dev/null 2>&1 && return 0
  c_info "Memasang $2..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "$2" >/dev/null 2>&1
  command -v "$1" >/dev/null 2>&1 && return 0
  c_err "Gagal memasang $2. Pasang manual: apt install $2"
  return 1
}

# ===========================================================================
#  OPSI 7 — Backup (seluruh ~/.hermes → backup.zip)
# ===========================================================================
backup_all() {
  c_head "Backup Hermes (config, token, skills, memory)"
  [[ -d "$HERMES_DIR" ]] || { c_err "$HERMES_DIR tidak ada — belum ada instalasi Hermes."; return 1; }
  ensure_tool zip zip || return 1

  local out="/root/backup.zip"
  rm -f "$out"
  # Backup seluruh isi ~/.hermes, TAPI:
  #  - hanya file biasa (-type f) → socket/pipe (mis. gateway.sock) otomatis dilewati
  #    (socket tidak bisa di-zip: "No such device or address"; dibuat ulang saat gateway start)
  #  - kecualikan log & file .bak (clutter yang tidak perlu)
  #  - pakai -exec (bukan pipe) → aman untuk nama file berspasi/karakter khusus
  ( cd /root && find .hermes -type f \
      ! -path '.hermes/logs/*' ! -name '*.bak.*' \
      -exec zip -q "$out" {} + ) 2>/dev/null

  if [[ -f "$out" ]]; then
    c_ok "Backup dibuat: $out ($(du -h "$out" 2>/dev/null | cut -f1))"
    echo
    c_warn "PENTING: backup.zip BERISI API key & bot token (rahasia)."
    c_warn "Jangan upload ke tempat publik / share sembarangan."
    echo
    c_info "Pindahkan ke VPS baru:"
    c_info "  scp $out root@IP_VPS_BARU:~/"
    c_info "Lalu di VPS baru: jalankan script ini → opsi 8 (Restore)."
  else
    c_err "Gagal membuat backup (tidak ada file terbentuk)."
    return 1
  fi
}

# ===========================================================================
#  OPSI 8 — Restore (pulihkan backup.zip di VPS baru)
# ===========================================================================
restore_all() {
  c_head "Restore Hermes dari backup.zip"
  local zipf="${HERMES_RESTORE_ZIP:-}"
  [[ -z "$zipf" ]] && read -rp "Path ke backup.zip [default /root/backup.zip]: " zipf
  [[ -z "$zipf" ]] && zipf="/root/backup.zip"
  [[ -f "$zipf" ]] || { c_err "File tidak ditemukan: $zipf"; return 1; }
  ensure_tool unzip unzip || return 1

  # Proteksi: kalau sudah ada instalasi Hermes di VPS ini, restore akan menimpanya.
  if [[ -f "$HERMES_DIR/config.yaml" ]]; then
    c_warn "Terdeteksi instalasi Hermes yang sudah ada di $HERMES_DIR."
    c_warn "Restore akan MENIMPA config, token, dan skills yang ada sekarang."
    read -rp "Lanjutkan menimpa? [y/N]: " ow
    [[ "${ow,,}" == "y" ]] || { c_warn "Restore dibatalkan."; return 1; }
  fi

  # 1. Pastikan Hermes (binary + venv) terpasang dulu — backup hanya berisi data ~/.hermes,
  #    bukan program Hermes-nya.
  install_deps
  install_hermes || return 1

  # 2. Ekstrak backup → mengembalikan ~/.hermes (config, .env/token, skills, memory)
  c_info "Mengekstrak backup ke ~/.hermes ..."
  if ! ( cd /root && unzip -o -q "$zipf" ); then
    c_err "Gagal mengekstrak $zipf"
    return 1
  fi
  [[ -f "$HERMES_DIR/config.yaml" ]] || { c_err "config.yaml tidak ada setelah ekstrak — backup mungkin rusak / bukan backup Hermes."; return 1; }
  chmod 600 "$HERMES_DIR/.env" 2>/dev/null || true
  chmod 600 "$HERMES_DIR/config.yaml" 2>/dev/null || true
  c_ok "Data Hermes dipulihkan (config, token, skills, memory)"

  # 3. Pasang ulang service (unit systemd tidak ikut backup) + start
  install_service
  final_note
}

# ===========================================================================
#  MENU UTAMA (loop)
# ===========================================================================
require_root
while true; do
  c_head "Hermes Agent — Installer & Manager"
  echo "  1. Setup DeepSeek        (pilih Pro / Flash)"
  echo "  2. Setup Custom Model    (base URL + model + key — endpoint OpenAI-compatible)"
  echo "  3. Change model          (ubah model instalasi yang ada)"
  echo "  4. Status & model aktif"
  echo "  5. Restart gateway"
  echo "  6. Lihat log"
  echo "  7. Backup               (config, token, skills, memory → backup.zip)"
  echo "  8. Restore              (pulihkan dari backup.zip — untuk VPS baru)"
  echo "  9. Keluar"
  echo
  read -rp "Pilih [1-9]: " MAIN || { echo; c_ok "Keluar."; exit 0; }
  case "$MAIN" in
    1) setup_deepseek ;;
    2) setup_custom ;;
    3) change_model ;;
    4) status_and_model ;;
    5) restart_gateway ;;
    6) view_logs ;;
    7) backup_all ;;
    8) restore_all ;;
    9|q|Q) c_ok "Keluar."; exit 0 ;;
    *) c_err "Pilihan tidak valid (1-9)." ;;
  esac
  echo
  read -rp "Tekan ENTER untuk kembali ke menu..." _
done
