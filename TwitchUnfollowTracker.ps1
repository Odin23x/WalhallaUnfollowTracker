$ErrorActionPreference = 'Stop'

$PluginId = 'odin23x.twitch_unfollow_tracker_clean'
$PluginDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $PluginDir 'data'
$FollowersFile = Join-Path $DataDir 'followers.tsv'
$EventsFile = Join-Path $DataDir 'events.tsv'
$LogFile = Join-Path $DataDir 'tracker.log'
$TPHost = '127.0.0.1'
$TPPort = 12136

if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Force -Path $DataDir | Out-Null }

$script:Settings = @{
    'Twitch Client ID' = ''
    'Twitch User Access Token' = ''
    'Broadcaster Login' = ''
    'Check Interval Seconds' = '300'
}
$script:TcpClient = $null
$script:Writer = $null
$script:Reader = $null
$script:ForceRefresh = $false
$script:ResetRequested = $false
$script:LastCheckUtc = [datetime]::MinValue
$script:ResolvedBroadcasterId = ''
$script:ResolvedBroadcasterLogin = ''

function Send-TP {
    param([hashtable]$Payload)
    if ($null -eq $script:Writer) { return }
    $json = $Payload | ConvertTo-Json -Compress -Depth 10
    $script:Writer.WriteLine($json)
    $script:Writer.Flush()
}

function Set-State {
    param([string]$Id, [string]$Value)
    Send-TP @{ type = 'stateUpdate'; id = $Id; value = [string]$Value }
}

