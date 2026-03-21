import subprocess
import sys
import re
from typing import Optional
import pexpect


class Wrapper:
    def __init__(self, binary_path: str, input_file: str, solver: str = "cvc5"):
        self.binary_path = binary_path
        self.input_file = input_file
        self.solver = solver
        self.process = None

    def start(self) -> dict:
        self.process = pexpect.spawn(
            f"{self.binary_path} -i {self.input_file} --solver {self.solver}",
            encoding="utf-8"
        )
        return self._read_until_waiting()

    def send_choice(self, choice: int) -> dict:
        self.process.sendline(str(choice))
        return self._read_until_waiting()

    def _read_until_waiting(self) -> dict:
        lines = []
        while True:
            try:
                self.process.expect([r'\n', pexpect.EOF], timeout=0.5)
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
            self.process.terminate()
            self.process = None


if __name__ == "__main__":
    wrapper = Wrapper(
        binary_path="./noname",
        input_file="examples/bac/bac.nn"
    )

    result = wrapper.start()
    print("=== STATE ===")
    print(result["state"])
    print("=== OPTIONS ===")
    print(result["options"])
    print("=== TERMINAL ===")
    print(result["terminal"])
    print("=== RAW ===")
    print(result["raw"])

    if not result["terminal"] and result["options"]:
        print("\nSending choice 1...")
        result2 = wrapper.send_choice(1)
        print("=== AFTER CHOICE ===")
        print(result2["raw"])

    wrapper.terminate()