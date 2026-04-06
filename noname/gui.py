import dearpygui.dearpygui as dpg

clickable_nodes = [
    {"tag": "circle_challenge_left", "x": 200, "y": 180, "radius": 30, "label": "Challenge"},
    {"tag": "circle_grandchild", "x": 300, "y": 300, "radius": 30, "label": "Challenge"},
]

def is_inside_circle(mouse_x, mouse_y, cx, cy, radius):
    return (mouse_x - cx) ** 2 + (mouse_y - cy) ** 2 <= radius ** 2

def redraw_circle(tag, x, y, radius, color):
    dpg.delete_item(tag)
    with dpg.draw_node(tag=tag, parent="tree_drawlist"):
        dpg.draw_circle((x, y), radius, fill=color, color=(0,0,0,255))

def on_tree_click(sender, app_data):
    mouse_pos = dpg.get_drawing_mouse_pos()
    mx, my = mouse_pos[0], mouse_pos[1]
    for node in clickable_nodes:
        if is_inside_circle(mx, my, node["x"], node["y"], node["radius"]):
            dpg.set_value("detail_text", f"Clicked: {node['label']}")
            redraw_circle(node["tag"], node["x"], node["y"], node["radius"], (0,255,0,255))
            print(f"Clicked node: {node['label']}")

def setup_tree_panel():
    with dpg.drawlist(width=600, height=600, tag="tree_drawlist"):
        root_x, root_y = 300, 60
        child1_x, child1_y = 200, 180
        child2_x, child2_y = 400, 180
        grandchild1_x, grandchild1_y = 300, 300
        radius = 30

        dpg.draw_line((root_x, root_y), (child1_x, child1_y), color=(0,0,0,255), thickness=2)
        dpg.draw_line((root_x, root_y), (child2_x, child2_y), color=(0,0,0,255), thickness=2)
        dpg.draw_line((child2_x, child2_y), (grandchild1_x, grandchild1_y), color=(0,0,0,255), thickness=2)

        dpg.draw_circle((root_x, root_y), radius, fill=(0,255,0,255), color=(0,0,0,255))
        dpg.draw_circle((child2_x, child2_y), radius, fill=(0,255,0,255), color=(0,0,0,255))
        dpg.draw_circle((child1_x, child1_y), radius, fill=(180,180,180,255), color=(0,0,0,255), tag="circle_challenge_left")
        dpg.draw_circle((grandchild1_x, grandchild1_y), radius, fill=(180,180,180,255), color=(0,0,0,255), tag="circle_grandchild")

        dpg.draw_text((root_x - 35, root_y - 50), "Challenge", color=(0,0,0,255), size=16)
        dpg.draw_text((child1_x - 35, child1_y - 50), "Challenge", color=(0,0,0,255), size=16)
        dpg.draw_text((child2_x - 35, child2_y - 50), "Response", color=(0,0,0,255), size=16)
        dpg.draw_text((grandchild1_x - 35, grandchild1_y - 50), "Challenge", color=(0,0,0,255), size=16)

def setup_detail_panel():
    with dpg.group(tag="detail_panel"):
        dpg.add_text("Select a node to view details", tag="detail_text")
        dpg.add_separator()
        dpg.add_text("Executed: ", tag="detail_executed")
        dpg.add_text("alpha_0: ", tag="detail_alpha")
        dpg.add_text("beta_0: ", tag="detail_beta")
        dpg.add_text("Recipe choice: ", tag="detail_recipe")

dpg.create_context()

with dpg.item_handler_registry(tag="tree_handler"):
    dpg.add_item_clicked_handler(callback=on_tree_click)

dpg.create_viewport(title="noname GUI", width=1000, height=700)
dpg.setup_dearpygui()

with dpg.window(label="noname", width=1000, height=700, tag="main_window"):
    with dpg.group(horizontal=True):
        with dpg.child_window(width=600, height=650, tag="tree_window"):
            setup_tree_panel()
        with dpg.child_window(width=380, height=650, tag="detail_window"):
            setup_detail_panel()

dpg.bind_item_handler_registry("tree_drawlist", "tree_handler")

dpg.show_viewport()
dpg.start_dearpygui()
dpg.destroy_context()