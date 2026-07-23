#!/usr/bin/env bash

#===============================================================================
# Avaya ACM — KVM-Import auf Proxmox VE
#===============================================================================
# Beschreibung:  Erstellt eine KVM-VM aus einem Aura Communication Manager
#                (ACM) OVA/Image auf Proxmox VE.
#                Nutzt OVA → tar xvf → QCOW2-Import.
# Autor:         naix1337
# Lizenz:        MIT
#===============================================================================

set -euo pipefail

# --- Farben & Formatierung ---------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# --- Exit-Code-Tabelle -------------------------------------------------------
EXIT_OK=0
EXIT_ERROR=1
EXIT_USER_ABORT=2

# --- OVA-Konfiguration -------------------------------------------------------
# Standard-Dateinamen nach denen automatisch gesucht wird
OVA_SEARCH_NAMES=(
    "acm.ova"
    "avaya-acm.ova"
    "CM_*.ova"
    "ACM_*.ova"
    "communication-manager*.ova"
)

# Verzeichnisse die automatisch durchsucht werden (Reihenfolge nach Priorität)
OVA_SEARCH_DIRS=(
    "/var/lib/vz/template/iso"
    "/var/lib/vz/images"
    "/tmp"
    "/root"
    "$HOME"
)

# Standard-Download-URL (eigener Mirror/TrueNAS/etc.)
# Wenn gesetzt, erscheint "Automatisch herunterladen" im Menü.
# Überschreibbar per Umgebungsvariable: OVA_MIRROR_BASE
OVA_DEFAULT_DOWNLOAD_URL="${OVA_MIRROR_BASE:-https://ova.insolution.cloud}/acm/"

# --- Hilfsfunktionen ---------------------------------------------------------

msg_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
msg_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
msg_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
msg_error() { echo -e "${RED}[ERROR]${NC} $1"; }

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]] && [[ $exit_code -ne $EXIT_USER_ABORT ]]; then
        echo ""
        msg_error "Das Skript wurde mit einem Fehler beendet (Exit-Code: ${exit_code})."
    fi
}

trap cleanup EXIT

check_whiptail() {
    if ! command -v whiptail &>/dev/null; then
        echo -e "${RED}[ERROR]${NC} whiptail ist nicht installiert."
        echo "Bitte installieren: apt-get install whiptail"
        exit $EXIT_ERROR
    fi
}

check_tools() {
    local missing=0
    for tool in qm wget curl tar; do
        if ! command -v "$tool" &>/dev/null; then
            msg_error "'${tool}' ist nicht installiert oder nicht im PATH."
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        exit $EXIT_ERROR
    fi
}

validate_vmid() {
    local vmid="$1"
    if [[ ! "$vmid" =~ ^[0-9]+$ ]] || [[ "$vmid" -lt 100 ]] || [[ "$vmid" -gt 999999999 ]]; then
        msg_error "Ungültige VM-ID: ${vmid}. Erlaubt: 100 - 999999999 (numerisch)."
        return 1
    fi
    if qm status "$vmid" &>/dev/null; then
        msg_error "VM-ID ${vmid} ist bereits vergeben."
        return 1
    fi
    return 0
}

validate_storage() {
    local storage="$1"
    if ! pvesh get /storage/"${storage}" --noborder --noheader &>/dev/null; then
        msg_error "Storage '${storage}' existiert nicht in Proxmox."
        msg_info "Verfügbare Storages:"
        pvesh get /storage --noborder --noheader -output-format json 2>/dev/null \
            | python3 -c "import sys,json; [print(f'  - {s[\"storage\"]}') for s in json.load(sys.stdin)]" 2>/dev/null \
            || pvesh get /storage --noborder --noheader 2>/dev/null | awk '{print "  - " $0}'
        return 1
    fi

    local content
    content=$(pvesh get /storage/"${storage}" --noborder --noheader -output-format json 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('content',''))" 2>/dev/null)
    if [[ -n "$content" ]] && [[ "$content" != *"images"* ]] && [[ "$content" != *"rootdir"* ]]; then
        msg_warn "Storage '${storage}' unterstützt keine VM-Images (content: ${content})."
        msg_warn "Bitte einen Storage mit 'images'-Content-Type wählen (z. B. local-lvm)."
        if ! whiptail --title "Storage-Warnung" \
            --yesno "Storage '${storage}' unterstützt keine VM-Images.\n\nTrotzdem fortfahren (wird wahrscheinlich fehlschlagen)?" \
            10 65; then
            return 1
        fi
    fi
    return 0
}

