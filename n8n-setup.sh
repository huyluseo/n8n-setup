#!/usr/bin/env bash
# n8n-setup.sh v4 FIXED – n8n + Docker + PostgreSQL + Nginx + SSL  (Ubuntu 22.04)
# -------------------------------------------------------------------

set -Eeuo pipefail
trap 'echo -e "\n\033[0;31m[ERROR]\033[0m Lỗi ở dòng $LINENO – dừng script."; exit 1' ERR

wait_for_apt() {
  local lock=/var/lib/dpkg/lock-frontend waited=0
  while fuser "$lock" &>/dev/null; do
    (( waited == 0 )) && echo -e "\033[0;33m[INFO]\033[0m apt đang bận – theo dõi tiến trình:"

    # Lấy PID đầu tiên giữ lock
    read -r pid _ < <(lsof -t "$lock" | head -n1)

    if [[ -n $pid ]]; then
      cmd=$(ps -p "$pid" -o cmd= 2>/dev/null | cut -c1-40)
      printf "\r🕒  Đã chờ %3d s | PID %-5s: %-40s" "$waited" "$pid" "$cmd"
    else
      printf "\r🕒  Đã chờ %3d s | PID ?: (đang xác định)          " "$waited"
    fi

    sleep 5
    (( waited+=5 ))
    if (( waited >= 300 )); then
      echo -e "\n\033[0;31m[ERROR]\033[0m Chờ 5 phút nhưng apt vẫn khóa – thoát!"
      exit 1
    fi
  done
  echo -e "\n\033[0;32m[OK]\033[0m apt đã sẵn sàng."
}


### ───── 0. UPDATE & UPGRADE HỆ THỐNG ──────────────────────────────────── ###
echo -e "\n\033[0;34m[STEP] Cập nhật & nâng cấp hệ thống …\033[0m"
wait_for_apt
apt update -qq
wait_for_apt
apt upgrade -y -qq   # bạn có thể bỏ -qq nếu muốn xem chi tiết

### ───── 1. LẤY INPUT ─────────────────────────────────────────────────── ###
read -rp "➤ Domain dùng cho n8n (vd: n8n.example.com): " DOMAIN
while [[ -z $DOMAIN ]];  do read -rp "  Bạn chưa nhập – thử lại: " DOMAIN; done
read -rp "➤ Email đăng ký SSL: " EMAIL
while [[ -z $EMAIL ]];   do read -rp "  Bạn chưa nhập – thử lại: " EMAIL; done
read -rp "➤ PostgreSQL user   (mặc định: n8n_user): " DB_USER
DB_USER=${DB_USER:-n8n_user}
read -rp "➤ PostgreSQL database (mặc định: n8n_db): " DB_NAME
DB_NAME=${DB_NAME:-n8n_db}
read -rsp "➤ PostgreSQL password (enter = random): " DB_PASS; echo
[[ -z $DB_PASS ]] && DB_PASS=$(openssl rand -base64 16) &&
  echo "  • Password tự tạo: $DB_PASS"

### ───── 2. CÀI GÓI CƠ BẢN + NGINX + CERTBOT ─────────────────────────── ###
echo -e "\n\033[0;34m[STEP] Cài gói phụ thuộc…\033[0m"
wait_for_apt; apt install -y -qq software-properties-common ca-certificates curl gnupg lsb-release
wait_for_apt; apt install -y -qq nginx
# snap certbot
snap list core &>/dev/null || snap install core
snap refresh core
snap list certbot &>/dev/null || snap install --classic certbot
ln -sf /snap/bin/certbot /usr/bin/certbot

### ───── 3. PHÁT HÀNH SSL (STAND-ALONE) ───────────────────────────────── ###
if [[ ! -e /etc/letsencrypt/live/"$DOMAIN"/fullchain.pem ]]; then
  echo -e "\n\033[0;34m[STEP] Phát hành SSL cho $DOMAIN…\033[0m"
  systemctl stop nginx
  certbot certonly --standalone -d "$DOMAIN" -m "$EMAIL" \
    --agree-tos --non-interactive --keep-until-expiring
  systemctl start nginx
fi

