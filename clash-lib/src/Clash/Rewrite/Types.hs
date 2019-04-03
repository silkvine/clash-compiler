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
import Control.Monad
import Control.Monad.Fail                    (MonadFail(fail))
import Control.Monad.Fix                     (MonadFix (..), fix)
import Control.Monad.Reader                  (MonadReader (..))
import Control.Monad.State                   (MonadState (..))
import Control.Monad.Writer                  (MonadWriter (..))
import Data.IntMap.Strict                    (IntMap)
import Data.Monoid                           (Any)
import Data.Text                             (Text)

import SrcLoc (SrcSpan)

import Clash.Core.Evaluator      (GlobalHeap, PrimEvaluator)
import Clash.Core.Term           (Term)
import Clash.Core.Type           (Type)
import Clash.Core.TyCon          (TyConName, TyConMap)
import Clash.Core.Var            (Id, TyVar)
import Clash.Core.VarEnv         (InScopeSet, VarSet)
import Clash.Driver.Types        (BindingMap, DebugLevel)
import Clash.Netlist.Types       (FilteredHWType)
import Clash.Util

import Clash.Annotations.BitRepresentation.Internal (CustomReprs)

-- | Context in which a term appears
data CoreContext
  = AppFun
  -- ^ Function position of an application
  | AppArg (Maybe (Text, Int, Int))
  -- ^ Argument position of an application. If this is an argument applied to
  -- a primitive, a tuple is defined containing (name of the primitive, #type
  -- args, #term args)
  | TyAppC
  -- ^ Function position of a type application
  | LetBinding Id [Id]
  -- ^ RHS of a Let-binder with the sibling LHS'
  | LetBody [Id]
  -- ^ Body of a Let-binding with the bound LHS'
  | LamBody Id
  -- ^ Body of a lambda-term with the abstracted variable
  | TyLamBody TyVar
  -- ^ Body of a TyLambda-term with the abstracted type-variable
  | CaseAlt [TyVar] [Id]
  -- ^ RHS of a case-alternative with the variables bound by
  -- the pattern on the LHS
  | CaseScrut
  -- ^ Subject of a case-decomposition
  | CastBody
  -- ^ Body of a Cast
  deriving (Eq,Show)

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
  , _globalInScope    :: !InScopeSet
  -- ^ Superset of global binders
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
                    -> Maybe (Either String FilteredHWType)
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
  { runR :: RewriteEnv -> RewriteState extra -> (a,RewriteState extra,Any) }

instance MonadFail (RewriteMonad extra) where
  fail err = error ("RewriteMonad.fail: " ++ err)

instance Functor (RewriteMonad extra) where
  fmap f m = R (\r s -> case runR m r s of (a,s',w) -> (f a,s',w))

instance Applicative (RewriteMonad extra) where
  pure  = return
  (<*>) = ap

instance Monad (RewriteMonad extra) where
  return a = R (\_ s -> (a, s, mempty))
  m >>= k  = R (\r s -> case runR m r s of
                          (a,s',w) -> case runR (k a) r s' of
                                        (b,s'',w') -> let w'' = mappend w w'
                                                      in seq w'' (b,s'',w''))

instance MonadState (RewriteState extra) (RewriteMonad extra) where
  get     = R (\_ s -> (s,s,mempty))
  put s   = R (\_ _ -> ((),s,mempty))
  state f = R (\_ s -> case f s of (a,s') -> (a,s',mempty))

instance MonadUnique (RewriteMonad extra) where
  getUniqueM = do
    sup <- use uniqSupply
    let (a,sup') = freshId sup
    uniqSupply .= sup'
    a `seq` return a

instance MonadWriter Any (RewriteMonad extra) where
  writer (a,w) = R (\_ s -> (a,s,w))
  tell   w     = R (\_ s -> ((),s,w))
  listen m     = R (\r s -> case runR m r s of (a,s',w) -> ((a,w),s',w))
  pass   m     = R (\r s -> case runR m r s of ((a,f),s',w) -> (a, s', f w))

instance MonadReader RewriteEnv (RewriteMonad extra) where
   ask       = R (\r s -> (r,s,mempty))
   local f m = R (\r s -> runR m (f r) s)
   reader f  = R (\r s -> (f r,s,mempty))

instance MonadFix (RewriteMonad extra) where
  mfix f = R (\r s -> fix $ \ ~(a,_,_) -> runR (f a) r s)

data TransformContext
  = TransformContext
  { tfInScope     :: !InScopeSet
  , tfCoreContext :: [CoreContext]
  }

-- | Monadic action that transforms a term given a certain context
type Transform m = TransformContext -> Term -> m Term

-- | A 'Transform' action in the context of the 'RewriteMonad'
type Rewrite extra = Transform (RewriteMonad extra)
