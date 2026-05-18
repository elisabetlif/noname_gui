-- SPDX-FileCopyrightText: 2023 Technical University of Denmark
--
-- SPDX-License-Identifier: BSD-3-Clause
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Noname.Analysis
Description : Analysis steps to saturate the intruder knowledge.
Copyright   : 2023 Technical University of Denmark
License     : BSD-3-Clause
Maintainer  : lpkf@dtu.dk
Stability   : experimental
-}
module Noname.Analysis where

-- containers
import Data.Map (Map, (!))
import qualified Data.Map as Map

-- noname
import Noname.Evaluation
import Noname.LazyIntruder
import Noname.NonDetState
import Noname.State

-- | The decryption oracle associated to the destructor.
decryptionOracle :: Function -> LeftProcess
decryptionOracle f =
  Receive "X"
    . Receive "Y"
    . Center
    . Try "Z" f [Atom "Y", Atom "X"] (New [] . Send (Atom "Z") $ Send (Atom "Y") Nil)
    $ New [] Nil

-- | The projection oracle associated to the constructor.
projectionOracle :: State -> Function -> LeftProcess
projectionOracle state f =
  let n = arity state f
      zs = map (("Z" <>) . tshow) [1 .. n]
      ds = filter (isPublic state) $ destructorTab state ! f
      pcs = zipWith (\z d -> flip (Try z d [Atom "X"]) (New [] Nil)) zs ds
      pr = foldr (Send . Atom) Nil zs
  in  Receive "X" . Center $ foldr id (New [] pr) pcs

