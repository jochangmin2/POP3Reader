#!/usr/bin/env bash
set -euo pipefail

# =======================
# Configurable variables
# =======================
DB_NAME="AEGISAI"
DB_USER="xcurenet"
DB_USER_PASS="NewPassword1e3!"
ROOT_PASS="NewPassword1e3!"
MYSQL_PORT="63162"
CONFIG_FILE="/etc/my.cnf.d/mariadb-server.cnf"
BACKUP_ON_FIRST_RUN=true   # 첫 실행시만 백업

# 여러 소스 IP/CIDR 허용 (예: 단일 IP, /32, /24 등 혼용 가능)
ALLOW_SOURCES_IPV4=(
  "1.225.49.111"
  "15.1.2.0/24"
)
# 필요 시 IPv6 허용
ALLOW_SOURCES_IPV6=(
  # "2001:db8:1234::/64"
)

# =======================
# Helper functions
# =======================
pkg_install() {
  local pkgs=("$@")
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}"
  else
    yum install -y "${pkgs[@]}"
  fi
}

in_file() {
  local pattern="$1"; local file="$2"
  grep -Eqs "$pattern" "$file"
}

sha_or_empty() {
  local file="$1"
  if [[ -f "${file}" ]]; then sha256sum "${file}" | awk '{print $1}'; else echo ""; fi
}

ensure_section() {
  local section="$1"; local file="$2"
  if ! in_file "^\[${section}\]" "${file}"; then
    echo -e "\n[${section}]" >> "${file}"
  fi
}

# 섹션 끝(다음 섹션 직전)에 "관리 블록" 1개만 유지
write_managed_block() {
  local section="$1"; shift
  local file="$1"; shift
  local content="$*"

  local begin="# BEGIN MANAGED: mariadb-setup.sh [${section}]"
  local end="# END MANAGED: mariadb-setup.sh [${section}]"

  ensure_section "${section}" "${file}"

  awk -v sec="${section}" -v begin="${begin}" -v end="${end}" -v insert="${content}" '
    BEGIN { in_sec=0; inserted=0; in_old_block=0 }
    /^\[[^]]+\]/ {
      if (in_sec && !inserted) { print begin; print insert; print end; inserted=1 }
      in_sec = ($0 == "["sec"]"); in_old_block=0; print; next
    }
    {
      if (in_sec) {
        if ($0 == begin) { in_old_block=1; next }
        if ($0 == end)   { in_old_block=0; next }
        if (!in_old_block) { print }
      } else { print }
    }
    END { if (in_sec && !inserted) { print begin; print insert; print end } }
  ' "${file}" > "${file}.tmp"
  mv "${file}.tmp" "${file}"
}

restart_mariadb_if_changed() {
  local before_hash="$1"; local after_hash
  after_hash="$(sha_or_empty "${CONFIG_FILE}")"
  if [[ "${before_hash}" != "${after_hash}" ]]; then
    systemctl daemon-reload || true
    systemctl enable mariadb --now
    systemctl restart mariadb
  else
    systemctl enable mariadb --now
    systemctl start mariadb
  fi
  systemctl status mariadb --no-pager -l || true
}

add_rich_rule_if_missing() {
  local rule="$1"
  if ! firewall-cmd --permanent --query-rich-rule="${rule}" >/dev/null 2>&1; then
    firewall-cmd --permanent --add-rich-rule="${rule}"
    echo "  - Added: ${rule}"
  else
    echo "  - Exists: ${rule}"
  fi
}

# =======================
# 0) Pre-checks & optional backup (first run only)
# =======================
if [[ ! -f "${CONFIG_FILE}.first-backup" && "${BACKUP_ON_FIRST_RUN}" == "true" && -f "${CONFIG_FILE}" ]]; then
  cp -a "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
  touch "${CONFIG_FILE}.first-backup"
fi

# =======================
# 1) Install MariaDB & basics
# =======================
echo "[1/7] Installing MariaDB server..."
pkg_install mariadb-server policycoreutils-python-utils firewalld || true
systemctl enable mariadb || true
restorecon -Rv /var/lib/mysql || true
systemctl start mariadb

# =======================
# 2) Secure baseline via SQL (idempotent) — root 원격 차단
# =======================
echo "[2/7] Applying secure baseline (no remote root)..."
sudo mysql <<SQL
-- 2-1) 루트: 로컬 전용 계정들(소켓/로컬 TCP/IPv6 로컬)
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${ROOT_PASS}');
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '${ROOT_PASS}';
CREATE USER IF NOT EXISTS 'root'@'::1'       IDENTIFIED BY '${ROOT_PASS}';

GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'::1'       WITH GRANT OPTION;

-- 2-2) 원격 루트 금지: 기존 원격 root 계정 있으면 제거
DROP USER IF EXISTS 'root'@'%';

-- 2-3) 혹시 다른 host의 root가 있으면 정리(로컬/루프백만 허용)
DELETE FROM mysql.user
 WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');

