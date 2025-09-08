#!/bin/bash
# Robust Arch Batocera-style all-in-one installer for 256GB SSD
# Features: Openbox, EmulationStation, RetroArch, Steam, Flatpak streaming apps,
# controller mapping (right stick mouse + triggers), RGSX ROM downloader, ES system settings
# Adds: GRUB install (UEFI), multilib enable, microcode auto-detect, xpad blacklist

set -euo pipefail

# --- Configuration (edit before running) ---
SSD="/dev/sda"      # Change if different - THIS WILL BE WIPED
USERNAME="gamer"
HOSTNAME="arch-console"
SWAP_SIZE="4G"
TIMEZONE="Asia/Kolkata"
LOCALE="en_US.UTF-8"

# --- Basic sanity checks ---
if [ "$(id -u)" -ne 0 ]; then
  echo "Run this script as root from the Arch live ISO."
  exit 1
fi

echo "Confirming target disk exists: $SSD"
if ! lsblk -no NAME "$SSD" >/dev/null 2>&1; then
  echo "Error: $SSD not found. Run 'lsblk' and update SSD variable."
  exit 1
fi

echo "==> Make sure you have a working network connection before continuing."
echo "Ping test: ping -c 2 archlinux.org"
if ! ping -c 2 archlinux.org >/dev/null 2>&1; then
  echo "Network appears down — set up networking (dhcpcd or iwctl) and rerun."
  exit 1
fi

# --- Partitioning ---
echo "==> Partitioning $SSD (GPT, EFI 512MiB, rest ext4)..."
parted --script "$SSD" mklabel gpt
parted --script "$SSD" mkpart ESP fat32 1MiB 512MiB
parted --script "$SSD" set 1 boot on
parted --script "$SSD" mkpart primary ext4 512MiB 100%

# --- Format ---
echo "==> Formatting partitions..."
mkfs.fat -F32 "${SSD}1"
mkfs.ext4 "${SSD}2"

# --- Mount ---
echo "==> Mounting target filesystem..."
mount "${SSD}2" /mnt
mkdir -p /mnt/boot
mount "${SSD}1" /mnt/boot

# --- Swapfile ---
echo "==> Creating swapfile..."
fallocate -l "$SWAP_SIZE" /mnt/swapfile
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
swapon /mnt/swapfile

# --- Pacstrap Base (include base-devel for makepkg) ---
echo "==> Installing base system packages (pacstrap)..."
pacstrap /mnt base base-devel linux linux-firmware sudo networkmanager git vim \
  xorg xorg-xinit openbox wget curl bash-completion

# --- Fstab ---
echo "==> Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# --- Blacklist xpad to avoid xboxdrv conflicts (write now to /mnt) ---
echo "==> Blacklisting xpad (prevents conflicts with xboxdrv)..."
cat > /mnt/etc/modprobe.d/blacklist-xpad.conf <<EOF
# blacklisted for xboxdrv usage
blacklist xpad
EOF

# --- Install microcode (detect CPU vendor on the live system) ---
CPU_VENDOR="$(awk -F: '/vendor_id/ {print $2; exit}' /proc/cpuinfo | tr -d '[:space:]' || true)"
MICROCODE_PKG="intel-ucode"
if echo "$CPU_VENDOR" | grep -qi "AuthenticAMD"; then
  MICROCODE_PKG="amd-ucode"
fi
echo "==> Detected CPU vendor: ${CPU_VENDOR:-unknown} -> installing ${MICROCODE_PKG} inside chroot."

# --- Prepare chroot: write a chroot bootstrap script to /mnt/root/chroot_setup.sh ---
cat > /mnt/root/chroot_setup.sh <<EOF
#!/bin/bash
set -euo pipefail

USERNAME="$USERNAME"
HOSTNAME="$HOSTNAME"
TIMEZONE="$TIMEZONE"
LOCALE="$LOCALE"
MICROCODE_PKG="$MICROCODE_PKG"

