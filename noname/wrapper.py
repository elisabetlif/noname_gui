
import sys
import re
from typing import Optional
import platform
import sys

try: 
    import pexpect
except ImportError:
    pexpect = None

#lowest layer
#every method here returns or produces a dict with state, options, raw and terminal

class Wrapper:
    #stores the binary path, input file and solver. Process starts as None
    def __init__(self, binary_path: str, input_file: str, solver: str = "cvc5"):
        self.binary_path = binary_path
        self.input_file = input_file
        self.solver = solver
        self.process = None

    #spawns noname using pexpect with the -i flag hardcoded, then immediately reads until noname is waiting for input
    def start(self) -> dict:
        if pexpect is None:
            raise RuntimeError("pexpect not installed. Run pip install pexpect")
        if platform.system() == "Windows":
            try:
                import wexpect
                self.process = wexpect.spawn(f"{self.binary_path} -i {self.input_file} --solver {self.solver}",encoding="utf-8")
            except ImportError:
                raise RuntimeError("wexpect not installed on Windows. Run: pip install wexpect")
        self.process = pexpect.spawn(
            f"{self.binary_path} -i {self.input_file} --solver {self.solver}",
            encoding="utf-8"
        )
        return self._read_until_waiting()

    #sends a number to noname via the PTY, then reads until noname is waiting again
    def send_choice(self, choice: int) -> dict:
        self.process.sendline(str(choice))
        return self._read_until_waiting()

    #the core reading loop. Uses pexpect's expect with a 0.5 second timeout. 
    #keeps reading lines until noname goes quiet, then returns. If it sees EOF noname has ended.
    #if it times out and the last lime looks like a numbered option, noname is waiting for input
    def _read_until_waiting(self) -> dict:
        lines = []
        while True:
            try:
                self.process.expect([r'\n', pexpect.EOF], timeout=0.5)
                
                # if after is EOF class itself, noname has closed
                if self.process.after is pexpect.EOF:
                    if self.process.before:
                        lines.append(self.process.before.rstrip("\n\r"))
                    return self._parse_output(lines, terminal=True)
                
                # safe to concatenate now since after is a string newline
                line = self.process.before + self.process.after
                if isinstance(line, str):
                    lines.append(line.rstrip("\n\r"))
                    
            except pexpect.EOF:
                return self._parse_output(lines, terminal=True)
            except pexpect.TIMEOUT:
                if self._is_waiting(lines):
                    return self._parse_output(lines, terminal=False)

    #checks if the last non-empty line matches "1. Something" -> meaning noname has printed all its options and is now blocked waiting
    def _is_waiting(self, lines: list[str]) -> bool:
        non_empty = [i for i in lines if i.strip()]
        if not non_empty:
            return False
        last = non_empty[-1]
        return bool(re.match(r"^\d+\.\s", last))

    #takes the accumulated lines and splits them into structured data. Extracts the state fields into a dict, 
    # collects the numbered options into a list and keep everything raw
    def _parse_output(self, lines: list[str], terminal: bool) -> dict:
        state = {}
        options = []
        state_lines = []
        in_state = False

        for line in lines:
            if line.startswith("Current state:"):
                in_state = True
                continue
            if line.startswith("Select an option:"):
                in_state = False
                continue
            if re.match(r"^\d+\.\s", line):
                options.append(line)
                in_state = False
                continue
            if in_state:
                state_lines.append(line)

        raw_state = "\n".join(state_lines)
        for field in ["Executed", "Recipe choice", "alpha_0", "beta_0",
                      "gamma_0", "Possibilities", "Checked"]:
            m = re.search(rf"^{field} = (.*)$", raw_state, re.MULTILINE)
            if m:
                state[field] = m.group(1)

        return {
            "state": state,
            "options": options,
            "terminal": terminal,
            "raw": "\n".join(lines)
        }

    #kills the noname process
    def terminate(self):
        if self.process:
            self.process.terminate()
            self.process = None