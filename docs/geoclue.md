# GPS and Wi-Fi positioning with GeoClue

Linux has one standard location service: [GeoClue](https://gitlab.freedesktop.org/geoclue/geoclue).
It combines Wi-Fi positioning (Arch's build points at the open
[beaconDB](https://beacondb.net)), GNSS receivers via gpsd/NMEA, modem GPS
and a static `/etc/geolocation`. Omarchy does not install it, so the
plugin's satellite button is dimmed until you do.

## Setup

```bash
sudo pacman -S geoclue
```

GeoClue also needs an *authorisation agent* on your session. GNOME ships
one; on Hyprland start the demo agent from `~/.config/hypr/autostart.lua`:

```lua
o.launch_on_start("/usr/lib/geoclue-2.0/demos/agent")
```

then reload Hyprland (or run the agent once by hand). Alternatively skip
the agent by allowing the client outright, as root, in
`/etc/geoclue/conf.d/50-omarchy.conf`:

```ini
[geoclue-where-am-i]
allowed=true
system=false
users=
```

Open the popup again afterwards: the plugin re-checks the service every
time it opens, so no shell restart is needed.

## How the plugin uses it

- It asks for a position **only when you press the button** — never on
  startup or on a timer — and saves the result through
  `omarchy-weather-location`, so the stock weather widget follows too.
- The fix comes from `/usr/lib/geoclue-2.0/demos/where-am-i` (one process,
  one D-Bus connection, 12 s timeout); the place name comes from Photon's
  reverse lookup, refined with Kartverket in Norway.
- Where beaconDB has no Wi-Fi data, GeoClue falls back to an IP estimate;
  such coarse fixes are labelled "(approx.)" and the radius is shown.
- The demo agent approves any app with a `.desktop` file and shows no
  prompt — the button is the consent step. `submit-data=false` is the
  default, so nothing is uploaded to beaconDB unless you opt in.
- Wi-Fi positioning needs NetworkManager's `wpa_supplicant` backend; it
  yields nothing under `iwd`.

## States and messages

| Button state | Meaning | What to do |
|---|---|---|
| Dimmed, "not installed" | `/usr/lib/geoclue-2.0/demos/where-am-i` is missing | `sudo pacman -S geoclue` |
| Dimmed, "not authorised" | installed, but no agent running and no allow-list entry | start the agent (above) |
| Enabled | ready | click it |
| "Denied by GeoClue" | the agent rejected the request | check the agent is running for your user |
| "No position found" | no Wi-Fi data and no other source | set the location by search instead |
