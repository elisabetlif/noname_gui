import sys
import platform
import math
import os
import dearpygui.dearpygui as dpg
from session import Session
from processor import split_up, process_possibilities, possibilities_with_checks, extract_flic

# top layer -> talks only to session, never to the wrapper or tree directly

# globals
session = None
clickable_nodes = []
current_node = None
current_step_index = 0
current_steps = []

# fixed center point — does not change regardless of tree width
CENTER_X = 450


# so all symbols from noname show up in GUI
def get_system_font() -> str | None:
    system = platform.system()
    if system == "Darwin":
        candidates = [
            "/Library/Fonts/Arial Unicode.ttf",
            "/System/Library/Fonts/Supplemental/Geneva.ttf",
        ]
    elif system == "Windows":
        candidates = [
            "C:/Windows/Fonts/arial.ttf",
            "C:/Windows/Fonts/seguisym.ttf",
        ]
    elif system == "Linux":
        candidates = [
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/dejavu/DejaVuSans.ttf",
        ]
    else:
        return None
    for path in candidates:
        if os.path.exists(path):
            return path
    return None


# extracts the human readable name from the full option string
def calculate_label(option: str) -> str:
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


#step display shows what step from the noname output the user is on
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
            dpg.set_value("detail_possibilities", f"Possibilities: {state.get('Possibilities', '')}")
            dpg.set_value("detail_checked", f"Checked: {state.get('Checked', '')}")
            dpg.set_value("detail_raw", current_node.raw)
            # no steps to compare so just show processed possibilities without checkmarks
            dpg.set_value("detail_initial_possibilities", process_possibilities(state.get('Possibilities', '')))
            # extract and display flic from current possibilities
            flic_items = extract_flic(state.get("Possibilities", ""))
            dpg.set_value("detail_flic", "\n".join(flic_items) if flic_items else "")
        dpg.disable_item("btn_prev")
        dpg.disable_item("btn_next")
        return

    total = len(current_steps)
    step = current_steps[current_step_index]
    fields = step["fields"]

    dpg.set_value("detail_step_counter", f"Step {current_step_index + 1} of {total}")
    dpg.set_value("detail_transition", f"{step['transition']}")
    dpg.set_value("detail_executed", f"Executed: {fields.get('Executed', '')}")
    dpg.set_value("detail_alpha", f"alpha_0: {fields.get('alpha_0', '')}")
    dpg.set_value("detail_beta", f"beta_0: {fields.get('beta_0', '')}")
    dpg.set_value("detail_recipe", f"Recipe choice: {fields.get('Recipe choice', '')}")
    dpg.set_value("detail_gamma", f"gamma_0: {fields.get('gamma_0', '')}")
    dpg.set_value("detail_possibilities", f"Possibilities: {fields.get('Possibilities', '')}")
    dpg.set_value("detail_checked", f"Checked: {fields.get('Checked', '')}")
    dpg.set_value("detail_raw", current_node.raw)

    # extract and display flic from current step's possibilities
    # updates dynamically as user steps through with Next/Previous
    flic_items = extract_flic(fields.get("Possibilities", ""))
    dpg.set_value("detail_flic", "\n".join(flic_items) if flic_items else "")

    # update checkmarks based on current step
    # collects all possibilities seen so far up to current step
    # a step only gets a checkmark if it was seen at position [0] AND has since disappeared
    all_possibilities = [
        current_steps[i]["fields"].get("Possibilities", "")
        for i in range(current_step_index + 1)
    ]
    steps = possibilities_with_checks(
        current_steps[0]["fields"].get("Possibilities", ""),
        all_possibilities
    )
    text = "\n".join(
        f"✓ {s['step']}" if s['done'] else s['step']
        for s in steps
    )
    dpg.set_value("detail_initial_possibilities", text)

    # update button states
    if current_step_index <= 0:
        dpg.disable_item("btn_prev")
    else:
        dpg.enable_item("btn_prev")

    if current_step_index >= total - 1:
        dpg.disable_item("btn_next")
    else:
        dpg.enable_item("btn_next")


