#Requires -Version 5.1
# WalhallaUnfollowTracker - TwitchUnfollowTracker.ps1
# PS 5.1 kompatibel - KEIN PS7 Syntax!

$ErrorActionPreference = 'Stop'

$PluginId      = 'odin23x.twitch_unfollow_tracker_clean'
$PluginDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir       = Join-Path $PluginDir 'data'
$FollowersFile = Join-Path $DataDir 'followers.tsv'
$EventsFile    = Join-Path $DataDir 'events.tsv'
$LogFile       = Join-Path $DataDir 'tracker.log'
$TPHost        = '127.0.0.1'
$TPPort        = 12136
$LogMaxLines   = 400
$EventKeepDays = 30

# Sicherstellen, dass Data-Ordner existiert
if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
}

$script:Settings = @{
    'Twitch Client ID'         = ''
    'Twitch User Access Token' = ''
    'Broadcaster Login'        = ''
    'Check Interval Seconds'   = '300'
}
$script:TcpClient         = $null
$script:Writer            = $null
$script:Reader            = $null
$script:ForceRefresh      = $false
$script:ResetRequested    = $false
$script:LastCheckUtc      = [datetime]::MinValue
$script:ResolvedId        = ''
$script:ResolvedLogin     = ''

# ==============================================================================
# TCP / TP Kommunikation
# ==============================================================================

function Send-TP {
    param([hashtable]$Payload)
    if ($null -eq $script:Writer) { return }
    try {
        $json = $Payload | ConvertTo-Json -Compress -Depth 10
        $script:Writer.WriteLine($json)
        $script:Writer.Flush()
    } catch {}
}

function Set-State {
    param([string]$Id, [string]$Value)
    Send-TP @{ type = 'stateUpdate'; id = $Id; value = [string]$Value }
}

