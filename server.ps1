[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$port = 4950
$statusFile = "$env:TEMP\npm_manager_install.json"

# Admin-Prüfung – falls nicht Admin, mit UAC neu starten
$isAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[!] Starte als Administrator neu (UAC)..."
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$conn = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
if ($conn -and $conn.OwningProcess) {
    $oldProcess = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    if ($oldProcess) {
        Write-Host "Alten Prozess auf Port $port beenden (PID $($oldProcess.Id))..."
        $oldProcess.Kill()
        Start-Sleep -Seconds 1
    }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:${port}/")
try {
    $listener.Start()
} catch {
    Write-Host "[FEHLER] Port $port blockiert. Suche Ausweich-Port..."
    for ($p = 4951; $p -lt 4999; $p++) {
        try {
            $listener = New-Object System.Net.HttpListener
            $listener.Prefixes.Add("http://127.0.0.1:${p}/")
            $listener.Start()
            $port = $p
            break
        } catch {}
    }
    if (-not $listener.IsListening) { Write-Host "[FEHLER] Kein freier Port."; exit 1 }
}
$hostName = "http://127.0.0.1:${port}"
Write-Host "Server gestartet unter ${hostName}"
Write-Host "Druecke Strg+C zum Beenden."

$staticDir = Join-Path $PSScriptRoot "static"

function Send-Json {
    param($context, $data, $status = 200)
    $json = $data | ConvertTo-Json -Compress -Depth 5
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $context.Response.StatusCode = $status
    $context.Response.ContentType = "application/json; charset=utf-8"
    $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $context.Response.OutputStream.Close()
}

function Send-Error {
    param($context, $msg, $status = 400)
    Send-Json $context @{ detail = $msg } $status
}

function Send-File {
    param($context, $path)
    if (-not (Test-Path $path)) { Send-Error $context "Datei nicht gefunden" 404; return }
    $ext = [System.IO.Path]::GetExtension($path)
    $mime = @{
        ".html" = "text/html; charset=utf-8"
        ".css"  = "text/css; charset=utf-8"
        ".js"   = "application/javascript; charset=utf-8"
        ".svg"  = "image/svg+xml"
        ".png"  = "image/png"
        ".ico"  = "image/x-icon"
    }
    $contentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { "application/octet-stream" }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $context.Response.ContentType = $contentType
    $context.Response.StatusCode = 200
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.OutputStream.Close()
}

function Read-Body {
    param($context)
    $reader = New-Object System.IO.StreamReader($context.Request.InputStream)
    $body = $reader.ReadToEnd()
    $reader.Close()
    return $body | ConvertFrom-Json
}

function Invoke-Npm {
    param([string]$cmd)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c npm $cmd 2>&1"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $output = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    return @{ exitCode = $p.ExitCode; output = $output.Trim() }
}

function Clean-NpmOutput {
    param($text)
    $lines = $text -split "`n" | Where-Object { $_ -notmatch "^(npm (ERR|WARN|notice|info)|$)" }
    return ($lines -join "`n").Trim()
}

function Get-Packages {
    $result = Invoke-Npm "list -g --json --depth=0"
    if ([string]::IsNullOrWhiteSpace($result.output)) { return @() }
    $clean = Clean-NpmOutput $result.output
    if ([string]::IsNullOrWhiteSpace($clean)) { return @() }
    try { $data = $clean | ConvertFrom-Json } catch { return @() }
    $pkgs = @()
    if ($data.dependencies) {
        $data.dependencies.PSObject.Properties | ForEach-Object {
            if ($_.Name -notmatch '^\.') {
                $pkgs += @{
                    name    = $_.Name
                    version = if ($_.Value.version) { $_.Value.version } else { "unbekannt" }
                    missing = if ($_.Value.missing) { $true } else { $false }
                }
            }
        }
    }
    return ($pkgs | Sort-Object { $_['name'] })
}

function Get-Outdated {
    $result = Invoke-Npm "outdated -g --json"
    if ([string]::IsNullOrWhiteSpace($result.output)) { return @() }
    $clean = Clean-NpmOutput $result.output
    if ([string]::IsNullOrWhiteSpace($clean)) { return @() }
    try { $data = $clean | ConvertFrom-Json } catch { return @() }
    $pkgs = @()
    $data.PSObject.Properties | ForEach-Object {
        if ($_.Name -notmatch '^\.') {
            $pkgs += @{ name = $_.Name; current = $_.Value.current; wanted = $_.Value.wanted; latest = $_.Value.latest }
        }
    }
    return ($pkgs | Sort-Object { $_['name'] })
}

function Search-Registry {
    param($query)
    $url = "https://registry.npmjs.org/-/v1/search?text=$([System.Uri]::EscapeDataString($query))&size=20"
    try { $data = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 10 } catch { return @() }
    $results = @()
    if ($data.objects) {
        $data.objects | ForEach-Object {
            $results += @{
                name        = $_.package.name
                version     = $_.package.version
                description = if ($_.package.description) { $_.package.description } else { "" }
                publisher   = if ($_.package.publisher.username) { $_.package.publisher.username } else { "" }
            }
        }
    }
    return $results
}

function Get-Discover {
    # Mehrere Kategorien parallel abfragen
    $categories = @(
        @{ name = "Beliebt"; query = "popularity:1.0.0 boost-exact:false" },
        @{ name = "CLI-Tools"; query = "keywords:cli" },
        @{ name = "Framework"; query = "keywords:framework" },
        @{ name = "Dev-Tools"; query = "keywords:bundler,keywords:build" },
        @{ name = "Node.js"; query = "keywords:node.js" }
    )
    $sections = @()
    foreach ($cat in $categories) {
        $url = "https://registry.npmjs.org/-/v1/search?text=$([System.Uri]::EscapeDataString($cat.query))&size=8"
        try {
            $data = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 8
            $pkgs = @()
            if ($data.objects) {
                $data.objects | ForEach-Object {
                    $pkgs += @{
                        name        = $_.package.name
                        version     = $_.package.version
                        description = if ($_.package.description) { $_.package.description } else { "" }
                        publisher   = if ($_.package.publisher.username) { $_.package.publisher.username } else { "" }
                    }
                }
            }
            $sections += @{ title = $cat.name; packages = $pkgs }
        } catch {}
    }
    return $sections
}

function Write-InstallStatus {
    param($status, $progress, $message)
    $data = @{ status = $status; progress = $progress; message = $message } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($statusFile, $data)
}

function Start-NodeInstall {
    param($sf)
    function Write-St {
        param($s, $p, $m)
        [System.IO.File]::WriteAllText($sf, (@{ status = $s; progress = $p; message = $m } | ConvertTo-Json -Compress))
    }
    Write-St "downloading" 5 "Lade Node.js v22.12.0 herunter..."
    $url = "https://nodejs.org/dist/v22.12.0/node-v22.12.0-x64.msi"
    $msi = "$env:TEMP\node_install.msi"
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($url, $msi)
    } catch {
        Write-St "failed" 0 "Download fehlgeschlagen: $_"
        return
    }
    Write-St "installing" 40 "Installiere Node.js (dies kann einige Minuten dauern)..."
    $proc = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        Write-St "failed" 0 "Installation fehlgeschlagen (Code $($proc.ExitCode))."
        return
    }
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        Write-St "failed" 0 "Node.js-Installation fehlgeschlagen (Code $($proc.ExitCode)). Log: $env:TEMP\node_msi.log"
        return
    }
    Write-St "validating" 90 "Installation abgeschlossen. Aktualisiere Umgebungsvariablen..."
    # Pfad aktualisieren
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    "Path aktualisiert. node --version: $(node --version 2>`$null)" | Out-File $logFile -Append
    Write-St "done" 100 "Node.js wurde erfolgreich installiert!"
}

