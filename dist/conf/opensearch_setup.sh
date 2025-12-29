#!/usr/bin/env bash
set -euo pipefail

########################################
# 최소 설정
########################################
HTTP_PORT="63160"
ADMIN_USERNAME="admin"
ADMIN_PASSWORD="NewPassword1e3!"   # 운영 전 교체 필수

DISCOVERY_TYPE="single-node"
NETWORK_HOST="127.0.0.1"
TRANSPORT_PORT="9300"

# ✅ OpenSearch 데이터 저장 경로
DATA_PATH="/data/opensearch"

# 힙: XMS_MANUAL 비우면 RAM % 자동 (최대 32g)
XMS_AUTO_PERCENT="50"
XMS_MANUAL=""

CERT_DIR="/etc/opensearch"
ROOT_SUBJ="/C=KR/ST=Seoul/L=Seoul/O=XCURENET/OU=AI/CN=ROOT"
ADMIN_SUBJ="/C=KR/ST=Seoul/L=Seoul/O=XCURENET/OU=AI/CN=A"
NODE_CN="XCURENET"
NODE_SUBJ="/C=KR/ST=Seoul/L=Seoul/O=XCURENET/OU=AI/CN=${NODE_CN}"
OPENSSL_DAYS="730"
SAN_IPS="127.0.0.1,::1,1.225.49.111,15.1.2.100"


ADMIN_DN="CN=A,OU=AI,O=XCURENET,L=Seoul,ST=Seoul,C=KR"
NODE_DN="CN=${NODE_CN},OU=AI,O=XCURENET,L=Seoul,ST=Seoul,C=KR"

OS_YML="/etc/opensearch/opensearch.yml"
JVM_OPT="/etc/opensearch/jvm.options"
SEC_DIR="/etc/opensearch/opensearch-security"
TOOLS_DIR="/usr/share/opensearch/plugins/opensearch-security/tools"
JAVA_HOME="/usr/share/opensearch/jdk"
BACKUP_SUFFIX="$(date +%Y%m%d_%H%M%S)"