# ==============================================================================
# Logging mit Rotation
# ==============================================================================

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f ([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')), $Message
    try {
        if (Test-Path $LogFile) {
            $existing = @(Get-Content -Path $LogFile -Encoding UTF8 -ErrorAction SilentlyContinue)
            if ($existing.Count -ge $LogMaxLines) {
                $startIndex = $existing.Count - ($LogMaxLines - 50)
                if ($startIndex -lt 0) { $startIndex = 0 }
                $trimmed = $existing[$startIndex..($existing.Count - 1)]
                Set-Content -Path $LogFile -Value $trimmed -Encoding UTF8
            }
        }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {}
    try { Set-State ('{0}.state.last_debug' -f $PluginId) $Message } catch {}
}

# ==============================================================================
# Settings parsen
# ==============================================================================

function Parse-SettingsArray {
    param($Values)
    foreach ($item in $Values) {
        foreach ($prop in $item.PSObject.Properties) {
            $script:Settings[$prop.Name] = [string]$prop.Value
        }
    }
}

# ==============================================================================
# TSV Hilfsfunktionen
# ==============================================================================

function Escape-Field {
    param([string]$s)
    if ($null -eq $s) { return '' }
    return (($s -replace "`t", ' ') -replace "`r", ' ') -replace "`n", ' '
}

function Get-Prop {
    param($Obj, [string]$Key)
    if ($null -eq $Obj) { return '' }
    if ($Obj -is [hashtable]) {
        if ($Obj.ContainsKey($Key)) { return [string]$Obj[$Key] }
        return ''
    }
    try {
        $p = $Obj.PSObject.Properties[$Key]
        if ($null -ne $p) { return [string]$p.Value }
    } catch {}
    return ''
}

# Atomares Schreiben: .tmp -> umbenennen -> sicher!
function Write-AtomicFile {
    param([string]$Path, [System.Collections.Generic.List[string]]$Lines)
    $tmp = $Path + '.tmp'
    try {
        if ($null -eq $Lines -or $Lines.Count -eq 0) {
            Set-Content -Path $tmp -Value @() -Encoding UTF8
        } else {
            Set-Content -Path $tmp -Value $Lines.ToArray() -Encoding UTF8
        }
        if (Test-Path $Path) { Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue }
        Rename-Item -Path $tmp -NewName (Split-Path -Leaf $Path) -Force
    } catch {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}

# ==============================================================================
# Followers-Datenbank (TSV)
# Spalten: user_id | user_login | user_name | followed_at | last_seen_at
# ==============================================================================

function Load-Followers {
    $map = @{}
    if (-not (Test-Path $FollowersFile)) { return $map }
    foreach ($line in @(Get-Content -Path $FollowersFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $p = $line -split "`t", 5
        if ($p.Count -lt 5) { continue }
        $uid = [string]$p[0]
        if ([string]::IsNullOrWhiteSpace($uid)) { continue }
        $map[$uid] = @{
            user_id      = $uid
            user_login   = [string]$p[1]
            user_name    = [string]$p[2]
            followed_at  = [string]$p[3]
            last_seen_at = [string]$p[4]
        }
    }
    return $map
}

function Save-Followers {
    param([hashtable]$Followers)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($e in $Followers.GetEnumerator()) {
        $f   = $e.Value
        $uid = Get-Prop $f 'user_id'
        if ([string]::IsNullOrWhiteSpace($uid)) { continue }
        $lines.Add(('{0}`t{1}`t{2}`t{3}`t{4}' -f `
            (Escape-Field $uid), `
            (Escape-Field (Get-Prop $f 'user_login')), `
            (Escape-Field (Get-Prop $f 'user_name')), `
            (Escape-Field (Get-Prop $f 'followed_at')), `
            (Escape-Field (Get-Prop $f 'last_seen_at'))))
    }
    Write-AtomicFile -Path $FollowersFile -Lines $lines
}

# ==============================================================================
# Events-Datenbank (TSV) - 30-Tage-Rollend
# Spalten: user_id | login | name | time_utc | time_local | status
# status: "unfollow" | "refollowed:<ISO8601>"
# ==============================================================================

function Load-Events {
    $events = New-Object System.Collections.ArrayList
    $seen   = @{}
    if (-not (Test-Path $EventsFile)) { return , @($events) }
    foreach ($line in @(Get-Content -Path $EventsFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $p = $line -split "`t", 6
        if ($p.Count -lt 5) { continue }
        $uid = [string]$p[0]
        $utc = [string]$p[3]
        if ([string]::IsNullOrWhiteSpace($uid) -or [string]::IsNullOrWhiteSpace($utc)) { continue }
        $key = "$uid|$utc"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $status = ''
        if ($p.Count -ge 6) { $status = [string]$p[5] }
        if ([string]::IsNullOrWhiteSpace($status)) { $status = 'unfollow' }
        [void]$events.Add([pscustomobject]@{
            user_id    = $uid
            login      = [string]$p[1]
            name       = [string]$p[2]
            time_utc   = $utc
            time_local = [string]$p[4]
            status     = $status
        })
    }
    return , @($events)
}

function Save-Events {
    param($Events)
    $lines = New-Object System.Collections.Generic.List[string]
    $seen  = @{}
    foreach ($e in @($Events)) {
        $uid = Get-Prop $e 'user_id'
        $utc = Get-Prop $e 'time_utc'
        if ([string]::IsNullOrWhiteSpace($uid) -or [string]::IsNullOrWhiteSpace($utc)) { continue }
        $key = "$uid|$utc"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $status = Get-Prop $e 'status'
        if ([string]::IsNullOrWhiteSpace($status)) { $status = 'unfollow' }
        $lines.Add(('{0}`t{1}`t{2}`t{3}`t{4}`t{5}' -f `
            (Escape-Field $uid), `
            (Escape-Field (Get-Prop $e 'login')), `
            (Escape-Field (Get-Prop $e 'name')), `
            (Escape-Field $utc), `
            (Escape-Field (Get-Prop $e 'time_local')), `
            (Escape-Field $status)))
    }
    Write-AtomicFile -Path $EventsFile -Lines $lines
}

# Alte Events (>30 Tage) bereinigen - gibt gefilterte Liste zurück
function Purge-OldEvents {
    param($Events)
    $cutoff  = [datetime]::UtcNow.AddDays(-$EventKeepDays)
    $kept    = New-Object System.Collections.ArrayList
    $removed = 0
    foreach ($e in @($Events)) {
        $raw = Get-Prop $e 'time_utc'
        $dt  = [datetime]::MinValue
        $ok  = [datetime]::TryParse($raw, [ref]$dt)
        if ($ok -and $dt -ge $cutoff) {
            [void]$kept.Add($e)
        } else {
            $removed++
        }
    }
    if ($removed -gt 0) {
        Save-Events -Events @($kept)
        Write-Log "$removed Event(s) älter als $EventKeepDays Tage bereinigt."
    }
    return , @($kept)
}

# Wenn jemand re-folgt: Event auf "refollowed" setzen (NICHT löschen!)
function Mark-RefollowedEvents {
    param([hashtable]$CurrentFollowers)
    $events  = @(Load-Events)
    if ($events.Count -eq 0) { return }
    $changed = $false
    $refAt   = [datetime]::UtcNow.ToString('o')
    $updated = New-Object System.Collections.ArrayList
    foreach ($e in $events) {
        $uid    = Get-Prop $e 'user_id'
        $status = Get-Prop $e 'status'
        if ($CurrentFollowers.ContainsKey($uid) -and $status -eq 'unfollow') {
            # Re-follow erkannt - Status setzen, nicht löschen
            $e.status = "refollowed:$refAt"
            $changed  = $true
            Write-Log "Re-Follow erkannt: $(Get-Prop $e 'name') ($(Get-Prop $e 'login'))"
        }
        [void]$updated.Add($e)
    }
    if ($changed) { Save-Events -Events @($updated) }
}

# Display-State aktualisieren
function Update-DisplayFromEvents {
    $raw    = @(Load-Events)
    $events = @(Purge-OldEvents -Events $raw)

    if ($events.Count -eq 0) {
        Set-State ('{0}.state.list_text' -f $PluginId) 'Noch keine Unfollows in den letzten 30 Tagen.'
        return
    }

    # Nach Zeit absteigend, max. 20 anzeigen
    $sorted = @($events | Sort-Object {
        $dt = [datetime]::MinValue
        [void][datetime]::TryParse((Get-Prop $_ 'time_utc'), [ref]$dt)
        $dt
    } -Descending | Select-Object -First 20)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($row in $sorted) {
        $n = Get-Prop $row 'name'
        if ([string]::IsNullOrWhiteSpace($n)) { $n = Get-Prop $row 'login' }
        $t      = Get-Prop $row 'time_local'
        $status = Get-Prop $row 'status'

        $suffix = ''
        if ($status -like 'refollowed:*') {
            $rfRaw = $status.Substring('refollowed:'.Length)
            $rfDt  = [datetime]::MinValue
            if ([datetime]::TryParse($rfRaw, [ref]$rfDt)) {
                $suffix = ' [re-followed {0}]' -f $rfDt.ToLocalTime().ToString('dd.MM.yy')
            } else {
                $suffix = ' [re-followed]'
            }
        }
        $lines.Add(('{0} — {1}{2}' -f $n, $t, $suffix))
    }

    $activeCount = @($events | Where-Object { (Get-Prop $_ 'status') -eq 'unfollow' }).Count
    Set-State ('{0}.state.list_text' -f $PluginId) ([string]::Join([Environment]::NewLine, $lines.ToArray()))
    Write-Log ('Display aktualisiert: {0} Events gesamt, {1} aktive Unfollows.' -f $events.Count, $activeCount)
}

# ==============================================================================
# Twitch API
# ==============================================================================

function Invoke-TwitchApi {
    param([string]$Url, [string]$ClientId, [string]$Token)
    $headers = @{
        'Client-Id'     = $ClientId
        'Authorization' = "Bearer $Token"
    }
    return Invoke-RestMethod -Uri $Url -Method Get -Headers $headers -ContentType 'application/json' -TimeoutSec 30
}

function Resolve-Broadcaster {
    param([string]$ClientId, [string]$Token, [string]$Login)
    $clean = $Login.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($clean)) {
        throw 'Broadcaster Login ist leer. Bitte in den TP-Settings den Twitch LOGIN-NAMEN (z.B. "odin23x") eintragen - NICHT die numerische ID!'
    }
    # Cache nutzen
    if ($script:ResolvedLogin -eq $clean -and -not [string]::IsNullOrWhiteSpace($script:ResolvedId)) {
        return $script:ResolvedId
    }
    $resp = Invoke-TwitchApi `
        -Url    ('https://api.twitch.tv/helix/users?login={0}' -f [uri]::EscapeDataString($clean)) `
        -ClientId $ClientId -Token $Token
    if ($null -eq $resp.data -or $resp.data.Count -lt 1) {
        throw ("Broadcaster '{0}' wurde auf Twitch nicht gefunden. Bitte den LOGIN-NAMEN eintragen (z.B. 'odin23x'), KEINE numerische ID!" -f $clean)
    }
    $script:ResolvedId    = [string]$resp.data[0].id
    $script:ResolvedLogin = [string]$resp.data[0].login
    Write-Log ('Broadcaster aufgeloest: {0} (ID: {1})' -f $script:ResolvedLogin, $script:ResolvedId)
    return $script:ResolvedId
}

function Get-AllFollowers {
    param([string]$ClientId, [string]$Token, [string]$BroadcasterId)
    $all    = @{}
    $cursor = $null
    $page   = 0
    do {
        $page++
        $url = "https://api.twitch.tv/helix/channels/followers?broadcaster_id=$BroadcasterId&first=100"
        if ($cursor) { $url += "&after=$([uri]::EscapeDataString($cursor))" }
        $resp = Invoke-TwitchApi -Url $url -ClientId $ClientId -Token $Token
        foreach ($f in $resp.data) {
            $uid = [string]$f.user_id
            if ([string]::IsNullOrWhiteSpace($uid)) { continue }
            $all[$uid] = @{
                user_id     = $uid
                user_login  = [string]$f.user_login
                user_name   = [string]$f.user_name
                followed_at = [string]$f.followed_at
            }
        }
        $cursor = $null
        if ($null -ne $resp.pagination -and $null -ne $resp.pagination.cursor) {
            $c = [string]$resp.pagination.cursor
            if (-not [string]::IsNullOrWhiteSpace($c)) { $cursor = $c }
        }
        if ($page -gt 500) {
            Write-Log 'WARNUNG: Mehr als 50000 Follower - Pagination gestoppt.'
            break
        }
    } while ($cursor)
    return $all
}

function Register-UnfollowEvent {
    param([hashtable]$Follower)
    $fid = Get-Prop $Follower 'user_id'
    if ([string]::IsNullOrWhiteSpace($fid)) { return }

    # Kein doppelter Eintrag wenn bereits aktiver Unfollow vorhanden
    $events = @(Load-Events)
    foreach ($e in $events) {
        if ((Get-Prop $e 'user_id') -eq $fid -and (Get-Prop $e 'status') -eq 'unfollow') { return }
    }

    $flogin = Get-Prop $Follower 'user_login'
    $fname  = Get-Prop $Follower 'user_name'
    $name   = if (-not [string]::IsNullOrWhiteSpace($fname)) { $fname } else { $flogin }

    $newList = New-Object System.Collections.ArrayList
    foreach ($e in $events) { [void]$newList.Add($e) }
    [void]$newList.Add([pscustomobject]@{
        user_id    = $fid
        login      = $flogin
        name       = $name
        time_utc   = [datetime]::UtcNow.ToString('o')
        time_local = [datetime]::Now.ToString('dd.MM.yyyy HH:mm:ss')
        status     = 'unfollow'
    })
    Save-Events -Events @($newList)
    Write-Log ("Unfollow: {0} ({1})" -f $name, $flogin)
}

# ==============================================================================
# Haupt-Check
# ==============================================================================

function Run-Check {
    $clientId = [string]$script:Settings['Twitch Client ID']
    $token    = [string]$script:Settings['Twitch User Access Token']
    $login    = [string]$script:Settings['Broadcaster Login']

    if ([string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($login)) {
        Set-State ('{0}.state.status'     -f $PluginId) 'Bitte Settings setzen'
        Set-State ('{0}.state.last_error' -f $PluginId) 'Client ID, Token oder Broadcaster Login fehlen.'
        return
    }

    Set-State ('{0}.state.status'     -f $PluginId) 'Prüfe...'
    Set-State ('{0}.state.last_error' -f $PluginId) ''

    try {
        # Reset falls angefordert
        if ($script:ResetRequested) {
            if (Test-Path $FollowersFile) { Remove-Item $FollowersFile -Force -ErrorAction SilentlyContinue }
            if (Test-Path $EventsFile)    { Remove-Item $EventsFile    -Force -ErrorAction SilentlyContinue }
            $script:ResetRequested = $false
            $script:ResolvedId     = ''
            $script:ResolvedLogin  = ''
            Write-Log 'Baseline zurueckgesetzt.'
        }

        $bId     = Resolve-Broadcaster -ClientId $clientId -Token $token -Login $login
        $current = Get-AllFollowers    -ClientId $clientId -Token $token -BroadcasterId $bId
        $stored  = Load-Followers

        Write-Log ('Check Start: API={0} Follower, Gespeichert={1}' -f $current.Count, $stored.Count)

        $nowUtc = [datetime]::UtcNow.ToString('o')

        # Unfollows erkennen (in stored aber nicht mehr in current)
        foreach ($e in @($stored.GetEnumerator())) {
            $uid = [string]$e.Key
            if (-not $current.ContainsKey($uid)) {
                Register-UnfollowEvent -Follower $e.Value
                $stored.Remove($uid) | Out-Null
            }
        }

        # Aktuelle Follower speichern
        foreach ($pair in $current.GetEnumerator()) {
            $stored[[string]$pair.Key] = @{
                user_id      = [string]$pair.Value.user_id
                user_login   = [string]$pair.Value.user_login
                user_name    = [string]$pair.Value.user_name
                followed_at  = [string]$pair.Value.followed_at
                last_seen_at = $nowUtc
            }
        }

        Save-Followers -Followers $stored
        Mark-RefollowedEvents -CurrentFollowers $current
        Update-DisplayFromEvents

        Set-State ('{0}.state.last_check_time' -f $PluginId) ([datetime]::Now.ToString('dd.MM.yyyy HH:mm:ss'))
        Set-State ('{0}.state.status'          -f $PluginId) ('OK — {0} Follower' -f $current.Count)
        Set-State ('{0}.state.last_error'      -f $PluginId) ''

        Write-Log ('Check OK. Gespeichert jetzt={0}' -f $stored.Count)
        $script:LastCheckUtc = [datetime]::UtcNow

    } catch {
        $msg = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = "$msg | $($_.ErrorDetails.Message)" }
        Set-State ('{0}.state.status'     -f $PluginId) 'Fehler'
        Set-State ('{0}.state.last_error' -f $PluginId) $msg
        Write-Log "Run-Check Fehler: $msg"
    }
}

# ==============================================================================
# TP Message Handler
# ==============================================================================

function Handle-Message {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    $msg = $null
    try { $msg = $Line | ConvertFrom-Json } catch { return }
    if ($null -eq $msg) { return }

    switch ([string]$msg.type) {
        'info' {
            if ($null -ne $msg.settings) { Parse-SettingsArray -Values $msg.settings }
            Update-DisplayFromEvents
        }
        'settings' {
            if ($null -ne $msg.values) { Parse-SettingsArray -Values $msg.values }
            $script:ResolvedId    = ''
            $script:ResolvedLogin = ''
            $script:ForceRefresh  = $true
            Write-Log 'Settings geaendert. Broadcaster-Cache geleert, Refresh angefordert.'
        }
        'action' {
            switch ([string]$msg.actionId) {
                ('{0}.act.refresh' -f $PluginId) {
                    $script:ForceRefresh = $true
                    Write-Log 'Manueller Refresh angefordert.'
                }
                ('{0}.act.reset' -f $PluginId) {
                    $script:ResetRequested = $true
                    $script:ForceRefresh   = $true
                    Write-Log 'Baseline-Reset angefordert.'
                }
            }
        }
        'closePlugin' {
            Write-Log 'Touch Portal hat Plugin-Shutdown angefordert.'
            throw 'closePlugin received'
        }
    }
}

# ==============================================================================
# TCP Verbindung
# ==============================================================================

function Disconnect-TouchPortal {
    try { if ($null -ne $script:Reader)    { $script:Reader.Dispose()   } } catch {}
    try { if ($null -ne $script:Writer)    { $script:Writer.Dispose()   } } catch {}
    try { if ($null -ne $script:TcpClient) { $script:TcpClient.Close()  } } catch {}
    $script:Reader    = $null
    $script:Writer    = $null
    $script:TcpClient = $null
}

function Connect-TouchPortal {
    while ($true) {
        try {
            Write-Log "Verbinde mit Touch Portal ($TPHost`:$TPPort)..."
            $tc     = New-Object System.Net.Sockets.TcpClient
            $tc.Connect($TPHost, $TPPort)
            $stream = $tc.GetStream()
            $enc    = New-Object System.Text.UTF8Encoding($false)

            $script:TcpClient        = $tc
            $script:Writer           = New-Object System.IO.StreamWriter($stream, $enc)
            $script:Writer.AutoFlush = $true
            $script:Reader           = New-Object System.IO.StreamReader($stream, $enc)

            Send-TP @{ type = 'pair'; id = $PluginId }
            Write-Log 'Verbunden mit Touch Portal.'
            return
        } catch {
            Write-Log ("Verbindung fehlgeschlagen: {0} — Retry in 5s" -f $_.Exception.Message)
            try { if ($null -ne $tc) { $tc.Close() } } catch {}
            Start-Sleep -Seconds 5
        }
    }
}

function Test-Connected {
    if ($null -eq $script:TcpClient) { return $false }
    try { return $script:TcpClient.Connected } catch { return $false }
}

# ==============================================================================
# START
# ==============================================================================

Write-Log '===== Plugin startet ====='
Connect-TouchPortal

Set-State ('{0}.state.status'          -f $PluginId) 'Startet...'
Set-State ('{0}.state.list_text'       -f $PluginId) 'Noch keine Unfollows in den letzten 30 Tagen.'
Set-State ('{0}.state.last_error'      -f $PluginId) ''
Set-State ('{0}.state.last_check_time' -f $PluginId) ''
Set-State ('{0}.state.last_debug'      -f $PluginId) ''
Update-DisplayFromEvents

# ==============================================================================
# Hauptschleife
# ==============================================================================

while ($true) {
    try {
        # Verbindung prüfen
        if (-not (Test-Connected)) {
            throw 'TCP-Verbindung ist nicht mehr aktiv.'
        }

        # Nachrichten lesen (non-blocking)
        $readMore = $true
        while ($readMore) {
            $readMore = $false
            $hasData  = $false
            try {
                $hasData = ($script:TcpClient.Available -gt 0 -or $script:Reader.Peek() -ge 0)
            } catch {
                throw 'Fehler beim Lesen des TCP-Streams.'
            }

            if ($hasData) {
                $line = $null
                try { $line = $script:Reader.ReadLine() } catch { throw 'ReadLine-Fehler.' }

                # null = EOF = Verbindung getrennt
                if ($null -eq $line) { throw 'TCP-Verbindung getrennt (EOF).' }

                Handle-Message -Line $line
                $readMore = $true
            }
        }

        # Intervall-Check
        $interval = 300
        [void][int]::TryParse([string]$script:Settings['Check Interval Seconds'], [ref]$interval)
        if ($interval -lt 60) { $interval = 60 }

        $elapsed = ([datetime]::UtcNow - $script:LastCheckUtc).TotalSeconds
        $doCheck = $script:ForceRefresh
        if (-not $doCheck) { $doCheck = ($script:LastCheckUtc -eq [datetime]::MinValue) }
        if (-not $doCheck) { $doCheck = ($elapsed -ge $interval) }

        if ($doCheck) {
            $script:ForceRefresh = $false
            Run-Check
        }

        Start-Sleep -Milliseconds 500

    } catch {
        $errMsg = $_.Exception.Message
        Write-Log "Hauptschleife: $errMsg — Starte Reconnect..."

        try { Set-State ('{0}.state.status'     -f $PluginId) 'Reconnect...' } catch {}
        try { Set-State ('{0}.state.last_error' -f $PluginId) $errMsg } catch {}

        Disconnect-TouchPortal
        Start-Sleep -Seconds 3
        Connect-TouchPortal

        # States nach Reconnect wiederherstellen
        try {
            Set-State ('{0}.state.status'     -f $PluginId) 'Reconnected — OK'
            Set-State ('{0}.state.last_error' -f $PluginId) ''
            Update-DisplayFromEvents
        } catch {}
    }
}
