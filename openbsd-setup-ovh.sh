#!/usr/bin/env bash
# OpenBSD installer entry for existing Debian/Ubuntu GRUB installations.
# Run with bash, not sh. This script does not partition disks or reboot.
set -Eeuo pipefail
export LC_ALL=C
umask 022

# Change only this field to select another published release, e.g. "8.0".
OPENBSD_VERSION="7.9"
MARKER='# Managed by openbsd-setup-ovh'
ENTRY_ID=openbsd-installer
ENTRY_FILE=/etc/grub.d/42_openbsd_installer
DEFAULT_FILE=/etc/default/grub.d/zz-openbsd-installer.cfg
GRUB_CONFIG=/boot/grub/grub.cfg
CHECK_ONLY=0
ESP_REQUESTED=
WORK=
COMMITTED=0
declare -a SAVED_PATHS=() SAVED_COPIES=() SAVED_PRESENT=()

info() {
    local message=$*
    # Highlight status labels while keeping their values in the default color.
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} && $message == *': '* ]]; then
        printf '\033[1;92m%s:\033[0m %s\n' "${message%%: *}" "${message#*: }"
    else
        printf '%s\n' "$message"
    fi
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

show_banner() {
    # Keep redirected output and terminals without color support readable.
    if [[ ! -t 1 || ${TERM:-dumb} == dumb || -n ${NO_COLOR:-} ]]; then
        printf 'openbsd-setup-ovh.sh - ver. 1.0\nDesigned by Özgür Konstantin Kazanççı (2026).\nozgur@kazancci.com\n\n'
        return 0
    fi

    local reset=$'\033[0m' green=$'\033[32m'
    local glow=$'\033[1;92m'
    local border='  +==========================================================+'

    printf '\n%s%s%s\n\n' "$green" "$border" "$reset"
    printf '%s    >> openbsd-setup-ovh.sh - ver. 1.0%s\n' "$glow" "$reset"
    printf '%s    >> Designed by Özgür Konstantin Kazanççı (2026).%s\n' "$glow" "$reset"
    printf '%s    >> ozgur@kazancci.com%s\n\n' "$green" "$reset"
    printf '%s%s%s\n\n' "$green" "$border" "$reset"
}

usage() {
    show_banner
    cat <<HELP
Usage: sudo bash openbsd-setup-ovh.sh [--check] [--esp /boot/efi]

  --check      Run read-only preflight checks; do not download or modify files or packages.
  --esp PATH   Mount point of an already mounted EFI System Partition for UEFI.
  --help       Show this help message.

Supported hosts: x86_64 Debian 11/12/13; Ubuntu 22.04/24.04/26.04; existing GRUB.
BIOS: GRUB loads bsd.rd using kopenbsd.
UEFI: Secure Boot must be disabled. GRUB starts the OpenBSD EFI loader;
      at the boot> prompt in the KVM console, enter: boot esp:$EFI_RAMDISK
Selected OpenBSD release: $OPENBSD_VERSION (OPENBSD_VERSION at the top of this script).
Download directory: $DOWNLOAD_BASE
SHA256 manifest: $CHECKSUM_URL
The UEFI method requires OpenBSD 7.9 or later.
This script does not reboot automatically or partition disks.
HELP
}

configure_release() {
    [[ $OPENBSD_VERSION =~ ^[1-9][0-9]*\.[0-9]$ ]] ||
        die 'OPENBSD_VERSION must use the major.minor format, for example 7.9 or 8.0.'
    RELEASE_CODE=${OPENBSD_VERSION/./}
    DOWNLOAD_BASE="https://cdn.openbsd.org/pub/OpenBSD/$OPENBSD_VERSION/amd64"
    CHECKSUM_URL="$DOWNLOAD_BASE/SHA256"
    RAMDISK_URL="$DOWNLOAD_BASE/bsd.rd"
    EFI_URL="$DOWNLOAD_BASE/BOOTX64.EFI"
    EFI_RAMDISK="obsd$RELEASE_CODE.rd"
    EFI_DIRECTORY="EFI/OpenBSD-Installer/$RELEASE_CODE"
    BIOS_DIRECTORY="/boot/openbsd-installer/$RELEASE_CODE"
    # Never reuse checksums from a previously selected release.
    RAMDISK_SHA256=
    EFI_SHA256=
}

