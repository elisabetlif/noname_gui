from wrapper import Wrapper
from tree import Tree


class Session:
    def __init__(self,binary_path, input_file):
        self.wrapper = Wrapper(binary_path,input_file)
        self.root = None
        self.current = None

    
    def start(self):
        result = self.wrapper.start()
        self.root=Tree(
            state=result["state"],
            options=result["options"],
            raw=result["raw"]
        )
        self.current = self.root
        return self.root

    def choose(self,choice:int) -> Tree:
        result = self.wrapper.send_choice(choice)
        new_node = Tree(
            state=result["state"],
            options=result["options"],
            raw=result["raw"],
            choice_made=choice,
            parent=self.current
        )
        self.current.child=new_node
        self.current=new_node
        return new_node
    
    def revisit(self, node: Tree, choice: int) -> Tree:
        # restart noname entirely
        self.wrapper.terminate()
        self.wrapper.start()
        
        #replay all choices up to this node
        for past_choice in node.path_from_root():
            self.wrapper.send_choice(past_choice)
        
        #discard everything after this node
        node.child = None
        self.current = node
        
        #now make the new choice
        return self.choose(choice)
