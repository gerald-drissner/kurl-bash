# KURL (YOURLS CLI) — v1.0
[![Version](https://img.shields.io/badge/version-1.0-blue.svg)](https://github.com/gerald-drissner/kurl-thunderbird-addon/releases)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Listed in Awesome YOURLS!](https://img.shields.io/badge/Awesome-YOURLS-C5A3BE)](https://github.com/YOURLS/awesome)

An advanced **Bash** CLI to shorten and manage URLs with [YOURLS](https://yourls.org).

* ✅ Linux (Arch/Debian/Fedora/openSUSE, etc.)
* ✅ macOS
* ✅ Windows (via WSL)
* 🔐 API key kept out of process list (POST via stdin)
* 🧰 Smart dependency checker/installer (`-i/--check`)
* 📋 Clipboard auto-copy (Wayland/X11/macOS/WSL)
* 📦 Batch mode (stdin or file)
* 🖼️ Optional QR code
* 🌐 Profiles for multiple YOURLS instances

![KURL CLI screenshot](https://github.com/gerald-drissner/kurl-bash/blob/main/assets/kurl-bash-screenshot.jpg))

---

## Features (v1.0)

* **Security & reliability**

  * All API calls use **POST** with form data via **stdin** (no API key in process args).
  * Sensible curl defaults: retries, timeouts, IPv4/IPv6 forcing, optional `--insecure`.
* **Great UX**

  * `--assume-https` for bare domains (`example.com` → `https://example.com`).
  * `--strict` to require explicit `http(s)://`.
  * `--open` to launch the new short URL in your browser.
  * `--qr` to print a terminal QR code (needs `qrencode`).
  * `--quiet`, `--verbose`, `--no-color` for scripting/logs.
* **Batching**

  * `--batch <file>` or pipe **stdin**; outputs TSV: `original<TAB>short`.
* **Cross-platform clipboard**

  * Wayland (`wl-clipboard`), X11 (`xclip`/`xsel`), macOS (`pbcopy`), WSL (`clip.exe`).
* **Multi-profile configs**

  * `--profile <name>` stores creds at `~/.config/yourls-cli/<name>.cfg`.

---

## Requirements

* **Core**: `bash`, `curl`, `jq`
* **Optional (clipboard)**:

  * Wayland: `wl-clipboard`
  * X11: `xclip` (or `xsel`)
  * macOS: `pbcopy` (built-in)
  * WSL: `clip.exe` (built-in)
* **Optional (QR)**: `qrencode`

Run the built-in checker anytime:

```bash
kurl -i
# or
kurl --check
```

It detects your platform/distro and can **prompt to install** missing pieces.

---

## Installation

### 1) Download

```bash
git clone https://github.com/gerald-drissner/kurl.git
cd kurl
```

### 2) Make executable

```bash
chmod +x kurl.sh
```

### 3) Move into PATH (recommended)

```bash
sudo mv kurl.sh /usr/local/bin/kurl
```

> Prefer calling the tool as `kurl`. If you keep the original filename, use `kurl.sh` in commands below.

---

## First run

The first run sets up your YOURLS host and signature key:

```bash
kurl
```

Your config is stored at:

```
~/.config/yourls-cli/default.cfg
```

Use multiple configs with profiles:

```bash
kurl --profile work
# stored at ~/.config/yourls-cli/work.cfg
```

---

## Quick start

### Shorten a URL

```bash
kurl https://example.com
```

### Shorten a bare domain (no scheme)

```bash
# prompts to interpret as https://example.com
kurl example.com

# skip prompt and assume https://
kurl --assume-https example.com
```

### Custom keyword and title

```bash
kurl https://someverylongurl.com -k test12 -t "Some title"
```

### JSON output (prints last API response)

```bash
kurl https://example.com -f json
# or: -f xml | -f simple
```

### Open the short link and copy to clipboard

```bash
# Enable autocopy once:
kurl --autocopy-on

# Then shorten & open:
kurl https://example.com --open
```

### Show a terminal QR code

```bash
kurl https://example.com --qr
# requires: qrencode
```

---

## Batch mode

Shorten many URLs from a file (one per line):

```bash
kurl --batch urls.txt
# outputs TSV to stdout:  <original>\t<short>
```

…or pipe stdin:

```bash
cat urls.txt | kurl
```

**Tip — only short URLs:**

```bash
kurl --batch urls.txt | cut -f2
```

---

## Manage existing short URLs

> You can pass either the keyword (`abc123`) or your full short URL.

### Stats

```bash
kurl abc123 -s
# or
kurl https://sho.rt/abc123 --statistics
```

### Expand to long URL

```bash
kurl abc123 -e
# or
kurl --expand https://sho.rt/abc123
```

### Delete

```bash
kurl abc123 -d
# prompts for confirmation
```

---

## Global & listing

### Global stats

```bash
kurl -g
# shows total links & clicks + top/bottom URLs
```

### Interactive list

```bash
kurl -l
# choose: XML/JSON, export to file, tabular view, top/bottom lists
```

---

## CLI reference

```
kurl <url>
kurl <shorturl-or-keyword> -s | -e | -d
```

**Shorten options**

* `-k, --keyword <KEYWORD>` – custom keyword
* `-t, --title <TITLE>` – custom title
* `--assume-https` – auto-prefix `https://` for bare domains
* `--strict` – require explicit `http(s)://` (no normalization)
* `--open` – open new short URL in browser
* `--qr` – print QR code (needs `qrencode`)
* `-f, --format <json|xml|simple>` – print last API response

**Manage existing**

* `-s, --statistics` – show stats for a short URL/keyword
* `-e, --expand` – expand to long URL
* `-d, --delete` – delete a short URL (with confirmation)

**Database**

* `-g, --global` – global YOURLS stats
* `-l, --list` – interactive list/export

**Batch**

* `--batch <file>` – shorten many URLs (or pipe stdin)

**Config & setup**

* `-i, --check` – check/install dependencies interactively
* `-c, --change-config` – re-enter host/key
* `--autocopy-on` / `--autocopy-off`
* `--profile <name>` – use `~/.config/yourls-cli/<name>.cfg`

**Output & network**

* `--quiet` / `--verbose` / `--no-color`
* `--ipv4` / `--ipv6` – force IP family
* `--insecure` – allow insecure TLS (curl `-k`)

**Help**

* `-h, --help` – usage screen
* `-v, --version` – version & environment info

---

## Clipboard behavior

* **Wayland**: uses `wl-clipboard` (`wl-copy`)
* **X11**: uses `xclip` (or `xsel`)
* **macOS**: uses `pbcopy` (built-in)
* **WSL**: uses `clip.exe` (built-in)

If no suitable tool is available, KURL continues and prints:

```
Note: No suitable clipboard tool detected (...). Skipping copy.
```

Install via `kurl -i` or your package manager:

* Arch: `sudo pacman -S wl-clipboard xclip`
* Debian/Ubuntu: `sudo apt-get install wl-clipboard xclip`
* Fedora/RHEL: `sudo dnf install wl-clipboard xclip`
* openSUSE: `sudo zypper install wl-clipboard xclip`

---

## Security notes

* The YOURLS `signature` (API key) is sent via **POST** body (stdin) and **never** appears in process lists.
* The config file lives under `~/.config/yourls-cli/` and permissions are set to `600`.
* Honors system proxies (`HTTP_PROXY`, `HTTPS_PROXY`, etc.). Use `--insecure` only if you know what you’re doing.

---

## Troubleshooting

* **“Please provide a URL to shorten”**
  Pass a full URL (`https://…`) or use `--assume-https` for bare domains like `example.com`.

* **Clipboard didn’t copy**
  Install a clipboard tool (`kurl -i`) or copy from the printed short URL.

* **Wayland/X11 confusion**
  If you switch sessions, install both: `wl-clipboard` and `xclip`.

* **Behind a strict proxy**
  Try `--ipv4` or `--ipv6`, and as a last resort `--insecure`.

---

## Development

* Single Bash file: `kurl.sh`
* Linting suggestions: `shellcheck`, `shfmt`
* Packaging ideas: AUR/Homebrew/Debian — PRs welcome.

---

## License

**MIT License** — see `LICENSE` for details.
