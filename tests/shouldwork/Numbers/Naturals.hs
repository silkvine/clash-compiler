{-# LANGUAGE ViewPatterns #-}
module Naturals where

import Clash.Prelude
import Clash.Explicit.Testbench

import GHC.Natural

-- Mark NOINLINE to prevent GHC constant folding
plusNatural' :: Natural -> Natural -> Natural
plusNatural' = (+)
{-# NOINLINE plusNatural' #-}

timesNatural' :: Natural -> Natural -> Natural
timesNatural' = (*)
{-# NOINLINE timesNatural' #-}

minusNatural' :: Natural -> Natural -> Natural
minusNatural' = (-)
{-# NOINLINE minusNatural' #-}

wordToNatural' :: Word -> Natural
wordToNatural' = wordToNatural
{-# NOINLINE wordToNatural' #-}

naturalFromInteger' :: Integer -> Natural
naturalFromInteger' = naturalFromInteger
{-# NOINLINE naturalFromInteger' #-}

calc :: Integer -> Natural
calc (naturalFromInteger -> n) = c + h
  where
    a = n + n
    b = a * n
    c = b - n

    -- TODO: Should get constant folded. Test using blackbox forcing an
    -- TODO: argument to be a literal. Alternatively, we could ask Clash to
    -- TODO: print its Core after applying all transformations.
    d = naturalFromInteger' 5 -- 5
    e = plusNatural' d d      -- 10
    f = timesNatural' d e     -- 50
    g = minusNatural' f d     -- 45
    h = plusNatural' 1000 g   -- 1045, SHOULD show after transformations

    -- TODO: If intermediate results are less than zero, Clash should
    -- TODO: NOT constant fold. Instead, it should get compiled to undefined.
    -- TODO: Or should it? GHDL currently refused to compile, as it notes that
    -- TODO: the result of the code below is outside the range of an unsigned.
    -- lt_zero_d = minusNatural' 5 7            -- (-2)
    -- lt_zero_e = plusNatural' lt_zero_d 1000  -- 998, should NOT show after transformations
{-# NOINLINE calc #-}

topEntity :: Integer -> Natural
topEntity = calc

testBench :: Signal System Bool
testBench = done
  where
    testInput      = stimuliGenerator clk rst (6 :> 7 :> Nil)
    expectedOutput = outputVerifier clk rst (1111 :> 1136 :> Nil)
    done           = expectedOutput (topEntity <$> testInput)
    clk            = tbSystemClockGen (not <$> done)
    rst            = systemResetGen
