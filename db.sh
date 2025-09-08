#!/bin/bash
# Debian all-in-one gamer + streaming + desktop + RGSX + standalone emulators
# Fully lightweight and Intel HD 4000 optimized

set -euo pipefail

# --- Configuration ---
USERNAME="gamer"
HOSTNAME="debian-console"
TIMEZONE="Asia/Kolkata"
LOCALE="en_US.UTF-8"

# --- Root check ---
if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root."
    exit 1
fi

# --- Update system ---
apt update && apt -y upgrade

# --- Install essentials ---
apt -y install sudo xorg lightdm lightdm-gtk-greeter \
    mesa-utils mesa-vulkan-drivers libgl1-mesa-dri \
    xserver-xorg-video-intel xserver-xorg-video-all \
    pulseaudio alsa-utils git curl wget unzip \
    emulationstation retroarch retroarch-* libretro-* \
    steam lutris xboxdrv antimicrox gamemode \
    cpufrequtils xfce4 xfce4-goodies pcsx2 dolphin-emu ppsspp flycast

# --- Microcode detection ---
CPU_VENDOR=$(awk -F: '/vendor_id/ {print $2; exit}' /proc/cpuinfo | tr -d '[:space:]')
MICROCODE_PKG="intel-microcode"
if echo "$CPU_VENDOR" | grep -qi "AuthenticAMD"; then
    MICROCODE_PKG="amd64-microcode"
fi
apt -y install "$MICROCODE_PKG"

# --- Create gamer user if not exists ---
if ! id "$USERNAME" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$USERNAME"
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
    echo "$USERNAME:$USERNAME" | chpasswd
fi

# --- Blacklist Radeon ---
echo "blacklist radeon" > /etc/modprobe.d/blacklist-radeon.conf
echo "blacklist amdgpu" >> /etc/modprobe.d/blacklist-radeon.conf

# --- Force Intel GPU ---
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/20-intel.conf <<EOL
Section "Device"
    Identifier "Intel Graphics"
    Driver "intel"
    BusID "PCI:0:2:0"
    Option "TearFree" "true"
EndSection
EOL

# --- Environment variables for Intel GPU ---
echo 'export DRI_PRIME=0' >> /home/$USERNAME/.bashrc
echo 'export LIBGL_ALWAYS_SOFTWARE=0' >> /home/$USERNAME/.bashrc
chown $USERNAME:$USERNAME /home/$USERNAME/.bashrc

# --- Auto-login & start EmulationStation ---
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOL
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USERNAME --noclear %I \$TERM
EOL

echo '[[ -z $DISPLAY && $XDG_VTNR -eq 1 ]] && exec startx /usr/bin/emulationstation -- :0' >> /home/$USERNAME/.bash_profile
chown $USERNAME:$USERNAME /home/$USERNAME/.bash_profile

# --- EmulationStation setup ---
ES_DIR="/home/$USERNAME/.emulationstation"
mkdir -p $ES_DIR/controllers $ES_DIR/themes $ES_DIR/collections $ES_DIR/custom_apps

# --- Default ES Gaming Systems ---
cat > $ES_DIR/es_settings.cfg <<EOL
<?xml version="1.0"?>
<systemList>
    <system>
        <name>arcade</name>
        <path>/home/$USERNAME/ROMs/arcade</path>
        <extension>.zip .7z</extension>
        <command>retroarch -L /usr/lib/libretro/fbalpha_libretro.so %ROM%</command>
        <platform>arcade</platform>
        <theme>default</theme>
    </system>
    <system>
        <name>nes</name>
        <path>/home/$USERNAME/ROMs/nes</path>
        <extension>.nes</extension>
        <command>retroarch -L /usr/lib/libretro/fceumm_libretro.so %ROM%</command>
        <platform>nes</platform>
        <theme>default</theme>
    </system>
    <system>
        <name>dreamcast</name>
        <path>/home/$USERNAME/ROMs/dreamcast</path>
        <extension>.cdi .gdi .chd .iso</extension>
        <command>flycast %ROM%</command>
        <platform>dreamcast</platform>
        <theme>default</theme>
    </system>
    <system>
        <name>ps2</name>
        <path>/home/$USERNAME/ROMs/ps2</path>
        <extension>.iso .bin .img .cue</extension>
        <command>pcsx2 %ROM%</command>
        <platform>ps2</platform>
        <theme>default</theme>
    </system>
    <system>
        <name>psp</name>
        <path>/home/$USERNAME/ROMs/psp</path>
        <extension>.iso .cso</extension>
        <command>ppsspp %ROM%</command>
        <platform>psp</platform>
        <theme>default</theme>
    </system>
    <system>
        <name>gamecube</name>
        <path>/home/$USERNAME/ROMs/gamecube</path>
        <extension>.iso .gcm</extension>
        <command>dolphin-emu %ROM%</command>
        <platform>gamecube</platform>
        <theme>default</theme>
    </system>
    <system>
        <name>wii</name>
        <path>/home/$USERNAME/ROMs/wii</path>
        <extension>.iso</extension>
        <command>dolphin-emu %ROM%</command>
        <platform>wii</platform>
        <theme>default</theme>
    </system>
