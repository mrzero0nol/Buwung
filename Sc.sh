#!/bin/bash
# ===============================================
#  BUNNY DEPLOY MANAGER - v6.4
#  Author: mrzero0nol
#  Fitur: Nginx Hardening + Real IP Fix + Security Headers
# ===============================================

# --- 1. CONFIG & PERSIAPAN AWAL ---
CONFIG_FILE="/root/.bd_config"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "UPLOAD_LIMIT=\"64M\"" > "$CONFIG_FILE"
fi
source "$CONFIG_FILE"

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

# Cek Root
if [ "$EUID" -ne 0 ]; then echo "Harap jalankan sebagai root (sudo -i)"; exit; fi

# --- 2. INSTALL TOOLS DASAR ---
if ! command -v jq &> /dev/null; then
    echo "Update & Install system tools..."
    apt update -y
    apt install -y curl git unzip zip build-essential ufw software-properties-common mariadb-server bc jq || { echo "Gagal install tools dasar"; exit 1; }
fi

# Firewall Configuration (PENTING untuk Certbot & Akses)
echo "Konfigurasi Firewall (UFW)..."
ufw allow OpenSSH
ufw allow 'Nginx Full'
# Pastikan UFW aktif (optional, force enable bisa memutus koneksi jika ssh port beda, jadi kita allow dulu)
# ufw --force enable

# Service Database & Web Server
if ! systemctl is-active --quiet mariadb; then
    systemctl start mariadb
    systemctl enable mariadb
fi

if ! command -v nginx &> /dev/null; then
    echo "Install Nginx & Certbot..."
    add-apt-repository -y ppa:ondrej/php
    add-apt-repository -y ppa:deadsnakes/ppa
    apt update -y
    apt install -y nginx certbot python3-certbot-nginx || { echo "Gagal install Nginx/Certbot"; exit 1; }
fi

