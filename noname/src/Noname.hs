-- SPDX-FileCopyrightText: 2023 Technical University of Denmark
--
-- SPDX-License-Identifier: BSD-3-Clause
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

{- |
Module      : Noname
Description : The protocol verifier.
Copyright   : 2023 Technical University of Denmark
License     : BSD-3-Clause
Maintainer  : lpkf@dtu.dk
Stability   : experimental
-}
module Noname (Options (..), ExplorationMode (..), defaultOptions, noname) where

-- base
import Control.Monad (when)
import Data.Foldable (asum)
import Data.Functor.Identity (runIdentity)
import Data.Maybe (fromMaybe)
import System.Exit (exitFailure)
import System.IO (stderr)

-- text
import Data.Text (Text)
import qualified Data.Text.IO.Utf8 as Text.IO

-- unliftio
import UnliftIO (pooledMapConcurrently)

-- noname
import Noname.Parser
import Noname.Reachability
import Noname.State
import Noname.Verification

-- | The running mode for the exploration of reachable states.
data ExplorationMode
  = -- | Automatic exploration of all reachable states, without any user input.
    Automatic
  | -- | Interactive exploration of one particular trace, with user input.
    Interactive
  deriving (Eq)

-- | The options for the protocol verifier.
data Options = Options
  { optInput :: Maybe FilePath
  -- ^ Location of the input for the specification to verify.
  , optOutput :: Maybe FilePath
  -- ^ Location of the output for the verification result.
  , optBound :: Maybe Int
  -- ^ Upper bound on the number of transactions.
  , optSolver :: String
  -- ^ The solver to use.
  , optMode :: ExplorationMode
  -- ^ Mode for the exploration of states.
  , optQuiet :: Bool
  -- ^ Whether to be quiet.
  }

-- | The default options.
defaultOptions :: Options
defaultOptions =
  Options
    { optInput = Nothing
    , optOutput = Nothing
    , optBound = Nothing
    , optSolver = "cvc5"
    , optMode = Automatic
    , optQuiet = False
    }

{- | The protocol verifier with options given as arguments, returning the output
as 'Text'.
-}
noname :: Options -> IO Text
noname opts = do
  (fp, input) <- case optInput opts of
    Nothing -> ("stdin",) <$> Text.IO.getContents
    Just fp -> (fp,) <$> Text.IO.readFile fp
  case parseSpecification fp input of
    Left e -> Text.IO.putStrLn e *> exitFailure
    Right (n, state) ->
      let bound = fromMaybe n $ optBound opts
      in  explore opts bound 0 [state{solver = optSolver opts}]

{- | Explore the reachable states by executing transactions until the bound is
reached.
-}
explore :: Options -> Int -> Int -> [State] -> IO Text
explore _ _ _ [] = pure "There are no more reachable states."
explore opts bound n states = do
  let ntr = mconcat [" after ", tshow n, " transaction", if n > 1 then "s" else ""]
  when (not $ optQuiet opts) . Text.IO.hPutStrLn stderr $
    mconcat ["Number of states", ntr, ": ", tshow $ length states]
  result <- asum <$> pooledMapConcurrently checkConsistency states
  case result of
    Nothing ->
      if n < bound
        then case optMode opts of
          Automatic ->
            let states' = concat . runIdentity $ traverse executeOne states
            in  explore opts bound (n + 1) states'
          Interactive ->
            explore opts bound (n + 1) . concat =<< traverse executeOne states
        else pure $ mconcat ["Bound reached, no privacy violation found", ntr, "."]
    Just v -> pure $ mconcat ["Privacy violation found", ntr, ".\n", v]
