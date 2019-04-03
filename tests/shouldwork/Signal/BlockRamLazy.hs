module BlockRamLazy where

-- Issue: https://github.com/clash-lang/clash-compiler/issues/350

import Clash.Prelude

-- HACK to satisfy test runner
topEntity :: Signal System (Unsigned 1)
topEntity = pure 0

-- Actual bug test
bug = blockRamPow2 (repeat (0 :: Unsigned 1)) bug (pure Nothing)

main = mapM printX $ sampleN 4 bug
mainSystemVerilog = main
mainVerilog = main
mainVHDL = main
