import re


# splits up noname output from the choice
# splits on "Current state:"
# processes each chunk into a dict with the state text, transition description and parsed fields
# phase is determined by [COMPOSE_CHECK] and [ANALYZE] markers in the raw output

def split_up(raw: str) -> list[dict]:
    raw = raw.replace("\r\n", "\n").replace("\r", "\n")

    # remove echo line at start (single digit or short number)
    lines = raw.split("\n")
    if lines and lines[0].strip().isdigit():
        lines = lines[1:]
    raw = "\n".join(lines)

    terminal_phrases = [
        "Number of states",
        "Bound reached",
        "Privacy violation found",
        "There are no more reachable states",
        "SatResult:",
    ]

    # split on "Current state:" keeping everything between chunks
    # so we can detect phase markers as we go
    current_phase = "protocol"
    steps = []

    raw = raw.replace("State:", "Current state:")
    parts = raw.split("Current state:")


    for part in parts:
        if not part.strip():
            continue

        # check for phase markers appearing in this chunk
        # once we see [ANALYZE] all subsequent chunks are analyze phase
        # once we see [COMPOSE_CHECK] but not yet [ANALYZE] they are compose_check
        if "[ANALYZE]" in part:
            current_phase = "analyze"
        elif "[COMPOSE_CHECK]" in part:
            current_phase = "compose_check"

        # filter terminal phrases and phase markers from content
        chunk_lines = []
        for line in part.split("\n"):
            stripped = line.strip()
            if stripped in ("[COMPOSE_CHECK]", "[ANALYZE]"):
                continue
            if any(stripped.startswith(phrase) for phrase in terminal_phrases):
                continue
            chunk_lines.append(line)
        chunk = "\n".join(chunk_lines).strip()

        if not chunk:
            continue

        # parse state lines and transition
        lines_list = chunk.split("\n")
        state_lines = []
        transition = ""
        for line in lines_list:
            stripped = line.strip()
            if not stripped:
                continue
            if re.match(r'^[\w\s]+ =', stripped):
                state_lines.append(stripped)
            elif stripped.startswith("Select an option:"):
                break
            elif stripped and stripped[0].isdigit() and ". " in stripped:
                break
            elif state_lines:
                transition = stripped
                break

        if state_lines:
            fields = parse_fields(state_lines)

            # override phase if beta_0 contains ∨ — this means multiple
            # possibilities exist which only happens during intruder analysis
            # branching, even if no [ANALYZE] marker appeared in this chunk
            #beta = fields.get("beta_0", "")
            #if "∨" in beta and current_phase == "protocol":
            #    current_phase = "analyze"

            steps.append({
                "state_text": "\n".join(state_lines),
                "transition": transition,
                "fields": fields,
                "phase": current_phase
            })

    return steps





# joins the lines it receives into one string
# loops through known field names and runs a regex search
def parse_fields(state_lines: list[str]) -> dict:
    fields = {}
    field_names = [
        "Executed", "Recipe choice", "alpha_0",
        "beta_0", "gamma_0", "Possibilities", "Checked"
    ]
    joined = "\n".join(state_lines)
    for field in field_names:
        m = re.search(rf"^{field} = (.*)$", joined, re.MULTILINE)
        if m:
            fields[field] = m.group(1)
    return fields


# checks how many "Next" button presses are available
# for the GUI to use
# returns the number of intermediate steps in the raw output
def get_step_count(raw: str) -> int:
    return len(split_up(raw))


# for the GUI to use
# using the current index, the GUI gets what it's supposed to display
# returns a single step by index, or None if out of range
def get_step(raw: str, index: int) -> dict | None:
    steps = split_up(raw)
    if not steps or index < 0 or index >= len(steps):
        return None
    return steps[index]


# extracts the flic (messages and recipes) from the possibilities string
# returns a list of individual mappings like '-l1->session(x1,n1)'
def extract_flic(possibilities: str) -> list[str]:
    if not possibilities or "|" not in possibilities:
        return []

    # get everything after the | separator
    after_process = possibilities.split("|")[1]

    # find the flic — it's between [ and ]
    start = after_process.find("[")
    end = after_process.find("]")
    if start == -1 or end == -1:
        return []

    flic = after_process[start + 1:end]
    if not flic:
        return []

    # split on . outside parentheses
    mappings = []
    current = ""
    depth = 0
    for char in flic:
        if char == "(":
            depth += 1
            current += char
        elif char == ")":
            depth -= 1
            current += char
        elif char == "." and depth == 0:
            if current.strip():
                mappings.append(current.strip())
            current = ""
        else:
            current += char
    if current.strip():
        mappings.append(current.strip())

    return mappings


