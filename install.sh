#!/bin/bash
set -euo pipefail

# USB Gadget Installation Script
# Installs and configures Raspberry Pi USB mass storage gadget with NFS/SMB backend

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

fatal() {
    error "$*"
    exit 1
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        fatal "This script must be run as root. Use: sudo ./install.sh"
    fi
}

# Check if required dependencies are installed
check_dependencies() {
    info "Checking required dependencies..."

    local required_commands=(envsubst mkfs.exfat mount umount systemctl)
    local missing_commands=()

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_commands+=("$cmd")
        fi
    done

    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        fatal "Missing required commands: ${missing_commands[*]}\nPlease install these dependencies and try again."
    fi

    info "All required dependencies are available"
}

# Check if config file exists and source it
check_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        fatal "Config file not found: $CONFIG_FILE\nCopy config.example to config and customize it."
    fi

    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    # Verify required variables for all storage types
    local required_vars=(SMB_SERVER SMB_USERNAME SMB_PASSWORD SMB_DOMAIN DISK_SIZE STORAGE_TYPE)
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            fatal "Required variable $var not set in config file"
        fi
    done

    # Validate STORAGE_TYPE and its dependencies
    case "$STORAGE_TYPE" in
        nfs)
            if [[ -z "${NFS_SERVER:-}" ]]; then
                fatal "STORAGE_TYPE=nfs requires NFS_SERVER to be set"
            fi
            ;;
        local)
            if [[ -z "${LOCAL_DISK_LABEL:-}" ]]; then
                fatal "STORAGE_TYPE=local requires LOCAL_DISK_LABEL to be set"
            fi
            if [[ ! -e "/dev/disk/by-label/${LOCAL_DISK_LABEL}" ]]; then
                fatal "USB disk with label '${LOCAL_DISK_LABEL}' not found.\nPrepare the disk first: sudo e2label /dev/sdX1 ${LOCAL_DISK_LABEL}"
            fi
            ;;
        *)
            fatal "STORAGE_TYPE must be 'nfs' or 'local', got: $STORAGE_TYPE"
            ;;
    esac

    # Export variables so envsubst can see them
    export NFS_SERVER SMB_SERVER SMB_USERNAME SMB_PASSWORD SMB_DOMAIN DISK_SIZE STORAGE_TYPE LOCAL_DISK_LABEL
}

# Test NFS mount
test_nfs_mount() {
    local test_mount="/tmp/test_nfs_$$"
    mkdir -p "$test_mount"

    info "Testing NFS mount: $NFS_SERVER"

    if ! mount -t nfs4 -o ro "$NFS_SERVER" "$test_mount" 2>/dev/null; then
        rmdir "$test_mount" 2>/dev/null || true
        fatal "Cannot mount NFS server: $NFS_SERVER\nCheck that the NFS share exists and is accessible from this host."
    fi

    umount "$test_mount"
    rmdir "$test_mount"
    info "NFS mount test successful"
}

# Test SMB mount
test_smb_mount() {
    local test_mount="/tmp/test_smb_$$"
    local test_creds="/tmp/test_creds_$$"
    mkdir -p "$test_mount"

    # Create temporary credentials file
    cat > "$test_creds" <<EOF
username=$SMB_USERNAME
password=$SMB_PASSWORD
domain=$SMB_DOMAIN
EOF
    chmod 600 "$test_creds"

    info "Testing SMB mount: $SMB_SERVER"

    if ! mount -t cifs -o "credentials=$test_creds,ro" "$SMB_SERVER" "$test_mount" 2>/dev/null; then
        rm -f "$test_creds"
        rmdir "$test_mount" 2>/dev/null || true
        fatal "Cannot mount SMB share: $SMB_SERVER\nCheck credentials and that the share is accessible from this host."
    fi

    umount "$test_mount"
    rm -f "$test_creds"
    rmdir "$test_mount"
    info "SMB mount test successful"
}