function Write-Log {
    param([string]$Message)
    $line = ('[{0}] {1}' -f ([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')), $Message)
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    try { Set-State 'odin23x.twitch_unfollow_tracker_clean.state.last_debug' $Message } catch {}
}

function Parse-SettingsArray {
    param($Values)
    foreach ($item in $Values) {
        foreach ($prop in $item.PSObject.Properties) {
            $script:Settings[$prop.Name] = [string]$prop.Value
        }
    }
}

function Escape-Field([string]$s) {
    if ($null -eq $s) { return '' }
    return (($s -replace "`t", ' ') -replace "`r", ' ') -replace "`n", ' '
}

function Get-MapValue {
    param($Obj, [string]$Key)
    if ($null -eq $Obj) { return '' }
    if ($Obj -is [hashtable]) {
        if ($Obj.ContainsKey($Key)) { return [string]$Obj[$Key] }
        return ''
    }
    try {
        $prop = $Obj.PSObject.Properties[$Key]
        if ($null -ne $prop) { return [string]$prop.Value }
    } catch {}
    return ''
}

function Load-Followers {
    $map = @{}
    if (-not (Test-Path $FollowersFile)) { return $map }
    foreach ($line in Get-Content -Path $FollowersFile -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", 5
        if ($parts.Count -lt 5) { continue }
        $uid = [string]$parts[0]
        if ([string]::IsNullOrWhiteSpace($uid)) { continue }
        $map[$uid] = @{ user_id=$uid; user_login=[string]$parts[1]; user_name=[string]$parts[2]; followed_at=[string]$parts[3]; last_seen_at=[string]$parts[4] }
    }
    return $map
}

function Save-Followers {
    param([hashtable]$Followers)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Followers.GetEnumerator()) {
        $f = $entry.Value
        $uid = Get-MapValue $f 'user_id'
        if ([string]::IsNullOrWhiteSpace($uid)) { continue }
        $lines.Add(("{0}`t{1}`t{2}`t{3}`t{4}" -f (Escape-Field $uid), (Escape-Field (Get-MapValue $f 'user_login')), (Escape-Field (Get-MapValue $f 'user_name')), (Escape-Field (Get-MapValue $f 'followed_at')), (Escape-Field (Get-MapValue $f 'last_seen_at'))))
    }
    Set-Content -Path $FollowersFile -Value $lines -Encoding UTF8
}

function Load-Events {
    $events = New-Object System.Collections.ArrayList
    $seen = @{}
    if (-not (Test-Path $EventsFile)) { return @($events) }
    foreach ($line in Get-Content -Path $EventsFile -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", 5
        if ($parts.Count -lt 5) { continue }
        $uid = [string]$parts[0]
        $utc = [string]$parts[3]
        if ([string]::IsNullOrWhiteSpace($uid) -or [string]::IsNullOrWhiteSpace($utc)) { continue }
        $dedupeKey = "$uid|$utc"
        if ($seen.ContainsKey($dedupeKey)) { continue }
        $seen[$dedupeKey] = $true
        [void]$events.Add([pscustomobject]@{ user_id=$uid; login=[string]$parts[1]; name=[string]$parts[2]; time_utc=$utc; time_local=[string]$parts[4] })
    }
    return @($events)
}

function Save-Events {
    param($Events)
    $lines = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($e in @($Events)) {
        $uid = Get-MapValue $e 'user_id'
        $utc = Get-MapValue $e 'time_utc'
        if ([string]::IsNullOrWhiteSpace($uid) -or [string]::IsNullOrWhiteSpace($utc)) { continue }
        $dedupeKey = "$uid|$utc"
        if ($seen.ContainsKey($dedupeKey)) { continue }
        $seen[$dedupeKey] = $true
        $lines.Add(("{0}`t{1}`t{2}`t{3}`t{4}" -f (Escape-Field $uid), (Escape-Field (Get-MapValue $e 'login')), (Escape-Field (Get-MapValue $e 'name')), (Escape-Field $utc), (Escape-Field (Get-MapValue $e 'time_local'))))
    }
    Set-Content -Path $EventsFile -Value $lines -Encoding UTF8
}

function Purge-RefollowedEvents {
    param([hashtable]$CurrentFollowers)
    $events = @(Load-Events)
    if ($events.Count -eq 0) { return }
    $filtered = New-Object System.Collections.ArrayList
    $changed = $false
    foreach ($e in $events) {
        $uid = Get-MapValue $e 'user_id'
        if ([string]::IsNullOrWhiteSpace($uid)) { $changed = $true; continue }
        if ($CurrentFollowers.ContainsKey($uid)) {
            $changed = $true
            continue
        }
        [void]$filtered.Add($e)
    }
    if ($changed) { Save-Events -Events @($filtered) }
}

function Update-DisplayFromEvents {
    $events = @(Load-Events)
    $cutoff = [datetime]::UtcNow.AddDays(-30)
    $kept = New-Object System.Collections.ArrayList
    foreach ($e in $events) {
        $evtUtcRaw = Get-MapValue $e 'time_utc'
        if ([string]::IsNullOrWhiteSpace($evtUtcRaw)) { continue }
        try { $evtUtc = [datetime]::Parse($evtUtcRaw) } catch { continue }
        if ($evtUtc -ge $cutoff) { [void]$kept.Add($e) }
    }
    if ($kept.Count -ne $events.Count) { Save-Events -Events @($kept) }
    $events = @($kept)
    if ($events.Count -eq 0) {
        Set-State 'odin23x.twitch_unfollow_tracker_clean.state.list_text' 'Noch keine Unfollows in den letzten 30 Tagen.'
        return
    }
    $top = @($events | Sort-Object {[datetime]::Parse((Get-MapValue $_ 'time_utc'))} -Descending | Select-Object -First 20)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($row in $top) {
        $n = Get-MapValue $row 'name'
        if ([string]::IsNullOrWhiteSpace($n)) { $n = Get-MapValue $row 'login' }
        $t = Get-MapValue $row 'time_local'
        $lines.Add(("{0} - {1}" -f $n, $t))
    }
    $text = [string]::Join([Environment]::NewLine, $lines.ToArray())
    if ([string]::IsNullOrWhiteSpace($text)) { $text = 'Noch keine Unfollows in den letzten 30 Tagen.' }
    Set-State 'odin23x.twitch_unfollow_tracker_clean.state.list_text' $text
}

function Invoke-TwitchJson {
    param([string]$Url,[string]$ClientId,[string]$Token)
    $headers = @{ 'Client-Id' = $ClientId; 'Authorization' = "Bearer $Token" }
    return Invoke-RestMethod -Uri $Url -Method Get -Headers $headers -ContentType 'application/json'
}

function Resolve-Broadcaster {
    param([string]$ClientId,[string]$Token,[string]$Login)
    $loginClean = $Login.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($loginClean)) { throw 'Broadcaster Login is empty.' }
    if ($script:ResolvedBroadcasterLogin -eq $loginClean -and -not [string]::IsNullOrWhiteSpace($script:ResolvedBroadcasterId)) { return $script:ResolvedBroadcasterId }
    $resp = Invoke-TwitchJson -Url ("https://api.twitch.tv/helix/users?login={0}" -f [uri]::EscapeDataString($loginClean)) -ClientId $ClientId -Token $Token
    if ($null -eq $resp.data -or $resp.data.Count -lt 1) { throw "Broadcaster '$loginClean' was not found on Twitch." }
    $script:ResolvedBroadcasterId = [string]$resp.data[0].id
    $script:ResolvedBroadcasterLogin = [string]$resp.data[0].login
    return $script:ResolvedBroadcasterId
}

function Get-AllFollowers {
    param([string]$ClientId,[string]$Token,[string]$BroadcasterId)
    $all = @{}
    $cursor = $null
    do {
        $url = "https://api.twitch.tv/helix/channels/followers?broadcaster_id=$BroadcasterId&first=100"
        if ($cursor) { $url += "&after=$([uri]::EscapeDataString($cursor))" }
        $resp = Invoke-TwitchJson -Url $url -ClientId $ClientId -Token $Token
        foreach ($f in $resp.data) {
            $uid = [string]$f.user_id
            if ([string]::IsNullOrWhiteSpace($uid)) { continue }
            $all[$uid] = @{ user_id=$uid; user_login=[string]$f.user_login; user_name=[string]$f.user_name; followed_at=[string]$f.followed_at }
        }
        $cursor = $null
        if ($null -ne $resp.pagination -and $resp.pagination.cursor) {
            $cursor = [string]$resp.pagination.cursor
            if ([string]::IsNullOrWhiteSpace($cursor)) { $cursor = $null }
        }
    } while ($cursor)
    return $all
}

function Register-UnfollowEvent {
    param([hashtable]$Follower)
    $fid = Get-MapValue $Follower 'user_id'
    if ([string]::IsNullOrWhiteSpace($fid)) { return }
    $events = @(Load-Events)
    foreach ($e in $events) {
        if ((Get-MapValue $e 'user_id') -eq $fid) { return }
    }
    $flogin = Get-MapValue $Follower 'user_login'
    $fname = Get-MapValue $Follower 'user_name'
    $name = if ([string]::IsNullOrWhiteSpace($fname)) { $flogin } else { $fname }
    $local = [datetime]::Now.ToString('dd.MM.yyyy HH:mm:ss')
    $utc = [datetime]::UtcNow.ToString('o')
    $newEvents = New-Object System.Collections.ArrayList
    foreach ($e in $events) { [void]$newEvents.Add($e) }
    [void]$newEvents.Add([pscustomobject]@{ user_id=$fid; login=$flogin; name=$name; time_utc=$utc; time_local=$local })
    Save-Events -Events @($newEvents)
    Write-Log ("Detected unfollow: {0} ({1})" -f $name, $flogin)
}

function Run-Check {
    $clientId = [string]$script:Settings['Twitch Client ID']
    $token = [string]$script:Settings['Twitch User Access Token']
    $login = [string]$script:Settings['Broadcaster Login']
    if ([string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($login)) {
        Set-State 'odin23x.twitch_unfollow_tracker_clean.state.status' 'Bitte Settings setzen'
        Set-State 'odin23x.twitch_unfollow_tracker_clean.state.last_error' 'Client ID, Token und Broadcaster Login fehlen.'
        return
    }
    Set-State 'odin23x.twitch_unfollow_tracker_clean.state.status' 'Prüfe...'
    Set-State 'odin23x.twitch_unfollow_tracker_clean.state.last_error' ''
    try {
        if ($script:ResetRequested) {
            if (Test-Path $FollowersFile) { Remove-Item $FollowersFile -Force -ErrorAction SilentlyContinue }
            if (Test-Path $EventsFile) { Remove-Item $EventsFile -Force -ErrorAction SilentlyContinue }
            $script:ResetRequested = $false
            Write-Log 'Baseline reset.'
        }
        $broadcasterId = Resolve-Broadcaster -ClientId $clientId -Token $token -Login $login
        $current = Get-AllFollowers -ClientId $clientId -Token $token -BroadcasterId $broadcasterId
        $stored = Load-Followers
        Write-Log (("Run-Check start. Current={0}, Stored={1}" -f @($current.Keys).Count, @($stored.Keys).Count))
        $nowUtc = [datetime]::UtcNow.ToString('o')
        foreach ($entry in @($stored.GetEnumerator())) {
            $uid = [string]$entry.Key
            if (-not $current.ContainsKey($uid)) {
                Register-UnfollowEvent -Follower $entry.Value
                $stored.Remove($uid) | Out-Null
            }
        }
        foreach ($pair in $current.GetEnumerator()) {
            $stored[[string]$pair.Key] = @{ user_id=[string]$pair.Value.user_id; user_login=[string]$pair.Value.user_login; user_name=[string]$pair.Value.user_name; followed_at=[string]$pair.Value.followed_at; last_seen_at=$nowUtc }
        }
        Save-Followers -Followers $stored
        Purge-RefollowedEvents -CurrentFollowers $current
        Update-DisplayFromEvents
        Set-State 'odin23x.twitch_unfollow_tracker_clean.state.last_check_time' ([datetime]::Now.ToString('dd.MM.yyyy HH:mm:ss'))
        Set-State 'odin23x.twitch_unfollow_tracker_clean.state.status' 'OK'
        Set-State 'odin23x.twitch_unfollow_tracker_clean.state.last_error' ''
        Write-Log (("Run-Check done. Stored now={0}" -f @($stored.Keys).Count))
        $script:LastCheckUtc = [datetime]::UtcNow
    } catch {
        $msg = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $msg + ' | ' + $_.ErrorDetails.Message }
        Set-State 'odin23x.twitch_unfollow_tracker_clean.state.status' 'Fehler'
        Set-State 'odin23x.twitch_unfollow_tracker_clean.state.last_error' $msg
        Write-Log ("Run-Check failed: $msg")
    }
}

function Handle-Message {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    try { $msg = $Line | ConvertFrom-Json } catch { return }
    switch ([string]$msg.type) {
        'info' {
            if ($null -ne $msg.settings) { Parse-SettingsArray -Values $msg.settings }
            Update-DisplayFromEvents
        }
        'settings' {
            if ($null -ne $msg.values) { Parse-SettingsArray -Values $msg.values }
            $script:ResolvedBroadcasterId = ''
            $script:ResolvedBroadcasterLogin = ''
            $script:ForceRefresh = $true
        }
        'action' {
            switch ([string]$msg.actionId) {
                'odin23x.twitch_unfollow_tracker_clean.act.refresh' { $script:ForceRefresh = $true }
                'odin23x.twitch_unfollow_tracker_clean.act.reset' { $script:ResetRequested = $true; $script:ForceRefresh = $true }
            }
        }
        'closePlugin' { throw 'Touch Portal requested plugin shutdown.' }
    }
}

function Connect-TouchPortal {
    while ($true) {
        try {
            $script:TcpClient = New-Object System.Net.Sockets.TcpClient
            $script:TcpClient.Connect($TPHost, $TPPort)
            $stream = $script:TcpClient.GetStream()
            $script:Writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
            $script:Writer.AutoFlush = $true
            $script:Reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding($false)))
            Send-TP @{ type = 'pair'; id = $PluginId }
            Write-Log 'Connected to Touch Portal.'
            return
        } catch { Start-Sleep -Seconds 5 }
    }
}