# --- FIX: CLOUDFLARE REAL IP (PENTING) ---
# Agar Nginx mencatat IP asli pengunjung, bukan IP Cloudflare
echo "Konfigurasi Cloudflare Real IP..."
CF_CONF="/etc/nginx/conf.d/cloudflare.conf"
echo "# Cloudflare Real IP" > "$CF_CONF"
for i in $(curl -s https://www.cloudflare.com/ips-v4); do
    echo "set_real_ip_from $i;" >> "$CF_CONF"
done
for i in $(curl -s https://www.cloudflare.com/ips-v6); do
    echo "set_real_ip_from $i;" >> "$CF_CONF"
done
echo "real_ip_header CF-Connecting-IP;" >> "$CF_CONF"

# --- FIX: LONG DOMAIN NAME SUPPORT (NGINX) ---
# Mengatasi error "could not build server_names_hash"
if grep -q "# server_names_hash_bucket_size 64;" /etc/nginx/nginx.conf; then
    sed -i 's/# server_names_hash_bucket_size 64;/server_names_hash_bucket_size 64;/' /etc/nginx/nginx.conf
fi

# Security
if ! command -v fail2ban-client &> /dev/null; then
    apt install -y fail2ban
    if [ -f /etc/fail2ban/jail.conf ]; then
        cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
    fi
    systemctl restart fail2ban
    systemctl enable fail2ban
fi

# Restart Nginx untuk menerapkan perubahan config
systemctl restart nginx

# ==========================================
# 3. GENERATE SCRIPT UTAMA
# ==========================================
cat << 'EOF' > /usr/local/bin/bd
#!/bin/bash
# COLORS
CYAN=$'\e[0;36m'; WHITE=$'\e[1;37m'; GREEN=$'\e[0;32m'; YELLOW=$'\e[1;33m'; RED=$'\e[0;31m'; NC=$'\e[0m'

CONFIG_FILE="/root/.bd_config"
source "$CONFIG_FILE" 2>/dev/null || UPLOAD_LIMIT="64M"

BACKUP_DIR="/root/backups"
mkdir -p $BACKUP_DIR
UPDATE_URL="https://raw.githubusercontent.com/mrzero0nol/Bunny-deploy/main/bdm.sh"

# --- HELPER: PATH FINDER ---
get_site_root() {
    local dom=$1
    local path=$(awk '/root/ && !/^[ \t]*#/ {print $2}' /etc/nginx/sites-available/$dom 2>/dev/null | tr -d ';')
    echo "$path"
}

# --- UI DRAWING ---
get_width() {
    TERM_W=$(tput cols)
    [ -z "$TERM_W" ] && TERM_W=80
    BOX_W=$((TERM_W - 4))
    if [ "$BOX_W" -gt 55 ]; then BOX_W=55; fi
}

draw_line() {
    local type=$1 
    local line=""
    for ((i=0; i<BOX_W; i++)); do line+="─"; done
    if [ "$type" == "1" ]; then echo -e "${CYAN}┌${line}┐${NC}";
    elif [ "$type" == "2" ]; then echo -e "${CYAN}├${line}┤${NC}";
    elif [ "$type" == "3" ]; then echo -e "${CYAN}└${line}┘${NC}"; fi
}

box_center() {
    local text="$1"
    local color="$2"
    local clean_text=$(echo -e "$text" | sed "s/\x1B\[[0-9;]*[a-zA-Z]//g")
    local len=${#clean_text}
    local space_total=$((BOX_W - len))
    [ "$space_total" -lt 0 ] && space_total=0
    local pad_l=$((space_total / 2))
    local pad_r=$((space_total - pad_l))
    local sp_l=""; for ((i=0; i<pad_l; i++)); do sp_l+=" "; done
    local sp_r=""; for ((i=0; i<pad_r; i++)); do sp_r+=" "; done
    echo -e "${CYAN}│${NC}${sp_l}${color}${text}${NC}${sp_r}${CYAN}│${NC}"
}

box_row() {
    local l_txt="$1"
    local r_txt="$2"
    local clean_l=$(echo -e "$l_txt" | sed "s/\x1B\[[0-9;]*[a-zA-Z]//g")
    local clean_r=$(echo -e "$r_txt" | sed "s/\x1B\[[0-9;]*[a-zA-Z]//g")
    local len_l=${#clean_l}
    local len_r=${#clean_r}
    local gap=$((BOX_W - len_l - len_r - 2))
    local sp=""; for ((i=0; i<gap; i++)); do sp+=" "; done
    if [ "$gap" -lt 1 ]; then
        echo -e "${CYAN}│${NC} ${l_txt}"
        echo -e "${CYAN}│${NC} ${r_txt}"
    else
        echo -e "${CYAN}│${NC} ${l_txt}${sp}${r_txt} ${CYAN}│${NC}"
    fi
}

box_input() {
    local label="$1"
    echo -e "${CYAN}┌─ [ ${YELLOW}${label}${CYAN} ]${NC}"
    echo -ne "${CYAN}└─► ${NC}"
    read -r temp_input
    printf -v "$2" '%s' "$temp_input"
}

# --- SYSTEM INFO ---
get_sys_info() {
    RAM=$(free -m | grep Mem | awk '{print $3"/"$2"MB"}')
    SWAP_USED=$(free -m | grep Swap | awk '{print $3}')
    SWAP_TOT=$(free -m | grep Swap | awk '{print $2}')
    if [ "$SWAP_TOT" == "0" ]; then SWAP="0/0 (No Swap)"; else SWAP="${SWAP_USED}/${SWAP_TOT}MB"; fi
    DISK=$(df -h / | awk 'NR==2 {print $3"/"$2}')
    CPU_IDLE=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print $1}')
    CPU_USE=$(echo "100 - $CPU_IDLE" | bc)
    CPU="${CPU_USE}%"
}

# --- MENU HEADER ---
show_header() {
    get_width
    get_sys_info
    clear
    draw_line 1
    box_center "BUNNY DEPLOY MANAGER" "$WHITE"
    box_center "v6.4 (Secured)" "$CYAN"
    draw_line 2
    box_row "RAM : $RAM"  "SWAP: $SWAP"
    box_row "DISK: $DISK" "CPU : $CPU"
    
    draw_line 2
    box_center "--- MAIN MENU ---" "$YELLOW"
    box_row "1. Deploy Wizard"  "4. File Manager"
    box_row "2. Manage Web"     "5. Database"
    box_row "3. App Manager"    "6. Backup"
    
    draw_line 2
    box_center "--- UTILITIES ---" "$YELLOW"
    box_row "7. Cron Job"       "9. Update Tool"
    box_row "8. Upload Limit"   "s. System Health"
    box_row "u. Uninstall"      ""
    
    draw_line 2
    box_center "0. KELUAR (EXIT)" "$RED"
    draw_line 3
}

submenu_header() {
    get_width
    clear
    draw_line 1
    box_center "MENU: $1" "$YELLOW"
    draw_line 2
}

# --- LAZY INSTALLER ---
ensure_php() {
    local ver=$1
    if ! command -v php-fpm$ver &> /dev/null; then
        echo -e "${YELLOW}Install PHP $ver...${NC}"; apt update -y; apt install -y php$ver php$ver-fpm php$ver-mysql php$ver-curl php$ver-xml php$ver-mbstring php$ver-zip php$ver-gd composer
    fi
}
ensure_node() {
    local ver=$1
    CURR=$(node -v 2>/dev/null | cut -d'.' -f1 | tr -d 'v')
    if [ "$CURR" != "$ver" ]; then
        echo -e "${YELLOW}Install Node v$ver...${NC}"; curl -fsSL https://deb.nodesource.com/setup_${ver}.x | bash -; apt install -y nodejs build-essential; npm install -g pm2 yarn
    fi
}
ensure_python() {
    if ! command -v python3-venv &> /dev/null; then
        echo -e "${YELLOW}Install Python Env...${NC}"; apt update -y; apt install -y python3-pip python3-venv python3-dev; if ! command -v pm2 &> /dev/null; then ensure_node "20"; fi
    fi
}
check_php_ver() {
    echo "1. PHP 8.1 | 2. PHP 8.2 | 3. PHP 8.3"; box_input "Pilih (0=Batal)" pv
    case $pv in 1) V="8.1";; 2) V="8.2";; 3) V="8.3";; 0) return 1;; *) V="8.2";; esac
    ensure_php "$V"; PHP_V=$V; return 0
}
check_node_ver() {
    echo "1. v18 | 2. v20 | 3. v22"; box_input "Pilih (0=Batal)" nv
    case $nv in 1) V="18";; 2) V="20";; 3) V="22";; 0) return 1;; *) V="20";; esac
    ensure_node "$V"; return 0
}