# Install systemd units
install_systemd_units() {
    info "Installing systemd units..."

    # Select twiximage.mount template based on STORAGE_TYPE
    local twiximage_template="${SCRIPT_DIR}/systemd/twiximage.mount.${STORAGE_TYPE}"
    if [[ ! -f "$twiximage_template" ]]; then
        fatal "Template not found: $twiximage_template"
    fi
    envsubst < "$twiximage_template" > "/etc/systemd/system/twiximage.mount"
    info "Installed /etc/systemd/system/twiximage.mount (from ${STORAGE_TYPE} template)"

    # Process twixfiles.mount template
    local twixfiles_source="${SCRIPT_DIR}/systemd/twixfiles.mount"
    if [[ ! -f "$twixfiles_source" ]]; then
        fatal "Source file not found: $twixfiles_source"
    fi
    envsubst < "$twixfiles_source" > "/etc/systemd/system/twixfiles.mount"
    info "Installed /etc/systemd/system/twixfiles.mount"

    # Copy static units
    for unit in usb-gadget.service twix-rsync.service twix-rsync.timer; do
        local source_file="${SCRIPT_DIR}/systemd/${unit}"
        if [[ ! -f "$source_file" ]]; then
            fatal "Source file not found: $source_file"
        fi
        cp "$source_file" "/etc/systemd/system/${unit}"
        info "Installed /etc/systemd/system/${unit}"
    done
}

# Install rsync script
install_rsync_script() {
    info "Installing rsync script..."

    local source_file="${SCRIPT_DIR}/scripts/twix-rsync"
    if [[ ! -f "$source_file" ]]; then
        fatal "Source file not found: $source_file"
    fi
    cp "$source_file" /usr/local/bin/twix-rsync
    chmod +x /usr/local/bin/twix-rsync
    info "Installed /usr/local/bin/twix-rsync"
}

# Generate mount credentials file
generate_mount_credentials() {
    info "Generating mount credentials file..."

    cat > /root/.mountcreds <<EOF
username=$SMB_USERNAME
password=$SMB_PASSWORD
domain=$SMB_DOMAIN
EOF
    chmod 600 /root/.mountcreds
    info "Created /root/.mountcreds"
}

# Create mount directories
create_mount_dirs() {
    info "Creating mount directories..."

    mkdir -p /twiximage
    mkdir -p /twixfiles
    info "Created /twiximage and /twixfiles"
}

# Create and format disk image
create_disk_image() {
    info "Creating disk image..."

    # Mount storage (NFS or local USB) first
    systemctl daemon-reload
    systemctl enable --now twiximage.mount

    # Wait for mount to complete
    local max_wait=30
    local waited=0
    while ! mountpoint -q /twiximage && [[ $waited -lt $max_wait ]]; do
        warn "Waiting for /twiximage mount to complete... ($waited/$max_wait seconds)"
        sleep 1
        ((waited++))
    done

    if ! mountpoint -q /twiximage; then
        fatal "Mount /twiximage failed to complete within ${max_wait} seconds. Check systemctl status twiximage.mount"
    fi

    info "Mount /twiximage completed successfully"

    # Check if disk image already exists
    if [[ -f /twiximage/disk.img ]]; then
        warn "Disk image /twiximage/disk.img already exists, skipping creation"
        return
    fi

    info "Creating ${DISK_SIZE} disk image (this may take a moment)..."
    truncate -s "$DISK_SIZE" /twiximage/disk.img

    info "Formatting as exFAT..."
    mkfs.exfat /twiximage/disk.img

    info "Disk image created and formatted"
}

# Enable and start services
enable_services() {
    info "Enabling and starting services..."

    systemctl daemon-reload

    # Enable and start mounts and services
    systemctl enable --now twixfiles.mount
    systemctl enable --now usb-gadget.service
    systemctl enable --now twix-rsync.timer

    info "Services enabled"
}

# Verify services are running
verify_services() {
    info "Verifying services..."

    local failed=0
    for service in twiximage.mount twixfiles.mount usb-gadget.service twix-rsync.timer; do
        if systemctl is-active --quiet "$service"; then
            info "✓ $service is active"
        else
            warn "✗ $service failed to start"
            warn "  Check status with: systemctl status $service"
            failed=1
        fi
    done

    return $failed
}

