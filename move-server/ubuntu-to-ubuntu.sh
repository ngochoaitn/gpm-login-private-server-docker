#!/usr/bin/env bash
###############################################################################
# ubuntu-to-ubuntu.sh
#
# Di chuyển (migrate) GPM Login private server (docker stack + volumes) giữa 2 VPS.
#
# >>> CHẠY SCRIPT NÀY TRÊN VPS ĐÍCH (máy MỚI, còn khoẻ). <<<
#     Script sẽ KÉO (pull) toàn bộ dữ liệu từ VPS NGUỒN sang.
#     Ưu điểm: VPS nguồn chỉ cần đọc (kể cả khi root fs read-only vẫn copy được),
#     không cần cài gì thêm trên nguồn.
#
# Việc script tự làm trên máy đích:
#   1. Cài docker + docker compose + rsync + sshpass (nếu thiếu)
#   2. (Tuỳ chọn) Mở rộng đĩa LVM để đủ chỗ chứa dữ liệu
#   3. Mở 1 kết nối SSH master tới nguồn (tránh iptables rate-limit trên nguồn)
#   3b. Nếu Docker nguồn đang chạy stack: DỪNG stack nguồn trước khi copy (để DB
#       nhất quán), copy xong START lại. Nếu Docker nguồn lỗi: copy 'nóng' như cũ.
#   4. Copy thư mục app (docker-compose, .env, config...) nguồn -> đích
#   5. Tự phát hiện & rsync tất cả docker volume của project (giữ nguyên uid/gid)
#   6. Xác minh lại (rsync pass 2 = 0 byte + so số file)
#   7. docker compose up -d, sửa quyền, kiểm tra health (web/phpmyadmin/mysql)
#
# Cách dùng:
#   chmod +x ubuntu-to-ubuntu.sh
#   sudo ./ubuntu-to-ubuntu.sh           # sẽ hỏi thông tin nguồn
#   # hoặc truyền sẵn qua biến môi trường:
#   sudo SRC_HOST=1.2.3.4 SRC_PASS='xxx' ./ubuntu-to-ubuntu.sh
###############################################################################
set -euo pipefail

# ----------------------------- Cấu hình đầu vào ------------------------------
SRC_HOST="${SRC_HOST:-}"          # IP VPS nguồn
SRC_PORT="${SRC_PORT:-}"          # cổng SSH nguồn (trống = sẽ hỏi, mặc định 22)
SRC_USER="${SRC_USER:-}"          # user SSH nguồn (trống = sẽ hỏi, mặc định root)
SRC_PASS="${SRC_PASS:-}"          # mật khẩu SSH nguồn
APP_PARENT="${APP_PARENT:-/root}" # thư mục cha ưu tiên tìm app trên nguồn
APP_NAME="${APP_NAME:-gpm-login-private-server-docker}"  # tên thư mục app mặc định (sẽ tự dò lại)
APP_DIR_OVERRIDE="${APP_DIR:-}"   # nếu đặt sẵn APP_DIR thì bỏ qua bước tự dò
AUTO_EXPAND_DISK="${AUTO_EXPAND_DISK:-ask}"  # yes | no | ask

SOCK="/tmp/.gpm_migrate_$$.sock"
LOGDIR="/var/log/gpm-migrate"
c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_b="\033[36m"; c_0="\033[0m"
log()  { echo -e "${c_b}[$(date +%H:%M:%S)]${c_0} $*"; }
ok()   { echo -e "${c_g}  ✓ $*${c_0}"; }
warn() { echo -e "${c_y}  ! $*${c_0}"; }
die()  { echo -e "${c_r}  ✗ $*${c_0}" >&2; exit 1; }
ask()  { local p="$1" d="${2:-}" a; if [ -n "$d" ]; then read -rp "$p [$d]: " a; echo "${a:-$d}"; else read -rp "$p: " a; echo "$a"; fi; }

SRC_STOPPED=0   # =1 khi đã DỪNG stack nguồn (để biết có cần start lại không)

