#!/bin/bash
# Easy-CF-Tunnel v1.0
# Аналог easy-vk-tunnel.sh, но через Cloudflare Free (cloudflared + R2/GitHub Pages)

CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
CONFIG_DIR="$HOME/.easy-cf-tunnel"
CONFIG_FILE="$CONFIG_DIR/config.env"
SUB_FILE="$CONFIG_DIR/sub.txt"
CRON_JOB="$CONFIG_DIR/watchdog.sh"

mkdir -p "$CONFIG_DIR"

# =============== ФУНКЦИИ ===================

ask_input() {
    read -rp "$1: " val
    echo "$val"
}

install_deps() {
    echo "[*] Установка зависимостей..."
    sudo apt update -y
    sudo apt install -y awscli jq curl
    if [ ! -f "$CLOUDFLARED_BIN" ]; then
        sudo curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o $CLOUDFLARED_BIN
        sudo chmod +x $CLOUDFLARED_BIN
    fi
}

create_config() {
    UUID=$(ask_input "Введите UUID для VLESS")
    PORT=$(ask_input "Введите локальный порт inbound (например 1180)")
    PATH_WS=$(ask_input "Введите path для WebSocket (например /ws)")
    SUB_NAME=$(ask_input "Введите имя подписки (sub.txt)")

    echo "[*] Настройка Cloudflare R2 или GitHub Pages?"
    echo "1) Cloudflare R2 (через S3)"
    echo "2) GitHub Pages (raw)"
    read -rp "Ваш выбор [1/2]: " STORE_TYPE

    if [ "$STORE_TYPE" = "1" ]; then
        BUCKET=$(ask_input "Введите имя R2 bucket")
        ACCOUNT_ID=$(ask_input "Введите ваш Cloudflare account_id")
        AWS_KEY=$(ask_input "Введите R2 access key ID")
        AWS_SECRET=$(ask_input "Введите R2 secret key")
    else
        GITHUB_REPO=$(ask_input "Введите GitHub репо (user/repo)")
        GITHUB_TOKEN=$(ask_input "Введите GitHub token (с правами push)")
    fi

    cat > "$CONFIG_FILE" <<EOF
UUID=$UUID
PORT=$PORT
PATH_WS=$PATH_WS
SUB_NAME=$SUB_NAME
STORE_TYPE=$STORE_TYPE
BUCKET=$BUCKET
ACCOUNT_ID=$ACCOUNT_ID
AWS_KEY=$AWS_KEY
AWS_SECRET=$AWS_SECRET
GITHUB_REPO=$GITHUB_REPO
GITHUB_TOKEN=$GITHUB_TOKEN
EOF

    echo "[*] Конфиг сохранён: $CONFIG_FILE"
}

start_tunnel() {
    source "$CONFIG_FILE"
    echo "[*] Запуск cloudflared tunnel..."
    nohup $CLOUDFLARED_BIN tunnel --url http://127.0.0.1:$PORT --no-autoupdate > $CONFIG_DIR/cf.log 2>&1 &
    sleep 5
    CF_DOMAIN=$(grep -o 'https://.*\.cfargotunnel.com' $CONFIG_DIR/cf.log | head -n1 | sed 's#https://##')
    echo "[*] Домен туннеля: $CF_DOMAIN"
    generate_sub "$CF_DOMAIN"
    upload_sub
}

generate_sub() {
    source "$CONFIG_FILE"
    DOMAIN=$1
    VLESS_URI="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&sni=$DOMAIN&type=ws&host=$DOMAIN&path=$PATH_WS#$SUB_NAME"
    echo "$VLESS_URI" > "$SUB_FILE"
    echo "[*] Подписка создана: $SUB_FILE"
}

upload_sub() {
    source "$CONFIG_FILE"
    if [ "$STORE_TYPE" = "1" ]; then
        echo "[*] Загрузка в Cloudflare R2..."
        AWS_ACCESS_KEY_ID=$AWS_KEY AWS_SECRET_ACCESS_KEY=$AWS_SECRET \
        aws s3 cp "$SUB_FILE" s3://$BUCKET/$SUB_NAME \
            --endpoint-url=https://$ACCOUNT_ID.r2.cloudflarestorage.com
        echo "URL подписки: https://$ACCOUNT_ID.r2.cloudflarestorage.com/$BUCKET/$SUB_NAME"
    else
        echo "[*] Загрузка в GitHub Pages..."
        TMP_DIR=$(mktemp -d)
        cd $TMP_DIR || exit
        git init
        git remote add origin https://$GITHUB_TOKEN@github.com/$GITHUB_REPO.git
        git checkout -b main
        cp "$SUB_FILE" index.html
        git add index.html
        git commit -m "update sub"
        git push -f origin main
        cd - >/dev/null
        echo "URL подписки: https://$(echo $GITHUB_REPO | cut -d'/' -f1).github.io/$(echo $GITHUB_REPO | cut -d'/' -f2)/"
    fi
}

create_watchdog() {
    source "$CONFIG_FILE"
    cat > "$CRON_JOB" <<EOF
#!/bin/bash
if ! pgrep -x cloudflared >/dev/null; then
    $0 --start
fi
EOF
    chmod +x "$CRON_JOB"
    (crontab -l 2>/dev/null; echo "* * * * * $CRON_JOB") | crontab -
    echo "[*] Watchdog добавлен в cron"
}

uninstall_all() {
    crontab -l | grep -v "$CRON_JOB" | crontab -
    rm -rf "$CONFIG_DIR"
    pkill cloudflared
    echo "[*] Удалено."
}

# =============== ОСНОВНАЯ ЛОГИКА ===================

case "$1" in
    --install)
        install_deps
        create_config
        start_tunnel
        create_watchdog
        ;;
    --start)
        start_tunnel
        ;;
    --uninstall)
        uninstall_all
        ;;
    *)
        echo "Использование: $0 --install | --start | --uninstall"
        ;;
esac
