#!/bin/bash
# Pop!_OS All-in-One Gamer Setup (Console Style)
# Based on Debian script, fully patched for Pop!_OS (Ubuntu-based)

set -euo pipefail

USERNAME="gamer"
HOSTNAME="popos-console"
TIMEZONE="Asia/Kolkata"
LOCALE="en_US.UTF-8"

# --- Root Check ---
if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root."
    exit 1
fi

# --- Network Check ---
if ! ping -c1 8.8.8.8 >/dev/null 2>&1; then
    echo "No network detected. Connect and try again."
    exit 1
fi

# --- Set hostname, timezone, locale ---
hostnamectl set-hostname "$HOSTNAME"
timedatectl set-timezone "$TIMEZONE"
localectl set-locale LANG=$LOCALE

# --- Update system ---
apt update && apt -y upgrade

# --- Essential packages ---
apt install -y sudo git curl wget unzip \
    xorg mesa-utils mesa-vulkan-drivers libgl1-mesa-dri \
    pulseaudio alsa-utils dbus-x11 \
    xfce4 xfce4-goodies \
    retroarch libretro-core-info \
    pcsx2 dolphin-emu ppsspp-sdl flycast \
    steam lutris xboxdrv antimicrox gamemode cpufrequtils \
    software-properties-common apt-transport-https ca-certificates gnupg

# --- 32-bit libraries for Steam/Lutris ---
dpkg --add-architecture i386
apt update
apt install -y libc6:i386 libgl1-mesa-dri:i386 libgl1-mesa-glx:i386 libvulkan1:i386

# --- Microcode ---
CPU_VENDOR=$(awk -F: '/vendor_id/ {print $2; exit}' /proc/cpuinfo | tr -d '[:space:]')
MICROCODE_PKG="intel-microcode"
[ "$(echo $CPU_VENDOR | grep -i AMD)" ] && MICROCODE_PKG="amd64-microcode"
apt install -y "$MICROCODE_PKG"

# --- User setup ---
if ! id "$USERNAME" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$USERNAME"
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
    echo "$USERNAME:$USERNAME" | chpasswd
fi

# --- GPU Settings (force Intel) ---
cat > /etc/modprobe.d/blacklist-radeon.conf <<EOL
blacklist radeon
blacklist amdgpu
EOL

mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/20-intel.conf <<EOL
Section "Device"
    Identifier "Intel Graphics"
    Driver "intel"
    Option "TearFree" "true"
EndSection
EOL

# --- Install EmulationStation-DE (.deb) ---
ES_DEB="emulationstation-de_2.1.1_amd64.deb"
wget -O /tmp/$ES_DEB https://github.com/ES-DE/emulationstation-de/releases/download/v2.1.1/$ES_DEB
apt install -y /tmp/$ES_DEB

# --- Autologin & EmulationStation boot (agetty) ---
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOL
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USERNAME --noclear %I \$TERM
EOL

# --- .bash_profile with EmulationStation start ---
BASH_PROFILE="/home/$USERNAME/.bash_profile"
cat > "$BASH_PROFILE" <<EOL
[[ -z \$DISPLAY && \$XDG_VTNR -eq 1 ]] && exec startx /usr/bin/emulationstation -- :0
EOL
chown $USERNAME:$USERNAME "$BASH_PROFILE"

# --- ROM directories ---
ROM_DIR="/home/$USERNAME/ROMs"
SYSTEMS=(arcade nes snes gba n64 psx ps2 psp dreamcast gamecube wii)
for sys in "${SYSTEMS[@]}"; do
    mkdir -p "$ROM_DIR/$sys"
done

# --- EmulationStation config ---
ES_DIR="/home/$USERNAME/.emulationstation"
mkdir -p $ES_DIR/controllers $ES_DIR/themes $ES_DIR/collections $ES_DIR/custom_apps

cat > "$ES_DIR/es_settings.cfg" <<EOL
<?xml version="1.0"?>
<systemList>
    <system>
        <name>nes</name>
        <path>$ROM_DIR/nes</path>
        <extension>.nes</extension>
        <command>retroarch -L /usr/lib/x86_64-linux-gnu/libretro/fceumm_libretro.so %ROM%</command>
        <platform>nes</platform>
        <theme>default</theme>
    </system>
    <system>
        <name>ps2</name>
        <path>$ROM_DIR/ps2</path>
        <extension>.iso .bin .img .cue</extension>
        <command>PCSX2 %ROM%</command>
        <platform>ps2</platform>
        <theme>default</theme>
    </system>
    <system>
        <name>psp</name>
        <path>$ROM_DIR/psp</path>
        <extension>.iso .cso</extension>
        <command>ppsspp-sdl %ROM%</command>
        <platform>psp</platform>
        <theme>default</theme>
    </system>
    <system>
        <name>dreamcast</name>
        <path>$ROM_DIR/dreamcast</path>
        <extension>.cdi .gdi .chd .iso</extension>
        <command>flycast %ROM%</command>
        <platform>dreamcast</platform>
        <theme>default</theme>
    </system>
    <system>
        <name>gamecube</name>
        <path>$ROM_DIR/gamecube</path>
        <extension>.iso .gcm</extension>
        <command>dolphin-emu %ROM%</command>
        <platform>gamecube</platform>
        <theme>default</theme>
    </system>
    <system>
        <name>wii</name>
        <path>$ROM_DIR/wii</path>
        <extension>.iso</extension>
        <command>dolphin-emu %ROM%</command>
        <platform>wii</platform>
        <theme>default</theme>
    </system>