# extracts all possibilities from the raw string, returning
# a list of dicts with 'process' and 'condition' for each.
# used to show the intruder what branches exist when noname
# doesn't know which branch was taken.
# uses § separator added in Pretty.hs for unambiguous splitting
def extract_all_possibilities(possibilities: str) -> list[dict]:
    if not possibilities:
        return []

    inner = possibilities[1:-1]
    parts = [p.strip() for p in inner.split("§") if p.strip()]

    parsed = []
    for p in parts:
        if p.startswith("("):
            p = p[1:]
        if p.endswith(")"):
            p = p[:-1]

        if "|" not in p:
            continue

        process_part = p.split("|")[0].strip()
        after_pipe = p.split("|")[1]

        # extract condition at depth 0
        depth = 0
        condition = ""
        for char in after_pipe:
            if char == "(":
                depth += 1
                condition += char
            elif char == ")":
                depth -= 1
                condition += char
            elif char == "," and depth == 0:
                break
            else:
                condition += char

        # extract flic — between [ and ] after condition
        flic_start = after_pipe.find("[")
        flic_end = after_pipe.find("]")
        flic_str = after_pipe[flic_start + 1:flic_end] if flic_start != -1 and flic_end != -1 else ""

        # split flic on dots outside parentheses
        flic_items = []
        current = ""
        depth = 0
        for char in flic_str:
            if char == "(":
                depth += 1
                current += char
            elif char == ")":
                depth -= 1
                current += char
            elif char == "." and depth == 0:
                if current.strip():
                    flic_items.append(current.strip())
                current = ""
            else:
                current += char
        if current.strip():
            flic_items.append(current.strip())

        # split process on dots outside parentheses
        steps = []
        current_step = ""
        depth = 0
        for char in process_part:
            if char == "(":
                depth += 1
                current_step += char
            elif char == ")":
                depth -= 1
                current_step += char
            elif char == "." and depth == 0:
                if current_step.strip():
                    steps.append(current_step.strip())
                current_step = ""
            else:
                current_step += char
        if current_step.strip():
            steps.append(current_step.strip())

        parsed.append({
            "process": "\n".join(steps),
            "condition": condition.strip(),
            "flic": flic_items
        })

    return parsed

def extract_branches(possibilities: str, beta: str) -> list[dict]:
    if not beta or beta == "⊤":
        conditions = []
    else:
        conditions = []
        current = ""
        depth = 0
        for char in beta:
            if char == "(":
                depth += 1
                current += char
            elif char == ")":
                depth -= 1
                current += char
            elif char == "∨" and depth == 0:
                if current.strip():
                    conditions.append(current.strip())
                current = ""
            else:
                current += char
        if current.strip():
            conditions.append(current.strip())

    all_pos = extract_all_possibilities(possibilities)

    if not all_pos:
        return []
    if len(all_pos) == 1:
        return all_pos

    result = []
    for i, pos in enumerate(all_pos):
        condition = conditions[i] if i < len(conditions) else pos["condition"]
        result.append({
            "condition": condition,
            "process": pos["process"],
            "flic": pos["flic"]
        })
    return result

#Extracts the violation path from non-interactive noname output
#Returns dict with Executed, Recipe choice, alpha_0, beta_0 or None.
def parse_violation(output: str) -> dict | None:
    if "Privacy violation found" not in output:
        return None

    violation_pos = output.find("Privacy violation found")
    state_block = output[violation_pos:]

    fields = {}

    m = re.search(r'^State:\s*Executed = (.*)$', state_block, re.MULTILINE)
    if m:
        fields["Executed"] = m.group(1)

    for field in ["Recipe choice", "alpha_0", "beta_0", "Checked"]:
        m = re.search(rf"^{field} = (.*)$", state_block, re.MULTILINE)
        if m:
            fields[field] = m.group(1)

    
    return fields if fields else None
    