-- SPDX-FileCopyrightText: 2023 Technical University of Denmark
--
-- SPDX-License-Identifier: BSD-3-Clause
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Noname.NonDetState
Description : Fundamental definitions for the non-deterministic state monad.
Copyright   : 2023 Technical University of Denmark
License     : BSD-3-Clause
Maintainer  : lpkf@dtu.dk
Stability   : experimental
-}
module Noname.NonDetState where

-- base
import Control.Monad (replicateM)
import Data.Maybe (listToMaybe)

-- containers
import Data.Map ((!))
import qualified Data.Map as Map

-- text
import Data.Text (Text)

-- transformers
import Control.Monad.Trans.State (StateT (..))
import qualified Control.Monad.Trans.State as StateT

-- noname
import Noname.State

{- | The non-deterministic state monad. The state is of type @t'State'@ and the
inner monad is @'List'@.
-}
type NonDetState = StateT State []

-- | Specialization of @'StateT.get'@ to @'NonDetState'@.
get :: NonDetState State
get = StateT.get

-- | Specialization of @'StateT.put'@ to @'NonDetState'@.
put :: State -> NonDetState ()
put = StateT.put

-- | Specialization of @'StateT.modify'@ to @'NonDetState'@.
modify :: (State -> State) -> NonDetState ()
modify = StateT.modify

-- | Specialization of @'StateT.runStateT'@ to @'NonDetState'@.
runNonDetState :: NonDetState a -> State -> [(a, State)]
runNonDetState = StateT.runStateT

-- | Specialization of @'StateT.evalStateT'@ to @'NonDetState'@.
evalNonDetState :: NonDetState a -> State -> [a]
evalNonDetState = StateT.evalStateT

-- | Specialization of @'StateT.execStateT'@ to @'NonDetState'@.
execNonDetState :: NonDetState a -> State -> [State]
execNonDetState = StateT.execStateT

{- | The representation of impossible computations: no matter the state, the
empty list is returned.
-}
noway :: NonDetState a
noway = StateT $ const []

{- | The combination of several non-deterministic states: the lists are
concatenated.
-}
fork :: [NonDetState a] -> NonDetState a
fork l = StateT $ \s -> concatMap (`runNonDetState` s) l

-- | Return the results of the computation without changing the state.
collectOne :: NonDetState a -> NonDetState [a]
collectOne m = StateT $ \s -> [(evalNonDetState m s, s)]

-- | Return the results of several computations without changing the states.
collect :: [NonDetState a] -> NonDetState [a]
collect l = concat <$> traverse collectOne l

{- | Return the result of the computation with @'Maybe'@ instead of @'List'@,
particularly useful when the computation can give either 0 or 1 result.
-}
evalMaybe :: NonDetState a -> NonDetState (Maybe a)
evalMaybe m = listToMaybe <$> collectOne m

-- | Insert a name-symbol association in the symbol table.
register :: Text -> Symbol -> NonDetState ()
register name sym =
  modify $ \state -> state{symbolTab = Map.insert name sym $ symbolTab state}

{- | Like @'register'@ but increments the appropriate counter and returns the
fresh name.
-}
fresh :: Text -> Symbol -> NonDetState Identifier
fresh name sym = do
  let counterName =
        case sym of
          Pvar _ -> "Pvar"
          Ivar -> "Ivar"
          Rvar -> "Rvar"
          Fun 0 -> "Const"
          Lab -> "Label"
          _ -> terror "NonDetState.fresh"
  ct <- counterTab <$> get
  let i = ct ! counterName
  let name' = mconcat [name, tshow i]
  register name' sym
  modify $ \state -> state{counterTab = Map.insert counterName (i + 1) ct}
  pure name'

{- | Fresh privacy variable: by convention, the name starts with a lowercase
x.
-}
freshPvar :: Domain -> NonDetState Variable
freshPvar d = fresh "x" $ Pvar d

{- | Fresh intruder variable: by convention, the name starts with an uppercase
X.
-}
freshIvar :: NonDetState Variable
freshIvar = fresh "X" Ivar

{- | Fresh recipe variable: by convention, the name starts with an uppercase
R.
-}
freshRvar :: NonDetState Variable
freshRvar = fresh "R" Rvar

-- | Fresh constant: by convention, the name starts with a lowercase n.
freshConst :: NonDetState Function
freshConst = fresh "n" $ Fun 0

-- | Fresh label: by convention, the name starts with a lowercase l.
freshLabel :: NonDetState Label
freshLabel = fresh "l" Lab

-- | Fresh left process: all bound variables are replaced by fresh variables.
freshLeftProcess :: LeftProcess -> NonDetState LeftProcess
freshLeftProcess (Choice mode x d pl) = do
  x' <- freshPvar d
  pl' <- freshLeftProcess pl
  pure . Choice mode x' d $ substituteLeftProcess (Map.singleton x $ Atom x') pl'
freshLeftProcess (Receive x pl) = do
  x' <- freshIvar
  pl' <- freshLeftProcess pl
  pure . Receive x' $ substituteLeftProcess (Map.singleton x $ Atom x') pl'
freshLeftProcess (LetLeft x t pl) = do
  x' <- freshIvar
  pl' <- freshLeftProcess pl
  pure . LetLeft x' t $ substituteLeftProcess (Map.singleton x $ Atom x') pl'
freshLeftProcess (Center pc) = Center <$> freshCenterProcess pc

{- | Fresh center process: all bound variables are replaced by fresh variables,
except for the 'New' construct where the variables are replaced by fresh
constants.
-}
freshCenterProcess :: CenterProcess -> NonDetState CenterProcess
freshCenterProcess (Try x d ts pc1 pc2) = do
  x' <- freshIvar
  let pc1' = substituteCenterProcess (Map.singleton x $ Atom x') pc1
  Try x' d ts <$> freshCenterProcess pc1' <*> freshCenterProcess pc2
freshCenterProcess (Read x cell t pc) = do
  x' <- freshIvar
  let pc' = substituteCenterProcess (Map.singleton x $ Atom x') pc
  Read x' cell t <$> freshCenterProcess pc'
freshCenterProcess (If phi pc1 pc2) =
  If phi <$> freshCenterProcess pc1 <*> freshCenterProcess pc2
freshCenterProcess (LetCenter x t pc) = do
  x' <- freshIvar
  pc' <- freshCenterProcess pc
  pure . LetCenter x' t $ substituteCenterProcess (Map.singleton x $ Atom x') pc'
freshCenterProcess (New xs pr) = do
  ns <- replicateM (length xs) freshConst
  let sigma = Map.fromList $ zipWith (\x n -> (x, Comp n [])) xs ns
  New ns . substituteRightProcess sigma <$> freshRightProcess pr

-- | Fresh right process: all bound variables are replaced by fresh variables.
freshRightProcess :: RightProcess -> NonDetState RightProcess
freshRightProcess (Send t pr) = Send t <$> freshRightProcess pr
freshRightProcess (Write cell s t pr) = Write cell s t <$> freshRightProcess pr
freshRightProcess (Release mode phi pr) =
  Release mode phi <$> freshRightProcess pr
freshRightProcess (LetRight x t pr) = do
  x' <- freshIvar
  pr' <- freshRightProcess pr
  pure . LetRight x' t $ substituteRightProcess (Map.singleton x $ Atom x') pr'
freshRightProcess Nil = pure Nil

{- | Fresh process: it suffices to define it for a left process, since it will
only be used for transactions (which are left processes).
-}
freshProcess :: LeftProcess -> NonDetState Process
freshProcess pl = Pl <$> freshLeftProcess pl
