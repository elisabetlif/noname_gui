# noname_gui

A visual interface for noname, a tool for verifying privacy in security 
protocols developed at DTU.

## Platform support

**macOS (Apple Silicon)**: fully supported — uses `noname-macos`.

**Linux (x86_64)**: fully supported — uses `noname-linux`.

**Windows**: the noname binary only runs on Linux. Windows users must 
use **WSL2** and follow the Linux instructions. The `noname-linux` 
binary will be used automatically inside WSL.

**Note**: Intel Mac (x86_64) is not currently supported as no binary is included. Users with an Intel Mac would need to compile noname from 
source.
---

## Background

### What is (α, β)-privacy?

noname checks whether a protocol satisfies **(α, β)-privacy** — a formal 
definition of privacy that asks: does an attacker learn more than they are 
supposed to?

The two core concepts are:

- **α (alpha)** — what the attacker is *allowed* to know. For example, in a 
voting protocol α might say the attacker knows the final election result but 
nothing about individual votes
- **β (beta)** — what the attacker *actually* learns from observing the 
protocol's messages

A **privacy violation** occurs when β allows the attacker to rule out 
possibilities that α should have kept open — the attacker has learned more 
than they should. noname checks this automatically by exploring all possible 
protocol runs up to a given bound and testing each one for violations.

### What is a protocol specification?

noname takes a `.nn` file as input. This describes a security protocol as a 
set of **transactions** — the atomic steps that protocol participants can 
execute. Each transaction has three phases:

- **Left** — non-deterministic choices are made and the intruder delivers a 
message
- **Center** — the protocol does its internal work: decryption, condition 
checks, memory reads
- **Right** — the protocol sends a response and writes to memory

The protocol also has **memory cells** — persistent storage that carries 
information between transactions.

### How does the intruder store information? The FLIC

The intruder's knowledge is stored in a **FLIC (Framed Lazy Intruder 
Constraints)**:

- Messages the intruder **receives** are marked with `-l`
- Messages the intruder **sends** are marked with `+R` (recipes) — a recipe 
describes how the intruder computes a new message from what they already know

There can be several parallel FLICs running at the same time when multiple 
possibilities are being tracked simultaneously — for example when the intruder 
cannot tell which branch of an `if/then/else` was taken.

### Intruder experiments

The intruder can test privacy by choosing two recipes and checking whether 
they produce the same message across all parallel FLICs. If the outcome 
differs across FLICs, the intruder can distinguish between possibilities and 
potentially rule out models of the privacy variables — leading to a privacy 
violation.

---

## The interface

### The tree

noname explores all possible protocol runs by building a tree of **symbolic 
states**. Each symbolic state is a snapshot of the execution — it captures 
what the intruder knows, what possibilities they are tracking, and the current 
memory. The GUI makes this tree visible and lets you walk through it step by 
step.

For example:
<img width="592" height="642" alt="tree_gui(1)" src="https://github.com/user-attachments/assets/5352f353-3881-418d-b887-cec505ec6dfe" />

| Node type | Appearance | Action |
|---|---|---|
| Start | Green circle labelled *Start* | — |
| Chosen path | Green circle | Click to rewind to that point |
| Available next choices | Full-size grey circle | Click to proceed |
| Past unchosen options | Small grey circle | Click to go back and take that branch |

### Making choices

At each step you may face one of three kinds of choice:

**Transactions** — which transaction fires next, for example `ReceivePrivateKey` 
or `Server`.

**Try/Catch** — when a decryption is attempted the execution splits:
- `Try X15=l1` — the decryption succeeds using this recipe
- `Catch X15≠inv(pk(x1))` — the decryption fails

**Equivalences** — when the intruder compares two recipes:
- `l4=no` — the two recipes produce the same message
- `l4≠no` — the two recipes produce different messages
  
For example:
<img width="1099" height="820" alt="full_gui" src="https://github.com/user-attachments/assets/d71d5137-7102-49d3-b575-f6afca636d0a" />

