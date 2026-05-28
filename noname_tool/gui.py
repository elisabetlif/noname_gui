import sys
import platform
import math
import os
import subprocess
import dearpygui.dearpygui as dpg
from session import Session
from processor import split_up, extract_flic, extract_all_possibilities, parse_violation
import re



# top layer -> talks only to session, never to the wrapper or tree directly

# globals
session = None
clickable_nodes = []
current_node = None
current_step_index = 0
current_steps = []
red_highlight_theme = None
default_input_theme = None

# fixed center point — does not change regardless of tree width
CENTER_X = 450



# so all symbols from noname show up in GUI
# on Linux, uses fc-match to find a suitable font dynamically
# falls back to hardcoded paths if fc-match is not available
def get_system_font() -> str | None:
    system = platform.system()
    if system == "Darwin":
        candidates = [
            "/Library/Fonts/Arial Unicode.ttf",
            "/System/Library/Fonts/Supplemental/Geneva.ttf",
        ]
    elif system == "Linux":
        # try fc-match first — works on any distro with fontconfig installed
        # asks for a font that supports Greek characters (covers α, β, γ etc.)
        try:
            result = subprocess.run(
                ["fc-match", "--format=%{file}", ":lang=el:spacing=proportional"],
                capture_output=True, text=True
            )
            if result.returncode == 0 and result.stdout.strip():
                path = result.stdout.strip()
                if os.path.exists(path):
                    return path
        except FileNotFoundError:
            pass

        # fallback to hardcoded paths for common distros
        candidates = [
            # Ubuntu/Debian
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            # Arch Linux (ttf-dejavu)
            "/usr/share/fonts/dejavu/DejaVuSans.ttf",
            # Arch Linux (ttf-dejavu alternative path)
            "/usr/share/fonts/TTF/DejaVuSans.ttf",
            # Arch Linux (noto-fonts)
            "/usr/share/fonts/noto/NotoSans-Regular.ttf",
            # Arch Linux (ttf-liberation)
            "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
            # Fedora/RHEL
            "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
        ]
    else:
        return None
    for path in candidates:
        if os.path.exists(path):
            return path
    return None


# extracts the human readable name from the full option string
def calculate_label(option: str, flic: list = None, all_options: list = None) -> str:
    # equivalence options
    m = re.search(r'recipes (\S+) and (\S+) are NOT equivalent', option)
    if m:
        a = m.group(1).rstrip(".")
        b = m.group(2).rstrip(".")
        return f"{a}≠{b}"

    m = re.search(r'recipes (\S+) and (\S+) are equivalent', option)
    if m:
        a = m.group(1).rstrip(".")
        b = m.group(2).rstrip(".")
        return f"{a}={b}"

    if "The choice of" in option:
        match = re.search(r'\[(.*?)\]', option)
        if match:
            full = match.group(1)
            if "->" in full:
                arrow_pos = full.index("->")
                r_var = full[:arrow_pos]
                raw_value = full[arrow_pos + 2:]
                # extract value up to first comma at depth 0
                # to avoid including subsequent recipe assignments
                depth = 0
                end = len(raw_value)
                for i, c in enumerate(raw_value):
                    if c == "(":
                        depth += 1
                    elif c == ")":
                        depth -= 1
                    elif c == "," and depth == 0:
                        end = i
                        break
                value = raw_value[:end]
                # get X var from sibling catch option
                x_var = None
                if all_options:
                    for other in all_options:
                        if "The disequalities" in other:
                            x_match = re.search(r'(X\d+)≠', other)
                            if x_match:
                                x_var = x_match.group(1)
                                break
                var = x_var if x_var else r_var
                return f"Try\n{var}={value}"
        return "Try"
    if "The disequalities" in option:
        match = re.search(r'(X\d+≠\S+)', option)
        if match:
            return f"Catch\n{match.group(1)}"
        return "Catch"
    parts = option.split("Execute the transaction ")
    if len(parts) > 1:
        return parts[1].rstrip(".")
    parts2 = option.split(". ", 1)
    if len(parts2) > 1:
        return parts2[1]
    return option