# Configure boot settings
configure_boot() {
    info "Configuring boot settings..."

    local config_file="/boot/firmware/config.txt"
    local backup_file="/boot/firmware/config.txt.bak"

    # Backup config
    if [[ ! -f "$backup_file" ]]; then
        cp "$config_file" "$backup_file"
        info "Created backup: $backup_file"
    fi

    # Check if dtoverlay=dwc2 already exists in [all] section
    # Use awk to check only within [all] section
    if awk '/^\[all\]/,/^\[/ {if (/^dtoverlay=dwc2/) exit 0} END {exit 1}' "$config_file"; then
        info "dtoverlay=dwc2 already present in [all] section"
        return
    fi

    # Check if [all] section exists
    if grep -q "^\[all\]" "$config_file"; then
        # Add after [all] section
        sed -i '/^\[all\]/a dtoverlay=dwc2' "$config_file"
    else
        # Add [all] section at end
        echo "" >> "$config_file"
        echo "[all]" >> "$config_file"
        echo "dtoverlay=dwc2" >> "$config_file"
    fi

    info "Added dtoverlay=dwc2 to config.txt"
}

# Prepare for read-only mode
prepare_readonly() {
    info "Preparing for read-only mode..."

    # Disable cloud-init if it exists
    if systemctl list-unit-files | grep -q cloud-init; then
        touch /etc/cloud/cloud-init.disabled
        systemctl disable cloud-init.service cloud-init-local.service cloud-config.service cloud-final.service 2>/dev/null || true
        rm -f /run/systemd/generator/*cloud-init* 2>/dev/null || true
        info "Disabled cloud-init services"
    fi

    # Disable swap
    if systemctl list-unit-files | grep -q dphys-swapfile; then
        systemctl disable dphys-swapfile.service 2>/dev/null || true
        info "Disabled swap service"
    fi

    # Disable raspi-config
    if [[ -f /etc/systemd/system/multi-user.target.wants/raspi-config.service ]]; then
        rm -f /etc/systemd/system/multi-user.target.wants/raspi-config.service
        info "Disabled raspi-config service"
    fi

    # Disable fake-hwclock
    systemctl disable fake-hwclock.service fake-hwclock.timer 2>/dev/null || true
    info "Disabled fake-hwclock services"

    info "System prepared for read-only mode"
}

# Print final instructions
print_final_instructions() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    info "Installation complete!"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    warn "⚠  REBOOT REQUIRED for USB gadget mode to take effect"
    echo ""
    echo "After reboot:"
    echo "  1. Test the USB gadget by plugging into another computer"
    echo "  2. Copy a test file to the mounted disk"
    echo "  3. Wait ~60 seconds and verify file appears in SMB share"
    echo ""
    echo "Once verified, enable read-only mode:"
    echo "  1. Run: sudo raspi-config"
    echo "  2. Select: 4 Performance Options → P2 Overlay File System"
    echo "  3. Enable overlay-fs and boot partition write protection"
    echo "  4. Reboot"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
}

# Main installation flow
main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  USB Gadget Installation Script"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    info "[1/6] Checking prerequisites..."
    check_root
    check_dependencies
    check_config

    info "[2/6] Validating network mounts..."
    if [[ "$STORAGE_TYPE" == "nfs" ]]; then
        test_nfs_mount
    else
        info "Skipping NFS test (STORAGE_TYPE=$STORAGE_TYPE)"
    fi
    test_smb_mount

    info "[3/6] Installing files..."
    create_mount_dirs
    install_systemd_units
    install_rsync_script
    generate_mount_credentials

    info "[4/6] Creating disk image..."
    create_disk_image

    info "[5/6] Enabling services..."
    enable_services
    verify_services || warn "Some services failed to start - check logs"

    info "[6/6] Configuring system..."
    configure_boot
    prepare_readonly

    print_final_instructions
}

# Run main function
main "$@"
