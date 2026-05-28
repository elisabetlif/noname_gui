from wrapper import Wrapper
from tree import TreeNode
import platform
import re


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
    

    def rewind(self, node: TreeNode) -> TreeNode:
        # restart noname and replay up to this node
        self.wrapper.terminate()
        self.wrapper = Wrapper(self.binary_path, self.input_file)
        self.wrapper.start()

        # replay all choices up to this node
        for past_choice in node.path_from_root():
            self.wrapper.send_choice(past_choice)

        # discard everything after this node
        node.child = None
        self.current = node

        return node

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

    
    #Replay the choices needed to reach a violation state.
    #Restarts noname and replays transactions and recipe choices.
    def replay_violation(self, executed: str, recipe_choice: str, checked: str) -> TreeNode:
        
        # restart noname from scratch
        self.wrapper.terminate()
        self.wrapper = Wrapper(self.binary_path, self.input_file)
        result = self.wrapper.start()

        # update root with fresh state from restart
        self.root.state = result["state"]
        self.root.options = result["options"]
        self.root.raw = result["raw"]
        self.root.child = None
        self.current = self.root

        # split executed into individual transactions
        transactions = [t.strip() for t in executed.split(".") if t.strip()]

        # parse recipe choices — split on ,R to avoid splitting inside function args
        recipes = []
        if recipe_choice and recipe_choice != "[]":
            inner = recipe_choice[1:-1]
            parts = re.split(r',(?=R\d)', inner)
            recipes = [p.strip() for p in parts]

        # parse checked equivalences e.g. {(l7,nonceErr),(l2,pk(i))}
        equiv_pairs = set()
        if checked and checked != "{}":
            inner = checked[1:-1]
            depth = 0
            current_pair = ""
            for char in inner:
                if char == "(" and not current_pair:
                    depth += 1
                    continue
                elif char == "(":
                    depth += 1
                    current_pair += char
                elif char == ")":
                    depth -= 1
                    if depth == 0:
                        comma_pos = current_pair.find(",")
                        if comma_pos != -1:
                            a = current_pair[:comma_pos].strip()
                            b = current_pair[comma_pos+1:].strip()
                            equiv_pairs.add((a, b))
                        current_pair = ""
                    else:
                        current_pair += char
                elif char == "," and depth == 0:
                    continue
                else:
                    current_pair += char

        # single interleaved replay loop —
        # at each step decide what kind of choice noname is presenting
        # and handle it accordingly: transaction, recipe, equivalence, or send
        max_iterations = 100
        iterations = 0
        tx_index = 0  # tracks which transaction we are up to

        while self.current.options and iterations < max_iterations:
            iterations += 1
            options = self.current.options

            # check what kind of options are being presented
            has_transaction = any("Execute the transaction" in opt for opt in options)
            has_recipe = any("The choice of" in opt for opt in options)
            has_equivalence = any("are equivalent" in opt or "are NOT equivalent" in opt for opt in options)
            has_send = any("A message is sent" in opt for opt in options)

            # --- transaction choice ---
            if has_transaction and tx_index < len(transactions):
                transaction = transactions[tx_index]
                matched = False
                for i, option in enumerate(options):
                    if f"Execute the transaction {transaction}." in option:
                        self.choose(i + 1)
                        tx_index += 1
                        matched = True
                        break
                if not matched:
                    print(f"WARNING: could not find transaction {transaction}")
                    return self.current
                continue

            # --- recipe choice ---
            if has_recipe:
                matched = False
                for recipe in recipes:
                    for i, option in enumerate(options):
                        if recipe in option and "The choice of" in option:
                            self.choose(i + 1)
                            matched = True
                            break
                    if matched:
                        break
                if not matched:
                    # pick first recipe option as fallback
                    for i, option in enumerate(options):
                        if "The choice of" in option:
                            self.choose(i + 1)
                            break
                continue

            # --- equivalence choice ---
            if has_equivalence:
                chose = False
                for i, option in enumerate(options):
                    m = re.search(r'recipes (\S+) and (\S+) are equivalent', option)
                    if m:
                        a = m.group(1).rstrip(".")
                        b = m.group(2).rstrip(".")
                        pair = (a, b)
                        if pair in equiv_pairs or (pair[1], pair[0]) in equiv_pairs:
                            self.choose(i + 1)
                            chose = True
                            break
                if not chose:
                    # not in checked — choose NOT equivalent
                    for i, option in enumerate(options):
                        if "are NOT equivalent" in option:
                            self.choose(i + 1)
                            break
                continue

            # --- send step ---
            if has_send:
                for i, option in enumerate(options):
                    if "A message is sent" in option:
                        self.choose(i + 1)
                        break
                continue

            # no more choices we know how to handle
            break

        return self.current