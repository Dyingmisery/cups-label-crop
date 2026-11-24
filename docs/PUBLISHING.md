# Publishing checklist

Nothing here has been run yet. Run these from a machine logged in to GitHub as **Dyingmisery** (`gh auth login`), in a clone of this folder.

## 1. Create the public repo and push

```bash
cd cups-label-crop
gh repo create Dyingmisery/cups-label-crop --public \
  --description "CUPS + AirPrint print server that crops Vinted/InPost/Evri A4 label sheets to 4x6 for thermal printers" \
  --homepage "https://github.com/Dyingmisery/cups-label-crop" \
  --source=. --remote=origin --push
gh repo edit Dyingmisery/cups-label-crop --add-topic unraid,cups,airprint,label-printer,vinted,thermal-printer,docker
```

The push to `main` starts **.github/workflows/docker.yml**: lint, an amd64 test build with the end-to-end tests, then a multi-arch (amd64 + arm64) build pushed to `ghcr.io/dyingmisery/cups-label-crop:latest`.

```bash
gh run watch            # follow the first workflow run
```

## 2. Make the GHCR package public

The first push creates the package as **private**. Unraid cannot pull it until it is public:

1. Open https://github.com/users/Dyingmisery/packages/container/cups-label-crop/settings
2. **Danger Zone > Change visibility > Public**, type the name to confirm.
3. Check from any machine without logging in: `docker pull ghcr.io/dyingmisery/cups-label-crop:latest`

(The `org.opencontainers.image.source` label links the package to the repo automatically, so the README shows on the package page.)

## 3. Cut a first release (optional, gives versioned tags)

```bash
git tag -a v0.1.0 -m "cups-label-crop 0.1.0"
git push origin v0.1.0
gh release create v0.1.0 --generate-notes
```

That publishes `:0.1.0`, `:0.1` and `:sha-xxxxxxx` tags in addition to `:latest`.

## 4. Test the published image on Unraid before submitting to CA

```bash
wget -O /boot/config/plugins/dockerMan/templates-user/my-cups-label-crop.xml \
  https://raw.githubusercontent.com/Dyingmisery/cups-label-crop/main/templates/cups-label-crop.xml
```

Docker > Add Container > Template: *cups-label-crop*. Install from the defaults, add the printer, print a real sheet.

Then follow [CA-SUBMISSION.md](CA-SUBMISSION.md).
