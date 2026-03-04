#!/usr/bin/env bash

[[ -z "$DISTRO" || -z "$LOG_FILE" ]] && { echo "Required environment variables not set."; exit 1; }

source "./utils/prompter.sh"
source "./utils/formatter.sh"
source "./utils/packages.sh"

readonly SRC_DIR="src"
readonly TKG_URL="https://github.com/Frogging-Family/linux-tkg.git"
readonly TKG_DIR="linux-tkg"
readonly TKG_CFG_DIR="../../$SRC_DIR/linux-tkg/customization.cfg"
readonly PATCH_DIR="../../patches/Kernel"
readonly KERNEL_MAJOR="6"
readonly KERNEL_MINOR="14"
readonly KERNEL_PATCH="latest" # Set as "-latest" for linux-tkg
readonly KERNEL_VERSION="${KERNEL_MAJOR}.${KERNEL_MINOR}-${KERNEL_PATCH}"
readonly KERNEL_USER_PATCH="../../patches/Kernel/zen-kernel-${KERNEL_MAJOR}.${KERNEL_MINOR}-${KERNEL_PATCH}-${CPU_VENDOR}.mypatch"
readonly REQUIRED_DISK_SPACE="35"

check_disk_space() {
  local build_path="${1:-$(pwd)}"
  local required_bytes=$((REQUIRED_DISK_SPACE * 1024 * 1024 * 1024))

  local mountpoint
  mountpoint=$(df --output=target "$build_path" | tail -1)
  local available_bytes=$(($(stat -f --format="%a*%S" "$mountpoint")))
  local required_gb=$(awk "BEGIN {printf \"%.1f\", $required_bytes/1024/1024/1024}")
  local available_gb=$(awk "BEGIN {printf \"%.1f\", $available_bytes/1024/1024/1024}")

  if (( available_bytes < required_bytes )); then
    fmtr::error "Insufficient disk space on $mountpoint."
    fmtr::error "Available: ${available_gb}GB, Required: ${required_gb}GB"
    exit 1
  fi

  fmtr::info "Sufficient drive space: ${available_gb}GB available on '$mountpoint' (Required: ${required_gb}GB)"
}

acquire_tkg_source() {

  mkdir -p "$SRC_DIR" && cd "$SRC_DIR"

  if [ -d "$TKG_DIR" ]; then
    if [ -d "$TKG_DIR/.git" ]; then
      fmtr::warn "Directory $TKG_DIR already exists and is a valid Git repository."
      fmtr::info "Deleting and re-cloning the linux-tkg source (automated)."
    else
      fmtr::warn "Directory $TKG_DIR exists but is not a valid Git repository."
      fmtr::info "Deleting and re-cloning the linux-tkg source (automated)."
    fi
    rm -rf "$TKG_DIR" || { fmtr::fatal "Failed to remove existing directory: $TKG_DIR"; exit 1; }
    fmtr::info "Directory purged"
  fi

  fmtr::info "Cloning linux-tkg repository..."
  git clone --single-branch --depth=1 "$TKG_URL" "$TKG_DIR" &>> "$LOG_FILE" || { fmtr::fatal "Failed to clone repository."; exit 1; }
  cd "$TKG_DIR" || { fmtr::fatal "Failed to change to TKG directory after cloning: $TKG_DIR"; exit 1; }
  fmtr::info "TKG source successfully acquired."

  grep -RIl '\-Werror' "$(pwd)" | while read -r file; do
      echo "$file"
      sed -i -e 's/-Werror=/\-W/g' -e 's/-Werror-/\-W/g' -e 's/-Werror/\-W/g' "$file"
  done &>> "$LOG_FILE" || { fmtr::fatal "Failed to disable warnings-as-errors!"; exit 1; }

}


select_distro() {
  fmtr::info "Selecting Linux distribution: Debian (automated)."
  distro="Debian"
}


