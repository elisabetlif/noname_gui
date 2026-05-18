-- SPDX-FileCopyrightText: 2023 Technical University of Denmark
--
-- SPDX-License-Identifier: BSD-3-Clause
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Noname.Verification
Description : Verification of privacy in symbolic states using SBV and cvc5.
Copyright   : 2023 Technical University of Denmark
License     : BSD-3-Clause
Maintainer  : lpkf@dtu.dk
Stability   : experimental
-}
module Noname.Verification where

-- base
import Data.Foldable (asum)
import Data.List (nub, partition)

-- containers
import Data.Map (Map, (!))
import qualified Data.Map as Map

-- sbv
import Data.SBV
  ( ConstraintSet
  , Forall (..)
  , SBool
  , SInteger
  , SatResult
  , constrain
  , cvc5
  , distinct
  , free
  , getModelDictionary
  , modelExists
  , quantifiedBool
  , sAnd
  , sElem
  , sInteger
  , sNot
  , sTrue
  , satWith
  , uninterpret
  , z3
  , (.==)
  )

-- text
import Data.Text (Text)
import qualified Data.Text as Text

-- unliftio
import UnliftIO (pooledMapConcurrently)

-- noname
import Noname.Pretty
import Noname.State

-- | The list of all constants occurring in the message.
constants :: Message -> [Function]
constants = nub . go
 where
  go :: Message -> [Function]
  go (Atom _) = []
  go (Comp c []) = [c]
  go (Comp _ ts) = concatMap go ts

-- | The list of all constants occurring in the formula.
constantsFormula :: Formula -> [Function]
constantsFormula Top = []
constantsFormula (Equality s t) = nub $ concatMap constants [s, t]
constantsFormula (Relational _ ts) = nub $ concatMap constants ts
constantsFormula (Neg phi) = constantsFormula phi
constantsFormula (And phi psi) = nub $ concatMap constantsFormula [phi, psi]

-- | Whether the message contains the meta-notation.
containsMeta :: Message -> Bool
containsMeta (Atom _) = False
containsMeta (Comp f ts) = f == meta || any containsMeta ts

-- | Whether the formula contains the meta-notation.
containsMetaFormula :: Formula -> Bool
containsMetaFormula Top = False
containsMetaFormula (Equality s t) = any containsMeta [s, t]
containsMetaFormula (Relational _ ts) = any containsMeta ts
containsMetaFormula (Neg phi) = containsMetaFormula phi
containsMetaFormula (And phi psi) = any containsMetaFormula [phi, psi]

-- | The list of all variables occurring in the formula.
varsFormula :: Formula -> [Variable]
varsFormula Top = []
varsFormula (Equality s t) = nub $ concatMap vars [s, t]
varsFormula (Relational _ ts) = nub $ concatMap vars ts
varsFormula (Neg phi) = varsFormula phi
varsFormula (And phi psi) = nub $ concatMap varsFormula [phi, psi]

-- FIXME extend definition for more than 7 arguments, recent versions of sbv
-- contain more instances of SMTDefinable

{- | Apply the (uninterpreted) relation to symbolic integers. The library sbv
allows for up to 7 arguments, but it could be extended if needed by defining
instances of SMTDefinable for more arguments.
-}
applyRelation :: Text -> [SInteger] -> SBool
applyRelation rel ts =
  let r = Text.unpack rel
  in  case ts of
        [] -> uninterpret r
        [t1] -> uninterpret r t1
        [t1, t2] -> uninterpret r t1 t2
        [t1, t2, t3] -> uninterpret r t1 t2 t3
        [t1, t2, t3, t4] -> uninterpret r t1 t2 t3 t4
        [t1, t2, t3, t4, t5] -> uninterpret r t1 t2 t3 t4 t5
        [t1, t2, t3, t4, t5, t6] -> uninterpret r t1 t2 t3 t4 t5 t6
        [t1, t2, t3, t4, t5, t6, t7] -> uninterpret r t1 t2 t3 t4 t5 t6 t7
        _ -> terror "Verification.applyRelation"

{- | The association of relations to their fixed interpretation (over symbolic
integers).
-}
type RelationTable = Map Relation ([SInteger] -> SBool)

-- | The association of messages to symbolic integers.
type SIntegerTable = Map Message SInteger

-- | The relation table for the state given the symbolic integers table.
relationTab :: State -> SIntegerTable -> RelationTable
relationTab state sIntegerTab =
  let g0 = interpretation state
  in  Map.map (\tss ts -> ts `sElem` map (map (sIntegerTab !)) tss) g0

qb :: [Variable] -> SIntegerTable -> Formula -> SBool
qb [] sIntegerTab phi = formulaSBool sIntegerTab Nothing phi
qb (y : ys) sIntegerTab phi =
  quantifiedBool $ \(Forall y') -> qb ys (Map.insert (Atom y) y' sIntegerTab) phi

{- | Transform the formula into a symbolic boolean, using the symbolic integers
and relation tables. If no relation table is given, the relations are
uninterpreted. If a relation table is given, the relations are looked up in the
table.
-}
formulaSBool :: SIntegerTable -> Maybe RelationTable -> Formula -> SBool
formulaSBool _ _ Top = sTrue
formulaSBool sIntegerTab _ (Equality s t) =
  sIntegerTab ! s .== sIntegerTab ! t
