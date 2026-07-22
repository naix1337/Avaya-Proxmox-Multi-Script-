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

EXIT_OK=0
EXIT_ERROR=1
EXIT_USER_ABORT=2

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
        pvesh get /storage --noborder --noheader 2>/dev/null | awk '{print "  - " $0}' || true
        return 1
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
    # Suche nach .qcow2 oder .img-Dateien im Verzeichnis
    find "$dir" -maxdepth 1 -type f \( -name "*.qcow2" -o -name "*.img" -o -name "*.raw" \) 2>/dev/null | head -5 || true
}

# --- Profile ----------------------------------------------------------------
# NAME|CORES|RAM_MB|DISK_GB|NICS
declare -A PROFILES
PROFILES["small"]   "Small ACM|4|8192|100|2"
PROFILES["medium"]  "Medium ACM|6|16384|200|3"
PROFILES["large"]   "Large ACM|8|32768|300|4"

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

    # ----- Schritt 1: Variante wählen ---------------------------------------
    local variant_choice
    variant_choice=$(whiptail --title "ACM-Profil" \
        --radiolist "\
Wähle ein ACM-Profil:\n\
" \
        16 60 5 \
        "small"   "Small ACM    — 4 Cores, 8 GB RAM, 100 GB, 2 NICs"  ON \
        "medium"  "Medium ACM   — 6 Cores, 16 GB RAM, 200 GB, 3 NICs" OFF \
        "large"   "Large ACM    — 8 Cores, 32 GB RAM, 300 GB, 4 NICs" OFF \
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

    # ----- Schritt 3: VM-Name -------------------------------------------------
    local vm_name=""
    vm_name=$(whiptail --title "VM-Name" \
        --inputbox "\nGib einen Namen für die VM ein (z. B. acm-small, acm-prod):\n" \
        10 60 "acm-${variant_choice}" \
        3>&1 1>&2 2>&3)

    if [[ $? -ne 0 ]]; then
        msg_info "Abbruch durch Benutzer."
        exit $EXIT_USER_ABORT
    fi

    # ----- Schritt 4: Storage -------------------------------------------------
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

    # ----- Schritt 5: Bridge --------------------------------------------------
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

    # ----- Schritt 6: VLAN (optional) -----------------------------------------
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

    # ----- Schritt 7: Quelle (lokal oder Download) ---------------------------
    local source_type=""
    source_type=$(whiptail --title "Quelle" \
        --radiolist "\nWo befindet sich die ACM-OVA/Image-Datei?\n" \
        12 60 3 \
        "local"    "Lokale OVA-Datei oder bereits entpacktes QCOW2" ON \
        "download" "Von URL herunterladen (OVA von Avaya PLDS)"    OFF \
        3>&1 1>&2 2>&3)

    if [[ $? -ne 0 ]] || [[ -z "$source_type" ]]; then
        msg_info "Abbruch durch Benutzer."
        exit $EXIT_USER_ABORT
    fi

    local source_path=""
    local dl_url=""

    if [[ "$source_type" == "local" ]]; then
        source_path=$(whiptail --title "OVA/QCOW2-Pfad" \
            --inputbox "\nGib den vollständigen Pfad zur OVA- oder QCOW2-Datei ein:\nBeispiel: /var/lib/vz/template/iso/acm.ova\n" \
            12 70 "/var/lib/vz/template/iso/" \
            3>&1 1>&2 2>&3)
        if [[ $? -ne 0 ]]; then
            msg_info "Abbruch durch Benutzer."
            exit $EXIT_USER_ABORT
        fi
    else
        dl_url=$(whiptail --title "Download-URL" \
            --inputbox "\nGib die Download-URL der ACM-OVA ein:\n(Hinweis: URL aus Avaya PLDS generieren)\n" \
            12 70 "" \
            3>&1 1>&2 2>&3)
        if [[ $? -ne 0 ]] || [[ -z "$dl_url" ]]; then
            msg_info "Abbruch durch Benutzer."
            exit $EXIT_USER_ABORT
        fi

        local dl_dir="/var/lib/vz/template/iso/"
        local ova_filename="acm.ova"
        ova_filename=$(basename "$dl_url" | sed 's/?.*//') # URL-Parameter entfernen
        [[ -z "$ova_filename" ]] && ova_filename="acm.ova"

        source_path="${dl_dir}${ova_filename}"
        mkdir -p "$dl_dir"

        if [[ ! -f "$source_path" ]]; then
            if ! download_file "$dl_url" "$source_path"; then
                msg_error "Download fehlgeschlagen."
                exit $EXIT_ERROR
            fi
        else
            msg_ok "Datei bereits vorhanden: ${source_path}"
        fi
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

    # ----- Zusammenfassung ----------------------------------------------------
    local vlan_display="kein VLAN"
    [[ -n "$vlan_tag" ]] && vlan_display="VLAN ${vlan_tag}"
    local start_display="nein"
    [[ "$start_vm" == "yes" ]] && start_display="ja"
    local src_display="$source_path"
    if [[ "$source_type" == "download" ]]; then
        src_display="${source_path} (von URL geladen)"
    fi

    whiptail --title "Zusammenfassung" \
        --yesno "\
Profil:          ${profile_label}
VM-ID:           ${vmid}
VM-Name:         ${vm_name}
CPU Cores:       ${profile_cores}
RAM:             ${profile_ram} MB
Disk (root):     ${profile_disk} GB
NICs (Anzahl):   ${profile_nics}
NIC-Modell:      ${nic_model}
Storage:         ${storage}
Bridge:          ${bridge} (${vlan_display})
Quelle:          ${src_display}
Auto-Start:      ${start_display}

Soll die VM mit diesen Werten erstellt werden?\
" \
        20 75

    if [[ $? -ne 0 ]]; then
        msg_info "Abbruch durch Benutzer."
        exit $EXIT_USER_ABORT
    fi

    # ----- Ausführung ---------------------------------------------------------
    echo ""
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}  Starte ACM VM-Import${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo ""

    # Schritt A: OVA entpacken oder QCOW2 direkt nutzen
    local qcow2_path=""

    if [[ "$source_path" == *.ova ]] || [[ "$source_path" == *.ovf ]]; then
        msg_info "OVA/OVF-Datei erkannt. Entpacke nach ${source_path%.*} ..."
        local extract_dir
        extract_dir="$(dirname "$source_path")/acm-extract-${vmid}"
        mkdir -p "$extract_dir"

        if ! tar -xvf "$source_path" -C "$extract_dir"; then
            msg_error "Fehler beim Entpacken der OVA-Datei."
            exit $EXIT_ERROR
        fi
        msg_ok "OVA erfolgreich entpackt nach ${extract_dir}"

        # QCOW2 im entpackten Verzeichnis suchen
        qcow2_path=$(find_qcow2_in_dir "$extract_dir" | head -1)
        if [[ -z "$qcow2_path" ]]; then
            msg_warn "Keine QCOW2-Datei gefunden. Suche nach VMDK/ anderen Formaten ..."
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
        # Direkt eine QCOW2/IMG-Datei
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
        --cores "${profile_cores}" \
        --memory "${profile_ram}" \
        --cpu host \
        --bios ovmf \
        --scsihw virtio-scsi-pci \
        --machine q35 \
        --net0 none \
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
        msg_error "Fehler beim Import der Disk."
        msg_error "qm importdisk Ausgabe:"
        echo "${import_output}"
        exit $EXIT_ERROR
    fi
    msg_ok "Disk erfolgreich importiert."

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
        local net_param="net${i},model=${nic_model},bridge=${bridge}"
        if [[ -n "$vlan_tag" ]]; then
            net_param="${net_param},tag=${vlan_tag}"
        fi
        qm set "${vmid}" "--${net_param}" 2>/dev/null || \
        qm set "${vmid}" "${net_param}" 1>/dev/null || {
            msg_error "Fehler beim Hinzufügen von net${i}."
            exit $EXIT_ERROR
        }
        msg_info "  net${i}: ${nic_model} -> ${bridge}${vlan_display:+ (VLAN ${vlan_tag})}"
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

    # ----- Fertig -------------------------------------------------------------
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
CPU:             ${profile_cores} Cores
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