### ───── 4. CẤU HÌNH NGINX ─────────────────────────────────────────────── ###
echo -e "\n\033[0;34m[STEP] Tạo vHost Nginx…\033[0m"
cat >/etc/nginx/sites-available/$DOMAIN <<NGINX
server {
  listen 80;
  server_name $DOMAIN;
  return 301 https://\$host\$request_uri;
}
server {
  listen 443 ssl http2;
  server_name $DOMAIN;

  ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers on;
  add_header Strict-Transport-Security "max-age=63072000" always;

  location / {
    proxy_pass http://127.0.0.1:5678;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    client_max_body_size 50m;
  }
}
NGINX
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

### ───── 5. KHÔNG CÀI POSTGRESQL TRÊN HOST (SỬ DỤNG DOCKER) ────────────── ###
echo -e "\n\033[0;34m[STEP] PostgreSQL sẽ chạy trong Docker container…\033[0m"

### ───── 6. CÀI DOCKER & COMPOSE ───────────────────────────────────────── ###
echo -e "\n\033[0;34m[STEP] Cài Docker (repo chính thức)…\033[0m"

wait_for_apt
apt-get install -y -qq \
  ca-certificates curl gnupg lsb-release

# Thêm kho Docker
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

wait_for_apt
apt-get update -qq

# Cài engine + buildx + compose plugin
wait_for_apt
apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
                      docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker
echo "  • Docker $(docker --version)"
echo "  • Compose $(docker compose version)"

### ───── 7. TẠO FILE COMPOSE & KHỞI CHẠY ───────────────────────────────── ###
APP=/opt/n8n; mkdir -p "$APP"/{data,compose}; chown -R 1000:1000 "$APP"
cat >"$APP/compose/.env" <<ENV
DOMAIN=$DOMAIN
WEBHOOK_URL=https://$DOMAIN/
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=$(openssl rand -hex 12)
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=$DB_NAME
DB_POSTGRESDB_USER=$DB_USER
DB_POSTGRESDB_PASSWORD=$DB_PASS
GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
ENV

cat >"$APP/compose/docker-compose.yml" <<COMPOSE
services:
  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    restart: unless-stopped
    env_file: .env
    ports: ["127.0.0.1:5678:5678"]
    volumes: ["../data:/home/node/.n8n"]
    depends_on: 
      postgres:
        condition: service_healthy
    networks:
      - n8n-network

  postgres:
    image: postgres:15-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASS}
    volumes: 
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - n8n-network

volumes: 
  pgdata:

networks:
  n8n-network:
    driver: bridge
COMPOSE

echo -e "\n\033[0;34m[STEP] Khởi chạy n8n…\033[0m"
cd "$APP/compose" && docker compose up -d

# Chờ database sẵn sàng
echo -e "\n\033[0;34m[INFO] Chờ PostgreSQL khởi động hoàn tất…\033[0m"
sleep 10

# Kiểm tra logs
echo -e "\n\033[0;34m[INFO] Kiểm tra trạng thái services…\033[0m"
docker compose ps
docker compose logs --tail=20 postgres
docker compose logs --tail=20 n8n

### ───── 8. TÓM TẮT ────────────────────────────────────────────────────── ###
cat <<EOF

╔═════════════════════════════════════════════╗
║   🚀  N8N ĐÃ SẴN SÀNG TRÊN https://$DOMAIN  ║
╠═════════════════════════════════════════════╣
║ Basic-auth user : admin                     ║
║ Basic-auth pass : $(grep N8N_BASIC_AUTH_PASSWORD "$APP/compose/.env" | cut -d= -f2) ║
║ DB  : $DB_NAME • User : $DB_USER            ║
║ DB Pass : $DB_PASS                          ║
╚═════════════════════════════════════════════╝

Data dir   : $APP/data  
Compose    : $APP/compose/docker-compose.yml  

Lệnh hữu ích:
  cd $APP/compose
  docker compose logs -f        # Xem logs
  docker compose restart n8n    # Khởi động lại n8n
  docker compose down           # Dừng services
  docker compose up -d          # Khởi động services

Chúc bạn làm việc hiệu quả! 🎉
EOF
