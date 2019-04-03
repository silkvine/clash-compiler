module IndexInt where

import Clash.Prelude
import Clash.Explicit.Testbench

index_ints
  :: KnownNat m
  => KnownNat n
  => (Vec m Int, Int)
  -> (Vec n Int, Int)
  -> (Int, Int)
index_ints (mv, mi) (nv, ni) =
  (mv !! mi, nv !! ni)
{-# NOINLINE index_ints #-}

fst' ab = fst ab
{-# NOINLINE fst' #-}

topEntity
  :: (Vec 3 Int, Int)
  -> (Vec 0 Int, Int)
  -> Int
topEntity (mv, mi) (nv, ni) =
  fst' (index_ints (mv, mi) (nv, ni))
{-# NOINLINE topEntity #-}

testBench :: Signal System Bool
testBench = done
  where
    testInput1     = (4 :> 5 :> 6 :> Nil, 1)
    testInput2     = (Nil, 1)

    expectedOutput = outputVerifier clk rst (5 :> Nil)
    done           = expectedOutput (pure (topEntity testInput1 testInput2))
    clk            = tbSystemClockGen (not <$> done)
    rst            = systemResetGen