validate_bridge() {
    local bridge="$1"
    if ! ip link show "$bridge" &>/dev/null; then
        msg_warn "Bridge '${bridge}' existiert nicht oder ist nicht aktiv."
        if ! whiptail --title "Bridge-Warnung" \
            --yesno "Bridge '${bridge}' wurde nicht gefunden.\n\nTrotzdem fortfahren?" \
            10 60; then
            return 1
        fi
    fi
    return 0
}

validate_vlan() {
    local vlan="$1"
    if [[ -z "$vlan" ]]; then
        return 0
    fi
    if [[ ! "$vlan" =~ ^[0-9]+$ ]] || [[ "$vlan" -lt 1 ]] || [[ "$vlan" -gt 4094 ]]; then
        msg_error "Ungültige VLAN-ID: ${vlan}. Erlaubt: 1 - 4094."
        return 1
    fi
    return 0
}

download_file() {
    local url="$1"
    local target="$2"
    msg_info "Lade herunter: ${url}"
    if wget --progress=dot:giga -O "$target" "$url"; then
        msg_ok "Download erfolgreich: $(du -h "$target" 2>/dev/null | cut -f1)"
        return 0
    else
        msg_error "Download fehlgeschlagen."
        return 1
    fi
}

list_storages() {
    pvesh get /storage --noborder --noheader -output-format json 2>/dev/null \
        | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for s in data:
        if 'images' in s.get('content','') or 'rootdir' in s.get('content',''):
            print(s['storage'])
except: pass" 2>/dev/null || true
    pvesh get /storage --noborder --noheader 2>/dev/null | awk '{print $1}' || true
}

find_qcow2_in_dir() {
    local dir="$1"
    find "$dir" -maxdepth 1 -type f \( -name "*.qcow2" -o -name "*.img" -o -name "*.raw" \) 2>/dev/null | head -5 || true
}

check_disk_space() {
    local ova_path="$1"
    local target_dir="$2"

    local ova_size_kb
    ova_size_kb=$(du -k "$ova_path" 2>/dev/null | cut -f1)
    if [[ -z "$ova_size_kb" ]] || [[ "$ova_size_kb" -eq 0 ]]; then
        msg_warn "Konnte Größe der OVA-Datei nicht ermitteln. Überspringe Speicherprüfung."
        return 0
    fi

    local free_kb
    free_kb=$(df -k "$target_dir" 2>/dev/null | awk 'NR==2{print $4}')
    if [[ -z "$free_kb" ]] || [[ "$free_kb" -eq 0 ]]; then
        msg_warn "Konnte freien Speicher nicht ermitteln. Überspringe Speicherprüfung."
        return 0
    fi

    local min_needed_kb=$(( ova_size_kb * 3 ))
    local five_gb=$(( 5 * 1024 * 1024 ))
    [[ $min_needed_kb -lt $five_gb ]] && min_needed_kb=$five_gb

    local ova_size_mb=$(( ova_size_kb / 1024 ))
    local free_mb=$(( free_kb / 1024 ))
    local needed_mb=$(( min_needed_kb / 1024 ))

    if [[ $free_kb -lt $min_needed_kb ]]; then
        msg_warn "Wenig Speicherplatz in ${target_dir}: ${free_mb} MB frei"
        msg_warn "OVA ist ${ova_size_mb} MB groß. Empfohlen: mind. ${needed_mb} MB frei."
        if ! whiptail --title "Wenig Speicherplatz" \
            --yesno "Wenig Speicher in ${target_dir} (${free_mb} MB frei).\n\nDie OVA (${ova_size_mb} MB) benötigt ca. ${needed_mb} MB für die Entpackung.\n\nTrotzdem fortfahren?" \
            12 65; then
            msg_info "Abbruch wegen zu wenig Speicherplatz."
            exit $EXIT_USER_ABORT
        fi
    else
        msg_ok "Speicherplatz ausreichend: ${free_mb} MB frei (OVA: ${ova_size_mb} MB)"
    fi
    return 0
}

