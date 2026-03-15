-- SPDX-FileCopyrightText: 2023 Technical University of Denmark
--
-- SPDX-License-Identifier: BSD-3-Clause
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Noname.Pretty
Description : Pretty printing of the different datatypes.
Copyright   : 2023 Technical University of Denmark
License     : BSD-3-Clause
Maintainer  : lpkf@dtu.dk
Stability   : experimental
-}
module Noname.Pretty where

-- containers
import qualified Data.Map as Map

-- text
import Data.Text (Text)
import qualified Data.Text as Text

-- noname
import Noname.State

prettyMessage :: Message -> Text
prettyMessage (Atom x) = x
prettyMessage (Comp f ts) =
  if null ts
    then f
    else mconcat [f, "(", Text.intercalate "," $ map prettyMessage ts, ")"]

prettySubstitution :: State -> Substitution -> Text
prettySubstitution state sigma =
  let sigma' = Map.filterWithKey (\x _ -> x `elem` Map.keys (symbolTab state)) sigma
  in  mconcat ["[", Text.intercalate "," . map prettyOne $ Map.assocs sigma', "]"]
 where
  prettyOne :: (Variable, Message) -> Text
  prettyOne (x, t) = mconcat [x, "->", prettyMessage $ substitute sigma t]

prettyRecipe :: Recipe -> Text
prettyRecipe = prettyMessage

prettyRecipeChoice :: State -> RecipeChoice -> Text
prettyRecipeChoice = prettySubstitution

prettyDomain :: Domain -> Text
prettyDomain d = mconcat ["{", Text.intercalate "," d, "}"]

prettyContext :: Context -> Text
prettyContext = prettyMessage

prettySymbol :: Symbol -> Text
prettySymbol (Pvar d) = mconcat ["privacy variable with domain ", prettyDomain d]
prettySymbol Ivar = "intruder variable"
prettySymbol Rvar = "recipe variable"
prettySymbol (Fun n) = mconcat ["function of arity ", tshow n]
prettySymbol (Rel n) = mconcat ["relation of arity ", tshow n]
prettySymbol Cel = "memory cell"
prettySymbol Lab = "label"

prettyTheory :: State -> Text
prettyTheory state =
  mconcat
    ["{", Text.intercalate "," (map prettyOne . Map.assocs $ theory state), "}"]
 where
  prettyOne :: (Function, ([Message], Message)) -> Text
  prettyOne (f, (ts, t)) =
    mconcat [prettyMessage $ Comp f ts, "->", prettyMessage t]

prettyPublic :: State -> Text
prettyPublic state = mconcat ["{", Text.intercalate "," $ public state, "}"]

prettyTransparent :: State -> Text
prettyTransparent state =
  mconcat ["{", Text.intercalate "," $ transparent state, "}"]

prettyExecuted :: State -> Text
prettyExecuted state = Text.intercalate "." $ executed state

prettyMark :: Mark -> Text
prettyMark Done = "✓"
prettyMark Hold = "+"
prettyMark Todo = "★"

prettyMarking :: Marking -> Text
prettyMarking (Atom m) = prettyMark m
prettyMarking (Comp m ms) =
  if null ms
    then prettyMark m
    else
      let args = Text.intercalate "," $ map prettyMarking ms
      in  mconcat [prettyMark m, "(", args, ")"]

prettyMapping :: Mapping -> Text
prettyMapping (Rcv l t m) =
  -- mconcat ["-", l, "->", prettyMessage t]
  mconcat ["-", l, "(", prettyMarking m, ")->", prettyMessage t]
prettyMapping (Snd r t) = mconcat ["+", r, "->", prettyMessage t]

prettyFlic :: Flic -> Text
prettyFlic a = mconcat ["[", Text.intercalate "." $ map prettyMapping a, "]"]

prettyFormula :: Formula -> Text
prettyFormula Top = "⊤"
prettyFormula (Equality s t) = mconcat [prettyMessage s, "=", prettyMessage t]
prettyFormula (Relational r ts) = prettyMessage $ Comp r ts
prettyFormula (Neg Top) = "⊥"
prettyFormula (Neg (Equality s t)) =
  mconcat [prettyMessage s, "≠", prettyMessage t]
prettyFormula (Neg (Neg phi)) = prettyFormula phi
prettyFormula (Neg (And (Neg phi) (Neg psi))) =
  mconcat ["(", prettyFormula phi, ")∨(", prettyFormula psi, ")"]
prettyFormula (Neg phi) = mconcat ["¬(", prettyFormula phi, ")"]
prettyFormula (And phi psi) =
  mconcat ["(", prettyFormula phi, ")∧(", prettyFormula psi, ")"]

prettyInDom :: Variable -> Domain -> Text
prettyInDom x d = mconcat [x, "∈", prettyDomain d]

prettyMode :: Mode -> Text
prettyMode Star = "★"
prettyMode Diamond = "◇"

prettyLeftProcess :: LeftProcess -> Text
prettyLeftProcess (Choice mode x d pl) =
  mconcat [prettyMode mode, prettyInDom x d, ".", prettyLeftProcess pl]
prettyLeftProcess (Receive x pl) =
  mconcat ["receive ", x, ".", prettyLeftProcess pl]
prettyLeftProcess (LetLeft x t pl) =
  mconcat ["let ", x, "=", prettyMessage t, ".", prettyLeftProcess pl]
prettyLeftProcess (Center pc) = prettyCenterProcess pc

prettyCenterProcess :: CenterProcess -> Text
prettyCenterProcess (Read x cell t pc) =
  mconcat [x, ":=", cell, "[", prettyMessage t, "].", prettyCenterProcess pc]
prettyCenterProcess (Try x d ts pc (New [] Nil)) =
  mconcat
    [ "try "
    , x
    , ":="
    , prettyMessage $ Comp d ts
    , " in "
    , prettyCenterProcess pc
    ]
prettyCenterProcess (Try x d ts pc1 pc2) =
  mconcat
    [ "try "
    , x
    , ":="
    , prettyMessage $ Comp d ts
    , " in "
    , prettyCenterProcess pc1
    , " catch "
    , prettyCenterProcess pc2
    ]
prettyCenterProcess (If phi pc (New [] Nil)) =
  mconcat ["if ", prettyFormula phi, " then ", prettyCenterProcess pc]
prettyCenterProcess (If phi pc1 pc2) =
  mconcat
    [ "if "
    , prettyFormula phi
    , " then "
    , prettyCenterProcess pc1
    , " else "
    , prettyCenterProcess pc2
    ]
prettyCenterProcess (LetCenter x t pc) =
  mconcat ["let ", x, "=", prettyMessage t, ".", prettyCenterProcess pc]
prettyCenterProcess (New [] pr) = prettyRightProcess pr
prettyCenterProcess (New xs pr) =
  mconcat ["new ", Text.intercalate "," xs, ".", prettyRightProcess pr]

prettyRightProcess :: RightProcess -> Text
prettyRightProcess (Send t Nil) = mconcat ["send ", prettyMessage t]
prettyRightProcess (Send t pr) =
  mconcat ["send ", prettyMessage t, ".", prettyRightProcess pr]
prettyRightProcess (Write cell s t Nil) =
  mconcat [cell, "[", prettyMessage s, "]:=", prettyMessage t]
prettyRightProcess (Write cell s t pr) =
  mconcat
    [ cell
    , "["
    , prettyMessage s
    , "]:="
    , prettyMessage t
    , "."
    , prettyRightProcess pr
    ]
prettyRightProcess (Release mode phi Nil) =
  mconcat [prettyMode mode, prettyFormula phi]
prettyRightProcess (Release mode phi pr) =
  mconcat [prettyMode mode, prettyFormula phi, ".", prettyRightProcess pr]
prettyRightProcess (LetRight x t pr) =
  mconcat ["let ", x, "=", prettyMessage t, ".", prettyRightProcess pr]
prettyRightProcess Nil = "nil"

prettyProcess :: Process -> Text
prettyProcess (Pl pl) = prettyLeftProcess pl
prettyProcess (Pc pc) = prettyCenterProcess pc
prettyProcess (Pr pr) = prettyRightProcess pr

prettyDisequality :: Disequality -> Text
prettyDisequality (xs, eqs) =
  let phi = Neg . conjunction $ map (uncurry Equality) eqs
      diseq = prettyFormula phi
  in  if null xs
        then diseq
        else mconcat ["∀", Text.intercalate "," xs, ".", diseq]

prettyDisequalities :: [Disequality] -> Text
prettyDisequalities ds =
  mconcat ["{", Text.intercalate "," $ map prettyDisequality ds, "}"]

prettyMemoryUpdate :: MemoryUpdate -> Text
prettyMemoryUpdate (MemoryUpdate cell s t) =
  mconcat [cell, "[", prettyMessage s, "]:=", prettyMessage t]

prettyMemory :: [MemoryUpdate] -> Text
prettyMemory delta =
  mconcat ["[", Text.intercalate "." $ map prettyMemoryUpdate delta, "]"]

prettyPossibility :: Possibility -> Text
prettyPossibility p =
  mconcat
    [ "("
    , prettyProcess $ process p
    , ","
    , prettyFormula $ condition p
    , ","
    , prettyFlic $ flic p
    , ","
    , prettyDisequalities $ diseqs p
    , ","
    , prettyFormula $ partialPayload p
    , ","
    , prettyMemory $ memory p
    , ")"
    ]

prettyPossibilities :: [Possibility] -> Text
prettyPossibilities ps =
  mconcat ["{", Text.intercalate "," $ map prettyPossibility ps, "}"]

prettyAlpha0 :: State -> Text
prettyAlpha0 state =
  let xs = alphaVars state
      ds = map (domPvar state) xs
  in  Text.intercalate "∧" $ zipWith prettyInDom xs ds

prettyBeta0 :: State -> Text
prettyBeta0 state =
  let ys = betaVars state
      ds = map (domPvar state) ys
      yds = Text.intercalate "∧" $ zipWith prettyInDom ys ds
      ps = possibilities state
      phis = Text.intercalate "∨" $ map (prettyFormula . condition) ps
  in  if Text.null yds then phis else mconcat [yds, "∧(", phis, ")"]

prettyChecked :: State -> Text
prettyChecked state =
  mconcat ["{", Text.intercalate "," . map prettyOne $ checked state, "}"]
 where
  prettyOne :: (Label, Recipe) -> Text
  prettyOne (l, r) =
    let r' = substitute (recipeChoice state) r
    in  mconcat ["(", l, ",", prettyRecipe r', ")"]

prettyState :: State -> Text
prettyState state =
  mconcat
    [ "Executed = "
    , prettyExecuted state
    , "\nRecipe choice = "
    , prettyRecipeChoice state $ recipeChoice state
    , "\nalpha_0 = "
    , prettyAlpha0 state
    , "\nbeta_0 = "
    , prettyBeta0 state
    , "\ngamma_0 = "
    , prettyFormula $ gamma0 state
    , "\nPossibilities = "
    , prettyPossibilities $ possibilities state
    , "\nChecked = "
    , prettyChecked state
    ]

prettyStateDebug :: State -> Text
prettyStateDebug state =
  mconcat
    [ "Counter table = "
    , tshow $ counterTab state
    , "\nSymbol table = "
    , tshow $ symbolTab state
    , "\nContext table = "
    , tshow $ contextTab state
    , "\nTheory = "
    , prettyTheory state
    , "\nDestructor table = "
    , tshow $ destructorTab state
    , "\nPublic functions = "
    , prettyPublic state
    , "\nTransparent functions = "
    , prettyTransparent state
    , "\nTransaction table = "
    , tshow $ transactionTab state
    , "\n"
    , prettyState state
    ]
