import sys
import re
from typing import Optional
import platform
import subprocess
import os



try:
    import pexpect
except ImportError:
    pexpect = None

try:
    from winpty import PtyProcess
except ImportError:
    PtyProcess = None

class Wrapper:
    def __init__(self, binary_path: str, input_file: str, solver: str = "cvc5"):
        self.binary_path = binary_path
        self.input_file = input_file
        self.solver = solver
        self.process = None
        self._is_windows = platform.system() == "Windows"

    def start(self) -> dict:
        print(f"Platform: {platform.system()}")
        print(f"Is Windows: {self._is_windows}")
        if self._is_windows:
            if PtyProcess is None:
                raise RuntimeError("pywinpty not installed. Run: pip install pywinpty")
            self.process = PtyProcess.spawn(
            [self.binary_path, "-i", self.input_file, "--solver", self.solver],
            env={**os.environ, "PYTHONIOENCODING": "utf-8", "PYTHONUTF8": "1"}
            )
            return self._read_until_waiting_winpty()
        
        if pexpect is None:
            raise RuntimeError("pexpect not installed. Run: pip install pexpect")
        self.process = pexpect.spawn(
            f"{self.binary_path} -i {self.input_file} --solver {self.solver}",
            encoding="utf-8"
        )
        result = self._read_until_waiting()
        print(f"Raw output: {repr(result['raw'])}")
        print(f"Options: {result['options']}")
        return result

    def send_choice(self, choice: int) -> dict:
        if self._is_windows:
            self.process.write(str(choice) + "\r\n")
            return self._read_until_waiting_winpty()
        self.process.sendline(str(choice))
        return self._read_until_waiting()

    # Windows PTY reading loop using pywinpty
    # reads chunks, splits into lines, stops when noname is waiting for input
    def _read_until_waiting_winpty(self) -> dict:
        lines = []
        buffer = ""
        import time
        while True:
            try:
                chunk = self.process.read(1000)
                if chunk:
                    # pywinpty returns bytes or str depending on version
                    if isinstance(chunk, bytes):
                        chunk = chunk.decode("utf-8", errors="replace")
                    buffer += chunk
                    # split buffer into lines keeping incomplete last line
                    parts = buffer.split("\n")
                    buffer = parts[-1]
                    for part in parts[:-1]:
                        line = part.rstrip("\r")
                        lines.append(line)
                    # check if noname is waiting after processing new lines
                    if self._is_waiting(lines):
                        return self._parse_output(lines, terminal=False)
                else:
                    # no data — check if process ended
                    if not self.process.isalive():
                        if buffer.strip():
                            lines.append(buffer.rstrip("\r\n"))
                        return self._parse_output(lines, terminal=True)
                    time.sleep(0.05)
            except EOFError:
                if buffer.strip():
                    lines.append(buffer.rstrip("\r\n"))
                return self._parse_output(lines, terminal=True)

    # existing pexpect reading loop for macOS/Linux
    def _read_until_waiting(self) -> dict:
        lines = []
        while True:
            try:
                self.process.expect([r'\n', pexpect.EOF], timeout=0.5)
                if self.process.after is pexpect.EOF:
                    if self.process.before:
                        lines.append(self.process.before.rstrip("\n\r"))
                    return self._parse_output(lines, terminal=True)
                line = self.process.before + self.process.after
                if isinstance(line, str):
                    lines.append(line.rstrip("\n\r"))
            except pexpect.EOF:
                return self._parse_output(lines, terminal=True)
            except pexpect.TIMEOUT:
                if self._is_waiting(lines):
                    return self._parse_output(lines, terminal=False)

    def _is_waiting(self, lines: list[str]) -> bool:
        non_empty = [i for i in lines if i.strip()]
        if not non_empty:
            return False
        last = non_empty[-1]
        return bool(re.match(r"^\d+\.\s", last))

    def _parse_output(self, lines: list[str], terminal: bool) -> dict:
        state = {}
        options = []
        state_lines = []
        in_state = False

        for line in lines:
            if line.startswith("Current state:"):
                in_state = True
                continue
            if line.startswith("State:"):
                in_state = True
                line = line[len("State:"):].strip()
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

    def terminate(self):
        if self.process:
            try:
                if self._is_windows:
                    self.process.terminate()
                else:
                    self.process.terminate()
            except Exception:
                pass
            self.process = None

    def run_automatic(self) -> str:
        result = subprocess.run(
            [self.binary_path, self.input_file, "--solver", self.solver],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=60
        )
        return result.stdout + result.stderr