modify_customization_cfg() {

  ####################################################################################################
  ####################################################################################################

  fmtr::info "This patch enables corrected IOMMU grouping on
      motherboards with bad PCI IOMMU grouping."
  fmtr::info "Applying ACS override bypass Kernel patch (automated)."
  acs="true"

  ####################################################################################################
  ####################################################################################################

  if [[ "$VENDOR_ID" == *AuthenticAMD* ]]; then
    vendor="AMD"
    fmtr::info "Detected CPU Vendor: $vendor - Selecting first option (automated - k8)."
    selected="k8"
  elif [[ "$VENDOR_ID" == *GenuineIntel* ]]; then
    vendor="Intel"
    fmtr::info "Detected CPU Vendor: $vendor - Selecting first option (automated - mpsc)."
    selected="mpsc"
  else
    fmtr::warn "Unsupported or undefined CPU_VENDOR: $CPU_VENDOR"
    exit 1
  fi

  ####################################################################################################
  ####################################################################################################

  if output=$(/lib/ld-linux-x86-64.so.2 --help 2>/dev/null | grep supported); then
      :
  elif output=$(/lib64/ld-linux-x86-64.so.2 --help 2>/dev/null | grep supported); then
      :
  fi

  highest=0

  while IFS= read -r line; do
      if [[ $line =~ x86-64-v([123]) ]]; then
          version="${BASH_REMATCH[1]}"
          if (( version > highest )); then
              highest=$version
          fi
      fi
  done <<< "$output"

  x86_version=$highest

  ####################################################################################################
  ####################################################################################################

  declare -A config_values=(
      [_distro]="$distro"
      [_version]="$KERNEL_VERSION"
      [_menunconfig]="false"
      [_diffconfig]="false"
      [_cpusched]="eevdf"
      [_compiler]="gcc"
      [_sched_yield_type]="0"
      [_rr_interval]="2"
      [_tickless]="1"
      [_acs_override]="$acs"
      [_processor_opt]="$selected"
      [_x86_64_isalvl]="$highest"
      [_timer_freq]="1000"
      [_user_patches_no_confirm]="true"
  )

  for key in "${!config_values[@]}"; do
      sed -i "s|$key=\"[^\"]*\"|$key=\"${config_values[$key]}\"|" "$TKG_CFG_DIR" &>> "$LOG_FILE"
  done

}

patch_kernel() {

  mkdir -p "linux${KERNEL_MAJOR}${KERNEL_MINOR}-tkg-userpatches"
  cp "${KERNEL_USER_PATCH}" "linux${KERNEL_MAJOR}${KERNEL_MINOR}-tkg-userpatches"

}

arch_distro() {

  makepkg -C -si --noconfirm

  fmtr::info "Adding systemd-boot entry for this kernel (automated)."
  systemd-boot_boot_entry_maker

}

other_distro() {

  echo "Y" | ./install.sh install

  fmtr::info "Adding systemd-boot entry for this kernel (automated)."
  systemd-boot_boot_entry_maker

}

systemd-boot_boot_entry_maker() {

  declare -a SDBOOT_CONF_LOCATIONS=(
    "/boot/loader/entries"
    "/boot/efi/loader/entries"
    "/efi/loader/entries"
  )

  local ENTRY_NAME="HvP-RDTSC"
  local TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
  local ROOT_DEVICE=$(findmnt -no SOURCE /)
  local ROOTFSTYPE=$(findmnt -no FSTYPE /)
  local PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_DEVICE")

  if [[ -z "$PARTUUID" ]]; then
    fmtr::error "Unable to determine PARTUUID for root device ($ROOT_DEVICE)."
    return 1
  fi

  local BOOT_ENTRY_CONTENT=$(cat <<EOF
# Created by: Hypervisor-Phantom
# Created on: $TIMESTAMP
title   HvP (RDTSC Patch)
linux   /vmlinuz-linux$KERNEL_MAJOR$KERNEL_MINOR-tkg-eevdf
initrd  /initramfs-linux$KERNEL_MAJOR$KERNEL_MINOR-tkg-eevdf.img
options root=PARTUUID=$PARTUUID rw rootfstype=$ROOTFSTYPE
EOF
)

  local FALLBACK_BOOT_ENTRY_CONTENT=$(cat <<EOF
# Created by: Hypervisor-Phantom
# Created on: $TIMESTAMP
title   HvP (RDTSC Patch - Fallback)
linux   /vmlinuz-linux$KERNEL_MAJOR$KERNEL_MINOR-tkg-eevdf
initrd  /initramfs-linux$KERNEL_MAJOR$KERNEL_MINOR-tkg-eevdf-fallback.img
options root=PARTUUID=$PARTUUID rw rootfstype=$ROOTFSTYPE
EOF
)

  for ENTRY_DIR in "${SDBOOT_CONF_LOCATIONS[@]}"; do
    if [[ -d "$ENTRY_DIR" ]]; then
      echo "$BOOT_ENTRY_CONTENT" | tee "$ENTRY_DIR/$ENTRY_NAME.conf" &>> "$LOG_FILE"
      echo "$FALLBACK_BOOT_ENTRY_CONTENT" | tee "$ENTRY_DIR/$ENTRY_NAME-fallback.conf" &>> "$LOG_FILE"
      if [[ $? -eq 0 ]]; then
        fmtr::info "Boot entries written to: $ENTRY_DIR/$ENTRY_NAME.conf and $ENTRY_DIR/$ENTRY_NAME-fallback.conf"
        return 0
      else
        fmtr::error "Failed to write boot entries to: $ENTRY_DIR/$ENTRY_NAME.conf and $ENTRY_DIR/$ENTRY_NAME-fallback.conf"
        return 1
      fi
    fi
  done

  fmtr::error "No valid systemd-boot entry directory found."
  return 1

}

check_disk_space
acquire_tkg_source
select_distro
modify_customization_cfg
patch_kernel

if [ "$distro" == "Arch" ]; then
    arch_distro
else
    other_distro
fi