formulaSBool sIntegerTab Nothing (Relational r ts) =
  applyRelation r $ map (sIntegerTab !) ts
formulaSBool sIntegerTab (Just relTab) (Relational r ts) =
  case Map.lookup r relTab of
    Nothing -> terror "Verification.formulaSBool"
    Just r' -> r' $ map (sIntegerTab !) ts
formulaSBool sIntegerTab relTab (Neg phi) =
  sNot $ formulaSBool sIntegerTab relTab phi
formulaSBool sIntegerTab relTab (And phi psi) =
  sAnd $ map (formulaSBool sIntegerTab relTab) [phi, psi]

inconsistency :: State -> Formula -> Formula -> ConstraintSet
inconsistency state alpha_i phi_i = do
  let xs = alphaVars state
      xsInDomains = alpha0 state
      ys = betaVars state
      (ysInDomains, phi) = beta0 state
      alpha = conjunction [xsInDomains, alpha_i]
      alphaNotBeta0 = ysInDomains `implies` conjunction [alpha, Neg phi]
      cs = nub $ concatMap constantsFormula [alphaNotBeta0, gamma0 state]
  cs' <- traverse (sInteger . Text.unpack) cs
  constrain $ distinct cs'
  let constantTab = Map.fromList $ zip (map (\c -> Comp c []) cs) cs'
  xs' <- traverse (free . Text.unpack) xs
  if containsMetaFormula alpha_i
    then do
      let zs = xs ++ ys
      zsMeta <-
        traverse (sInteger . (\z -> Text.unpack $ mconcat [meta, "(", z, ")"])) zs
      let sIntegerTab =
            Map.union constantTab . Map.fromList $
              zip (map Atom xs) xs'
                ++ zip (map (\c -> Comp meta [Comp c []]) cs) cs'
                ++ zip (map (\z -> Comp meta [Atom z]) zs) zsMeta
          sIntegerTabMeta = Map.union constantTab . Map.fromList $ zip (map Atom zs) zsMeta
          relTab = relationTab state sIntegerTab
          metaFormula = conjunction [xsInDomains, ysInDomains, phi_i]
      constrain $ formulaSBool sIntegerTabMeta (Just relTab) metaFormula
      constrain $ qb ys sIntegerTab alphaNotBeta0
    else
      let sIntegerTab = Map.union constantTab . Map.fromList $ zip (map Atom xs) xs'
      in  constrain $ qb ys sIntegerTab alphaNotBeta0

-- | Text to display the SAT result.
prettySatResult :: State -> Formula -> SatResult -> Text
prettySatResult state alpha_i res =
  let xs = alphaVars state
      cs =
        nub $
          concatMap
            constantsFormula
            [alpha0 state, alpha_i, snd $ beta0 state, gamma0 state]
      model = Map.mapKeys Text.pack $ getModelDictionary res
      (csIntegers, zsIntegers) = partition ((`elem` cs) . fst) $ Map.assocs model
      nameTab = Map.fromList $ map (\(i, c) -> (c, i)) csIntegers
      zsCs = map (\(z, i) -> (z, nameTab ! i)) zsIntegers
      (xsCs, zsMetaCs) = partition ((`elem` xs) . fst) zsCs
      prettyPayload =
        if alpha_i == Top
          then prettyAlpha0 state
          else mconcat [prettyAlpha0 state, "∧(", prettyFormula alpha_i, ")"]
      concrete =
        if containsMetaFormula alpha_i
          then
            mconcat
              [ " for the concrete execution where: "
              , Text.intercalate "∧" $ map (\(z, c) -> mconcat [z, "=", c]) zsMetaCs
              ]
          else "."
  in  mconcat
        [ "alpha = "
        , prettyPayload
        , "\nbeta_0 = "
        , prettyBeta0 state
        , "\n(alpha, beta_0)-privacy does not hold"
        , concrete
        , "\nModel found: "
        , Text.intercalate "∧" $ map (\(x, c) -> mconcat [x, "=", c]) xsCs
        , "\nState: "
        , prettyState state
        , "\nSatResult: "
        , tshow res
        ]

{- | Return either Nothing if the possibility in the state is consistent or Just
the privacy violation found.
-}
checkConsistencyPossibility :: State -> Possibility -> IO (Maybe Text)
checkConsistencyPossibility state p = do
  let alpha_i = partialPayload p
      solverConfig =
        case solver state of
          "cvc5" -> cvc5
          "z3" -> z3
          s ->
            terror $
              mconcat
                [ "'"
                , Text.pack s
                , "' is not a supported solver, use either 'cvc5' or 'z3'."
                ]
  res <- satWith solverConfig . inconsistency state alpha_i $ condition p
  if modelExists res
    then pure . Just $ prettySatResult state alpha_i res
    else pure Nothing

{- | Return either Nothing if the state is consistent or Just the privacy
violation found.
-}
checkConsistency :: State -> IO (Maybe Text)
checkConsistency state =
  asum
    <$> pooledMapConcurrently (checkConsistencyPossibility state) (possibilities state)
