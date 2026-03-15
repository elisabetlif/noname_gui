-- SPDX-FileCopyrightText: 2023 Technical University of Denmark
--
-- SPDX-License-Identifier: BSD-3-Clause
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Noname.LazyIntruder
Description : Constraint-solving in FLICs with the lazy intruder technique.
Copyright   : 2023 Technical University of Denmark
License     : BSD-3-Clause
Maintainer  : lpkf@dtu.dk
Stability   : experimental
-}
module Noname.LazyIntruder where

-- base
import Control.Monad (replicateM, when)
import Data.Foldable (traverse_)
import Data.List (nub, sortBy, (\\))
import Data.Maybe (isJust, isNothing)

-- containers
import Data.Map ((!))
import qualified Data.Map as Map

-- noname
import Noname.NonDetState
import Noname.State
import Noname.Unification

-- | Record the choice of one recipe variable.
chooseRecipe :: Variable -> Recipe -> NonDetState ()
chooseRecipe r r' =
  modify $ \state -> state{recipeChoice = Map.insert r r' $ recipeChoice state}

-- | Compute the message produced by the recipe in the FLIC.
cook :: Flic -> Recipe -> Message
cook = substitute . go
 where
  go :: Flic -> Substitution
  go [] = Map.empty
  go (Rcv l t _ : a) = Map.insert l t $ go a
  go (Snd r t : a) = Map.insert r t $ go a

{- | Split the FLIC into three parts: the longest simple prefix, the first
non-simple constraint and the rest.
-}
splitFirstNonSimple :: State -> Flic -> Maybe (Flic, (Variable, Message), Flic)
splitFirstNonSimple state = go [] []
 where
  go :: [Variable] -> Flic -> Flic -> Maybe (Flic, (Variable, Message), Flic)
  go _ _ [] = Nothing
  go xs a1 (Rcv l t m : a2) = go xs (a1 ++ [Rcv l t m]) a2
  go xs a1 (Snd r t@(Atom x) : a2) =
    if isIvar state x && x `notElem` xs
      then go (x : xs) (a1 ++ [Snd r t]) a2
      else Just (a1, (r, t), a2)
  go _ a1 (Snd r t@(Comp _ _) : a2) = Just (a1, (r, t), a2)

-- | Whether the FLIC is simple.
isSimple :: State -> Flic -> Bool
isSimple state = isNothing . splitFirstNonSimple state

{- | Split the FLIC into three parts: the prefix of the recipe variable, the
message the recipe variable maps to, and the rest.
-}
splitSend :: Flic -> Variable -> (Flic, Message, Flic)
splitSend a r = go [] a
 where
  go :: Flic -> Flic -> (Flic, Message, Flic)
  go _ [] = terror "LazyIntruder.splitSend"
  go a1 (Rcv l t m : a2) = go (a1 ++ [Rcv l t m]) a2
  go a1 (Snd r' t : a2) =
    if r' == r then (a1, t, a2) else go (a1 ++ [Snd r' t]) a2

-- | Find the first recipe variable that sends the given variable.
findFirst :: Flic -> Variable -> Variable
findFirst (Rcv{} : a) x = findFirst a x
findFirst (Snd r (Atom y) : a) x =
  if x == y then r else findFirst a x
findFirst _ _ = terror "LazyIntruder.findFirst"

-- | Whether the message is composed.
isComposed :: Message -> Bool
isComposed (Atom _) = False
isComposed (Comp _ _) = True

{- | Lazy intruder rule for unification: if the constraint is to send a composed
message, the intruder can reuse a label that maps to another composed message
provided they are unifiable.
-}
unification
  :: RecipeChoice
  -> (Flic, (Variable, Message), Flic)
  -> Substitution
  -> NonDetState (RecipeChoice, Flic, Substitution)