Write-Log 'Plugin starting.'
Connect-TouchPortal
Set-State 'odin23x.twitch_unfollow_tracker_clean.state.status' 'Startet...'
Set-State 'odin23x.twitch_unfollow_tracker_clean.state.list_text' 'Noch keine Unfollows in den letzten 30 Tagen.'
Set-State 'odin23x.twitch_unfollow_tracker_clean.state.last_error' ''
Set-State 'odin23x.twitch_unfollow_tracker_clean.state.last_check_time' ''
Set-State 'odin23x.twitch_unfollow_tracker_clean.state.last_debug' ''
Update-DisplayFromEvents

while ($true) {
    try {
        while ($script:TcpClient.Available -gt 0 -or $script:Reader.Peek() -ge 0) {
            $line = $script:Reader.ReadLine()
            if ($null -eq $line) { break }
            Handle-Message -Line $line
        }
        $interval = 300
        [void][int]::TryParse([string]$script:Settings['Check Interval Seconds'], [ref]$interval)
        if ($interval -lt 60) { $interval = 60 }
        $elapsed = ([datetime]::UtcNow - $script:LastCheckUtc).TotalSeconds
        if ($script:ForceRefresh -or $script:LastCheckUtc -eq [datetime]::MinValue -or $elapsed -ge $interval) {
            $script:ForceRefresh = $false
            Run-Check
        }
        Start-Sleep -Milliseconds 500
    } catch {
        try {
            Set-State 'odin23x.twitch_unfollow_tracker_clean.state.status' 'Reconnect...'
            Set-State 'odin23x.twitch_unfollow_tracker_clean.state.last_error' $_.Exception.Message
        } catch {}
        Start-Sleep -Seconds 3
        try { if ($script:Reader) { $script:Reader.Dispose() } } catch {}
        try { if ($script:Writer) { $script:Writer.Dispose() } } catch {}
        try { if ($script:TcpClient) { $script:TcpClient.Close() } } catch {}
        $script:Reader = $null
        $script:Writer = $null
        $script:TcpClient = $null
        Connect-TouchPortal
    }
}