# Start lại stack nguồn nếu trước đó ta đã chủ động dừng nó
restart_src_if_needed() {
  [ "$SRC_STOPPED" = "1" ] || return 0
  log "Khởi động lại stack trên NGUỒN…"
  if rcmd "cd '$APP_DIR' && docker compose start" >/dev/null 2>&1; then
    SRC_STOPPED=0; ok "Đã start lại stack nguồn."
  else
    warn "KHÔNG start lại được stack nguồn! Hãy tự chạy trên nguồn: cd $APP_DIR && docker compose start"
  fi
}
cleanup() {
  restart_src_if_needed   # an toàn: nếu script chết sau khi đã dừng nguồn, vẫn bật lại
  ssh -O exit -o ControlPath="$SOCK" "$SRC_USER@$SRC_HOST" 2>/dev/null || true
  rm -f "$SOCK"
}
trap cleanup EXIT

# ------------------------------- Preflight ----------------------------------
[ "$(id -u)" -eq 0 ] || die "Hãy chạy bằng root (sudo)."
mkdir -p "$LOGDIR"

echo -e "${c_b}==== GPM SERVER MIGRATION (chạy trên VPS ĐÍCH, kéo từ nguồn) ====${c_0}"
[ -z "$SRC_HOST" ] && SRC_HOST=$(ask "IP VPS NGUỒN")
[ -z "$SRC_PORT" ] && SRC_PORT=$(ask "Cổng SSH nguồn" "22")
[ -z "$SRC_USER" ] && SRC_USER=$(ask "User SSH nguồn" "root")
if [ -z "$SRC_PASS" ]; then read -rsp "Mật khẩu SSH nguồn: " SRC_PASS; echo; fi
# APP_DIR sẽ được TỰ DÒ trên nguồn sau khi mở SSH (xem khối "Tự dò thư mục app").
[ -z "$SRC_HOST" ] && die "Thiếu IP nguồn."
[ -z "$SRC_PASS" ] && die "Thiếu mật khẩu nguồn."

# --------------------------- Cài công cụ cần thiết ---------------------------
log "Cài công cụ cần thiết (nếu thiếu)…"
export DEBIAN_FRONTEND=noninteractive
need_apt_update=1
_apt() { if [ "$need_apt_update" = 1 ]; then apt-get update -qq >/dev/null 2>&1 || true; need_apt_update=0; fi; apt-get install -y -qq "$@" >/dev/null 2>&1; }
command -v rsync    >/dev/null || _apt rsync
command -v sshpass  >/dev/null || _apt sshpass
command -v curl     >/dev/null || _apt curl
command -v growpart >/dev/null || _apt cloud-guest-utils || true

if ! command -v docker >/dev/null; then
  log "Cài Docker…"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo "$VERSION_CODENAME") stable" \
     > /etc/apt/sources.list.d/docker.list
  apt-get update -qq >/dev/null
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin >/dev/null
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker compose version >/dev/null 2>&1 || die "Thiếu 'docker compose' (plugin v2)."
ok "docker $(docker --version | awk '{print $3}' | tr -d ,) / compose $(docker compose version --short 2>/dev/null)"

# ----------------------- Kết nối SSH master tới nguồn ------------------------
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=25
          -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -p "$SRC_PORT")
log "Mở kết nối SSH master tới nguồn $SRC_USER@$SRC_HOST:$SRC_PORT (dùng lại 1 kết nối để tránh rate-limit)…"
sshpass -p "$SRC_PASS" ssh "${SSH_OPTS[@]}" \
   -o ControlMaster=yes -o ControlPath="$SOCK" -o ControlPersist=8h \
   -fN "$SRC_USER@$SRC_HOST" \
  || die "Không mở được SSH master tới nguồn (sai mật khẩu/cổng hoặc bị chặn)."
ok "Đã mở kết nối master tới nguồn."
RS_E="sshpass -p $(printf %q "$SRC_PASS") ssh -o ControlPath=$SOCK ${SSH_OPTS[*]}"

# Chạy lệnh trên NGUỒN qua kết nối master đã mở (tái dùng, khỏi nhập lại mật khẩu)
rcmd() { ssh -o ControlPath="$SOCK" "$SRC_USER@$SRC_HOST" "$@"; }

