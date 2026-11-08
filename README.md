# Bare Bitcoin Prisvarsel — Omarchy-plugin

Viser den aktuelle BTC-prisen i NOK hos [Bare Bitcoin](https://barebitcoin.no/invitert/uHgWAMQr)
rett i Omarchy-linja, med prisgraf for dag/uke/måned/år, og varsler deg når
prisen krysser en terskel du setter — direkte i panelet.

**Plugin-id:** `io.github.katla50.barebitcoin`

## Hva den gjør — og ikke gjør

![Pluginen i drift: pris, ettårsgraf og terskelskjema](preview.png)

- ✅ Henter BTC/NOK-prisen fra Bare Bitcoins **offentlige** prisendepunkt:
  `GET https://api.bb.no/v1/price/nok` (ingen autentisering, se
  [API-dokumentasjonen](https://dev.barebitcoin.no/api/openapi))
- ✅ Viser prisen som et bar-widget (pill); klikk åpner et panel med
  nåpris, bid/ask og en prisgraf
- ✅ Prisgraf med velbare perioder: **dag, uke, måned og år**
- ✅ Hold musa over grafen for **dato og pris** på nærmeste punkt
- ✅ Lagrede prisvarsler tegnes som en **oransje stiplet linje** i grafen
  (kun når terskelen er lagret og ligger innenfor valgt periodes prisnivå)
- ✅ Setter øvre/nedre terskel og pollintervall **i panelet**, uten å
  redigere filer for hånd
- ✅ Sender desktop-varsel (`notify-send`) når prisen krysser en terskel —
  én gang per krysning, og den aktiveres på nytt når prisen er tilbake i
  det nøytrale båndet
- ❌ Ingen handel, ingen ordrer, ingen uttak
- ❌ Ingen API-nøkkel eller konto kreves
- ❌ Ingen POST-forespørsler mot Bare Bitcoin — pluginen er 100 % read-only

### Om historikken i grafen

Bare Bitcoins offentlige API har **ingen** historisk pris-endepunkt (kun
`/v1/price/nok` og volumstatistikk). Grafen bruker derfor CoinGeckos
offentlige BTC/NOK-markedsserie (`/api/v3/coins/bitcoin/market_chart`,
nøkkelfri GET). Linja er markedspris; tallet øverst i panelet og pillen er
Bare Bitcoins egen kurs — de skiller seg med omtrent spreaden. Kilden står
under grafen i panelet.

## Forutsetninger

- Omarchy med Quattro-shell og plugin-støtte
- `curl`, `jq`, `gawk`/`awk`, `coreutils` (`numfmt`) og `libnotify` (`notify-send`)

## Installasjon

```sh
omarchy plugin add https://github.com/katla50/barebitcoin-omarchy --enable
# eller: omarchy plugin install <samme URL>
```

## Konfigurasjon

Alt kan settes i panelet (klikk på pillen → **Prisvarsel** → **Lagre
innstillinger**). Det lagres i `~/.config/barebitcoin-plugin/config.json`,
som også kan redigeres direkte (midtklikk på pillen åpner fila):

```json
{
  "upper_threshold_nok": 1200000,
  "lower_threshold_nok": 900000,
  "poll_interval_seconds": 60
}
```

- Sett en terskel til `null` (eller la feltet stå tomt i panelet) for å
  deaktivere den.
- Minimum pollintervall er 30 sekunder — lavere verdier heves til 30.
- Endringer tas i bruk ved neste poll, uten omstart av skallet.

Selve widgetens utseende (kompakt visning, bid/ask i panelet, ikon) justeres
i `~/.config/omarchy/shell.json` via manifestets `barWidget`-skjema.

## Avinstallasjon

```sh
omarchy plugin remove io.github.katla50.barebitcoin
```

Pluginen rører bare sitt eget plugin-område samt
`~/.config/barebitcoin-plugin/` (config + varseltilstand). Sistnevnte er
dine egne data og fjernes derfor ikke automatisk — slett mappa manuelt om du
vil ha alt borte:

```sh
rm -rf ~/.config/barebitcoin-plugin
```

## Feilsøking

- **Ingen pris?** Test endepunktet direkte:
  `curl -s https://api.bb.no/v1/price/nok` — forventet svar:
  `{"price":718839.94,"bid":…,"ask":…,"timestamp":…}`
- **Tom graf?** CoinGecko rate-limiter nøkkelfrie kall. Panelet viser
  «rate limited» når det skjer; åpne det igjen litt senere. Resultatet
  caches i 10 minutter per periode.
- **Ingen varsler?** Test varslene: `notify-send "Test" "Varsler virker"`
- **Se hva helperen gjør:** kjør
  `sh ~/.config/omarchy/plugins/io.github.katla50.barebitcoin/price-watch.sh ~/.config/barebitcoin-plugin`
  i en terminal — den skriver én JSON-linje per poll.
- **Lagring feiler?** Kjør `save-config.sh` for hånd:
  `sh ~/.config/omarchy/plugins/io.github.katla50.barebitcoin/save-config.sh ~/.config/barebitcoin-plugin 1200000 900000 60`
- **QML-feil:** `qs log -p ~/.local/share/omarchy/shell --tail 100 | grep barebitcoin`

## Lisens

MIT — se [LICENSE](LICENSE).
