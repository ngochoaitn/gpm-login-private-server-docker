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
#   1. Cài docker + docker compose + rsync + sshpass (nếu thiếu); nguồn thiếu rsync thì
#      thử cài, không cài được thì copy bằng 'tar qua ssh'.
#   2. (Tuỳ chọn) Mở rộng đĩa LVM để đủ chỗ chứa dữ liệu
#   3. Mở 1 kết nối SSH master tới nguồn (tránh iptables rate-limit trên nguồn)
#   3b. Nếu Docker nguồn đang chạy stack: chỉ DỪNG ở pha chốt (xem bước 6), xong START
#       lại ngay. Nếu Docker nguồn lỗi: copy 'nóng' như cũ.
#   4. Copy thư mục app (docker-compose, .env, config...) nguồn -> đích
#   5. Tự phát hiện & rsync tất cả docker volume của project (giữ nguyên uid/gid).
#      Volume nguồn lấy theo container đang mount thật (kể cả tên cũ '<project>_<key>'),
#      volume đích đặt đúng tên compose hiện tại sẽ dùng (VD 'gpm_login_private_server_*').
#   6. Copy 2 pha: pha 1 copy NÓNG khi nguồn vẫn chạy (phần lớn dữ liệu, không downtime),
#      pha 2 dừng nguồn rồi chỉ đồng bộ phần thay đổi -> downtime nguồn rất ngắn.
#      Đứt mạng: tự mở lại SSH + thử lại rsync, chạy tiếp từ chỗ dừng (RSYNC_RETRIES).
#      Xác minh khi nguồn còn dừng (dry-run rsync = 0 file + so số file).
#   7. docker compose up -d, sửa quyền, kiểm tra health (web/phpmyadmin/mysql)
#
# Cách dùng:
#   chmod +x ubuntu-to-ubuntu.sh
#   sudo ./ubuntu-to-ubuntu.sh           # sẽ hỏi thông tin nguồn
#   # hoặc truyền sẵn qua biến môi trường:
#   sudo SRC_HOST=1.2.3.4 SRC_PASS='xxx' ./ubuntu-to-ubuntu.sh
#   # biến tuỳ chọn: APP_DIR=/root/<thư mục app>  OVERWRITE_DST=yes|no  AUTO_EXPAND_DISK=yes|no
###############################################################################
set -euo pipefail

# ----------------------------- Cấu hình đầu vào ------------------------------
SRC_HOST="${SRC_HOST:-}"          # IP VPS nguồn
SRC_PORT="${SRC_PORT:-}"          # cổng SSH nguồn (trống = sẽ hỏi, mặc định 22)
SRC_USER="${SRC_USER:-}"          # user SSH nguồn (trống = sẽ hỏi, mặc định root)
SRC_PASS="${SRC_PASS:-}"          # mật khẩu SSH nguồn
APP_PARENT="${APP_PARENT:-/root}" # thư mục cha ưu tiên tìm app trên nguồn
# Tên thư mục app mặc định = tên repo chứa script này (…/<repo>/move-server/ubuntu-to-ubuntu.sh),
# nên cùng 1 script dùng được cho cả gpm-login-private-server-docker và gpm-login-global-private-server-docker.
_SELF_REPO="$(basename "$(dirname "$(dirname "$(readlink -f "$0")")")")"
case "$_SELF_REPO" in gpm-login*) _DEF_APP="$_SELF_REPO";; *) _DEF_APP="gpm-login-private-server-docker";; esac
APP_NAME="${APP_NAME:-$_DEF_APP}"  # tên thư mục app mặc định (sẽ tự dò lại)
APP_DIR_OVERRIDE="${APP_DIR:-}"   # nếu đặt sẵn APP_DIR thì bỏ qua bước tự dò
AUTO_EXPAND_DISK="${AUTO_EXPAND_DISK:-ask}"  # yes | no | ask
RSYNC_RETRIES="${RSYNC_RETRIES:-100}"   # số lần thử lại khi rsync bị đứt kết nối (tự chạy tiếp từ chỗ dừng)
RSYNC_BWLIMIT="${RSYNC_BWLIMIT:-}"     # giới hạn băng thông KiB/s (VD 7500). Có nhà mạng cắt luồng SSH chạy ~12MB/s liên tục sau ~45s

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
  local i
  for i in 1 2 3; do
    if rcmd "cd '$APP_DIR' && docker compose start" >/dev/null 2>&1; then
      SRC_STOPPED=0; ok "Đã start lại stack nguồn."; return 0
    fi
    sleep 10
  done
  warn "KHÔNG start lại được stack nguồn! Hãy tự chạy trên nguồn: cd $APP_DIR && docker compose start"
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
          -o ServerAliveInterval=5 -o ServerAliveCountMax=6 -o TCPKeepAlive=yes
          -o IPQoS=throughput -p "$SRC_PORT")
