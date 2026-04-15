
#indepandant of noname and DearPyGui. just data structure 

class TreeNode:
    #stores state, options, raw, which choice led here, parent node.
    #Child starts as None since no choice has been made yet.
    #Terminal is derived from whether options is empty
    def __init__(self, state, options, raw, choice_made=None, parent=None):
        self.state = state
        self.options = options
        self.raw = raw
        self.choice_made = choice_made
        self.parent = parent
        self.child = None
        self.terminal = len(options) == 0

    #walks up the tree via parent pointers collecting choices, then reverses.
    #Gives you the exact sequence to replay noname to reach this node
    def path_from_root(self) -> list[int]:
        path = []
        node = self
        while node.parent is not None:
            path.append(node.choice_made)
            node = node.parent
        return list(reversed(path))

    #counts how many steps from root
    #Used by the GUI to calculate vertical position of circles
    def depth(self) -> int:
        d = 0
        node = self
        while node.parent is not None:
            d += 1
            node = node.parent
        return d

    #walks up to root collecting nodes, then reverses.
    #Gives the GIU the full list of green nodes to draw
    def active_path(self) -> list:
        path = []
        node = self
        while node is not None:
            path.append(node)
            node = node.parent
        return list(reversed(path))

    #creates a new TreeNode attached to this one
    #Called by session after every choice
    #if a child already existed it gets replaced and discarded
    def make_child(self, state, options, raw, choice_made) -> "TreeNode":
        self.child = TreeNode(
            state=state,
            options=options,
            raw=raw,
            choice_made=choice_made,
            parent=self
        )
        return self.child