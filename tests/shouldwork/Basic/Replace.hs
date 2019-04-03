
-- See: https://github.com/clash-lang/clash-compiler/issues/365
module Replace where

import Clash.Prelude
import Clash.Explicit.Testbench

import Data.Word

topEntity
  :: HiddenClockReset System Source Asynchronous
  => Signal System Word8
topEntity = fmap head r
  where
    r = register (0 :> Nil) (fmap f r)
      where
        f :: Vec 1 Word8 -> Vec 1 Word8
        f regs = replace 0 (regs!!0 + 1) regs
{-# NOINLINE topEntity #-}

testBench :: Signal System Bool
testBench = done
  where
    expectedOutput = outputVerifier clk rst (0 :> 1 :> 2 :> 3 :> Nil)
    done           = expectedOutput (exposeClockReset topEntity clk rst)
    clk            = tbSystemClockGen (not <$> done)
    rst            = asyncResetGen @System
{-# NOINLINE testBench #-}