# =============================================================================
# OVA-Suche: Durchsucht alle bekannten Verzeichnisse nach OVA-Dateien
# Gibt den Pfad zur gefundenen Datei zurück oder leeren String
# =============================================================================
search_ova_local() {
    msg_info "Suche nach OVA-Datei im lokalen Dateisystem..."

    local found_path=""
    for search_dir in "${OVA_SEARCH_DIRS[@]}"; do
        if [[ ! -d "$search_dir" ]]; then
            continue
        fi
        for pattern in "${OVA_SEARCH_NAMES[@]}"; do
            # Glob-Suche im Verzeichnis
            while IFS= read -r -d '' found_file; do
                if [[ -f "$found_file" ]] && [[ -r "$found_file" ]]; then
                    local size_mb
                    size_mb=$(du -m "$found_file" 2>/dev/null | cut -f1)
                    msg_ok "OVA gefunden: ${found_file} (${size_mb:-?} MB)"
                    found_path="$found_file"
                    echo "$found_path"
                    return 0
                fi
            done < <(find "$search_dir" -maxdepth 2 -name "$pattern" -print0 2>/dev/null)
        done
    done

    echo ""
    return 1
}

# =============================================================================
# OVA-Dialog: Zeigt Optionen wenn keine OVA lokal gefunden wurde
# Gibt den finalen OVA-Pfad zurück
# =============================================================================
handle_ova_not_found() {
    local dl_dir="${1:-/var/lib/vz/template/iso}"

    # Whiptail-Menü: automatisch herunterladen oder eigene URL
    local action
    action=$(whiptail --title "❌ Keine OVA-Datei gefunden" \
        --menu "\nDie ACM OVA-Datei wurde nicht lokal gefunden.\n\nWie möchtest du fortfahren?\n" \
        16 72 4 \
        "auto"   "Automatisch herunterladen (Standard-Mirror)" \
        "custom" "Eigene Download-URL eingeben" \
        "manual" "Pfad manuell eingeben (Datei liegt woanders)" \
        "abort"  "Abbrechen" \
        3>&1 1>&2 2>&3)

    if [[ $? -ne 0 ]] || [[ -z "$action" ]] || [[ "$action" == "abort" ]]; then
        msg_info "Abbruch durch Benutzer."
        exit $EXIT_USER_ABORT
    fi

    local final_path=""

    case "$action" in

        "auto")
            # Standard-Download-URL prüfen
            if [[ -z "$OVA_DEFAULT_DOWNLOAD_URL" ]]; then
                whiptail --title "Kein Standard-Mirror konfiguriert" \
                    --msgbox "Es wurde kein Standard-Download-Mirror konfiguriert.\n\nBitte trage deine Download-URL in die Variable\n'OVA_DEFAULT_DOWNLOAD_URL' im Script ein\n(z. B. dein TrueNAS oder eigener Mirror).\n\nDu kannst alternativ 'Eigene URL' verwenden." \
                    14 65
                # Direkt weiter zu "custom"
                action="custom"
            else
                local ova_filename
                ova_filename=$(basename "$OVA_DEFAULT_DOWNLOAD_URL" | sed 's/?.*//')
                [[ -z "$ova_filename" ]] && ova_filename="acm.ova"
                final_path="${dl_dir}/${ova_filename}"
                mkdir -p "$dl_dir"

                if [[ -f "$final_path" ]]; then
                    msg_ok "Datei bereits vorhanden: ${final_path}"
                else
                    msg_info "Starte automatischen Download von: ${OVA_DEFAULT_DOWNLOAD_URL}"
                    if ! download_file "$OVA_DEFAULT_DOWNLOAD_URL" "$final_path"; then
                        msg_error "Automatischer Download fehlgeschlagen."
                        exit $EXIT_ERROR
                    fi
                fi
                echo "$final_path"
                return 0
            fi
            ;;&  # Fall-through zu "custom" wenn kein Mirror konfiguriert

        "custom")
            local custom_url=""
            custom_url=$(whiptail --title "Eigene Download-URL" \
                --inputbox "\nGib die Download-URL der ACM OVA-Datei ein:\n\nBeispiele:\n  http://nas.local:8080/ova/acm.ova\n  http://100.x.x.x/avaya/acm.ova   (Tailscale)\n  https://your-mirror.com/acm.ova\n" \
                16 72 "${OVA_DEFAULT_DOWNLOAD_URL}" \
                3>&1 1>&2 2>&3)

            if [[ $? -ne 0 ]] || [[ -z "$custom_url" ]]; then
                msg_info "Abbruch durch Benutzer."
                exit $EXIT_USER_ABORT
            fi

            local ova_filename
            ova_filename=$(basename "$custom_url" | sed 's/?.*//')
            [[ -z "$ova_filename" ]] || [[ "$ova_filename" != *"."* ]] && ova_filename="acm.ova"
            final_path="${dl_dir}/${ova_filename}"
            mkdir -p "$dl_dir"

            if [[ -f "$final_path" ]]; then
                if whiptail --title "Datei bereits vorhanden" \
                    --yesno "Die Datei existiert bereits:\n${final_path}\n\nErneut herunterladen?" \
                    10 65; then
                    if ! download_file "$custom_url" "$final_path"; then
                        msg_error "Download fehlgeschlagen."
                        exit $EXIT_ERROR
                    fi
                else
                    msg_ok "Vorhandene Datei wird verwendet: ${final_path}"
                fi
            else
                if ! download_file "$custom_url" "$final_path"; then
                    msg_error "Download fehlgeschlagen."
                    exit $EXIT_ERROR
                fi
            fi
            echo "$final_path"
            return 0
            ;;

        "manual")
            local manual_path=""
            manual_path=$(whiptail --title "Manueller Pfad" \
                --inputbox "\nGib den vollständigen Pfad zur OVA-Datei ein:\n\nBeispiel: /mnt/nas/avaya/acm.ova\n" \
                12 65 "/var/lib/vz/template/iso/" \
                3>&1 1>&2 2>&3)

            if [[ $? -ne 0 ]] || [[ -z "$manual_path" ]]; then
                msg_info "Abbruch durch Benutzer."
                exit $EXIT_USER_ABORT
            fi

            if [[ ! -f "$manual_path" ]]; then
                whiptail --title "Datei nicht gefunden" \
                    --msgbox "Die angegebene Datei wurde nicht gefunden:\n${manual_path}\n\nBitte Pfad prüfen und erneut versuchen." \
                    10 65
                exit $EXIT_ERROR
            fi

            msg_ok "Datei gefunden: ${manual_path}"
            echo "$manual_path"
            return 0
            ;;
    esac
}