# ------------------------ Tự dò thư mục app trên nguồn -----------------------
# (tái dùng master -> không mở TCP mới -> an toàn với rate-limit của nguồn)
log "Dò thư mục app trên nguồn…"
APP_DIR=""
if [ -n "$APP_DIR_OVERRIDE" ]; then
  APP_DIR="$APP_DIR_OVERRIDE"
else
  # thứ tự ưu tiên: tên mặc định -> bản -docker -> bản global -> trong /opt
  CANDIDATES=(
    "$APP_PARENT/$APP_NAME"
    "$APP_PARENT/gpm-login-private-server-docker"
    "$APP_PARENT/gpm-login-global-private-server"
    "/opt/gpm-login-private-server-docker"
    "/opt/gpm-login-global-private-server"
  )
  # 1) ưu tiên thư mục có file compose
  for c in "${CANDIDATES[@]}"; do
    if rcmd "test -f '$c/docker-compose.yml' -o -f '$c/docker-compose.yaml' -o -f '$c/compose.yml' -o -f '$c/compose.yaml'" 2>/dev/null; then
      APP_DIR="$c"; break
    fi
  done
  # 2) nếu chưa thấy, chấp nhận thư mục tồn tại
  if [ -z "$APP_DIR" ]; then
    for c in "${CANDIDATES[@]}"; do
      if rcmd "test -d '$c'" 2>/dev/null; then APP_DIR="$c"; break; fi
    done
  fi
  # 3) vẫn chưa thấy -> quét /opt, /root, /home tìm compose liên quan gpm/login
  if [ -z "$APP_DIR" ]; then
    warn "Chưa thấy ở vị trí mặc định — quét /opt, /root, /home…"
    hit=$(rcmd "find /opt /root /home -maxdepth 3 \( -name docker-compose.y*ml -o -name compose.y*ml \) 2>/dev/null | grep -iE 'gpm|login' | head -1" 2>/dev/null || true)
    [ -n "$hit" ] && APP_DIR="$(dirname "$hit")"
  fi
fi
# 4) vẫn không thấy -> hỏi user nhập đường dẫn (lặp tới khi hợp lệ)
while [ -z "$APP_DIR" ] || ! rcmd "test -d '$APP_DIR'" 2>/dev/null; do
  [ -n "$APP_DIR" ] && warn "Không thấy thư mục '$APP_DIR' trên nguồn."
  warn "Không tự tìm được thư mục app trên nguồn."
  APP_DIR=$(ask "Nhập ĐƯỜNG DẪN TUYỆT ĐỐI thư mục app trên nguồn (chứa docker-compose.yml)")
  [ -z "$APP_DIR" ] && die "Không có đường dẫn — dừng."
done
APP_DIR="${APP_DIR%/}"
APP_NAME="$(basename "$APP_DIR")"
APP_PARENT="$(dirname "$APP_DIR")"
ok "Thư mục app trên nguồn: $APP_DIR (project=$APP_NAME)"

# ------------------------ Phát hiện volume trên nguồn ------------------------
log "Kiểm tra dữ liệu trên nguồn…"
VOL_ROOT="/var/lib/docker/volumes"

# Tìm file compose trên nguồn
SRC_COMPOSE=""
for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
  if rcmd "test -f '$APP_DIR/$f'"; then SRC_COMPOSE="$APP_DIR/$f"; break; fi
done
[ -n "$SRC_COMPOSE" ] || die "Không thấy docker-compose.yml trên nguồn ($APP_DIR)."

# Đọc nội dung compose về (chỉ đọc file → không cần docker daemon nguồn còn sống)
_CTMP=$(mktemp)
rcmd "cat '$SRC_COMPOSE'" > "$_CTMP" 2>/dev/null || { rm -f "$_CTMP"; die "Không đọc được compose trên nguồn."; }

