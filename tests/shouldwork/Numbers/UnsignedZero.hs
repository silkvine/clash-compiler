module UnsignedZero where

import Clash.Prelude
import Clash.Explicit.Testbench

topEntity
  :: Clock  System Source
  -> Reset  System Asynchronous
  -> Signal System (Unsigned 16)
  -> Signal System ( Unsigned 17
                   , Unsigned 17
                   , Unsigned 17
                   , Unsigned 16
                   , Unsigned 16
                   )
topEntity clk rst =
  fmap (\n ->
    ( add (n :: Unsigned 16) (0 :: Unsigned 0)
    , add (0 :: Unsigned 0)  (n :: Unsigned 16)
    , sub (n :: Unsigned 16) (0 :: Unsigned 0)
    , mul (n :: Unsigned 16) (0 :: Unsigned 0)
    , mul (0 :: Unsigned 0)  (n :: Unsigned 16)
    ))
{-# NOINLINE topEntity #-}

testBench :: Signal System Bool
testBench = done
  where
    n              = 22
    expectedOutput = outputVerifier clk rst ((n, n, n, 0, 0) :> Nil)
    done           = expectedOutput (topEntity clk rst (pure n))
    clk            = tbSystemClockGen (not <$> done)
    rst            = systemResetGen
{-# NOINLINE testBench #-}
