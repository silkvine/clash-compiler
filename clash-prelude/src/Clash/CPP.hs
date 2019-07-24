{-|
Copyright  :  (C) 2019, Myrtle Software Ltd
License    :  BSD2 (see the file LICENSE)
Maintainer :  Christiaan Baaij <christiaan.baaij@gmail.com>
-}

{-# LANGUAGE CPP#-}
{-# OPTIONS_HADDOCK hide #-}

#ifndef MAX_TUPLE_SIZE
#define MAX_TUPLE_SIZE 62
#endif

module Clash.CPP
 ( maxTupleSize
 ) where

maxTupleSize :: Num a => a
maxTupleSize = MAX_TUPLE_SIZE