# Giải tên volume ON-DISK từ section 'volumes:' cấp cao nhất của compose:
#   - có 'name:' -> dùng đúng tên đó                (bản global: gpm_login_global_private_server_*)
#   - không có   -> mặc định '<APP_NAME>_<key>'     (bản cũ: gpm-login-private-server-docker_*)
mapfile -t SRC_VOLS < <(
  awk -v app="$APP_NAME" '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
    /^volumes:[ \t]*$/ { invol=1; next }
    /^[^ \t]/ { if (invol) invol=0 }                     # dòng cột 0 khác => hết section volumes
    invol {
      if ($0 ~ /^[ \t]+[A-Za-z0-9._-]+:[ \t]*$/) {       # khoá volume: "  ten:" (không gì phía sau)
        k=trim($0); sub(/:$/,"",k); curkey=k; order[++n]=k; name[k]=""; next
      }
      if (curkey!="" && $0 ~ /^[ \t]+name:[ \t]*/) {      # override "name:"
        v=$0; sub(/^[ \t]+name:[ \t]*/,"",v); gsub(/"/,"",v); name[curkey]=trim(v)
      }
    }
    END { for(i=1;i<=n;i++){ k=order[i]; print (name[k]!="" ? name[k] : app"_"k) } }
  ' "$_CTMP"
)
rm -f "$_CTMP"

# Fallback: parse không ra gì -> quay lại cách cũ (glob theo APP_NAME)
if [ "${#SRC_VOLS[@]}" -eq 0 ]; then
  warn "Không phân tích được volume từ compose — thử dò theo '${APP_NAME}_*'."
  mapfile -t SRC_VOLS < <(rcmd "ls -d $VOL_ROOT/${APP_NAME}_*/ 2>/dev/null | xargs -n1 basename 2>/dev/null" || true)
fi

# Chỉ giữ volume THỰC SỰ có trên đĩa nguồn
_present=()
for v in "${SRC_VOLS[@]}"; do
  [ -n "$v" ] || continue
  if rcmd "test -d '$VOL_ROOT/$v/_data'"; then _present+=("$v")
  else warn "Bỏ qua '$v' (không thấy $VOL_ROOT/$v/_data trên nguồn)."; fi
done
SRC_VOLS=("${_present[@]}")
[ "${#SRC_VOLS[@]}" -gt 0 ] || die "Không tìm thấy volume dữ liệu nào của project trên nguồn."

log "Các volume sẽ chuyển:"; for v in "${SRC_VOLS[@]}"; do echo "    - $v"; done

# Tổng dung lượng cần chuyển (du từng volume đã giải tên)
NEED_BYTES=0
for v in "${SRC_VOLS[@]}"; do
  b=$(rcmd "du -sb '$VOL_ROOT/$v/_data' 2>/dev/null | cut -f1" || echo 0)
  NEED_BYTES=$(( NEED_BYTES + ${b:-0} ))
done
NEED_H=$(numfmt --to=iec "$NEED_BYTES" 2>/dev/null || echo "${NEED_BYTES}B")
log "Tổng dung lượng volume cần chuyển: ~$NEED_H"

# --------------- Kiểm tra Docker trên NGUỒN (quyết định dừng hay copy nóng) ---
SRC_DOCKER_OK=0; SRC_WAS_RUNNING=0
if rcmd "docker info" >/dev/null 2>&1; then
  SRC_DOCKER_OK=1
  RUNNING_Q=$(rcmd "cd '$APP_DIR' 2>/dev/null && docker compose ps -q 2>/dev/null" 2>/dev/null || true)
  if [ -n "$RUNNING_Q" ]; then
    SRC_WAS_RUNNING=1
    ok "Docker nguồn OK, stack đang CHẠY → sẽ DỪNG khi copy để dữ liệu nhất quán, xong START lại."
  else
    warn "Docker nguồn OK nhưng stack không chạy → copy trực tiếp (không cần dừng)."
  fi
else
  warn "Docker nguồn KHÔNG hoạt động → copy 'nóng' như hiện tại (không dừng được; DB có thể không nhất quán)."
fi

# --------------------- (Tuỳ chọn) Mở rộng đĩa trên đích ---------------------
AVAIL_BYTES=$(df --output=avail -B1 / | tail -1 | tr -d ' ')
if [ "$AVAIL_BYTES" -lt $((NEED_BYTES + 5*1024*1024*1024)) ]; then
  warn "Đĩa đích trống ~$(numfmt --to=iec "$AVAIL_BYTES") — có thể KHÔNG đủ cho $NEED_H (+5G dự phòng)."
  do_expand="no"
  case "$AUTO_EXPAND_DISK" in
    yes) do_expand="yes";;
    no)  do_expand="no";;
    *)   a=$(ask "Thử mở rộng đĩa LVM lấp đầy đĩa vật lý? (y/N)" "N"); [[ "$a" =~ ^[Yy] ]] && do_expand="yes";;
  esac
  if [ "$do_expand" = "yes" ]; then
    log "Đang mở rộng đĩa…"
    LV=$(findmnt -no SOURCE /)
    if [[ "$LV" == /dev/mapper/* || "$LV" == /dev/*vg*/* ]]; then
      VG=$(lvs --noheadings -o vg_name "$LV" | xargs)
      PV=$(pvs --noheadings -o pv_name -S vg_name="$VG" | head -1 | xargs)     # vd /dev/sda3
      DISK="/dev/$(lsblk -no pkname "$PV" | head -1)"                           # vd /dev/sda
      PNUM=$(echo "$PV" | grep -o '[0-9]*$')
      growpart "$DISK" "$PNUM" || warn "growpart: không có gì để mở rộng."
      pvresize "$PV"
      lvextend -l +100%FREE "$LV" || warn "lvextend: không còn free."
      resize2fs "$LV"
      ok "Đĩa sau mở rộng: $(df -h / | tail -1 | awk '{print $2" tổng, "$4" trống"}')"
    else
      warn "Root không phải LVM ($LV) — bỏ qua tự mở rộng, hãy tự nới đĩa rồi chạy lại."
    fi
  fi
