

class Tree:
    def __init__(self,state, options, raw, choice_made=None, parent=None):
        self.state = state 
        self.options = options
        self.raw = raw
        self.choice_made = choice_made
        self.parent = parent
        self.child=None
        self.terminal = len(options)==0

    #makes replay possible -> user can return to a previous point
    def path_from_root(self) -> list[int]:
        path = []
        node = self
        while node.parent is not None:
            path.append(node.choice_made)
            node = node.parent
        return list(reversed(path))
    
    #if a user does revisit an old node and makes a new choice
    def make_choice(node,choice,new_state,new_options,new_raw):
        node.child = Tree(
            state=new_state,
            options=new_options,
            raw=new_raw,
            choice_made=choice,
            parent=node
        )
        return node.child