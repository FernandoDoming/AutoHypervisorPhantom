#!/usr/bin/env bash

# Usage: install_req_pkgs <component_name>
install_req_pkgs() {
  [[ -z "$1" ]] && { fmtr::error "Component name not specified!"; exit 1; }
  local component="$1"

  fmtr::log "Checking for required missing $component packages..."

  # Determine if we need sudo
  local SUDO_CMD=""
  if [[ $EUID -ne 0 ]]; then
    SUDO_CMD="sudo"
  fi

  # Determine package manager commands
  case "$DISTRO" in
    Arch)
      PKG_MANAGER="pacman"
      INSTALL_CMD="$SUDO_CMD pacman -S --noconfirm"
      CHECK_CMD="pacman -Q"
      UPDATE_CMD="$SUDO_CMD pacman -Sy"
      ;;
    Debian)
      PKG_MANAGER="apt"
      INSTALL_CMD="$SUDO_CMD apt -y install"
      CHECK_CMD="dpkg -s"
      UPDATE_CMD="$SUDO_CMD apt update"
      ;;
    openSUSE)
      PKG_MANAGER="zypper"
      INSTALL_CMD="$SUDO_CMD zypper install -y"
      CHECK_CMD="rpm -q"
      UPDATE_CMD="$SUDO_CMD zypper refresh"
      ;;
    Fedora)
      PKG_MANAGER="dnf"
      INSTALL_CMD="$SUDO_CMD dnf -yq install"
      CHECK_CMD="rpm -q"
      UPDATE_CMD="$SUDO_CMD dnf check-update"
      ;;
    *)
      fmtr::error "Unsupported distribution: $DISTRO."
      exit 1
      ;;
  esac

  # Load required packages from caller's distro-specific array
  local pkg_var="REQUIRED_PKGS_${DISTRO}"
  if [[ ! -v "$pkg_var" ]]; then
    fmtr::error "$component packages undefined for $DISTRO."
    exit 1
  fi
  declare -n REQUIRED_PKGS_REF="$pkg_var"
  local REQUIRED_PKGS=("${REQUIRED_PKGS_REF[@]}")

  # Check for missing packages
  local MISSING_PKGS=()
  for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! $CHECK_CMD "$pkg" &>/dev/null; then
      MISSING_PKGS+=("$pkg")
    fi
  done

  if [[ ${#MISSING_PKGS[@]} -eq 0 ]]; then
    fmtr::log "All required $component packages already installed."
    return 0
  fi

  # Handle installation
  fmtr::warn "Missing required $component packages: ${MISSING_PKGS[*]}"
  
  # Update package cache for Debian-based systems
  if [[ "$DISTRO" == "Debian" ]]; then
    fmtr::info "Updating package cache..."
    if ! $UPDATE_CMD &>> "$LOG_FILE"; then
      fmtr::warn "Failed to update package cache, continuing anyway..."
    fi
  fi
  
  fmtr::info "Installing required missing $component packages (automated)..."
  if ! $INSTALL_CMD "${MISSING_PKGS[@]}" &>> "$LOG_FILE"; then
    fmtr::error "Failed to install required $component packages"
    fmtr::error "Check log file for details: $LOG_FILE"
    exit 1
  fi
  fmtr::log "Installed: ${MISSING_PKGS[*]}"
}