# --- UTILITIES ---
system_health() {
    submenu_header "SYSTEM HEALTH"
    echo -ne "Nginx  : "; systemctl is-active --quiet nginx && echo -e "${GREEN}OK${NC}" || echo -e "${RED}DEAD${NC}"
    echo -ne "MariaDB: "; systemctl is-active --quiet mariadb && echo -e "${GREEN}OK${NC}" || echo -e "${RED}DEAD${NC}"
    echo -ne "PM2    : "; command -v pm2 &> /dev/null && echo -e "${GREEN}INSTALLED${NC}" || echo -e "${RED}NOT FOUND${NC}"
    echo ""; read -p "Enter..."
}

set_limit() {
    submenu_header "UPLOAD LIMIT"
    echo "Current: $UPLOAD_LIMIT"
    echo "1. 64M | 2. 128M | 3. 512M | 4. Custom"
    box_input "Pilih" L
    case $L in 1) U="64M";; 2) U="128M";; 3) U="512M";; 4) box_input "Input (e.g 1G)" U ;; esac
    [ ! -z "$U" ] && UPLOAD_LIMIT=$U && echo "UPLOAD_LIMIT=\"$U\"" > "$CONFIG_FILE"
}

update_tool() {
    echo "Mengecek update dari: $UPDATE_URL"
    curl -sL "$UPDATE_URL" -o /tmp/bd_latest
    if grep -q "#!/bin/bash" /tmp/bd_latest; then
        mv /tmp/bd_latest /usr/local/bin/bd
        chmod +x /usr/local/bin/bd
        echo -e "${GREEN}Update Berhasil! Meluncurkan ulang...${NC}"
        sleep 2
        exec bd
    else
        echo -e "${RED}Gagal download. Cek link/koneksi.${NC}"
        read -p "Enter..."
    fi
}