fi
AVAIL_BYTES=$(df --output=avail -B1 / | tail -1 | tr -d ' ')
[ "$AVAIL_BYTES" -ge "$NEED_BYTES" ] || die "Đĩa đích không đủ chỗ ($(numfmt --to=iec "$AVAIL_BYTES") < $NEED_H). Nới đĩa rồi chạy lại."

# --------------------------- Dừng stack cũ (nếu có) -------------------------
if [ -f "$APP_DIR/docker-compose.yml" ] && docker compose -f "$APP_DIR/docker-compose.yml" ps -q 2>/dev/null | grep -q .; then
  warn "Trên đích đã có stack đang chạy — tạm dừng để đồng bộ dữ liệu."
  (cd "$APP_DIR" && docker compose down) || true
fi

# ----------------- Dừng stack NGUỒN (nếu đang chạy) để copy nhất quán --------
if [ "$SRC_WAS_RUNNING" = "1" ]; then
  log "Dừng stack trên NGUỒN để đồng bộ nhất quán…"
  if rcmd "cd '$APP_DIR' && docker compose stop" >/dev/null 2>&1; then
    SRC_STOPPED=1; ok "Đã dừng stack nguồn (sẽ start lại ngay sau khi copy xong)."
  else
    warn "Không dừng được stack nguồn — tiếp tục copy 'nóng' (DB có thể không nhất quán)."
  fi
fi

# --------------------------- Copy thư mục app -------------------------------
log "Copy thư mục app nguồn -> đích ($APP_DIR)…"
mkdir -p "$APP_DIR"
rsync -aHAX --numeric-ids -e "$RS_E" "$SRC_USER@$SRC_HOST:$APP_DIR/" "$APP_DIR/"
ok "Đã copy app (compose, .env, config)."

