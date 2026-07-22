#!/usr/bin/env bash

#===============================================================================
# Avaya-Proxmox-Multi-Script — Hauptmenü
#===============================================================================
# Beschreibung:  Hauptscript im Stil der Proxmox Helper Scripts
#                Zeigt ein whiptail-Menü mit Avaya-Produkten und startet
#                die entsprechenden Modul-Scripts.
# Autor:         naix1337
# Lizenz:        MIT
# GitHub:        https://github.com/naix1337/Avaya-Proxmox-Multi-Script-
#===============================================================================

set -euo pipefail

# --- Konfiguration -----------------------------------------------------------
REPO_OWNER="naix1337"
REPO_NAME="Avaya-Proxmox-Multi-Script-"
REPO_BRANCH="main"
REPO_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
TEMP_DIR="/tmp/avaya-proxmox-scripts"

# Module registry: (Anzeigename | Script-Dateiname | Implementiert?)
MODULES=(
    "ACM|avaya-acm.sh|yes"
    "SMGR|avaya-smgr.sh|no"
    "ASM|avaya-asm.sh|no"
    "SBCE|avaya-sbce-test.sh|yes"
    "Breeze|avaya-breeze.sh|no"
    "AADS|avaya-aads.sh|no"
)

# --- Farben & Formatierung (für echo-Ausgaben) --------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Hilfsfunktionen ---------------------------------------------------------

msg_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

msg_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

msg_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

msg_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Prüft, ob whiptail verfügbar ist
check_whiptail() {
    if ! command -v whiptail &>/dev/null; then
        msg_error "whiptail ist nicht installiert. Bitte nachinstallieren:"
        echo "  apt-get install whiptail"
        exit 1
    fi
}

# Prüft, ob curl verfügbar ist
check_curl() {
    if ! command -v curl &>/dev/null; then
        msg_error "curl ist nicht installiert. Bitte nachinstallieren:"
        echo "  apt-get install curl"
        exit 1
    fi
}

# Modul laden und ausführen
# Sucht zuerst lokal im scripts/-Verzeichnis, lädt bei Bedarf von GitHub Raw.
run_module() {
    local module_name="$1"
    local script_file="$2"
    local is_implemented="$3"

    # Nicht implementierte Module
    if [[ "$is_implemented" != "yes" ]]; then
        whiptail --title "Noch nicht implementiert" \
            --msgbox "Das Modul für ${module_name} ist noch nicht implementiert.\n\nEs wird in einer zukünftigen Version hinzugefügt." \
            10 60
        return 0
    fi

    local script_path="${SCRIPTS_DIR}/${script_file}"

    # 1. Lokal suchen
    if [[ -f "$script_path" ]]; then
        msg_info "Starte lokales Modul: ${module_name} (${script_path})"
        bash "$script_path"
        local exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            msg_ok "Modul ${module_name} erfolgreich beendet."
        else
            msg_error "Modul ${module_name} mit Fehler (Exit-Code: ${exit_code}) beendet."
        fi
        return $exit_code
    fi

    # 2. Fallback: Von GitHub Raw laden
    msg_warn "Modul ${script_file} nicht lokal gefunden unter:"
    msg_warn "  ${script_path}"
    msg_info "Lade von GitHub Raw nach ..."

    check_curl

    mkdir -p "$TEMP_DIR"

    local remote_url="${REPO_BASE}/scripts/${script_file}"
    local temp_script="${TEMP_DIR}/${script_file}"

    if curl -fsSL "$remote_url" -o "$temp_script"; then
        chmod +x "$temp_script"
        msg_ok "Modul erfolgreich geladen: ${remote_url}"
        msg_info "Starte Modul: ${module_name}"
        bash "$temp_script"
        local exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            msg_ok "Modul ${module_name} erfolgreich beendet."
        else
            msg_error "Modul ${module_name} mit Fehler (Exit-Code: ${exit_code}) beendet."
        fi
        # Aufräumen
        rm -f "$temp_script"
        return $exit_code
    else
        msg_error "Konnte Modul nicht von GitHub Raw laden: ${remote_url}"
        whiptail --title "Download-Fehler" \
            --msgbox "Das Modul ${script_file} konnte weder lokal noch von GitHub Raw geladen werden.\n\nPrüfe die Internetverbindung oder lade das Repository vollständig herunter." \
            12 60
        return 1
    fi
}

# Hauptmenü anzeigen
show_main_menu() {
    local menu_items=()
    local i=0

    for module in "${MODULES[@]}"; do
        IFS='|' read -r display_name script_file is_implemented <<< "$module"
        if [[ "$is_implemented" == "yes" ]]; then
            menu_items+=("$display_name" "✅  VM-Import ausführen")
        else
            menu_items+=("$display_name" "⏳  Noch nicht implementiert")
        fi
    done

    local menu_choice
    menu_choice=$(whiptail --title "Avaya Proxmox Multi Script" \
        --menu "\nWähle ein Avaya-Produkt für den VM-Import auf Proxmox:\n" \
        18 65 7 \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3)

    if [[ $? -ne 0 ]] || [[ -z "$menu_choice" ]]; then
        echo ""
        msg_info "Abbruch durch Benutzer."
        exit 0
    fi

    # Modul anhand der Auswahl finden und ausführen
    for module in "${MODULES[@]}"; do
        IFS='|' read -r display_name script_file is_implemented <<< "$module"
        if [[ "$display_name" == "$menu_choice" ]]; then
            run_module "$display_name" "$script_file" "$is_implemented"
            return $?
        fi
    done

    # Sollte nie passieren
    msg_error "Unbekannte Auswahl: ${menu_choice}"
    return 1
}

# --- Hauptprogramm -----------------------------------------------------------

# Prüfen, ob das Skript auf einem Proxmox-Host läuft
check_proxmox() {
    if [[ ! -f /etc/pve/local.conf ]] && [[ ! -d /etc/pve ]]; then
        msg_warn "Dies scheint kein Proxmox VE Host zu sein."
        msg_warn "Einige Befehle (qm create, qm importdisk) werden nicht verfügbar sein."
        echo ""
        if ! whiptail --title "Proxmox-Prüfung" \
            --yesno "Dieses System scheint kein Proxmox VE zu sein.\n\nMöchtest du trotzdem fortfahren?" \
            10 60; then
            msg_info "Abgebrochen."
            exit 0
        fi
    else
        # Proxmox detailliert prüfen
        if ! command -v qm &>/dev/null; then
            msg_warn "qm-Befehl nicht gefunden. Bist du auf einem Proxmox VE Node?"
        else
            msg_ok "Proxmox VE erkannt."
        fi
    fi
}

main() {
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}  Avaya Proxmox Multi Script${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo ""

    check_whiptail
    check_proxmox

    while true; do
        show_main_menu
        # Nach Modul-Ende zurück ins Menü, wenn gewünscht
        echo ""
        if ! whiptail --title "Menü" \
            --yesno "Möchtest du zurück zum Hauptmenü?" \
            8 40; then
            msg_info "Auf Wiedersehen."
            break
        fi
        echo ""
    done
}

main "$@"
