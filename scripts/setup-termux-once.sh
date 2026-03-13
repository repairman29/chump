#!/data/data/com.termux/files/usr/bin/bash
# One-time Termux setup: reliable SSH + deps for Mabel (llama.cpp Vulkan).
# Run once in Termux (from Downloads or after copying to ~/chump).
#
# Usage (in Termux):
#   termux-setup-storage   # if you haven't — then:
#   bash ~/storage/downloads/chump/setup-termux-once.sh
#   # or if files are in ~/chump already:
#   bash ~/chump/setup-termux-once.sh
#
# After this: install "Termux:Boot" from F-Droid and set Termux battery to
# Unrestricted so SSH stays up and Termux isn't killed in background.

set -e

echo "=== One-time Termux setup (SSH + Mabel deps) ==="

# 1. Packages: SSH server + shaderc (glslc for llama.cpp Vulkan build)
echo "Installing openssh and shaderc..."
pkg update -y
pkg install -y openssh shaderc

# 2. SSH key dir (so sshd can run)
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# 3. Start sshd on every boot (when Termux:Boot runs)
BOOT_DIR="$HOME/.termux/boot"
mkdir -p "$BOOT_DIR"
cat > "$BOOT_DIR/01-sshd.sh" << 'BOOT'
#!/data/data/com.termux/files/usr/bin/bash
# Start SSH so Mac can connect (port 8022). Run by Termux:Boot on device boot.
sshd
BOOT
chmod +x "$BOOT_DIR/01-sshd.sh"
echo "Created $BOOT_DIR/01-sshd.sh (runs when Termux:Boot starts Termux)."

# 4. Start sshd now so this session has SSH without rebooting
echo "Starting sshd now..."
sshd
echo "sshd running on port 8022."

# 5. Remind about SSH key (so Mac can log in without password)
if [[ ! -f ~/.ssh/authorized_keys ]] || [[ ! -s ~/.ssh/authorized_keys ]]; then
  echo ""
  echo "Add your Mac's SSH key so you can log in without a password:"
  echo "  On Mac:  cat ~/.ssh/id_ed25519.pub"
  echo "  In Termux: mkdir -p ~/.ssh && echo 'PASTE_THE_LINE_HERE' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
fi

echo ""
echo "--- Next steps ---"
echo "1. Install 'Termux:Boot' from F-Droid. After the next reboot, sshd will start automatically."
echo "2. Settings → Apps → Termux → Battery → set to 'Unrestricted' so Android doesn't kill Termux (and sshd) in background."
echo "3. Your username for SSH is: $(whoami)"
echo "4. From Mac: ssh -p 8022 $(whoami)@<pixel-ip>"
echo ""
echo "Done. Run setup-llama-on-termux.sh next to build llama.cpp and download the model."
