#!/bin/bash
# Разовая настройка сервера под бота «Следопыта».
#
# Запускать в VNC-консоли:   bash /opt/sledopyt-site/setup-bot.sh
#
# Скрипт можно запускать сколько угодно раз — он доделывает то, чего
# не хватает, и ничего не ломает. Ничего длинного набирать не нужно:
# всё, что понадобится, он напечатает на экран, а вы перенесёте это
# в браузер на своём компьютере.
set -uo pipefail

APP_DIR=/opt/sledopyt
KEY_FILE=/opt/sledopyt-secret.key
SSH_KEY=/root/.ssh/sledopyt_deploy
REPO=git@github.com:catis-test/sledopyt.git

echo "=== Nastroyka servera Sledopyt ==="
echo

# ── 1. Ключ, которым сервер читает закрытый репозиторий ──────────────
if [ ! -f "$SSH_KEY" ]; then
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  ssh-keygen -t ed25519 -N "" -C "sledopyt-server" -f "$SSH_KEY" >/dev/null
  echo "Sozdan klyuch dostupa."
fi
grep -q "sledopyt_deploy" /root/.ssh/config 2>/dev/null || cat >> /root/.ssh/config <<CFG
Host github.com
  IdentityFile $SSH_KEY
  StrictHostKeyChecking accept-new
CFG

# ── 2. Пароль, которым расшифровываются секреты ──────────────────────
# Пароль передаётся первым аргументом. Если не передали и его ещё нет —
# создаём свой и печатаем: тогда его надо перенести в GitHub Secrets.
if [ $# -ge 1 ] && [ -n "${1:-}" ]; then
  printf '%s' "$1" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
elif [ ! -f "$KEY_FILE" ]; then
  openssl rand -hex 8 > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  NEED_UPLOAD=1
fi

# ── 3. Что нужно перенести в GitHub ──────────────────────────────────
echo
echo "############################################################"
echo "SHAG 1. Deploy key -> GitHub"
echo "Settings -> Deploy keys -> Add deploy key (read-only):"
echo
cat "$SSH_KEY.pub"
echo
if [ "${NEED_UPLOAD:-0}" = "1" ]; then
  echo "############################################################"
  echo "SHAG 2. Secret DEPLOY_PASSPHRASE -> GitHub"
  echo "Settings -> Secrets and variables -> Actions -> New secret"
  echo "Imya:  DEPLOY_PASSPHRASE"
  echo "Znachenie:"
  echo
  cat "$KEY_FILE"
  echo
  echo "############################################################"
fi
echo

# ── 4. Код проекта ───────────────────────────────────────────────────
if [ ! -d "$APP_DIR/.git" ]; then
  if git clone --quiet "$REPO" "$APP_DIR" 2>/dev/null; then
    echo "Kod skachan."
  else
    echo "Kod poka ne skachan: snachala dobavte deploy key (SHAG 1),"
    echo "potom zapustite etot skript esche raz."
    exit 0
  fi
else
  git -C "$APP_DIR" fetch --quiet origin main && git -C "$APP_DIR" reset --quiet --hard origin/main
  echo "Kod obnovlen."
fi

# ── 5. Службы: приложение и бот ──────────────────────────────────────
cat > /etc/systemd/system/sledopyt-api.service <<UNIT
[Unit]
Description=Sledopyt API
After=network-online.target

[Service]
WorkingDirectory=$APP_DIR/app
ExecStart=/usr/bin/python3 -u api.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/sledopyt-bot.service <<UNIT
[Unit]
Description=Sledopyt Telegram bot
After=network-online.target sledopyt-api.service

[Service]
WorkingDirectory=$APP_DIR/bot_administrator
ExecStart=/usr/bin/python3 -u bot.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

# ── 6. Обновление по таймеру ─────────────────────────────────────────
cat > /etc/cron.d/sledopyt-update <<CRON
*/2 * * * * root /bin/bash $APP_DIR/deploy/update.sh >> /var/log/sledopyt-update.log 2>&1
CRON

systemctl daemon-reload
systemctl enable --quiet sledopyt-api sledopyt-bot

if [ -f "$APP_DIR/deploy/bot.env.enc" ]; then
  bash "$APP_DIR/deploy/update.sh" || true
  echo
  echo "Gotovo. Sostoyanie sluzhb:"
  systemctl is-active sledopyt-api sledopyt-bot
else
  echo
  echo "Sekrety poka ne prishli. Sdelayte SHAG 2, dozhdites zelenogo"
  echo "GitHub Actions i zapustite etot skript esche raz."
fi
