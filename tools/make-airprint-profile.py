#!/usr/bin/env python3
"""Make an iOS/iPadOS .mobileconfig that adds AirPrint printers by address.

Use it to print to cups-label-crop over Tailscale (or any VPN), where Bonjour
discovery does not reach your phone.

  python3 tools/make-airprint-profile.py YOUR-TAILSCALE-IP Label_Crop Label_Printer -o label-printers.mobileconfig

Part of cups-label-crop. GPL-3.0-or-later.
"""
import argparse
import plistlib
import sys
import uuid


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("host", help="server address the phone can reach, e.g. a Tailscale 100.x IP or MagicDNS name")
    ap.add_argument("queues", nargs="+", help="CUPS queue names, e.g. Label_Crop Label_Printer")
    ap.add_argument("--port", type=int, default=631)
    ap.add_argument("--tls", action="store_true", help="force TLS (ipps); CUPS uses a self-signed certificate")
    ap.add_argument("--name", default="cups-label-crop printers", help="profile name shown in Settings")
    ap.add_argument("-o", "--output", default="-", help="output file (default stdout)")
    args = ap.parse_args()

    printers = [
        {"IPAddress": args.host, "ResourcePath": f"/printers/{q}", "Port": args.port, "ForceTLS": bool(args.tls)}
        for q in args.queues
    ]
    ident = "io.github.cups-label-crop.airprint." + uuid.uuid4().hex[:12]
    payload = {
        "PayloadType": "com.apple.airprint",
        "PayloadVersion": 1,
        "PayloadIdentifier": ident + ".printers",
        "PayloadUUID": str(uuid.uuid4()).upper(),
        "PayloadDisplayName": "AirPrint",
        "AirPrint": printers,
    }
    profile = {
        "PayloadType": "Configuration",
        "PayloadVersion": 1,
        "PayloadIdentifier": ident,
        "PayloadUUID": str(uuid.uuid4()).upper(),
        "PayloadDisplayName": args.name,
        "PayloadDescription": "Adds AirPrint printers served by cups-label-crop at " + args.host,
        "PayloadRemovalDisallowed": False,
        "PayloadContent": [payload],
    }
    data = plistlib.dumps(profile, fmt=plistlib.FMT_XML)
    if args.output == "-":
        sys.stdout.buffer.write(data)
    else:
        with open(args.output, "wb") as fh:
            fh.write(data)
        print(f"wrote {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
