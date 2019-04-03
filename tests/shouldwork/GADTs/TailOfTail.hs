module TailOfTail where

import Clash.Prelude
import Clash.Explicit.Testbench

tailOfTail :: Vec (n+2) (Signed 16) -> Vec n (Signed 16)
tailOfTail (Cons _ (Cons _ xs)) = xs
{-# NOINLINE tailOfTail #-}

topEntity :: Vec 4 (Signed 16) -> Vec 2 (Signed 16)
topEntity = tailOfTail
{-# NOINLINE topEntity #-}

testBench :: Signal System Bool
testBench = done
  where
    testInput      = stimuliGenerator clk rst ((1 :> 2 :> 3 :> 4 :> Nil) :> Nil)
    expectedOutput = outputVerifier clk rst ((3 :> 4 :> Nil) :> Nil)

    done           = expectedOutput (topEntity <$> testInput)
    clk            = tbSystemClockGen (not <$> done)
    rst            = systemResetGen