# checks if a mouse click falls within a circle using the distance formula
def is_inside_circle(mouse_x, mouse_y, cx, cy, radius):
    return (mouse_x - cx) ** 2 + (mouse_y - cy) ** 2 <= radius ** 2


# returns the rendered pixel width of a string using the active Dear PyGui font.
# falls back to a character-count estimate if get_text_size returns None,
# which can happen on the first draw call before the font is fully active.
def get_text_width(line: str) -> float:
    size = dpg.get_text_size(line)
    if size is None:
        return len(line) * 9
    return size[0]


def refresh_step_display():
    global current_steps, current_step_index, current_node

    if not current_steps:
        # no intermediate steps — show node.state directly
        if current_node:
            state = current_node.state
            dpg.set_value("detail_step_counter", "Step 1 of 1")
            dpg.set_value("detail_transition", "")
            dpg.set_value("detail_executed", f"Executed: {state.get('Executed', '')}")
            dpg.set_value("detail_alpha", f"alpha_0: {state.get('alpha_0', '')}")
            dpg.set_value("detail_beta", f"beta_0: {state.get('beta_0', '')}")
            dpg.set_value("detail_recipe", f"Recipe choice: {state.get('Recipe choice', '')}")
            dpg.set_value("detail_gamma", f"gamma_0: {state.get('gamma_0', '')}")
            dpg.set_value("detail_checked", f"Checked: {state.get('Checked', '')}")
            #dpg.set_value("detail_raw", current_node.raw)

            # apply theme based on terminal state
            if current_node.terminal and "Privacy violation found" in current_node.raw:
                dpg.bind_item_theme("detail_alpha", red_highlight_theme)
                dpg.bind_item_theme("detail_beta", red_highlight_theme)
            else:
                dpg.bind_item_theme("detail_alpha", default_input_theme)
                dpg.bind_item_theme("detail_beta", default_input_theme)

            # override transition with bound reached message if present
            if current_node.terminal:
                for line in current_node.raw.split("\n"):
                    if line.strip().startswith("Bound reached"):
                        dpg.set_value("detail_transition", line.strip())
                        break

            # rebuild table with flic and analysis
            dpg.delete_item("intruder_table", children_only=True)
            all_pos = extract_all_possibilities(state.get("Possibilities", ""))
            if not all_pos:
                all_pos = [{"condition": "⊤", "flic": [], "process": ""}]
            dpg.add_table_column(label="", width_fixed=True,
                                 init_width_or_weight=60, parent="intruder_table")
            for p in all_pos:
                label = p["condition"] if p["condition"] and p["condition"] != "⊤" else ""
                dpg.add_table_column(label=label, parent="intruder_table")
            with dpg.table_row(parent="intruder_table"):
                dpg.add_text("FLIC")
                for p in all_pos:
                    dpg.add_text("\n".join(p["flic"]) if p["flic"] else "", wrap=120)
            with dpg.table_row(parent="intruder_table"):
                dpg.add_text("Analysis")
                for p in all_pos:
                    process = p["process"] if p["process"] != "nil" else "-"
                    dpg.add_text(process, wrap=150)
        dpg.disable_item("btn_prev")
        dpg.disable_item("btn_next")
        return

    total = len(current_steps)
    step = current_steps[current_step_index]
    fields = step["fields"]
    phase = step["phase"]

    dpg.set_value("detail_step_counter", f"Step {current_step_index + 1} of {total}")
    dpg.set_value("detail_executed", f"Executed: {fields.get('Executed', '')}")
    dpg.set_value("detail_alpha", f"alpha_0: {fields.get('alpha_0', '')}")
    dpg.set_value("detail_beta", f"beta_0: {fields.get('beta_0', '')}")
    dpg.set_value("detail_recipe", f"Recipe choice: {fields.get('Recipe choice', '')}")
    dpg.set_value("detail_gamma", f"gamma_0: {fields.get('gamma_0', '')}")
    dpg.set_value("detail_checked", f"Checked: {fields.get('Checked', '')}")

    # apply theme based on terminal state
    if current_node and current_node.terminal and "Privacy violation found" in current_node.raw:
        dpg.bind_item_theme("detail_alpha", red_highlight_theme)
        dpg.bind_item_theme("detail_beta", red_highlight_theme)
    else:
        dpg.bind_item_theme("detail_alpha", default_input_theme)
        dpg.bind_item_theme("detail_beta", default_input_theme)

    if phase == "protocol":
        dpg.set_value("detail_transition", step["transition"])
    else:
        dpg.set_value("detail_transition", f"{step['transition']}")

    # override transition with bound reached message if present
    if current_node and current_node.terminal:
        for line in current_node.raw.split("\n"):
            if line.strip().startswith("Bound reached"):
                dpg.set_value("detail_transition", line.strip())
                break

    # always rebuild the table using all possibilities from noname output
    dpg.delete_item("intruder_table", children_only=True)

    all_pos = extract_all_possibilities(fields.get("Possibilities", ""))

    if not all_pos:
        all_pos = [{"condition": "⊤", "flic": [], "process": ""}]

    dpg.add_table_column(label="", width_fixed=True,
                         init_width_or_weight=60, parent="intruder_table")
    for p in all_pos:
        label = p["condition"] if p["condition"] and p["condition"] != "⊤" else ""
        dpg.add_table_column(label=label, parent="intruder_table")

    with dpg.table_row(parent="intruder_table"):
        dpg.add_text("FLIC")
        for p in all_pos:
            dpg.add_text("\n".join(p["flic"]) if p["flic"] else "", wrap=140)

    with dpg.table_row(parent="intruder_table"):
        row_label = "Process" if phase == "protocol" else "Analysis"
        dpg.add_text(row_label)
        for p in all_pos:
            process = p["process"] if p["process"] != "nil" else "-"
            dpg.add_text(process, wrap=150)

    if phase != "protocol":
        dpg.highlight_table_row("intruder_table", 1, (200, 30, 30, 180))

    if current_step_index <= 0:
        dpg.disable_item("btn_prev")
    else:
        dpg.enable_item("btn_prev")

    if current_step_index >= total - 1:
        dpg.disable_item("btn_next")
    else:
        dpg.enable_item("btn_next")


