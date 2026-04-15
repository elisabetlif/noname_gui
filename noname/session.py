from wrapper import Wrapper
from tree import TreeNode

#The coordinator -> owns both Wrapper and the tree root 
#the bridge between the Wrapper and GUI

class Session:
    #creates a Wrapper instance, sets root and current to None
    def __init__(self, binary_path: str, input_file: str):
        self.binary_path = binary_path
        self.input_file = input_file
        self.wrapper = Wrapper(binary_path, input_file)
        self.root = None
        self.current = None

    #calls wrapper.start(), creates the root TreeNode from the result, sets current to root, returns root to the GUI
    def start(self) -> TreeNode:
        result = self.wrapper.start()
        self.root = TreeNode(
            state=result["state"],
            options=result["options"],
            raw=result["raw"]
        )
        self.current = self.root
        return self.root
    
    #calls wrapper.send_choice(), creates a new child node via make_child(), updates current, returns root to GUI
    def choose(self, choice: int) -> TreeNode:
        result = self.wrapper.send_choice(choice)
        new_node = self.current.make_child(
            state=result["state"],
            options=result["options"],
            raw=result["raw"],
            choice_made=choice
        )
        self.current = new_node
        return new_node

    #terminates the wrapper, creates a fresh one, replays all choices up to the given node using path_from_root(), then makes the new choice
    #Discards everything after the revisited node by setting its child to None
    def revisit(self, node: TreeNode, choice: int) -> TreeNode:
        # restart noname entirely
        self.wrapper.terminate()
        self.wrapper = Wrapper(self.binary_path, self.input_file)
        self.wrapper.start()

        # replay all choices up to this node
        for past_choice in node.path_from_root():
            self.wrapper.send_choice(past_choice)

        # discard everything after this node
        node.child = None
        self.current = node

        # make the new choice
        return self.choose(choice)

    #cleans everything up
    def terminate(self):
        self.wrapper.terminate()
        self.root = None
        self.current = None