### The detail panel

Clicking a node populates the detail panel with the current execution state. 
Use **Previous** and **Next** to step through the individual phases of the 
transaction.
an example:
<img width="486" height="656" alt="detail_panel" src="https://github.com/user-attachments/assets/1a73a80e-da7e-43b7-9b8a-a8d8b482c3f5" />


| Field | Description |
|---|---|
| Executed | Which transactions have run so far |
| α | What the intruder is allowed to know |
| β | What the intruder actually knows |
| γ | The ground truth of what actually happened |
| Recipe choice | The intruder's toolkit — messages observed so far |
| Checked | Intruder experiments already performed and resolved |
| Transition | Plain language summary of the most recent action |

The **table** at the bottom shows the parallel possibilities the intruder is 
tracking, one column per possibility:

- **FLIC** row — messages observed in each possibility (`-l` received, 
`+R` sent)
- **Process** row — remaining process to execute in each possibility
- **Analysis** row (highlighted red) — intruder experiments are happening 
here. The intruder is comparing what the protocol sent across possibilities 
to try to distinguish between them

another example with intruder experiments:
<img width="425" height="671" alt="detail_panel_intruder(1)" src="https://github.com/user-attachments/assets/01b94b64-6456-4a0c-b49b-912b0a888143" />

---

## Outcomes

### Privacy violation

If a privacy violation is found, the tree stops and **α** and **β** are 
highlighted in red. The intruder has learned more than α permits — for example, 
they determined the exact value of a privacy variable that α only allowed them 
to know the domain of.

an example:
<img width="1094" height="787" alt="gui_privacy_violation" src="https://github.com/user-attachments/assets/7a425403-f733-466f-a56f-18e152793477" />


### Bound reached

If the bound is reached with no violation found, the tree stops and a message 
is shown. This does **not** mean the protocol is fully secure — it means no 
violation was found within the set bound. A higher bound might still reveal 
one.

an example:
<img width="1100" height="754" alt="bound_reached" src="https://github.com/user-attachments/assets/e8817e2b-45c8-4fd2-856a-1ba46f0136b6" />

---

## Automatic mode

Click **Run noname (automatic mode)** to let noname find a violation 
automatically. noname explores the full tree and reports the first violation 
it finds. The GUI then replays the path through the tree and shows the same 
result you would have reached by walking through interactively. If no 
violation is found within the bound, a message is shown instead.

---

## Requirements

- Python 3.10 or newer
- A `.nn` protocol specification file
- GHC 9.6.7 and Cabal (only needed if building noname from source — 
  pre-built binaries for macOS arm64 and Linux x86_64 are included)
---

## Installation

---

### macOS and Linux

**1. Install Python dependencies:**

```bash
pip install dearpygui pexpect
```

If you get an `externally-managed-environment` error, use a virtual 
environment:

```bash
python3 -m venv ~/noname_venv
source ~/noname_venv/bin/activate
pip install dearpygui pexpect
```

**2. Install cvc5:**

> **Important**: do not use your package manager to install cvc5 — the 
> packaged version is too old and incompatible with this version of noname. 
> Install the binary from GitHub instead:

```bash
wget https://github.com/cvc5/cvc5/releases/download/cvc5-1.2.0/cvc5-Linux-x86_64-static.zip
unzip cvc5-Linux-x86_64-static.zip
sudo cp cvc5-Linux-x86_64-static/bin/cvc5 /usr/local/bin/cvc5
sudo chmod +x /usr/local/bin/cvc5
cvc5 --version
```

On **macOS**, download the macOS release instead:

```bash
wget https://github.com/cvc5/cvc5/releases/download/cvc5-1.2.0/cvc5-macOS-arm64-static.zip
```

**3. Make noname executable:**

```bash
chmod +x ./noname
```

