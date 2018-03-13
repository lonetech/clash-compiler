{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE BinaryLiterals #-}
{-# LANGUAGE QuasiQuotes #-}

module ReprCompact
  ( testBench
  , topEntity
  ) where

import Prelude
import Data.Maybe
import RotateC (Color(..), MaybeColor(..))
import qualified RotateC
import Clash.Annotations.BitRepresentation

{-# ANN module (
  DataReprAnn
    $(reprType [t| Color |])
    2
    [ ConstrRepr
        'Red
        0b11
        0b00
        []
    , ConstrRepr
        'Blue
        0b11
        0b10
        []
    , ConstrRepr
        'Green
        0b11
        0b01
        []
    ]) #-}

{-# ANN module (
  DataReprAnn
    $(reprType [t| MaybeColor |])
    2
    [ ConstrRepr
        'NothingC
        0b11 -- Mask
        0b11 -- Value
        []
    , ConstrRepr
        'JustC
        0b00   -- Mask
        0b00   -- Value
        [0b11] -- Masks
    ]) #-}

topEntity = RotateC.topEntity
testBench = RotateC.testBench