# =============================================================================
# Haupt-OVA-Resolver: Lokal suchen → bei Fehler Dialog anzeigen
# Setzt die globale Variable OVA_PATH
# =============================================================================
resolve_ova_path() {
    local dl_dir="${1:-/var/lib/vz/template/iso}"

    # 1. Automatische lokale Suche
    local found
    found=$(search_ova_local)

    if [[ -n "$found" ]]; then
        # Bestätigung anzeigen
        local size_mb
        size_mb=$(du -m "$found" 2>/dev/null | cut -f1)
        if whiptail --title "✅ OVA-Datei gefunden" \
            --yesno "OVA-Datei wurde automatisch gefunden:\n\n  ${found}\n  Größe: ${size_mb:-?} MB\n\nDiese Datei verwenden?" \
            12 70; then
            OVA_PATH="$found"
            return 0
        else
            # User will eine andere Datei → Dialog zeigen
            local alt_path
            alt_path=$(handle_ova_not_found "$dl_dir")
            OVA_PATH="$alt_path"
            return 0
        fi
    fi

    # 2. Nicht gefunden → Dialog
    msg_warn "Keine OVA-Datei in den Standardpfaden gefunden."
    local chosen_path
    chosen_path=$(handle_ova_not_found "$dl_dir")
    OVA_PATH="$chosen_path"
    return 0
}

# --- Profile (offizielle Avaya-Werte) ----------------------------------------
declare -A PROFILES
PROFILES["simplex"]="CM Simplex2|2|4608|64|2"
PROFILES["duplex"]="CM Duplex|3|5120|64|3"
PROFILES["highduplex"]="CM High Duplex|3|5120|64|3"

# Globale OVA-Pfad-Variable
OVA_PATH=""

# --- Hauptfunktion -----------------------------------------------------------