# --------------------------- rsync từng volume ------------------------------
rsync_volume() {  # $1 = tên volume
  local v="$1"
  local src="$VOL_ROOT/$v/_data/"
  local dst="$VOL_ROOT/$v/_data/"
  docker volume create "$v" >/dev/null 2>&1 || true   # đăng ký volume với docker (giữ nguyên _data nếu đã có)
  mkdir -p "$dst"
  log "rsync volume $v …"
  rsync -aHAX --numeric-ids --info=progress2 --partial -e "$RS_E" \
        "$SRC_USER@$SRC_HOST:$src" "$dst"
  # Xác minh: pass 2 phải 0 byte, số file khớp
  local moved; moved=$(rsync -aHAX --numeric-ids --stats -e "$RS_E" \
        "$SRC_USER@$SRC_HOST:$src" "$dst" 2>/dev/null | awk -F': ' '/Number of regular files transferred/{print $2}' | tr -d ', ')
  local ns nd
  ns=$(rcmd "find $src | wc -l"); nd=$(find "$dst" | wc -l)
  if [ "${moved:-0}" = "0" ] && [ "$ns" = "$nd" ]; then ok "$v OK (số file: $nd, đồng bộ khớp)"
  else warn "$v: pass2 chuyển thêm ${moved:-?} file, nguồn=$ns đích=$nd — kiểm tra lại!"; fi
}
for v in "${SRC_VOLS[@]}"; do rsync_volume "$v"; done

# --------------- Start lại stack NGUỒN ngay sau khi copy xong ----------------
restart_src_if_needed   # giảm tối đa downtime nguồn (không đợi tới khi đích boot xong)

# --------------------------- Khởi động & kiểm tra ---------------------------
log "Khởi động stack trên đích…"
cd "$APP_DIR"
docker compose up -d
sleep 20

# ----- Tự xác định tên service web / mysql (khác nhau giữa các bản) ----------
SERVICES=$(docker compose config --services 2>/dev/null || true)
WEB_SVC=$(echo "$SERVICES"   | grep -iE 'web'           | head -1 || true)
MYSQL_SVC=$(echo "$SERVICES" | grep -iE 'mysql|mariadb' | head -1 || true)

# Sửa quyền như installer gốc (service web dù tên gì)
WEB_CT=$([ -n "$WEB_SVC" ] && docker compose ps -q "$WEB_SVC" 2>/dev/null || true)
if [ -n "$WEB_CT" ]; then
  docker exec "$WEB_CT" chmod 777 /var/www/html/.env 2>/dev/null || true
  docker exec "$WEB_CT" chmod -R 777 /var/www/html/storage 2>/dev/null || true
fi

# Đọc cổng từ .env
WEB_PORT=$(grep -E '^WEB_PORT=' "$APP_DIR/.env" | cut -d= -f2 | tr -d '"' ); WEB_PORT=${WEB_PORT:-80}
PMA_PORT=$(grep -E '^PMA_PORT=' "$APP_DIR/.env" | cut -d= -f2 | tr -d '"' ); PMA_PORT=${PMA_PORT:-8081}

echo; echo -e "${c_b}==== KIỂM TRA ====${c_0}"
docker compose ps
MY_CT=$([ -n "$MYSQL_SVC" ] && docker compose ps -q "$MYSQL_SVC" 2>/dev/null || true)
[ -n "$MY_CT" ] && { docker exec "$MY_CT" mysqladmin ping 2>/dev/null | grep -q alive && ok "MySQL alive" || warn "MySQL chưa sẵn sàng (chờ thêm rồi kiểm tra lại)"; }
wc=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$WEB_PORT/" || echo 000);  [ "$wc" = 200 ] && ok "Web HTTP $wc (cổng $WEB_PORT)" || warn "Web HTTP $wc"
pc=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PMA_PORT/" || echo 000); [ "$pc" = 200 ] && ok "phpMyAdmin HTTP $pc (cổng $PMA_PORT)" || warn "phpMyAdmin HTTP $pc"

IP=$(hostname -I | awk '{print $1}')
echo; echo -e "${c_g}==== HOÀN TẤT ====${c_0}"
echo "  Web/API   : http://$IP:$WEB_PORT"
echo "  phpMyAdmin: http://$IP:$PMA_PORT"
echo "  Đĩa       : $(df -h / | tail -1 | awk '{print $3" đã dùng / "$2" ("$5")"}')"
echo -e "${c_y}  LƯU Ý:${c_0}"
echo "   • Client GPM phải trỏ về IP mới: $IP"
echo "   • KHÔNG chạy 'php artisan migrate' (giữ nguyên trạng thái DB đã copy)."
echo "   • Kiểm tra dữ liệu rồi mới ngừng/hủy VPS nguồn."