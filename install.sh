#!/bin/bash
set -euo pipefail

REPO="alexisprovost/keys-cli"
INSTALL_DIR="/usr/local/bin"
BIN_NAME="keys"

echo "Installing keys..."

# Download the script
curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/keys.sh" -o "/tmp/${BIN_NAME}"

# Install to /usr/local/bin (may need sudo)
if [[ -w "$INSTALL_DIR" ]]; then
    mv "/tmp/${BIN_NAME}" "${INSTALL_DIR}/${BIN_NAME}"
    chmod +x "${INSTALL_DIR}/${BIN_NAME}"
else
    sudo mv "/tmp/${BIN_NAME}" "${INSTALL_DIR}/${BIN_NAME}"
    sudo chmod +x "${INSTALL_DIR}/${BIN_NAME}"
fi

echo "Installed keys to ${INSTALL_DIR}/${BIN_NAME}"
echo "Run 'keys' to get started."
