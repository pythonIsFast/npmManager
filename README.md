# 📦 npm Package Manager

Web-GUI zum Verwalten globaler npm-Pakete unter Windows. Keine Abhängigkeiten – nur Doppelklick auf `start.bat`.

## ✨ Features

🌐 **Dark-Theme Web-GUI** – modernes SPA, kein CLI-Wissen nötig  
🔍 **Entdecken** – Beliebte Pakete live aus der npm Registry, kategorisiert  
📋 **Installierte Pakete** – Anzeigen, suchen & deinstallieren  
⬆️ **Updates** – Veraltete Pakete erkennen & einzeln oder alle aktualisieren  
🔎 **Live-Suche** – npm Registry durchsuchen & mit einem Klick installieren  
🚀 **Node.js Auto-Install** – Fehlt Node.js? Ein Klick installiert es  
🔐 **Auto-Admin** – Fordert bei Bedarf Admin-Rechte per UAC an  
🔌 **Port-Fallback** – Port 4950 belegt? Automatisch 4951–4998

## 🚀 Start

```powershell
.\start.bat
```

Dann im Browser öffnen: **[http://127.0.0.1:4950](http://127.0.0.1:4950)**

## 📁 Dateien

| Datei | Zweck |
|---|---|
| `start.bat` | Launcher |
| `server.ps1` | PowerShell HTTP Server |
| `static/index.html` | Frontend |

## 🔧 Systemvoraussetzungen

- Windows 7+, PowerShell 5.1+
- Node.js wird bei Bedarf automatisch installiert

## 📜 Lizenz

GNU General Public License v3
