#!/bin/bash

set -e

PRODUCT=""
PROFILE=""
CORES=""
RAM=""
DISK=""
SWAP=""
BRIDGE="vmbr0"
STORAGE="local-lvm"
TEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
UNPRIVILEGED=1
START_AFTER_CREATE=1

choose_product() {
  while true; do
    clear
    echo "======================================"
    echo " Avaya Proxmox LXC Installer"
    echo "======================================"
    echo "1) ACM"
    echo "2) SMGR"
    echo "3) ASM"
    echo "4) SBCE"
    echo "5) Breeze"
    echo "6) AADS"
    echo "7) CMS"
    echo "0) Beenden"
    echo
    read -rp "Produkt auswählen: " choice

    case "$choice" in
      1) PRODUCT="ACM"; break ;;
      2) PRODUCT="SMGR"; break ;;
      3) PRODUCT="ASM"; break ;;
      4) PRODUCT="SBCE"; break ;;
      5) PRODUCT="Breeze"; break ;;
      6) PRODUCT="AADS"; break ;;
      7) PRODUCT="CMS"; break ;;
      0) exit 0 ;;
      *) echo "Ungültige Auswahl"; sleep 1 ;;
    esac
  done
}

choose_profile() {
  while true; do
    clear
    echo "======================================"
    echo " Produkt: $PRODUCT"
    echo " Profil auswählen"
    echo "======================================"
    echo "1) Profile 1"
    echo "2) Profile 2"
    echo "3) Profile 3"
    echo "0) Zurück"
    echo
    read -rp "Profil auswählen: " choice

    case "$choice" in
      1) PROFILE="Profile 1"; break ;;
      2) PROFILE="Profile 2"; break ;;
      3) PROFILE="Profile 3"; break ;;
      0) choose_product ;;
      *) echo "Ungültige Auswahl"; sleep 1 ;;
    esac
  done
}

set_profile_values() {
  case "$PRODUCT-$PROFILE" in
    "ACM-Profile 1")
      CORES=2; RAM=2048; DISK=16; SWAP=512
      ;;
    "ACM-Profile 2")
      CORES=4; RAM=4096; DISK=24; SWAP=1024
      ;;
    "ACM-Profile 3")
      CORES=6; RAM=8192; DISK=32; SWAP=2048
      ;;

    "SMGR-Profile 1")
      CORES=2; RAM=2048; DISK=20; SWAP=512
      ;;
    "SMGR-Profile 2")
      CORES=4; RAM=4096; DISK=32; SWAP=1024
      ;;
    "SMGR-Profile 3")
      CORES=6; RAM=8192; DISK=48; SWAP=2048
      ;;

    "ASM-Profile 1")
      CORES=2; RAM=2048; DISK=16; SWAP=512
      ;;
    "ASM-Profile 2")
      CORES=4; RAM=4096; DISK=24; SWAP=1024
      ;;
    "ASM-Profile 3")
      CORES=6; RAM=6144; DISK=32; SWAP=2048
      ;;

    "SBCE-Profile 1")
      CORES=2; RAM=4096; DISK=20; SWAP=1024
      ;;
    "SBCE-Profile 2")
      CORES=4; RAM=6144; DISK=32; SWAP=2048
      ;;
    "SBCE-Profile 3")
      CORES=6; RAM=8192; DISK=48; SWAP=2048
      ;;

    "Breeze-Profile 1")
      CORES=2; RAM=2048; DISK=16; SWAP=512
      ;;
    "Breeze-Profile 2")
      CORES=4; RAM=4096; DISK=24; SWAP=1024
      ;;
    "Breeze-Profile 3")
      CORES=6; RAM=8192; DISK=32; SWAP=2048
      ;;

    "AADS-Profile 1")
      CORES=2; RAM=2048; DISK=16; SWAP=512
      ;;
    "AADS-Profile 2")
      CORES=4; RAM=4096; DISK=24; SWAP=1024
      ;;
    "AADS-Profile 3")
      CORES=6; RAM=8192; DISK=32; SWAP=2048
      ;;

    "CMS-Profile 1")
      CORES=2; RAM=2048; DISK=16; SWAP=512
      ;;
    "CMS-Profile 2")
      CORES=4; RAM=4096; DISK=24; SWAP=1024
      ;;
    "CMS-Profile 3")
      CORES=6; RAM=8192; DISK=32; SWAP=2048
      ;;
    *)
      echo "Keine Werte für $PRODUCT / $PROFILE gefunden."
      exit 1
      ;;
  esac
}

show_summary() {
  clear
  echo "======================================"
  echo " Auswahlübersicht"
  echo "======================================"
  echo "Produkt       : $PRODUCT"
  echo "Profil        : $PROFILE"
  echo "CPU Cores     : $CORES"
  echo "RAM           : $RAM MB"
  echo "Disk          : $DISK GB"
  echo "Swap          : $SWAP MB"
  echo "Bridge        : $BRIDGE"
  echo "Storage       : $STORAGE"
  echo "Template      : $TEMPLATE"
  echo
}

create_lxc() {
  read -rp "Hostname für den LXC: " HOSTNAME
  read -rp "CT ID leer lassen für auto: " CTID

  if [ -z "$CTID" ]; then
    CTID=$(pvesh get /cluster/nextid)
  fi

  echo
  echo "LXC wird erstellt..."
  echo "CTID: $CTID"
  echo

  pct create "$CTID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$RAM" \
    --swap "$SWAP" \
    --rootfs "$STORAGE:$DISK" \
    --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp,type=veth" \
    --unprivileged "$UNPRIVILEGED" \
    --onboot 1 \
    --start "$START_AFTER_CREATE"

  echo
  echo "LXC $HOSTNAME mit CTID $CTID wurde erstellt."
}

main() {
  choose_product
  choose_profile
  set_profile_values
  show_summary

  read -rp "LXC jetzt erstellen? (j/n): " confirm
  case "$confirm" in
    j|J|y|Y) create_lxc ;;
    *) echo "Abgebrochen." ;;
  esac
}

main