# takes a TreeNode and populates the right side panel with its state fields
# all steps (protocol and intruder) are kept in one unified list for navigation
def update_detail_panel(node):
    global current_node, current_step_index, current_steps
    current_node = node
    current_steps = split_up(node.raw)

    # for terminal violation nodes, merge all steps into one:
    # take the complete fields from the last step,
    # the transition from the first step,
    # and prepend the "Privacy violation found" line if present
    if node.terminal and len(current_steps) >= 2:
        violation_line = ""
        for line in node.raw.split("\n"):
            if line.strip().startswith("Privacy violation found"):
                violation_line = line.strip()
                break
        merged = {
            "state_text": current_steps[-1]["state_text"],
            "transition": f"{violation_line}\n{current_steps[0]['transition']}".strip(),
            "fields": current_steps[-1]["fields"],
            "phase": current_steps[-1]["phase"]
        }
        current_steps = [merged]

    if node.terminal and current_steps:
        current_step_index = len(current_steps) - 1
    else:
        current_step_index = 0

    refresh_step_display()


def on_next(sender, app_data):
    global current_step_index
    if current_step_index < len(current_steps) - 1:
        current_step_index += 1
        refresh_step_display()


def on_prev(sender, app_data):
    global current_step_index
    if current_step_index > 0:
        current_step_index -= 1
        refresh_step_display()


# called when the viewport is resized — adjusts all panels to fill the new size
# tree panel gets 60% of width, detail panel gets the remaining 40%
def on_resize(sender, app_data):
    viewport_width = dpg.get_viewport_width()
    viewport_height = dpg.get_viewport_height()

    tree_width = int(viewport_width * 0.6)
    detail_width = viewport_width - tree_width - 15

    dpg.configure_item("tree_window", width=tree_width, height=viewport_height - 50)
    dpg.configure_item("detail_window", width=detail_width, height=viewport_height - 50)
    # resize table container proportionally
    dpg.configure_item("table_window", height=int(viewport_height * 0.3))

    redraw_tree()


