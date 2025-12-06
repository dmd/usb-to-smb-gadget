# Raspberry Pi USB Gadget for TWIX Files

Quick-start installation guide for the McLean Hospital USB gadget system that allows copying TWIX files from Siemens scanners to network storage.

## Overview

This system makes a Raspberry Pi appear as a USB mass storage device to the scanner console. Files copied to this "USB drive" are automatically synced to a network file share, eliminating the need for physical USB sticks.

## Prerequisites

- Raspberry Pi 4B with Raspberry Pi OS (64-bit)
  - Use the [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to image an SD card with a standard 64-bit Raspberry Pi OS image. Let it create a user account for you.

- **Storage option A: Local USB disk** (recommended for performance)
  - USB disk attached to the Pi, must be formatted and labeled before installation (see below)

- **Storage option B: NFS share** for disk image storage
  - Note: This sends data over the network three times. Consider local USB for better performance.

- SMB/CIFS share configured on your file server for synced file access
- [USB-C power splitter](https://www.pishop.us/product/usb-c-pwr-splitter-without-barrel-jack/)
  - This is needed because we need to power the Pi via the USB-C port, but also use it as the port connected to the scanner. This splitter makes sure power from the power supply does not feed into the scanner console's USB port.


## Preparing Local USB Storage (if using STORAGE_TYPE=local)

If using a locally attached USB disk instead of NFS:

1. **Identify the USB disk:**
   ```bash
   lsblk
   ```
   Find your USB disk (e.g., `/dev/sda`)

2. **Partition the disk** (if needed):
   ```bash
   sudo fdisk /dev/sda
   # Create a single partition using all space
   ```

3. **Format as ext4:**
   ```bash
   sudo mkfs.ext4 /dev/sda1
   ```

4. **Label the partition:**
   ```bash
   sudo e2label /dev/sda1 TWIXIMAGE
   ```

5. **Verify the label:**
   ```bash
   ls -la /dev/disk/by-label/
   # Should show TWIXIMAGE -> ../../sda1
   ```


## Installation

### 1. Copy and edit configuration

```bash
cp config.example config
nano config
```

Edit with your site-specific values:
- **Storage type**: Choose `nfs` or `local`
- If `local`: Set `LOCAL_DISK_LABEL` (e.g., `TWIXIMAGE`)
- If `nfs`: Set `NFS_SERVER` (e.g., `fileserver:/volume1/twiximage`)
- SMB server path (e.g., `//fileserver/twixfiles`)
- SMB credentials (username, password, domain)
- Disk size (default 250G)

**Security note:** The `config` file contains credentials. Do not commit it to version control.

### 2. Run the installer

```bash
sudo ./install.sh
```

The installer will:
- Validate network connectivity to your file servers
- Install systemd units and scripts
- Create and format the disk image
- Enable all services
- Configure boot settings

### 3. Reboot

```bash
sudo reboot
```

The USB gadget mode requires a reboot to take effect.

### 4. Test the setup

- Plug the USB-C cable (from the data port of your splitter) into another computer
- A new USB drive should appear
- Copy a test file to the drive
- Eject the drive
- Wait ~60 seconds
- Verify the file appears in your SMB share at `/twixfiles`

### 5. Enable read-only mode (after testing)

Once you've verified everything works:

```bash
sudo raspi-config
```

- Select: `4 Performance Options`
- Select: `P2 Overlay File System`
- Enable overlay-fs: `Yes`
- Enable write-protect boot partition: `Yes`
- Reboot: `Yes`

This makes the Pi resistant to power failures and unexpected disconnections. If you need to make any changes, turn overlay-fs back off.

## Troubleshooting

### Services won't start

Check service status:
```bash
sudo systemctl status twiximage.mount
sudo systemctl status twixfiles.mount
sudo systemctl status usb-gadget.service
sudo systemctl status twix-rsync.timer
```

Check logs:
```bash
sudo journalctl -u twiximage.mount -n 50
sudo journalctl -u twix-rsync.service -n 50
```

### Files not syncing

Check that rsync is running:
```bash
sudo systemctl status twix-rsync.timer
sudo journalctl -u twix-rsync.service -f
```

Manually trigger a sync:
```bash
sudo systemctl start twix-rsync.service
```

### Network mount issues

Test mounts manually:
```bash
# Test NFS
sudo mount -t nfs4 fileserver:/path/to/share /mnt

# Test SMB
sudo mount -t cifs //fileserver/share /mnt -o credentials=/root/.mountcreds
```

## Other Notes

You may also want to install `ufw` and enable firewall rules to only allow ssh from a few hosts, and only allow communication with the file server otherwise.

A better way of triggering rsync would be to have it run when the device is unmounted. Unfortunately there seems to be a [Linux kernel bug preventing the Pi from seeing that](https://forums.raspberrypi.com/viewtopic.php?t=248774).

## Project Structure

```
.
├── README.md             # This file
├── usb-gadget.md         # Detailed documentation
├── install.sh            # Installation script
├── config.example        # Configuration template
├── systemd/              # Systemd unit files
│   ├── twiximage.mount
│   ├── twixfiles.mount
│   ├── usb-gadget.service
│   ├── twix-rsync.service
│   └── twix-rsync.timer
└── scripts/
    └── twix-rsync        # Sync script
```

## Credits

Created by [Daniel Drucker](https://3e.org/dmd/) (Director of IT, McLean Hospital Imaging Center).

Based on thagrol's [USB Mass Storage Gadget Beginner's Guide](https://github.com/thagrol/Guides/blob/main/mass-storage-gadget.pdf).

## License

This project is provided as-is for educational and research purposes.
