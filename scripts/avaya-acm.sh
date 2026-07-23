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
#  0  OK  — Erfolgreich ausgeführt
#  1  ERROR  — Allgemeiner Fehler (qm, wget, tar, etc.)
#  2  USER_ABORT  — Abbruch durch Benutzer (ESC/Cancel)
# 127  — Befehl nicht gefunden (declare -A, fehlende Tools)
# 255  — whiptail-Fehler (falsche Argumente)
# -----------------------------------------------------------------------------
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
        pvesh get /storage --noborder --noheader -output-format json 2>/dev/null \
            | python3 -c "import sys,json; [print(f'  - {s[\"storage\"]}') for s in json.load(sys.stdin)]" 2>/dev/null \
            || pvesh get /storage --noborder --noheader 2>/dev/null | awk '{print "  - " $0}'
        return 1
    fi

    # Prüfen, ob der Storage VM-Images unterstützt
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
    # Suche nach .qcow2 oder .img-Dateien im Verzeichnis
    find "$dir" -maxdepth 1 -type f \( -name "*.qcow2" -o -name "*.img" -o -name "*.raw" \) 2>/dev/null | head -5 || true
}

# Prüft, ob genug Speicherplatz für die OVA-Entpackung vorhanden ist
check_disk_space() {
    local ova_path="$1"
    local target_dir="$2"

    # OVA-Größe ermitteln
    local ova_size_kb
    ova_size_kb=$(du -k "$ova_path" 2>/dev/null | cut -f1)
    if [[ -z "$ova_size_kb" ]] || [[ "$ova_size_kb" -eq 0 ]]; then
        msg_warn "Konnte Größe der OVA-Datei nicht ermitteln. Überspringe Speicherprüfung."
        return 0
    fi

    # Freier Speicher im Ziel-Verzeichnis
    local free_kb
    free_kb=$(df -k "$target_dir" 2>/dev/null | awk 'NR==2{print $4}')
    if [[ -z "$free_kb" ]] || [[ "$free_kb" -eq 0 ]]; then
        msg_warn "Konnte freien Speicher nicht ermitteln. Überspringe Speicherprüfung."
        return 0
    fi

    # Großzügiger Faktor: entpackte OVA braucht meist das 2-3fache
    # Wir prüfen auf min. 3x OVA-Größe oder 5 GB (je nachdem was größer ist)
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

# --- Profile ----------------------------------------------------------------
# NAME|CORES|RAM_MB|DISK_GB|NICS
declare -A PROFILES
PROFILES["small"]="Small ACM|4|8192|100|2"
PROFILES["medium"]="Medium ACM|6|16384|200|3"
PROFILES["large"]="Large ACM|8|32768|300|4"

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

    # Name validieren (nur sichere Zeichen)
    if [[ -z "$vm_name" ]] || [[ ! "$vm_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        msg_error "Ungültiger VM-Name. Erlaubt: Buchstaben, Ziffern, Punkte, Unterstriche, Bindestriche."
        whiptail --title "Ungültiger Name" --msgbox "Der Name darf nur Buchstaben, Ziffern, Punkte, Unterstriche und\nBindestriche enthalten." 8 60
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
        local extract_dir
        extract_dir="$(dirname "$source_path")/acm-extract-${vmid}"
        mkdir -p "$extract_dir"

        # Checks vor der Entpackung
        check_disk_space "$source_path" "$extract_dir"

        msg_info "OVA/OVF-Datei erkannt. Entpacke nach ${extract_dir} ..."

        if ! tar -xvf "$source_path" -C "$extract_dir"; then
            local disk_free
            disk_free=$(df -h "$extract_dir" 2>/dev/null | awk 'NR==2{print $4}')
            msg_error "Fehler beim Entpacken der OVA-Datei."
            msg_error "Verfügbarer Speicher in ${extract_dir}: ${disk_free:-unbekannt}"
            msg_error "Prüfe: df -h $(dirname "$extract_dir")"
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
        msg_error "  1. Storage '${storage}' unterstützt keine VM-Images (pvesh get /storage/${storage})"
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
