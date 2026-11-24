# Submitting to Unraid Community Applications

CA submissions now go through **https://ca.unraid.net/submit** (sign in with your Unraid account). The site validates and scans the GitHub repo, checks for duplicates, and a moderator reviews it. Approved apps appear after the next catalog build. A forum support thread is not strictly required (a GitHub support URL satisfies the rule), but CA expects apps to be supported, so open one.

## What the repo already has

| Requirement | File |
|---|---|
| Public, active GitHub repo | *(after publishing)* |
| OSI-approved license at the root | `LICENSE` (GPL-3.0) |
| `ca_profile.xml` at the root with a non-empty `<Profile>` | `ca_profile.xml` |
| One Docker template XML per app | `templates/cups-label-crop.xml` |
| Public image the template points at | `ghcr.io/dyingmisery/cups-label-crop:latest` *(after step 2 of PUBLISHING.md)* |
| Icon | `assets/icon.png` (512x512), raw URL in the template and profile |

## Steps

1. Finish [PUBLISHING.md](PUBLISHING.md): repo public, image built, **GHCR package public**, and a clean install from the template on a real Unraid server.
2. Open the support thread on the forum (draft below): https://forums.unraid.net/forum/47-docker-containers/ , *Start new topic*, title `[Support] cups-label-crop`.
3. Put the thread URL in two places, commit and push:
   - `templates/cups-label-crop.xml`: change `<Support>` to the thread URL (keep GitHub issues in the README).
   - `ca_profile.xml`: uncomment `<Forum>` and paste the URL.
4. Go to https://ca.unraid.net/submit/new, sign in, enter `https://github.com/Dyingmisery/cups-label-crop`.
5. Run **Validate** and **Scan**; fix anything reported (re-run after each XML change).
6. Submit. Watch the thread and GitHub issues; reviewers may ask questions there.

After it is listed, template changes go live on the next CA catalog build. Bump nothing else; CA reads the XML from `main`.

## Support thread draft

**Title:** `[Support] cups-label-crop – print Vinted/InPost/Evri A4 labels as 4x6 on any label printer`

> **cups-label-crop** is a CUPS print server with AirPrint and a "Label Crop" queue for sellers.
>
> Vinted (InPost, Evri, Royal Mail...) and many marketplaces send shipping labels as a PDF with the label on an A4 sheet. Print that sheet to **Label Crop** from your phone or computer and the container finds the label, crops it, turns it upright and sends a sharp 4x6 label to your thermal printer. No app, no website, no manual cropping.
>
> - Works with any CUPS label printer: Zebra, Rollo, Munbyn, SATO, DYMO, Brother and others
> - AirPrint built in, so it shows up on iPhone/iPad/Mac on your network
> - Vendor drivers: drop the `.deb` in `appdata/cups-label-crop/drivers` and it is installed at every start, so it survives updates
> - Configurable label size (4x6, 100x150 mm, 4x4...), padding and rotation
> - amd64 and arm64 images
> - GPL-3.0. Label detection is based on [dodopus/vinted-label-4x6](https://github.com/dodopus/vinted-label-4x6), thanks dodopus!
>
> **Setup**
> 1. Install from CA. Keep Network = host (needed for AirPrint) and set an admin password.
> 2. Open the WebUI (port 631) and add your label printer named `Label_Printer` (or whatever you set in *Target printer queue*). Set its default media to 4x6.
> 3. On your phone, print the carrier's A4 PDF to **Label Crop**.
>
> Remote printing over Tailscale and the iOS profile are covered in the README.
>
> **Links:** GitHub: https://github.com/Dyingmisery/cups-label-crop · Image: `ghcr.io/dyingmisery/cups-label-crop`
>
> **When asking for help, please post:** your printer model and how it is connected, the container log (`docker logs cups-label-crop`), and the job's message from the CUPS web UI (*Jobs* tab). If a label is detected wrongly, an anonymised sample PDF helps a lot. **Please do not post real labels; they contain names and addresses.**
>
> Note: if you already run another CUPS container on host networking, stop it first, as both need port 631.