open_master() {
  sshpass -p "$SRC_PASS" ssh "${SSH_OPTS[@]}" \
     -o ControlMaster=yes -o ControlPath="$SOCK" -o ControlPersist=8h \
     -fN "$SRC_USER@$SRC_HOST"
}
# Kết nối master có thể bị nhà mạng cắt giữa chừng -> kiểm tra & mở lại (thử nhiều lần)
ensure_master() {
  ssh -o ControlPath="$SOCK" -O check "$SRC_USER@$SRC_HOST" >/dev/null 2>&1 && return 0
  rm -f "$SOCK"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    open_master >/dev/null 2>&1 && return 0
    sleep 10
  done
  return 1
}
log "Mở kết nối SSH master tới nguồn $SRC_USER@$SRC_HOST:$SRC_PORT (dùng lại 1 kết nối để tránh rate-limit)…"
open_master || die "Không mở được SSH master tới nguồn (sai mật khẩu/cổng hoặc bị chặn)."
ok "Đã mở kết nối master tới nguồn."
RS_E="sshpass -p $(printf %q "$SRC_PASS") ssh -o ControlPath=$SOCK ${SSH_OPTS[*]}"

# Chạy lệnh trên NGUỒN qua kết nối master (tự mở lại nếu master đã chết)
rcmd() {
  ensure_master || { warn "Mất kết nối SSH tới nguồn (đã thử mở lại 10 lần)." >&2; return 255; }
  ssh -o ControlPath="$SOCK" "$SRC_USER@$SRC_HOST" "$@"
}

# rsync nguồn -> đích, tự thử lại khi đứt kết nối (--partial: chạy tiếp từ chỗ dừng)
#   rsync_pull <src/> <dst/> [tham số rsync thêm...]
rsync_pull() {
  local s="$1" d="$2"; shift 2
  local extra=(); [ -n "$RSYNC_BWLIMIT" ] && extra+=(--bwlimit="$RSYNC_BWLIMIT")
  local n=0 rc
  while :; do
    ensure_master || true      # rsync tự kết nối thẳng (sshpass) nếu master chưa mở lại được
    set +e
    rsync -aHAX --numeric-ids --partial --timeout=60 "${extra[@]}" "$@" -e "$RS_E" \
          "$SRC_USER@$SRC_HOST:$s" "$d"
    rc=$?
    set -e
    case "$rc" in
      0)  return 0;;
      24) return 0;;          # file biến mất trong lúc copy nóng -> bình thường
      1|2|4) warn "rsync lỗi tham số/cú pháp (mã $rc) — không thử lại."; return "$rc";;
    esac
    n=$((n+1))
    [ "$n" -le "$RSYNC_RETRIES" ] || { warn "rsync thất bại sau $RSYNC_RETRIES lần thử lại (mã $rc)."; return "$rc"; }
    warn "rsync bị ngắt (mã $rc) — thử lại lần $n/$RSYNC_RETRIES sau 15s (chạy tiếp từ chỗ dừng)…"
    sleep 15
  done
}

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
    "$APP_PARENT/gpm-login-global-private-server-docker"
    "$APP_PARENT/gpm-login-global-private-server"
    "/opt/$APP_NAME"
    "/opt/gpm-login-private-server-docker"
    "/opt/gpm-login-global-private-server-docker"
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

