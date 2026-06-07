# Walhalla Twitch Unfollow Tracker
### Touch Portal Plugin by odin23x

Verfolge wer deinen Twitch-Kanal unfollowd – direkt in Touch Portal.
Speichert die letzten 20 Unfollows der vergangenen 30 Tage. Wenn jemand wieder folgt, wird der Eintrag automatisch entfernt.

## Einrichtung

### Einstellungen
| Einstellung | Beschreibung |
|---|---|
| Twitch Client ID | Deine App Client ID (dev.twitch.tv) |
| Twitch User Access Token | OAuth Token mit `moderator:read:followers` Scope |
| Broadcaster Login | Dein Twitch-Login (lowercase) |
| Check Interval Seconds | Prüfintervall (60–86400, Standard: 300) |

### Benötigte Token-Scopes
- `moderator:read:followers`

## States
| State | Beschreibung |
|---|---|
| Status | Plugin-Status |
| Unfollow Liste | Liste der letzten Unfollows (Name - Datum) |
| Letzter Fehler | Fehlermeldung falls vorhanden |
| Letzter Check | Zeitstempel des letzten Checks |

## Aktionen
- **Refresh now** – Sofortiger Check
- **Reset Baseline** – Follower-Basis zurücksetzen

## Lizenz
MIT License – by odin23x
