{-|
Copyright  :  (C) 2013-2016, University of Twente,
                  2017     , Google Inc.
                  2019     , Myrtle Software Ltd
License    :  BSD2 (see the file LICENSE)
Maintainer :  Christiaan Baaij <christiaan.baaij@gmail.com>
-}

{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-# LANGUAGE Unsafe #-}

{-# OPTIONS_HADDOCK show-extensions #-}

module Clash.Prelude.Testbench
  ( -- * Testbench functions for circuits
    assert
  , ignoreFor
  , outputVerifier
  , outputVerifierBitVector
  , stimuliGenerator
  )
where

import GHC.TypeLits                       (KnownNat)

import qualified Clash.Explicit.Testbench as E
import           Clash.Signal
  (HiddenClock, HiddenReset, HiddenClockResetEnable, Signal, hideClock,
  hideReset, hideClockResetEnable)
import Clash.Promoted.Nat                 (SNat)
import Clash.Sized.BitVector              (BitVector)
import Clash.Sized.Vector                 (Vec)
import Clash.XException                   (ShowX)

{- $setup
>>> :set -XTemplateHaskell -XDataKinds -XTypeApplications
>>> import Clash.Prelude
>>> let testInput = stimuliGenerator $(listToVecTH [(1::Int),3..21])
>>> let expectedOutput = outputVerifier $(listToVecTH ([70,99,2,3,4,5,7,8,9,10]::[Int]))
-}

-- | Compares the first two 'Signal's for equality and logs a warning when they
-- are not equal. The second 'Signal' is considered the expected value. This
-- function simply returns the third 'Signal' unaltered as its result. This
-- function is used by 'outputVerifier'.
--
--
-- __NB__: This function /can/ be used in synthesizable designs.
assert
  :: (Eq a, ShowX a, HiddenClock dom , HiddenReset dom )
  => String
  -- ^ Additional message
  -> Signal dom a
  -- ^ Checked value
  -> Signal dom a
  -- ^ Expected value
  -> Signal dom b
  -- ^ Return value
  -> Signal dom b
assert msg actual expected ret =
  hideReset (hideClock E.assert) msg actual expected ret

--assert {-msg actual expected ret-} =
--  hideReset (hideClock E.assert) {-msg actual expected ret-}
{-# INLINE assert #-}

-- |
--
-- Example:
--
-- @
-- testInput
--   :: HiddenClockResetEnable dom
--   => 'Signal' dom Int
-- testInput = 'stimuliGenerator' $('Clash.Sized.Vector.listToVecTH' [(1::Int),3..21])
-- @
--
-- >>> sampleN 13 testInput
-- [1,3,5,7,9,11,13,15,17,19,21,21,21]
stimuliGenerator
  :: ( KnownNat l
     , HiddenClock dom
     , HiddenReset dom  )
  => Vec l a
  -- ^ Samples to generate
  -> Signal dom a
  -- ^ Signal of given samples
stimuliGenerator = hideReset (hideClock E.stimuliGenerator)
{-# INLINE stimuliGenerator #-}

-- |
--
-- Example:
--
-- @
-- expectedOutput
--   :: HiddenClockResetEnable dom
--   -> 'Signal' dom Int -> 'Signal' dom Bool
-- expectedOutput = 'outputVerifier' $('Clash.Sized.Vector.listToVecTH' ([70,99,2,3,4,5,7,8,9,10]::[Int]))
-- @
--
-- >>> import qualified Data.List as List
-- >>> sampleN 12 (expectedOutput (fromList ([0..10] List.++ [10,10,10])))
-- <BLANKLINE>
-- cycle(system10000): 0, outputVerifier
-- expected value: 70, not equal to actual value: 0
-- [False
-- cycle(system10000): 1, outputVerifier
-- expected value: 99, not equal to actual value: 1
-- ,False,False,False,False,False
-- cycle(system10000): 6, outputVerifier
-- expected value: 7, not equal to actual value: 6
-- ,False
-- cycle(system10000): 7, outputVerifier
-- expected value: 8, not equal to actual value: 7
-- ,False
-- cycle(system10000): 8, outputVerifier
-- expected value: 9, not equal to actual value: 8
-- ,False
-- cycle(system10000): 9, outputVerifier
-- expected value: 10, not equal to actual value: 9
-- ,False,True,True]
--
-- If your working with 'BitVector's containing don't care bits you should use 'outputVerifierBitVector'.
outputVerifier
  :: ( KnownNat l
     , Eq a
     , ShowX a
     , HiddenClock dom
     , HiddenReset dom  )
  => Vec l a
  -- ^ Samples to compare with
  -> Signal dom a
  -- ^ Signal to verify
  -> Signal dom Bool
  -- ^ Indicator that all samples are verified
outputVerifier = hideReset (hideClock E.outputVerifier)
{-# INLINE outputVerifier #-}


-- | Same as 'outputVerifier',
-- but can handle don't care bits in it's expected values.
outputVerifierBitVector
  :: ( KnownNat l
     , KnownNat n
     , HiddenClock dom
     , HiddenReset dom  )
  => Vec l (BitVector n)
  -- ^ Samples to compare with
  -> Signal dom (BitVector n)
  -- ^ Signal to verify
  -> Signal dom Bool
  -- ^ Indicator that all samples are verified
outputVerifierBitVector = hideReset (hideClock E.outputVerifierBitVector)
{-# INLINE outputVerifierBitVector #-}

-- | Ignore signal for a number of cycles, while outputting a static value.
ignoreFor
  :: HiddenClockResetEnable dom
  => SNat n
  -- ^ Number of cycles to ignore incoming signal
  -> a
  -- ^ Value function produces when ignoring signal
  -> Signal dom a
  -- ^ Incoming signal
  -> Signal dom a
  -- ^ Either a passthrough of the incoming signal, or the static value
  -- provided as the second argument.
ignoreFor = hideClockResetEnable E.ignoreFor
{-# INLINE ignoreFor #-}