# calculates how tall the drawlist needs to be so the tree doesn't get clipped
def get_drawlist_height() -> int:
    depth = session.current.depth()
    min_height = 650
    calculated = (depth + 3) * 200 + 100
    return max(min_height, calculated)


# calculates how wide the drawlist needs to be
def get_drawlist_width() -> int:
    min_width = 900
    active_path = session.current.active_path()
    base_spread = 200
    max_right = CENTER_X
    for node in active_path:
        d = node.depth()
        spread = max(base_spread / (2 ** max(d - 1, 0)), 80) if d > 0 else 0
        total = len(node.options) if node.options else 1
        x = calculate_node_x(node)
        max_right = max(max_right, x + spread * total / 2)
    calculated = int(max_right + 300)
    return max(min_width, calculated)


def draw_line_between_circles(x1, y1, x2, y2, radius1, radius2,
                               color=(0, 0, 0, 255), thickness=2):
    dx = x2 - x1
    dy = y2 - y1
    length = math.sqrt(dx**2 + dy**2)
    if length == 0:
        return
    nx = dx / length
    ny = dy / length
    start_x = x1 + nx * radius1
    start_y = y1 + ny * radius1
    end_x = x2 - nx * radius2
    end_y = y2 - ny * radius2
    dpg.draw_line(
        (start_x, start_y),
        (end_x, end_y),
        color=color,
        thickness=thickness,
        parent="tree_drawlist"
    )


def wrap_text(text: str, max_chars: int = 12) -> list[str]:
    words = text.split(" ")
    lines = []
    current_line = ""
    for word in words:
        if len(current_line) + len(word) + 1 <= max_chars:
            current_line += ("" if current_line == "" else " ") + word
        else:
            if current_line:
                lines.append(current_line)
            current_line = word
    if current_line:
        lines.append(current_line)
    return lines


# Calculate the x position of a node based on its path from root.
# Each choice shifts the position left or right, with spread halving at each depth.
# Uses fixed CENTER_X so the tree never shifts unexpectedly.
def calculate_node_x(node, base_spread: int = 200) -> float:
    x = float(CENTER_X)
    path_node = node
    ancestors = []
    while path_node.parent is not None:
        ancestors.append(path_node)
        path_node = path_node.parent
    ancestors = list(reversed(ancestors))

    current = path_node  # root
    for ancestor in ancestors:
        total = len(current.options)
        depth = ancestor.depth()
        spread = max(base_spread / (2 ** max(depth - 1, 0)), 80)
        offset = (ancestor.choice_made - (total + 1) / 2) * spread
        x += offset
        current = ancestor

    return x


# Calculate the x position of a grey circle representing an unchosen option.
# Uses the same logic as calculate_node_x — the grey circle sits where the green node WOULD be if that choice had been made.
def calculate_grey_x(parent_node, choice_num: int) -> float:
    parent_x = calculate_node_x(parent_node)
    total = len(parent_node.options)
    depth = parent_node.depth()
    spread = max(200 / (2 ** max(depth, 0)), 80)
    offset = (choice_num - (total + 1) / 2) * spread
    return parent_x + offset


