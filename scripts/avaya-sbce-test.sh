#!/usr/bin/env bash

#===============================================================================
# Avaya SBCE — KVM-Import auf Proxmox VE
#===============================================================================
# Beschreibung:  Erstellt eine KVM-VM aus einem SBCE QCOW2-Image.
#                Unterstützt die Varianten SBC, Small SBC und EMS.
#                Basiert auf der Avaya SBCE KVM-Installationsanleitung.
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

# --- Status-Konstanten -------------------------------------------------------
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

# whiptail prüfen
check_whiptail() {
    if ! command -v whiptail &>/dev/null; then
        echo -e "${RED}[ERROR]${NC} whiptail ist nicht installiert."
        echo "Bitte installieren: apt-get install whiptail"
        exit $EXIT_ERROR
    fi
}

# Prüft, ob die benötigten Tools vorhanden sind
check_tools() {
    local missing=0
    for tool in qm wget curl; do
        if ! command -v "$tool" &>/dev/null; then
            msg_error "'${tool}' ist nicht installiert oder nicht im PATH."
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        exit $EXIT_ERROR
    fi
}

# Validiert, ob eine VM-ID bereits vergeben ist
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

# Validiert, ob ein Storage in Proxmox existiert
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

    # Prüfen, ob Storage Content-Type für Images unterstützt
    local content
    content=$(pvesh get /storage/"${storage}" --noborder --noheader -output-format json 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('content',''))" 2>/dev/null)
    if [[ -n "$content" ]] && [[ "$content" != *"images"* ]] && [[ "$content" != *"rootdir"* ]]; then
        msg_warn "Storage '${storage}' unterstützt möglicherweise keine VM-Images (content: ${content})."
        if ! whiptail --title "Storage-Warnung" \
            --yesno "Storage '${storage}' scheint keine VM-Images zu unterstützen.\n\nTrotzdem fortfahren?" \
            10 60; then
            return 1
        fi
    fi
    return 0
}

# Validiert Bridge-Interfaces
validate_bridge() {
    local bridge="$1"
    if ! ip link show "$bridge" &>/dev/null; then
        msg_warn "Bridge '${bridge}' existiert nicht oder ist nicht aktiv."
        msg_info "Verfügbare Bridges:"
        ip -br link show type bridge 2>/dev/null | awk '{print "  - " $1}' || true
        if ! whiptail --title "Bridge-Warnung" \
            --yesno "Bridge '${bridge}' wurde nicht gefunden.\n\nTrotzdem fortfahren?" \
            10 60; then
            return 1
        fi
    fi
    return 0
}

# Validiert eine VLAN-ID (1-4094)
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

# Prüft, ob eine Datei existiert (und ggf. die korrekte Endung hat)
validate_qcow2() {
    local filepath="$1"
    if [[ ! -f "$filepath" ]]; then
        msg_error "QCOW2-Datei nicht gefunden: ${filepath}"
        return 1
    fi
    if [[ ! "$filepath" =~ \.qcow2$ ]] && [[ ! "$filepath" =~ \.qcow2\.gz$ ]] && [[ ! "$filepath" =~ \.img$ ]] && [[ ! "$filepath" =~ \.raw$ ]]; then
        msg_warn "Die Datei '${filepath}' hat keine typische Image-Endung (.qcow2, .img)."
        if ! whiptail --title "Datei-Endung" \
            --yesno "Die ausgewählte Datei hat keine erkennbare Image-Endung.\n\nTrotzdem fortfahren?" \
            10 60; then
            return 1
        fi
    fi
    # Dateigröße prüfen (sollte > 100 MB sein)
    local size_mb
    size_mb=$(du -m "$filepath" 2>/dev/null | cut -f1)
    if [[ -n "$size_mb" ]] && [[ "$size_mb" -lt 100 ]]; then
        msg_warn "Die QCOW2-Datei ist nur ${size_mb} MB groß. Das scheint sehr klein für ein VM-Image."
        if ! whiptail --title "Dateigröße" \
            --yesno "Die Datei ist nur ${size_mb} MB groß.\n\nTrotzdem fortfahren?" \
            10 60; then
            return 1
        fi
    fi
    return 0
}