########################################
# Helpers
########################################
log(){ printf "\e[1;34m[INFO]\e[0m %s\n" "$*"; }
fail(){ printf "\e[1;31m[ERR]\e[0m %s\n" "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null || fail "$1 not found"; }
pkg_install(){ command -v dnf >/dev/null && sudo dnf -y install "$@" || sudo yum -y install "$@"; }
backup_and_write(){ local p="$1"; [[ -f "$p" ]] && sudo cp -a "$p" "${p}.bak.${BACKUP_SUFFIX}" || true; sudo tee "$p" >/dev/null; }
calc_heap(){
  if [[ -n "${XMS_MANUAL}" ]]; then echo "${XMS_MANUAL}"; return; fi
  local mem_mb="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
  local v=$((mem_mb*XMS_AUTO_PERCENT/100)); ((v>32768)) && v=32768; echo "${v}m"
}
wait_http(){
  local url="$1" user="$2" pass="$3" tries="${4:-120}" sleep_s="${5:-1}" code
  for ((i=1;i<=tries;i++)); do
    code=$(curl -sk -u "$user:$pass" -o /dev/null -w "%{http_code}" "$url" || true)
    [[ "$code" =~ ^(200|3[0-9]{2}|401)$ ]] && return 0
    sleep "$sleep_s"
  done; return 1
}

########################################
# 1) 시스템 준비 (패키지/디렉토리/권한/limits)
########################################
prepare_system(){
  log "Installing OpenSearch & deps ..."
  need curl; need openssl
  command -v jq >/dev/null || pkg_install jq || true
  echo 'DISABLE_INSTALL_DEMO_CONFIG=true' | sudo tee -a /etc/sysconfig/opensearch >/dev/null || true
  pkg_install opensearch

  sudo mkdir -p /etc/opensearch "${DATA_PATH}" /var/lib/opensearch /var/log/opensearch /run/opensearch
  sudo chown -R opensearch:opensearch /etc/opensearch "${DATA_PATH}" /var/lib/opensearch /var/log/opensearch /run/opensearch

  # 커널/리밋 (권장 최소)
  echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-opensearch.conf >/dev/null
  sudo sysctl -p /etc/sysctl.d/99-opensearch.conf >/dev/null || true

  sudo install -d -m0755 /etc/systemd/system/opensearch.service.d
  backup_and_write /etc/security/limits.d/99-opensearch.conf <<'LIM'
opensearch soft nofile 65536
opensearch hard nofile 65536
opensearch soft nproc  4096
opensearch hard nproc  4096
opensearch soft memlock unlimited
opensearch hard memlock unlimited
LIM
  backup_and_write /etc/systemd/system/opensearch.service.d/override.conf <<'OVR'
[Service]
LimitNOFILE=65536
LimitNPROC=4096
LimitMEMLOCK=infinity
Restart=on-failure
RestartSec=5
OVR
  sudo systemctl daemon-reload
}

########################################
# 2) JVM 힙/옵션
########################################
configure_jvm(){
  log "Configuring JVM heap ..."
  sudo cp -a "$JVM_OPT" "${JVM_OPT}.bak.${BACKUP_SUFFIX}" || true
  sudo sed -i -E 's/^-Xms[0-9]+[mg]/# &/; s/^-Xmx[0-9]+[mg]/# &/' "$JVM_OPT"
  local XMS="$(calc_heap)"
  { echo "-Xms${XMS}"; echo "-Xmx${XMS}"; } | sudo tee -a "$JVM_OPT" >/dev/null

  # Java 21 호환 필수 옵션
  grep -q -- '--add-opens=java.base/java.lang=ALL-UNNAMED' "$JVM_OPT" || echo '--add-opens=java.base/java.lang=ALL-UNNAMED' | sudo tee -a "$JVM_OPT" >/dev/null
  echo '--enable-native-access=ALL-UNNAMED' | sudo tee /etc/opensearch/jvm.options.d/99-native-access.options >/dev/null
}

########################################
# 3) 인증서 생성 (자체서명)
########################################
gen_certs(){
  log "Generating TLS certs ..."
  sudo mkdir -p "$CERT_DIR"; pushd "$CERT_DIR" >/dev/null
  sudo rm -f *.pem *.srl || true

  sudo openssl genrsa -out root-ca-key.pem 2048
  sudo openssl req -new -x509 -sha256 -key root-ca-key.pem -subj "${ROOT_SUBJ}" -out root-ca.pem -days "${OPENSSL_DAYS}"

  sudo openssl genrsa -out admin-key.pem 2048
  sudo openssl req -new -key admin-key.pem -subj "${ADMIN_SUBJ}" -out admin.csr
  sudo openssl x509 -req -in admin.csr -CA root-ca.pem -CAkey root-ca-key.pem -CAcreateserial -sha256 -out admin.pem -days "${OPENSSL_DAYS}"

  sudo openssl genrsa -out node1-key.pem 2048
  sudo openssl req -new -key node1-key.pem -subj "${NODE_SUBJ}" -out node1.csr

  local san="subjectAltName = DNS:${NODE_CN}, DNS:localhost"
  IFS=',' read -ra A <<< "$SAN_IPS"; for ip in "${A[@]}"; do san+=", IP:${ip}"; done
  echo "$san" | sudo tee node1.ext >/dev/null
  sudo openssl x509 -req -in node1.csr -CA root-ca.pem -CAkey root-ca-key.pem -CAcreateserial -sha256 -out node1.pem -days "${OPENSSL_DAYS}" -extfile node1.ext

  sudo rm -f admin.csr node1.csr node1.ext
  sudo chown opensearch:opensearch *.pem
  sudo chmod 0640 *.pem; sudo chmod 0600 *-key.pem
  popd >/dev/null
}

########################################
# 4) opensearch.yml (보안/TLS)
########################################
write_opensearch_yml(){
  log "Writing opensearch.yml ..."
  backup_and_write "$OS_YML" <<YML
cluster.name: aegisai
node.name: node-1
network.host: ${NETWORK_HOST}
http.port: ${HTTP_PORT}
transport.port: ${TRANSPORT_PORT}
discovery.type: ${DISCOVERY_TYPE}

path.data: ${DATA_PATH}
path.logs: /var/log/opensearch

bootstrap.memory_lock: true

plugins.security.disabled: false
plugins.security.ssl.transport.pemcert_filepath: ${CERT_DIR}/node1.pem
plugins.security.ssl.transport.pemkey_filepath: ${CERT_DIR}/node1-key.pem
plugins.security.ssl.transport.pemtrustedcas_filepath: ${CERT_DIR}/root-ca.pem
plugins.security.ssl.transport.enforce_hostname_verification: false

plugins.security.ssl.http.enabled: true
plugins.security.ssl.http.pemcert_filepath: ${CERT_DIR}/node1.pem
plugins.security.ssl.http.pemkey_filepath: ${CERT_DIR}/node1-key.pem
plugins.security.ssl.http.pemtrustedcas_filepath: ${CERT_DIR}/root-ca.pem

plugins.security.authcz.admin_dn: [ '${ADMIN_DN}' ]
plugins.security.nodes_dn:       [ '${NODE_DN}' ]
plugins.security.allow_default_init_securityindex: true
plugins.security.audit.type: internal_opensearch
plugins.security.enable_snapshot_restore_privilege: true
plugins.security.check_snapshot_restore_write_privileges: true
plugins.security.restapi.roles_enabled: ["all_access","security_rest_api_access"]
YML
  sudo chown opensearch:opensearch "$OS_YML"
  sudo chmod 0644 "$OS_YML"
}

########################################
# 5) 내부 사용자(admin) 등록
########################################
write_internal_users(){
  log "Preparing internal_users.yml ..."
  local file="${SEC_DIR}/internal_users.yml"
  sudo mkdir -p "$SEC_DIR"
  [[ -f "$file" ]] && sudo cp -a "$file" "${file}.bak.${BACKUP_SUFFIX}" || true

  local hash_raw hash
  if [[ -x "$TOOLS_DIR/hash.sh" ]]; then
    hash_raw=$(OPENSEARCH_JAVA_HOME="$JAVA_HOME" "$TOOLS_DIR/hash.sh" -p "${ADMIN_PASSWORD}" 2>&1 || true)
  else
    sudo chmod +x "$TOOLS_DIR/hash.sh" || true
    hash_raw=$(OPENSEARCH_JAVA_HOME="$JAVA_HOME" "$TOOLS_DIR/hash.sh" -p "${ADMIN_PASSWORD}" 2>&1 || true)
  fi
  hash=$(printf '%s\n' "$hash_raw" | grep -Eo '\$2[aby]\$[^[:space:]]+' | head -1)
  [[ -z "${hash:-}" ]] && { printf '%s\n' "$hash_raw"; fail "bcrypt 생성 실패"; }

  backup_and_write "$file" <<EOF
---
_meta: { type: "internalusers", config_version: 2 }
${ADMIN_USERNAME}:
  hash: "${hash}"
  reserved: true
  backend_roles: [ "admin" ]
  description: "Admin user"
EOF
  sudo chown opensearch:opensearch "$file"
  sudo chmod 0640 "$file"
}

########################################
# 6) 시작 & 보안 초기화
########################################
start_and_secure(){
  log "Starting OpenSearch ..."
  sudo systemctl enable --now opensearch || { sudo journalctl -xeu opensearch.service -n 120 --no-pager || true; fail "opensearch start failed"; }

  log "Waiting for HTTPS ..."
  wait_http "https://127.0.0.1:${HTTP_PORT}" "${ADMIN_USERNAME}" "${ADMIN_PASSWORD}" 180 1 || true

  log "Running securityadmin ..."
  ( cd "$TOOLS_DIR" && sudo -u opensearch OPENSEARCH_JAVA_HOME="$JAVA_HOME" ./securityadmin.sh \
       -cd "$SEC_DIR/" \
       -cacert "$CERT_DIR/root-ca.pem" \
       -cert "$CERT_DIR/admin.pem" \
       -key  "$CERT_DIR/admin-key.pem" \
       -h localhost -p "${HTTP_PORT}" -icl -nhnv ) || true

  # 간단 건강 확인
  curl -ks -u "${ADMIN_USERNAME}:${ADMIN_PASSWORD}" "https://127.0.0.1:${HTTP_PORT}" | jq . 2>/dev/null || true
  curl -ks -u "${ADMIN_USERNAME}:${ADMIN_PASSWORD}" "https://127.0.0.1:${HTTP_PORT}/_cluster/health?wait_for_status=yellow&timeout=60s" | jq . 2>/dev/null || true
  log "✅ Ready: https://127.0.0.1:${HTTP_PORT}"
}

########################################
# Main (정말 필요한 단계만)
########################################
prepare_system
configure_jvm
gen_certs
write_opensearch_yml
write_internal_users
start_and_secure