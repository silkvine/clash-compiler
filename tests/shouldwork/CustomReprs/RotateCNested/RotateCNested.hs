module RotateCNested where

import Clash.Prelude.Testbench
import Clash.Prelude
import GHC.Generics
import Clash.Annotations.BitRepresentation
import Data.Maybe

-- Test data structures:
data Color
  = Red
  | Green
  | Blue
    deriving (Eq, Show, Generic, ShowX)

data MaybeColor
  = NothingC
  | JustC Color
    deriving (Eq, Show, Generic, ShowX)

{-# ANN module (
  DataReprAnn
    $(liftQ [t| Color |])
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
    $(liftQ [t| MaybeColor |])
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

-- Test functions:
rotateColor
  :: Color
  -> Color
rotateColor c =
  case c of
    Red   -> Green
    Green -> Blue
    Blue  -> Red

topEntity
  :: SystemClockReset
  => Signal System (Maybe MaybeColor)
  -> Signal System Color
topEntity = fmap f
  where
    f cM =
      case cM of
        Just (JustC c) -> rotateColor c
        Just NothingC  -> Blue
        Nothing        -> Red
{-# NOINLINE topEntity #-}

-- Testbench:
testBench :: Signal System Bool
testBench = done'
  where
    testInput = stimuliGenerator $ Nothing
                               :> Just (NothingC)
                               :> Just (JustC Red)
                               :> Just (JustC Green)
                               :> Just (JustC Blue)
                               :> Nil

    expectedOutput = outputVerifier $ Red
                                   :> Blue
                                   :> Green
                                   :> Blue
                                   :> Red
                                   :> Nil

    done  = expectedOutput (topEntity testInput)
    done' = withClockReset (tbSystemClockGen (not <$> done')) systemResetGen done
