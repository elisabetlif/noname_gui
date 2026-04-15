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
            if re.match(r'^[\w\s]+ =', stripped):  # replace the old field detection line
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
def get_step_count(raw: str) -> int:
    """
    Returns the number of intermediate steps in the raw output.
    """
    return len(split_up(raw))

#for the GUI to use
#using the current index, the GUI gets what it's supposed to display
def get_step(raw: str, index: int) -> dict | None:
    """
    Returns a single step by index, or None if out of range.
    """
    steps = split_up(raw)
    if not steps or index < 0 or index >= len(steps):
        return None
    return steps[index]


if __name__ == "__main__":
    raw = (
        '2\nCurrent state:\nExecuted = Challenge.Response.Response\nRecipe choice = [R1->l3,R3->l1,R4->l3]\nalpha_0 = x1∈{t1,t2}\nbeta_0 = ⊤\ngamma_0 = ⊤\nPossibilities = {(nil,⊤,[-l1(✓(✓,✓))->session(x1,n1).-l2(✓)->n1.-l3(+(✓(✓),✓,✓))->scrypt(sk(x1),n1,fixedR).+R2->X2.-l4(✓)->ok.+R5->X25.+R6->X26],{∀X31,X32.X25≠session(X31,X32),X2≠sk(x1)},⊤,[noncestate[n1]:=spent])}\nChecked = {(l4,ok)}\nThe process of the possibility with condition ⊤ goes into the right part.\nNumber of states after 3 transactions: 1\nBound reached, no privacy violation found after 3 transactions.'
    )
    steps = split_up(raw)
    print(f"Found {len(steps)} steps")
    for i, step in enumerate(steps):
        print(f"\n--- Step {i + 1} ---")
        print(f"Transition: {step['transition']}")
        print(f"Fields: {step['fields']}")