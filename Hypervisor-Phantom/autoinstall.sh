detect_distro() {
  local distro_id=""
  
  if [ -f /etc/os-release ]; then
    distro_id=$(grep ^ID= /etc/os-release | cut -d= -f2 | tr -d '"')
    case "$distro_id" in
      # Arch-based
      arch|manjaro|endeavouros|arcolinux|garuda|artix)
        DISTRO="Arch"
        ;;
        
      # openSUSE
      opensuse-tumbleweed|opensuse-slowroll|opensuse-leap|sles)
        DISTRO="openSUSE"
        ;;

      # Debian-based
      debian|ubuntu|linuxmint|kali|pureos|pop|elementary|zorin|mx|parrot|deepin|peppermint|trisquel|bodhi|linuxlite|neon)
        DISTRO="Debian"
        ;;
        
      # RHEL/Fedora-based
      fedora|centos|rhel|rocky|alma|oracle)
        DISTRO="Fedora"
        ;;
    esac
  fi

  # Fallback if DISTRO wasn't set by case statement
  if [ -z "$DISTRO" ]; then
    if command -v pacman &>/dev/null; then
      DISTRO="Arch"
    elif command -v apt &>/dev/null; then
      DISTRO="Debian"
    elif command -v zypper &>/dev/null; then
      DISTRO="openSUSE"
    elif command -v dnf &>/dev/null; then
      DISTRO="Fedora"
    else
      if [ -n "$distro_id" ]; then
        DISTRO="Unknown ($distro_id)"
      else
        DISTRO="Unknown"
      fi
    fi
  fi

  export DISTRO
  readonly DISTRO
}

cpu_vendor_id() {
  VENDOR_ID=$(LANG=en_US.UTF-8 lscpu 2>/dev/null | awk -F': +' '/^Vendor ID:/ {print $2}' | xargs)

  if [ -z "$VENDOR_ID" ]; then
    VENDOR_ID=$(awk -F': +' '/vendor_id/ {print $2; exit}' /proc/cpuinfo | xargs) # Fallback method
  fi

  : "${VENDOR_ID:=Unknown}"

  export VENDOR_ID
  readonly VENDOR_ID
}

detect_distro
cpu_vendor_id

if ! source "./utils/debugger.sh"; then
    echo "Log file at ${LOG_FILE} couldn't be generated. Check permissions!"
    exit 1
fi

./modules/virtualization.sh
./modules/patch_qemu.sh
./modules/patch_ovmf.sh
#./modules/patch_kernel.sh