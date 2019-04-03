module Tail where

import Clash.Prelude
import Clash.Explicit.Testbench

tail' :: Vec (n+1) (Signed 16) -> Vec n (Signed 16)
tail' (Cons x xs) = xs
{-# NOINLINE tail' #-}

topEntity :: Vec 3 (Signed 16) -> Vec 2 (Signed 16)
topEntity = tail'
{-# NOINLINE topEntity #-}

testBench :: Signal System Bool
testBench = done
  where
    testInput      = stimuliGenerator clk rst ((1 :> 2 :> 3 :> Nil) :> Nil)
    expectedOutput = outputVerifier clk rst ((2 :> 3 :> Nil) :> Nil)

    done           = expectedOutput (topEntity <$> testInput)
    clk            = tbSystemClockGen (not <$> done)
    rst            = systemResetGen