# ------------------ rsync trên NGUỒN (cần ở cả 2 đầu) ----------------------
# Kiểm tra TRƯỚC khi dừng stack nguồn. Thiếu thì thử cài; cài không được (VD root fs
# read-only, không có mạng) thì chuyển sang chế độ 'tar qua ssh' (không cần cài gì trên nguồn).
COPY_MODE="rsync"
if ! rcmd "command -v rsync" >/dev/null 2>&1; then
  warn "Nguồn chưa có rsync — thử cài…"
  rcmd "export DEBIAN_FRONTEND=noninteractive;
        if command -v apt-get >/dev/null; then (apt-get install -y -qq rsync || { apt-get update -qq && apt-get install -y -qq rsync; });
        elif command -v dnf >/dev/null; then dnf install -y -q rsync;
        elif command -v yum >/dev/null; then yum install -y -q rsync; fi" >/dev/null 2>&1 || true
  if rcmd "command -v rsync" >/dev/null 2>&1; then ok "Đã cài rsync trên nguồn."
  else
    COPY_MODE="tar"
    rcmd "command -v tar" >/dev/null 2>&1 || die "Nguồn không có cả rsync lẫn tar — không copy được."
    warn "Không cài được rsync trên nguồn → dùng 'tar qua ssh' (copy toàn bộ, không resume được)."
  fi
fi
command -v pv >/dev/null || _apt pv || true   # hiển thị tiến độ cho chế độ tar (không bắt buộc)

# tar_pull <thư mục nguồn> <thư mục đích>: stream tar nguồn -> đích, giữ uid/gid/quyền/xattr
tar_pull() {
  local s="$1" d="$2" rc
  local showp=(cat); command -v pv >/dev/null && showp=(pv -s "${3:-0}")
  set +e
  rcmd "tar -C '$s' --numeric-owner --xattrs --acls -cpf - ." | "${showp[@]}" \
    | tar -C "$d" --numeric-owner --xattrs --xattrs-include='*' --acls -xpf -
  rc=("${PIPESTATUS[@]}")
  set -e
  # tar nguồn trả 1 = "file changed as we read it" (copy nóng) -> chỉ cảnh báo
  [ "${rc[0]}" -le 1 ] && [ "${rc[1]}" = 0 ] && [ "${rc[2]}" = 0 ] \
    || die "tar copy $s lỗi (mã: ${rc[*]})."
  [ "${rc[0]}" = 1 ] && warn "Có file thay đổi trong lúc copy $s (copy nóng)."
  return 0
}

# --------------- Kiểm tra Docker trên NGUỒN (quyết định dừng hay copy nóng) ---
SRC_DOCKER_OK=0; SRC_WAS_RUNNING=0
if rcmd "docker info" >/dev/null 2>&1; then
  SRC_DOCKER_OK=1
  RUNNING_Q=$(rcmd "cd '$APP_DIR' 2>/dev/null && docker compose ps -q 2>/dev/null" 2>/dev/null || true)
  if [ -n "$RUNNING_Q" ]; then
    SRC_WAS_RUNNING=1
    ok "Docker nguồn OK, stack đang CHẠY → copy nóng trước, chỉ DỪNG ngắn ở pha chốt rồi START lại."
  else
    warn "Docker nguồn OK nhưng stack không chạy → copy trực tiếp (không cần dừng)."
  fi
else
  warn "Docker nguồn KHÔNG hoạt động → copy 'nóng' như hiện tại (không dừng được; DB có thể không nhất quán)."
fi

# ------------------------ Phát hiện volume trên nguồn ------------------------
# Vấn đề cần xử lý: tên volume trên đĩa KHÔNG nhất thiết khớp compose hiện tại.
#   VD nguồn cài bản cũ (volume '<project>_db_data'), sau đó 'git pull' bản mới có
#   'name: gpm_login_private_server_db_data' nhưng chưa recreate → container vẫn
#   dùng volume tên cũ, còn compose thì trỏ tên mới (chưa tồn tại).
# Cách làm: với MỖI khoá volume trong compose:
#   - TÊN ĐÍCH  = tên compose sẽ dùng khi 'up' trên đích (name: nếu có, không thì <project>_<key>)
#   - TÊN NGUỒN = volume container của project ĐANG MOUNT thật (hỏi docker nguồn);
#                 nếu docker nguồn chết → dò trên đĩa các tên có thể, chọn cái có dữ liệu nhiều nhất.
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

