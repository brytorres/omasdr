# Frequency Reference

Somewhere to start when the dial is blank. Everything here is **receive only** —
an RTL-SDR cannot transmit, and listening needs no licence.

> Band *edges* are law, set by each country's regulator. Everything inside them
> — calling frequencies, repeater subbands, channel spacing — is convention,
> coordinated regionally. Numbers that differ by region are marked as such.
> Check your own national band plan before relying on any of them.

## Pick the mode first

| Mode | Used for |
| --- | --- |
| **WFM** | Broadcast FM only (87.5–108 MHz; 76–95 in Japan) |
| **AM** | Airband (118–137 MHz), medium wave, shortwave broadcast |
| **NFM** | Almost all VHF/UHF land mobile: repeaters, marine, weather, licence-free radios |
| **USB** | HF above 10 MHz, every amateur satellite, utility and military HF |
| **LSB** | HF below 10 MHz |
| **CW** | Morse, and the narrowest filter here — good for digging a weak carrier out |
| **RAW** | No demodulation; for feeding a decoder |

Aviation stayed AM on purpose. With two aircraft transmitting at once you hear
both, garbled. FM's capture effect would silence the weaker one, and the weaker
one may be the emergency.

## Antenna length

Each leg of a dipole is a quarter wave:

```
leg length (cm) ≈ 7125 / frequency (MHz)
```

| Band | Leg |
| --- | --- |
| 6 m (52 MHz) | 137 cm |
| Airband (127 MHz) | 56 cm |
| Weather satellites (137 MHz) | 52 cm |
| 2 m (146 MHz) | 49 cm |
| Marine (157 MHz) | 45 cm |
| 1.25 m (223 MHz) | 32 cm |
| 70 cm (435 MHz) | 16 cm |
| ADS-B (1090 MHz) | 6.5 cm |

Vertical for land mobile, marine and repeaters; horizontal for SSB weak-signal
work. Crossing the two costs about 20 dB. A dipole is deaf off its ends, so
rotate it 90° before deciding a signal is not there.

## Broadcast

| Target | Frequency | Mode |
| --- | --- | --- |
| FM broadcast | 87.5–108 MHz | WFM |
| Medium wave | 526.5–1606.5 kHz | AM |
| Shortwave broadcast | 5.9–6.2, 7.2–7.45, 9.4–9.9, 11.6–12.1, 15.1–15.8 MHz | AM |

Medium wave is on 9 kHz channel spacing outside the Americas and 10 kHz within
them. Both it and shortwave open up dramatically after dark, when the signal
starts bouncing off the ionosphere instead of dying at the horizon; a station a
thousand miles away at midnight is ordinary.

DAB+ (174–240 MHz) and HD Radio are digital. They show up as flat-topped blocks
in the spectrum but there is nothing here to decode them with.

## Aircraft

| Target | Frequency | Mode |
| --- | --- | --- |
| Airband voice (tower, ground, approach) | 118–137 MHz | AM |
| Emergency | 121.500 MHz | AM |
| Oceanic and long-haul HF | 2.8–22 MHz | USB |
| VOLMET weather broadcasts | 3413, 5505, 8957, 13270 kHz | USB |
| ADS-B position beacons | 1090 MHz | use `dump1090` |

Airband channels are spaced 25 kHz apart, or 8.33 kHz in Europe. A tower is
quiet between transmissions and then busy in bursts — leave squelch open at
first so you can hear that you are on the right channel.

## Marine

| Target | Frequency | Mode |
| --- | --- | --- |
| Marine VHF | 156–162 MHz | NFM |
| Distress and calling (Ch 16) | 156.800 MHz | NFM |
| DSC (Ch 70) | 156.525 MHz | data |
| AIS ship positions | 161.975 / 162.025 MHz | use `AIS-catcher` |

The marine band is the same worldwide, which makes it one of the safest bets in
an unfamiliar country. Coastal traffic carries a long way over water.

## Weather satellites

| Satellite | Frequency | Note |
| --- | --- | --- |
| NOAA 15 | 137.620 MHz | APT, analogue images |
| NOAA 18 | 137.9125 MHz | APT |
| NOAA 19 | 137.100 MHz | APT |
| Meteor-M | 137.100 / 137.900 MHz | LRPT, digital, sharper |

Passes last about fifteen minutes and the signal is strongest overhead. Record
the pass and decode it afterwards with **SatDump**; a turnstile or V-dipole
beats a vertical here, because the satellite is above you rather than out at the
horizon.