# clears the drawlist entirely and redraws everything from scratch.
# walks active_path() to draw green circles and connecting lines,
# then draws grey circles for unchosen options at every level.
# also rebuilds clickable_nodes so click detection works on the new layout.
# uses dpg.get_text_size() for accurate label positioning across platforms
def redraw_tree():
    global clickable_nodes
    clickable_nodes = []

    new_height = get_drawlist_height()
    new_width = get_drawlist_width()
    dpg.configure_item("tree_drawlist", height=new_height, width=new_width)
    dpg.delete_item("tree_drawlist", children_only=True)

    start_y = 60
    level_height = 200
    green_radius = 30
    grey_radius = 15

    active_path = session.current.active_path()

    # first pass — calculate positions for all green nodes
    green_positions = {}
    for node in active_path:
        x = calculate_node_x(node)
        y = start_y + node.depth() * level_height
        green_positions[id(node)] = (x, y)

    # draw lines first so circles appear on top

    # green to green lines
    for i, node in enumerate(active_path):
        if i > 0:
            parent = active_path[i - 1]
            px, py = green_positions[id(parent)]
            nx, ny = green_positions[id(node)]
            draw_line_between_circles(
                px, py, nx, ny,
                green_radius, green_radius,
                color=(100, 200, 100, 255),
                thickness=2
            )

    # lines from green nodes to their unchosen grey circles
    for i, node in enumerate(active_path):
        gx, gy = green_positions[id(node)]

        if node.options and node.child is not None:
            for j, option in enumerate(node.options):
                choice_num = j + 1
                if choice_num == node.child.choice_made:
                    continue

                grey_x = calculate_grey_x(node, choice_num)
                grey_y = gy + level_height

                draw_line_between_circles(
                    gx, gy, grey_x, grey_y,
                    green_radius, grey_radius,
                    color=(120, 120, 120, 255),
                    thickness=1
                )

    # lines from current node to its available options
    current = session.current
    if not current.terminal:
        cx, cy = green_positions[id(current)]

        for j, option in enumerate(current.options):
            choice_num = j + 1
            grey_x = calculate_grey_x(current, choice_num)
            grey_y = cy + level_height

            draw_line_between_circles(
                cx, cy, grey_x, grey_y,
                green_radius, green_radius,
                color=(150, 150, 150, 255),
                thickness=1
            )

    # draw unchosen grey circles at each green node on the active path
    for i, node in enumerate(active_path):
        gx, gy = green_positions[id(node)]

        if node.options and node.child is not None:
            for j, option in enumerate(node.options):
                choice_num = j + 1
                if choice_num == node.child.choice_made:
                    continue

                grey_x = calculate_grey_x(node, choice_num)
                grey_y = gy + level_height
                tag = f"grey_past_{id(node)}_{j}"
                # pass node.options so Try label can find X var from sibling Catch
                label = calculate_label(option, None, node.options)
                lines = wrap_text(label)

                # small grey circle for unchosen past option
                dpg.draw_circle(
                    (grey_x, grey_y),
                    grey_radius,
                    fill=(120, 120, 120, 255),
                    color=(80, 80, 80, 255),
                    thickness=2,
                    parent="tree_drawlist",
                    tag=tag
                )

                # place label on outer side, right-aligned for left circles
                # use dpg.get_text_size for accurate width measurement across platforms
                text_y = grey_y - (len(lines) * 20) / 2
                if grey_x < gx:
                    for k, line in enumerate(lines):
                        text_width = get_text_width(line)
                        dpg.draw_text(
                            (grey_x - grey_radius - text_width,
                             text_y + (k * 16)),
                            line,
                            color=(180, 180, 180, 255),
                            size=20,
                            parent="tree_drawlist"
                        )
                elif grey_x > gx:
                    for k, line in enumerate(lines):
                        dpg.draw_text(
                            (grey_x + grey_radius + 5,
                             text_y + (k * 16)),
                            line,
                            color=(180, 180, 180, 255),
                            size=20,
                            parent="tree_drawlist"
                        )
                else:
                    for k, line in enumerate(lines):
                        dpg.draw_text(
                            (grey_x - 25,
                             grey_y + grey_radius + 3 + (k * 16)),
                            line,
                            color=(180, 180, 180, 255),
                            size=20,
                            parent="tree_drawlist"
                        )

                clickable_nodes.append({
                    "tag": tag,
                    "x": grey_x,
                    "y": grey_y,
                    "radius": grey_radius,
                    "label": label,
                    "choice": choice_num,
                    "node": node
                })

    # draw current node's available options as full size grey circles
    if not current.terminal:
        cx, cy = green_positions[id(current)]

        # get flic from current node's last step for Try label enrichment
        current_flic = []
        if session.current.raw:
            current_steps_raw = split_up(session.current.raw)
            if current_steps_raw:
                current_flic = extract_flic(
                    current_steps_raw[-1]["fields"].get("Possibilities", "")
                )

        for j, option in enumerate(current.options):
            choice_num = j + 1
            grey_x = calculate_grey_x(current, choice_num)
            grey_y = cy + level_height
            tag = f"grey_current_{j}"
            # pass current_flic and current.options so Try label can be enriched
            label = calculate_label(option, current_flic, current.options)
            lines = wrap_text(label)

            # full size grey circle for current options
            dpg.draw_circle(
                (grey_x, grey_y),
                green_radius,
                fill=(180, 180, 180, 255),
                color=(100, 100, 100, 255),
                thickness=2,
                parent="tree_drawlist",
                tag=tag
            )

            # place label on outer side, right-aligned for left circles
            # use dpg.get_text_size for accurate width measurement across platforms
            text_y = grey_y - (len(lines) * 20) / 2
            if grey_x < cx:
                for k, line in enumerate(lines):
                    text_width = get_text_width(line)
                    dpg.draw_text(
                        (grey_x - green_radius - text_width,
                         text_y + (k * 16)),
                        line,
                        color=(255, 255, 255, 255),
                        size=20,
                        parent="tree_drawlist"
                    )
            elif grey_x > cx:
                for k, line in enumerate(lines):
                    dpg.draw_text(
                        (grey_x + green_radius + 5,
                         text_y + (k * 16)),
                        line,
                        color=(255, 255, 255, 255),
                        size=20,
                        parent="tree_drawlist"
                    )
            else:
                for k, line in enumerate(lines):
                    dpg.draw_text(
                        (grey_x - 30,
                         grey_y + green_radius + 5 + (k * 16)),
                        line,
                        color=(255, 255, 255, 255),
                        size=20,
                        parent="tree_drawlist"
                    )

            clickable_nodes.append({
                "tag": tag,
                "x": grey_x,
                "y": grey_y,
                "radius": green_radius,
                "label": label,
                "choice": choice_num,
                "node": current
            })

    # draw green circles last so they appear on top of everything
    for i, node in enumerate(active_path):
        gx, gy = green_positions[id(node)]

        dpg.draw_circle(
            (gx, gy),
            green_radius,
            fill=(0, 200, 0, 255),
            color=(0, 150, 0, 255),
            thickness=2,
            parent="tree_drawlist"
        )

        if i == 0:
            label = "Start"
        else:
            parent = active_path[i - 1]
            # pass parent.options so Try/Catch green circle labels are enriched
            label = calculate_label(parent.options[node.choice_made - 1], None, parent.options)

        lines = wrap_text(label)

        if i == 0:
            # root node — always above
            for k, line in enumerate(reversed(lines)):
                dpg.draw_text(
                    (gx - 25, gy - green_radius - 18 - (k * 16)),
                    line,
                    color=(255, 255, 255, 255),
                    size=20,
                    parent="tree_drawlist"
                )
        elif node is session.current and node.terminal:
            # terminal node — always below
            for k, line in enumerate(lines):
                dpg.draw_text(
                    (gx - 25, gy + green_radius + 5 + (k * 16)),
                    line,
                    color=(255, 255, 255, 255),
                    size=20,
                    parent="tree_drawlist"
                )
        else:
            # non-root non-terminal — place label above on outer side
            # to avoid overlap with lines going down to children
            parent = active_path[i - 1]
            px, _ = green_positions[id(parent)]

            if gx < px:
                # node is left of parent — label above, right-aligned
                # use dpg.get_text_size for accurate width measurement across platforms
                for k, line in enumerate(lines):
                    text_width = get_text_width(line)
                    dpg.draw_text(
                        (gx - green_radius - text_width,
                         gy - green_radius - 18 - ((len(lines) - k - 1) * 20)),
                        line,
                        color=(255, 255, 255, 255),
                        size=20,
                        parent="tree_drawlist"
                    )
            elif gx > px:
                # node is right of parent — label above, starts at right edge
                for k, line in enumerate(reversed(lines)):
                    dpg.draw_text(
                        (gx + green_radius + 5,
                         gy - green_radius - 18 - (k * 16)),
                        line,
                        color=(255, 255, 255, 255),
                        size=20,
                        parent="tree_drawlist"
                    )
            else:
                # directly below parent — shift slightly right of vertical line
                for k, line in enumerate(reversed(lines)):
                    dpg.draw_text(
                        (gx + 5, gy - green_radius - 40 - (k * 16)),
                        line,
                        color=(255, 255, 255, 255),
                        size=20,
                        parent="tree_drawlist"
                    )