</systemList>
EOL

# --- Theme ---
git clone https://github.com/batocera-linux/batocera-emulationstation-theme.git $ES_DIR/themes/Batocera41 || true
echo 'theme=Batocera41' > $ES_DIR/themes/theme.cfg

# --- Controller config ---
cat > $ES_DIR/controllers/default.cfg <<EOL
input_player1_joypad = "xbox"
EOL

# --- Streaming Apps via Chrome ---
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-linux-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-linux-keyring.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list

curl -fsSL https://download.spotify.com/debian/pubkey_0D811D58.gpg | gpg --dearmor -o /usr/share/keyrings/spotify-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/spotify-archive-keyring.gpg] http://repository.spotify.com stable non-free" > /etc/apt/sources.list.d/spotify.list

apt update && apt -y install google-chrome-stable spotify-client

mkdir -p $ES_DIR/collections/streaming
declare -A STREAM_APPS=(
    ["Netflix"]="google-chrome-stable https://www.netflix.com"
    ["PrimeVideo"]="google-chrome-stable https://www.primevideo.com"
    ["AppleTV"]="google-chrome-stable https://tv.apple.com"
    ["DisneyPlus"]="google-chrome-stable https://www.disneyplus.com"
    ["Crunchyroll"]="google-chrome-stable https://www.crunchyroll.com"
    ["Spotify"]="spotify"
)

for app in "${!STREAM_APPS[@]}"; do
cat > "$ES_DIR/collections/streaming/${app}.desktop" <<EOL
[Desktop Entry]
Name=$app
Exec=${STREAM_APPS[$app]}
Type=Application
EOL
done

# --- Custom Apps (Steam, Lutris, Desktop, RGSX) ---
cat > $ES_DIR/custom_apps/steam.desktop <<EOL
[Desktop Entry]
Name=Steam
Exec=steam
Type=Application
EOL

cat > $ES_DIR/custom_apps/lutris.desktop <<EOL
[Desktop Entry]
Name=Lutris
Exec=lutris
Type=Application
EOL

cat > $ES_DIR/custom_apps/desktop.desktop <<EOL
[Desktop Entry]
Name=Desktop (XFCE)
Exec=startxfce4
Type=Application
EOL

# --- RGSX Installer ---
sudo -u $USERNAME git clone https://github.com/RetroGameSets/RGSX.git /home/$USERNAME/rgsx || true
chmod +x /home/$USERNAME/rgsx/rgsx.sh
chown -R $USERNAME:$USERNAME /home/$USERNAME/rgsx

cat > $ES_DIR/custom_apps/rgsx.desktop <<EOL
[Desktop Entry]
Name=RGSX
Exec=/home/$USERNAME/rgsx/rgsx.sh
Type=Application
EOL

# --- First boot scraper (optional, lightweight) ---
cat > /home/$USERNAME/es_firstboot_scan.sh <<EOL
#!/bin/bash
emulationstation --scrape || true
touch /home/$USERNAME/.es_scanned
EOL

chmod +x /home/$USERNAME/es_firstboot_scan.sh
chown $USERNAME:$USERNAME /home/$USERNAME/es_firstboot_scan.sh

echo 'if [ ! -f $HOME/.es_scanned ]; then
    bash $HOME/es_firstboot_scan.sh
fi' >> "$BASH_PROFILE"

# --- Xboxdrv service ---
cat > /etc/systemd/system/xboxdrv.service <<EOL
[Unit]
Description=Xboxdrv controller mapping
After=multi-user.target

[Service]
ExecStart=/usr/bin/xboxdrv --daemon --detach-kernel-driver --silent
User=$USERNAME
Restart=always

[Install]
WantedBy=multi-user.target
EOL

systemctl enable xboxdrv.service

# --- Clean system (remove bloat safely) ---
apt -y purge libreoffice* thunderbird* hexchat* transmission* rhythmbox* gnome-games gnome-sudoku gnome-mahjongg gnome-mines || true
apt -y autoremove --purge
apt clean

# --- Final permissions ---
chown -R $USERNAME:$USERNAME /home/$USERNAME

# --- Enable autologin service ---
systemctl enable getty@tty1.service

# --- Done ---
echo "===================================================="
echo "==> Pop!_OS Gamer Console Setup Complete!"
echo "==> User: $USERNAME | Password: $USERNAME"
echo "==> Boot directly into EmulationStation (TTY1)"
echo "==> ROMs: $ROM_DIR"
echo "==> Steam Library: /home/$USERNAME/SteamLibrary"
echo "==> Streaming Apps in EmulationStation > Streaming"
echo "==> XFCE Desktop available from menu"
echo "==> RGSX installed at /home/$USERNAME/rgsx"
echo "==> Xbox controller supported via xboxdrv"
echo "==> Reboot to start gaming!"
echo "===================================================="