unification rho (a1, (r, t), a2) sigma = do
  if isComposed t then fork . map unifyWith $ dom a1 else noway
 where
  unifyWith :: Label -> NonDetState (RecipeChoice, Flic, Substitution)
  unifyWith l = do
    let r' = Atom l
        s = cook a1 r'
    if isComposed s
      then do
        sigma' <- unifyFA (s, t) sigma
        let ras = (Map.insert r r' rho, substituteFlic sigma' $ a1 ++ a2, sigma')
        ras <$ chooseRecipe r r'
      else noway

{- | Lazy intruder rule for composition: if the constraint is to send a composed
message, the intruder can compose it themselves provided the function is public
and they can send the subterms.
-}
composition
  :: RecipeChoice
  -> (Flic, (Variable, Message), Flic)
  -> Substitution
  -> NonDetState (RecipeChoice, Flic, Substitution)
composition rho (a1, (r, t), a2) sigma =
  case t of
    Atom _ -> noway
    Comp f ts -> do
      state <- get
      if isPublic state f
        then do
          rs <- replicateM (length ts) freshRvar
          let r' = Comp f $ map Atom rs
              ras = (Map.insert r r' rho, a1 ++ zipWith Snd rs ts ++ a2, sigma)
          ras <$ chooseRecipe r r'
        else noway

{- | Lazy intruder rule for guessing: if the constraint is to send a privacy
variable, the intruder can guess any constant in the domain of the variable.
-}
guessing
  :: RecipeChoice
  -> (Flic, (Variable, Message), Flic)
  -> Substitution
  -> NonDetState (RecipeChoice, Flic, Substitution)
guessing rho (a1, (r, t), a2) sigma = do
  state <- get
  case t of
    Atom x -> case symbolTab state ! x of
      Pvar d -> fork $ map guess d
      _ -> noway
    Comp _ _ -> noway
 where
  guess :: Function -> NonDetState (RecipeChoice, Flic, Substitution)
  guess c = do
    let r' = Comp c []
    sigma' <- unifyFA (t, r') sigma
    let ras = (Map.insert r r' rho, substituteFlic sigma' $ a1 ++ a2, sigma')
    ras <$ chooseRecipe r r'

{- | Lazy intruder rule for repetition: if the constraint is to send an intruder
variable that has been sent before, the intruder can reuse the first recipe
variable.
-}
repetition
  :: RecipeChoice
  -> (Flic, (Variable, Message), Flic)
  -> Substitution
  -> NonDetState (RecipeChoice, Flic, Substitution)
repetition rho (a1, (r, t), a2) sigma =
  case t of
    Atom x -> do
      state <- get
      if isIvar state x
        then do
          let r' = Atom $ findFirst a1 x
              ras = (Map.insert r r' rho, a1 ++ a2, sigma)
          ras <$ chooseRecipe r r'
        else noway
    Comp _ _ -> noway

{- | Lazy intruder simplification procedure: apply the rules until the FLIC is
simple.
-}
simplify
  :: (RecipeChoice, Flic, Substitution)
  -> NonDetState (RecipeChoice, Flic, Substitution)
simplify ras@(rho, a, sigma) = do
  state <- get
  case splitFirstNonSimple state a of
    Nothing -> pure ras
    Just aSplit ->
      let rules = [unification, composition, guessing, repetition]
      in  simplify =<< fork [rule rho aSplit sigma | rule <- rules]

{- | Lazy intruder results: the choices of recipes that come from the
simplification.
-}
solve :: Flic -> Substitution -> NonDetState RecipeChoice
solve a sigma = do
  (rho, _, _) <- simplify (Map.empty, substituteFlic sigma a, sigma)
  pure rho

-- | The recipe variables in the FLIC.
rvarsFlic :: Flic -> [Variable]
rvarsFlic = nub . go
 where
  go :: Flic -> [Variable]
  go [] = []
  go (Rcv{} : a) = rvarsFlic a
  go (Snd r _ : a) = r : rvarsFlic a

{- | Apply the choice of one recipe variable to the FLIC. This depends on the
association between fresh recipe variables and intruder variables.
-}
applyOneFlic
  :: Variable
  -> Recipe
  -> [(Variable, Variable)]
  -> Flic
  -> (Flic, Substitution)
applyOneFlic r r' rxs a =
  case splitSend a r of
    (a1, Atom x, a2) ->
      let rs = (vars r' \\ rvarsFlic a) \\ dom a
          rxs' = filter ((`elem` rs) . fst) rxs
          a' = a1 ++ map (\(ri, xi) -> Snd ri $ Atom xi) rxs'
          sigma = Map.singleton x $ cook a' r'
      in  (a' ++ substituteFlic sigma a2, sigma)
    _ -> terror "LazyIntruder.applyOneFlic"

{- | Define an ordering between recipe variables w.r.t. the FLIC: the recipe
variable occurring first is lower.
-}
compareRvars :: Flic -> Variable -> Variable -> Ordering
compareRvars [] _ _ = terror "LazyIntruder.compareRvars"
compareRvars (Rcv{} : a) r1 r2 = compareRvars a r1 r2
compareRvars (Snd r _ : a) r1 r2
  | r == r1 = LT
  | r == r2 = GT
  | otherwise = compareRvars a r1 r2

{- | Apply the choice of recipes to the FLIC. This depends on the association
between fresh recipe variables and intruder variables.
-}
applyRecipeChoiceFlic
  :: RecipeChoice -> [(Variable, Variable)] -> Flic -> (Flic, Substitution)
applyRecipeChoiceFlic rho rxs a =
  let rs = sortBy (compareRvars a) . filter (`elem` rvarsFlic a) $ Map.keys rho
  in  go rs (a, Map.empty)
 where
  go :: [Variable] -> (Flic, Substitution) -> (Flic, Substitution)
  go [] (a', sigma) = (a', sigma)
  go (r : rs) (a', sigma) =
    let (a'', sigma') = applyOneFlic r (substitute rho $ Atom r) rxs a'
    in  go rs (a'', Map.union sigma' sigma)

{- | Canonic form of the disequality: the free intruder variables are replaced
with fresh constants. The disequality is satisfiable iff there is no unifier for
the equalities in the canonic form.
-}
canonicDisequality :: Disequality -> NonDetState [(Message, Message)]
canonicDisequality (xs, eqs) = do
  state <- get
  let ys = nub $ concatMap (\(s, t) -> ivars state s ++ ivars state t) eqs
      canonic x = (\n -> (x, Comp n [])) <$> freshConst
  sigma <- Map.fromList <$> traverse canonic (ys \\ xs)
  pure $ map (\(s, t) -> (substitute sigma s, substitute sigma t)) eqs

{- | Check that the disequality is satisfiable and stop the computation with
@'noway'@ if not.
-}
checkDisequality :: Disequality -> NonDetState ()
checkDisequality diseq = do
  unifier <- evalMaybe $ mguEqsFA =<< canonicDisequality diseq
  when (isJust unifier) noway

-- | Check that all the disequalities in the possibility are satisfiable.
checkDisequalities :: Possibility -> NonDetState ()
checkDisequalities p =
  let sigma = conditionEqs p
  in  traverse_ (checkDisequality . substituteDisequality sigma) $ diseqs p

{- | Apply the choice of recipes to the possibility. This depends on the
association between fresh recipe variables and intruder variables.
-}
applyRecipeChoicePossibility
  :: RecipeChoice
  -> [(Variable, Variable)]
  -> Possibility
  -> NonDetState Possibility
applyRecipeChoicePossibility rho rxs p =
  let (a, sigma) = applyRecipeChoiceFlic rho rxs $ flic p
      p' = substitutePossibility sigma p{flic = a}
  in  p' <$ checkDisequalities p'

{- | The recipe variables in the state, i.e., the recipe variables in some FLIC:
all the FLICs in the state have the same recipe variables.
-}
rvarsState :: State -> [Variable]
rvarsState state =
  case possibilities state of
    [] -> []
    p : _ -> rvarsFlic $ flic p

-- | Set the list of possibilities.
setPossibilities :: [Possibility] -> NonDetState ()
setPossibilities [] = noway
setPossibilities ps = modify $ \state -> state{possibilities = ps}

-- | Apply the choice of recipes to every possibility.
applyRecipeChoice :: RecipeChoice -> NonDetState ()
applyRecipeChoice rho = do
  state <- get
  let rs = nub . concatMap (vars . substitute rho . Atom) $ Map.keys rho
      rs' = rs \\ (rvarsState state ++ domState state)
      ps = possibilities state
  xs <- replicateM (length rs') freshIvar
  ps' <- traverse (applyRecipeChoicePossibility rho $ zip rs' xs) ps
  setPossibilities ps'