# called whenever the user clicks on the drawlist
# checks grey circles first — if so calls session.choose() or session.revisit() and redraws
# then checks green circles:
#   clicking current node — just shows its data
#   clicking an older node — rewinds to that point, discarding everything after it
def on_tree_click(sender, app_data):
    mouse_pos = dpg.get_drawing_mouse_pos()
    mx, my = mouse_pos[0], mouse_pos[1]

    # check clickable grey circles first
    for item in clickable_nodes:
        if is_inside_circle(mx, my, item["x"], item["y"], item["radius"]):
            if item["node"] is session.current:
                new_node = session.choose(item["choice"])
            else:
                new_node = session.revisit(item["node"], item["choice"])
            update_detail_panel(new_node)
            redraw_tree()
            return

    # check green circles on active path
    active_path = session.current.active_path()
    green_radius = 30
    start_y = 60
    level_height = 200

    for node in active_path:
        gx = calculate_node_x(node)
        gy = start_y + node.depth() * level_height
        if is_inside_circle(mx, my, gx, gy, green_radius):
            if node is session.current:
                # clicking current node — just show its data, no reset
                update_detail_panel(node)
            else:
                # clicking older node — rewind to that point
                # discards all nodes after it and restarts noname up to that point
                rewound_node = session.rewind(node)
                update_detail_panel(rewound_node)
                redraw_tree()
            return


