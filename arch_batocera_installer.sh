#!/bin/bash
# Arch Batocera-style all-in-one installer for 256GB SSD
# Features: Openbox, EmulationStation, RetroArch, Steam, Lutris, controller mapping,
# RGSX ROM downloader, ES system settings

set -e

# --- Configuration ---
SSD="/dev/sda"      # Change if different
USERNAME="gamer"
HOSTNAME="arch-console"
SWAP_SIZE="4G"

# --- Partitioning ---
echo "==> Partitioning SSD..."
parted --script $SSD mklabel gpt
parted --script $SSD mkpart ESP fat32 1MiB 512MiB
parted --script $SSD set 1 boot on
parted --script $SSD mkpart primary ext4 512MiB 100%

mkfs.fat -F32 ${SSD}1
mkfs.ext4 ${SSD}2

# --- Mount ---
mount ${SSD}2 /mnt
mkdir -p /mnt/boot
mount ${SSD}1 /mnt/boot

# --- Swapfile ---
fallocate -l $SWAP_SIZE /mnt/swapfile
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
swapon /mnt/swapfile

# --- Pacstrap Base ---
pacstrap /mnt base base-devel linux linux-firmware intel-ucode sudo networkmanager git vim xorg xorg-xinit openbox wget

# --- Fstab ---
genfstab -U /mnt >> /mnt/etc/fstab

# --- Chroot System Setup ---
arch-chroot /mnt /bin/bash <<EOF
set -e

# Hostname
echo "$HOSTNAME" > /etc/hostname

# Timezone
ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
hwclock --systohc

# Locale
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

# NetworkManager
systemctl enable NetworkManager

# User Creation
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
passwd -d $USERNAME # Set blank password
EOF

# --- User Setup Script ---
echo "==> Creating user-specific setup script inside the chroot..."
cat << 'EOT' > /mnt/home/$USERNAME/user_setup.sh
#!/bin/bash
set -e
USERNAME_ENV=$(whoami)

echo "==> Starting user-specific setup..."

# AUR Helper (yay)
git clone https://aur.archlinux.org/yay.git /tmp/yay
cd /tmp/yay
makepkg -si --noconfirm

# Install Applications
yay -S --noconfirm pcsx2-git portmaster emulationstation retroarch dolphin-emu ppsspp steam lutris \
  xorg-xrandr xorg-xinput xboxdrv antimicrox python-pip

# Batocera 41 Theme
git clone https://github.com/batocera-linux/batocera-emulationstation-theme.git /home/$USERNAME_ENV/.emulationstation/themes/Batocera41

# RGSX ROM Downloader
git clone https://github.com/RetroGameSets/RGSX.git /home/$USERNAME_ENV/rgsx
cat <<EOF > /home/$USERNAME_ENV/rgsx/rgsx.desktop
[Desktop Entry]
Name=RGSX Downloader
Exec=python3 /home/$USERNAME_ENV/rgsx/ports/RGSX
Type=Application
EOF

# System Settings Menu
mkdir -p /home/$USERNAME_ENV/scripts
cat <<EOF > /home/$USERNAME_ENV/scripts/emustation_settings.sh
#!/bin/bash
PS3="Choose an option: "
options=("Volume" "Display" "Network" "Bluetooth" "Update System" "Exit")
select opt in "\${options[@]}"
do
    case \$opt in
        "Volume") alsamixer ;;
        "Display") xrandr ;;
        "Network") nmcli d ;;
        "Bluetooth") bluetoothctl ;;
        "Update System") sudo pacman -Syu ;;
        "Exit") break ;;
        *) echo "Invalid option.";;
    esac
done
EOF
chmod +x /home/$USERNAME_ENV/scripts/emustation_settings.sh

mkdir -p /home/$USERNAME_ENV/.emulationstation/custom_apps
cat <<EOF > /home/$USERNAME_ENV/.emulationstation/custom_apps/system_settings.desktop
[Desktop Entry]
Name=System Settings
Exec=/home/$USERNAME_ENV/scripts/emustation_settings.sh
Type=Application
EOF

# Steam menu entry
cat <<EOF > /home/$USERNAME_ENV/.emulationstation/custom_apps/steam.desktop
[Desktop Entry]
Name=Steam
Exec=steam
Type=Application
EOF

# Lutris menu entry
cat <<EOF > /home/$USERNAME_ENV/.emulationstation/custom_apps/lutris.desktop
[Desktop Entry]
Name=Lutris
Exec=lutris
Type=Application
EOF

chown -R $USERNAME_ENV:$USERNAME_ENV /home/$USERNAME_ENV/.emulationstation /home/$USERNAME_ENV/scripts /home/$USERNAME_ENV/rgsx
echo "User setup complete."
EOT

chmod +x /mnt/home/$USERNAME/user_setup.sh
arch-chroot /mnt /bin/su - $USERNAME -c "/home/$USERNAME/user_setup.sh"
rm /mnt/home/$USERNAME/user_setup.sh

# --- Chroot Final System Configuration ---
arch-chroot /mnt /bin/bash <<EOF
set -e

# Controller Service
cat <<EOL > /etc/systemd/system/xboxdrv.service
[Unit]
Description=Xboxdrv controller mapping (Right Stick Mouse + Triggers)
After=network.target

[Service]
ExecStart=/usr/bin/xboxdrv --detach-kernel-driver --mimic-xpad --axismap="REL_X=RX*2,REL_Y=RY*2" \
  --mouse --trigger-as-button --buttonmap="LT=BTN_LEFT,RT=BTN_RIGHT" \
  --ui-buttonmap="A=ENTER,B=ESC,Y=TAB,X=SPACE,START=ENTER,SELECT=ESC" --silent
User=$USERNAME
Restart=always

[Install]
WantedBy=multi-user.target
EOL

systemctl enable xboxdrv.service

EOF

# --- Finish ---
echo "==> Installation complete. Reboot into your new Arch Batocera-style console!"
echo "Features ready: Openbox + ES, RetroArch, Steam, Lutris, controller mapping, RGSX."
