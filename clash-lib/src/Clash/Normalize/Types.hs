{-|
  Copyright  :  (C) 2012-2016, University of Twente,
                         2017, Google Inc.
  License    :  BSD2 (see the file LICENSE)
  Maintainer :  Christiaan Baaij <christiaan.baaij@gmail.com>

  Types used in Normalize modules
-}

{-# LANGUAGE TemplateHaskell   #-}

module Clash.Normalize.Types where

import Control.Monad.State.Strict (State)
import Data.Map                   (Map)
import Data.Set                   (Set)
import Data.Text                  (Text)

import Clash.Core.Term        (Term)
import Clash.Core.Type        (Type)
import Clash.Core.Var         (Id)
import Clash.Core.VarEnv      (VarEnv)
import Clash.Driver.Types     (BindingMap)
import Clash.Primitives.Types (CompiledPrimMap)
import Clash.Rewrite.Types    (Rewrite, RewriteMonad)
import Clash.Util

-- | State of the 'NormalizeMonad'
data NormalizeState
  = NormalizeState
  { _normalized          :: BindingMap
  -- ^ Global binders
  , _specialisationCache :: Map (Id,Int,Either Term Type) Id
  -- ^ Cache of previously specialised functions:
  --
  -- * Key: (name of the original function, argument position, specialised term/type)
  --
  -- * Elem: (name of specialised function,type of specialised function)
  , _specialisationHistory :: VarEnv Int
  -- ^ Cache of how many times a function was specialized
  , _specialisationLimit :: !Int
  -- ^ Number of time a function 'f' can be specialized
  , _inlineHistory   :: VarEnv (VarEnv Int)
  -- ^ Cache of function where inlining took place:
  --
  -- * Key: function where inlining took place
  --
  -- * Elem: (functions which were inlined, number of times inlined)
  , _inlineLimit     :: !Int
  -- ^ Number of times a function 'f' can be inlined in a function 'g'
  , _inlineFunctionLimit :: !Word
  -- ^ Size of a function below which it is always inlined if it is not
  -- recursive
  , _inlineConstantLimit :: !Word
  -- ^ Size of a constant below which it is always inlined; 0 = no limit
  , _primitives :: CompiledPrimMap
  -- ^ Primitive Definitions
  , _primitiveArgs :: Map Text (Set Int)
  -- ^ Cache for looking up constantness of blackbox arguments
  , _recursiveComponents :: VarEnv Bool
  -- ^ Map telling whether a components is recursively defined.
  --
  -- NB: there are only no mutually-recursive component, only self-recursive
  -- ones.
  , _newInlineStrategy :: Bool
  -- ^ Flattening stage should use the new (no-)inlining strategy
  }

makeLenses ''NormalizeState


-- | State monad that stores specialisation and inlining information
type NormalizeMonad = State NormalizeState

-- | RewriteSession with extra Normalisation information
type NormalizeSession = RewriteMonad NormalizeState

-- | A 'Transform' action in the context of the 'RewriteMonad' and 'NormalizeMonad'
type NormRewrite = Rewrite NormalizeState

-- | Description of a @Term@ in terms of the type "components" the @Term@ has.
--
-- Is used as a performance/size metric.
data TermClassification
  = TermClassification
  { _function   :: !Int -- ^ Number of functions
  , _primitive  :: !Int -- ^ Number of primitives
  , _selection  :: !Int -- ^ Number of selections/multiplexers
  }
  deriving Show

makeLenses ''TermClassification