# Lädt eine Datei von einer URL herunter
download_file() {
    local url="$1"
    local target="$2"

    msg_info "Lade herunter: ${url}"
    msg_info "Ziel: ${target}"

    # Wget mit Fortschrittsanzeige
    if wget --progress=dot:giga -O "$target" "$url"; then
        msg_ok "Download erfolgreich: $(du -h "$target" 2>/dev/null | cut -f1)"
        return 0
    else
        msg_error "Download fehlgeschlagen."
        return 1
    fi
}

# Gibt verfügbare Proxmox-Storages als Liste zurück
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
    # Fallback: zeige alle Storages
    pvesh get /storage --noborder --noheader 2>/dev/null | awk '{print $1}' || true
}

# --- Profil-Definitionen -----------------------------------------------------
# Format: NAME|CORES|RAM_MB|DISK_GB|NICS
declare -A PROFILES
PROFILES["sbc"]="SBC|4|8192|64|6"
PROFILES["small"]="Small SBC|2|4096|64|4"
PROFILES["ems"]="EMS|3|8192|64|2"

# --- Hauptfunktion -----------------------------------------------------------

main() {
    check_whiptail
    check_tools

    # ----- Splash / Begrüßung ------------------------------------------------
    whiptail --title "Avaya SBCE — KVM-Import" \
        --msgbox "Dieses Skript erstellt eine KVM-VM für Avaya SBCE auf Proxmox VE.\n\n" \
"Es führt folgende Schritte aus:
• VM mit Profil-Vorgaben anlegen (CPU, RAM, Disk)
• QCOW2-Image importieren (lokal oder via Download)
• Netzwerkkarten hinzufügen (je nach Variante 2, 4 oder 6)
• BIOS OVMF, VirtIO SCSI, CPU Host, E1000-NICs
• Boot von der importierten Festplatte (scsi0)" \
        16 65

    if [[ $? -ne 0 ]]; then
        msg_info "Abbruch durch Benutzer."
        exit $EXIT_USER_ABORT
    fi

    # ----- Schritt 1: Variante wählen ----------------------------------------
    local variant_choice
    variant_choice=$(whiptail --title "SBCE-Variante" \
        --radiolist "\nWähle die SBCE-Variante:\n\nDie Profile basieren auf der offiziellen Avaya SBCE-Tabelle.\n" \
        18 60 5 \
        "sbc"   "SBC — 4 Cores, 8 GB RAM, 6 NICs"    ON \
        "small" "Small SBC — 2 Cores, 4 GB RAM, 4 NICs" OFF \
        "ems"   "EMS — 3 Cores, 8 GB RAM, 2 NICs"      OFF \
        3>&1 1>&2 2>&3)

    if [[ $? -ne 0 ]] || [[ -z "$variant_choice" ]]; then
        msg_info "Abbruch durch Benutzer."
        exit $EXIT_USER_ABORT
    fi

    # Profil-Daten auslesen
    local profile_data="${PROFILES[$variant_choice]}"
    IFS='|' read -r profile_label profile_cores profile_ram profile_disk profile_nics <<< "$profile_data"

    msg_info "Gewählte Variante: ${profile_label}"
    msg_info "  CPU: ${profile_cores} Cores  |  RAM: ${profile_ram} MB  |  Disk: ${profile_disk} GB  |  NICs: ${profile_nics}"

    # ----- Schritt 2: VM-ID ---------------------------------------------------
    local vmid=""
    while true; do
        vmid=$(whiptail --title "VM-ID" \
            --inputbox "\nGib eine eindeutige VM-ID ein (100 - 999999999):\n" \
            10 60 "300" \
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
        --inputbox "\nGib einen Namen für die VM ein (z. B. sbce-sbc, sbce-ems):\n" \
        10 60 "sbce-${variant_choice}" \
        3>&1 1>&2 2>&3)

    if [[ $? -ne 0 ]]; then
        msg_info "Abbruch durch Benutzer."
        exit $EXIT_USER_ABORT
    fi

    # ----- Schritt 4: Storage wählen ------------------------------------------
    local storage_list
    storage_list=$(list_storages)
    local storage=""

    if [[ -z "$storage_list" ]]; then
        # Keine Liste verfügbar, manuelle Eingabe
        while true; do
            storage=$(whiptail --title "Storage" \
                --inputbox "\nGib den Proxmox-Storage für das VM-Image ein (z. B. local-lvm, Avaya):\n" \
                10 60 "local-lvm" \
                3>&1 1>&2 2>&3)

            if [[ $? -ne 0 ]]; then
                msg_info "Abbruch durch Benutzer."
                exit $EXIT_USER_ABORT
            fi

            if validate_storage "$storage"; then
                break
            fi

            whiptail --title "Storage-Fehler" \
                --msgbox "Storage '${storage}' existiert nicht. Bitte erneut eingeben." \
                8 50
        done
    else
        # Storage-Auswahl aus Liste
        local storage_menu_items=()
        while IFS= read -r st; do
            [[ -z "$st" ]] && continue
            storage_menu_items+=("$st" "$st")
        done <<< "$storage_list"

        if [[ ${#storage_menu_items[@]} -eq 0 ]]; then
            # Fallback auf Eingabe
            while true; do
                storage=$(whiptail --title "Storage" \
                    --inputbox "\nGib den Proxmox-Storage für das VM-Image ein (z. B. local-lvm):\n" \
                    10 60 "local-lvm" \
                    3>&1 1>&2 2>&3)

                if [[ $? -ne 0 ]]; then
                    msg_info "Abbruch durch Benutzer."
                    exit $EXIT_USER_ABORT
                fi

                if validate_storage "$storage"; then
                    break
                fi

                whiptail --title "Storage-Fehler" \
                    --msgbox "Storage '${storage}' existiert nicht. Bitte erneut eingeben." \
                    8 50
            done
        else
            # Menü-Tags müssen eindeutig sein
            local storage_choice
            storage_choice=$(whiptail --title "Storage auswählen" \
                --menu "\nWähle den Ziel-Storage für das VM-Image:\n" \
                15 50 6 \
                "${storage_menu_items[@]}" \
                3>&1 1>&2 2>&3)

            if [[ $? -ne 0 ]]; then
                msg_info "Abbruch durch Benutzer."
                exit $EXIT_USER_ABORT
            fi

            storage="$storage_choice"
            msg_info "Storage: ${storage}"
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

    # ----- Schritt 6: VLAN-Tag (optional) -------------------------------------
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
        if ! validate_vlan "$vlan_tag"; then
            whiptail --title "Ungültige VLAN-ID" \
                --msgbox "Ungültige VLAN-ID. Erlaubt: 1-4094.\n\nDas VLAN wird ignoriert." \
                8 50
            vlan_tag=""
        fi
    fi

    # ----- Schritt 7: NIC-Modell ----------------------------------------------
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

    # ----- Schritt 8: QCOW2-Verzeichnis ---------------------------------------
    local qcow2_dir=""
    qcow2_dir=$(whiptail --title "QCOW2-Verzeichnis" \
        --inputbox "\nGib das Verzeichnis mit der QCOW2-Datei ein:\nBeispiel: /var/lib/vz/template/iso/\n" \
        12 70 "/var/lib/vz/template/iso/" \
        3>&1 1>&2 2>&3)

    if [[ $? -ne 0 ]]; then
        msg_info "Abbruch durch Benutzer."
        exit $EXIT_USER_ABORT
    fi

    # Normierung: Entferne angehängten Slash für Konsistenz
    qcow2_dir="${qcow2_dir%/}"

    # ----- Schritt 9: QCOW2-Dateiname -----------------------------------------
    local qcow2_file=""
    qcow2_file=$(whiptail --title "QCOW2-Dateiname" \
        --inputbox "\nGib den Dateinamen der QCOW2-Datei ein (inkl. Endung):\nBeispiel: sbce.qcow2\n" \
        12 70 "sbce-${variant_choice}.qcow2" \
        3>&1 1>&2 2>&3)

    if [[ $? -ne 0 ]]; then
        msg_info "Abbruch durch Benutzer."
        exit $EXIT_USER_ABORT
    fi

    local qcow2_path="${qcow2_dir}/${qcow2_file}"

    # ----- Schritt 10: Download-URL (optional) ---------------------------------
    local dl_url=""
    dl_url=$(whiptail --title "Download-URL (optional)" \
        --inputbox "\nWenn die QCOW2-Datei noch nicht lokal existiert, kann sie\ndirekt heruntergeladen werden. URL eingeben oder leer lassen:\n" \
        12 70 "" \
        3>&1 1>&2 2>&3)

    if [[ $? -ne 0 ]]; then
        msg_info "Abbruch durch Benutzer."
        exit $EXIT_USER_ABORT
    fi

    # ----- Schritt 11: VM automatisch starten ----------------------------------
    local start_vm=""
    if whiptail --title "VM starten" \
        --yesno "Soll die VM nach dem Import automatisch gestartet werden?" \
        8 50; then
        start_vm="yes"
    else
        start_vm="no"
    fi

    # ----- Schritt 12: Zusammenfassung vor Ausführung -------------------------
    local vlan_display="kein VLAN"
    [[ -n "$vlan_tag" ]] && vlan_display="VLAN ${vlan_tag}"
    local start_display="nein"
    [[ "$start_vm" == "yes" ]] && start_display="ja"

    local summary_text="\n"
    summary_text+="Variante:        ${profile_label}\n"
    summary_text+="VM-ID:           ${vmid}\n"
    summary_text+="VM-Name:         ${vm_name}\n"
    summary_text+="CPU Cores:       ${profile_cores}\n"
    summary_text+="RAM:             ${profile_ram} MB\n"
    summary_text+="Disk (root):     ${profile_disk} GB\n"
    summary_text+="NICs (Anzahl):   ${profile_nics}\n"
    summary_text+="NIC-Modell:      ${nic_model}\n"
    summary_text+="Storage:         ${storage}\n"
    summary_text+="Bridge:          ${bridge} (${vlan_display})\n"
    summary_text+="QCOW2:           ${qcow2_path}\n"
    summary_text+="Auto-Start:      ${start_display}\n"

    if [[ -n "$dl_url" ]]; then
        summary_text+="Download-URL:    ${dl_url}\n"
    fi

    whiptail --title "Zusammenfassung" \
        --yesno "${summary_text}\nSoll die VM mit diesen Werten erstellt werden?" \
        20 75

    if [[ $? -ne 0 ]]; then
        msg_info "Abbruch durch Benutzer."
        exit $EXIT_USER_ABORT
    fi

    # ----- Ausführung ---------------------------------------------------------
    echo ""
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}  Starte VM-Import${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo ""

    # 1. QCOW2 prüfen / herunterladen
    if [[ ! -f "$qcow2_path" ]]; then
        if [[ -n "$dl_url" ]]; then
            msg_info "QCOW2 nicht lokal gefunden. Starte Download ..."
            mkdir -p "$qcow2_dir"
            if ! download_file "$dl_url" "$qcow2_path"; then
                msg_error "Download fehlgeschlagen. VM wird nicht erstellt."
                exit $EXIT_ERROR
            fi
        else
            msg_error "QCOW2-Datei nicht gefunden: ${qcow2_path}"
            msg_error "Bitte Pfad prüfen oder Download-URL angeben."
            exit $EXIT_ERROR
        fi
    else
        msg_ok "QCOW2-Datei gefunden: ${qcow2_path}"
    fi

    # QCOW2-Validierung (nur Warnungen)
    validate_qcow2 "$qcow2_path" || true

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

    # 4. Importierte "unused disk" aus der Config holen und als scsi0 einbinden
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

    msg_info "Gefundene importierte Disk: ${unused_disk}"

    # 5. Unused Disk als scsi0 einbinden und Boot-Reihenfolge setzen
    msg_info "Binde Disk als scsi0 ein (cache=directsync) ..."
    qm set "${vmid}" \
        --scsi0 "${unused_disk},cache=directsync" \
        --boot order=scsi0

    if [[ $? -ne 0 ]]; then
        msg_error "Fehler beim Einbinden der Disk als scsi0."
        exit $EXIT_ERROR
    fi
    msg_ok "scsi0 eingerichtet mit Boot-Reihenfolge."

    # 6. Netzwerkkarten hinzufügen
    msg_info "Füge ${profile_nics} Netzwerkkarte(n) hinzu (${nic_model}, ${bridge}) ..."
    for ((i = 0; i < profile_nics; i++)); do
        local net_param="net${i},model=${nic_model},bridge=${bridge}"
        if [[ -n "$vlan_tag" ]]; then
            net_param="${net_param},tag=${vlan_tag}"
        fi
        qm set "${vmid}" "--${net_param}" 2>/dev/null || \
        qm set "${vmid}" "${net_param}" 2>/dev/null || {
            msg_error "Fehler beim Hinzufügen von net${i}."
            exit $EXIT_ERROR
        }
        msg_info "  net${i}: ${nic_model} -> ${bridge}${vlan_display:+ (VLAN ${vlan_tag})}"
    done

    # 7. Ggf. EFI-Disk für OVMF hinzufügen
    msg_info "Richte EFI-Disk für OVMF ein ..."
    if ! qm set "${vmid}" --efidisk0 "${storage}:0,pre-enrolled-keys=1" 2>/dev/null; then
        # Fallback: versuche ohne pre-enrolled-keys
        if ! qm set "${vmid}" --efidisk0 "${storage}:0" 2>/dev/null; then
            msg_warn "Konnte keine EFI-Disk anlegen. Evt. manuell nachholen."
        else
            msg_ok "EFI-Disk angelegt (ohne pre-enrolled-keys)."
        fi
    else
        msg_ok "EFI-Disk angelegt."
    fi

    # 8. Optional: VM starten
    if [[ "$start_vm" == "yes" ]]; then
        msg_info "Starte VM ${vmid} ..."
        qm start "${vmid}" && msg_ok "VM ${vmid} gestartet." || msg_warn "VM ${vmid} konnte nicht gestartet werden."
    fi

    # ----- Fertig -------------------------------------------------------------
    echo ""
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}  Import abgeschlossen!${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo ""

    local final_start_text="nein (manuell starten mit: qm start ${vmid})"
    [[ "$start_vm" == "yes" ]] && final_start_text="ja (wurde gestartet)"

    whiptail --title "Import abgeschlossen" \
        --msgbox "\
VM-ID:           ${vmid}
Name:            ${vm_name}
Variante:        ${profile_label}
CPU:             ${profile_cores} Cores
RAM:             ${profile_ram} MB
NICs:            ${profile_nics} (${nic_model} @ ${bridge})
Storage:         ${storage}
QCOW2:           ${qcow2_file}
Autostart:       ${final_start_text}

Status:          VM wurde erfolgreich erstellt.

Nächste Schritte:
• VM in Proxmox UI prüfen
• ggf. Serielles Konsolen-Login testen
• Netzwerkkonfiguration in SBCE vornehmen" \
        20 70

    msg_ok "VM ${vmid} (${vm_name}) erfolgreich erstellt."
    msg_info "Zum Anmelden: qm terminal ${vmid} oder über die Proxmox-WebUI."
}

main "$@"
