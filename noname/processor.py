import re

#splits up noname output from the choice 
#splits on "Current state:" 
#processes each chunk into a a dict with the state text, transition description and parsed fields
def split_up(raw: str) -> list[dict]:
    raw = raw.replace("\r\n", "\n").replace("\r", "\n")

    # remove echo line at start (single digit or short number)
    lines = raw.split("\n")
    if lines and lines[0].strip().isdigit():
        lines = lines[1:]
    raw = "\n".join(lines)
    
    # remove terminal messages
    terminal_phrases = [
        "Number of states",
        "Bound reached",
        "Privacy violation found",
        "There are no more reachable states"
    ]
    filtered_lines = []
    for line in raw.split("\n"):
        if not any(line.strip().startswith(phrase) for phrase in terminal_phrases):
            filtered_lines.append(line)
    raw = "\n".join(filtered_lines)

    chunks = [c.strip() for c in raw.split("Current state:") if c.strip()]
    steps = []

    for chunk in chunks:
        lines = chunk.split("\n")
        state_lines = []
        transition = ""

        for line in lines:
            stripped = line.strip()
            if not stripped:
                continue
            if re.match(r'^[\w\s]+ =', stripped):  
                state_lines.append(stripped)
            elif stripped.startswith("Select an option:"):
                break
            elif stripped[0].isdigit() and ". " in stripped:
                break
            elif state_lines:
                transition = stripped
                break

        if state_lines:
            steps.append({
                "state_text": "\n".join(state_lines),
                "transition": transition,
                "fields": parse_fields(state_lines)
            })

    return steps




#joins the lines it receives into one string
#loops through known fields names and runs a regex search
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

#checks how many "Next" button presses are available
#for the GUI to use
# Returns the number of intermediate steps in the raw output
def get_step_count(raw: str) -> int:
    return len(split_up(raw))

#for the GUI to use
#using the current index, the GUI gets what it's supposed to display
#Returns a single step by index, or None if out of range
def get_step(raw: str, index: int) -> dict | None:
    steps = split_up(raw)
    if not steps or index < 0 or index >= len(steps):
        return None
    return steps[index]


#takes the raw Possibilities string from the first step and transforms it into a more desired format (i.e. it looks like the transaction)
def process_possibilities(possibilities: str) -> str:
    if not possibilities:
        return ""
    inner = possibilities[2:-2]
    process = inner.split("|")[0]
    # split on dots
    steps = process.split(".")
    return "\n".join(s.strip() for s in steps if s.strip())

#compares initial and current possibilities to determine which steps have been examined by noname
#returns a list of dicts with "step" and "done" keys
def possibilities_with_checks(initial: str, all_possibilities: list[str]) -> list[dict]:
    initial_steps = process_possibilities(initial).split("\n")
    
    # collect all steps that have appeared at position [0] — the front of the process
    seen_at_front = set()
    for pos in all_possibilities:
        steps = process_possibilities(pos).split("\n")
        if steps:
            seen_at_front.add(steps[0].strip())
    
   
    # current possibilities — last in the list
    current_steps_stripped = [s.strip() for s in process_possibilities(all_possibilities[-1]).split("\n")]
    
    result = []
    found_undone = False

    for step in initial_steps:
        step_stripped = step.strip()

        if found_undone:
            result.append({"step": step, "done": False})
            continue

        # get prefix up to first ( to avoid variable substitution issues
        if "(" in step_stripped:
            prefix = step_stripped.split("(")[0]
        else:
            prefix = step_stripped

        # ensure prefix is at least 10 chars
        if len(prefix) < 10:
            prefix = step_stripped[:min(20, len(step_stripped))]

        # step is done only if it was seen at position [0] AND is no longer in current
        # step is done only if it was seen at position [0] AND is no longer in current
        # special case for if statements — variable substitution means
        # the condition changes, so just match on "if " prefix
        if step_stripped.startswith("if "):
            was_seen = any(s.startswith("if ") for s in seen_at_front)
        else:
            was_seen = any(s.startswith(prefix) for s in seen_at_front)
        
        still_present = any(cs.startswith(prefix) for cs in current_steps_stripped)

        done = was_seen and not still_present
        still_present = any(cs.startswith(prefix) for cs in current_steps_stripped)

        done = was_seen and not still_present

        if not done:
            found_undone = True

        result.append({"step": step, "done": done})

    return result


#Extracts the flic (messages and recipes) from the possibilities string
#Returns a list of individual mappings like '-l1->session(x1,n1)'
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
    
    flic = after_process[start+1:end]
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