# creates empty drawlist container
def setup_tree_panel():
    with dpg.drawlist(width=900, height=650, tag="tree_drawlist"):
        pass


def on_run_automatic(sender, app_data):
    dpg.set_value("auto_result", "Running...")

    # run noname non-interactively
    output = session.wrapper.run_automatic()

    # parse violation
    violation = parse_violation(output)

    if not violation:
        dpg.set_value("auto_result", "No privacy violation found.")
        return

    executed = violation.get("Executed", "")
    recipe_choice = violation.get("Recipe choice", "[]")
    beta = violation.get("beta_0", "")
    alpha = violation.get("alpha_0", "")
    checked = violation.get("Checked", "{}")

    dpg.set_value("auto_result",
        f"Violation found!\nalpha: {alpha}\nbeta: {beta}\nReplaying path...")

    # replay the violation path in the tree
    node = session.replay_violation(
        executed,
        recipe_choice,
        checked
    )

    update_detail_panel(node)
    redraw_tree()

    dpg.set_value("auto_result",
        f"Violation: {beta}")


def setup_detail_panel():
    with dpg.group(tag="detail_panel"):
        dpg.add_text("Select a node to view details", tag="detail_text")
        dpg.add_separator()

        # step navigation — covers both protocol and intruder analysis steps
        dpg.add_text("Step 0 of 0", tag="detail_step_counter")
        with dpg.group(horizontal=True):
            dpg.add_button(label="Previous", tag="btn_prev", callback=on_prev)
            dpg.add_button(label="Next", tag="btn_next", callback=on_next)
        dpg.disable_item("btn_prev")
        dpg.disable_item("btn_next")

        # button for making noname run non-interactively
        dpg.add_separator()
        dpg.add_button(
            label="Run noname (automatic mode)",
            tag="btn_auto",
            callback=on_run_automatic,
            width=220
        )
        dpg.add_text("", tag="auto_result", wrap=370)

        # state fields
        dpg.add_separator()
        dpg.add_text("Executed: ", tag="detail_executed", wrap=370)
        dpg.add_input_text(tag="detail_alpha", default_value="alpha_0: ", width=-1, readonly=True)
        dpg.add_input_text(tag="detail_beta", default_value="beta_0: ", width=-1, readonly=True)
        dpg.add_text("gamma_0: ", tag="detail_gamma", wrap=370)
        dpg.add_text("Recipe choice: ", tag="detail_recipe", wrap=370)
        dpg.add_text("Checked: ", tag="detail_checked", wrap=370)

        # transition description
        dpg.add_separator()
        dpg.add_text("Transition:", wrap=370)
        dpg.add_text("", tag="detail_transition", wrap=370)

        # flic and intruder analysis table
        # flic shown for all steps, analysis row shows current possibilities
        # multiple columns when branches exist, single column otherwise
        dpg.add_separator()
        with dpg.child_window(height=300, border=False, tag="table_window"):
            with dpg.table(tag="intruder_table",
                       header_row=True,
                       borders_innerH=True,
                       borders_innerV=True,
                       borders_outerH=True,
                       borders_outerV=True,
                       scrollX=True,
                       row_background=True):
                dpg.add_table_column(label="", width_fixed=True, init_width_or_weight=60)


