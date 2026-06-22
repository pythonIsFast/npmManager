# 📦 npm Package Manager

Web-based GUI to manage global npm packages on Windows. No dependencies – just double-click `start.bat`.

## ✨ Features

🌐 **Dark-theme Web GUI** – modern SPA, no CLI knowledge required  
🔍 **Discover** – Browse popular packages live from the npm registry, categorized  
📋 **Installed packages** – View, search & uninstall global packages  
⬆️ **Updates** – Spot outdated packages and update individually or all at once  
🔎 **Live search** – Search the npm registry and install with one click  
🚀 **Auto Node.js install** – Missing Node.js? One click installs it  
🔐 **Auto-admin** – Prompts for admin rights via UAC when needed  
🔌 **Port fallback** – Port 4950 taken? Auto-tries 4951–4998

## 🚀 Getting started

```powershell
.\start.bat
```

Open in your browser: **[http://127.0.0.1:4950](http://127.0.0.1:4950)**

## 📁 Files

| File | Purpose |
|---|---|
| `start.bat` | Launcher |
| `server.ps1` | PowerShell HTTP server |
| `static/index.html` | Frontend |

## 🔧 Requirements

- Windows 7+, PowerShell 5.1+
- Node.js is installed automatically if missing

## 📜 License

GNU General Public License v3
