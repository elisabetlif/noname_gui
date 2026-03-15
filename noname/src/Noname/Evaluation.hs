-- SPDX-FileCopyrightText: 2023 Technical University of Denmark
--
-- SPDX-License-Identifier: BSD-3-Clause
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Noname.Evaluation
Description : Symbolic execution of the different steps in the processes.
Copyright   : 2023 Technical University of Denmark
License     : BSD-3-Clause
Maintainer  : lpkf@dtu.dk
Stability   : experimental
-}
module Noname.Evaluation where

-- base
import Control.Monad (replicateM)
import Data.Foldable (traverse_)
import Data.List (delete, intersect, nub, partition, (\\))
import Data.Maybe (catMaybes)

-- containers
import Data.Map ((!))
import qualified Data.Map as Map

-- text
import Data.Text (Text)

-- noname
import Noname.LazyIntruder
import Noname.NonDetState
import Noname.Pretty
import Noname.State
import Noname.Unification

-- | Transform the substitution into equalities between messages.
substitutionEqs :: Substitution -> [(Message, Message)]
substitutionEqs = map (\(x, t) -> (Atom x, t)) . Map.assocs

-- | Add equalities to the condition of the possibility.
addConditionEqs :: Substitution -> Possibility -> NonDetState Possibility
addConditionEqs sigma p = do
  let eqs = concatMap substitutionEqs [sigma, conditionEqs p]
  unifier <- evalMaybe $ mguEqsFA eqs
  case unifier of
    Nothing -> noway
    Just sigma' -> checkConditionDiseqs p{conditionEqs = sigma'}

-- | Add disequalities to the condition of the possibility.
addConditionDiseqs :: Substitution -> Possibility -> NonDetState Possibility
addConditionDiseqs tau p =
  checkConditionDiseqs p{conditionDiseqs = tau : conditionDiseqs p}

{- | Check that the given substitution for disequalities in the condition is
consistent with the equalities already in the condition of the possibility.
-}
checkConditionDiseq
  :: Substitution -> Substitution -> NonDetState (Maybe Substitution)
checkConditionDiseq sigma tau = do
  let tauEqs = substitutionEqs tau
      eqs = map (\(s, t) -> (substitute sigma s, substitute sigma t)) tauEqs
  unifier <- evalMaybe $ mguEqsFA eqs
  if any null unifier then noway else pure unifier

{- | Check that all substitutions for disequalities in the condition are
consistent with the equalities already in the condition of the possibility.
-}
checkConditionDiseqs :: Possibility -> NonDetState Possibility
checkConditionDiseqs p = do
  let sigma = conditionEqs p
      relations' = map (substituteFormula sigma) $ relations p
  taus <- traverse (checkConditionDiseq sigma) $ conditionDiseqs p
  let taus' = nub $ catMaybes taus
  checkDomainDiseqs p{conditionDiseqs = taus', relations = relations'}

{- | Check that all disequalities in the condition of the possibility are
consistent with the domains of privacy variables.
-}
checkDomainDiseqs :: Possibility -> NonDetState Possibility
checkDomainDiseqs p = go . nub . concatMap Map.keys $ conditionDiseqs p
 where
  go :: [Variable] -> NonDetState Possibility
  go [] = pure p
  go (x : xs) = do
    state <- get
    let sigmas = map (\c -> Map.singleton x $ Comp c []) $ domPvar state x
    if all (`elem` conditionDiseqs p) sigmas then noway else go xs

-- | Apply the function to every possibility.
updatePossibilities :: (Possibility -> Possibility) -> NonDetState ()
updatePossibilities f =
  modify $ \state -> state{possibilities = map f $ possibilities state}

-- | Delete the possibility.
deletePossibility :: Possibility -> NonDetState ()
deletePossibility p =
  modify $ \state -> state{possibilities = delete p $ possibilities state}

-- | Add the possibility.
addPossibility :: Possibility -> NonDetState ()
addPossibility p =
  modify $ \state -> state{possibilities = p : possibilities state}

-- | Replace the first possibility by the second.
replacePossibility :: Possibility -> Possibility -> NonDetState ()
replacePossibility p p' = deletePossibility p >> addPossibility p'

-- | Add the variable to the \(\alpha\)-variables.
addAlphaVar :: Variable -> NonDetState ()
addAlphaVar x = modify $ \state -> state{alphaVars = x : alphaVars state}

-- | Add the variable to the \(\beta\)-variables.
addBetaVar :: Variable -> NonDetState ()
addBetaVar x = modify $ \state -> state{betaVars = x : betaVars state}