-- 2-4) 익명/테스트 제거
DELETE FROM mysql.user WHERE User='' OR User IS NULL;
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db LIKE 'test\_%';

FLUSH PRIVILEGES;
SQL

MYSQL_CMD=(mysql -uroot -p"${ROOT_PASS}" --protocol=socket)

# =======================
# 3 & 4) Config (mysqld/mariadb/mariadbd) - managed blocks
# =======================
echo "[3/7] Preparing managed config blocks..."
old_hash="$(sha_or_empty "${CONFIG_FILE}")"

# 공통 서버 옵션 블록(포트 포함)
common_block=$(cat <<EOF
port=${MYSQL_PORT}
group_concat_max_len=50240
event_scheduler=ON
max_connections=500
collation-server=utf8mb4_unicode_ci
character-set-server=utf8mb4
init_connect=SET NAMES utf8mb4
init_connect=SET collation_connection=utf8mb4_unicode_ci
skip-character-set-client-handshake
EOF
)

# InnoDB/스토리지 옵션 블록
mariadb_block=$(cat <<'EOF'
innodb_compression_default=ON
innodb_compression_level=9
innodb_file_per_table=1
innodb_compression_algorithm=zlib
EOF
)

# 섹션별 관리 블록 갱신 (중복 누적 X, 섹션 끝에 위치 → 최종 우선)
write_managed_block "mysqld"   "${CONFIG_FILE}" "${common_block}"
write_managed_block "mariadbd" "${CONFIG_FILE}" "${common_block}"
write_managed_block "mariadb"  "${CONFIG_FILE}" "${mariadb_block}"

echo "[4/7] SELinux port allow for ${MYSQL_PORT}..."
if command -v semanage >/dev/null 2>&1; then
  if semanage port -l | awk '{print $1,$3,$4}' | grep -qE "^mysqld_port_t[[:space:]]+tcp[[:space:]]+${MYSQL_PORT}\$"; then
    echo "  - SELinux port already present."
  else
    semanage port -a -t mysqld_port_t -p tcp "${MYSQL_PORT}" 2>/dev/null || \
    semanage port -m -t mysqld_port_t -p tcp "${MYSQL_PORT}" || true
  fi
else
  echo "  - semanage not found; SELinux custom port not configured."
fi

# 설정 변경 시에만 재시작
restart_mariadb_if_changed "${old_hash}"

# =======================
# 5) Create DB & user (idempotent)
# =======================
echo "[5/7] Creating database & application user..."
"${MYSQL_CMD[@]}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_USER_PASS}';
-- 구 커넥터 호환을 위해 native 플러그인 명시
ALTER USER '${DB_USER}'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('${DB_USER_PASS}');
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

# =======================
# 6) Firewall: multi-source allow (idempotent)
# =======================
echo "[6/7] Configuring firewalld..."
systemctl enable firewalld --now || true

for SRC in "${ALLOW_SOURCES_IPV4[@]}"; do
  RULE="rule family=\"ipv4\" source address=\"${SRC}\" port protocol=\"tcp\" port=\"${MYSQL_PORT}\" accept"
  add_rich_rule_if_missing "${RULE}"
done
for SRC in "${ALLOW_SOURCES_IPV6[@]}"; do
  RULE="rule family=\"ipv6\" source address=\"${SRC}\" port protocol=\"tcp\" port=\"${MYSQL_PORT}\" accept"
  add_rich_rule_if_missing "${RULE}"
done

firewall-cmd --reload || true
# (선택) 런타임 즉시 반영
for SRC in "${ALLOW_SOURCES_IPV4[@]}"; do
  firewall-cmd --add-rich-rule="rule family=ipv4 source address=${SRC} port protocol=tcp port=${MYSQL_PORT} accept" >/dev/null 2>&1 || true
done
for SRC in "${ALLOW_SOURCES_IPV6[@]}"; do
  firewall-cmd --add-rich-rule="rule family=ipv6 source address=${SRC} port protocol=tcp port=${MYSQL_PORT} accept" >/dev/null 2>&1 || true
done

# =======================
# 7) Final checks
# =======================
echo "[7/7] Final checks..."
echo " - Version:" && "${MYSQL_CMD[@]}" -e "SELECT VERSION();"
echo " - Port      : ${MYSQL_PORT}"
echo " - Databases :" && "${MYSQL_CMD[@]}" -e "SHOW DATABASES LIKE '${DB_NAME}';"
echo " - Users     :" && "${MYSQL_CMD[@]}" -e "SELECT User, Host FROM mysql.user WHERE User IN ('root','${DB_USER}');"
echo " - Root hosts:" && "${MYSQL_CMD[@]}" -e "SELECT Host FROM mysql.user WHERE User='root' ORDER BY Host;"

echo "All done 🎉"
echo "Root (local only): mariadb -uroot -p"
echo "Remote access     : mariadb -h <SERVER-IP> -P ${MYSQL_PORT} -u ${DB_USER} -p"
