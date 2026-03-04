#!/usr/bin/env bash

[[ -z "$DISTRO" || -z "$LOG_FILE" ]] && { echo "Required environment variables not set."; exit 1; }

source "./utils/formatter.sh"
source "./utils/prompter.sh"
source "./utils/packages.sh"

declare -r CPU_VENDOR=$(case "$VENDOR_ID" in
  *AuthenticAMD*) echo "amd" ;;
  *GenuineIntel*) echo "intel" ;;
  *) fmtr::error "Unknown CPU Vendor ID."; exit 1 ;;
esac)

readonly SRC_DIR="$(pwd)/src"
readonly EDK2_URL="https://github.com/tianocore/edk2.git"
readonly EDK2_TAG="edk2-stable202508"
readonly PATCH_DIR="$(pwd)/patches/EDK2"
readonly OVMF_PATCH="${CPU_VENDOR}-${EDK2_TAG}.patch"

REQUIRED_PKGS_Arch=(base-devel acpica git nasm python patch virt-firmware)
REQUIRED_PKGS_Debian=(build-essential uuid-dev acpica-tools git nasm python-is-python3 patch python3-virt-firmware)
REQUIRED_PKGS_openSUSE=(gcc gcc-c++ make acpica git nasm python3 libuuid-devel patch virt-firmware)
REQUIRED_PKGS_Fedora=(gcc gcc-c++ make acpica-tools git nasm python3 libuuid-devel patch python3-virt-firmware)

################################################################################
# Acquire EDK2 source
################################################################################
acquire_edk2_source() {
  mkdir -p "$SRC_DIR" && cd "$SRC_DIR" || { fmtr::fatal "Failed to enter source dir: $SRC_DIR"; exit 1; }

  clone_init() {
    git clone --single-branch --depth=1 --branch "$EDK2_TAG" "$EDK2_URL" "$EDK2_TAG" &>>"$LOG_FILE" \
      || { fmtr::fatal "Failed to clone repository."; exit 1; }
    cd "$EDK2_TAG" || { fmtr::fatal "Failed to enter EDK2 directory: $EDK2_TAG"; exit 1; }
    fmtr::info "Initializing submodules... (be patient)"
    git submodule update --init &>>"$LOG_FILE" \
      || { fmtr::fatal "Failed to initialize submodules."; exit 1; }
    fmtr::info "EDK2 source successfully acquired and submodules initialized."
    patch_ovmf
  }

  if [ -d "$EDK2_TAG" ]; then
    fmtr::warn "EDK2 source directory '$EDK2_TAG' detected."
    fmtr::info "Purging EDK2 source directory (automated)."
    rm -rf "$EDK2_TAG" || { fmtr::fatal "Failed to remove existing directory: $EDK2_TAG"; exit 1; }
    fmtr::info "Directory purged successfully."
    fmtr::info "Cloning the EDK2 repository (automated)."
    clone_init
  else
    clone_init
  fi
}

################################################################################
# Patch OVMF
################################################################################
patch_ovmf() {
  [ -d "$PATCH_DIR" ] || fmtr::fatal "Patch directory $PATCH_DIR not found!"
  [ -f "$PATCH_DIR/$OVMF_PATCH" ] || { fmtr::error "Patch file $PATCH_DIR/$OVMF_PATCH not found!"; return 1; }

  fmtr::log "Patching OVMF with '$OVMF_PATCH'..."
  git apply < "$PATCH_DIR/$OVMF_PATCH" &>>"$LOG_FILE" || { fmtr::error "Failed to apply patch '$OVMF_PATCH'!"; return 1; }
  fmtr::info "Patch '$OVMF_PATCH' applied successfully."

  fmtr::log "Applying host's BGRT BMP boot logo image (automated - option 1)."
  if [ -f /sys/firmware/acpi/bgrt/image ]; then
    cp /sys/firmware/acpi/bgrt/image MdeModulePkg/Logo/Logo.bmp \
      && fmtr::info "Image replaced successfully." \
      || fmtr::error "Image not found or failed to copy."
  else
    fmtr::error "Host BMP image not found."
  fi
}

################################################################################
# Compile OVMF
################################################################################
compile_ovmf() {
  export WORKSPACE=$(pwd)
  export EDK_TOOLS_PATH="$WORKSPACE/BaseTools"
  export CONF_PATH="$WORKSPACE/Conf"

  fmtr::log "Building BaseTools (EDK II build tools)..."
  [ -d BaseTools/Build ] || { make -C BaseTools && source edksetup.sh; } &>>"$LOG_FILE" || { fmtr::fatal "Failed to build BaseTools"; exit 1; }

  fmtr::log "Compiling OVMF with SB and TPM support..."
  build -a X64 -p OvmfPkg/OvmfPkgX64.dsc -b RELEASE -t GCC5 -n 0 -s -q \
    --define SECURE_BOOT_ENABLE=TRUE \
    --define TPM_CONFIG_ENABLE=TRUE \
    --define TPM_ENABLE=TRUE \
    --define TPM1_ENABLE=TRUE \
    --define TPM2_ENABLE=TRUE &>>"$LOG_FILE" || { fmtr::fatal "OVMF build failed"; exit 1; }

  fmtr::log "Converting compiled OVMF to .qcow2 format..."
  out_dir="../output/firmware"
  mkdir -p "$out_dir"
  for f in CODE.secboot.4m VARS.4m; do
    src="Build/OvmfX64/RELEASE_GCC5/FV/OVMF_${f%%.*}.fd"
    dest="$out_dir/OVMF_${f}.qcow2"
    qemu-img convert -f raw -O qcow2 "$src" "$dest" || { fmtr::fatal "Failed to convert $src"; exit 1; }
  done
}

