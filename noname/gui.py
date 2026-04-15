import sys
import platform
import math
import os
import dearpygui.dearpygui as dpg
from session import Session
from processor import split_up

# top layer -> talks only to session, never to the wrapper or tree directly

# globals
session = None
clickable_nodes = []
current_node = None
current_step_index = 0
current_steps = []


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


# calculates how tall the drawlist needs to be
def get_drawlist_height() -> int:
    depth = session.current.depth()
    min_height = 650
    calculated = (depth + 3) * 120 + 100
    return max(min_height, calculated)


# calculates how wide the drawlist needs to be
def get_drawlist_width() -> int:
    min_width = 580
    if session.current.terminal:
        return min_width
    total = len(session.current.options)
    spacing = 200
    calculated = total * spacing + 100
    return max(min_width, calculated)


def draw_line_between_circles(x1, y1, x2, y2, radius, color=(0, 0, 0, 255), thickness=2):
    dx = x2 - x1
    dy = y2 - y1
    length = math.sqrt(dx**2 + dy**2)
    if length == 0:
        return
    nx = dx / length
    ny = dy / length
    start_x = x1 + nx * radius
    start_y = y1 + ny * radius
    end_x = x2 - nx * radius
    end_y = y2 - ny * radius
    dpg.draw_line(
        (start_x, start_y),
        (end_x, end_y),
        color=color,
        thickness=thickness,
        parent="tree_drawlist"
    )


def wrap_text(text: str, max_chars: int = 15) -> list[str]:
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


# clears the drawlist entirely and redraws everything from scratch
def redraw_tree():
    global clickable_nodes
    clickable_nodes = []

    new_height = get_drawlist_height()
    new_width = get_drawlist_width()
    dpg.configure_item("tree_drawlist", height=new_height, width=new_width)

    dpg.delete_item("tree_drawlist", children_only=True)

    center_x = 280
    start_y = 60
    level_height = 120
    radius = 30

    active_path = session.current.active_path()

    # draw green nodes and connecting lines
    for i, node in enumerate(active_path):
        x = center_x
        y = start_y + (node.depth() * level_height)

        if i > 0:
            parent = active_path[i - 1]
            parent_y = start_y + (parent.depth() * level_height)
            draw_line_between_circles(
                center_x, parent_y,
                x, y,
                radius
            )

        dpg.draw_circle(
            (x, y),
            radius,
            fill=(0, 255, 0, 255),
            color=(0, 0, 0, 255),
            parent="tree_drawlist"
        )

        if i == 0:
            label = "Start"
        else:
            label = calculate_label(active_path[i - 1].options[node.choice_made - 1])
        dpg.draw_text(
            (x - 30, y - 50),
            label,
            color=(255, 255, 255, 255),
            size=16,
            parent="tree_drawlist"
        )

    # draw grey circles for current node's options
    current = session.current
    if not current.terminal:
        current_y = start_y + (current.depth() * level_height)
        child_y = current_y + level_height
        total = len(current.options)
        spacing = 200

        for i, option in enumerate(current.options):
            child_x = center_x - ((total - 1) * spacing / 2) + (i * spacing)
            tag = f"grey_circle_{i}"
            label = calculate_label(option)

            draw_line_between_circles(
                center_x, current_y,
                child_x, child_y,
                radius
            )

            dpg.draw_circle(
                (child_x, child_y),
                radius,
                fill=(180, 180, 180, 255),
                color=(0, 0, 0, 255),
                parent="tree_drawlist",
                tag=tag
            )

            lines = wrap_text(label)
            for j, line in enumerate(lines):
                dpg.draw_text(
                    (child_x - 40, child_y + radius + 5 + (j * 18)),
                    line,
                    color=(255, 255, 255, 255),
                    size=16,
                    parent="tree_drawlist"
                )

            clickable_nodes.append({
                "tag": tag,
                "x": child_x,
                "y": child_y,
                "radius": radius,
                "label": label,
                "choice": i + 1,
                "node": current
            })


# called whenever the user clicks on the drawlist
def on_tree_click(sender, app_data):
    mouse_pos = dpg.get_drawing_mouse_pos()
    mx, my = mouse_pos[0], mouse_pos[1]

    for item in clickable_nodes:
        if is_inside_circle(mx, my, item["x"], item["y"], item["radius"]):
            if item["node"] is session.current:
                new_node = session.choose(item["choice"])
            else:
                new_node = session.revisit(item["node"], item["choice"])
            update_detail_panel(new_node)
            redraw_tree()
            return

    active_path = session.current.active_path()
    center_x = 280
    start_y = 60
    level_height = 120
    radius = 30

    for node in active_path:
        x = center_x
        y = start_y + (node.depth() * level_height)
        if is_inside_circle(mx, my, x, y, radius):
            update_detail_panel(node)
            return


# creates empty drawlist container
def setup_tree_panel():
    with dpg.drawlist(width=580, height=650, tag="tree_drawlist"):
        pass


# creates the right side panel with all the text fields
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

        # transition description
        dpg.add_separator()
        dpg.add_text("Transition:", wrap=470)
        dpg.add_text("", tag="detail_transition", wrap=470)

        # state fields
        dpg.add_separator()
        dpg.add_text("Executed: ", tag="detail_executed", wrap=470)
        dpg.add_text("alpha_0: ", tag="detail_alpha", wrap=470)
        dpg.add_text("beta_0: ", tag="detail_beta", wrap=470)
        dpg.add_text("gamma_0: ", tag="detail_gamma", wrap=470)
        dpg.add_text("Recipe choice: ", tag="detail_recipe", wrap=470)
        dpg.add_text("Possibilities: ", tag="detail_possibilities", wrap=470)
        dpg.add_text("Checked: ", tag="detail_checked", wrap=470)

        # raw output
        dpg.add_separator()
        dpg.add_text("Raw output:", wrap=470)
        dpg.add_text("", tag="detail_raw", wrap=470)


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

    dpg.create_viewport(title="noname GUI", width=1100, height=700)
    dpg.setup_dearpygui()

    with dpg.window(label="noname", width=1100, height=700, tag="main_window"):
        with dpg.group(horizontal=True):
            with dpg.child_window(width=600, height=650, tag="tree_window", horizontal_scrollbar=True):
                setup_tree_panel()
            with dpg.child_window(width=500, height=650, tag="detail_window", horizontal_scrollbar=True):
                setup_detail_panel()

    dpg.bind_item_handler_registry("tree_drawlist", "tree_handler")

    redraw_tree()

    dpg.show_viewport()
    dpg.start_dearpygui()
    dpg.destroy_context()

    session.terminate()


if __name__ == "__main__":
    main()