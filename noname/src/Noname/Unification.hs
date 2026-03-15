-- SPDX-FileCopyrightText: 2023 Technical University of Denmark
--
-- SPDX-License-Identifier: BSD-3-Clause

{- |
Module      : Noname.Unification
Description : Unification of terms in the free algebra.
Copyright   : 2023 Technical University of Denmark
License     : BSD-3-Clause
Maintainer  : lpkf@dtu.dk
Stability   : experimental
-}
module Noname.Unification where

-- base
import Data.List (intersect)

-- containers
import Data.Map ((!))
import qualified Data.Map as Map

-- noname
import Noname.NonDetState
import Noname.State

-- | Like @'substitute'@ but stops as soon as we reach a composed message.
expand :: Substitution -> Message -> Message
expand sigma t@(Atom x) =
  case Map.lookup x sigma of
    Nothing -> t
    Just s -> expand sigma s
expand _ t@(Comp _ _) = t

-- | Whether the variable occurs in the message.
occursIn :: Variable -> Message -> Bool
occursIn x (Atom y) = x == y
occursIn x (Comp _ ts) = any (x `occursIn`) ts

{- | Check that privacy variables are substituted with either other privacy
variables where the domains overlap or with constants in their domains.
-}
checkDomains :: Substitution -> NonDetState Substitution
checkDomains sigma = go $ Map.assocs sigma
 where
  go :: [(Variable, Message)] -> NonDetState Substitution
  go [] = pure sigma
  go ((x, t) : xts) = do
    st <- symbolTab <$> get
    case expand sigma t of
      Atom y -> case (st ! x, st ! y) of
        (Pvar dx, Pvar dy) -> if null $ dx `intersect` dy then noway else go xts
        (_, _) -> go xts
      Comp f ts -> case st ! x of
        Pvar d -> if null ts && f `elem` d then go xts else noway
        _ -> go xts

-- | Unify two messages, in the free algebra.
unifyFA :: (Message, Message) -> Substitution -> NonDetState Substitution
unifyFA (s, t) sigma = do
  st <- symbolTab <$> get
  let s' = expand sigma s
      t' = expand sigma t
  if s' == t'
    then checkDomains sigma
    else case (s', t') of
      (Atom x, Atom y) -> case (st ! x, st ! y) of
        (Pvar _, Ivar) -> unifyFA (t', s') sigma
        (_, _) -> checkDomains $ Map.insert x t' sigma
      (Atom x, Comp _ _) ->
        if x `occursIn` t' then noway else checkDomains $ Map.insert x t' sigma
      (Comp _ _, Atom _) -> unifyFA (t', s') sigma
      (Comp f ss, Comp g ts) ->
        if f == g then unifyEqsFA (zip ss ts) sigma else noway

-- | Unify the list of equalities between messages, in the free algebra.
unifyEqsFA :: [(Message, Message)] -> Substitution -> NonDetState Substitution
unifyEqsFA [] sigma = checkDomains sigma
unifyEqsFA ((s, t) : eqs) sigma = unifyEqsFA eqs =<< unifyFA (s, t) sigma

{- | Compute the most general unifier for two messages. Like @'unifyFA'@ but
starts with the identity substitution.
-}
mguFA :: (Message, Message) -> NonDetState Substitution
mguFA (s, t) = unifyFA (s, t) Map.empty

{- | Compute the most general unifier for the list of equalities between
messages. Like @'unifyEqsFA'@ but starts with the identity substitution.
-}
mguEqsFA :: [(Message, Message)] -> NonDetState Substitution
mguEqsFA eqs = unifyEqsFA eqs Map.empty