-- | Replace the marking of the subterms on hold so they have to be analyzed.
holdTodo :: Marking -> Marking
holdTodo m@(Atom _) = m
holdTodo (Comp m' ms) =
  let ms' = map holdTodo ms
  in  case m' of
        Hold -> Comp Todo ms'
        _ -> Comp m' ms'

{- | Replace the markingTab of messages on hold in the FLIC so they have to be
analyzed.
-}
holdTodoFlic :: Flic -> Flic
holdTodoFlic [] = []
holdTodoFlic (Rcv l t m : a) = Rcv l t (holdTodo m) : holdTodoFlic a
holdTodoFlic (Snd r t : a) = Snd r t : holdTodoFlic a

-- | The marking of the label in the FLIC.
marking :: Label -> Flic -> Marking
marking _ [] = terror "Analysis.marking"
marking l (Rcv l' _ m : a) = if l == l' then m else marking l a
marking l (Snd _ _ : a) = marking l a

-- | Whether the marking is for a message to be analyzed.
isTodo :: Marking -> Bool
isTodo (Comp Todo _) = True
isTodo _ = False

-- | Find the first label and possibility where the message is to be analyzed.
findTodo :: [Label] -> [Possibility] -> Maybe (Label, Possibility)
findTodo [] _ = Nothing
findTodo (l : ls) ps =
  case filter (isTodo . marking l . flic) ps of
    [] -> findTodo ls ps
    p : _ -> Just (l, p)

{- | Whether the message produced by the label in the possibility is composed
with the function.
-}
isComposedWith :: Function -> Label -> Possibility -> Bool
isComposedWith f l p =
  case cook (flic p) $ Atom l of
    Atom _ -> False
    Comp f' _ -> f == f'

{- | Replace the marking of the message produced by the label in the FLIC so the
message is on hold, if the message was to analyze and is composed with the
function.
-}
todoHoldFlic :: Function -> Label -> Flic -> Flic
todoHoldFlic _ _ [] = terror "Analysis.todoHoldFlic"
todoHoldFlic f l a@(Rcv l' t m : a') =
  if l == l'
    then case t of
      Comp g _ ->
        if f == g
          then case m of
            Comp Todo ms -> Rcv l t (Comp Hold ms) : a'
            _ -> a
          else a
      _ -> a
    else Rcv l' t m : todoHoldFlic f l a'
todoHoldFlic f l (Snd r t : a) = Snd r t : todoHoldFlic f l a

-- | The marking where all marks are replaced with Done.
done :: Marking -> Marking
done (Atom _) = Atom Done
done (Comp _ ms) = Comp Done $ map done ms

{- | Replace the marking of the message produced by the label in the FLIC so the
message is completely analyzed, if the message was to analyze and is composed
with the function.
-}
todoDoneFlic :: Function -> Label -> Flic -> Flic
todoDoneFlic _ _ [] = terror "Analysis.todoDoneFlic"
todoDoneFlic f l a@(Rcv l' t m : a') =
  if l == l'
    then case t of
      Comp g _ -> if f == g then Rcv l t (done m) : a' else a
      _ -> a
    else Rcv l' t m : todoDoneFlic f l a'
todoDoneFlic f l (Snd r t : a) = Snd r t : todoDoneFlic f l a

-- | The last @n@ elements in the list.
lastN :: Int -> [a] -> [a]
lastN n l = go l $ drop n l
 where
  go :: [a] -> [a] -> [a]
  go xs [] = xs
  go (_ : xs) (_ : ys) = go xs ys
  go [] _ = terror "Analysis.lastN"

{- | Set the markings in the FLIC for the given labels using the given marking
table.
-}
setMarkings :: [Label] -> Map Message Marking -> Flic -> Flic
setMarkings _ _ [] = []
setMarkings ls markingTab (Rcv l t m : a) =
  if l `elem` ls
    then Rcv l t (markingTab ! t) : setMarkings ls markingTab a
    else Rcv l t m : setMarkings ls markingTab a
setMarkings ls markingTab (Snd r t : a) = Snd r t : setMarkings ls markingTab a

{- | Set the markings for the last 2 messages received in every possibility and
the message that was decrypted.
-}
updateMarkingsDecrypted :: Label -> Possibility -> Possibility
updateMarkingsDecrypted l p =
  let a = flic p
  in  case (cook a $ Atom l, marking l a, lastN 2 a) of
        (t@(Comp _ ts), m@(Comp _ ms), [Rcv l1 _ _, Rcv l2 t2 m2]) ->
          let markingTab = Map.fromList $ (t, done m) : (t2, done m2) : zip ts ms
          in  p{flic = holdTodoFlic $ setMarkings [l, l1, l2] markingTab a}
        _ -> terror "Analysis.updateMarkingsDecrypted"

-- | Set the markings after decryption.
updateMarkingsDecryption :: Function -> Label -> [Label] -> NonDetState ()
updateMarkingsDecryption f l ls = do
  ls' <- domState <$> get
  if ls == ls'
    then updatePossibilities $ \p -> p{flic = todoHoldFlic f l $ flic p}
    else updatePossibilities $ updateMarkingsDecrypted l

{- | Set the markings for the last \(n\) messages received in every possibility
and the message that was projected, where \(n\) is the arity of the transparent
constructor.
-}
updateMarkingsProjected :: Arity -> Label -> Possibility -> Possibility
updateMarkingsProjected n l p =
  let a = flic p
      ls = [l' | Rcv l' _ _ <- lastN n a]
  in  case (cook a $ Atom l, marking l a) of
        (t@(Comp _ ts), m@(Comp _ ms)) ->
          let markingTab = Map.fromList $ (t, done m) : zip ts ms
          in  p{flic = holdTodoFlic $ setMarkings (l : ls) markingTab a}
        _ -> terror "Analysis.updateMarkingsProjected"

-- | Set the markings after projection.
updateMarkingsProjection :: Function -> Label -> [Label] -> NonDetState ()
updateMarkingsProjection f l ls = do
  state <- get
  let n = arity state f
      ls' = domState state
  if ls == ls'
    then updatePossibilities $ \p -> p{flic = todoHoldFlic f l $ flic p}
    else updatePossibilities $ updateMarkingsProjected n l

-- | Whether the state is analyzed, i.e., no message received is marked 'to do'.
isAnalyzed :: State -> Bool
isAnalyzed state =
  let ps = possibilities state
      isAnalyzedOne p = not $ any isTodo [m | Rcv _ _ m <- flic p]
  in  not (null ps) && all isAnalyzedOne ps
