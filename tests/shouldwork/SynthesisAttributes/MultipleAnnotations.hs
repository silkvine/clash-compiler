module Product where

import qualified Prelude as P
import Prelude ((++))

import Clash.Prelude hiding (assert, (++))
import Clash.Annotations.SynthesisAttributes

import Data.String (IsString)
import Data.List (isInfixOf)
import System.Environment (getArgs)
import System.FilePath ((</>))

import qualified Data.Text as T
import qualified Data.Text.IO as T

--------------- Logic -------------------
mac xy = mealy macT 0 xy
  where
    macT acc (x,y) = (acc',o)
      where
        acc' = acc + x * y
        o    = acc

topEntity
  :: SystemClockReset
  => (Signal System (Signed 9) `Annotate` 'StringAttr "top" "input1") `Annotate` 'StringAttr "top" "input2"
  -> Signal System (Signed 9)
  -> Signal System (Signed 9)
topEntity x y = mac $ bundle (x, y)


--------------- Actual tests for generated HDL -------------------
assertIn :: String -> String -> IO ()
assertIn :: String -> String -> IO ()
assertIn needle haystack
  | needle `isInfixOf` haystack = return ()
  | otherwise                   = P.error $ P.concat [ "Expected:\n\n  ", needle
                                                     , "\n\nIn:\n\n", haystack ]

-- VHDL test
mainVHDL :: IO ()
mainVHDL = do
  [topFile] <- getArgs
  content <- readFile topFile

  assertIn "attribute top : string;" content
  assertIn " : signal is \"input1\"" content
  assertIn " : signal is \"input2\"" content

-- Verilog test
mainVerilog :: IO ()
mainVerilog = do
  topFile <- getArgs
  content <- readFile topFile

  assertIn "(* top = \"input1\" *) input" content
  assertIn "(* top = \"input2\" *) input" content

-- Verilog and SystemVerilog should share annotation syntax
mainSystemVerilog = mainVerilog