**4. Install fonts** (Linux only — needed for symbols like α, β, γ, ∨, ⊤):

```bash
# Ubuntu/Debian/WSL
sudo apt install fonts-dejavu

# Arch Linux
sudo pacman -S ttf-dejavu
```

The GUI loads fonts automatically based on your OS:

| OS | Font used |
|---|---|
| macOS | Arial Unicode or Geneva |
| Linux | DejaVu Sans |

If no suitable font is found, a warning is printed, and some symbols may 
not display correctly.

**5. Run the GUI:**

```bash
cd path/to/noname_tool
python3 gui.py examples/bac/bac.nn
```
*For testing purposes, we recommend using .nn files from the /examples folder
---

### Windows (WSL2)

The noname binary is a Linux binary and cannot run natively on Windows. 
You must use WSL2.

**1. Install WSL2:**

Open PowerShell as Administrator:

```powershell
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
```

Restart, then:

```powershell
wsl --set-default-version 2
wsl --install -d Ubuntu
```

All remaining steps should be run inside the Ubuntu WSL terminal.

**2. Install Python and system dependencies:**

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install python3 python3-pip python3-venv fonts-dejavu -y
```

**3. Create a virtual environment:**

```bash
python3 -m venv ~/noname_venv
source ~/noname_venv/bin/activate
pip install dearpygui pexpect
```

Add to `~/.bashrc` so the venv and PATH are set on every new terminal:

```bash
echo 'source ~/noname_venv/bin/activate' >> ~/.bashrc
echo 'export PATH=/usr/local/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

**4. Install cvc5:**

> **Important**: do not use `apt install cvc5` — the apt version is too old. 
> Install the binary from GitHub instead:

```bash
wget https://github.com/cvc5/cvc5/releases/download/cvc5-1.2.0/cvc5-Linux-x86_64-static.zip
unzip cvc5-Linux-x86_64-static.zip
sudo cp cvc5-Linux-x86_64-static/bin/cvc5 /usr/local/bin/cvc5
sudo chmod +x /usr/local/bin/cvc5
cvc5 --version
```

**5. Navigate to the project and make noname executable:**

```bash
cd /mnt/c/Users/<your_username>/path/to/noname_tool
chmod +x ./noname
```

**6. Run the GUI:**

```bash
source ~/noname_venv/bin/activate
cd /mnt/c/Users/<your_username>/path/to/noname_tool
python3 gui.py examples/bac/bac.nn
```
*For testing purposes, we recommend using .nn files from the /examples folder
---

## Troubleshooting

**`pexpect not found`:**
```bash
pip install pexpect
```

**`cvc5: command not found`** — make sure `/usr/local/bin` is on PATH:
```bash
echo 'export PATH=/usr/local/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

**`externally-managed-environment` error from pip** — use a virtual 
environment:
```bash
python3 -m venv ~/noname_venv
source ~/noname_venv/bin/activate
pip install dearpygui pexpect
```

**`Exec format error` when running noname** — make sure you are using 
the correct binary for your platform. The repository includes:

- `noname-macos` — macOS arm64 (Apple Silicon)
- `noname-linux` — Linux x86_64

The GUI selects the correct binary automatically based on your OS. 
If you see this error, check that the correct binary is present and executable:

```bash
file ./noname-macos   # should say: Mach-O 64-bit arm64 executable
file ./noname-linux   # should say: ELF 64-bit LSB executable, x86-64
chmod +x ./noname-macos
chmod +x ./noname-linux
```

**Symbols appear as blank squares** — install DejaVu fonts:
```bash
# Ubuntu/Debian/WSL
sudo apt install fonts-dejavu

# Arch Linux
sudo pacman -S ttf-dejavu
```

**`GHC version mismatch` during build** — set the correct GHC version:
```bash
ghcup set ghc 9.6.7
ghc --version
```

**Python version error** — check your version:
```bash
python --version
```
Python 3.10 or newer is required.
