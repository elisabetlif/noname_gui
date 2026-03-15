-- SPDX-FileCopyrightText: 2023 Technical University of Denmark
--
-- SPDX-License-Identifier: BSD-3-Clause

{- |
Module      : Main
Description : Test suite with golden tests for noname.
Copyright   : 2023 Technical University of Denmark
License     : BSD-3-Clause
Maintainer  : lpkf@dtu.dk
Stability   : experimental
-}
module Main (main) where

-- bytestring
import Data.ByteString.Lazy (ByteString, fromStrict)

-- filepath
import System.FilePath (takeBaseName, (<.>), (</>))

-- tasty
import Test.Tasty (defaultMain, testGroup)

-- tasty-golden
import Test.Tasty.Golden (goldenVsString)

-- text
import Data.Text.Encoding (encodeUtf8)

-- noname
import Noname (Options (..), defaultOptions, noname)

-- | The filepaths to the specifications for the golden tests.
testFiles :: [FilePath]
testFiles =
  map
    ("examples" </>)
    [ "bac" </> "bac.nn"
    , "bac" </> "bac_fixed.nn"
    , "bac" </> "bac_parallel.nn"
    , "bac" </> "bac_sequential.nn"
    , "basic_hash" </> "basic_hash.nn"
    , "basic_hash" </> "basic_hash_compromise.nn"
    , "osk" </> "osk_0_desynchro.nn"
    , "osk" </> "osk_1_desynchro.nn"
    , "runex" </> "runex.nn"
    , "runex" </> "runex_fix_attempt.nn"
    , "runex" </> "runex_fixed.nn"
    ]

-- | Wrapper around the protocol verifier function to be used in the tests.
nonameTest :: FilePath -> IO ByteString
nonameTest fp =
  fromStrict . encodeUtf8
    <$> noname defaultOptions{optInput = Just fp, optQuiet = True}

-- | Run the golden tests.
main :: IO ()
main =
  defaultMain $
    testGroup
      "noname golden tests"
      [ goldenVsString name goldenFile $ nonameTest fp
      | fp <- testFiles
      , let name = takeBaseName fp
      , let goldenFile = "tests" </> "golden" </> name <.> "golden"
      ]
