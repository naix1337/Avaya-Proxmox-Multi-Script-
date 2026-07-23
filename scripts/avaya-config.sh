#!/usr/bin/env bash

#===============================================================================
# Avaya-Proxmox-Multi-Script — Zentrale Konfiguration
#===============================================================================
# Beschreibung:  Zentrale Konfigurationsdatei für OVA-Mirror und
#                Download-Funktionen. Von avaya-main.sh gesourct.
# GitHub:        https://github.com/naix1337/Avaya-Proxmox-Multi-Script-
# Lizenz:        MIT
#
# OVA_MIRROR_BASE kann als Umgebungsvariable überschrieben werden:
#   export OVA_MIRROR_BASE="https://dein-mirror.example.com"
#===============================================================================

OVA_MIRROR_BASE="${OVA_MIRROR_BASE:-https://ova.insolution.cloud}"

# --- Download-Funktion für OVAs/Images ---------------------------------------
# Aufruf: download_ova "datei.ova" "/ziel/verzeichnis/"
download_ova() {
    local filename="$1"
    local target_dir="$2"
    local url="${OVA_MIRROR_BASE}/${filename}"
    local target="${target_dir}/$(basename "${filename}")"

    if [[ -f "$target" ]]; then
        local existing_size
        existing_size=$(du -h "$target" 2>/dev/null | cut -f1)
        if whiptail --title "Datei existiert" \
            --yesno "Datei existiert:\n  ${target}\n  (${existing_size})\n\nErneut laden?" 12 65; then
            rm -f "$target"
        else
            msg_ok "Verwende vorhandene Datei: ${target}"
            return 0
        fi
    fi

    mkdir -p "$target_dir"
    msg_info "Lade: ${url}"
    wget --progress=dot:giga -O "$target" "$url" 2>&1 || {
        msg_error "Download fehlgeschlagen"
        return 1
    }
    local size; size=$(du -h "$target" 2>/dev/null | cut -f1)
    msg_ok "Download erfolgreich: ${target} (${size})"
    return 0
}
