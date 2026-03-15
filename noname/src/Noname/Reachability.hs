-- SPDX-FileCopyrightText: 2023 Technical University of Denmark
--
-- SPDX-License-Identifier: BSD-3-Clause
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Noname.Reachability
Description : Exploration of reachable states.
Copyright   : 2023 Technical University of Denmark
License     : BSD-3-Clause
Maintainer  : lpkf@dtu.dk
Stability   : experimental
-}
module Noname.Reachability where

-- base
import Data.Functor.Identity (Identity)

-- containers
import Data.Map ((!))
import qualified Data.Map as Map

-- text
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO.Utf8 as Text.IO

-- noname
import Noname.Analysis
import Noname.ComposeChecks
import Noname.Evaluation
import Noname.LazyIntruder
import Noname.NonDetState
import Noname.Pretty
import Noname.State

-- | The class for abstracting the selection function.
class Monad m => HasSelect m where
  select :: State -> [(Text, a)] -> m [a]

{- | For Identity, select all the options in the list (used in
@'Noname.Automatic'@ mode).
-}
instance HasSelect Identity where
  select _ = pure . map snd

{- | For IO, ask the user to select one option among the list (used in
@'Noname.Interactive'@ mode).
-}
instance HasSelect IO where
  select = userSelect

-- | Ask the user to select one option among the list.
userSelect :: State -> [(Text, a)] -> IO [a]
userSelect _ [] = pure []
userSelect state [(t, x)] =
  let msg = mconcat ["Current state:\n", prettyState state, "\n", t]
  in  [x] <$ Text.IO.putStrLn msg
userSelect state txs = do
  Text.IO.putStrLn $
    mconcat ["Current state:\n", prettyState state, "\nSelect an option:"]
  let itxs = zipWith (\i tx -> (tshow (i :: Int), tx)) [1 ..] txs
  Text.IO.putStrLn . Text.unlines $
    map (\(i, (t, _)) -> mconcat [i, ". ", t]) itxs
  i <- Text.IO.getLine
  case lookup i itxs of
    Nothing -> Text.IO.putStrLn "Invalid choice." *> userSelect state txs
    Just (_, x) -> pure [x]

-- | Apply one evaluation rule.
evaluateOne :: HasSelect m => State -> m [State]
evaluateOne state =
  if isFinished state
    then pure [state]
    else select state $ runNonDetState (go $ possibilities state) state
 where
  go :: [Possibility] -> NonDetState Text
  go [] = sendOrTerminate
  go (p : ps) = case process p of
    Pl (Choice mode x _ _) -> choice mode x
    Pl (Receive x _) -> receive x
    Pl (LetLeft{}) -> letLeft p
    Pl (Center{}) -> center p
    Pc (Try{}) -> try p
    Pc (Read{}) -> cellRead p
    Pc (If{}) -> conditional p
    Pc (LetCenter{}) -> letCenter p
    Pc (New{}) -> new p
    Pr (Write{}) -> cellWrite p
    Pr (Release{}) -> release p
    Pr (LetRight{}) -> letRight p
    _ -> go ps

-- | Apply all evaluation rules until the states are finished.
evaluate :: HasSelect m => [State] -> m [State]
evaluate states =
  if all isFinished states
    then pure states
    else evaluate . concat =<< traverse evaluateOne states

-- | Perform one intruder experiment.
composeCheckOne :: HasSelect m => State -> m [State]
composeCheckOne state =
  case evalNonDetState pairs state of
    [[]] -> pure [state]
    [(l, r) : _] -> select state $ runNonDetState (experiment (l, r)) state
    _ -> terror "Reachability.composeCheckOne"
 where
  experiment :: (Label, Recipe) -> NonDetState Text
  experiment (l, r) = do
    psigmas <- collect . map (checkLI (l, r)) . possibilities =<< get
    case psigmas of
      [] -> privacySplit (l, r)
      (p, sigma) : _ -> recipeSplit p sigma

-- | Perform all intruder experiments until the states are normal.
composeCheck :: HasSelect m => [State] -> m [State]
composeCheck states =
  if all isNormal states
    then pure states
    else composeCheck . concat =<< traverse composeCheckOne states

{- | Set the process in every possibility to a fresh instance of the
transaction.
-}
setProcess :: LeftProcess -> NonDetState ()
setProcess pl = do
  state <- get
  if isFinished state
    then do
      pl' <- freshProcess pl
      updatePossibilities $ \p -> p{process = pl'}
    else terror "Evaluation.setProcess"

-- | Execute the destructor oracle with the message produced by the label.
executeWithLabel :: HasSelect m => State -> LeftProcess -> Label -> m [State]
executeWithLabel state pl l = do
  composeCheck =<< evaluate (execNonDetState instantiateOracle state)
 where
  instantiateOracle :: NonDetState ()
  instantiateOracle = do
    setProcess pl
    procs <- map process . possibilities <$> get
    case procs of
      Pl (Receive x _) : _ -> do
        _ <- receive x
        mappings <- map (last . flic) . possibilities <$> get
        case mappings of
          Snd r _ : _ -> do
            let r' = Atom l
            chooseRecipe r r'
            applyRecipeChoice $ Map.singleton r r'
          _ -> terror "Reachability.executeWithLabel"
      _ -> terror "Reachability.executeWithLabel"

{- | Apply the destructor oracle with the message produced by the label, i.e.,
execute the transaction and update the markings.
-}
applyOracle :: HasSelect m => State -> Label -> Possibility -> m [State]
applyOracle state l p = do
  let a = flic p
      ls = dom a
  case cook a $ Atom l of
    Atom _ -> terror "Reachability.applyOracle"
    Comp f _ ->
      if isTransparent state f
        then do
          states <- executeWithLabel state (projectionOracle state f) l
          let updateMarkings = updateMarkingsProjection f l ls
          pure $ concatMap (execNonDetState updateMarkings) states
        else case filter (isPublic state) $ destructorTab state ! f of
          [d] -> do
            states <- executeWithLabel state (decryptionOracle d) l
            let updateMarkings = updateMarkingsDecryption f l ls
            pure $ concatMap (execNonDetState updateMarkings) states
          _ -> terror "Reachability.applyOracle"

-- | Perform one analysis step.
analyzeOne :: HasSelect m => State -> m [State]
analyzeOne state =
  if isAnalyzed state
    then pure [state]
    else case findTodo (domState state) $ possibilities state of
      Nothing -> terror "Reachability.analyzeOne"
      Just (l, p) -> applyOracle state l p

-- | Perform all analysis steps until the states are analyzed.
analyze :: HasSelect m => [State] -> m [State]
analyze states =
  if all isAnalyzed states
    then pure states
    else analyze . concat =<< traverse analyzeOne states

{- | Execute the transaction and add the name of the transaction to the list of
executed transactions.
-}
executeTransaction :: HasSelect m => State -> (Text, LeftProcess) -> m [State]
executeTransaction state (t, pl) =
  analyze =<< composeCheck =<< evaluate (execNonDetState setTransaction state)
 where
  setTransaction :: NonDetState ()
  setTransaction = do
    modify $ \state' -> state'{executed = executed state' ++ [t]}
    setProcess pl

-- | Execute one transaction.
executeOne :: HasSelect m => State -> m [State]
executeOne state = do
  tpls <- select state . map addMsg . Map.assocs $ transactionTab state
  concat <$> traverse (executeTransaction state) tpls
 where
  addMsg :: (Text, LeftProcess) -> (Text, (Text, LeftProcess))
  addMsg (t, pl) = (mconcat ["Execute the transaction ", t, "."], (t, pl))