-- | Evaluation rule for the non-deterministic choice of a variable.
choice :: Mode -> Variable -> NonDetState Text
choice mode x = do
  case mode of
    Star -> addAlphaVar x
    Diamond -> addBetaVar x
  let msg = mconcat ["Variable ", x, " is chosen with mode ", prettyMode mode, "."]
  msg <$ updatePossibilities removeChoice
 where
  removeChoice :: Possibility -> Possibility
  removeChoice p@(Possibility{process = Pl (Choice _ _ _ pl)}) =
    p{process = Pl pl}
  removeChoice _ = terror "Evaluation.removeChoice"

-- | Evaluation rule for receiving a message.
receive :: Variable -> NonDetState Text
receive x = do
  r <- freshRvar
  let msg = mconcat ["Message ", x, " is received."]
  msg <$ updatePossibilities (removeReceive r)
 where
  removeReceive :: Variable -> Possibility -> Possibility
  removeReceive r p@(Possibility{process = Pl (Receive _ pl)}) =
    p{process = Pl pl, flic = flic p ++ [Snd r $ Atom x]}
  removeReceive _ _ = terror "Evaluation.removeReceive"

-- | Evaluation rule for let expression binding in a left process.
letLeft :: Possibility -> NonDetState Text
letLeft p@(Possibility{process = Pl (LetLeft x t pl)}) =
  let msg =
        mconcat
          [ "Variable "
          , x
          , " is bound to message "
          , prettyMessage t
          , " in the possibility with condition "
          , prettyFormula $ condition p
          , "."
          ]
      pl' = substituteLeftProcess (Map.singleton x t) pl
  in  msg <$ replacePossibility p p{process = Pl pl'}
letLeft _ = terror "Evaluation.letLeft"

-- | Trivial evaluation rule just to go into center processes.
center :: Possibility -> NonDetState Text
center p@(Possibility{process = Pl (Center pc)}) =
  let msg =
        mconcat
          [ "The process of the possibility with condition "
          , prettyFormula $ condition p
          , " goes into the center part."
          ]
  in  msg <$ replacePossibility p p{process = Pc pc}
center _ = terror "Evaluation.center"

-- | Unfold the sequence of memory updates by nesting conditional statements.
unfoldMemory
  :: Variable
  -> Message
  -> CenterProcess
  -> [MemoryUpdate]
  -> Message
  -> CenterProcess
unfoldMemory x _ pc [] s0 = substituteCenterProcess (Map.singleton x s0) pc
unfoldMemory x t pc (MemoryUpdate _ t' s : delta) s0 =
  let pc' = substituteCenterProcess (Map.singleton x s) pc
  in  If (Equality t t') pc' $ unfoldMemory x t pc delta s0

-- | Evaluation rule for reading from a memory cell.
cellRead :: Possibility -> NonDetState Text
cellRead p@(Possibility{process = Pc (Read x cell t pc)}) = do
  state <- get
  let s0 = substitute (Map.singleton hole t) $ contextTab state ! cell
      sameCell (MemoryUpdate cell' _ _) = cell == cell'
      delta = filter sameCell $ memory p
      pc' = unfoldMemory x t pc delta s0
      msg =
        mconcat
          [ "In the possibility with condition "
          , prettyFormula $ condition p
          , ", the memory cell "
          , cell
          , " is read into variable "
          , x
          , " using message "
          , prettyMessage t
          , "."
          ]
  msg <$ replacePossibility p p{process = Pc pc'}
cellRead _ = terror "Evaluation.cellRead"

-- | Evaluation rule for writing to a memory cell.
cellWrite :: Possibility -> NonDetState Text
cellWrite p@(Possibility{process = Pr (Write cell s t pr)}) =
  let mu = MemoryUpdate cell s t
      p' = p{process = Pr pr, memory = mu : memory p}
      msg =
        mconcat
          [ "In the possibility with condition "
          , prettyFormula $ condition p
          , ", the memory update "
          , prettyMemoryUpdate mu
          , " is written."
          ]
  in  msg <$ replacePossibility p p'
cellWrite _ = terror "Evaluation.cellWrite"

-- | Return the two branches of the process in the possibility.
branches :: Possibility -> (Process, Process)
branches (Possibility{process = Pc (Try _ _ _ pc1 pc2)}) = (Pc pc1, Pc pc2)
branches (Possibility{process = Pc (If _ pc1 pc2)}) = (Pc pc1, Pc pc2)
branches _ = terror "Evaluation.branches"

-- | Split the possibility into two based on the substitution.
splitPossibility :: Possibility -> Substitution -> NonDetState Text
splitPossibility p sigma = do
  deletePossibility p
  state <- get
  let (proc1, proc2) = branches p
      (sigmaIvar, sigmaPvar) = partitionSubstitution state sigma
      -- FIXME useless renaming for intruder variables
      p' = substitutePossibility sigmaIvar p{process = proc1}
      msg =
        mconcat
          [ "The process of the possibility with condition "
          , prettyFormula $ condition p
          , " is split to go into both branches."
          ]
  p1 <- evalMaybe $ addConditionEqs sigmaPvar p'
  p2 <- evalMaybe $ addConditionDiseqs sigmaPvar p{process = proc2}
  case catMaybes [p1, p2] of
    [] -> terror "Evaluation.splitPossibility"
    ps -> msg <$ traverse_ addPossibility ps

-- | Exclude the unifier in the possibility by adding disequalities.
excludeMgu :: Possibility -> Substitution -> NonDetState Text
excludeMgu p sigma = do
  state <- get
  let xs = [x | Snd _ (Atom x) <- flic p]
      ys = xs `intersect` Map.keys sigma
      eqs = map ((\t -> (t, substitute sigma t)) . Atom) ys
      zs = nub $ concatMap (ivars state . snd) eqs
      diseq = (zs \\ xs, eqs)
      msg =
        mconcat
          [ "The disequalities "
          , prettyDisequality diseq
          , " are added to the possibility with condition "
          , prettyFormula $ condition p
          , "."
          ]
  msg <$ replacePossibility p p{diseqs = diseq : diseqs p}

-- | Apply a choice of recipe that can solve the constraints.
makeRecipeChoice :: Flic -> Substitution -> NonDetState Text
makeRecipeChoice a sigma = do
  state <- get
  rho <- solve a sigma
  let prettyRho = prettyRecipeChoice state rho
      msg = mconcat ["The choice of recipes ", prettyRho, " is made."]
  msg <$ applyRecipeChoice rho

{- | Common part of the evaluation rules for destructor applications and
conditional statements.
-}
tryOrConditional :: Possibility -> Substitution -> NonDetState Text
tryOrConditional p sigma = do
  state <- get
  let a = flic p
      p' = p{process = snd $ branches p}
  if isSimple state $ substituteFlic sigma a
    then splitPossibility p sigma
    else fork [makeRecipeChoice a sigma, replacePossibility p p' >> excludeMgu p' sigma]

{- | Compute the mgu between the given messages and a fresh instance of the
rewrite rule for the destructor.
-}
mguDestructor
  :: Variable -> Function -> [Message] -> NonDetState (Maybe Substitution)
mguDestructor x f ts = do
  state <- get
  (ts', t) <- freshMsgs $ theory state ! f
  evalMaybe . mguEqsFA $ (Atom x, t) : zip ts ts'
 where
  freshMsgs :: ([Message], Message) -> NonDetState ([Message], Message)
  freshMsgs (ts', t) = do
    let xs = nub . concatMap vars $ t : ts'
    sigma <- Map.fromList . zip xs . map Atom <$> replicateM (length xs) freshIvar
    pure (map (substitute sigma) ts', substitute sigma t)

-- | Evaluation rule for destructor application.
try :: Possibility -> NonDetState Text
try p@(Possibility{process = Pc (Try x f ts _ pc2)}) = do
  state <- get
  unifier <- mguDestructor x f ts
  case unifier of
    Nothing -> do
      put state
      let msg =
            mconcat
              [ "The process of the possibility with condition "
              , prettyFormula $ condition p
              , " goes into the 'catch' branch."
              ]
      msg <$ replacePossibility p p{process = Pc pc2}
    Just sigma -> tryOrConditional p sigma
try _ = terror "Evaluation.try"

-- | Evaluation rule for conditional statement.
conditional :: Possibility -> NonDetState Text
conditional p@(Possibility{process = Pc (If psi pc1 pc2)}) = do
  let msg =
        mconcat
          ["The process of the possibility with condition ", prettyFormula $ condition p]
      thenBranch = mconcat [msg, " goes into the 'then' branch."]
      elseBranch = mconcat [msg, " goes into the 'else' branch."]
      bothBranches = mconcat [msg, " is split to go into both branches."]
  case psi of
    Top -> thenBranch <$ replacePossibility p p{process = Pc pc1}
    Equality s t -> do
      unifier <- evalMaybe $ mguFA (s, t)
      case unifier of
        Nothing -> elseBranch <$ replacePossibility p p{process = Pc pc2}
        Just sigma -> tryOrConditional p sigma
    Relational _ _ -> do
      deletePossibility p
      let psi' = substituteFormula (conditionEqs p) psi
          pThen = p{process = Pc pc1, relations = psi' : relations p}
          pElse = p{process = Pc pc2, relations = Neg psi' : relations p}
      if psi' `elem` relations p
        then thenBranch <$ addPossibility p{process = Pc pc1}
        else
          if Neg psi' `elem` relations p
            then elseBranch <$ addPossibility p{process = Pc pc2}
            else bothBranches <$ (addPossibility pThen >> addPossibility pElse)
    And psi1 psi2 ->
      let nesting = mconcat [msg, " is changed by nesting conditional statements."]
          p' = p{process = Pc $ If psi1 (If psi2 pc1 pc2) pc2}
      in  nesting <$ replacePossibility p p'
    Neg psi' ->
      let swapping = mconcat [msg, " is changed by swapping the branches."]
      in  swapping <$ replacePossibility p p{process = Pc $ If psi' pc2 pc1}
conditional _ = terror "Evaluation.conditional"

-- | Evaluation rule for let expression binding in a center process.
letCenter :: Possibility -> NonDetState Text
letCenter p@(Possibility{process = Pc (LetCenter x t pc)}) =
  let msg =
        mconcat
          [ "Variable "
          , x
          , " bound to message "
          , prettyMessage t
          , " in the possibility with condition "
          , prettyFormula $ condition p
          , "."
          ]
      pc' = substituteCenterProcess (Map.singleton x t) pc
  in  msg <$ replacePossibility p p{process = Pc pc'}
letCenter _ = terror "Evaluation.letCenter"

{- | Trivial evaluation rule just to go into right processes. The new variables
have been replaced by fresh constants before evaluating the transaction.
-}
new :: Possibility -> NonDetState Text
new p@(Possibility{process = Pc (New _ pr)}) =
  let msg =
        mconcat
          [ "The process of the possibility with condition "
          , prettyFormula $ condition p
          , " goes into the right part."
          ]
  in  msg <$ replacePossibility p p{process = Pr pr}
new _ = terror "Evaluation.new"

-- | Evaluation rule for releasing a formula.
release :: Possibility -> NonDetState Text
release p@(Possibility{process = Pr (Release Star psi pr)}) =
  let alpha = conjunction [partialPayload p, psi]
      msg =
        mconcat
          [ "In the possibility with condition "
          , prettyFormula $ condition p
          , ", the formula "
          , prettyFormula psi
          , " is released."
          ]
  in  msg <$ replacePossibility p p{process = Pr pr, partialPayload = alpha}
release _ = terror "Evaluation.release"

-- | Evaluation rule for let expression binding in a right process.
letRight :: Possibility -> NonDetState Text
letRight p@(Possibility{process = Pr (LetRight x t pr)}) =
  let msg =
        mconcat
          [ "Variable "
          , x
          , " bound to message "
          , prettyMessage t
          , " in the possibility with condition "
          , prettyFormula $ condition p
          , "."
          ]
      pr' = substituteRightProcess (Map.singleton x t) pr
  in  msg <$ replacePossibility p p{process = Pr pr'}
letRight _ = terror "Evaluation.letRight"

{- | The marking for the message where all subterms are marked as completely
analyzed.
-}
allDone :: Message -> Marking
allDone (Atom _) = Atom Done
allDone (Comp _ ts) = Comp Done $ map allDone ts

-- | The initial marking of the message.
initialMarking :: State -> Message -> Marking
initialMarking _ (Atom _) = Atom Done
initialMarking state (Comp f ts) =
  let m = allDone $ Comp f ts
  in  case Map.lookup f $ destructorTab state of
        Nothing -> m
        Just ds ->
          if any (isPublic state) ds
            then Comp Todo $ map (initialMarking state) ts
            else m

-- | Evaluation rule for sending a message.
send :: [Possibility] -> NonDetState Text
send ps = do
  l <- freshLabel
  state <- get
  let msg = mconcat ["A message is sent, labeled with ", l, "."]
  msg <$ setPossibilities (map (removeSend state l) ps)
 where
  removeSend :: State -> Label -> Possibility -> Possibility
  removeSend state l p@(Possibility{process = Pr (Send t pr)}) =
    let m = initialMarking state t
    in  p{process = Pr pr, flic = flic p ++ [Rcv l t m]}
  removeSend _ _ _ = terror "Evaluation.removeSend"

-- | Evaluation rule for terminating.
terminate :: [Possibility] -> NonDetState Text
terminate ps = "The processes terminate." <$ setPossibilities ps

-- | Evaluation rule for sending or terminating.
sendOrTerminate :: NonDetState Text
sendOrTerminate = do
  (psSend, psTerm) <- partition startsWithSend . possibilities <$> get
  fork [send psSend, terminate psTerm]
 where
  startsWithSend :: Possibility -> Bool
  startsWithSend (Possibility{process = Pr (Send _ _)}) = True
  startsWithSend _ = False

-- | Whether the state is finished, i.e., all the processes are nil.
isFinished :: State -> Bool
isFinished state =
  let ps = possibilities state
  in  not (null ps) && all ((== Pr Nil) . process) ps