# entry point
def main():
    global session, red_highlight_theme, default_input_theme

    if len(sys.argv) < 2:
        print("Usage: python3 gui.py <path_to_nn_file>")
        sys.exit(1)

    input_file = sys.argv[1]
    #session = Session("./noname", input_file)

    SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
    system = platform.system()
   

    if system == "Darwin":
        binary_path = os.path.join(SCRIPT_DIR, "noname-macos")
    elif system == "Linux":
        binary_path = os.path.join(SCRIPT_DIR, "noname-linux")
    else:
        binary_path = os.path.join(SCRIPT_DIR, "noname-linux")

    if not os.path.exists(binary_path):
        print(f"Error: noname binary not found at {binary_path}")
        print("Make sure the correct noname binary is in the same directory as gui.py")
        sys.exit(1)



    session = Session(binary_path, input_file)
    session.start()
    print("Options:", session.current.options)

    dpg.create_context()

    with dpg.theme() as red_highlight_theme:
        with dpg.theme_component(dpg.mvInputText):
            dpg.add_theme_color(dpg.mvThemeCol_FrameBg, (180, 30, 30, 180))
            dpg.add_theme_color(dpg.mvThemeCol_Text, (255, 255, 255, 255))

    with dpg.theme() as default_input_theme:
        with dpg.theme_component(dpg.mvInputText):
            dpg.add_theme_color(dpg.mvThemeCol_FrameBg, (37, 37, 38, 255))
            dpg.add_theme_color(dpg.mvThemeCol_Text, (255, 255, 255, 255))

    font_path = get_system_font()
    if font_path:
        with dpg.font_registry():
            with dpg.font(font_path, 20) as default_font:
                pass
        dpg.bind_font(default_font)
    else:
        print("Warning: no suitable system font found, some symbols may not display correctly")

    with dpg.item_handler_registry(tag="tree_handler"):
        dpg.add_item_clicked_handler(callback=on_tree_click)

    dpg.create_viewport(title="noname GUI", width=1100, height=700)
    dpg.setup_dearpygui()

    # set viewport resize callback so all panels adjust when window is resized
    dpg.set_viewport_resize_callback(on_resize)

    with dpg.window(label="noname", tag="main_window"):
        # set as primary window so it fills the entire viewport automatically
        dpg.set_primary_window("main_window", True)
        with dpg.group(horizontal=True):
            with dpg.child_window(width=600, height=650, tag="tree_window",
                                  horizontal_scrollbar=True):
                setup_tree_panel()
            with dpg.child_window(width=500, height=650, tag="detail_window",
                                  horizontal_scrollbar=True):
                setup_detail_panel()

    dpg.bind_item_handler_registry("tree_drawlist", "tree_handler")

    redraw_tree()

    dpg.show_viewport()
    dpg.start_dearpygui()
    dpg.destroy_context()

    session.terminate()


if __name__ == "__main__":
    main()