while ($listener.IsListening) {
    $task = $listener.GetContextAsync()
    $context = $task.GetAwaiter().GetResult()
    $request = $context.Request
    $response = $context.Response
    $method = $request.HttpMethod
    $path = $request.Url.AbsolutePath

    try {
        if ($path -eq "/") {
            Send-File $context (Join-Path $staticDir "index.html")
            continue
        }
        if ($path -match "^/static/(.+)$") {
            $file = $matches[1] -replace "\.\.", "" -replace "[\\/]", "\"
            Send-File $context (Join-Path $staticDir $file)
            continue
        }

        # === STATUS ===
        if ($method -eq "GET" -and $path -eq "/api/status") {
            # Zuerst per where prüfen ob node im PATH, dann exit code checken
            $whereNode = cmd.exe /c "where node >nul 2>&1" 2>$null; $ecNode = $LASTEXITCODE
            $whereNpm  = cmd.exe /c "where npm >nul 2>&1" 2>$null; $ecNpm  = $LASTEXITCODE
            # Fallback: Standardpfade testen falls nicht im PATH
            if ($ecNode -ne 0) {
                foreach ($p in @("$env:ProgramFiles\nodejs\node.exe", "${env:ProgramFiles(x86)}\nodejs\node.exe", "$env:LOCALAPPDATA\node\node.exe")) {
                    if (Test-Path $p) { $env:Path = "$([System.IO.Path]::GetDirectoryName($p));$env:Path"; $ecNode = 0; break }
                }
                if ($ecNode -eq 0) {
                    $null = cmd.exe /c "where npm >nul 2>&1" 2>$null; $ecNpm = $LASTEXITCODE
                }
            }
            $hasNode = $ecNode -eq 0
            $hasNpm  = $ecNpm -eq 0
            $nodeVer = if ($hasNode) { (cmd.exe /c "node --version 2>&1" 2>$null).Trim() } else { "" }
            $npmVer  = if ($hasNpm)  { (cmd.exe /c "npm --version 2>&1" 2>$null).Trim() } else { "" }
            Send-Json $context @{ npm = $hasNpm; node = $hasNode; nodeVersion = $nodeVer; npmVersion = $npmVer }
            continue
        }

        # === DEBUG ===
        if ($method -eq "GET" -and $path -eq "/api/debug") {
            $whereNode = cmd.exe /c "where node 2>nul" 2>$null
            $whereNpm  = cmd.exe /c "where npm 2>nul" 2>$null
            $allPath = $env:Path -split ";"
            $debug = @{
                admin = [Security.Principal.WindowsPrincipal]::new(
                    [Security.Principal.WindowsIdentity]::GetCurrent()
                ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                whereNode = ($whereNode -split "`n").Trim()
                whereNpm  = ($whereNpm -split "`n").Trim()
                pathNode = ($allPath | Where-Object { $_ -match "node|npm" }) -join "; "
                pathCount = $allPath.Length
                checks = @()
            }
            foreach ($p in @("$env:ProgramFiles\nodejs\node.exe", "${env:ProgramFiles(x86)}\nodejs\node.exe", "$env:LOCALAPPDATA\node\node.exe",
                "$env:ProgramFiles\nodejs\npm.cmd", "${env:ProgramFiles(x86)}\nodejs\npm.cmd", "$env:LOCALAPPDATA\npm\npm.cmd")) {
                $debug.checks += @{ path = $p; exists = (Test-Path $p) }
            }
            Send-Json $context $debug
            continue
        }

        # === NODE.JS INSTALL ===
        if ($method -eq "POST" -and $path -eq "/api/install-nodejs") {
            # Prüfen ob npm inzwischen da ist (PATH wurde evtl. repariert)
            $hasNpm = !!(Get-Command npm -ErrorAction SilentlyContinue) -or (Test-Path "C:\Program Files\nodejs\npm.cmd")
            if ($hasNpm) {
                Send-Json $context @{ status = "done"; progress = 100; message = "Node.js ist bereits installiert." }
                continue
            }
            if (Test-Path $statusFile) { Remove-Item $statusFile -Force }
            $data = @{ status = "idle"; progress = 0; message = "" } | ConvertTo-Json -Compress
            [System.IO.File]::WriteAllText($statusFile, $data)
            Start-Job -ScriptBlock ${function:Start-NodeInstall} -ArgumentList $statusFile | Out-Null
            Send-Json $context @{ started = $true }
            continue
        }

        # === INSTALL STATUS ===
        if ($method -eq "GET" -and $path -eq "/api/install-status") {
            $st = @{ status = "idle"; progress = 0; message = "" }
            if (Test-Path $statusFile) {
                try { $st = Get-Content $statusFile -Raw | ConvertFrom-Json } catch {}
            }
            Send-Json $context @{ status = "$($st.status)"; progress = [int]$st.progress; message = "$($st.message)" }
            continue
        }

        # === DISCOVER ===
        if ($method -eq "GET" -and $path -eq "/api/discover") {
            Send-Json $context @{ sections = @(Get-Discover) }
            continue
        }

        # === PAKETE ===
        if ($method -eq "GET" -and $path -eq "/api/packages") {
            Send-Json $context @{ packages = @(Get-Packages) }
            continue
        }

        if ($method -eq "GET" -and $path -eq "/api/outdated") {
            Send-Json $context @{ packages = @(Get-Outdated) }
            continue
        }

        if ($method -eq "GET" -and $path -eq "/api/search") {
            $query = $request.QueryString["q"]
            if ([string]::IsNullOrWhiteSpace($query)) { Send-Json $context @{ results = @() }; continue }
            Send-Json $context @{ results = @(Search-Registry $query) }
            continue
        }

        if ($method -eq "POST" -and $path -eq "/api/packages/install") {
            $body = Read-Body $context
            $name = "$($body.name)"
            if ([string]::IsNullOrWhiteSpace($name)) { Send-Error $context "Paketname fehlt"; continue }
            $result = Invoke-Npm "install -g $name"
            if ($result.exitCode -ne 0) { Send-Error $context $result.output; continue }
            Send-Json $context @{ success = $true; output = $result.output; package = $name }
            continue
        }

        if ($method -eq "POST" -and $path -eq "/api/packages/uninstall") {
            $body = Read-Body $context
            $name = "$($body.name)"
            if ([string]::IsNullOrWhiteSpace($name)) { Send-Error $context "Paketname fehlt"; continue }
            $result = Invoke-Npm "uninstall -g $name"
            if ($result.exitCode -ne 0) { Send-Error $context $result.output; continue }
            Send-Json $context @{ success = $true; output = $result.output; package = $name }
            continue
        }

        if ($method -eq "POST" -and $path -eq "/api/packages/update") {
            $body = Read-Body $context
            $name = "$($body.name)"
            if ([string]::IsNullOrWhiteSpace($name)) { Send-Error $context "Paketname fehlt"; continue }
            $result = Invoke-Npm "update -g $name"
            if ($result.exitCode -ne 0) { Send-Error $context $result.output; continue }
            Send-Json $context @{ success = $true; output = $result.output; package = $name }
            continue
        }

        if ($method -eq "POST" -and $path -eq "/api/packages/update-all") {
            $result = Invoke-Npm "update -g"
            if ($result.exitCode -ne 0) { Send-Error $context $result.output; continue }
            Send-Json $context @{ success = $true; output = $result.output; package = "(all)" }
            continue
        }

        Send-Error $context "Route nicht gefunden" 404
    }
    catch {
        Send-Error $context $_.Exception.Message 500
    }
}

$listener.Stop()