check_release_firmware() {
    local major=${OPENBSD_VERSION%.*} minor=${OPENBSD_VERSION#*.}
    if [[ $1 == uefi && ${#major} == 1 ]] && ((major < 7 || (major == 7 && minor < 9))); then
        die 'Loading a kernel from the ESP in UEFI mode requires OpenBSD 7.9 or later.'
    fi
}

supported_os() {
    case "$1:$2" in
        debian:11|debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) return 0 ;;
        *) return 1 ;;
    esac
}

safe_grub_value() {
    # Values are put inside GRUB single quotes. Refuse shell/GRUB metacharacters.
    [[ -n $1 && $1 != *[!a-zA-Z0-9_./:@,+-]* ]]
}

verify_download() {
    local file=$1 expected=$2 actual
    actual=$(sha256sum -- "$file")
    actual=${actual%% *}
    [[ $actual == "$expected" ]] || die "SHA256 mismatch: ${file##*/}"
    info "${file##*/}: SHA256 OK"
}

checksum_for() {
    # Parse only the named release file, never execute a downloaded manifest
    # or pass arbitrary manifest paths to sha256sum --check.
    local filename=$1 manifest=$2 digest
    digest=$(awk -v name="$filename" '
        $1 == "SHA256" && $2 == "(" name ")" && $3 == "=" {
            count++
            if (NF != 4 || length($4) != 64 || $4 ~ /[^0-9A-Fa-f]/)
                invalid = 1
            else
                hash = tolower($4)
        }
        END {
            if (count != 1 || invalid) exit 1
            print hash
        }
    ' "$manifest") || die "Expected exactly one valid SHA256 manifest entry for: $filename"
    printf '%s\n' "$digest"
}

download_file() {
    local url=$1 output=$2
    curl --fail --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 20 --max-time 300 --retry 3 --output "$output" "$url" ||
        die "Download failed: $url. Check that the selected release is available on the mirror."
}

fetch_release_files() {
    download_file "$CHECKSUM_URL" "$WORK/SHA256"
    RAMDISK_SHA256=$(checksum_for bsd.rd "$WORK/SHA256")
    if [[ $MODE == uefi ]]; then
        EFI_SHA256=$(checksum_for BOOTX64.EFI "$WORK/SHA256")
    fi
    download_file "$RAMDISK_URL" "$WORK/bsd.rd"
    verify_download "$WORK/bsd.rd" "$RAMDISK_SHA256"
    if [[ $MODE == uefi ]]; then
        download_file "$EFI_URL" "$WORK/BOOTX64.EFI"
        verify_download "$WORK/BOOTX64.EFI" "$EFI_SHA256"
    fi
}

remember_file() {
    local path=$1 copy="$WORK/backup-${#SAVED_PATHS[@]}" present=0
    [[ ! -L $path ]] || die "Refusing to overwrite a symbolic link: $path"
    if [[ -e $path ]]; then
        [[ -f $path ]] || die "Not a regular file: $path"
        cp -p -- "$path" "$copy"
        present=1
    fi
    SAVED_PATHS+=("$path")
    SAVED_COPIES+=("$copy")
    SAVED_PRESENT+=("$present")
}

cleanup() {
    local status=$? i rollback_failed=0
    trap - EXIT HUP INT TERM
    if (( ! COMMITTED && ${#SAVED_PATHS[@]} )); then
        printf 'Setup did not complete; reverting file changes.\n' >&2
        for ((i=${#SAVED_PATHS[@]}-1; i>=0; i--)); do
            if [[ ${SAVED_PRESENT[i]} == 1 ]]; then
                cp -p -- "${SAVED_COPIES[i]}" "${SAVED_PATHS[i]}" || rollback_failed=1
            else
                rm -f -- "${SAVED_PATHS[i]}" || rollback_failed=1
            fi
        done
    fi
    if (( rollback_failed )); then
        printf 'Rollback was incomplete. Backups have been preserved in: %s\n' "$WORK" >&2
        exit 1
    fi
    if [[ -n $WORK && -d $WORK ]]; then
        rm -rf -- "$WORK"
    fi
    exit "$status"
}

check_host() {
    [[ $(uname -s) == Linux ]] || die 'Run this script on Debian or Ubuntu Linux.'
    [[ $(uname -m) == x86_64 ]] || die 'Only x86_64 is supported.'
    [[ $EUID == 0 ]] || die 'Run with: sudo bash openbsd-setup-ovh.sh'
    command -v dpkg >/dev/null || die 'dpkg was not found.'
    [[ $(dpkg --print-architecture) == amd64 ]] || die 'An amd64 userland is required.'
    [[ -r /etc/os-release ]] || die '/etc/os-release was not found.'
    # OS metadata is a root-managed local shell file.
    . /etc/os-release
    supported_os "${ID:-}" "${VERSION_ID:-}" || die "Unsupported host release: ${ID:-?} ${VERSION_ID:-?}"
    info "System: ${PRETTY_NAME:-$ID $VERSION_ID} / x86_64"
    MODE=bios
    if [[ -d /sys/firmware/efi ]]; then
        MODE=uefi
        [[ -r /sys/firmware/efi/fw_platform_size ]] || die 'Could not read the UEFI firmware bit width.'
        [[ $(cat /sys/firmware/efi/fw_platform_size) == 64 ]] || die '64-bit UEFI is required.'
        local sb=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c state
        [[ -r $sb ]] || die 'Could not read the Secure Boot status; check that efivarfs is mounted.'
        state=$(od -An -tu1 -j4 -N1 "$sb")
        state=${state//[[:space:]]/}
        case "$state" in
            0) ;;
            1) die 'Secure Boot is enabled. Disable it in the firmware/OVH settings and reboot Linux before preparing OpenBSD.' ;;
            *) die 'Could not determine the Secure Boot status.' ;;
        esac
    fi
    [[ -d /etc/grub.d && -s $GRUB_CONFIG && -f /etc/default/grub ]] ||
        die 'No existing GRUB configuration was found. This script does not install GRUB.'
    [[ ! -L $GRUB_CONFIG ]] || die 'A grub.cfg symbolic link is not supported.'
    info "Firmware: $MODE"
}

dependencies() {
    local tool
    local -a missing=() packages=()
    for tool in grub-probe grub-mkrelpath grub-mkconfig grub-script-check; do
        command -v "$tool" >/dev/null || missing+=("$tool")
    done
    ((${#missing[@]} == 0)) || packages+=(grub2-common)
    command -v curl >/dev/null || packages+=(curl)
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || packages+=(ca-certificates)
    for tool in findmnt blkid df od sha256sum flock; do
        command -v "$tool" >/dev/null || die "Required system tool is missing: $tool"
    done
    if ((${#packages[@]})); then
        (( ! CHECK_ONLY )) || die "Missing dependencies: ${packages[*]}. Run without --check to install them using APT."
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
    fi
    for tool in grub-probe grub-mkrelpath grub-mkconfig grub-script-check curl; do
        command -v "$tool" >/dev/null || die "Tool installation failed: $tool"
    done
}

check_esp() {
    local candidate fs source parttype
    ESP=
    local -a candidates=(/boot/efi /efi /boot)
    [[ -z $ESP_REQUESTED ]] || candidates=("$ESP_REQUESTED")
    for candidate in "${candidates[@]}"; do
        [[ -d $candidate ]] || continue
        fs=$(findmnt -rn --mountpoint "$candidate" -o FSTYPE) || continue
        [[ $fs == vfat ]] || continue
        source=$(findmnt -rn --mountpoint "$candidate" -o SOURCE)
        [[ -b $source ]] || continue
        parttype=$(blkid -p -s PART_ENTRY_TYPE -o value "$source") || continue
        case "${parttype,,}" in
            c12a7328-f81f-11d2-ba4b-00a0c93ec93b|0xef) ESP=$candidate; break ;;
        esac
    done
    [[ -n $ESP ]] || die 'No mounted FAT EFI System Partition was found. Mount the ESP and use --esp /path if needed.'
    [[ -w $ESP ]] || die "The ESP is not writable: $ESP"
    local options
    options=$(findmnt -rn --mountpoint "$ESP" -o OPTIONS)
    [[ ,$options, != *,ro,* ]] || die "The ESP is mounted read-only: $ESP"
    info "EFI System Partition: $ESP"
}

check_storage() {
    local part partmaps abstraction available module
    if [[ $MODE == uefi ]]; then
        check_esp
        STORAGE=$ESP
        KERNEL_DEST="$ESP/$EFI_RAMDISK"
        LOADER_DEST="$ESP/$EFI_DIRECTORY/BOOTX64.EFI"
    else
        [[ -z $ESP_REQUESTED ]] || die '--esp can only be used in UEFI mode.'
        STORAGE=/boot
        KERNEL_DEST="$BIOS_DIRECTORY/bsd.rd"
        [[ -r /boot/grub/i386-pc/bsd.mod ]] ||
            die 'The active GRUB directory is missing i386-pc/bsd.mod. Check the grub-pc-bin module installation; this script does not run grub-install.'
    fi
    FS_UUID=$(grub-probe --target=fs_uuid "$STORAGE")
    FS_MODULE=$(grub-probe --target=fs "$STORAGE")
    safe_grub_value "$FS_UUID" || die 'Invalid filesystem UUID for GRUB.'
    [[ $FS_MODULE =~ ^[a-zA-Z0-9_]+$ ]] || die 'Could not determine the GRUB filesystem module.'
    # Standard cloud disks are direct partitions. Avoid generating incomplete
    # access commands for encrypted, LVM, RAID, or other abstract block devices.
    abstraction=$(grub-probe --target=abstraction "$STORAGE")
    [[ -z $abstraction ]] || die "Unsupported storage abstraction: $abstraction. A directly accessible, GRUB-readable /boot or ESP is required."
    PART_MODULES=()
    partmaps=$(grub-probe --target=partmap "$STORAGE")
    while IFS= read -r part; do
        [[ -z $part ]] && continue
        case "$part" in
            gpt|msdos) PART_MODULES+=("part_$part") ;;
            *) die "Unsupported partition table: $part" ;;
        esac
    done <<<"$partmaps"
    if [[ $MODE == bios ]]; then
        for module in "${PART_MODULES[@]}" "$FS_MODULE" search search_fs_uuid bsd gzio; do
            [[ -r /boot/grub/i386-pc/$module.mod ]] || die "Active BIOS GRUB module is missing: $module"
        done
    fi
    available=$(df -Pk "$STORAGE" | awk 'END {print $4}')
    [[ $available =~ ^[0-9]+$ && $available -ge 16384 ]] || die "At least 16 MiB of free space is required on $STORAGE."
    info "GRUB filesystem: $FS_MODULE / UUID: $FS_UUID"
}

check_owned_file() {
    local path=$1
    [[ ! -L $path ]] || die "Refusing to modify a symbolic link: $path"
    if [[ -e $path ]]; then
        [[ -f $path ]] || die "Not a regular file: $path"
        if ! grep -Fqx "$MARKER" "$path"; then
            die "Refusing to overwrite a file not managed by this script: $path"
        fi
    fi
}

render_entry() {
    local mode=$1 uuid=$2 payload=$3 fs=$4 module
    shift 4
    safe_grub_value "$uuid" && safe_grub_value "$payload" || die 'Unsafe GRUB entry value.'
    printf "menuentry 'OpenBSD %s installer (%s)' --id '%s' {\n" "$OPENBSD_VERSION" "$mode" "$ENTRY_ID"
    for module in "$@" "$fs" search search_fs_uuid; do
        [[ $module =~ ^[a-zA-Z0-9_]+$ ]] || die 'Invalid GRUB module name.'
        printf '    insmod %s\n' "$module"
    done
    printf "    search --no-floppy --fs-uuid --set=root '%s'\n" "$uuid"
    if [[ $mode == bios ]]; then
        printf "    insmod gzio\n    insmod bsd\n    kopenbsd '%s'\n" "$payload"
    elif [[ $mode == uefi ]]; then
        printf "    insmod chain\n    chainloader '%s'\n" "$payload"
    else
        die 'Invalid firmware mode.'
    fi
    printf '}\n'
}

main() {
    while (($#)); do
        case "$1" in
            --check) CHECK_ONLY=1; shift ;;
            --esp) (($# >= 2)) || die '--esp requires a path.'; ESP_REQUESTED=$2; shift 2 ;;
            --help|-h) usage; return 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    show_banner
    configure_release
    check_host
    check_release_firmware "$MODE"
    dependencies
    check_storage
    check_owned_file "$ENTRY_FILE"
    check_owned_file "$DEFAULT_FILE"
    if (( CHECK_ONLY )); then
        info 'Preflight checks passed; no files were changed. GRUB must be the active bootloader.'
        return 0
    fi

    # Prevent concurrent runs from modifying the same boot files.
    exec 9>/run/lock/openbsd-setup-ovh.lock
    flock -n 9 || die 'Another OpenBSD GRUB setup process is running.'
    WORK=$(mktemp -d /tmp/openbsd-setup-ovh.XXXXXXXX)
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    info "Downloading OpenBSD $OPENBSD_VERSION installer files..."
    fetch_release_files
    if [[ $MODE == uefi ]]; then
        # Protect a pre-existing ESP root file that may belong to another setup.
        if [[ -e $KERNEL_DEST ]]; then
            verify_download "$KERNEL_DEST" "$RAMDISK_SHA256"
        fi
        if [[ -e $LOADER_DEST ]]; then
            verify_download "$LOADER_DEST" "$EFI_SHA256"
        fi
        mkdir -p -- "$ESP/$EFI_DIRECTORY"
        remember_file "$LOADER_DEST"
        install -m 0644 -- "$WORK/BOOTX64.EFI" "$LOADER_DEST"
    else
        mkdir -p -- "$BIOS_DIRECTORY"
    fi
    remember_file "$KERNEL_DEST"
    install -m 0644 -- "$WORK/bsd.rd" "$KERNEL_DEST"

    local payload
    if [[ $MODE == uefi ]]; then
        payload=$(grub-mkrelpath "$LOADER_DEST")
    else
        payload=$(grub-mkrelpath "$KERNEL_DEST")
    fi
    render_entry "$MODE" "$FS_UUID" "$payload" "$FS_MODULE" "${PART_MODULES[@]}" >"$WORK/entry.cfg"
    grub-script-check "$WORK/entry.cfg"
    {
        printf '#!/bin/sh\n%s\n' "$MARKER"
        printf "cat <<'OPENBSD_GRUB_ENTRY'\n"
        cat "$WORK/entry.cfg"
        printf 'OPENBSD_GRUB_ENTRY\n'
    } >"$WORK/entry.sh"
    {
        printf '%s\n' "$MARKER"
        printf 'GRUB_TIMEOUT_STYLE=menu\nGRUB_TIMEOUT=15\n'
    } >"$WORK/defaults.cfg"

    mkdir -p /etc/default/grub.d
    remember_file "$ENTRY_FILE"
    remember_file "$DEFAULT_FILE"
    install -m 0755 -- "$WORK/entry.sh" "$ENTRY_FILE"
    install -m 0644 -- "$WORK/defaults.cfg" "$DEFAULT_FILE"

    # Generate and validate before replacing the working boot menu.
    grub-mkconfig -o "$WORK/grub.cfg"
    grub-script-check "$WORK/grub.cfg"
    grep -Fq -- "--id '$ENTRY_ID'" "$WORK/grub.cfg" || die 'The generated GRUB menu does not contain the installer entry.'
    remember_file "$GRUB_CONFIG"
    local new_config
    new_config=$(mktemp /boot/grub/.openbsd-grub.cfg.XXXXXXXX)
    SAVED_PATHS+=("$new_config")
    SAVED_COPIES+=('')
    SAVED_PRESENT+=(0)
    install -m 0600 -- "$WORK/grub.cfg" "$new_config"
    chmod --reference="$GRUB_CONFIG" "$new_config"
    chown --reference="$GRUB_CONFIG" "$new_config"
    mv -f -- "$new_config" "$GRUB_CONFIG"
    sync
    COMMITTED=1

    info ''
    info "Ready: select OpenBSD $OPENBSD_VERSION installer ($MODE) from the GRUB menu in the KVM console."
    info 'The existing GRUB default selection was preserved; the menu is shown for 15 seconds.'
    if [[ $MODE == uefi ]]; then
        info 'UEFI: at the OpenBSD boot> prompt, enter:'
        info "  boot esp:$EFI_RAMDISK"
    fi
    info 'When ready, reboot manually with the KVM console open: reboot'
}

configure_release
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
