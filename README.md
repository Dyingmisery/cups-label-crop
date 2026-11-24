<p align="center"><img src="assets/icon.png" width="128" alt="cups-label-crop icon"></p>

# cups-label-crop

A CUPS print server with AirPrint and a **Label Crop** queue for online sellers.

Vinted, InPost, Evri and many other carriers send the shipping label as a PDF with the label sitting on an A4 (or US Letter) sheet. Print that sheet to **Label Crop** and the server finds the label on the page, crops it, turns it upright and sends a sharp 4x6 label to your thermal label printer. Everything else keeps printing normally.

```
iPhone / Mac / PC ──A4 sheet──▶ Label Crop ──crop + rotate──▶ 4x6 PDF ──▶ your label printer
```

- Runs as one Docker container (Unraid Community Applications template included).
- AirPrint built in: the queues show up on iPhone, iPad and Mac with no app.
- Keeps the label as vectors, so barcodes stay sharp. No raster blur.
- Label size, padding and rotation are configurable (4x6 by default; 100x150 mm, 4x4 and others work).
- Free software under the GPL-3.0.

## Two ways to install

| | **All-in-one container** (recommended) | **Add-on for an existing CUPS server** |
|---|---|---|
| For | Unraid, Docker, new setups | A Raspberry Pi, Linux box or CUPS container you already run |
| What you get | CUPS + AirPrint + the crop queue in one image | Just the crop queue, filter and backend added to your CUPS |
| Updates | Pull the new image | Re-run the installer |
| Jump to | [Install on Unraid](#install-on-unraid), [docker run / Compose](#install-with-docker-run--compose) | [Add-on install](#add-on-for-an-existing-cups-server) |

## Supported printers

Any printer CUPS can drive that takes 4x6 (or your chosen size) labels:

| Brand | How to get a driver |
|---|---|
| Zebra (ZPL/EPL), most ZPL clones | Built in: pick *Zebra ZPL Label Printer* in the CUPS UI (`drv:///sample.drv/zebra.ppd`) |
| DYMO LabelWriter (incl. 4XL) | Built in (`printer-driver-dymo`) |
| Brother QL / P-touch | Built in (`printer-driver-ptouch`) |
| Rollo, Munbyn, iDPRT, HPRT, Phomemo, ... | Vendor Linux driver: drop it into `/config/drivers` ([below](#driver-drop-in)) |
| SATO (CG4, CL4NX, ...) | Vendor Linux driver `.deb` into `/config/drivers` |
| Driverless IPP Everywhere / AirPrint printers | Built in: choose *IPP Everywhere* |

If a printer already does AirPrint and accepts 4x6 PDFs, you can point the crop queue straight at it too.

## How it works

The crop queue uses a small CUPS filter (`label-crop`) and backend (`labelcrop`):

1. The filter reads the PDF content stream and looks for an embedded Form or Image XObject whose size is close to the label size (this is how carrier PDFs from Vinted, InPost and Evri place the label). It picks the best match, adds a little padding, and rotates it upright if it lies sideways.
2. If no such object exists (flattened or scanned PDFs), it renders the page and looks for the label-sized block of ink.
3. The crop is placed on an exact label page (288 x 432 pt for 4x6) and the backend forwards it to your real printer queue (`TARGET_PRINTER`) with a matching media size.

Sheets with no label are rejected with a clear message in the job log, instead of printing a shrunken A4 page.

## Install on Unraid

1. In **Apps** (Community Applications), search for **cups-label-crop** and click Install.
   *Before it is listed in CA*, install the template by hand from the Unraid terminal, then use **Docker > Add Container** and pick *cups-label-crop* from the Template list:

   ```bash
   wget -O /boot/config/plugins/dockerMan/templates-user/my-cups-label-crop.xml \
     https://raw.githubusercontent.com/Dyingmisery/cups-label-crop/main/templates/cups-label-crop.xml
   ```
2. Set **CUPS admin password**. Leave Network on **host** (needed for AirPrint).
3. Set **Target printer queue** to the name you will give your label printer (default `Label_Printer`).
4. Apply, then open the WebUI (`http://YOUR-SERVER:631`) and [add your printer](#adding-your-label-printer).

Settings, printers and drivers live in `/mnt/user/appdata/cups-label-crop`, so they survive updates.

> If another CUPS container (for example anujdatar/cups) already uses port 631 on the host, stop it first, or move its printers over. Two CUPS servers cannot share port 631 on host networking.

## Install with docker run / Compose

```bash
docker run -d --name cups-label-crop \
  --network host \
  --restart unless-stopped \
  -e CUPSADMIN=admin -e CUPSPASSWORD='change-me' \
  -e TARGET_PRINTER=Label_Printer \
  -e TZ=Europe/London \
  -v /srv/cups-label-crop:/config \
  --device /dev/bus/usb \
  ghcr.io/dyingmisery/cups-label-crop:latest
```

See [`docker-compose.yml`](docker-compose.yml) for the Compose version. Images are published for `linux/amd64` and `linux/arm64` (Raspberry Pi 4/5 with a 64-bit OS). Drop `--device /dev/bus/usb` for a network-only printer.

## Settings

| Variable | Default | What it does |
|---|---|---|
| `CUPSADMIN` / `CUPSPASSWORD` | `admin` / `admin` | Login for the CUPS web UI admin pages. Change the password. |
| `TARGET_PRINTER` | `Label_Printer` | Queue name of your real label printer. Cropped labels go here. No spaces. |
| `CROP_QUEUE_NAME` | `Label_Crop` | Queue name of the crop queue. No spaces. |
| `CROP_QUEUE_DISPLAY_NAME` | `Label Crop` | Name shown in print dialogs (e.g. `Vinted Label`). |
| `LABEL_WIDTH_IN` / `LABEL_HEIGHT_IN` | `4` / `6` | Output label size in inches. 100x150 mm = `3.937` / `5.906`. Width larger than height gives a landscape label. |
| `PADDING_PT` | `3` | Margin kept around the detected label, in points (72 pt = 1 in). |
| `ROTATE_MODE` | `auto` | `auto` stands sideways labels upright. `0`, `90`, `180`, `270` force a clockwise rotation. |
| `DEFAULT_SHEET` | `A4` | Sheet size the crop queue advertises (`A4` or `Letter`), so phones send the full page. |
| `PRINTER_URI` | *(empty)* | Optional: create `TARGET_PRINTER` automatically on first start, e.g. `socket://192.168.1.50:9100`. |
| `PRINTER_PPD` | *(empty)* | Optional, with `PRINTER_URI`: a PPD file path (`/config/drivers/ppd/x.ppd`) or a model from `lpinfo -m`. Empty + `ipp://` URI = IPP Everywhere. |
| `PRINTER_DISPLAY_NAME` | *(empty)* | Optional display name for the auto-created printer. |
| `TARGET_MEDIA` | *(auto)* | Force the media name sent to the target printer, e.g. `w288h432`. |
| `ENABLE_AVAHI` | `true` | Advertise printers over Bonjour/mDNS (AirPrint). |
| `CUPS_LOG_LEVEL` | `warn` | `debug` while troubleshooting. |
| `TZ` | `Etc/UTC` | Timezone (Unraid sets it for you). |

The crop queue is re-created from these settings at every start; your own printers are never changed after they exist.

## Add-on for an existing CUPS server

Already have CUPS working? The add-on adds one **Label Crop** queue to it and leaves everything else alone.

### Safety first

The installer was written so it cannot mess up a working CUPS setup:

- **It looks before it changes anything.** All checks run first: root, CUPS binaries and folders, cupsd running, Python and pikepdf, your target queue, and name clashes. If any check fails, it stops and changes nothing.
- **`--dry-run` shows every step** and changes nothing. Always run that first.
- **It only adds things.** It never edits `cupsd.conf`, `cups-files.conf` or `printers.conf` by hand, never touches your other queues, and never restarts CUPS. Its own queue is created with `lpadmin` and its own PPD.
- **It never overwrites anything it didn't install.** If a file or queue with its name already exists and isn't from cups-label-crop, it stops.
- **It backs up first.** `/etc/cups` (tarball), `lpstat -v`, `cupsctl` settings and PPD checksums go to `/var/backups/cups-label-crop/<timestamp>/`, with restore steps in `RESTORE.txt`.
- **It keeps a manifest.** Every file (with its SHA-256), the queue and any setting it created are recorded in `/var/lib/cups-label-crop/manifest`. Re-running it upgrades only those files. `--uninstall` removes only those items and keeps the backups.
- **It checks its work.** After installing, it compares every other queue's URI, PPD checksum and options with the snapshot from before, and warns loudly (with restore steps) if anything differs. It then test-crops a sample sheet as the CUPS filter user.
- **It leaves server settings alone.** If printer sharing is off, it tells you how to turn it on instead of doing it. `--enable-sharing` uses `cupsctl --share-printers` and is recorded, so `--uninstall` turns sharing off again.
- **It doesn't touch your system Python.** If pikepdf is missing, it goes into a private venv in `/opt/cups-label-crop/venv`, or into your distro's package with `--install-deps`. It always asks first, unless you pass `--yes`.

### Install

Download, read, dry-run, then install. Please don't pipe it into a shell.

```bash
# 1. Get a release (or: git clone https://github.com/Dyingmisery/cups-label-crop)
curl -fLO https://github.com/Dyingmisery/cups-label-crop/archive/refs/tags/v0.1.0.tar.gz
sha256sum v0.1.0.tar.gz                     # must match "v0.1.0.tar.gz" under Checksums in the release notes
tar xzf v0.1.0.tar.gz && cd cups-label-crop-0.1.0

# 2. Check the files, and read the script
sha256sum -c addon/SHA256SUMS               # every line must say OK
sha256sum addon/install.sh                  # must match the addon/install.sh line in the release notes
less addon/install.sh

# 3. See exactly what it would do. Nothing is changed.
lpstat -v                                   # find your label printer's queue name
sudo bash addon/install.sh --dry-run --target Label_Printer

# 4. Install
sudo bash addon/install.sh --target Label_Printer
```

The installer also checks the files against `addon/SHA256SUMS` itself and refuses to run if they don't match.

| Option | Default | |
|---|---|---|
| `--target QUEUE` | *(required)* | Your existing label printer queue |
| `--name NAME` / `--display-name TEXT` | `Label_Crop` / `Label Crop` | Crop queue name and the name phones show |
| `--size WxH` | `4x6` | Label size in inches |
| `--padding PT` / `--rotate MODE` | `3` / `auto` | Same as `PADDING_PT` / `ROTATE_MODE` |
| `--sheet A4\|Letter` | `A4` | Sheet size the crop queue advertises |
| `--allow-missing-target` | | Install before the printer is added (jobs wait until it exists) |
| `--enable-sharing` | | Turn on CUPS printer sharing (reverted by `--uninstall`) |
| `--install-deps` / `--no-venv` | | Python libraries from the distro instead of a venv / never make a venv |
| `--dry-run`, `--yes` | | Show the plan only / don't ask |

Remove it with `sudo bash addon/install.sh --uninstall` (add `--remove-venv` to delete the venv too). Distro packages installed with `--install-deps` are left in place, since other software may use them. The uninstaller tells you their names.

### In a CUPS container (anujdatar/cups, olbat/cupsd, ...)

```bash
docker cp cups-label-crop-0.1.0 cups:/tmp/cups-label-crop
docker exec -it cups bash /tmp/cups-label-crop/addon/install.sh --dry-run --target Label_Printer
docker exec -it cups bash /tmp/cups-label-crop/addon/install.sh --target Label_Printer --install-deps
```

The installer detects the container and warns you. The filter and backend live in the container's own filesystem, so **they disappear when the container is recreated** (for example on an image update), while the queue in a persisted `/etc/cups` remains. Re-run the same command after each update: it recognises its own queue and puts the files back. For Docker and Unraid, the [all-in-one image](#install-on-unraid) avoids this completely.

## Adding your label printer

1. Open `http://YOUR-SERVER:631`, then **Administration > Add Printer**, and log in with `CUPSADMIN` / `CUPSPASSWORD`.
2. Pick the printer: network printers appear under *Discovered Network Printers*, or choose *AppSocket/HP JetDirect* and enter `socket://PRINTER-IP:9100`. USB printers appear when `/dev/bus/usb` is passed through.
3. **Name** it exactly the `TARGET_PRINTER` value (default `Label_Printer`). The *Description* can be anything, like `Label Printer`.
4. Choose the driver (Zebra ZPL, DYMO, your vendor's PPD, ...).
5. In **Set Default Options**, set the media to 4x6 / 101.6 x 152.4 mm, and set the media type to labels with gap sensing (die-cut labels with gaps between them; use *mark* for black-mark stock or *continuous* for plain rolls). Darkness and speed are worth a few test prints.
6. Print a test: `docker exec cups-label-crop lp -d Label_Crop /usr/share/cups-label-crop/test/mock-vinted-a4-landscape.pdf`

Or skip the UI with `PRINTER_URI` + `PRINTER_PPD`, for example a Zebra on the network:

```
PRINTER_URI=socket://192.168.1.50:9100
PRINTER_PPD=drv:///sample.drv/zebra.ppd
```

## Driver drop-in

Vendor drivers are not bundled (licensing, and there are hundreds). Put them in the `drivers` folder of the config path, `/mnt/user/appdata/cups-label-crop/drivers` on Unraid:

| Put this in `/config/drivers` | What happens at every container start |
|---|---|
| `*.deb` | Installed with apt (dependencies are fetched if needed). Already installed versions are skipped. |
| `*.ppd`, `*.ppd.gz` (or in `drivers/ppd/`) | Copied into the CUPS model list, so they show up in *Add Printer*. |
| `install.sh` | Run as root, for vendor installers that are a tarball or script. |

Because this runs at every start, drivers come back automatically after an image update. Restart the container after adding a driver.

Example, SATO CG412: SATO's Linux driver download contains `satodriver-<version>-linux-4.15-x86_64.deb` (plus `.rpm` and `.tar.gz`; only the `.deb` is needed):

```bash
cp satodriver-*-x86_64.deb /mnt/user/appdata/cups-label-crop/drivers/
docker restart cups-label-crop
docker logs cups-label-crop | grep -i driver
```

Then add the printer in the web UI (*Make: SATO*, model *CG412*) or set `PRINTER_URI=socket://PRINTER-IP:9100` and `PRINTER_PPD=sato/sato-cg412.ppd`. Vendor packages built for `x86_64`/`amd64` only install on amd64 hosts.

Prefer a big all-in-one image? Build with Debian's `printer-driver-all` (adds about 300 packages):

```bash
docker build --build-arg INSTALL_ALL_DRIVERS=true -t cups-label-crop:all-drivers .
```

## Printing from iPhone and iPad (AirPrint)

On the same network, both queues appear in the print dialog automatically:

- **Label Crop**: print the carrier's original A4/Letter PDF here (from the Vinted app's share sheet, Files, Mail or Safari). Leave the paper size as it is; the server does the cropping.
- **Your label printer** (e.g. *Label Printer*): for PDFs that are already 4x6.

Do not send an A4 sheet directly to the label printer: iOS would shrink the whole page onto the label.

Mac and Android (Mopria / default print service) find the queues the same way. On Windows 10/11, *Add a printer by address* with `http://YOUR-SERVER:631/printers/Label_Crop`; Windows uses its built-in IPP class driver.

## Printing remotely over Tailscale

AirPrint discovery uses Bonjour (multicast), which does not cross Tailscale, so the printers will not appear on their own away from home. Add them by address with a configuration profile instead:

1. Install Tailscale on the server (on Unraid: the Tailscale plugin) and on the phone. Note the server's Tailscale IP (`100.x.y.z`) or MagicDNS name.
2. Make the profile (on any computer with Python 3):

   ```bash
   python3 tools/make-airprint-profile.py 100.x.y.z Label_Crop Label_Printer -o label-printers.mobileconfig
   ```

   This writes a standard `com.apple.airprint` payload pointing at `/printers/Label_Crop` and `/printers/Label_Printer` on port 631. (Apple Configurator on a Mac can make the same profile: *AirPrint > add IP + resource path*.)
3. Send the `.mobileconfig` to the phone (AirDrop, iCloud Drive/Files or email), tap it, then go to **Settings > Profile Downloaded > Install**. iOS warns that it is unsigned; that is expected for a profile you made.
4. With Tailscale connected, the printers appear in the print dialog anywhere.

The profile hard-codes the address. If the Tailscale IP changes, make and install a new one (MagicDNS names avoid that). Tailscale ACLs must allow the phone to reach TCP 631 on the server.

## Testing without a printer

```bash
# crop a sheet on the server and look at the result
docker exec cups-label-crop label-crop /config/Vinted.pdf /config/Vinted-4x6.pdf
```

`label-crop` also takes `--width-in`, `--height-in`, `--padding-pt` and `--rotate`. Real labels contain addresses, so delete the copies when you are done.

## Troubleshooting

| Problem | What to check |
|---|---|
| Printer does not show on iPhone | Container must use **host** networking. Phone and server on the same LAN/VLAN (mDNS does not cross VLANs without a reflector). `docker exec cups-label-crop avahi-browse -rt _ipp._tcp` should list *Label Crop*. |
| Job stuck: *target queue 'Label_Printer' does not exist* | Add your printer with exactly the `TARGET_PRINTER` name, or change the setting. Jobs retry every 30 s. |
| *no 4x6 in label found* | The sheet has no label-sized block (or a different size). Try `LABEL_WIDTH_IN`/`LABEL_HEIGHT_IN` for your carrier, open an issue with an anonymised sample. |
| *job arrived as Apple URF raster, not PDF* | iOS rasterised the page (e.g. printed from Photos or a screenshot). Print the original PDF from Files, Safari, Mail or the seller app. |
| Label prints upside down or sideways | Set `ROTATE_MODE` (try `90` or `270`), or check the printer's own orientation setting. |
| Label is tiny / has big margins | Set the target printer's default media to 4x6 in the CUPS UI; the crop output is exact, so margins come from the printer settings. |
| Label prints across two labels or drifts | Calibrate the printer's gap sensor (media type *gap*/*web*), set the label size in the printer options. |
| Faint or too dark print | Adjust *Darkness* in the printer's default options. |
| Admin login refused | Use `CUPSADMIN`/`CUPSPASSWORD` from the container settings. Logs: `docker logs cups-label-crop`, and `/var/log/cups/error_log` inside the container (`CUPS_LOG_LEVEL=debug` for detail). |
| *Printer drivers are deprecated* warning | Harmless message from CUPS 2.4 about PPD drivers. They still work. |
| Port 631 already in use | Another CUPS (container or host service) is running. Stop it. |
| Unraid's own Avahi | Unraid runs Avahi for SMB discovery. The container runs its own Avahi on host networking, as other CUPS containers on Unraid do. If discovery misbehaves, check `docker logs` for Avahi errors, and restart the container after the array starts. |

## Development

```bash
bash tests/run-tests.sh                     # cropper unit tests (needs python3-pikepdf, poppler-utils)
bash tests/addon/run-matrix.sh              # add-on installer safety tests in throwaway containers
./tools/update-addon-checksums.sh           # after changing the add-on or src/ files
docker build -t cups-label-crop:dev .
IMAGE=cups-label-crop:dev bash tests/container-test.sh   # end-to-end: queues, forwarding, persistence, drivers, AirPrint
```

Mock sheets are in `tests/fixtures` (generated by `make_mocks.py`; all names and addresses are fake). Please never commit real labels.

## Credits and license

The label detection approach (finding the label-sized XObject in the content stream, its scoring window and the 270-degree rotation rule) comes from **[dodopus/vinted-label-4x6](https://github.com/dodopus/vinted-label-4x6)** by dodopus, licensed GPL-3.0. Thank you! This project is an independent Python rewrite for CUPS that follows the same approach and adds an ink-based fallback, configurable sizes and the print server around it.

cups-label-crop is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License version 3** (or, at your option, any later version). See [LICENSE](LICENSE). It comes with no warranty.

Not affiliated with Vinted, InPost, Evri, Apple or any printer maker. Trademarks belong to their owners.
