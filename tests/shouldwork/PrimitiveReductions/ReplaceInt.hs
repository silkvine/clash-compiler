module ReplaceInt where

import Clash.Prelude
import Clash.Sized.Vector (replace)
import Clash.Explicit.Testbench

replace_int
  :: KnownNat n
  => Vec n a
  -> Int
  -> a
  -> Vec n a
replace_int v i a = replace i a v
{-# NOINLINE replace_int #-}


topEntity
  :: HiddenClockReset System Source Asynchronous
  => Signal System Int
  -> Signal System (Vec 5 Char)
topEntity i = a
  where
    a =
      register
        (replace_int (repeat 'a') 3 'c')
        (replace_int <$> a <*> i <*> pure 'x')
{-# NOINLINE topEntity #-}

testBench :: Signal System Bool
testBench = done
  where
    testInput      = stimuliGenerator clk rst (1 :> 2 :> 3 :> Nil)
    expectedOutput = outputVerifier clk rst ( ('a' :> 'a' :> 'a' :> 'c' :> 'a' :> Nil)
                                           :> ('a' :> 'x' :> 'a' :> 'c' :> 'a' :> Nil)
                                           :> ('a' :> 'x' :> 'x' :> 'c' :> 'a' :> Nil)
                                           :> ('a' :> 'x' :> 'x' :> 'x' :> 'a' :> Nil)
                                           :> Nil)
    done           = expectedOutput (exposeClockReset topEntity clk rst testInput)
    clk            = tbSystemClockGen (not <$> done)
    rst            = asyncResetGen @System
{-# NOINLINE testBench #-}
