# cups-label-crop add-on

`install.sh` adds the Label Crop queue to a CUPS server you already run. It is additive only, backs up `/etc/cups` first, keeps a manifest, and has `--dry-run` and `--uninstall`.

Full instructions and the safety guarantees are in the main README: [Add-on for an existing CUPS server](../README.md#add-on-for-an-existing-cups-server).

```bash
sudo bash addon/install.sh --help
sudo bash addon/install.sh --dry-run --target Label_Printer
```

The add-on needs the whole repository (or a release tarball), not just this script: it installs `src/label-crop`, `src/labelcrop` and `src/label-crop.ppd`, and checks them against `SHA256SUMS`.