# --- DEPLOY WIZARD (NGINX FIXED) ---
handle_git() {
    local url=$1
    local dir=$2
    if [ -d "$dir" ]; then
        if [ -d "$dir/.git" ]; then
            echo -e "${YELLOW}Direktori ada. Melakukan git pull...${NC}"
            cd "$dir" && git pull
        else
            echo -e "${RED}PERINGATAN: Direktori $dir sudah ada tapi bukan git repo.${NC}"
            echo "1. Backup & Timpa | 2. Batalkan"
            box_input "Pilih" ACT
            if [ "$ACT" == "1" ]; then
                mv "$dir" "${dir}_bak_$(date +%s)"
                git clone "$url" "$dir"
            else
                echo "Deploy dibatalkan."; return 1
            fi
        fi
    else
        git clone "$url" "$dir"
    fi
    chown -R www-data:www-data "$dir"
}

deploy_web() {
    while true; do
        submenu_header "DEPLOY WIZARD"
        box_row "1. HTML Static" "3. Node.js App"
        box_row "2. PHP Web"     "4. Python App"
        box_center "0. Kembali" "$RED"
        draw_line 3
        
        box_input "Pilih Tipe" TYPE
        if [ "$TYPE" == "0" ]; then return; fi
        
        if [ "$TYPE" == "2" ]; then check_php_ver; if [ $? -eq 1 ]; then continue; fi; fi
        if [ "$TYPE" == "3" ]; then check_node_ver; if [ $? -eq 1 ]; then continue; fi; fi
        if [ "$TYPE" == "4" ]; then ensure_python; fi

        box_input "Domain" DOMAIN; box_input "Email SSL" EMAIL
        ROOT="/var/www/$DOMAIN"; CONFIG="/etc/nginx/sites-available/$DOMAIN"
        
        NGINX_OPTS="client_max_body_size ${UPLOAD_LIMIT}; fastcgi_read_timeout 300; error_log /var/log/nginx/error.log warn;"
        SEC_HEADERS="add_header X-Frame-Options \"SAMEORIGIN\"; add_header X-XSS-Protection \"1; mode=block\"; add_header X-Content-Type-Options \"nosniff\";"
        DENY_FILES="location ~ /\.(?!well-known).* { deny all; access_log off; log_not_found off; }"
        PROXY_PARAMS="proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection 'upgrade'; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme;"

        if [ "$TYPE" == "1" ]; then
            box_input "Git URL" GIT; [ ! -z "$GIT" ] && handle_git "$GIT" "$ROOT" || mkdir -p $ROOT
            BLOCK="server { listen 80; server_name $DOMAIN; root $ROOT; index index.html; $SEC_HEADERS $NGINX_OPTS $DENY_FILES location / { try_files \$uri \$uri/ /index.html; } location = /favicon.ico { access_log off; log_not_found off; } location = /robots.txt { access_log off; log_not_found off; } }"
        elif [ "$TYPE" == "2" ]; then
            box_input "Git URL" GIT;
            if [ ! -z "$GIT" ]; then
                handle_git "$GIT" "$ROOT"
                if [ -f "$ROOT/composer.json" ]; then cd "$ROOT" && composer install --no-dev; fi
            else mkdir -p $ROOT; fi
            chown -R www-data:www-data $ROOT
            BLOCK="server { listen 80; server_name $DOMAIN; root $ROOT; index index.php index.html; $SEC_HEADERS $NGINX_OPTS $DENY_FILES location / { try_files \$uri \$uri/ /index.php?\$query_string; } location ~ \.php$ { include snippets/fastcgi-php.conf; fastcgi_pass unix:/run/php/php$PHP_V-fpm.sock; } location = /favicon.ico { access_log off; log_not_found off; } location = /robots.txt { access_log off; log_not_found off; } }"
        elif [ "$TYPE" == "3" ]; then
            box_input "Port (e.g 3000)" PORT; box_input "Git URL" GIT
            if [ ! -z "$GIT" ]; then 
                handle_git "$GIT" "$ROOT"
                if [ -d "$ROOT" ]; then
                    cd $ROOT && npm install; box_input "Start File" S; pm2 start $S --name "$DOMAIN" && pm2 save
                fi
            fi
            BLOCK="server { listen 80; server_name $DOMAIN; $SEC_HEADERS $NGINX_OPTS $DENY_FILES location / { proxy_pass http://localhost:$PORT; $PROXY_PARAMS } }"
        elif [ "$TYPE" == "4" ]; then
            box_input "Port (e.g 5000)" PORT; box_input "Git URL" GIT
            if [ ! -z "$GIT" ]; then 
                handle_git "$GIT" "$ROOT"
                if [ -d "$ROOT" ]; then
                    cd $ROOT; python3 -m venv venv; source venv/bin/activate
                    [ -f "requirements.txt" ] && pip install -r requirements.txt; pip install gunicorn
                    box_input "WSGI (e.g app:app)" W; pm2 start "gunicorn -w 4 -b 127.0.0.1:$PORT $W" --name "$DOMAIN" && pm2 save
                fi
            fi
            BLOCK="server { listen 80; server_name $DOMAIN; $SEC_HEADERS $NGINX_OPTS $DENY_FILES location / { proxy_pass http://localhost:$PORT; $PROXY_PARAMS } }"
        fi

        echo "$BLOCK" > $CONFIG; ln -s $CONFIG /etc/nginx/sites-enabled/ 2>/dev/null
        nginx -t
        if [ $? -eq 0 ]; then
            systemctl reload nginx
            echo -e "${YELLOW}Menjalankan Certbot (SSL)...${NC}"
            certbot --nginx -n -m "$EMAIL" -d "$DOMAIN" --agree-tos
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}Deployment & SSL Sukses!${NC}"
            else
                echo -e "${RED}Gagal Install SSL. Cek Firewall/Cloudflare Mode.${NC}"
                echo -e "${YELLOW}Tips: Matikan Proxy Cloudflare (Orange Cloud) saat install SSL.${NC}"
            fi
        else
            echo -e "${RED}Konfigurasi Nginx Salah. Membatalkan...${NC}"
            rm "$CONFIG" "/etc/nginx/sites-enabled/$(basename $CONFIG)" 2>/dev/null
        fi
        read -p "Enter..."
    done
}