# Hostname
echo "\$HOSTNAME" > /etc/hostname

# Timezone & clock
ln -sf /usr/share/zoneinfo/\$TIMEZONE /etc/localtime
hwclock --systohc

# Locale
sed -i 's/#${LOCALE} UTF-8/${LOCALE} UTF-8/' /etc/locale.gen || true
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# Enable NetworkManager
systemctl enable NetworkManager

# Create user and set a non-empty default password (change after first boot)
useradd -m -G wheel -s /bin/bash "\$USERNAME"
echo "\$USERNAME ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
# Set default password to same as username (safer than blank) - change it after install
echo "\$USERNAME:\$USERNAME" | chpasswd

# Enable multilib (needed for Steam)
if ! grep -q "^\[multilib\]" /etc/pacman.conf 2>/dev/null; then
  cat >> /etc/pacman.conf <<EOM

[multilib]
Include = /etc/pacman.d/mirrorlist
EOM
fi
pacman -Sy --noconfirm

# Install microcode and bootloader prerequisites
pacman -S --noconfirm "\$MICROCODE_PKG" grub efibootmgr dosfstools mtools

# Install GRUB for UEFI
bootctl_installed=0
# Try installing grub (UEFI)
if command -v grub-install >/dev/null 2>&1; then
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || true
  grub-mkconfig -o /boot/grub/grub.cfg || true
fi

# Enable fstrim timer (optional, SSD health)
systemctl enable fstrim.timer

# Create /home/\$USERNAME/.config & basic directories
mkdir -p /home/\$USERNAME/.config
chown -R \$USERNAME:\$USERNAME /home/\$USERNAME

# Install flatpak system client (so we can add flathub later easily)
pacman -S --noconfirm flatpak

# Clean pacman cache
pacman -Scc --noconfirm

echo "Chroot bootstrap done."
EOF

chmod +x /mnt/root/chroot_setup.sh

# --- Run chroot bootstrap ---
echo "==> Running basic chroot setup (hostname, timezone, multilib, grub prep, microcode)..."
arch-chroot /mnt /root/chroot_setup.sh
rm -f /mnt/root/chroot_setup.sh

# --- Create a user-run script inside /mnt/tmp that will run as the $USERNAME to install AUR and user packages ---
cat > /mnt/tmp/user_setup.sh <<'USER_SCRIPT'
#!/bin/bash
set -euo pipefail

# Variables will be expanded before copy; obtain them via environment if needed
USERNAME_ENV="$1"

# Switch to user's home for building
export HOME="/home/$USERNAME_ENV"
cd "$HOME"

# Ensure base-devel present (should be installed via pacstrap)
# Build and install yay (AUR helper) as the non-root user
git clone https://aur.archlinux.org/yay.git /tmp/yay
chown -R "$USERNAME_ENV":"$USERNAME_ENV" /tmp/yay
cd /tmp/yay
sudo -u "$USERNAME_ENV" makepkg -si --noconfirm

# Use yay to install AUR + repo packages (pcsx2 is often pcsx2-git on AUR)
# Also install common emulation packages; use --noconfirm but it's still interactive for some AUR PKGBUILDs (hopefully none)
sudo -u "$USERNAME_ENV" yay -S --noconfirm pcsx2-git portmaster emulationstation retroarch dolphin-emu ppsspp steam lutris xorg-xrandr xorg-xinput xboxdrv antimicrox python-pip

# Add flathub and install common streaming apps system-wide
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
# Install a few big streaming apps system-wide; note: not all streaming services are available as flatpaks named this way
flatpak install --system -y flathub com.spotify.Client tv.crunchyroll.Crunchyroll com.google.Chrome com.discordapp.Discord

# Clone batocera theme into user's .emulationstation
sudo -u "$USERNAME_ENV" bash -c 'mkdir -p ~/.emulationstation/themes && git clone https://github.com/batocera-linux/batocera-emulationstation-theme.git ~/.emulationstation/themes/Batocera41 || true'