main() {
    check_whiptail
    check_tools

    # ----- Splash ------------------------------------------------------------
    whiptail --title "Avaya ACM — KVM-Import" \
        --msgbox "\
Dieses Skript erstellt eine KVM-VM für Avaya Aura Communication Manager
(ACM) auf Proxmox VE.

Quelle: OVA-Datei (von Avaya PLDS)
  → tar xvf entpacken
  → QCOW2-Import via qm importdisk

Es werden die Standard-Einstellungen aus der Avaya-Installationsanleitung
verwendet: OVMF, VirtIO SCSI, CPU Host, E1000-NICs.\
" \
        14 65

    if [[ $? -ne 0 ]]; then
        msg_info "Abbruch durch Benutzer."
        exit $EXIT_USER_ABORT
    fi

    # ----- Schritt 1: Variante wählen ----------------------------------------
    local variant_choice
    variant_choice=$(whiptail --title "ACM-Profil" \
        --radiolist "\
Wähle ein ACM-Profil (offizielle Avaya-Werte):\n\
" \
        16 65 5 \
        "simplex"     "CM Simplex2    — 2 vCPUs, 4.5 GB RAM, 64 GB, 2 NICs"   ON \
        "duplex"      "CM Duplex      — 3 vCPUs, 5 GB RAM, 64 GB, 3 NICs"      OFF \
        "highduplex"  "CM High Duplex — 3 vCPUs, 5 GB RAM, 64 GB, 3 NICs"      OFF \
        3>&1 1>&2 2>&3)

    if [[ $? -ne 0 ]] || [[ -z "$variant_choice" ]]; then
        msg_info "Abbruch durch Benutzer."
        exit $EXIT_USER_ABORT
    fi

    local profile_data="${PROFILES[$variant_choice]}"
    IFS='|' read -r profile_label profile_cores profile_ram profile_disk profile_nics <<< "$profile_data"
    msg_info "Gewähltes Profil: ${profile_label}"

    # ----- Schritt 2: VM-ID --------------------------------------------------
    local vmid=""
    while true; do
        vmid=$(whiptail --title "VM-ID" \
            --inputbox "\nGib eine eindeutige VM-ID ein (100 - 999999999):\n" \
            10 60 "200" \
            3>&1 1>&2 2>&3)

        if [[ $? -ne 0 ]]; then
            msg_info "Abbruch durch Benutzer."
            exit $EXIT_USER_ABORT
        fi

        if validate_vmid "$vmid"; then
            break
        fi

        whiptail --title "Ungültige VM-ID" \
            --msgbox "Die VM-ID ${vmid} ist ungültig oder bereits vergeben.\n\nBitte eine andere ID wählen." \
            8 50
    done

    # ----- Schritt 3: VM-Name ------------------------------------------------
    local vm_name=""
    vm_name=$(whiptail --title "VM-Name" \
        --inputbox "\nGib einen Namen für die VM ein (z. B. acm-small, acm-prod):\n" \
        10 60 "acm-${variant_choice}" \
        3>&1 1>&2 2>&3)

    if [[ $? -ne 0 ]]; then
        msg_info "Abbruch durch Benutzer."
        exit $EXIT_USER_ABORT
    fi

    if [[ -z "$vm_name" ]] || [[ ! "$vm_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        msg_error "Ungültiger VM-Name. Erlaubt: Buchstaben, Ziffern, Punkte, Unterstriche, Bindestriche."
        whiptail --title "Ungültiger Name" --msgbox "Der Name darf nur Buchstaben, Ziffern, Punkte, Unterstriche und\nBindestriche enthalten." 8 60
        exit $EXIT_USER_ABORT
    fi

    # ----- Schritt 4: Storage ------------------------------------------------
    local storage_list
    storage_list=$(list_storages)
    local storage=""

    if [[ -z "$storage_list" ]]; then
        while true; do
            storage=$(whiptail --title "Storage" \
                --inputbox "\nGib den Proxmox-Storage für das VM-Image ein:\n" \
                10 60 "local-lvm" \
                3>&1 1>&2 2>&3)
            if [[ $? -ne 0 ]]; then
                msg_info "Abbruch durch Benutzer."
                exit $EXIT_USER_ABORT
            fi
            if validate_storage "$storage"; then break; fi
            whiptail --title "Storage-Fehler" --msgbox "Storage '${storage}' existiert nicht." 8 50
        done
    else
        local storage_menu_items=()
        while IFS= read -r st; do
            [[ -z "$st" ]] && continue
            storage_menu_items+=("$st" "$st")
        done <<< "$storage_list"

        if [[ ${#storage_menu_items[@]} -eq 0 ]]; then
            while true; do
                storage=$(whiptail --title "Storage" \
                    --inputbox "\nGib den Proxmox-Storage für das VM-Image ein:\n" \
                    10 60 "local-lvm" \
                    3>&1 1>&2 2>&3)
                if [[ $? -ne 0 ]]; then
                    msg_info "Abbruch durch Benutzer."
                    exit $EXIT_USER_ABORT
                fi
                if validate_storage "$storage"; then break; fi
                whiptail --title "Storage-Fehler" --msgbox "Storage '${storage}' existiert nicht." 8 50
            done
        else
            storage=$(whiptail --title "Storage auswählen" \
                --menu "\nWähle den Ziel-Storage für das VM-Image:\n" \
                15 50 6 \
                "${storage_menu_items[@]}" \
                3>&1 1>&2 2>&3)
            if [[ $? -ne 0 ]]; then
                msg_info "Abbruch durch Benutzer."
                exit $EXIT_USER_ABORT
            fi
        fi
    fi

    # ----- Schritt 5: Bridge -------------------------------------------------
    local bridge=""
    bridge=$(whiptail --title "Bridge" \
        --inputbox "\nGib die Bridge für die Netzwerkkarten ein (Standard: vmbr0):\n" \
        10 60 "vmbr0" \
        3>&1 1>&2 2>&3)

    if [[ $? -ne 0 ]]; then
        msg_info "Abbruch durch Benutzer."
        exit $EXIT_USER_ABORT
    fi
    validate_bridge "$bridge" || true

    # ----- Schritt 6: VLAN (optional) ----------------------------------------
    local vlan_tag=""
    vlan_tag=$(whiptail --title "VLAN-Tag (optional)" \
        --inputbox "\nVLAN-Tag für alle Netzwerkkarten (leer lassen für kein VLAN):\n" \
        10 60 "" \
        3>&1 1>&2 2>&3)

    if [[ $? -ne 0 ]]; then
        msg_info "Abbruch durch Benutzer."
        exit $EXIT_USER_ABORT
    fi
    if [[ -n "$vlan_tag" ]]; then
        validate_vlan "$vlan_tag" || vlan_tag=""
    fi

    # ----- Schritt 7: OVA-Datei (automatische Suche + Fallback-Dialog) -------
    local dl_dir="/var/lib/vz/template/iso"
    resolve_ova_path "$dl_dir"
    local source_path="$OVA_PATH"

    if [[ -z "$source_path" ]] || [[ ! -f "$source_path" ]]; then
        msg_error "Keine gültige OVA-Datei verfügbar. Abbruch."
        exit $EXIT_ERROR
    fi

    # ----- Schritt 8: NIC-Modell ---------------------------------------------
    local nic_model=""
    nic_model=$(whiptail --title "NIC-Modell" \
        --radiolist "\nWähle das Netzwerkkarten-Modell:\n" \
        15 60 4 \
        "e1000"   "Intel E1000 (Standard, empfohlen für Avaya)" ON \
        "virtio"   "VirtIO (höhere Performance)"               OFF \
        "vmxnet3"  "VMXNET3 (nur für VMware-Kompatibilität)"  OFF \
        3>&1 1>&2 2>&3)

    if [[ $? -ne 0 ]] || [[ -z "$nic_model" ]]; then
        nic_model="e1000"
    fi

    # ----- Schritt 9: Auto-Start ---------------------------------------------
    local start_vm="no"
    if whiptail --title "VM starten" \
        --yesno "Soll die VM nach dem Import automatisch gestartet werden?" \
        8 50; then
        start_vm="yes"
    fi

    # ----- Zusammenfassung ---------------------------------------------------
    local vlan_display="kein VLAN"
    [[ -n "$vlan_tag" ]] && vlan_display="VLAN ${vlan_tag}"
    local start_display="nein"
    [[ "$start_vm" == "yes" ]] && start_display="ja"

    whiptail --title "Zusammenfassung" \
        --yesno "\
Profil:          ${profile_label}
VM-ID:           ${vmid}
VM-Name:         ${vm_name}
vCPUs:          ${profile_cores} (1 Socket)
RAM:             ${profile_ram} MB
Disk (root):     ${profile_disk} GB
NICs (Anzahl):   ${profile_nics}
NIC-Modell:      ${nic_model}
Storage:         ${storage}
Bridge:          ${bridge} (${vlan_display})
Quelle:          ${source_path}
Auto-Start:      ${start_display}

Soll die VM mit diesen Werten erstellt werden?\
" \
        20 75

    if [[ $? -ne 0 ]]; then
        msg_info "Abbruch durch Benutzer."
        exit $EXIT_USER_ABORT
    fi

    # ----- Ausführung --------------------------------------------------------
    echo ""
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}  Starte ACM VM-Import${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo ""

    # Schritt A: OVA entpacken oder QCOW2 direkt nutzen
    local qcow2_path=""

    if [[ "$source_path" == *.ova ]] || [[ "$source_path" == *.ovf ]]; then
        local extract_dir
        extract_dir="$(dirname "$source_path")/acm-extract-${vmid}"
        mkdir -p "$extract_dir"

        check_disk_space "$source_path" "$extract_dir"

        msg_info "OVA/OVF-Datei erkannt. Entpacke nach ${extract_dir} ..."

        if ! tar -xvf "$source_path" -C "$extract_dir"; then
            local disk_free
            disk_free=$(df -h "$extract_dir" 2>/dev/null | awk 'NR==2{print $4}')
            msg_error "Fehler beim Entpacken der OVA-Datei."
            msg_error "Verfügbarer Speicher in ${extract_dir}: ${disk_free:-unbekannt}"
            exit $EXIT_ERROR
        fi
        msg_ok "OVA erfolgreich entpackt nach ${extract_dir}"

        qcow2_path=$(find_qcow2_in_dir "$extract_dir" | head -1)
        if [[ -z "$qcow2_path" ]]; then
            msg_warn "Keine QCOW2-Datei gefunden. Suche nach VMDK/anderen Formaten ..."
            qcow2_path=$(find "$extract_dir" -maxdepth 1 -type f \( -name "*.vmdk" -o -name "*.vdi" -o -name "*.vhd" \) 2>/dev/null | head -1 || true)
        fi

        if [[ -z "$qcow2_path" ]]; then
            msg_error "Kein VM-Image im OVA-Archiv gefunden."
            msg_error "Inhalt von ${extract_dir}:"
            ls -la "$extract_dir"
            exit $EXIT_ERROR
        fi
        msg_info "Gefundenes Image: ${qcow2_path}"
    else
        qcow2_path="$source_path"
        if [[ ! -f "$qcow2_path" ]]; then
            msg_error "Datei nicht gefunden: ${qcow2_path}"
            exit $EXIT_ERROR
        fi
        msg_ok "Nutze Image-Datei: ${qcow2_path}"
    fi

    # 2. VM erstellen
    msg_info "Erstelle VM ${vmid} (${vm_name}) ..."
    qm create "${vmid}" \
        --name "${vm_name}" \
        --sockets 1 \
        --cores "${profile_cores}" \
        --memory "${profile_ram}" \
        --cpu host \
        --bios ovmf \
        --scsihw virtio-scsi-pci \
        --machine q35 \
        --agent 1

    if [[ $? -ne 0 ]]; then
        msg_error "Fehler beim Erstellen der VM ${vmid}."
        exit $EXIT_ERROR
    fi
    msg_ok "VM ${vmid} erstellt."

    # 3. Disk importieren
    msg_info "Importiere Disk nach ${storage} ..."
    local import_output
    import_output=$(qm importdisk "${vmid}" "${qcow2_path}" "${storage}" 2>&1)
    local import_exit=$?

    if [[ $import_exit -ne 0 ]]; then
        local df_info
        df_info=$(df -h "$qcow2_path" 2>/dev/null | awk 'NR==2{print "Frei: " $4 " von " $2}')
        msg_error "Fehler beim Import der Disk nach '${storage}'."
        echo ""
        echo "  Befehl:  qm importdisk ${vmid} ${qcow2_path} ${storage}"
        echo "  Fehler:  ${import_output}"
        echo "  ${df_info:-}"
        echo ""
        msg_error "Mögliche Ursachen:"
        msg_error "  1. Storage '${storage}' unterstützt keine VM-Images"
        msg_error "  2. Speicherplatz voll (df -h)"
        msg_error "  3. QCOW2-Datei defekt (qemu-img check ${qcow2_path})"
        exit $EXIT_ERROR
    fi
    msg_ok "Disk erfolgreich importiert nach '${storage}'."

    # 4. Unused Disk als scsi0 einbinden
    msg_info "Ermittle importierte Disk aus VM-Config ..."
    local vm_config
    vm_config=$(qm config "${vmid}" 2>&1)
    local unused_disk
    unused_disk=$(echo "${vm_config}" | grep -oP 'unused\d+: (\S+)' | head -1 | awk '{print $2}')

    if [[ -z "$unused_disk" ]]; then
        msg_error "Konnte keine importierte (unused) Disk in der VM-Config finden."
        msg_error "VM-Config:"
        echo "${vm_config}"
        exit $EXIT_ERROR
    fi

    msg_info "Importierte Disk: ${unused_disk}"
    msg_info "Binde Disk als scsi0 ein (cache=directsync) ..."
    qm set "${vmid}" \
        --scsi0 "${unused_disk},cache=directsync" \
        --boot order=scsi0

    if [[ $? -ne 0 ]]; then
        msg_error "Fehler beim Einbinden der Disk als scsi0."
        exit $EXIT_ERROR
    fi
    msg_ok "scsi0 eingerichtet mit Boot-Reihenfolge."

    # 5. Netzwerkkarten
    msg_info "Füge ${profile_nics} Netzwerkkarte(n) hinzu (${nic_model}, ${bridge}) ..."
    for ((i = 0; i < profile_nics; i++)); do
        local net_opts="model=${nic_model},bridge=${bridge}"
        if [[ -n "$vlan_tag" ]]; then
            net_opts="${net_opts},tag=${vlan_tag}"
        fi
        if ! qm set "${vmid}" "--net${i}" "${net_opts}" >/dev/null 2>&1; then
            msg_error "Fehler beim Hinzufügen von net${i}."
            exit $EXIT_ERROR
        fi
        msg_info "  net${i}: ${nic_model} -> ${bridge}${vlan_tag:+ (VLAN ${vlan_tag})}"
    done

    # 6. EFI-Disk
    msg_info "Richte EFI-Disk für OVMF ein ..."
    if ! qm set "${vmid}" --efidisk0 "${storage}:0,pre-enrolled-keys=1" 2>/dev/null; then
        if ! qm set "${vmid}" --efidisk0 "${storage}:0" 2>/dev/null; then
            msg_warn "Konnte keine EFI-Disk anlegen. Evt. manuell nachholen."
        else
            msg_ok "EFI-Disk angelegt."
        fi
    else
        msg_ok "EFI-Disk angelegt."
    fi

    # 7. Optional: Start
    if [[ "$start_vm" == "yes" ]]; then
        msg_info "Starte VM ${vmid} ..."
        qm start "${vmid}" && msg_ok "VM ${vmid} gestartet." || msg_warn "VM ${vmid} konnte nicht gestartet werden."
    fi

    # ----- Fertig ------------------------------------------------------------
    echo ""
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}  ACM Import abgeschlossen!${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo ""

    local final_start_text="nein (manuell starten: qm start ${vmid})"
    [[ "$start_vm" == "yes" ]] && final_start_text="ja (gestartet)"

    whiptail --title "Import abgeschlossen" \
        --msgbox "\
VM-ID:           ${vmid}
Name:            ${vm_name}
Profil:          ${profile_label}
vCPUs:           ${profile_cores} (1 Socket)
RAM:             ${profile_ram} MB
NICs:            ${profile_nics} (${nic_model} @ ${bridge})
Storage:         ${storage}
Autostart:       ${final_start_text}

ACM wurde erfolgreich als VM importiert.

Nächste Schritte:
• VM in Proxmox UI prüfen
• Lizenz in ACM aktivieren
• Netzwerkkonfiguration anpassen\
" \
        18 70

    msg_ok "VM ${vmid} (${vm_name}) erfolgreich erstellt."
}

main "$@"