# --- APP MANAGER ---
manage_app() {
    if ! command -v pm2 &> /dev/null; then echo "PM2 belum terinstall."; sleep 1; return; fi
    while true; do
        submenu_header "APP MANAGER"
        box_row "ID  NAME" "STATUS | RAM | CPU"
        draw_line 2
        JSON=$(pm2 jlist)
        COUNT=$(echo $JSON | jq '. | length')
        if [ "$COUNT" == "0" ]; then
            box_center "Tidak ada aplikasi berjalan" "$WHITE"
        else
            while read -r item; do
                ID=$(echo "$item" | jq -r '.pm_id')
                NAME=$(echo "$item" | jq -r '.name' | cut -c 1-15)
                STATUS=$(echo "$item" | jq -r '.pm2_env.status')
                MEM=$(echo "$item" | jq -r '.monit.memory' | awk '{ byte =$1 / 1024 / 1024; print byte "MB" }' | cut -d. -f1 | awk '{print $1"MB"}')
                CPU=$(echo "$item" | jq -r '.monit.cpu')
                if [ "$STATUS" == "online" ]; then S_COLOR="${GREEN}ON${NC}"; else S_COLOR="${RED}OFF${NC}"; fi
                LEFT="$ID $NAME"
                RIGHT="$S_COLOR | $MEM | ${CPU}%"
                box_row "$LEFT" "$RIGHT"
            done <<< "$(echo $JSON | jq -c '.[]')"
        fi
        draw_line 2
        box_row "1. Restart App" "3. Delete App"
        box_row "2. Stop App"    "4. View Logs"
        box_center "0. Kembali" "$RED"
        draw_line 3
        box_input "Pilih" P
        case $P in
            0) return ;;
            1) box_input "ID App" I; pm2 restart $I ;;
            2) box_input "ID App" I; pm2 stop $I ;;
            3) box_input "ID App" I; pm2 delete $I ;;
            4) box_input "ID App" I; pm2 logs $I ;;
        esac
        read -p "Enter..."
    done
}

