{- |
Copyright  :  (C) 2017, QBayLogic
License    :  BSD2 (see the file LICENSE)
Maintainer :  Christiaan Baaij <christiaan.baaij@gmail.com>

Add inline documentation to types:

@
fifo
  :: Clock domain gated
  -> Reset domain synchronous
  -> SNat addrSize
  -> "read request" ::: Signal domain Bool
  -> "write request" ::: Signal domain (Maybe (BitVector dataSize))
  -> ( "q"     ::: Signal domain (BitVector dataSize)
     , "full"  ::: Signal domain Bool
     , "empty" ::: Signal domain Bool
     )
@

which can subsequently be inspected in the interactive environment:

>>> :t fifo @System
fifo @System
  :: Clock System gated
     -> Reset System synchronous
     -> SNat addrSize
     -> ("read request" ::: Signal System Bool)
     -> ("write request" ::: Signal System (Maybe (BitVector dataSize)))
     -> ("q" ::: Signal System (BitVector dataSize),
         "full" ::: Signal System Bool, "empty" ::: Signal System Bool)

-}

{-# LANGUAGE PolyKinds     #-}
{-# LANGUAGE TypeOperators #-}

{-# LANGUAGE Safe #-}

{-# OPTIONS_HADDOCK show-extensions #-}

module CLaSH.NamedTypes
  ((:::))
where

type (name :: k) ::: a = a
-- ^ Annotate a type with a name

{- $setup
>>> :set -XDataKinds -XTypeOperators -XNoImplicitPrelude
>>> import CLaSH.Explicit.Prelude
>>> :{
let fifo
      :: Clock domain gated
      -> Reset domain synchronous
      -> SNat addrSize
      -> "read request" ::: Signal domain Bool
      -> "write request" ::: Signal domain (Maybe (BitVector dataSize))
      -> ( "q"     ::: Signal domain (BitVector dataSize)
         , "full"  ::: Signal domain Bool
         , "empty" ::: Signal domain Bool
         )
    fifo = CLaSH.Explicit.Prelude.undefined
:}

-}
