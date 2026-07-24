# Avaya-Proxmox-Multi-Script

Modulares Bash-Projekt für den Import von Avaya KVM-Images auf **Proxmox VE**.
Das Hauptscript bietet ein **whiptail**-basiertes Menü 
## Repository-Struktur

```
Avaya-Proxmox-Multi-Script-/
├── avaya-main.sh          # Hauptscript — whiptail-Menü, Einstiegspunkt
├── README.md              # Diese Datei
└── scripts/
    ├── avaya-sbce-test.sh # SBCE (Session Border Controller for Enterprise)
    ├── avaya-acm.sh       # ACM (Aura Communication Manager) — Demo/Test
    ├── avaya-smgr.sh      # SMGR (Session Manager) — in Entwicklung
    ├── avaya-asm.sh       # ASM (Aura System Manager) — zurückgestellt
    ├── avaya-breeze.sh    # Breeze — in Entwicklung
    └── avaya-aads.sh      # AADS — in Entwicklung
```

## Verfügbare Produkte

| Produkt | Status | Typ | Basis |
|---------|--------|-----|-------|
| **SBCE** | ✅ Implementiert | QCOW2-Import | SBC / Small SBC / EMS |
| **ACM** | ✅ Implementiert | OVA → QCOW2 | Aura Communication Manager |
| **SMGR** | 🔄 In Entwicklung | OVA → QCOW2 | Session Manager |
| **ASM** | ⏸️ Zurückgestellt | — | Aura System Manager |
| **Breeze** | 🔄 In Entwicklung | OVA → QCOW2 | Breeze |
| **AADS** | 🔄 In Entwicklung | OVA → QCOW2 | AADS |

## One-Liner (Schnellstart)

Das Hauptscript kann direkt von GitHub gestartet werden:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/naix1337/Avaya-Proxmox-Multi-Script-/main/avaya-main.sh)"
```

**Ablauf:**
1. Das Hauptscript zeigt ein Menü mit allen Avaya-Produkten
2. Nur implementierte Module (SBCE, ACM) sind aktiv
3. Nicht implementierte Module zeigen einen Hinweis
4. Fehlende Modul-Skripte werden automatisch von GitHub Raw geladen

> **Hinweis:** Das Skript muss auf einem **Proxmox VE Host** ausgeführt werden, da es `qm create` und `qm importdisk` verwendet.

## Lokale Nutzung (geklontes Repo)

```bash
git clone https://github.com/naix1337/Avaya-Proxmox-Multi-Script-.git
cd Avaya-Proxmox-Multi-Script-
chmod +x avaya-main.sh scripts/*.sh
./avaya-main.sh
```

Oder ein bestimmtes Modul direkt starten:

```bash
bash scripts/avaya-sbce-test.sh     # SBCE
bash scripts/avaya-acm.sh           # ACM
```

## Systemvoraussetzungen

- **Proxmox VE 7.x oder 8.x** (getestet)
- **whiptail** (im Proxmox-Standard enthalten)
- **curl, wget** (für Downloads)
- Ausreichend Speicherplatz für Images

## SBCE-Modul im Detail

### Profile

| Variante | Cores | RAM | Disk | NICs |
|----------|-------|-----|------|------|
| **SBC** | 4 | 8.192 MB | 64 GB | 6 |
| **Small SBC** | 2 | 4.096 MB | 64 GB | 4 |
| **EMS** | 3 | 8.192 MB | 64 GB | 2 |

### Ablauf

1. **Variante wählen** — SBC, Small SBC oder EMS
2. **VM-Parameter festlegen** — VM-ID, Name, Storage, Bridge, VLAN
3. **QCOW2-Quelle angeben** — lokale Datei oder Download-URL
4. **VM-Import** — `qm create` → `qm importdisk` → scsi0 einbinden
5. **Netzwerkkarten** — automatisch je nach Profil (E1000 oder VirtIO)
6. **BIOS OVMF (UEFI)** — EFI-Disk wird angelegt
7. **Fertig** — VM kann gestartet werden

### Einstellungen (Standard)

| Parameter | Wert |
|-----------|------|
| CPU-Typ | `host` |
| BIOS | `ovmf` (UEFI) |
| SCSI-Controller | `virtio-scsi-pci` |
| Maschinentyp | `q35` |
| Netzwerkmodell | `e1000` (Intel, konfigurierbar) |
| Cache | `directsync` |
| Boot-Reihenfolge | `scsi0` zuerst |

## Hinweise zu den Avaya-Lizenzdateien

- Die eigentlichen Avaya-Images (QCOW2, OVA) müssen separat bezogen werden
- Die Download-URL kann je nach Lizenzvertrag variieren
- Für SBCE: der Downloadlink wird im **Avaya PLDS** generiert
- Dieses Skript automatisiert nur den Import — die Lizenzbedingungen von Avaya bleiben hiervon unberührt

## Exit-Code-Tabelle

| Code | Name | Bedeutung |
|------|------|----------|
| **0** | `OK` | Erfolgreich ausgeführt |
| **1** | `ERROR` | Allgemeiner Fehler — `qm`, `wget`, `tar`, `curl` etc. sind fehlgeschlagen |
| **2** | `USER_ABORT` | Abbruch durch Benutzer (ESC / Cancel in whiptail) |
| **127** | — | Befehl nicht gefunden — z. B. `declare -A` (bash <4), fehlende Tools |
| **255** | — | whiptail-Fehler — falsche Argumente oder abgeschnittenes Script |

### Fehlerursachen (Exit-Code 1)

| Symptom | Häufige Ursache | Fix |
|---------|----------------|-----|
| `qm importdisk` schlägt fehl | Storage unterstützt keine VM-Images (z.B. "Backup") | `pvesh get /storage/NAME` → Content-Type muss `images` enthalten |
| `qm importdisk` schlägt fehl (2) | Speicherplatz voll | `df -h` prüfen, Speicher freigeben |
| `qm importdisk` schlägt fehl (3) | QCOW2-Datei defekt | `qemu-img check DATEI` |
| `tar`-Fehler beim OVA-Entpacken | Platte voll | OVA in `/var/lib/vz/template/iso/` verschieben |
| `net0.model: value 'none'` | `--net0 none` (alte Syntax) nicht mehr gültig | Seit Commit b27f857 gefixt |
| `unused disk not found` | Import fehlgeschlagen, keine Disk in Config | `qm config VMID` prüfen |

## Entwicklung

### Neues Modul hinzufügen

1. Script in `scripts/avaya-<produkt>.sh` anlegen
2. Im Hauptscript `MODULES`-Array erweitern:
   ```bash
   MODULES=(
       # ...
       "Produktname|avaya-produkt.sh|no"    # "yes" wenn implementiert
   )
   ```

### Moduleigenschaften

Jedes Modul-Script sollte:
- Eigenständig lauffähig sein (`set -euo pipefail`)
- Mit whiptail arbeiten
- Die gleichen QEMU-Standards verwenden (OVMF, VirtIO SCSI, host CPU)
- Den Import über `qm importdisk` realisieren
- Fehlerbehandlung enthalten

## Lizenz

MIT — siehe [LICENSE](./LICENSE).

---

*Dieses Projekt ist nicht-affiliiert mit Avaya Inc. oder Proxmox Server Solutions GmbH.*