manage_web() {
    while true; do
        submenu_header "MANAGE WEBSITE"
        for file in /etc/nginx/sites-available/*; do
            [ -e "$file" ] || continue
            domain=$(basename "$file")
            if [ "$domain" == "default" ]; then continue; fi
            if grep -q "proxy_pass" "$file"; then TYPE="${CYAN}APP${NC}"; else TYPE="${YELLOW}WEB${NC}"; fi
            if [ -L "/etc/nginx/sites-enabled/$domain" ]; then STATUS="${GREEN}ON${NC}"; else STATUS="${RED}OFF${NC}"; fi
            box_row "$domain" "$TYPE | $STATUS"
        done
        draw_line 2
        box_row "1. ON/OFF"  "3. Git Pull"
        box_row "2. Hapus"   "0. Kembali"
        draw_line 3
        box_input "Pilih" W
        case $W in
            0) return ;;
            1) box_input "Domain" D; if [ -L "/etc/nginx/sites-enabled/$D" ]; then rm /etc/nginx/sites-enabled/$D; else ln -s /etc/nginx/sites-available/$D /etc/nginx/sites-enabled/; fi; systemctl reload nginx; echo "Done." ;;
            2) box_input "Domain" D; rm /etc/nginx/sites-enabled/$D 2>/dev/null; rm /etc/nginx/sites-available/$D; certbot delete --cert-name $D -n ;;
            3) box_input "Domain" D; R=$(get_site_root "$D"); cd $R && git pull && echo "Updated.";;
        esac
        read -p "Enter..."
    done
}

# --- LAIN-LAIN ---
open_file_manager() {
    if ! command -v mc &> /dev/null; then apt install -y mc; fi
    export EDITOR=nano; [ -d "/var/www" ] && mc /var/www || mc
}
create_db() {
    submenu_header "DATABASE"
    box_input "DB Name" D; box_input "DB User" U; box_input "DB Pass" P
    mysql -e "CREATE DATABASE IF NOT EXISTS \`${D}\`; CREATE USER IF NOT EXISTS '${U}'@'localhost' IDENTIFIED BY '${P}'; GRANT ALL PRIVILEGES ON \`${D}\`.* TO '${U}'@'localhost'; FLUSH PRIVILEGES;"
    echo "Done."; read -p "Enter..."
}
backup_wizard() {
    submenu_header "BACKUP"
    box_row "1. Files" "2. Database"
    box_input "Pilih" B
    if [ "$B" == "1" ]; then box_input "Domain" D; R=$(get_site_root "$D"); zip -r "$BACKUP_DIR/${D}_bak.zip" $R -x "node_modules/*"; echo "Saved."; fi
    if [ "$B" == "2" ]; then box_input "DB Name" D; mysqldump $D > "$BACKUP_DIR/${D}.sql"; echo "Saved."; fi
    read -p "Enter..."
}

# --- MAIN LOOP ---
while true; do
    show_header
    box_input "Pilih Menu" OPT
    case $OPT in
        1) deploy_web ;; 2) manage_web ;; 3) manage_app ;; 4) open_file_manager ;; 5) create_db ;; 6) backup_wizard ;; 7) echo "Manual: crontab -e"; sleep 1;; 8) set_limit ;; 
        9) update_tool ;;
        s) system_health ;;
        0) clear; exit ;; u) rm /usr/local/bin/bd; exit ;; *) echo "Invalid"; sleep 1 ;;
    esac
done
EOF

chmod +x /usr/local/bin/bd
echo -e "${GREEN}SUKSES: BUNNY DEPLOY MANAGER v6.4 (Secured) Terinstall.${NC}"