# Tên project compose: COMPOSE_PROJECT_NAME (.env) > 'name:' cấp cao nhất > tên thư mục
norm_proj() { echo "$1" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-'; }
PROJ=$(rcmd "grep -E '^COMPOSE_PROJECT_NAME=' '$APP_DIR/.env' 2>/dev/null | tail -1 | cut -d= -f2-" 2>/dev/null | tr -d "\"' \r" || true)
[ -n "$PROJ" ] || PROJ=$(sed -n 's/^name:[ \t]*//p' "$_CTMP" | head -1 | tr -d "\"' \r")
[ -n "$PROJ" ] || PROJ="$APP_NAME"
PROJ=$(norm_proj "$PROJ")
LEGACY_PROJ=$(norm_proj "$APP_NAME")

# Khoá volume + tên đích từ section 'volumes:' cấp cao nhất (in: "key<TAB>name-override")
declare -A DST_OF=() SRC_OF=() SRC_RUN=()
VKEYS=()
while IFS=$'\t' read -r k n; do
  [ -n "$k" ] || continue
  VKEYS+=("$k"); DST_OF[$k]="${n:-${PROJ}_$k}"
done < <(
  awk '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
    /^volumes:[ \t]*$/ { invol=1; next }
    /^[^ \t#]/ { if (invol) invol=0 }                    # dòng cột 0 khác => hết section volumes
    invol {
      if ($0 ~ /^[ \t]+[A-Za-z0-9._-]+:[ \t]*$/) {       # khoá volume: "  ten:" (không gì phía sau)
        k=trim($0); sub(/:$/,"",k); curkey=k; order[++n]=k; name[k]=""; next
      }
      if (curkey!="" && $0 ~ /^[ \t]+name:[ \t]*/) {      # override "name:"
        v=$0; sub(/^[ \t]+name:[ \t]*/,"",v); gsub(/["\047]/,"",v); name[curkey]=trim(v)
      }
    }
    END { for(i=1;i<=n;i++){ k=order[i]; printf "%s\t%s\n", k, name[k] } }
  ' "$_CTMP"
)
rm -f "$_CTMP"

src_has() { rcmd "test -d '$VOL_ROOT/$1/_data'" 2>/dev/null; }
src_bytes() { local b; b=$(rcmd "du -sb '$VOL_ROOT/$1/_data' 2>/dev/null | cut -f1" 2>/dev/null || true); echo "${b:-0}"; }
is_key() { local x; for x in "${VKEYS[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }

if [ "${#VKEYS[@]}" -eq 0 ]; then
  # Fallback: parse không ra gì -> glob theo tên project, giữ nguyên tên ở đích
  warn "Không phân tích được volume từ compose — thử dò theo '${PROJ}_*'."
  while read -r v; do
    [ -n "$v" ] || continue
    k="${v#${PROJ}_}"; VKEYS+=("$k"); DST_OF[$k]="$v"; SRC_OF[$k]="$v"
  done < <(rcmd "ls -d $VOL_ROOT/${PROJ}_*/ 2>/dev/null | xargs -rn1 basename" 2>/dev/null || true)
fi

# (1) Hỏi docker nguồn: container của project đang mount volume nào cho từng khoá
if [ "$SRC_DOCKER_OK" = "1" ] && [ "${#VKEYS[@]}" -gt 0 ]; then
  while IFS=$'\t' read -r v lk running; do
    [ -n "$v" ] || continue
    k=""
    if [ -n "$lk" ] && is_key "$lk"; then k="$lk"
    else
      for x in "${VKEYS[@]}"; do
        if [ "$v" = "${DST_OF[$x]}" ] || [[ "$v" == *"_$x" ]]; then k="$x"; break; fi
      done
    fi
    [ -n "$k" ] || continue
    # ưu tiên volume của container đang CHẠY
    if [ -z "${SRC_OF[$k]:-}" ] || { [ "${SRC_RUN[$k]:-}" != "true" ] && [ "$running" = "true" ]; }; then
      SRC_OF[$k]="$v"; SRC_RUN[$k]="$running"
    fi
  done < <(rcmd "bash -s -- '$PROJ' '$APP_DIR'" 2>/dev/null <<'REMOTE' || true
P="$1"; D="$2"
ids=$( { docker ps -aq --filter "label=com.docker.compose.project=$P"
         docker ps -aq --filter "label=com.docker.compose.project.working_dir=$D"; } | sort -u )
[ -n "$ids" ] || exit 0
for id in $ids; do
  st=$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null)
  docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' "$id" 2>/dev/null |
  while read -r v; do
    [ -n "$v" ] || continue
    k=$(docker volume inspect -f '{{index .Labels "com.docker.compose.volume"}}' "$v" 2>/dev/null)
    [ "$k" = "<no value>" ] && k=""
    printf '%s\t%s\t%s\n' "$v" "$k" "$st"
  done
done
REMOTE
  )
fi

# (2) Khoá nào chưa xác định (hoặc docker nguồn chết) -> dò trên đĩa các tên có thể
for k in "${VKEYS[@]}"; do
  if [ -n "${SRC_OF[$k]:-}" ] && ! src_has "${SRC_OF[$k]}"; then
    warn "Volume '${SRC_OF[$k]}' (khoá $k) không có _data trên đĩa nguồn — dò tên khác."
    SRC_OF[$k]=""
  fi
  [ -n "${SRC_OF[$k]:-}" ] && continue
  best=""; best_b=-1
  for cand in "${DST_OF[$k]}" "${PROJ}_$k" "${LEGACY_PROJ}_$k"; do
    [ "$cand" = "$best" ] && continue
    if src_has "$cand"; then
      b=$(src_bytes "$cand")
      if [ "$b" -gt "$best_b" ]; then best="$cand"; best_b="$b"; fi
    fi
  done
  if [ -n "$best" ]; then SRC_OF[$k]="$best"
  else warn "Bỏ qua khoá volume '$k' (không thấy volume nào trên nguồn: ${DST_OF[$k]} / ${PROJ}_$k)."; fi
done

SRC_KEYS=()
for k in "${VKEYS[@]}"; do [ -n "${SRC_OF[$k]:-}" ] && SRC_KEYS+=("$k"); done
if [ "${#SRC_KEYS[@]}" -eq 0 ]; then
  warn "Các volume hiện có trên nguồn:"
  rcmd "ls -1 $VOL_ROOT 2>/dev/null | grep -vE '^(backingFsBlockDev|metadata.db)$'" 2>/dev/null | sed 's/^/      /' || true
  die "Không tìm thấy volume dữ liệu nào của project trên nguồn."
fi

log "Các volume sẽ chuyển (nguồn -> đích):"
for k in "${SRC_KEYS[@]}"; do
  if [ "${SRC_OF[$k]}" = "${DST_OF[$k]}" ]; then echo "    - ${SRC_OF[$k]}"
  else echo "    - ${SRC_OF[$k]}  ->  ${DST_OF[$k]}   (đổi tên theo compose mới)"; fi
done

# Tổng dung lượng cần chuyển
NEED_BYTES=0
for k in "${SRC_KEYS[@]}"; do
  b=$(src_bytes "${SRC_OF[$k]}")
  NEED_BYTES=$(( NEED_BYTES + ${b:-0} ))
done
NEED_H=$(numfmt --to=iec "$NEED_BYTES" 2>/dev/null || echo "${NEED_BYTES}B")
log "Tổng dung lượng volume cần chuyển: ~$NEED_H"

# Volume đích đã có dữ liệu? (VD đã cài mới trên đích) -> rsync chồng lên sẽ hỏng MySQL
RSYNC_DELETE=()
for k in "${SRC_KEYS[@]}"; do
  d="$VOL_ROOT/${DST_OF[$k]}/_data"
  if [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
    warn "Volume đích '${DST_OF[$k]}' ĐÃ CÓ dữ liệu."
    case "${OVERWRITE_DST:-ask}" in
      yes) a=y;;
      no)  a=n;;
      *)   a=$(ask "Ghi đè các volume đích cho giống hệt nguồn (XOÁ file thừa ở đích)? (y/N)" "N");;
    esac
    [[ "$a" =~ ^[Yy] ]] || die "Dừng để tránh trộn dữ liệu. Xoá volume đích hoặc chạy lại với OVERWRITE_DST=yes."
    RSYNC_DELETE=(--delete); break
  fi
done

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

# ------------------------------ Hàm copy ------------------------------------
ensure_dst_volume() {  # $1 = khoá volume: tạo volume đích, gắn label compose
  local k="$1" dv="${DST_OF[$1]}"
  docker volume create --label "com.docker.compose.project=$PROJ" \
         --label "com.docker.compose.volume=$k" "$dv" >/dev/null 2>&1 || true
  mkdir -p "$VOL_ROOT/$dv/_data"
}
vsrc() { echo "$VOL_ROOT/${SRC_OF[$1]}/_data/"; }
vdst() { echo "$VOL_ROOT/${DST_OF[$1]}/_data/"; }

copy_app() {
  mkdir -p "$APP_DIR"
  if [ "$COPY_MODE" = "rsync" ]; then rsync_pull "$APP_DIR/" "$APP_DIR/"
  else tar_pull "$APP_DIR" "$APP_DIR"; fi
}

# Xác minh 1 volume (gọi khi nguồn ĐANG DỪNG): dry-run rsync phải 0 file + số file khớp
verify_volume() {
  local k="$1" src dst moved ns nd
  src=$(vsrc "$k"); dst=$(vdst "$k")
  ns=$(rcmd "find '$src' | wc -l" || echo "?"); nd=$(find "$dst" | wc -l)
  if [ "$COPY_MODE" = "rsync" ]; then
    moved=$(rsync -aHAX --numeric-ids -n --delete --stats -e "$RS_E" \
          "$SRC_USER@$SRC_HOST:$src" "$dst" 2>/dev/null | awk -F': ' '/Number of regular files transferred/{print $2}' | tr -d ', ' || true)
  else moved=0; fi
  if [ "${moved:-?}" = "0" ] && [ "$ns" = "$nd" ]; then ok "${DST_OF[$k]} OK (số file: $nd, khớp nguồn)"
  else warn "${DST_OF[$k]}: còn ${moved:-?} file khác, nguồn=$ns đích=$nd — kiểm tra lại!"; fi
}

for k in "${SRC_KEYS[@]}"; do ensure_dst_volume "$k"; done

# ----- PHA 1 (chỉ rsync): copy NÓNG khi nguồn vẫn chạy -> phần lớn dữ liệu sang trước -----
# Nguồn không bị downtime trong pha này; đứt mạng thì tự thử lại & chạy tiếp.
if [ "$COPY_MODE" = "rsync" ]; then
  log "PHA 1: copy app + volume khi nguồn VẪN CHẠY (không downtime)…"
  copy_app || die "Copy thư mục app thất bại."
  ok "Đã copy app (compose, .env, config)."
  for k in "${SRC_KEYS[@]}"; do
    log "rsync volume ${SRC_OF[$k]} -> ${DST_OF[$k]} (pha 1, nóng)…"
    rsync_pull "$(vsrc "$k")" "$(vdst "$k")" --delete --info=progress2 \
      || die "rsync pha 1 thất bại cho ${SRC_OF[$k]}. Nguồn vẫn chạy bình thường; chạy lại script sẽ tiếp tục từ chỗ dừng."
  done
fi

# ----------------- Dừng stack NGUỒN (nếu đang chạy) để chốt dữ liệu nhất quán --------
if [ "$SRC_WAS_RUNNING" = "1" ]; then
  log "Dừng stack trên NGUỒN để chốt dữ liệu nhất quán…"
  if rcmd "cd '$APP_DIR' && docker compose stop" >/dev/null 2>&1; then
    SRC_STOPPED=1; ok "Đã dừng stack nguồn (sẽ start lại ngay sau khi chốt xong)."
  else
    warn "Không dừng được stack nguồn — tiếp tục copy 'nóng' (DB có thể không nhất quán)."
  fi
fi

# ----- PHA 2: chốt (rsync: chỉ phần thay đổi từ pha 1 -> nhanh; tar: copy toàn bộ) -----
if [ "$COPY_MODE" = "rsync" ]; then
  log "PHA 2: đồng bộ phần thay đổi khi nguồn đã dừng…"
  copy_app || die "Copy thư mục app (pha 2) thất bại."
  for k in "${SRC_KEYS[@]}"; do
    log "rsync volume ${SRC_OF[$k]} -> ${DST_OF[$k]} (pha 2, chốt)…"
    rsync_pull "$(vsrc "$k")" "$(vdst "$k")" --delete --info=progress2 \
      || die "rsync pha 2 thất bại cho ${SRC_OF[$k]}."
  done
else
  log "Copy thư mục app nguồn -> đích ($APP_DIR)…"
  copy_app; ok "Đã copy app (compose, .env, config)."
  for k in "${SRC_KEYS[@]}"; do
    log "tar copy volume ${SRC_OF[$k]} -> ${DST_OF[$k]} …"
    # đích chỉ có thể có dữ liệu khi user đã đồng ý ghi đè (xem bước kiểm tra phía trên)
    find "$(vdst "$k")" -mindepth 1 -delete
    tar_pull "$(vsrc "$k")" "$(vdst "$k")" "$(src_bytes "${SRC_OF[$k]}")"
  done
fi

log "Xác minh dữ liệu (nguồn vẫn đang dừng)…"
for k in "${SRC_KEYS[@]}"; do verify_volume "$k"; done

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