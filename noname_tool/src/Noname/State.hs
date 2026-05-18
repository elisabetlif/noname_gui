-- SPDX-FileCopyrightText: 2023 Technical University of Denmark
--
-- SPDX-License-Identifier: BSD-3-Clause
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Noname.State
Description : Fundamental definitions for symbolic states.
Copyright   : 2023 Technical University of Denmark
License     : BSD-3-Clause
Maintainer  : lpkf@dtu.dk
Stability   : experimental
-}
module Noname.State where

-- base
import Data.List (foldl1', nub)

-- containers
import Data.Map (Map)
import qualified Data.Map as Map

-- text
import Data.Text (Text)
import qualified Data.Text as Text

-- | Like @'show'@, but return @'Text'@.
tshow :: Show a => a -> Text
tshow = Text.pack . show

-- | Like @'error'@, but expect @'Text'@.
terror :: Text -> a
terror = error . Text.unpack

-- | A term is either atomic or composed with subterms.
data Term a b
  = -- | Atomic term.
    Atom b
  | -- | Composed term.
    Comp a [Term a b]
  deriving (Eq, Ord, Show)

-- | Representation of identifiers.
type Identifier = Text

-- | Variable names.
type Variable = Identifier

-- | Function names.
type Function = Identifier

-- | The arity denotes how many arguments a function or relation takes.
type Arity = Int

-- | Relation names.
type Relation = Identifier

-- | Cell names.
type Cell = Identifier

-- | A label is a special identifier for messages in the intruder knowledge.
type Label = Identifier

-- | A message is a term using privacy and intruder variables and functions.
type Message = Term Function Variable

-- | Like @'Message'@, but is used with labels and recipe variables.
type Recipe = Message

-- | A substitution instantiates variables with messages.
type Substitution = Map Variable Message

-- | A choice of recipes instantiates variables with recipes.
type RecipeChoice = Map Variable Recipe

-- | A domain is a list of constants (functions of arity 0).
type Domain = [Function]

-- | The hole is a special variable that represents a placeholder for messages.
hole :: Variable
hole = "_"

{- | A context is a ground message, i.e., without any variables except for the
@'hole'@, which is replaced by a message when the context is applied.
-}
type Context = Message

-- | @'meta'@ is a special identifier for the meta-notation.
meta :: Identifier
meta = "gamma"

-- | A symbol represents the different datatypes that identifiers can refer to.
data Symbol
  = -- | Privacy variable, with associated domain.
    Pvar Domain
  | -- | Intruder variable.
    Ivar
  | -- | Recipe variable.
    Rvar
  | -- | Function, with associated arity.
    Fun Arity
  | -- | Relation, with associated arity.
    Rel Arity
  | -- | Memory cell.
    Cel
  | -- | Label.
    Lab
  deriving (Eq, Ord, Show)

-- | A symbol table associates identifiers with symbols.
type SymbolTable = Map Identifier Symbol

-- | A theory associates destructors with arguments and decomposition result.
type Theory = Map Function ([Message], Message)

-- | An interpretation associates relations with lists of lists of messages.
type Interpretation = Map Relation [[Message]]

-- | A mark denotes the status for analysis of messages.
data Mark
  = -- | For a completely analyzed message.
    Done
  | -- | For a message that may be further analyzed.
    Hold
  | -- | For a message to be analyzed.
    Todo
  deriving (Eq, Show)

-- | A marking is a term using marks.
type Marking = Term Mark Mark

-- | A mapping is either a received message or a sent message.
data Mapping
  = -- | A received message is labelled and marked.
    Rcv Label Message Marking
  | -- | A sent message binds a recipe variable.
    Snd Variable Message
  deriving (Eq, Show)

-- | A FLIC is a list of mappings.
type Flic = [Mapping]

-- | The domain of the FLIC is the list of labels in the FLIC.
dom :: Flic -> [Label]
dom [] = []
dom (Rcv l _ _ : a) = l : dom a
dom (Snd _ _ : a) = dom a

-- | A quantifier-free FOL formula.
data Formula
  = -- | Trivially true formula.
    Top
  | -- | Equality between messages.
    Equality Message Message
  | -- | Relation over messages.
    Relational Relation [Message]
  | -- | Negation.
    Neg Formula
  | -- | Conjunction.
    And Formula Formula
  deriving (Eq, Show)

-- | The conjunction of the list of formulas.
conjunction :: [Formula] -> Formula
conjunction phis =
  case filter (/= Top) phis of
    [] -> Top
    phis' -> if Neg Top `elem` phis' then Neg Top else foldl1' And phis'

-- | The disjunction of the list of formulas.
disjunction :: [Formula] -> Formula
disjunction phis =
  case filter (/= Neg Top) phis of
    [phi] -> phi
    phis' -> if Top `elem` phis' then Top else Neg . conjunction $ map Neg phis'

-- | The implication between formulas.
implies :: Formula -> Formula -> Formula
implies phi psi = disjunction [Neg phi, psi]

{- | Given a variable \(x\) and a domain \(D\), define the @'Formula'@
corresponding to \(x \in D\).
-}
inDom :: Variable -> Domain -> Formula
inDom x = disjunction . map (\c -> Equality (Atom x) $ Comp c [])

-- | Transform the substitution into a formula.
substitutionFormula :: Substitution -> Formula
substitutionFormula =
  conjunction . map (\(x, t) -> Equality (Atom x) t) . Map.assocs

-- | Mode for non-deterministic choices of variables.
data Mode
  = -- | The mode \(\star\) for \(\alpha\)-variables.
    Star
  | -- | The mode \(\diamond\) for \(\beta\)-variables.
    Diamond
  deriving (Eq, Show)

-- | A left process is the first part in a transaction.
data LeftProcess
  = -- | Non-deterministic choice of variable.
    Choice Mode Variable Domain LeftProcess
  | -- | Receive a message.
    Receive Variable LeftProcess
  | -- | Let expression binding.
    LetLeft Variable Message LeftProcess
  | -- | Continue with a center process.
    Center CenterProcess
  deriving (Eq, Show)

-- | A center process is after a left process and before a right process.
data CenterProcess
  = -- | Destructor application.
    Try Variable Function [Message] CenterProcess CenterProcess
  | -- | Cell read.
    Read Variable Cell Message CenterProcess
  | -- | Conditional statement.
    If Formula CenterProcess CenterProcess
  | -- | Let expression binding.
    LetCenter Variable Message CenterProcess
  | -- | Fresh constants.
    New [Variable] RightProcess
  deriving (Eq, Show)

-- | A right process is the last part in a transaction.
data RightProcess
  = -- | Send a message.
    Send Message RightProcess
  | -- | Cell write.
    Write Cell Message Message RightProcess
  | -- | Release a formula in \(\alpha\) (releases in \(\beta\) not supported).
    Release Mode Formula RightProcess
  | -- | Let expression binding.
    LetRight Variable Message RightProcess
  | -- | Terminate with the nil process.
    Nil
  deriving (Eq, Show)

-- | A process is a left, center or right process
data Process
  = -- | Left process.
    Pl LeftProcess
  | -- | Center process.
    Pc CenterProcess
  | -- | Right process.
    Pr RightProcess
  deriving (Eq, Show)

{- | A disequality consists of a list of universally quantified variables and a
list of negated equalities.
-}
type Disequality = ([Variable], [(Message, Message)])

-- | A memory update changes the value returned when accessing a cell.
data MemoryUpdate
  = -- | Update the memory in the given cell.
    MemoryUpdate Cell Message Message
  deriving (Eq, Show)

{- | A possibility contains a process, the condition to reach that possibility
(a formula actually represented here with several substitutions and formulas),
a FLIC, some disequalities, a partial payload and a list of memory updates.
-}
data Possibility = Possibility
  { process :: Process
  -- ^ The process \(P_i\)
  , conditionEqs :: Substitution
  -- ^ The equalities part of \(\phi_i\)
  , conditionDiseqs :: [Substitution]
  -- ^ The disequalities part of \(\phi_i\)
  , relations :: [Formula]
  -- ^ The relations part of \(\phi_i\)
  , flic :: Flic
  -- ^ The FLIC \(\mathcal{A}_i\)
  , diseqs :: [Disequality]
  -- ^ The disequalities \(\mathcal{X}_i\)
  , partialPayload :: Formula
  -- ^ The partial payload \(\alpha_i\)
  , memory :: [MemoryUpdate]
  -- ^ The list of memory updates \(\delta_i\)
  }
  deriving (Eq, Show)

{- | Transform the substitutions expressing equalities and disequalities into a
formula.
-}
constraintsFormula :: Substitution -> [Substitution] -> Formula
constraintsFormula sigma taus =
  conjunction $ substitutionFormula sigma : map (Neg . substitutionFormula) taus

-- | Define the formula expressing the condition for reaching the possibility.
condition :: Possibility -> Formula
condition p =
  conjunction $
    constraintsFormula (conditionEqs p) (conditionDiseqs p) : relations p

{- | A @t'State'@ represents a symbolic state. The formulas \(\alpha_0\) and
\(\beta_0\) can be defined from the symbol table, the \(\alpha\)- and
\(\beta\)- variables and the possibilities.
-}
data State = State
  { counterTab :: Map Text Int
  -- ^ The counters for generating fresh identifiers.
  , symbolTab :: SymbolTable
  -- ^ The symbol table.
  , contextTab :: Map Cell Context
  -- ^ The association of cells to contexts.
  , theory :: Theory
  -- ^ The equational theory encoded with rewrite rules.
  , destructorTab :: Map Function [Function]
  -- ^ The association of constructors to destructors.
  , public :: [Function]
  -- ^ The public functions.
  , transparent :: [Function]
  -- ^ The transparent functions.
  , transactionTab :: Map Identifier LeftProcess
  -- ^ The protocol transactions.
  , executed :: [Text]
  -- ^ The list of transactions executed.
  , recipeChoice :: RecipeChoice
  -- ^ The choice of recipes so far.
  , alphaVars :: [Variable]
  -- ^ The \(\alpha\)-variables.
  , betaVars :: [Variable]
  -- ^ The \(\beta\)-variables.
  , interpretation :: Interpretation
  -- ^ The fixed interpretation of relations.
  , possibilities :: [Possibility]
  -- ^ The possibilities \(\mathcal{P}\).
  , checked :: [(Label, Recipe)]
  -- ^ The pairs of recipes checked \(\mathit{Checked}\).
  , solver :: String
  -- ^ The solver to use.
  }
  deriving (Eq, Show)

-- | The domain of the state is the domain of some FLIC in that state.
domState :: State -> [Label]
domState state =
  case possibilities state of
    [] -> terror "State.domState"
    p : _ -> dom $ flic p

-- | Whether the function is public.
isPublic :: State -> Function -> Bool
isPublic state f = f `elem` public state

-- | Whether the function is transparent.
isTransparent :: State -> Function -> Bool
isTransparent state f = f `elem` transparent state

{- | The initial state is empty, except that it contains one initial possibility
where the process is nil and the condition is true.
-}
initialState :: State
initialState =
  State
    { counterTab =
        Map.fromList [("Pvar", 1), ("Ivar", 1), ("Rvar", 1), ("Const", 1), ("Label", 1)]
    , symbolTab = Map.empty
    , contextTab = Map.empty
    , theory = Map.empty
    , destructorTab = Map.empty
    , public = []
    , transparent = []
    , transactionTab = Map.empty
    , executed = []
    , recipeChoice = Map.empty
    , alphaVars = []
    , betaVars = []
    , interpretation = Map.empty
    , possibilities =
        [ Possibility
            { process = Pr Nil
            , conditionEqs = Map.empty
            , conditionDiseqs = []
            , relations = []
            , flic = []
            , diseqs = []
            , partialPayload = Top
            , memory = []
            }
        ]
    , checked = []
    , solver = "cvc5"
    }

-- | The arity associated to the function.
arity :: State -> Function -> Arity
arity state f =
  case Map.lookup f $ symbolTab state of
    Just (Fun n) -> n
    _ -> terror "State.arity"

-- | The domain associated to the privacy variable.
domPvar :: State -> Variable -> Domain
domPvar state x =
  case Map.lookup x $ symbolTab state of
    Just (Pvar d) -> d
    _ -> terror "State.domPvar"

-- | Define \(\alpha_0\) based on the \(\alpha\)-variables and their domains.
alpha0 :: State -> Formula
alpha0 state =
  let xs = alphaVars state
      ds = map (domPvar state) xs
  in  conjunction $ zipWith inDom xs ds

{- | Define \(\beta_0\) based on the \(\beta\)-variables and their domains, and
the conditions of the possibilities.
-}
beta0 :: State -> (Formula, Formula)
beta0 state =
  let ys = betaVars state
      ds = map (domPvar state) ys
      ysInDomains = conjunction $ zipWith inDom ys ds
      phi = disjunction . map condition $ possibilities state
  in  (ysInDomains, phi)

{- | Define \(\gamma_0\) as the formula corresponding to the fixed
interpretation of relations.
-}
gamma0 :: State -> Formula
gamma0 state =
  let applyRelation (r, l) = map (Relational r) l
  in  conjunction . concatMap applyRelation . Map.assocs $ interpretation state

-- | The list of all variables occurring in the message.
vars :: Message -> [Variable]
vars = nub . go
 where
  go :: Message -> [Variable]
  go (Atom x) = [x]
  go (Comp _ ts) = concatMap go ts

-- | Whether the variable is an intruder variable.
isIvar :: State -> Variable -> Bool
isIvar state x = Map.lookup x (symbolTab state) == Just Ivar

-- | The list of all intruder variables occurring in the message.
ivars :: State -> Message -> [Variable]
ivars state = filter (isIvar state) . vars

-- | Apply the substitution to the message.
substitute :: Substitution -> Message -> Message
substitute sigma t@(Atom x) =
  case Map.lookup x sigma of
    Nothing -> t
    Just s -> if s == t then t else substitute sigma s
substitute sigma (Comp f ts) = Comp f $ map (substitute sigma) ts

{- | Partition the substitution into two substitutions: one for intruder
variables and one for privacy variables.
-}
partitionSubstitution :: State -> Substitution -> (Substitution, Substitution)
partitionSubstitution state sigma =
  let (sigmaIvar, sigmaPvar) = Map.partitionWithKey (\x _ -> isIvar state x) sigma
  in  (Map.map (substitute sigmaPvar) sigmaIvar, sigmaPvar)

-- | Whether the substitution only substitutes privacy variables.
isPriv :: State -> Substitution -> Bool
isPriv state = null . fst . partitionSubstitution state

-- | Apply the substitution to the message in the mapping.
substituteMapping :: Substitution -> Mapping -> Mapping
substituteMapping sigma (Rcv l t m) = Rcv l (substitute sigma t) m
substituteMapping sigma (Snd r t) = Snd r $ substitute sigma t

-- | Apply the substitution to all messages in the FLIC.
substituteFlic :: Substitution -> Flic -> Flic
substituteFlic sigma = map $ substituteMapping sigma

-- | Apply the substitution to all messages in the formula.
substituteFormula :: Substitution -> Formula -> Formula
substituteFormula _ Top = Top
substituteFormula sigma (Equality s t) =
  Equality (substitute sigma s) $ substitute sigma t
substituteFormula sigma (Relational r ts) =
  Relational r $ map (substitute sigma) ts
substituteFormula sigma (Neg phi) = Neg $ substituteFormula sigma phi
substituteFormula sigma (And phi psi) =
  And (substituteFormula sigma phi) $ substituteFormula sigma psi

{- | Apply the substitution to the left process. The variables bound in a choice
or receive are not affected.
-}
substituteLeftProcess :: Substitution -> LeftProcess -> LeftProcess
substituteLeftProcess sigma (Choice mode x d pl) =
  Choice mode x d $ substituteLeftProcess sigma pl
substituteLeftProcess sigma (Receive x pl) =
  Receive x $ substituteLeftProcess sigma pl
substituteLeftProcess sigma (LetLeft x t pl) =
  LetLeft x (substitute sigma t) $ substituteLeftProcess sigma pl
substituteLeftProcess sigma (Center pc) =
  Center $ substituteCenterProcess sigma pc

{- | Apply the substitution to the center process. The variables bound in a
destructor application, cell read or fresh constant are not affected.
-}
substituteCenterProcess :: Substitution -> CenterProcess -> CenterProcess
substituteCenterProcess sigma (Try x d ts pc1 pc2) =
  Try x d (map (substitute sigma) ts) (substituteCenterProcess sigma pc1) $
    substituteCenterProcess sigma pc2
substituteCenterProcess sigma (Read x cell t pc) =
  Read x cell (substitute sigma t) $ substituteCenterProcess sigma pc
substituteCenterProcess sigma (If phi pc1 pc2) =
  If (substituteFormula sigma phi) (substituteCenterProcess sigma pc1) $
    substituteCenterProcess sigma pc2
substituteCenterProcess sigma (LetCenter x t pc) =
  LetCenter x (substitute sigma t) $ substituteCenterProcess sigma pc
substituteCenterProcess sigma (New xs pr) =
  New xs $ substituteRightProcess sigma pr

-- | Apply the substitution to the right process.
substituteRightProcess :: Substitution -> RightProcess -> RightProcess
substituteRightProcess sigma (Send t pr) =
  Send (substitute sigma t) $ substituteRightProcess sigma pr
substituteRightProcess sigma (Write cell s t pr) =
  Write cell (substitute sigma s) (substitute sigma t) $
    substituteRightProcess sigma pr
substituteRightProcess sigma (Release mode phi pr) =
  Release mode (substituteFormula sigma phi) $ substituteRightProcess sigma pr
substituteRightProcess sigma (LetRight x t pr) =
  LetRight x (substitute sigma t) $ substituteRightProcess sigma pr
substituteRightProcess _ Nil = Nil

-- | Apply the substitution to the process.
substituteProcess :: Substitution -> Process -> Process
substituteProcess sigma (Pl pl) = Pl $ substituteLeftProcess sigma pl
substituteProcess sigma (Pc pc) = Pc $ substituteCenterProcess sigma pc
substituteProcess sigma (Pr pr) = Pr $ substituteRightProcess sigma pr

{- | Apply the substitution to the disequality. The bound variables are not
affected.
-}
substituteDisequality :: Substitution -> Disequality -> Disequality
substituteDisequality sigma (xs, eqs) =
  (xs, map (\(s, t) -> (substitute sigma s, substitute sigma t)) eqs)

-- | Apply the substitution to the memory update.
substituteMemoryUpdate :: Substitution -> MemoryUpdate -> MemoryUpdate
substituteMemoryUpdate sigma (MemoryUpdate cell s t) =
  MemoryUpdate cell (substitute sigma s) $ substitute sigma t

-- | Apply the substitution to the list of memory updates.
substituteMemory :: Substitution -> [MemoryUpdate] -> [MemoryUpdate]
substituteMemory sigma = map $ substituteMemoryUpdate sigma

{- | Apply the substitution to the possibility. The substitutions representing
the condition, and the partial payload, are not affected because we will always
apply a substitution of intruder variables.
-}
substitutePossibility :: Substitution -> Possibility -> Possibility
substitutePossibility sigma p =
  p
    { process = substituteProcess sigma $ process p
    , flic = substituteFlic sigma $ flic p
    , diseqs = map (substituteDisequality sigma) $ diseqs p
    , memory = substituteMemory sigma $ memory p
    }
