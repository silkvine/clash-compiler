{-|
  Copyright  :  (C) 2012-2016, University of Twente,
                    2016     , Myrtle Software Ltd,
                    2017     , Google Inc.
  License    :  BSD2 (see the file LICENSE)
  Maintainer :  Christiaan Baaij <christiaan.baaij@gmail.com>

  Utilities for rewriting: e.g. inlining, specialisation, etc.
-}

{-# LANGUAGE CPP                      #-}
{-# LANGUAGE LambdaCase               #-}
{-# LANGUAGE NondecreasingIndentation #-}
{-# LANGUAGE OverloadedStrings        #-}
{-# LANGUAGE Rank2Types               #-}
{-# LANGUAGE FlexibleContexts         #-}
{-# LANGUAGE TemplateHaskell          #-}
{-# LANGUAGE ViewPatterns             #-}

module Clash.Rewrite.Util where

import           Control.DeepSeq
import           Control.Exception           (throw)
import           Control.Lens
  (Lens', (%=), (+=), (^.), _3, _4, _Left)
import qualified Control.Lens                as Lens
import qualified Control.Monad               as Monad
import           Control.Monad.Fail          (MonadFail)
import qualified Control.Monad.State.Strict  as State
import qualified Control.Monad.Writer        as Writer
import           Data.Bifunctor              (bimap)
import           Data.Coerce                 (coerce)
import           Data.Functor.Const          (Const (..))
import           Data.List                   (group, sort)
import qualified Data.Map                    as Map
import           Data.Maybe                  (catMaybes,isJust,mapMaybe)
import qualified Data.Monoid                 as Monoid
import qualified Data.Set                    as Set
import qualified Data.Set.Lens               as Lens
import qualified Data.Text                   as Text

import           BasicTypes                  (InlineSpec (..))
import           SrcLoc                      (SrcSpan)
import           GHC.Stack                   (HasCallStack)

import           Clash.Core.DataCon          (dcExtTyVars)
import           Clash.Core.FreeVars
  (idDoesNotOccurIn, idOccursIn, typeFreeVars, termFreeVars')
import           Clash.Core.Name
import           Clash.Core.Pretty           (showPpr)
import           Clash.Core.Subst
  (aeqTerm, aeqType, extendIdSubst, mkSubst, substTm)
import           Clash.Core.Term
  (LetBinding, Pat (..), Term (..), TmName)
import           Clash.Core.TyCon
  (TyConMap, tyConDataCons)
import           Clash.Core.Type             (KindOrType, Type (..),
                                              TypeView (..), coreView1,
                                              normalizeType,
                                              typeKind, tyView)
import           Clash.Core.Util
  (collectArgs, isPolyFun, mkAbstraction, mkApps, mkLams,
   mkTmApps, mkTyApps, mkTyLams, termType, dataConInstArgTysE, isClockOrReset)
import           Clash.Core.Var
  (Id, TyVar, Var (..), mkId, mkTyVar)
import           Clash.Core.VarEnv
  (InScopeSet, VarEnv, elemVarSet, extendInScopeSet,
   extendInScopeSetList, mkInScopeSet, notElemVarEnv, unionInScope, uniqAway)
import           Clash.Driver.Types
  (DebugLevel (..))
import           Clash.Netlist.Util          (representableType)
import           Clash.Rewrite.Types
import           Clash.Unique
import           Clash.Util

-- | Lift an action working in the '_extra' state to the 'RewriteMonad'
zoomExtra :: State.State extra a
          -> RewriteMonad extra a
zoomExtra m = R (\_ s -> case State.runState m (s ^. extra) of
                           (a,s') -> (a,s {_extra = s'},mempty))

-- | Some transformations might erroneously introduce shadowing. For example,
-- a transformation might result in:
--
--   let a = ...
--       b = ...
--       a = ...
--
-- where the last 'a', shadows the first, while Clash assumes that this can't
-- happen. This function finds those constructs and a list of found duplicates.
--
findAccidentialShadows :: Term -> [[Id]]
findAccidentialShadows =
  \case
    Var {}      -> []
    Data {}     -> []
    Literal {}  -> []
    Prim {}     -> []
    Lam _ t     -> findAccidentialShadows t
    TyLam _ t   -> findAccidentialShadows t
    App t1 t2   -> concatMap findAccidentialShadows [t1, t2]
    TyApp t _   -> findAccidentialShadows t
    Cast t _ _  -> findAccidentialShadows t
    Case t _ as ->
      concatMap (findInPat . fst) as ++
        concatMap findAccidentialShadows (t : map snd as)
    Letrec bs t ->
      findDups (map fst bs) ++ findAccidentialShadows t

 where
  findInPat :: Pat -> [[Id]]
  findInPat (LitPat _)        = []
  findInPat (DefaultPat)      = []
  findInPat (DataPat _ _ ids) = findDups ids

  findDups :: [Id] -> [[Id]]
  findDups ids = filter ((1 <) . length) (group (sort ids))


-- | Record if a transformation is successfully applied
apply
  :: String
  -- ^ Name of the transformation
  -> Rewrite extra
  -- ^ Transformation to be applied
  -> Rewrite extra
apply name rewrite ctx expr = do
  lvl <- Lens.view dbgLevel
  let before = showPpr expr
  (expr', anyChanged) <- traceIf (lvl >= DebugAll) ("Trying: " ++ name ++ " on:\n" ++ before) $ Writer.listen $ rewrite ctx expr
  let hasChanged = Monoid.getAny anyChanged
  Monad.when hasChanged $ transformCounter += 1
  let after  = showPpr expr'
  let expr'' = if hasChanged then expr' else expr

  Monad.when (lvl > DebugNone && hasChanged) $ do
    tcm                  <- Lens.view tcCache
    let beforeTy          = termType tcm expr
    beforeFV             <- Lens.setOf <$> localFreeVars <*> pure expr
    let afterTy           = termType tcm expr'
    afterFV              <- Lens.setOf <$> localFreeVars <*> pure expr'
    let newFV             = not (afterFV `Set.isSubsetOf` beforeFV)
    let accidentalShadows = findAccidentialShadows expr'

    Monad.when newFV $
            error ( concat [ $(curLoc)
                           , "Error when applying rewrite ", name
                           , " to:\n" , before
                           , "\nResult:\n" ++ after ++ "\n"
                           , "It introduces free variables."
                           , "\nBefore: " ++ showPpr (Set.toList beforeFV)
                           , "\nAfter: " ++ showPpr (Set.toList afterFV)
                           ]
                  )
    Monad.when (not (null accidentalShadows)) $
      error ( concat [ $(curLoc)
                     , "Error when applying rewrite ", name
                     , " to:\n" , before
                     , "\nResult:\n" ++ after ++ "\n"
                     , "It accidentally creates shadowing let/case-bindings:\n"
                     , " ", showPpr accidentalShadows, "\n"
                     , "This usually means that a transformation did not extend "
                     , "or incorrectly extended its InScopeSet before applying a "
                     , "substitution."
                     ])

    traceIf (lvl >= DebugAll && (beforeTy `aeqType` afterTy))
            ( concat [ $(curLoc)
                     , "Error when applying rewrite ", name
                     , " to:\n" , before
                     , "\nResult:\n" ++ after ++ "\n"
                     , "Changes type from:\n", showPpr beforeTy
                     , "\nto:\n", showPpr afterTy
                     ]
            ) (return ())

  Monad.when (lvl >= DebugApplied && not hasChanged && not (expr `aeqTerm` expr')) $
    error $ $(curLoc) ++ "Expression changed without notice(" ++ name ++  "): before" ++ before ++ "\nafter:\n" ++ after

  traceIf (lvl >= DebugName && hasChanged) name $
    traceIf (lvl >= DebugApplied && hasChanged) ("Changes when applying rewrite to:\n" ++ before ++ "\nResult:\n" ++ after ++ "\n") $
      traceIf (lvl >= DebugAll && not hasChanged) ("No changes when applying rewrite " ++ name ++ " to:\n" ++ after ++ "\n") $
        return expr''

-- | Perform a transformation on a Term
runRewrite
  :: String
  -- ^ Name of the transformation
  -> InScopeSet
  -> Rewrite extra
  -- ^ Transformation to perform
  -> Term
  -- ^ Term to transform
  -> RewriteMonad extra Term
runRewrite name is rewrite expr = apply name rewrite (TransformContext is []) expr

-- | Evaluate a RewriteSession to its inner monad
runRewriteSession :: RewriteEnv
                  -> RewriteState extra
                  -> RewriteMonad extra a
                  -> a
runRewriteSession r s m = traceIf True ("Clash: Applied " ++
                                        show (s' ^. transformCounter) ++
                                        " transformations")
                                  a
  where
    (a,s',_) = runR m r s

-- | Notify that a transformation has changed the expression
setChanged :: RewriteMonad extra ()
setChanged = Writer.tell (Monoid.Any True)

-- | Identity function that additionally notifies that a transformation has
-- changed the expression
changed :: a -> RewriteMonad extra a
changed val = do
  Writer.tell (Monoid.Any True)
  return val

closestLetBinder :: [CoreContext] -> Maybe Id
closestLetBinder [] = Nothing
closestLetBinder (LetBinding id_ _:_) = Just id_
closestLetBinder (_:ctx)              = closestLetBinder ctx

mkDerivedName :: TransformContext -> OccName -> TmName
mkDerivedName (TransformContext _ ctx) sf = case closestLetBinder ctx of
  Just id_ -> appendToName (varName id_) ('_' `Text.cons` sf)
  _ -> mkUnsafeInternalName sf 0

-- | Make a new binder and variable reference for a term
mkTmBinderFor
  :: (Monad m, MonadUnique m, MonadFail m)
  => InScopeSet
  -> TyConMap -- ^ TyCon cache
  -> Name a -- ^ Name of the new binder
  -> Term -- ^ Term to bind
  -> m Id
mkTmBinderFor is tcm name e = do
  Left r <- mkBinderFor is tcm name (Left e)
  return r

-- | Make a new binder and variable reference for either a term or a type
mkBinderFor
  :: (Monad m, MonadUnique m, MonadFail m)
  => InScopeSet
  -> TyConMap -- ^ TyCon cache
  -> Name a -- ^ Name of the new binder
  -> Either Term Type -- ^ Type or Term to bind
  -> m (Either Id TyVar)
mkBinderFor is tcm name (Left term) = do
  name' <- cloneName name
  let ty = termType tcm term
  return (Left (uniqAway is (mkId ty (coerce name'))))

mkBinderFor is tcm name (Right ty) = do
  name' <- cloneName name
  let ki = typeKind tcm ty
  return (Right (uniqAway is (mkTyVar ki (coerce name'))))

-- | Make a new, unique, identifier
mkInternalVar
  :: (Monad m, MonadUnique m)
  => InScopeSet
  -> OccName
  -- ^ Name of the identifier
  -> KindOrType
  -> m Id
mkInternalVar inScope name ty = do
  i <- getUniqueM
  let nm = mkUnsafeInternalName name i
  return (uniqAway inScope (mkId ty nm))

-- | Inline the binders in a let-binding that have a certain property
inlineBinders
  :: (Term -> LetBinding -> RewriteMonad extra Bool)
  -- ^ Property test
  -> Rewrite extra
inlineBinders condition (TransformContext inScope0 _) expr@(Letrec xes res) = do
  (replace,others) <- partitionM (condition expr) xes
  case replace of
    [] -> return expr
    _  -> do
      let inScope1 = extendInScopeSetList inScope0 (map fst xes)
      inScope2 <- unionInScope inScope1 <$> Lens.use globalInScope
      let (others',res') = substituteBinders inScope2 replace others res
          newExpr = case others' of
                          [] -> res'
                          _  -> Letrec others' res'

      changed newExpr

inlineBinders _ _ e = return e

-- | Determine whether a binder is a join-point created for a complex case
-- expression.
--
-- A join-point is when a local function only occurs in tail-call positions,
-- and when it does, more than once.
isJoinPointIn :: Id   -- ^ 'Id' of the local binder
              -> Term -- ^ Expression in which the binder is bound
              -> Bool
isJoinPointIn id_ e = case tailCalls id_ e of
                      Just n | n > 1 -> True
                      _              -> False

-- | Count the number of (only) tail calls of a function in an expression.
-- 'Nothing' indicates that the function was used in a non-tail call position.
tailCalls :: Id   -- ^ Function to check
          -> Term -- ^ Expression to check it in
          -> Maybe Int
tailCalls id_ = \case
  Var nm | id_ == nm -> Just 1
         | otherwise -> Just 0
  Lam _ e -> tailCalls id_ e
  TyLam _ e -> tailCalls id_ e
  App l r  -> case tailCalls id_ r of
                Just 0 -> tailCalls id_ l
                _      -> Nothing
  TyApp l _ -> tailCalls id_ l
  Letrec bs e ->
    let (bsIds,bsExprs) = unzip bs
        bsTls           = map (tailCalls id_) bsExprs
        bsIdsUsed       = mapMaybe (\(l,r) -> pure l <* r) (zip bsIds bsTls)
        bsIdsTls        = map (`tailCalls` e) bsIdsUsed
        bsCount         = pure . sum $ catMaybes bsTls
    in  case (all isJust bsTls) of
          False -> Nothing
          True  -> case (all (==0) $ catMaybes bsTls) of
            False  -> case all isJust bsIdsTls of
              False -> Nothing
              True  -> (+) <$> bsCount <*> tailCalls id_ e
            True -> tailCalls id_ e
  Case scrut _ alts ->
    let scrutTl = tailCalls id_ scrut
        altsTl  = map (tailCalls id_ . snd) alts
    in  case scrutTl of
          Just 0 | all (/= Nothing) altsTl -> Just (sum (catMaybes altsTl))
          _ -> Nothing
  _ -> Just 0

-- | Determines whether a function has the following shape:
--
-- > \(w :: Void) -> f a b c
--
-- i.e. is a wrapper around a (partially) applied function 'f', where the
-- introduced argument 'w' is not used by 'f'
isVoidWrapper :: Term -> Bool
isVoidWrapper (Lam bndr e@(collectArgs -> (Var _,_))) = bndr `idDoesNotOccurIn` e
isVoidWrapper _ = False

-- | Substitute the RHS of the first set of Let-binders for references to the
-- first set of Let-binders in: the second set of Let-binders and the additional
-- term
substituteBinders
  :: InScopeSet
  -> [LetBinding]
  -- ^ Let-binders to substitute
  -> [LetBinding]
  -- ^ Let-binders where substitution takes place
  -> Term
  -- ^ Expression where substitution takes place
  -> ([LetBinding],Term)
substituteBinders _ []    others res = (others,res)
substituteBinders inScope ((bndr,val):rest) others res =
  substituteBinders inScope rest' others' res'
 where
  subst    = extendIdSubst (mkSubst inScope) bndr val
  selfRef  = bndr `idOccursIn` val
  (res',rest',others') = if selfRef
    then (res,rest,(bndr,val):others)
    else ( substTm "substituteBindersRes" subst res
         , map (second (substTm "substituteBindersRest" subst)) rest
         , map (second (substTm "substituteBindersOthers" subst)) others
         )

-- | Calculate the /local/ free identifiers of an expression: the free
-- identifiers that are not bound in the global environment.
localFreeIds :: (Applicative f, Lens.Contravariant f)
             => RewriteMonad extra ((Id -> f Id) -> Term -> f Term)
localFreeIds = do
  globalBndrs <- Lens.use bindings
  let f i@(Id {}) = i `notElemUniqMap` globalBndrs
      f _         = False
  return (termFreeVars' f)

-- | Calculate the /local/ free variable of an expression: the free type
-- variables and the free identifiers that are not bound in the global
-- environment.
localFreeVars
  :: (Applicative f, Lens.Contravariant f)
  => RewriteMonad extra ((Var a -> f (Var a)) -> Term -> f Term)
localFreeVars = do
  globalBndrs <- Lens.use bindings
  let f i@(Id {}) = i `notElemUniqMap` globalBndrs
      f _         = True
  return (termFreeVars' f)

-- | Determines if term has any locally free variables. That is, the free type
-- variables and the free identifiers that are not bound in the global
-- scope.
hasLocalFreeVars :: RewriteMonad extra (Term -> Bool)
hasLocalFreeVars = Lens.notNullOf <$> localFreeVars

-- | Determine if a term represents a constant
isConstant :: Term -> RewriteMonad extra Bool
isConstant e = case collectArgs e of
  (Data _, args)   -> and <$> mapM (either isConstant (const (pure True))) args
  (Prim _ _, args) -> and <$> mapM (either isConstant (const (pure True))) args
  (Lam _ _, _)     -> not <$> (hasLocalFreeVars <*> pure e)
  (Literal _,_)    -> pure True
  _                -> pure False

isConstantNotClockReset
  :: Term
  -> RewriteMonad extra Bool
isConstantNotClockReset e = do
  tcm <- Lens.view tcCache
  let eTy = termType tcm e
  if isClockOrReset tcm eTy
     then case collectArgs e of
        (Prim nm _,_) -> return (nm == "Clash.Transformations.removedArg")
        _ -> return False
     else isConstant e

inlineOrLiftBinders
  :: (LetBinding -> RewriteMonad extra Bool)
  -- ^ Property test
  -> (Term -> LetBinding -> RewriteMonad extra Bool)
  -- ^ Test whether to lift or inline
  --
  -- * True: inline
  -- * False: lift
  -> Rewrite extra
inlineOrLiftBinders condition inlineOrLift (TransformContext inScope0 _) expr@(Letrec xes res) = do
  (replace,others) <- partitionM condition xes
  case replace of
    [] -> return expr
    _  -> do
      let inScope1 = extendInScopeSetList inScope0 (map fst xes)
      inScope2 <- unionInScope inScope1 <$> Lens.use globalInScope
      (doInline,doLift) <- partitionM (inlineOrLift expr) replace
      -- We first substitute the binders that we can inline both the binders
      -- that we intend to lift, the other binders, and the body
      let (others',res')     = substituteBinders inScope2 doInline (doLift ++ others) res
          (doLift',others'') = splitAt (length doLift) others'
      doLift'' <- mapM liftBinding doLift'
      -- Add the new lifted binders to the inscope set
      inScope3 <- unionInScope inScope1 <$> Lens.use globalInScope
      -- We then substitute the lifted binders in the other binders and the body
      let (others3,res'') = substituteBinders inScope3 doLift'' others'' res'
          newExpr = case others3 of
                      [] -> res''
                      _  -> Letrec others3 res''
      changed newExpr

inlineOrLiftBinders _ _ _ e = return e

-- | Create a global function for a Let-binding and return a Let-binding where
-- the RHS is a reference to the new global function applied to the free
-- variables of the original RHS
liftBinding :: LetBinding
            -> RewriteMonad extra LetBinding
liftBinding (var@Id {varName = idName} ,e) = do
  globalBndrs <- Lens.use bindings
  -- Get all local FVs, excluding the 'idName' from the let-binding
  let unitFV :: Var a -> Const (UniqSet TyVar,UniqSet Id) (Var a)
      unitFV v@(Id {})    = Const (emptyUniqSet,unitUniqSet (coerce v))
      unitFV v@(TyVar {}) = Const (unitUniqSet (coerce v),emptyUniqSet)

      interesting :: Var a -> Bool
      interesting v@(Id {}) = v `notElemVarEnv` globalBndrs && varUniq v /= varUniq var
      interesting _         = True

      (boundFTVsSet,boundFVsSet) =
        getConst (Lens.foldMapOf (termFreeVars' interesting) unitFV e)
      boundFTVs = eltsUniqSet boundFTVsSet
      boundFVs  = eltsUniqSet boundFVsSet

  -- Make a new global ID
  tcm       <- Lens.view tcCache
  let newBodyTy = termType tcm $ mkTyLams (mkLams e boundFVs) boundFTVs
  (cf,sp)   <- Lens.use curFun
  newBodyNm <- cloneName (appendToName (varName cf) ("_" `Text.append` nameOcc idName))
  let newBodyId = mkId newBodyTy newBodyNm {nameSort = Internal}

  -- Make a new expression, consisting of the the lifted function applied to
  -- its free variables
  let newExpr = mkTmApps
                  (mkTyApps (Var newBodyId)
                            (map VarTy boundFTVs))
                  (map Var boundFVs)
      inScope0 = mkInScopeSet (coerce boundFVsSet)
      inScope1 = extendInScopeSetList inScope0 [var,newBodyId]
  inScope2 <- unionInScope inScope1 <$> Lens.use globalInScope
  let subst    = extendIdSubst (mkSubst inScope2) var newExpr
      -- Substitute the recursive calls by the new expression
      e' = substTm "liftBinding" subst e
      -- Create a new body that abstracts over the free variables
      newBody = mkTyLams (mkLams e' boundFVs) boundFTVs

  -- Check if an alpha-equivalent global binder already exists
  aeqExisting <- (eltsUniqMap . filterUniqMap ((`aeqTerm` newBody) . (^. _4))) <$> Lens.use bindings
  case aeqExisting of
    -- If it doesn't, create a new binder
    [] -> do -- Add the created function to the list of global bindings
             globalInScope %= (`extendInScopeSet` newBodyId)
             bindings %= extendUniqMap newBodyNm
                                    -- We mark this function as internal so that
                                    -- it can be inlined at the very end of
                                    -- the normalisation pipeline as part of the
                                    -- flattening pass. We don't inline
                                    -- right away because we are lifting this
                                    -- function at this moment for a reason!
                                    -- (termination, CSE and DEC oppertunities,
                                    -- ,etc.)
                                    (newBodyId
                                    ,sp
#if MIN_VERSION_ghc(8,4,1)
                                    ,NoUserInline
#else
                                    ,EmptyInlineSpec
#endif
                                    ,newBody)
             -- Return the new binder
             return (var, newExpr)
    -- If it does, use the existing binder
    ((k,_,_,_):_) ->
      let newExpr' = mkTmApps
                      (mkTyApps (Var k)
                                (map VarTy boundFTVs))
                      (map Var boundFVs)
      in  return (var, newExpr')

liftBinding _ = error $ $(curLoc) ++ "liftBinding: invalid core, expr bound to tyvar"

-- | Make a global function for a name-term tuple
mkFunction
  :: TmName
  -- ^ Name of the function
  -> SrcSpan
  -> InlineSpec
  -> Term
  -- ^ Term bound to the function
  -> RewriteMonad extra Id
  -- ^ Name with a proper unique and the type of the function
mkFunction bndrNm sp inl body = do
  tcm    <- Lens.view tcCache
  let bodyTy = termType tcm body
  bodyNm <- cloneName bndrNm
  addGlobalBind bodyNm bodyTy sp inl body
  return (mkId bodyTy bodyNm)

-- | Add a function to the set of global binders
addGlobalBind
  :: TmName
  -> Type
  -> SrcSpan
  -> InlineSpec
  -> Term
  -> RewriteMonad extra ()
addGlobalBind vNm ty sp inl body = do
  let vId = mkId ty vNm
  globalInScope %= (`extendInScopeSet` vId)
  (ty,body) `deepseq` bindings %= extendUniqMap vNm (vId,sp,inl,body)

-- | Create a new name out of the given name, but with another unique
cloneName
  :: (Monad m, MonadUnique m)
  => Name a
  -> m (Name a)
cloneName nm = do
  i <- getUniqueM
  return nm {nameUniq = i}

-- | Test whether a term is a variable reference to a local binder
isNonGlobalVar :: Term
           -> RewriteMonad extra Bool
isNonGlobalVar (Var x) = notElemUniqMap (varName x) <$> Lens.use bindings
isNonGlobalVar _ = return False

{-# INLINE isUntranslatable #-}
-- | Determine if a term cannot be represented in hardware
isUntranslatable
  :: Bool
  -- ^ String representable
  -> Term
  -> RewriteMonad extra Bool
isUntranslatable stringRepresentable tm = do
  tcm <- Lens.view tcCache
  not <$> (representableType <$> Lens.view typeTranslator
                             <*> Lens.view customReprs
                             <*> pure stringRepresentable
                             <*> pure tcm
                             <*> pure (termType tcm tm))

{-# INLINE isUntranslatableType #-}
-- | Determine if a type cannot be represented in hardware
isUntranslatableType
  :: Bool
  -- ^ String representable
  -> Type
  -> RewriteMonad extra Bool
isUntranslatableType stringRepresentable ty =
  not <$> (representableType <$> Lens.view typeTranslator
                             <*> Lens.view customReprs
                             <*> pure stringRepresentable
                             <*> Lens.view tcCache
                             <*> pure ty)

-- | Is the Context a Lambda/Term-abstraction context?
isLambdaBodyCtx :: CoreContext
                -> Bool
isLambdaBodyCtx (LamBody _) = True
isLambdaBodyCtx _           = False

-- | Make a binder that should not be referenced
mkWildValBinder
  :: (Monad m, MonadUnique m)
  => InScopeSet
  -> Type
  -> m Id
mkWildValBinder is = mkInternalVar is "wild"

-- | Make a case-decomposition that extracts a field out of a (Sum-of-)Product type
mkSelectorCase
  :: HasCallStack
  => (Functor m, Monad m, MonadUnique m)
  => String -- ^ Name of the caller of this function
  -> InScopeSet
  -> TyConMap -- ^ TyCon cache
  -> Term -- ^ Subject of the case-composition
  -> Int -- n'th DataCon
  -> Int -- n'th field
  -> m Term
mkSelectorCase caller inScope tcm scrut dcI fieldI = go (termType tcm scrut)
  where
    go (coreView1 tcm -> Just ty') = go ty'
    go scrutTy@(tyView -> TyConApp tc args) =
      case tyConDataCons (lookupUniqMap' tcm tc) of
        [] -> cantCreate $(curLoc) ("TyCon has no DataCons: " ++ show tc ++ " " ++ showPpr tc) scrutTy
        dcs | dcI > length dcs -> cantCreate $(curLoc) "DC index exceeds max" scrutTy
            | otherwise -> do
          let dc = indexNote ($(curLoc) ++ "No DC with tag: " ++ show (dcI-1)) dcs (dcI-1)
          let (Just fieldTys) = dataConInstArgTysE inScope tcm dc args
          if fieldI >= length fieldTys
            then cantCreate $(curLoc) "Field index exceed max" scrutTy
            else do
              wildBndrs <- mapM (mkWildValBinder inScope) fieldTys
              let ty = indexNote ($(curLoc) ++ "No DC field#: " ++ show fieldI) fieldTys fieldI
              selBndr <- mkInternalVar inScope "sel" ty
              let bndrs  = take fieldI wildBndrs ++ [selBndr] ++ drop (fieldI+1) wildBndrs
                  pat    = DataPat dc (dcExtTyVars dc) bndrs
                  retVal = Case scrut ty [ (pat, Var selBndr) ]
              return retVal
    go scrutTy = cantCreate $(curLoc) ("Type of subject is not a datatype: " ++ showPpr scrutTy) scrutTy

    cantCreate loc info scrutTy = error $ loc ++ "Can't create selector " ++ show (caller,dcI,fieldI) ++ " for: (" ++ showPpr scrut ++ " :: " ++ showPpr scrutTy ++ ")\nAdditional info: " ++ info

-- | Specialise an application on its argument
specialise :: Lens' extra (Map.Map (Id, Int, Either Term Type) Id) -- ^ Lens into previous specialisations
           -> Lens' extra (VarEnv Int) -- ^ Lens into the specialisation history
           -> Lens' extra Int -- ^ Lens into the specialisation limit
           -> Rewrite extra
specialise specMapLbl specHistLbl specLimitLbl ctx e = case e of
  (TyApp e1 ty) -> specialise' specMapLbl specHistLbl specLimitLbl ctx e (collectArgs e1) (Right ty)
  (App e1 e2)   -> specialise' specMapLbl specHistLbl specLimitLbl ctx e (collectArgs e1) (Left  e2)
  _             -> return e

-- | Specialise an application on its argument
specialise' :: Lens' extra (Map.Map (Id, Int, Either Term Type) Id) -- ^ Lens into previous specialisations
            -> Lens' extra (VarEnv Int) -- ^ Lens into specialisation history
            -> Lens' extra Int -- ^ Lens into the specialisation limit
            -> TransformContext -- Transformation context
            -> Term -- ^ Original term
            -> (Term, [Either Term Type]) -- ^ Function part of the term, split into root and applied arguments
            -> Either Term Type -- ^ Argument to specialize on
            -> RewriteMonad extra Term
specialise' specMapLbl specHistLbl specLimitLbl (TransformContext is0 _) e (Var f, args) specArgIn = do
  lvl <- Lens.view dbgLevel

  -- Don't specialise TopEntities
  topEnts <- Lens.view topEntities
  if f `elemVarSet` topEnts
  then traceIf (lvl >= DebugNone) ("Not specialising TopEntity: " ++ showPpr (varName f)) (return e)
  else do -- NondecreasingIndentation

  tcm <- Lens.view tcCache

  let specArg = bimap (normalizeTermTypes tcm) (normalizeType tcm) specArgIn
  -- Create binders and variable references for free variables in 'specArg'
  -- (specBndrsIn,specVars) :: ([Either Id TyVar], [Either Term Type])
  (specBndrsIn,specVars) <- specArgBndrsAndVars specArg
  let argLen  = length args
      specBndrs :: [Either Id TyVar]
      specBndrs = map (Lens.over _Left (normalizeId tcm)) specBndrsIn
      specAbs :: Either Term Type
      specAbs = either (Left . (`mkAbstraction` specBndrs)) (Right . id) specArg
  -- Determine if 'f' has already been specialized on (a type-normalized) 'specArg'
  specM <- Map.lookup (f,argLen,specAbs) <$> Lens.use (extra.specMapLbl)
  case specM of
    -- Use previously specialized function
    Just f' ->
      traceIf (lvl >= DebugApplied)
        ("Using previous specialization of " ++ showPpr (varName f) ++ " on " ++
          (either showPpr showPpr) specAbs ++ ": " ++ showPpr (varName f')) $
        changed $ mkApps (Var f') (args ++ specVars)
    -- Create new specialized function
    Nothing -> do
      -- Determine if we can specialize f
      bodyMaybe <- fmap (lookupUniqMap (varName f)) $ Lens.use bindings
      case bodyMaybe of
        Just (_,sp,inl,bodyTm) -> do
          -- Determine if we see a sequence of specialisations on a growing argument
          specHistM <- lookupUniqMap f <$> Lens.use (extra.specHistLbl)
          specLim   <- Lens.use (extra . specLimitLbl)
          if maybe False (> specLim) specHistM
            then throw (ClashException
                        sp
                        (unlines [ "Hit specialisation limit " ++ show specLim ++ " on function `" ++ showPpr (varName f) ++ "'.\n"
                                 , "The function `" ++ showPpr f ++ "' is most likely recursive, and looks like it is being indefinitely specialized on a growing argument.\n"
                                 , "Body of `" ++ showPpr f ++ "':\n" ++ showPpr bodyTm ++ "\n"
                                 , "Argument (in position: " ++ show argLen ++ ") that triggered termination:\n" ++ (either showPpr showPpr) specArg
                                 , "Run with '-fclash-spec-limit=N' to increase the specialisation limit to N."
                                 ])
                        Nothing)
            else do
              let existingNames = collectBndrsMinusApps bodyTm
                  newNames      = [ mkUnsafeInternalName ("pTS" `Text.append` Text.pack (show n)) n
                                  | n <- [(0::Int)..]
                                  ]
              is1 <- unionInScope is0 <$> Lens.use globalInScope
              -- Make new binders for existing arguments
              (boundArgs,argVars) <- fmap (unzip . map (either (Left &&& Left . Var) (Right &&& Right . VarTy))) $
                                     Monad.zipWithM
                                       (mkBinderFor is1 tcm)
                                       (existingNames ++ newNames)
                                       args
              -- Determine name the resulting specialised function, and the
              -- form of the specialised-on argument
              (fId,inl',specArg') <- case specArg of
                Left a@(collectArgs -> (Var g,gArgs)) -> if isPolyFun tcm a
                    then do
                      -- In case we are specialising on an argument that is a
                      -- global function then we use that function's name as the
                      -- name of the specialised higher-order function.
                      -- Additionally, we will return the body of the global
                      -- function, instead of a variable reference to the
                      -- global function.
                      --
                      -- This will turn things like @mealy g k@ into a new
                      -- binding @g'@ where both the body of @mealy@ and @g@
                      -- are inlined, meaning the state-transition-function
                      -- and the memory element will be in a single function.
                      gTmM <- fmap (lookupUniqMap (varName g)) $ Lens.use bindings
                      return (g,maybe inl (^. _3) gTmM, maybe specArg (Left . (`mkApps` gArgs) . (^. _4)) gTmM)
                    else return (f,inl,specArg)
                _ -> return (f,inl,specArg)
              -- Create specialized functions
              let newBody = mkAbstraction (mkApps bodyTm (argVars ++ [specArg'])) (boundArgs ++ specBndrs)
              newf <- mkFunction (varName fId) sp inl' newBody
              -- Remember specialization
              (extra.specHistLbl) %= extendUniqMapWith f 1 (+)
              (extra.specMapLbl)  %= Map.insert (f,argLen,specAbs) newf
              -- use specialized function
              let newExpr = mkApps (Var newf) (args ++ specVars)
              newf `deepseq` changed newExpr
        Nothing -> return e
  where
    collectBndrsMinusApps :: Term -> [Name a]
    collectBndrsMinusApps = reverse . go []
      where
        go bs (Lam v e')    = go (coerce (varName v):bs)  e'
        go bs (TyLam tv e') = go (coerce (varName tv):bs) e'
        go bs (App e' _) = case go [] e' of
          []  -> bs
          bs' -> init bs' ++ bs
        go bs (TyApp e' _) = case go [] e' of
          []  -> bs
          bs' -> init bs' ++ bs
        go bs _ = bs

specialise' _ _ _ _ctx _ (appE,args) (Left specArg) = do
  -- Create binders and variable references for free variables in 'specArg'
  (specBndrs,specVars) <- specArgBndrsAndVars (Left specArg)
  -- Create specialized function
  let newBody = mkAbstraction specArg specBndrs
  -- See if there's an existing binder that's alpha-equivalent to the
  -- specialised function
  existing <- filterUniqMap ((`aeqTerm` newBody) . (^. _4)) <$> Lens.use bindings
  -- Create a new function if an alpha-equivalent binder doesn't exist
  newf <- case eltsUniqMap existing of
    [] -> do (cf,sp) <- Lens.use curFun
             mkFunction (appendToName (varName cf) "_specF")
                        sp
#if MIN_VERSION_ghc(8,4,1)
                        NoUserInline
#else
                        EmptyInlineSpec
#endif
                        newBody
    ((k,_,_,_):_) -> return k
  -- Create specialized argument
  let newArg  = Left $ mkApps (Var newf) specVars
  -- Use specialized argument
  let newExpr = mkApps appE (args ++ [newArg])
  changed newExpr

specialise' _ _ _ _ e _ _ = return e

normalizeTermTypes :: TyConMap -> Term -> Term
normalizeTermTypes tcm e = case e of
  Cast e' ty1 ty2 -> Cast (normalizeTermTypes tcm e') (normalizeType tcm ty1) (normalizeType tcm ty2)
  Var v -> Var (normalizeId tcm v)
  -- TODO other terms?
  _ -> e

normalizeId :: TyConMap -> Id -> Id
normalizeId tcm v@(Id {}) = v {varType = normalizeType tcm (varType v)}
normalizeId _   tyvar     = tyvar


-- | Create binders and variable references for free variables in 'specArg'
specArgBndrsAndVars
  :: Either Term Type
  -> RewriteMonad extra ([Either Id TyVar],[Either Term Type])
specArgBndrsAndVars specArg = do
  globalBndrs <- Lens.use bindings
  let unitFV :: Var a -> Const (UniqSet TyVar,UniqSet Id) (Var a)
      unitFV v@(Id {})
        | v `notElemVarEnv` globalBndrs
        = Const (emptyUniqSet,unitUniqSet (coerce v))
        | otherwise
        = mempty
      unitFV v@(TyVar {}) = Const (unitUniqSet (coerce v),emptyUniqSet)

      (specFTVs,specFVs) = case specArg of
        Left tm  -> (eltsUniqSet *** eltsUniqSet) . getConst $
                    Lens.foldMapOf (termFreeVars' (const True)) unitFV tm
        Right ty -> (eltsUniqSet (Lens.foldMapOf typeFreeVars unitUniqSet ty),[] :: [Id])

      specTyBndrs = map Right specFTVs
      specTmBndrs = map Left  specFVs

      specTyVars  = map (Right . VarTy) specFTVs
      specTmVars  = map (Left . Var) specFVs

  return (specTyBndrs ++ specTmBndrs,specTyVars ++ specTmVars)
