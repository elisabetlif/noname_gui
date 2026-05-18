{-# LANGUAGE NoRebindableSyntax #-}
{-# OPTIONS_GHC -fno-warn-missing-import-lists #-}
{-# OPTIONS_GHC -w #-}
module PackageInfo_noname (
    name,
    version,
    synopsis,
    copyright,
    homepage,
  ) where

import Data.Version (Version(..))
import Prelude

name :: String
name = "noname"
version :: Version
version = Version [0,3] []

synopsis :: String
synopsis = "Formal verification of privacy in security protocols."
copyright :: String
copyright = "2023 Technical University of Denmark"
homepage :: String
homepage = ""
