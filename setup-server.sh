#!/usr/bin/env bash
set -euo pipefail

SWAPFILE="/swapfile1"
SWAPSIZE="2G"
NODE_DIR="/opt/remnanode"
COMPOSE_FILE="$NODE_DIR/docker-compose.yml"

# перезапуск раз в сутки
CRON_FILE="/etc/cron.d/remnanode-restart"
RESTART_TIME="30 4"          # минуты часы (4:30)
RESTART_TZ="Europe/Moscow"   # таймзона для расписания

# отключение icmp-пинга
SYSCTL_FILE="/etc/sysctl.d/99-disable-ping.conf"

# --- проверка прав -----------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Скрипт нужно запускать от root: sudo bash $0"
    exit 1
fi

# --- 1. Docker ---------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
    echo "[1/6] Docker уже установлен: $(docker --version)"
else
    echo "[1/6] Устанавливаю Docker..."
    curl -fsSL https://get.docker.com | sh
fi

# --- 2. Swapfile -------------------------------------------------------------
echo "[2/6] Настраиваю swap..."

if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
    echo "      $SWAPFILE уже активен, пропускаю"
else
    if [[ -f "$SWAPFILE" ]]; then
        echo "      $SWAPFILE уже существует, переиспользую"
    else
        echo "      Создаю $SWAPFILE размером $SWAPSIZE"
        fallocate -l "$SWAPSIZE" "$SWAPFILE" \
            || dd if=/dev/zero of="$SWAPFILE" bs=1M count=2048 status=progress
    fi
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
    swapon "$SWAPFILE"
fi

# автоподключение после перезагрузки
if grep -q "^[[:space:]]*$SWAPFILE[[:space:]]" /etc/fstab; then
    echo "      Запись в /etc/fstab уже есть"
else
    # гарантируем перевод строки в конце файла перед дозаписью
    [[ -s /etc/fstab && -n "$(tail -c1 /etc/fstab)" ]] && echo >> /etc/fstab
    echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
    echo "      Добавил запись в /etc/fstab"
fi

swapon --show

# --- 3. Директория -----------------------------------------------------------
echo "[3/6] Создаю директорию $NODE_DIR"
mkdir -p "$NODE_DIR"
cd "$NODE_DIR"

# --- 4. docker-compose.yml ---------------------------------------------------
if [[ -s "$COMPOSE_FILE" ]]; then
    echo "[4/6] $COMPOSE_FILE уже заполнен, не трогаю"
else
    echo "[4/6] Создаю пустой $COMPOSE_FILE"
    touch "$COMPOSE_FILE"
fi

# --- 5. Ежедневный перезапуск контейнеров ------------------------------------
echo "[5/6] Настраиваю ежедневный перезапуск"

# файл с фиксированным именем перезаписывается целиком -> дублей не возникает
cat > "$CRON_FILE" << EOF
# Ежедневный перезапуск remnanode. Файл создан setup-server.sh, правки будут перезаписаны.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
CRON_TZ=$RESTART_TZ

$RESTART_TIME * * * root cd $NODE_DIR && docker compose restart >/dev/null 2>&1
EOF

chmod 644 "$CRON_FILE"
chown root:root "$CRON_FILE"

# cron должен быть установлен и запущен, иначе задание просто не выполнится
if ! systemctl list-unit-files 2>/dev/null | grep -qE '^(cron|crond)\.service'; then
    echo "      cron не установлен, ставлю..."
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cron
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q cronie
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q cronie
    fi
fi

for svc in cron crond; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^$svc\.service"; then
        systemctl enable --now "$svc" >/dev/null 2>&1 || true
        break
    fi
done

echo "      Задание записано в $CRON_FILE"

# --- 6. Отключение icmp-пинга ------------------------------------------------
echo "[6/6] Отключаю ответы на icmp-пинг"

# drop-in перезаписывается целиком -> идемпотентно
cat > "$SYSCTL_FILE" << 'EOF'
# Не отвечать на icmp echo (ping). Файл создан setup-server.sh.
net.ipv4.icmp_echo_ignore_all = 1
net.ipv6.icmp.echo_ignore_all = 1
EOF

chmod 644 "$SYSCTL_FILE"

# применяем сразу; ipv6-ключа может не быть, если ipv6 выключен -> не падаем
sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
sysctl -w net.ipv4.icmp_echo_ignore_all=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.icmp.echo_ignore_all=1 >/dev/null 2>&1 || true

echo "      Сервер больше не отвечает на ping"

echo
echo "Готово. Теперь можно заполнить конфиг:"
echo "  vim $COMPOSE_FILE"
echo "Затем поднять стек:"
echo "  cd $NODE_DIR && docker compose up -d"