</systemList>
EOL

# --- Controller config ---
cat > $ES_DIR/controllers/default.cfg <<EOL
input_player1_joypad = "xbox"
input_player2_joypad = "xbox"
EOL

# --- Theme config ---
cat > $ES_DIR/themes/theme.cfg <<EOL
theme=carbon
showHiddenFiles=true
EOL

# --- Custom Apps: Steam, Lutris, Desktop ---
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
Name=Desktop
Exec=startxfce4
Type=Application
EOL

# --- Clone RGSX and add to custom apps ---
sudo -u $USERNAME git clone https://github.com/RetroGameSets/RGSX.git /home/$USERNAME/rgsx || true
chmod +x /home/$USERNAME/rgsx/rgsx.sh
chown -R $USERNAME:$USERNAME /home/$USERNAME/rgsx

cat > $ES_DIR/custom_apps/rgsx.desktop <<EOL
[Desktop Entry]
Name=RGSX
Exec=/home/$USERNAME/rgsx/rgsx.sh
Type=Application
EOL

# --- Streaming Section ---
mkdir -p $ES_DIR/collections/streaming
wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | apt-key add -
echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
curl -sS https://download.spotify.com/debian/pubkey_0D811D58.gpg | apt-key add -
echo "deb http://repository.spotify.com stable non-free" > /etc/apt/sources.list.d/spotify.list
apt update
apt -y install google-chrome-stable spotify-client

declare -A STREAM_APPS
STREAM_APPS["Netflix"]="google-chrome-stable https://www.netflix.com"
STREAM_APPS["Prime Video"]="google-chrome-stable https://www.primevideo.com"
STREAM_APPS["Apple TV"]="google-chrome-stable https://tv.apple.com"
STREAM_APPS["Disney+"]="google-chrome-stable https://www.disneyplus.com"
STREAM_APPS["Crunchyroll"]="google-chrome-stable https://www.crunchyroll.com"
STREAM_APPS["Spotify"]="spotify"

for app in "${!STREAM_APPS[@]}"; do
cat > $ES_DIR/collections/streaming/${app// /}.desktop <<EOL
[Desktop Entry]
Name=$app
Exec=${STREAM_APPS[$app]}
Type=Application
EOL
done

# --- Clone Batocera theme ---
sudo -u $USERNAME git clone https://github.com/batocera-linux/batocera-emulationstation-theme.git $ES_DIR/themes/Batocera41 || true

# --- Xboxdrv service (controller mapping) ---
cat > /etc/systemd/system/xboxdrv.service <<EOL
[Unit]
Description=Xboxdrv controller mapping
After=network.target

[Service]
ExecStart=/usr/bin/xboxdrv --detach-kernel-driver --mimic-xpad --axismap="REL_X=RX*2,REL_Y=RY*2" --mouse --trigger-as-button --buttonmap="LT=BTN_LEFT,RT=BTN_RIGHT" --ui-buttonmap="A=ENTER,B=ESC,Y=TAB,X=SPACE,START=ENTER,SELECT=ESC" --evdev /dev/input/event* --silent
User=$USERNAME
Restart=always

[Install]
WantedBy=multi-user.target
EOL
systemctl enable xboxdrv.service

# --- Pre-create ROM directories ---
ROM_DIR="/home/$USERNAME/ROMs"
SYSTEMS=("arcade" "nes" "snes" "gba" "n64" "psx" "ps2" "psp" "dreamcast" "gamecube" "wii")
for sys in "${SYSTEMS[@]}"; do
    mkdir -p "$ROM_DIR/$sys"
done
chown -R $USERNAME:$USERNAME "$ROM_DIR"

# --- Pre-create Steam library ---
STEAM_DIR="/home/$USERNAME/SteamLibrary"
mkdir -p "$STEAM_DIR/games"
chown -R $USERNAME:$USERNAME "$STEAM_DIR"

# --- First boot ES scan ---
cat > /home/$USERNAME/es_firstboot_scan.sh <<EOL
#!/bin/bash
# Scan all systems for games
emulationstation --scrape --batch
EOL
chmod +x /home/$USERNAME/es_firstboot_scan.sh
chown $USERNAME:$USERNAME /home/$USERNAME/es_firstboot_scan.sh

echo 'if [ ! -f /home/$USERNAME/.es_scanned ]; then
    /home/$USERNAME/es_firstboot_scan.sh
    touch /home/$USERNAME/.es_scanned
fi' >> /home/$USERNAME/.bash_profile

# --- Remove unused apps to keep lightweight ---
apt -y purge libreoffice* thunderbird* rhythmbox* hexchat* transmission* gnome-* \
    && apt -y autoremove --purge

# --- Permissions ---
chown -R $USERNAME:$USERNAME $ES_DIR
chown -R $USERNAME:$USERNAME /home/$USERNAME/rgsx

# --- Enable LightDM ---
systemctl enable lightdm

echo "==> Debian gamer + streaming + desktop + RGSX setup complete!"
echo "Reboot to auto-login into EmulationStation with Intel GPU only."