################################################################################
# Certificate injection
################################################################################
cert_injection() {
  readonly URL="https://raw.githubusercontent.com/microsoft/secureboot_objects/main/PreSignedObjects"
  readonly UUID="77fa9abd-0359-4d32-bd60-28f4e78f784b"
  local TEMP_DIR VM_NAME VARS_FILE NVRAM_DIR="/var/lib/libvirt/qemu/nvram"

  TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR" || { fmtr::fatal "Failed to enter temp dir"; exit 1; }

  fmtr::log "Available domains:"; echo ""
  mapfile -t VMS < <(virsh list --all --name | grep -v '^$')
  [ ${#VMS[@]} -gt 0 ] || { fmtr::fatal "No domains found!"; rm -rf "$TEMP_DIR"; exit 1; }

  for i in "${!VMS[@]}"; do
    fmtr::format_text '  ' "[$((i+1))]" " ${VMS[$i]}" "$TEXT_BRIGHT_YELLOW"
  done

  fmtr::info "Selecting first VM automatically (automated - option 1)."
  vm_choice=1
  VM_NAME="${VMS[$((vm_choice-1))]}"
  VARS_FILE="$NVRAM_DIR/${VM_NAME}_VARS.qcow2"
  [ -f "$VARS_FILE" ] || { fmtr::fatal "File not found: $VARS_FILE"; exit 1; }
  fmtr::log "Using '$VARS_FILE' as the base VARS file."

  fmtr::info "Downloading Microsoft's Secure Boot certifications..."
  declare -A CERTS=(
    ["ms_pk_oem.der"]="$URL/PK/Certificate/WindowsOEMDevicesPK.der"
    ["ms_kek_2011.der"]="$URL/KEK/Certificates/MicCorKEKCA2011_2011-06-24.der"
    ["ms_kek_2023.der"]="$URL/KEK/Certificates/microsoft%20corporation%20kek%202k%20ca%202023.der"
    ["ms_db_uef_2011.der"]="$URL/DB/Certificates/MicCorUEFCA2011_2011-06-27.der"
    ["ms_db_pro_2011.der"]="$URL/DB/Certificates/MicWinProPCA2011_2011-10-19.der"
    ["ms_db_optionrom_2023.der"]="$URL/DB/Certificates/microsoft%20option%20rom%20uefi%20ca%202023.der"
    ["ms_db_uefi_2023.der"]="$URL/DB/Certificates/microsoft%20uefi%20ca%202023.der"
    ["ms_db_windows_2023.der"]="$URL/DB/Certificates/windows%20uefi%20ca%202023.der"
    ["dbxupdate_x64.bin"]="https://uefi.org/sites/default/files/resources/dbxupdate_x64.bin"
  )

  for file in "${!CERTS[@]}"; do
    wget -q -O "$file" "${CERTS[$file]}" &
  done
  wait || { fmtr::fatal "Failed to download one or more certs"; exit 1; }

  fmtr::info "Injecting MS SB certs into '$VARS_FILE'..."
  virt-fw-vars --input "$VARS_FILE" --output "$NVRAM_DIR/${VM_NAME}_SECURE_VARS.qcow2" \
    --secure-boot \
    --set-pk "$UUID" ms_pk_oem.der \
    --add-kek "$UUID" ms_kek_2011.der \
    --add-kek "$UUID" ms_kek_2023.der \
    --add-db "$UUID" ms_db_uef_2011.der \
    --add-db "$UUID" ms_db_pro_2011.der \
    --add-db "$UUID" ms_db_optionrom_2023.der \
    --add-db "$UUID" ms_db_uefi_2023.der \
    --add-db "$UUID" ms_db_windows_2023.der \
    --set-dbx dbxupdate_x64.bin &>>"$LOG_FILE" || { fmtr::fatal "Failed to inject SB certs"; exit 1; }

  fmtr::log "Secure VARS generated at '$NVRAM_DIR/${VM_NAME}_SECURE_VARS.qcow2'"
  fmtr::info "Cleaning up..."
  rm -rf "$TEMP_DIR"
}

################################################################################
# Cleanup
################################################################################
cleanup() {
  fmtr::info "Cleaning up..."
  rm -rf "$SRC_DIR/$EDK2_TAG"
  rmdir --ignore-fail-on-non-empty "$SRC_DIR" 2>/dev/null || true
}

################################################################################
# Main menu
################################################################################
main() {
  install_req_pkgs "EDK2"

  fmtr::info "Creating patched OVMF (automated - option 1)."
  acquire_edk2_source
  fmtr::info "Compiling patched OVMF (automated)."
  compile_ovmf
  fmtr::info "Cleaning up EDK2 source (automated)."
  cleanup
}

main "$@"