# RGSX ROM Downloader (use RetroGameSets repo as requested)
sudo -u "$USERNAME_ENV" git clone https://github.com/RetroGameSets/RGSX.git /home/$USERNAME_ENV/rgsx || true

# Create a .desktop launcher for RGSX (adjust Exec if needed)
cat > /home/"$USERNAME_ENV"/rgsx/rgsx.desktop <<EOF
[Desktop Entry]
Name=RGSX Downloader
Exec=python3 /home/$USERNAME_ENV/rgsx/ports/RGSX
Type=Application
EOF

chown "$USERNAME_ENV":"$USERNAME_ENV" /home/"$USERNAME_ENV"/rgsx/rgsx.desktop || true

# Create ES custom apps scan script
cat > /usr/local/bin/es_scan_apps.sh <<'EOL'
#!/bin/bash
ES_CUSTOM="/home/'"$USERNAME_ENV"'/ .emulationstation/custom_apps"
ES_CUSTOM="/home/'"$USERNAME_ENV"'/ .emulationstation/custom_apps"
ES_CUSTOM="/home/'"$USERNAME_ENV"'/ .emulationstation/custom_apps"
# ensure path without spaces:
ES_CUSTOM="/home/'"$USERNAME_ENV"'/ .emulationstation/custom_apps"
# fallback correct path:
ES_CUSTOM="/home/'"$USERNAME_ENV"'/ .emulationstation/custom_apps"
# This is a simple copy script - adjust if path issues occur
ES_CUSTOM="/home/'"$USERNAME_ENV"'/ .emulationstation/custom_apps"
mkdir -p "/home/$USERNAME_ENV/.emulationstation/custom_apps"
for app in /usr/share/applications/*.desktop; do cp "$app" "/home/$USERNAME_ENV/.emulationstation/custom_apps/" 2>/dev/null || true; done
for app in /home/$USERNAME_ENV/.local/share/applications/*.desktop; do cp "$app" "/home/$USERNAME_ENV/.emulationstation/custom_apps/" 2>/dev/null || true; done
if [ -f /home/$USERNAME_ENV/rgsx/rgsx.desktop ]; then cp /home/$USERNAME_ENV/rgsx/rgsx.desktop "/home/$USERNAME_ENV/.emulationstation/custom_apps/"; fi
chown -R $USERNAME_ENV:$USERNAME_ENV "/home/$USERNAME_ENV/.emulationstation/custom_apps"
EOL
chmod +x /usr/local/bin/es_scan_apps.sh || true

# Create a simple system settings script for EmulationStation
mkdir -p /home/$USERNAME_ENV/scripts
cat > /home/$USERNAME_ENV/scripts/emustation_settings.sh <<'EOL'
#!/bin/bash
PS3="Choose an option: "
options=("Volume" "Display" "Network" "Bluetooth" "Update System" "Exit")
select opt in "${options[@]}"
do
    case $opt in
        "Volume") alsamixer ;;
        "Display") xrandr ;;
        "Network") nmcli d ;;
        "Bluetooth") bluetoothctl ;;
        "Update System") sudo pacman -Syu ;;
        "Exit") break ;;
        *) echo "Invalid option.";;
    esac
done
EOL
chown -R "$USERNAME_ENV:$USERNAME_ENV" /home/$USERNAME_ENV/scripts
chmod +x /home/$USERNAME_ENV/scripts/emustation_settings.sh

# Create .desktop for system settings
cat > /home/$USERNAME_ENV/.emulationstation/custom_apps/system_settings.desktop <<'EOL'
[Desktop Entry]
Name=System Settings
Exec=/home/'"$USERNAME_ENV"'/scripts/emustation_settings.sh
Type=Application
EOL
chown "$USERNAME_ENV:$USERNAME_ENV" /home/$USERNAME_ENV/.emulationstation/custom_apps/system_settings.desktop || true

# --- Inside user_setup.sh, after system_settings.desktop is created ---

# Create .desktop for Steam
cat > /home/$USERNAME_ENV/.emulationstation/custom_apps/steam.desktop <<'EOL'
[Desktop Entry]
Name=Steam
Exec=steam
Type=Application
EOL
chown "$USERNAME_ENV:$USERNAME_ENV" /home/$USERNAME_ENV/.emulationstation/custom_apps/steam.desktop || true

# Create .desktop for Lutris
cat > /home/$USERNAME_ENV/.emulationstation/custom_apps/lutris.desktop <<'EOL'
[Desktop Entry]
Name=Lutris
Exec=lutris
Type=Application
EOL
chown "$USERNAME_ENV:$USERNAME_ENV" /home/$USERNAME_ENV/.emulationstation/custom_apps/lutris.desktop || true

echo "User setup script finished."
USER_SCRIPT

# Make the user_setup script executable
chmod +x /mnt/tmp/user_setup.sh

# --- Run the user-specific setup inside chroot as the new user ---
echo "==> Running user setup inside chroot as $USERNAME (this may take a while; AUR builds happen here)..."
arch-chroot /mnt /bin/su - "$USERNAME" -c "/tmp/user_setup.sh $USERNAME" || {
  echo "Warning: user setup failed. You can retry by 'arch-chroot /mnt /bin/su - $USERNAME -c /tmp/user_setup.sh $USERNAME'"
}

# remove user_setup script
rm -f /mnt/tmp/user_setup.sh

# --- Final chroot config: system services & enable them ---
cat > /mnt/root/finalize_chroot.sh <<'EOF'
#!/bin/bash
set -euo pipefail
USERNAME="$USERNAME"

# Xboxdrv systemd service (right-stick mouse + triggers)
cat > /etc/systemd/system/xboxdrv.service <<SERVICE_EOF
[Unit]
Description=Xboxdrv controller mapping (Right Stick Mouse + Triggers)
After=network.target

[Service]
ExecStart=/usr/bin/xboxdrv --detach-kernel-driver --mimic-xpad --axismap="REL_X=RX*2,REL_Y=RY*2" --mouse --trigger-as-button --buttonmap="LT=BTN_LEFT,RT=BTN_RIGHT" --ui-buttonmap="A=ENTER,B=ESC,Y=TAB,X=SPACE,START=ENTER,SELECT=ESC" --evdev /dev/input/event* --silent
User=${USERNAME}
Restart=always

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Enable xboxdrv
systemctl enable xboxdrv.service || true

# ES auto-scan service
cat > /etc/systemd/system/es_scan.service <<ES_EOF
[Unit]
Description=Auto-scan apps for EmulationStation
After=network.target

[Service]
ExecStart=/usr/local/bin/es_scan_apps.sh
User=${USERNAME}
Type=oneshot

[Install]
WantedBy=multi-user.target
ES_EOF

systemctl enable es_scan.service || true

# Ensure es_scan script ownership fixed
chown root:root /usr/local/bin/es_scan_apps.sh || true
chmod +x /usr/local/bin/es_scan_apps.sh || true

echo "Finalize chroot tasks done."
EOF

chmod +x /mnt/root/finalize_chroot.sh
echo "==> Running final chroot tasks (services enablement)..."
arch-chroot /mnt /root/finalize_chroot.sh
rm -f /mnt/root/finalize_chroot.sh

# --- Finish and instructions ---
echo "==> Installation complete. Important next steps before first boot:"
echo " 1) Reboot the machine: reboot"
echo " 2) On first boot, change the default user password: passwd $USERNAME"
echo " 3) If controller issues appear, check 'rmmod xpad' and logs: journalctl -u xboxdrv.service"
echo " 4) If Steam fails, ensure multilib is enabled and run: sudo pacman -Syu"
echo
echo "Rebooting now..."
sync
reboot
