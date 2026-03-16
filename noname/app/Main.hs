-- SPDX-FileCopyrightText: 2023 Technical University of Denmark
--
-- SPDX-License-Identifier: BSD-3-Clause

{- |
Module      : Main
Description : Entry point to the noname CLI.
Copyright   : 2023 Technical University of Denmark
License     : BSD-3-Clause
Maintainer  : lpkf@dtu.dk
Stability   : experimental
-}
module Main (main) where
import Control.Monad (when)
import System.IO (hFlush, stdout)
import System.Process (spawnProcess)
-- optparse-applicative
import Options.Applicative

-- text
import qualified Data.Text.IO.Utf8 as Text.IO

-- noname
import Noname (ExplorationMode (..), Options (..), noname)

-- | The parser for the options.
optionsParser :: Parser Options
optionsParser =
  Options
    <$> ( (Just <$> argument str (mconcat [metavar "INPUT", help "Read from INPUT file"]))
            <|> flag' Nothing (mconcat [long "stdin", help "Read from stdin"])
        )
    <*> ( optional . strOption $
            mconcat
              [long "output", short 'o', metavar "OUTPUT", help "Write to OUTPUT file"]
        )
    <*> ( optional . option auto $
            mconcat
              [ long "bound"
              , short 'n'
              , metavar "INT"
              , help "Set bound to INT (override bound specified in the input)"
              ]
        )
    <*> strOption
      ( mconcat
          [ long "solver"
          , short 's'
          , metavar "(cvc5 | z3)"
          , help "The solver to use"
          , value "cvc5"
          ]
      )
    <*> flag
      Automatic
      Interactive
      (mconcat [long "interactive", short 'i', help "Use interactive mode"])
    <*> switch (mconcat [long "quiet", short 'q', help "Whether to be quiet"])

-- | The protocol verifier with options parsed from the CLI.
main :: IO ()
main = do
  opts <- execParser parser
  output <- noname opts
  case optOutput opts of
    Nothing -> Text.IO.putStrLn output
    Just f -> Text.IO.writeFile f output
 where
  parser :: ParserInfo Options
  parser =
    info (optionsParser <**> helper <**> simpleVersioner versionMsg) $
      mconcat
        [ progDesc "Verify an (alpha, beta)-privacy specification"
        , header "noname - formal verification of privacy in security protocols"
        ]
  versionMsg =
    mconcat
      [ "noname 0.3"
      , "\nCopyright 2023 Technical University of Denmark"
      , "\nLicense BSD-3-Clause <https://spdx.org/licenses/BSD-3-Clause.html>"
      , "\nReport bugs to lpkf@dtu.dk"
      ]
