{-|
  Copyright  :  (C) 2012-2016, University of Twente,
                    2016     , Myrtle Software Ltd,
                    2017     , Google Inc.
  License    :  BSD2 (see the file LICENSE)
  Maintainer :  Christiaan Baaij <christiaan.baaij@gmail.com>

  Type and instance definitions for Rewrite modules
-}

{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell            #-}

module Clash.Rewrite.Types where

import Control.Concurrent.Supply             (Supply, freshId)
import Control.Lens                          (use, (.=))
import Control.Monad.Fail                    (MonadFail(fail))
import Control.Monad.Fix                     (MonadFix (..), fix)
import Control.Monad.Reader                  (MonadReader (..))
import Control.Monad.State                   (MonadState (..))
import Control.Monad.State.Strict            (State)
import Control.Monad.Writer                  (MonadWriter (..))
import Data.IntMap.Strict                    (IntMap)
import Data.Monoid                           (Any)

import SrcLoc (SrcSpan)

import Clash.Core.Evaluator      (GlobalHeap, PrimEvaluator)
import Clash.Core.Term           (Term, Context)
import Clash.Core.Type           (Type)
import Clash.Core.TyCon          (TyConName, TyConMap)
import Clash.Core.Var            (Id)
import Clash.Core.VarEnv         (InScopeSet, VarSet)
import Clash.Driver.Types        (BindingMap, DebugLevel)
import Clash.Netlist.Types       (FilteredHWType, HWMap)
import Clash.Util

import Clash.Annotations.BitRepresentation.Internal (CustomReprs)

-- | State of a rewriting session
data RewriteState extra
  = RewriteState
  { _transformCounter :: {-# UNPACK #-} !Int
  -- ^ Number of applied transformations
  , _bindings         :: !BindingMap
  -- ^ Global binders
  , _uniqSupply       :: !Supply
  -- ^ Supply of unique numbers
  , _curFun           :: (Id,SrcSpan) -- Initially set to undefined: no strictness annotation
  -- ^ Function which is currently normalized
  , _nameCounter      :: {-# UNPACK #-} !Int
  -- ^ Used for 'Fresh'
  , _globalHeap       :: GlobalHeap
  -- ^ Used as a heap for compile-time evaluation of primitives that live in I/O
  , _extra            :: !extra
  -- ^ Additional state
  }

makeLenses ''RewriteState

-- | Read-only environment of a rewriting session
data RewriteEnv
  = RewriteEnv
  { _dbgLevel       :: DebugLevel
  -- ^ Lvl at which we print debugging messages
  , _typeTranslator :: CustomReprs
                    -> TyConMap
                    -> Type
                    -> State HWMap (Maybe (Either String FilteredHWType))
  -- ^ Hardcode Type -> FilteredHWType translator
  , _tcCache        :: TyConMap
  -- ^ TyCon cache
  , _tupleTcCache   :: IntMap TyConName
  -- ^ Tuple TyCon cache
  , _evaluator      :: PrimEvaluator
  -- ^ Hardcoded evaluator (delta-reduction)}
  , _topEntities    :: VarSet
  -- ^ Functions that are considered TopEntities
  , _customReprs    :: CustomReprs
  -- ^ Custom bit representations
  }

makeLenses ''RewriteEnv

-- | Monad that keeps track how many transformations have been applied and can
-- generate fresh variables and unique identifiers. In addition, it keeps track
-- if a transformation/rewrite has been successfully applied.
newtype RewriteMonad extra a = R
  { unR :: RewriteEnv -> RewriteState extra -> Any -> (a,RewriteState extra,Any) }

-- | Run the computation in the RewriteMonad
runR
  :: RewriteMonad extra a
  -> RewriteEnv
  -> RewriteState extra
  -> (a, RewriteState extra, Any)
runR m r s = unR m r s mempty

instance MonadFail (RewriteMonad extra) where
  fail err = error ("RewriteMonad.fail: " ++ err)

instance Functor (RewriteMonad extra) where
  fmap f m = R $ \ r s w -> case unR m r s w of (a, s', w') -> (f a, s', w')
  {-# INLINE fmap #-}

instance Applicative (RewriteMonad extra) where
  pure a = R $ \ _ s w -> (a, s, w)
  {-# INLINE pure #-}
  R mf <*> R mx = R $ \ r s w -> case mf r s w of
    (f,s',w') -> case mx r s' w' of
      (x,s'',w'') -> (f x, s'', w'')
  {-# INLINE (<*>) #-}

instance Monad (RewriteMonad extra) where
  return a = R $ \ _ s w -> (a, s, w)
  {-# INLINE return #-}
  m >>= k  =
    R $ \ r s w -> case unR m r s w of
      (a,s',w') -> unR (k a) r s' w'
  {-# INLINE (>>=) #-}


instance MonadState (RewriteState extra) (RewriteMonad extra) where
  get = R $ \_ s w -> (s,s,w)
  {-# INLINE get #-}
  put s = R $ \_ _ w -> ((),s,w)
  {-# INLINE put #-}
  state f = R $ \_ s w -> case f s of (a,s') -> (a,s',w)
  {-# INLINE state #-}

instance MonadUnique (RewriteMonad extra) where
  getUniqueM = do
    sup <- use uniqSupply
    let (a,sup') = freshId sup
    uniqSupply .= sup'
    a `seq` return a

instance MonadWriter Any (RewriteMonad extra) where
  writer (a,w') = R $ \_ s w -> let wt = w `mappend` w' in wt `seq` (a,s,wt)
  {-# INLINE writer #-}
  tell w' = R $ \_ s w -> let wt = w `mappend` w' in wt `seq` ((),s,wt)
  {-# INLINE tell #-}
  listen m = R $ \r s w -> case runR m r s of
    (a,s',w') -> let wt = w `mappend` w' in wt `seq` ((a,w'),s',wt)
  {-# INLINE listen #-}
  pass m = R $ \r s w -> case runR m r s of
    ((a,f),s',w') -> let wt = w `mappend` f w' in wt `seq` (a, s', wt)
  {-# INLINE pass #-}

censor :: (Any -> Any) -> RewriteMonad extra a -> RewriteMonad extra a
censor f m = R $ \r s w -> case runR m r s of
  (a,s',w') -> let wt = w `mappend` f w' in wt `seq` (a, s', wt)
{-# INLINE censor #-}

instance MonadReader RewriteEnv (RewriteMonad extra) where
   ask = R $ \r s w -> (r,s,w)
   {-# INLINE ask #-}
   local f m = R $ \r s w -> unR m (f r) s w
   {-# INLINE local #-}
   reader f = R $ \r s w -> (f r,s,w)
   {-# INLINE reader #-}

instance MonadFix (RewriteMonad extra) where
  mfix f = R $ \r s w -> fix $ \ ~(a,_,_) -> unR (f a) r s w
  {-# INLINE mfix #-}

data TransformContext
  = TransformContext
  { tfInScope :: !InScopeSet
  , tfContext :: Context
  }

-- | Monadic action that transforms a term given a certain context
type Transform m = TransformContext -> Term -> m Term

-- | A 'Transform' action in the context of the 'RewriteMonad'
type Rewrite extra = Transform (RewriteMonad extra)