## Satellites and the ISS

| Target | Frequency | Mode |
| --- | --- | --- |
| ISS voice downlink | 145.800 MHz | NFM |
| ISS SSTV images | 145.800 MHz | NFM, scheduled events |
| ISS APRS digipeater | 145.825 MHz | NFM |
| SO-50 downlink | 436.795 MHz | NFM |

Everything in orbit is Doppler-shifted: the downlink drifts several kHz across a
pass. Start tuned high and follow it down.

## Time and frequency standards

| Station | Frequency | Mode | Where |
| --- | --- | --- | --- |
| WWV / WWVH | 2.5, 5, 10, 15, 20 MHz | AM | United States |
| CHU | 3.330, 7.850, 14.670 MHz | USB | Canada |
| BPM | 2.5, 5, 10, 15 MHz | AM | China |
| RWM | 4.996, 9.996, 14.996 MHz | CW | Russia |

The low-frequency clock transmitters — DCF77 at 77.5 kHz, MSF at 60 kHz, JJY at
40 and 60 kHz — sit below what an RTL-SDR can reach, upconverter or not.

## Utility and beacons

| Target | Frequency | Mode |
| --- | --- | --- |
| Non-directional beacons (NDB) | 190–535 kHz | AM or CW |
| HFGCS (US military) | 8992, 11175 kHz | USB |
| Amateur beacon network (IBP) | 14.100, 18.110, 21.150, 24.930, 28.200 MHz | CW |

The IBP beacons transmit in a timed rotation from eighteen sites worldwide, so
hearing one tells you exactly where the band is open to right now.

## Sensors and data

| Region | ISM band | Command |
| --- | --- | --- |
| Europe, Africa, Russia | 433.050–434.790 MHz | `rtl_433 -f 433920000` |
| Americas | 902–928 MHz | `rtl_433 -f 915000000` |
| Europe (short range) | 868.0–868.6 MHz | `rtl_433 -f 868300000` |

`rtl_433` turns the neighbourhood's weather stations, tyre-pressure sensors,
thermometers and doorbells into structured readings. Best value per minute of
anything on this page, and it needs no antenna work at all.

## Amateur radio

The lower edge of each band is close to universal; upper edges and permitted
modes vary by country.

| Band | Range | Usual modes |
| --- | --- | --- |
| 160 m | 1.8–2.0 MHz | LSB, CW |
| 80 m | 3.5–4.0 MHz | LSB, CW |
| 40 m | 7.0–7.3 MHz | LSB, CW |
| 30 m | 10.1–10.15 MHz | CW, data |
| 20 m | 14.0–14.35 MHz | USB, CW |
| 17 m | 18.068–18.168 MHz | USB |
| 15 m | 21.0–21.45 MHz | USB, CW |
| 12 m | 24.89–24.99 MHz | USB |
| 10 m | 28.0–29.7 MHz | USB, CW, FM |
| 6 m | 50–54 MHz | USB, CW, FM |
| 2 m | 144–148 MHz | NFM, USB |
| 1.25 m | 222–225 MHz | NFM |
| 70 cm | 430–450 MHz | NFM, USB |

In ITU Region 1 (Europe, Africa, the Middle East, Russia) 2 m stops at 146 MHz,
70 cm at 440, and 6 m usually at 52. The 1.25 m band is Region 2 only.

**Repeaters.** A repeater listens on one frequency and retransmits on another,
offset by a standard shift for that band. You hear the output; a licensed
station transmits on the input. Most also need a sub-audible **CTCSS tone** to
open their squelch, which is why a repeater can sound dead while you are exactly
on frequency. If you hear a two-second tail of hiss and a courtesy beep after
each transmission, you are listening to a repeater rather than a direct contact.

**Where the activity is on 2 m:** the bottom of the band (144.0–144.3) is CW and
SSB weak-signal work, horizontally polarised and easy to miss on a vertical.
Everything above that is FM, vertical, and where the repeaters live.

**APRS** — packet position beacons, decodable with `direwolf`:

| Region | Frequency |
| --- | --- |
| North America | 144.390 MHz |
| Europe and Africa | 144.800 MHz |
| Australia and New Zealand | 145.175 MHz |
| Japan | 144.640 MHz |

## United States and Canada

