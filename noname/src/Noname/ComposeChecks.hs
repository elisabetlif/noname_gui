-- SPDX-FileCopyrightText: 2023 Technical University of Denmark
--
-- SPDX-License-Identifier: BSD-3-Clause
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Noname.ComposeChecks
Description : Intruder experiments to try and distinguish the possibilities.
Copyright   : 2023 Technical University of Denmark
License     : BSD-3-Clause
Maintainer  : lpkf@dtu.dk
Stability   : experimental
-}
module Noname.ComposeChecks where

-- containers
import qualified Data.Map as Map

-- text
import Data.Text (Text)

-- noname
import Noname.Evaluation
import Noname.LazyIntruder
import Noname.NonDetState
import Noname.Pretty
import Noname.State
import Noname.Unification

-- | Whether the pair of recipes is already checked.
isChecked :: State -> (Label, Recipe) -> Bool
isChecked state (l, r) =
  let lrs = checked state
  in  case r of
        Atom l' -> (l, r) `elem` lrs || (l', Atom l) `elem` lrs
        Comp _ _ -> (l, r) `elem` lrs

-- | Compute recipes that can produce the same message as the label in the FLIC.
repeatLabel :: Flic -> Label -> NonDetState (Label, Recipe)
repeatLabel a l = do
  r <- freshRvar
  rho <- solve (a ++ [Snd r . cook a $ Atom l]) Map.empty
  let r' = substitute rho $ Atom r
  if r' == Atom l then noway else pure (l, r')

-- | Return the pairs (not already checked) of experiments to perform.
pairs :: NonDetState [(Label, Recipe)]
pairs = do
  state <- get
  let pairsOne a = collect . map (repeatLabel a) $ dom a
      ms = map (pairsOne . flic) $ possibilities state
  concatMap (filter $ not . isChecked state) <$> collect ms

{- | Like @'addConditionEqs'@ but with a Maybe unifier instead of a
substitution. If the unifier contains intruder variables the possibility is
discarded.
-}
addPriv :: Maybe Substitution -> Possibility -> NonDetState Possibility
addPriv unifier p =
  case unifier of
    Nothing -> noway
    Just sigma -> do
      state <- get
      if isPriv state sigma then addConditionEqs sigma p else noway

{- | Like @'addConditionDiseqs'@ but with a Maybe unifier instead of a
substitution. If the unifier contains intruder variables the possibility is not
changed.
-}
addNegPriv :: Maybe Substitution -> Possibility -> NonDetState Possibility
addNegPriv unifier p =
  case unifier of
    Nothing -> pure p
    Just sigma -> do
      state <- get
      if isPriv state sigma then addConditionDiseqs sigma p else pure p

{- | Privacy split: the outcome of the experiment depends only on privacy
variables. The recipes are equivalent or not equivalent, and the pair is
checked.
-}
privacySplit :: (Label, Recipe) -> NonDetState Text
privacySplit (l, r) = do
  state <- get
  let ps = possibilities state
      msg = mconcat ["The recipes ", l, " and ", prettyRecipe r, " are "]
      equiv = mconcat [msg, "equivalent."]
      notEquiv = mconcat [msg, "NOT equivalent."]
      mguPair a = evalMaybe $ mguFA (cook a $ Atom l, cook a r)
  unifiers <- traverse (mguPair . flic) ps
  psPos <- collect $ zipWith addPriv unifiers ps
  psNeg <- collect $ zipWith addNegPriv unifiers ps
  put state{checked = (l, r) : checked state}
  fork [equiv <$ setPossibilities psPos, notEquiv <$ setPossibilities psNeg]

{- | Recipe split: the outcome of the experiment depends on intruder
variables. A choice of recipes is applied to solve the constraints or some
unifier is excluded in one possibility.
-}
recipeSplit :: Possibility -> Substitution -> NonDetState Text
recipeSplit p sigma =
  fork [makeRecipeChoice (flic p) sigma, excludeMgu p sigma]

{- | Check that the unifier of the messages produced by the pair contains
intruder variables and attempt to solve the constraints.
-}
checkLI
  :: (Label, Recipe) -> Possibility -> NonDetState (Possibility, Substitution)
checkLI (l, r) p = do
  let a = flic p
  unifier <- evalMaybe $ mguFA (cook a $ Atom l, cook a r)
  case unifier of
    Nothing -> noway
    Just sigma -> do
      state <- get
      if isPriv state sigma
        then noway
        else (p, sigma) <$ makeRecipeChoice a sigma

-- | Whether the state is normal, i.e., all the relevant experiments are done.
isNormal :: State -> Bool
isNormal state =
  case evalNonDetState pairs state of
    [lrs] -> null lrs
    _ -> terror "ComposeChecks.isNormal"
