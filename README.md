# Avaya-Proxmox-Multi-Script

**Modulare Bash-Skripte für den Import von Avaya-Produkten auf Proxmox VE.**

Unterstützt sowohl **KVM-VMs** (OVA → QCOW2 / QCOW2-Direktimport) als auch
**LXC-Container** für Avaya-Dienste. Das Hauptmenü im Stil der
[Proxmox Helper Scripts](https://github.com/tteck/Proxmox) macht die Bedienung
einfach — mit automatischer OVA-Suche, Mirror-Integration und übersichtlichen
whiptail-Dialogen.

---

## 📦 Repository-Struktur

```
Avaya-Proxmox-Multi-Script-/
├── avaya-main.sh           # Hauptmenü — KVM-Import (whiptail)
├── avayascript.sh          # Alternativer LXC-Installer (reines Bash)
├── README.md               # Diese Datei
├── LICENSE                 # MIT-Lizenz
└── scripts/
    ├── avaya-config.sh      # Zentrale Konfiguration (OVA-Mirror, Downloads)
    ├── avaya-acm.sh         # ACM — Aura Communication Manager (OVA → QCOW2)
    └── avaya-sbce-test.sh   # SBCE — Session Border Controller (QCOW2-Import)
```

---

## 🚀 Schnellstart

### KVM-Import (Hauptmenü mit whiptail)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/naix1337/Avaya-Proxmox-Multi-Script-/main/avaya-main.sh)"
```

Zeigt ein Menü mit allen Avaya-Produkten:
- ✅ Implementierte Module sind auswählbar
- ❌ Noch nicht implementierte Module zeigen einen Hinweis
- Fehlende Modul-Skripte werden automatisch von GitHub Raw geladen

### LXC-Installer (alternativ, ohne whiptail)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/naix1337/Avaya-Proxmox-Multi-Script-/main/avayascript.sh)"
```

Reines Bash-Menü — für Umgebungen ohne `whiptail` oder wenn **LXC-Container**
statt KVM-VMs gewünscht sind.

### Lokal (geklontes Repo)

```bash
git clone https://github.com/naix1337/Avaya-Proxmox-Multi-Script-.git
cd Avaya-Proxmox-Multi-Script-
chmod +x avaya-main.sh avayascript.sh scripts/*.sh
./avaya-main.sh          # KVM-Menü
# oder
./avayascript.sh         # LXC-Installer
```

> **Wichtig:** Die Skripte müssen auf einem **Proxmox VE Host** ausgeführt werden
> (`qm`, `pct`, `pvesh` erforderlich).

---

## 📋 Verfügbare Produkte

### KVM-Import (`avaya-main.sh`)

Im Hauptmenü integrierte Module:

| Produkt | Status | Typ | Beschreibung |
|---------|--------|-----|-------------|
| **ACM** | ✅ Implementiert | OVA → QCOW2 | Aura Communication Manager |
| **SBCE** | ✅ Implementiert | QCOW2-Direktimport | Session Border Controller (SBC / Small SBC / EMS) |
| **SMGR** | 🔄 Geplant | OVA → QCOW2 | Session Manager |
| **ASM** | ⏸️ Zurückgestellt | — | Aura System Manager |
| **Breeze** | 🔄 Geplant | OVA → QCOW2 | Breeze |
| **AADS** | 🔄 Geplant | OVA → QCOW2 | AADS |

### LXC-Installer (`avayascript.sh`)

Im LXC-Installer verfügbare Produkte:

| Produkt | Status |
|---------|--------|
| **ACM** | ✅ Verfügbar |
| **SMGR** | ✅ Verfügbar |
| **ASM** | ✅ Verfügbar |
| **SBCE** | ✅ Verfügbar |
| **Breeze** | ✅ Verfügbar |
| **AADS** | ✅ Verfügbar |
| **CMS** | ✅ Verfügbar |

---

## ⚙️ OVA-Mirror & Konfiguration

Die zentrale Konfigurationsdatei `scripts/avaya-config.sh` stellt den OVA-Mirror
und Download-Funktionen bereit:

| Variable | Standard | Beschreibung |
|----------|----------|-------------|
| `OVA_MIRROR_BASE` | `https://ova.insolution.cloud` | Basis-URL für Image-Downloads |

### Mirror überschreiben

```bash
export OVA_MIRROR_BASE="https://dein-eigener-mirror.example.com"
./avaya-main.sh
```

### Automatische Suchpfade

Die Module durchsuchen automatisch folgende Quellen:

1. **Lokale Verzeichnisse** — `/root/`, `/var/lib/vz/template/iso/`, `$(pwd)`
2. **OVA-Mirror** — via `OVA_MIRROR_BASE` herunterladen
3. **Eigene URL** — manuelle Eingabe möglich

### Verfügbare Funktionen

```bash
# Image von Mirror laden
download_ova "datei.ova" "/ziel/verzeichnis/"

# Existiert die Datei bereits? → Dialog mit Überschreiben-Option
```

---

## 🖥️ SBCE — Session Border Controller for Enterprise

### Profile

| Variante | Cores | RAM | Disk | NICs |
|----------|-------|-----|------|------|
| **SBC** | 4 | 8.192 MB | 64 GB | 6 |
| **Small SBC** | 2 | 4.096 MB | 64 GB | 4 |
| **EMS** | 3 | 8.192 MB | 64 GB | 2 |

### Ablauf

1. **Variante wählen** — SBC, Small SBC oder EMS
2. **VM-Parameter festlegen** — VM-ID, Name, Storage, Bridge, VLAN
3. **Image-Quelle angeben** — lokale QCOW2-Datei, Download-URL oder Mirror
4. **VM-Import** — `qm create` → `qm importdisk` → scsi0 anbinden
5. **Netzwerkkarten** automatisch nach Profil (E1000 / VirtIO)
6. **BIOS OVMF (UEFI)** — EFI-Disk wird angelegt
7. **Fertig** — VM kann gestartet werden

### Standard-Einstellungen

| Parameter | Wert |
|-----------|------|
| CPU-Typ | `host` |
| BIOS | `ovmf` (UEFI) |
| SCSI-Controller | `virtio-scsi-pci` |
| Maschinentyp | `q35` |
| Netzwerkmodell | `e1000` (konfigurierbar) |
| Cache | `directsync` |
| Boot-Reihenfolge | `scsi0` zuerst |

### OVA-Mirror Integration

```bash
# Konfigurierte Standard-URL (überschreibbar per Umgebungsvariable)
# Der Mirror-Pfad für SBCE wird aus OVA_MIRROR_BASE abgeleitet:
#   ${OVA_MIRROR_BASE}/sbce/
```

---

## 🖥️ ACM — Aura Communication Manager

| Eigenschaft | Wert |
|------------|------|
| **Typ** | OVA → VMDK → QCOW2-Import |
| **Variante** | CM Duplex 010.2.0.0.229-KVM-2 |
| **Automatische Suche** | Lokale Verzeichnisse + Mirror |
| **Standard-Mirror** | `https://ova.insolution.cloud/acm/` |

### Ablauf

1. **OVA-Quelle wählen** — lokale `.ova`-Datei, Download vom Mirror, eigene URL
2. **VM-Parameter festlegen** — VM-ID, Name, Storage, Bridge, VLAN
3. **OVA entpacken** — `tar xvf` → VMDK extrahieren
4. **VMDK konvertieren** → QCOW2
5. **VM erzeugen** — `qm create` → `qm importdisk` → scsi0 anbinden
6. **Netzwerkkonfiguration** + UEFI (OVMF)
7. **Fertig** — VM kann gestartet werden

---

## 📤 Exit-Codes

### Tabelle

| Code | Name | Bedeutung |
|------|------|-----------|
| **0** | `OK` | Erfolgreich ausgeführt |
| **1** | `ERROR` | Allgemeiner Fehler (`qm`, `wget`, `tar`, `curl`, …) |
| **2** | `USER_ABORT` | Abbruch durch Benutzer (ESC / Cancel) |
| **127** | — | Befehl nicht gefunden (bash <4, fehlende Tools) |
| **255** | — | whiptail-Fehler (falsche Argumente, abgeschnittenes Script) |

### Häufige Fehler

| Symptom | Ursache | Fix |
|---------|---------|-----|
| `qm importdisk` schlägt fehl | Storage unterstützt keine VM-Images (z. B. "Backup") | `pvesh get /storage/NAME` prüfen → Content-Type muss `images` enthalten |
| `qm importdisk` schlägt fehl (2) | Speicherplatz voll | `df -h` prüfen, Speicher freigeben |
| `qm importdisk` schlägt fehl (3) | QCOW2-Datei defekt | `qemu-img check DATEI` |
| `tar`-Fehler beim OVA-Entpacken | Platte voll oder OVA korrupt | `sha256sum` prüfen, Speicher freigeben |
| `net0.model: value 'none'` | Alte `--net0 none`-Syntax | Seit Commit `b27f857` gefixt |
| `unused disk not found` | Import fehlgeschlagen | `qm config VMID` prüfen |

---

## 🔧 Entwicklung

### Neues KVM-Modul hinzufügen

1. Script unter `scripts/avaya-<produkt>.sh` anlegen
2. Im Hauptscript `MODULES`-Array erweitern:

   ```bash
   MODULES=(
       # ...
       "Produktname|avaya-produkt.sh|yes"    # "yes" = aktiv, "no" = Hinweis
   )
   ```

### Modul-Richtlinien

Jedes Modul sollte:
- Eigenständig lauffähig sein (`set -euo pipefail`)
- Mit whiptail-Dialogen arbeiten
- Einheitliche QEMU-Standards verwenden (OVMF, VirtIO SCSI, `host` CPU)
- Import über `qm importdisk` realisieren
- Fehlerbehandlung mit sinnvollen Exit-Codes
- Einen Eintrag in der Exit-Code-Tabelle haben

### Neues Produkt im OVA-Mirror

```bash
# Mirrors Struktur:
#   https://ova.insolution.cloud/<produkt>/<datei>
#
# Im Modul-Script die Standard-URL setzen:
OVA_DEFAULT_DOWNLOAD_URL="${OVA_MIRROR_BASE:-https://ova.insolution.cloud}/<produkt>/<datei>"
```

---

## ☁️ OVA-Mirror selbst hosten

Eigenen Mirror betreiben (z. B. TrueNAS, einfacher Webserver, S3-Bucket):

```bash
export OVA_MIRROR_BASE="https://dein-mirror.example.com"
./avaya-main.sh
```

**Empfohlene Verzeichnisstruktur:**

```
<mirror-root>/
├── acm/
│   └── CM-Duplex-010.2.0.0.229-KVM-2.ova
└── sbce/
    └── <sbce-image>.qcow2
```

---

## ⚠️ Wichtige Hinweise

- **Avaya-Images** (QCOW2, OVA) müssen separat bezogen werden — die
  Lizenzbedingungen von Avaya bleiben hiervon unberührt.
- Download-URLs variieren je nach Lizenzvertrag und Avaya-PLDS-Generierung.
- Dieses Projekt ist **nicht-affiliiert** mit Avaya Inc. oder
  Proxmox Server Solutions GmbH.

---

## 📄 Lizenz

MIT — siehe [LICENSE](./LICENSE).

---

*Made with ☕ + 🐧 on Proxmox.*
