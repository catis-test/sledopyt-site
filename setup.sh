#!/bin/bash
# Настройка сервера «Следопыт»: раздача сайта, туннель наружу, авто-обновление.
# Запускать от root: bash /opt/sledopyt-site/setup.sh
#
# Что делает:
#   1. настраивает nginx на раздачу site/ из этого репозитория
#   2. оформляет cloudflared системной службой (поднимается после перезагрузки)
#   3. заводит задание: раз в минуту забирать свежую версию из репозитория
#
# Запускать можно повторно — всё перезаписывается заново.

set -u

REPO=/opt/sledopyt-site
SITE=$REPO/site
LOG=/var/log/cloudflared.log
GREEN=$'\033[32m'; RED=$'\033[31m'; OFF=$'\033[0m'

say()  { echo "${GREEN}==>${OFF} $*"; }
fail() { echo "${RED}ОШИБКА:${OFF} $*"; exit 1; }

[ "$(id -u)" = "0" ] || fail "нужны права root"
[ -d "$SITE" ]       || fail "нет папки $SITE — репозиторий склонирован не в /opt?"
command -v nginx >/dev/null       || fail "nginx не установлен"
command -v cloudflared >/dev/null || fail "cloudflared не установлен"
command -v git >/dev/null         || fail "git не установлен"

# ---------- 1. nginx ----------
say "настраиваю nginx"
cat > /etc/nginx/sites-available/sledopyt <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root $SITE;
    index index.html;

    # проект учебный, в поиске ему делать нечего
    add_header X-Robots-Tag "noindex, nofollow" always;

    # в логи не пишем адреса посетителей
    access_log off;

    # Пульт (админский дашборд): своя программа на 127.0.0.1:8000 —
    # тот же процесс, что и API бота (см. project/dashboard/). Пароль
    # и вся логика внутри неё, nginx только передаёт запрос дальше.
    location /dashboard {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINX

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/sledopyt /etc/nginx/sites-enabled/sledopyt
nginx -t >/dev/null 2>&1 || fail "конфигурация nginx не прошла проверку"
systemctl reload nginx || systemctl restart nginx
say "nginx раздаёт $SITE"

# ---------- 2. туннель как служба ----------
say "оформляю туннель службой"
pkill -f "cloudflared tunnel" 2>/dev/null && sleep 2

cat > /etc/systemd/system/sledopyt-tunnel.service <<UNIT
[Unit]
Description=Cloudflare tunnel для сайта «Следопыт»
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --url http://localhost:80 --logfile $LOG
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
UNIT

: > "$LOG"
systemctl daemon-reload
systemctl enable --now sledopyt-tunnel >/dev/null 2>&1
say "служба туннеля запущена"

# ---------- 3. авто-обновление ----------
say "завожу авто-обновление раз в минуту"
cat > /etc/cron.d/sledopyt-pull <<CRON
# Раз в минуту забираем свежую версию сайта из репозитория.
* * * * * root cd $REPO && git pull --quiet 2>/dev/null
CRON
chmod 644 /etc/cron.d/sledopyt-pull
say "авто-обновление настроено"

# ---------- 4. адрес ----------
echo
say "жду адрес туннеля (до 40 секунд)"
URL=""
for i in $(seq 1 20); do
    sleep 2
    URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG" 2>/dev/null | head -1)
    [ -n "$URL" ] && break
done

echo
echo "=============================================="
if [ -n "$URL" ]; then
    echo "  ГОТОВО. Сайт доступен по адресу:"
    echo
    echo "  $URL"
else
    echo "  Настройка завершена, но адрес пока не появился."
    echo "  Посмотреть позже:  grep trycloudflare $LOG"
fi
echo "=============================================="
echo
echo "Проверить состояние:   systemctl status sledopyt-tunnel"
echo "Посмотреть адрес:      grep trycloudflare $LOG"
echo "Обновление сайта:      git push в этот репозиторий, сервер подхватит за минуту"
