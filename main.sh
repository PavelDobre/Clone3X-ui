#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="$SCRIPT_DIR/creds"
KEY_PATH="$HOME/.ssh/id_ed25519_xui"
CONFIG_DIR="/etc/x-ui"
BIN_DIR="/usr/local/x-ui"
CERT_DIR="/etc/letsencrypt"
LIST_FILE="${SCRIPT_DIR}/list"

if [ "$(id -u)" -ne 0 ]; then
    echo "Should be root"
    exit 1
fi

# looking for creds
if [ -f "$CREDS_FILE" ]; then
    echo "Found creds file. Loading values..."
    source "$CREDS_FILE"
else
    echo "=== updating ==="
    apt update && apt upgrade -y
    apt install -y curl wget rsync unzip tar
    read -p "Install 3x-ui (y/n): " INSTALL_XUI
    
    if [[ "$INSTALL_XUI" =~ ^[Yy]$ || "$INSTALL_XUI" =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "=== installing 3x-ui ==="
        #bash -c "$(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)"
        VERSION=v2.8.4
        bash -c "$(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/$VERSION/install.sh)"
        echo "3x-ui installed"
    else
        echo "Skip 3x-ui installing"
    fi
    echo "No creds file found. Let's create one."
    read -p "Enter MAIN_SERVER_IP: " MAIN_SERVER_IP
    read -p "Enter MAIN_SERVER_USER: " MAIN_SERVER_USER
    read -p "Enter MAIN_SSH_PORT: " MAIN_SSH_PORT
    # saving to creds
    cat > "$CREDS_FILE" <<EOF
MAIN_SERVER_IP=$MAIN_SERVER_IP
MAIN_SERVER_USER=$MAIN_SERVER_USER
MAIN_SSH_PORT=$MAIN_SSH_PORT
EOF
    
    echo "File 'creds' created with your settings."
fi

echo
echo "Using settings:"
echo "IP=$MAIN_SERVER_IP"
echo "USER=$MAIN_SERVER_USER"
echo

#=== Starting

echo "checking ssh key..."
if ssh -i "$KEY_PATH" -p "$MAIN_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 "$MAIN_SERVER_USER@$MAIN_SERVER_IP" "echo OK" &>/dev/null; then
    echo "OK"
else
    echo "Not OK"
    if [ ! -f "$KEY_PATH" ]; then
        ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "auto-xui-key"
    fi
    ssh-copy-id -i "$KEY_PATH.pub" -p "$MAIN_SSH_PORT" "$MAIN_SERVER_USER@$MAIN_SERVER_IP"
    if ssh -i "$KEY_PATH" -p "$MAIN_SSH_PORT" -o BatchMode=yes "$MAIN_SERVER_USER@$MAIN_SERVER_IP" "echo OK" &>/dev/null; then
        echo "Now it's OK"
    else
        echo "Still not OK"
        exit 1
    fi
fi




x-ui stop
rsync -avz -e "ssh -i ${KEY_PATH} -p ${MAIN_SSH_PORT}" --delete \
${MAIN_SERVER_USER}@${MAIN_SERVER_IP}:${CONFIG_DIR}/ ${CONFIG_DIR}/
rsync -avz -e "ssh -i ${KEY_PATH} -p ${MAIN_SSH_PORT}" --delete \
${MAIN_SERVER_USER}@${MAIN_SERVER_IP}:${BIN_DIR}/ ${BIN_DIR}/

rsync -aHAX -e "ssh -i ${KEY_PATH} -p ${MAIN_SSH_PORT}" --rsync-path="sudo rsync" --delete \
${MAIN_SERVER_USER}@${MAIN_SERVER_IP}:${CERT_DIR}/ ${CERT_DIR}/


# List file
if [ -f "${LIST_FILE}" ] && [ -s "${LIST_FILE}" ]; then
    echo "=== list file found"
    while IFS= read -r relpath || [ -n "$relpath" ]; do
        relpath="$(echo "$relpath" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "$relpath" in
            ''|\#*) continue ;;
        esac
        
        if [[ "$relpath" != /* ]]; then
            echo "Warning: path '$relpath' is not absolute. Interpreting as absolute '/$relpath'"
            relpath="/${relpath#/}"
        fi
        
        SRC_PATH="${relpath%/}/"
        DST_PATH="${relpath%/}/"
        
        mkdir -p "$(dirname "$DST_PATH")"
        
        echo "-> Syncing ${SRC_PATH}  ->  ${DST_PATH}"
        rsync -aHAX -e "ssh -i ${KEY_PATH} -p ${MAIN_SSH_PORT}" --rsync-path="sudo rsync" --delete \
        ${MAIN_SERVER_USER}@${MAIN_SERVER_IP}:"${SRC_PATH}" "${DST_PATH}"
        
        if [ $? -ne 0 ]; then
            echo "Error syncing ${SRC_PATH} — continue to next"
        else
            echo "Synced ${SRC_PATH}"
        fi
        
    done < "${LIST_FILE}"
else
    echo "=== list file not found"
fi

echo "=== Certs rights"
chown -R root:root ${CERT_DIR}
chmod -R 700 ${CERT_DIR}

echo "=== Check certs' simlinks"
ls -l ${CERT_DIR}/live/ || echo "Live folder is empty or absent"

echo "=== Set right in systemd for 3x-ui"
chmod +x ${BIN_DIR}/x-ui
systemctl daemon-reload
systemctl enable x-ui
systemctl restart x-ui

x-ui status
x-ui settings
echo "=== all done ==="