# takes a TreeNode and populates the right side panel with its state fields
def update_detail_panel(node):
    global current_node, current_step_index, current_steps
    current_node = node
    current_step_index = 0
    current_steps = split_up(node.raw)
    refresh_step_display()


#next button in step display
def on_next(sender, app_data):
    global current_step_index
    if current_step_index < len(current_steps) - 1:
        current_step_index += 1
        refresh_step_display()


#prev button in step display
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


#line that connects circles in the tree part of the gui
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


#so the labels underneath the circles don't intersect (that is, not too long)
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

#Calculate the x position of a node based on its path from root
#Each choice shifts the position left or right, with spread halving at each depth.
#Uses fixed CENTER_X so the tree never shifts unexpectedly
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

#Calculates the x position of a grey circle representing an unchosen option
# Uses the same logic as calculate_node_x — the grey circle sits where the green node WOULD be if that choice had been made
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
    char_width = 7

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
                label = calculate_label(option)
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
                text_y = grey_y - (len(lines) * 14) / 2
                if grey_x < gx:
                    for k, line in enumerate(lines):
                        text_width = len(line) * char_width
                        dpg.draw_text(
                            (grey_x - grey_radius - text_width,
                             text_y + (k * 14)),
                            line,
                            color=(180, 180, 180, 255),
                            size=13,
                            parent="tree_drawlist"
                        )
                elif grey_x > gx:
                    for k, line in enumerate(lines):
                        dpg.draw_text(
                            (grey_x + grey_radius + 5,
                             text_y + (k * 14)),
                            line,
                            color=(180, 180, 180, 255),
                            size=13,
                            parent="tree_drawlist"
                        )
                else:
                    for k, line in enumerate(lines):
                        dpg.draw_text(
                            (grey_x - 25,
                             grey_y + grey_radius + 3 + (k * 14)),
                            line,
                            color=(180, 180, 180, 255),
                            size=13,
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

        for j, option in enumerate(current.options):
            choice_num = j + 1
            grey_x = calculate_grey_x(current, choice_num)
            grey_y = cy + level_height
            tag = f"grey_current_{j}"
            label = calculate_label(option)
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
            text_y = grey_y - (len(lines) * 14) / 2
            if grey_x < cx:
                for k, line in enumerate(lines):
                    text_width = len(line) * char_width
                    dpg.draw_text(
                        (grey_x - green_radius - text_width,
                         text_y + (k * 14)),
                        line,
                        color=(255, 255, 255, 255),
                        size=14,
                        parent="tree_drawlist"
                    )
            elif grey_x > cx:
                for k, line in enumerate(lines):
                    dpg.draw_text(
                        (grey_x + green_radius + 5,
                         text_y + (k * 14)),
                        line,
                        color=(255, 255, 255, 255),
                        size=14,
                        parent="tree_drawlist"
                    )
            else:
                for k, line in enumerate(lines):
                    dpg.draw_text(
                        (grey_x - 30,
                         grey_y + green_radius + 5 + (k * 16)),
                        line,
                        color=(255, 255, 255, 255),
                        size=14,
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
            label = calculate_label(parent.options[node.choice_made - 1])

        lines = wrap_text(label)

        if i == 0:
            # root node — always above
            for k, line in enumerate(reversed(lines)):
                dpg.draw_text(
                    (gx - 25, gy - green_radius - 18 - (k * 14)),
                    line,
                    color=(255, 255, 255, 255),
                    size=14,
                    parent="tree_drawlist"
                )
        elif node is session.current and node.terminal:
            # terminal node — always below
            for k, line in enumerate(lines):
                dpg.draw_text(
                    (gx - 25, gy + green_radius + 5 + (k * 14)),
                    line,
                    color=(255, 255, 255, 255),
                    size=14,
                    parent="tree_drawlist"
                )
        else:
            # non-root non-terminal — place label above on outer side
            # to avoid overlap with lines going down to children
            parent = active_path[i - 1]
            px, _ = green_positions[id(parent)]

            if gx < px:
                # node is left of parent — label above, right-aligned
                for k, line in enumerate(lines):
                    text_width = len(line) * char_width
                    dpg.draw_text(
                        (gx - green_radius - text_width,
                         gy - green_radius - 18 - ((len(lines) - k - 1) * 14)),
                        line,
                        color=(255, 255, 255, 255),
                        size=14,
                        parent="tree_drawlist"
                    )
            elif gx > px:
                # node is right of parent — label above, starts at right edge
                for k, line in enumerate(reversed(lines)):
                    dpg.draw_text(
                        (gx + green_radius + 5,
                         gy - green_radius - 18 - (k * 14)),
                        line,
                        color=(255, 255, 255, 255),
                        size=14,
                        parent="tree_drawlist"
                    )
            else:
                # directly below parent — shift slightly right of vertical line
                for k, line in enumerate(reversed(lines)):
                    dpg.draw_text(
                        (gx + 5, gy - green_radius - 40 - (k * 14)),
                        line,
                        color=(255, 255, 255, 255),
                        size=14,
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


# creates the right side detail panel with all the state fields
def setup_detail_panel():
    with dpg.group(tag="detail_panel"):
        dpg.add_text("Select a node to view details", tag="detail_text")
        dpg.add_separator()

        # step navigation
        dpg.add_text("Step 0 of 0", tag="detail_step_counter")
        with dpg.group(horizontal=True):
            dpg.add_button(label="Previous", tag="btn_prev", callback=on_prev)
            dpg.add_button(label="Next", tag="btn_next", callback=on_next)
        dpg.disable_item("btn_prev")
        dpg.disable_item("btn_next")
        dpg.add_separator()

         # state fields
        dpg.add_separator()
        dpg.add_text("Executed: ", tag="detail_executed", wrap=370)
        dpg.add_text("alpha_0: ", tag="detail_alpha", wrap=370)
        dpg.add_text("beta_0: ", tag="detail_beta", wrap=370)
        dpg.add_text("gamma_0: ", tag="detail_gamma", wrap=370)
        dpg.add_text("Recipe choice: ", tag="detail_recipe", wrap=370)
        dpg.add_text("Possibilities: ", tag="detail_possibilities", wrap=370)
        dpg.add_text("Checked: ", tag="detail_checked", wrap=370)


        # messages and recipes observed by the intruder so far
        dpg.add_separator()
        dpg.add_text("FLIC:", wrap=370)
        dpg.add_text("", tag="detail_flic", wrap=370)
        dpg.add_separator()

        # show all initial possibilities in the first step of the protocol
        # checkmarks appear as noname examines each step
        dpg.add_text("", tag="detail_initial_possibilities", wrap=370)

        #Analysis (what the intruder is up to)
        dpg.add_separator()
        dpg.add_text("Analysis", wrap=370)

        # transition description
        dpg.add_separator()
        dpg.add_text("Transition:", wrap=370)
        dpg.add_text("", tag="detail_transition", wrap=370)

        # raw output
        dpg.add_separator()
        dpg.add_text("Raw output:", wrap=370)
        dpg.add_text("", tag="detail_raw", wrap=370)


# entry point
def main():
    global session

    if len(sys.argv) < 2:
        print("Usage: python3 gui.py <path_to_nn_file>")
        sys.exit(1)

    input_file = sys.argv[1]
    session = Session("./noname", input_file)
    session.start()

    dpg.create_context()

    font_path = get_system_font()
    if font_path:
        with dpg.font_registry():
            with dpg.font(font_path, 16) as default_font:
                dpg.add_font_range_hint(dpg.mvFontRangeHint_Default)
                dpg.add_font_range(0x2200, 0x22FF)
                dpg.add_font_range(0x2100, 0x214F)
                dpg.add_font_range(0x0370, 0x03FF)
                dpg.add_font_range(0x2700, 0x27BF)
                dpg.add_font_range(0x2600, 0x26FF)
        dpg.bind_font(default_font)
    else:
        print("Warning: no suitable system font found, some symbols may not display correctly")

    with dpg.item_handler_registry(tag="tree_handler"):
        dpg.add_item_clicked_handler(callback=on_tree_click)

    dpg.create_viewport(title="noname GUI", width=1000, height=700)
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
            with dpg.child_window(width=400, height=650, tag="detail_window",
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