# WalhallaUnfollowTracker

Touch Portal Plugin für Twitch Unfollow-Tracking.

## Voraussetzungen
- Touch Portal Desktop App
- Twitch Client ID (Developer Console)
- Twitch User Access Token mit Scope: `moderator:read:followers`
- PowerShell 5.1 (Windows)

## Einrichtung

### 1. Plugin installieren
`.tpp` Datei in Touch Portal importieren.

### 2. Settings setzen (Touch Portal → Einstellungen → Plugins)
| Setting | Wert |
|---|---|
| Twitch Client ID | Deine App Client ID |
| Twitch User Access Token | Dein OAuth Token |
| Broadcaster Login | Dein Twitch **USERNAME** (z.B. `odin23x`) — **KEINE numerische ID!** |
| Check Interval Seconds | Prüfintervall in Sekunden (min. 60) |

### 3. Beim ersten Start
Das Plugin lädt alle aktuellen Follower als Baseline. Erst danach werden
Unfollows erkannt und gespeichert.

## States
| State | Beschreibung |
|---|---|
| Status | Plugin-Status (OK, Prüfe..., Fehler, Reconnect...) |
| Unfollow-Liste | Letzte 20 Unfollows der letzten 30 Tage |
| Letzter Fehler | Fehlermeldung bei Problemen |
| Debug Info | Letzte Log-Zeile |
| Letzter Check | Zeitstempel des letzten erfolgreichen Checks |

## Aktionen
- **Jetzt prüfen (Refresh)** — Sofortiger Check, unabhängig vom Intervall
- **Baseline zurücksetzen** — Löscht alle gespeicherten Daten, startet neu

## Datenbank
- Alle Unfollow-Events werden **30 Tage** gespeichert (rolling)
- Re-Follows werden als `[re-followed DD.MM.YY]` markiert — nicht gelöscht
- Dateien unter: `data/followers.tsv`, `data/events.tsv`, `data/tracker.log`
- Atomares Schreiben (kein Datenverlust bei Absturz)
- Log wird automatisch auf 400 Zeilen begrenzt

## Häufige Fehler
**"was not found on Twitch"** → Du hast eine numerische ID eingetragen.
Bitte den **LOGIN-NAMEN** (z.B. `odin23x`) in die Settings eintragen.

**Kein Reconnect** → War ein Bug in alten Versionen. Ab v301 behoben.