| Target | Frequency | Mode |
| --- | --- | --- |
| **NOAA Weather Radio** | 162.400 / .425 / .450 / .475 / .500 / .525 / .550 | NFM |
| FRS and GMRS | 462.5500–462.7250, 467.5500–467.7250 | NFM |
| MURS | 151.820–154.600 | NFM |
| FM simplex calling, 2 m | **146.520** | NFM |
| FM simplex calling, 70 cm | **446.000** | NFM |
| SSB calling, 2 m | 144.200 | USB |
| Travelers' Information Stations | 530, 1610–1700 kHz | AM |

Repeater offsets: ±600 kHz on 2 m, ±5 MHz on 70 cm, ±1 MHz on 6 m, −1.6 MHz on
1.25 m.

**Weather Radio is the closest thing to an always-on government channel** —
AMBER alerts, chemical spills, 911 outages and evacuation notices alongside the
forecast, seven channels, continuous. There is no dedicated national emergency
frequency: national alerts arrive *through* ordinary broadcast stations (EAS),
phones (WEA), and Weather Radio rather than instead of them.

**PEP stations** are the hardened backbone of that system — roughly eighty
high-power AM broadcast stations with protected facilities and their own fuel,
first to receive a Presidential-level alert and relayed by everyone else. Mostly
50 kW clear-channel: WABC, KFI, WWL, WLW, KOA and similar. Tune the AM band
after dark and they reach a thousand miles.

## Europe and ITU Region 1

| Target | Frequency | Mode |
| --- | --- | --- |
| PMR446 (licence-free) | 446.00625–446.19375, 16 channels | NFM |
| LPD433 | 433.075–434.775 | NFM |
| FM calling, 2 m | 145.500 | NFM |
| FM calling, 70 cm | 433.500 | NFM |
| SSB calling, 2 m | 144.300 | USB |
| SSB calling, 70 cm | 432.200 | USB |

Repeater offsets: −600 kHz on 2 m and −1.6 MHz on 70 cm in most of Europe, though
a few countries use −7.6 MHz on 70 cm.

Public alerting is by cell broadcast (EU-Alert, and national systems such as
NL-Alert and Cell Broadcast in Germany) rather than a radio channel, so there is
nothing to tune for it. Several countries still run siren networks with a
control tone on VHF.

## Asia-Pacific and elsewhere

| Target | Frequency | Mode | Where |
| --- | --- | --- | --- |
| UHF CB | 476.4250–477.4125, 80 channels | NFM | Australia, New Zealand |
| UHF CB calling (ch 11) | 476.675 | NFM | Australia |
| UHF CB emergency (ch 5) | 476.525 | NFM | Australia |
| FM broadcast | 76–95 MHz | WFM | Japan |
| Amateur 2 m | 144–146 MHz | NFM | Japan, much of Region 3 |

Allocations vary more here than anywhere else. Airband, marine and the satellite
frequencies above are unchanged; almost everything else is worth checking with
the national regulator first.

## HF on an RTL-SDR

The RTL-SDR Blog V4 covers HF through an upconverter built into the dongle: tune
the frequency you actually want and the driver handles the rest. Do **not**
enable direct sampling — that is V3 advice and does nothing on a V4.

A quarter wave at 1 MHz is 75 metres, so any small antenna is electrically tiny
down there. Strong locals will come through and weak signals will not. A long
wire or a loop is a separate small project, and the single biggest improvement
available on these bands.

## Getting a clean signal

- **Set gain by hand.** The tuner's own AGC pumps and overloads on strong
  stations. Raise gain until the noise floor lifts, then back off one step.
- **Too much gain looks like signals everywhere.** Images of a strong FM station
  appearing across the band mean the front end is overloaded, not that the band
  is busy.
- **Use squelch on NFM channels.** Land mobile idles silent, and open squelch on
  an empty channel is exhausting.
- **Move the dongle away from the computer.** A USB extension cable away from the
  case, and off a hub shared with anything else, is worth more than most antenna
  changes.

## Decoders worth pairing with this

| Tool | Decodes |
| --- | --- |
| `rtl_433` | ISM sensors: weather stations, tyre pressure, doorbells |
| `dump1090` | ADS-B aircraft positions |
| `direwolf` | APRS and packet |
| `SatDump` | Weather satellite imagery |
| `multimon-ng` | POCSAG and FLEX pagers, DTMF |
| `redsea` | FM RDS: station name and song text |

Only one program can hold the dongle at a time, so stop playback here before
starting any of them.
