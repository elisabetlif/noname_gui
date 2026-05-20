# noname_gui

A visual interface for noname, 
a tool for verifying privacy in security protocols developed at DTU.

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

--------------------------------------------------------------------------------------------------------------------------

### The tree

noname explores all possible protocol runs by building a tree of **symbolic 
states**. Each symbolic state is a snapshot of the execution — it captures 
what the intruder knows, what possibilities they are tracking, and the current 
memory. The GUI makes this tree visible and lets you walk through it step by 
step.

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

---

## The detail panel

Clicking a node populates the detail panel with the current execution state. 
Use **Previous** and **Next** to step through the individual phases of the 
transaction.

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
- **Analysis** row (highlighted red) — intruder experiments are happening here. The intruder is comparing what the protocol sent across possibilities  to try to distinguish between them

---

## Outcomes

### Privacy violation

If a privacy violation is found the tree stops and **α** and **β** are 
highlighted in red. The intruder has learned more than α permits — for example, 
they determined the exact value of a privacy variable that α only allowed them 
to know the domain of.

### Bound reached

If the bound is reached with no violation found the tree stops and a message 
is shown. This does **not** mean the protocol is fully secure — it means no 
violation was found within the set bound. A higher bound might still reveal 
one.

---

## Automatic mode

Click **Run noname (automatic mode)** to let noname find a violation 
automatically. noname explores the full tree and reports the first violation 
it finds. The GUI then replays the path through the tree and shows the same 
result you would have reached by walking through interactively. If no 
violation is found within the bound, a message is shown instead.


-------------------------------------------------------------------------------------------------------------


### Requirements:<br>
-GHC 9.6.7 <br>
-Cabal <br>
-Python 3.10 or newer <br>
-a .nn file <br>


### Setup:
1. Install GHCup, the recommended way to install the Haskell toolchain: <br>
   **curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh**

2. Clone the repository <br>
   **git clone...**

3. cd into **noname_tool** <br>

4. Build noname and copy the binary:
  **cabal build** <br>
  **cp $(cabal list-bin noname) ../noname** <br>

Note: <br>
For Windows:  $(cabal list-bin noname) does not work in the command prompt; instead, run cabal list-bin noname to get the full path, then copy the binary manually to the repo root and name it noname.exe



### Installation of dependencies:<br>

macOS:<br>
**pip install dearpygui pexpect**<br>

Windows:<br>
**pip install dearpygui wexpect**<br>

Linux:<br>
**pip install dearpygui pexpect**<br>

For compiling noname:<br>
**cabal build** <br>

Running:<br>
**python gui.py** <path_to_your_file.nn> <br>


Example: <br>
**python gui.py** test.nn <br>

If one wants to simply test the tool, it is good to go with the examples/ folder <br>
----------------------------------------------------------------------------------------------------------------------------
### The Interface: <br>

Left - Decision tree: Green circles are states you have visited. Grey circles are available or unchosen options. Click any grey circle to make that choice. Click an older green circle to rewind to that point, discarding everything after it. <br>

Right - Detail panel: Shows the fields of the selected node (Executed, alpha_0, beta_0, etc.), the transition description, and a table with FLIC and intruder analysis per branch. Use Previous / Next to step through intermediate states within a single transition. <br>


### Automatic Mode: <br>
Click Run noname (automatic mode) to let noname run non-interactively to completion. If a privacy violation is found, the GUI replays the violation path in the tree automatically so you can inspect it step by step. <br>


### Symbols not displaying correctly?

| OS       | Font used                 | 
|----------|-------------------------- |
| macOS    | Arial Unicode or Geneva   | 
| Windows  | Arial or Segoe UI Symbol  |
| Linux    | Deja Vu Sans              |


If none of these are found, a warning is printed and the default DearPyGui font is used, which may not render mathematical symbols (∨, ⊤, α, β, γ) correctly. On Linux, install DejaVu Sans with: <br>

**sudo apt install fonts-dejavu** <br>


---------------------------------------------------------------------------------------------------------------------------------

### Troubleshooting: <br>

pexpect not found (macOS/Linux): <br>
**pip install pexpect** <br>


wexpect not found (Windows): <br>
**pip install wexpect** <br>


Binary not found or permission denied (macOS/Linux): <br>
**chmod +x noname** <br>


Python version error: <br>
The code requires Python 3.10 or newer. Check your version with: <br>
**python --version** <br>


GHC version mismatch during build: <br>
Make sure GHCup installed GHC 9.6.7 and that it is the active version: <br>
**ghcup set ghc 9.6.7** <br>
**ghc –version** <br>







 














