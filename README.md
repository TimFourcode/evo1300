# EVO 1300 – BLE-Steuerung per Kurzbefehl

iOS-App (iOS 17+), die eine Magicshine-Lampe per CoreBluetooth steuert und die Befehle als App Intents für Kurzbefehle, Siri und die Action-Taste anbietet. Getestet mit der **Magicshine EVO 1300** (`M2-B0 EVO1300`).

> Kein offizielles Magicshine-Produkt und nicht mit Magicshine verbunden. Das Protokoll ist aus öffentlichen Quellen und eigenen Tests nachgebaut. Nutzung auf eigene Gefahr.

## Setup

```sh
open EVO1300.xcodeproj
```

In Xcode unter *Signing & Capabilities* das eigene Team auswählen. Wer ein anderes Konto nutzt, ändert dort außerdem die Bundle-ID (`de.fourcode.evo1300`). Danach die App auf einem echten iPhone starten, denn der Simulator hat kein Bluetooth. Das Projekt lässt sich alternativ mit `xcodegen generate` aus `project.yml` neu erzeugen.

1. Lampe einschalten und in der App aus der Liste auswählen (meist `M1-B0…` oder `M2-B0…`).
2. Die App startet mit der schwarzen Übersicht: ein Regler wie bei der iPhone-Taschenlampe (unten = aus) und ein Fernlicht-Button. Einrichtung, Tests und Log liegen hinter dem Zahnrad. Dort im Bereich *Test* die Stufen ausprobieren. Reagiert die Lampe nicht, das Profil wechseln (Modul 2 → Modul 1).
3. In Kurzbefehle z. B. **EVO 1300 umschalten** und danach **App öffnen: komoot** anlegen und auf die Action-Taste legen.

## Intents

| Intent | Wirkung |
| --- | --- |
| EVO 1300 umschalten | Aus ↔ zuletzt genutzte Stufe |
| EVO 1300 nächste Stufe | Niedrig → Mittel → Hoch → Max (wie die Modustaste) |
| EVO 1300 Helligkeit setzen | Direkte Wahl einer Stufe |
| EVO 1300 Fernlicht umschalten | Abblendlicht (zuletzt genutzte Stufe) ↔ Fernlicht |
| EVO 1300 Fernlicht setzen | Gezielt Fernlicht an oder aus |
| EVO 1300 Akkustand | Gibt den Akkustand zurück (ein Wert von -1 bedeutet: keine Antwort) |

Bei einem Bluetooth-Fehler werfen die Intents bewusst keinen Fehler. Sie geben stattdessen „Fehler: …“ zurück, damit der Kurzbefehl nicht abbricht und komoot trotzdem geöffnet wird.

## Protokoll

Quelle: [xrsprint/karoo-magicshine-controls](https://github.com/xrsprint/karoo-magicshine-controls). Die folgenden Punkte weichen von der ursprünglichen Spezifikation ab:

- Service `FFE1` / Characteristic `FFE0` (die umgekehrte Belegung FFE0/FFE1 wird als Fallback akzeptiert). Geschrieben wird mit Antwort (write-with-response), Antworten der Lampe kommen per Notify über dieselbe Characteristic.
- Aufbau eines Frames: `DE <Länge> <Befehl> <Payload…> <XOR> ED`. `A2` setzt die Lichtausgabe, `A4` und `A1` sind reine Abfragen (Akku und Temperatur) und dienen gleichzeitig als Handshake.
- Zwei Kanäle: Der M2-Frame ist als `01 02` aufgebaut, danach folgt je Kanal ein Tripel `(Kanal, Modus, Wert)`. Die übernommenen EVO-1700-Stufen setzen Kanal 0 fest auf 10 % und legen die Stufe auf Kanal 1. An der EVO 1300 ist Kanal 1 das Fernlicht. Das Profil `EVO 1300` (automatisch am Namen erkannt) setzt deshalb das Abblendlicht auf Kanal 0 und das Fernlicht auf Kanal 1. Welcher Kanal was ist, lässt sich in den Einstellungen testen und bei Bedarf tauschen.
- Fernlicht, weitere Methoden: Für die EVO 1300 gibt es keinen Mitschnitt. In den Einstellungen unter *Fernlicht* lässt sich die Methode wählen: das Bluetooth Light Profile der HORI 1300 (`00` und danach `04 01`/`04 00` an `8CE5DD03`) oder eine von mehreren A2-Varianten. Mit „Bluetooth-Dienste ins Log schreiben“ lässt sich prüfen, welche Services die Lampe anbietet.
- Die EVO 1300 selbst ist in den Referenz-Mitschnitten nicht enthalten. Welches Profil passt, muss also an der Lampe getestet werden. Mit dem Log und dem Roh-Befehl in der App lässt sich das Protokoll weiter untersuchen.

## Ablauf einer Session

Bluetooth prüfen → gekoppelte Lampe über `retrievePeripherals` holen (funktioniert auch im Hintergrund, ohne Scan) → verbinden. Für diese Schritte gilt ein Zeitlimit von 3 s. Danach Characteristic suchen → Notify einschalten → A4/A1 senden → Befehl senden. Auch dafür gilt ein Zeitlimit von 3 s. Zum Schluss wird die Verbindung getrennt.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
