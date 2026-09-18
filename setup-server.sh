#!/usr/bin/env bash
set -euo pipefail

SWAPFILE="/swapfile1"
SWAPSIZE="2G"
NODE_DIR="/opt/remnanode"
COMPOSE_FILE="$NODE_DIR/docker-compose.yml"

# --- проверка прав -----------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Скрипт нужно запускать от root: sudo bash $0"
    exit 1
fi

# --- 1. Docker ---------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
    echo "[1/4] Docker уже установлен: $(docker --version)"
else
    echo "[1/4] Устанавливаю Docker..."
    curl -fsSL https://get.docker.com | sh
fi

# --- 2. Swapfile -------------------------------------------------------------
echo "[2/4] Настраиваю swap..."

if swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"; then
    echo "      $SWAPFILE уже активен, пропускаю"
else
    if [[ ! -f "$SWAPFILE" ]]; then
        echo "      Создаю $SWAPFILE размером $SWAPSIZE"
        fallocate -l "$SWAPSIZE" "$SWAPFILE" \
            || dd if=/dev/zero of="$SWAPFILE" bs=1M count=2048 status=progress
    fi
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
    swapon "$SWAPFILE"
fi

# автоподключение после перезагрузки
if grep -q "^$SWAPFILE[[:space:]]" /etc/fstab; then
    echo "      Запись в /etc/fstab уже есть"
else
    echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
    echo "      Добавил запись в /etc/fstab"
fi

swapon --show

# --- 3. Директория -----------------------------------------------------------
echo "[3/4] Создаю директорию $NODE_DIR"
mkdir -p "$NODE_DIR"
cd "$NODE_DIR"

# --- 4. Пустой docker-compose.yml -------------------------------------------
echo "[4/4] Создаю $COMPOSE_FILE"
touch "$COMPOSE_FILE"

echo
echo "Готово. Теперь можно заполнить конфиг:"
echo "  vim $COMPOSE_FILE"