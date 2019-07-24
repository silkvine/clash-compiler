{-|
  Copyright   :  (C) 2012-2016, University of Twente,
                     2016     , Myrtle Software Ltd,
                     2017     , Google Inc.
  License     :  BSD2 (see the file LICENSE)
  Maintainer  :  Christiaan Baaij <christiaan.baaij@gmail.com>

  Turn CoreHW terms into normalized CoreHW Terms
-}

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE ViewPatterns      #-}

{-# OPTIONS_GHC -Wno-unused-imports #-}

module Clash.Normalize where

import Data.Either

import           Control.Concurrent.Supply        (Supply)
import           Control.Lens                     ((.=),(^.),_1,_4)
import qualified Control.Lens                     as Lens
import           Control.Monad.State.Strict       (State)
import           Data.Either                      (partitionEithers)
import qualified Data.IntMap                      as IntMap
import           Data.IntMap.Strict               (IntMap)
import           Data.List
  (groupBy, intersect, mapAccumL, sortBy)
import qualified Data.Map                         as Map
import qualified Data.Maybe                       as Maybe
import qualified Data.Set                         as Set
import qualified Data.Set.Lens                    as Lens
import           Data.Semigroup                   ((<>))
import           Data.Text.Prettyprint.Doc        (vcat)

import           BasicTypes                       (InlineSpec (..))
import           SrcLoc                           (SrcSpan,noSrcSpan)

import           Clash.Annotations.BitRepresentation.Internal
  (CustomReprs)
import           Clash.Core.Evaluator             (PrimEvaluator)
import           Clash.Core.FreeVars
  (freeLocalIds, globalIds, globalIdOccursIn, localIdDoesNotOccurIn)
import           Clash.Core.Pretty                (showPpr, ppr)
import           Clash.Core.Subst
  (deShadowTerm, extendGblSubstList, mkSubst, substTm)
import           Clash.Core.Term                  (Term (..), collectArgs)
import           Clash.Core.Type                  (Type, splitCoreFunForallTy)
import           Clash.Core.TyCon
  (TyConMap, TyConName)
import           Clash.Core.Util                  (mkApps, termType)
import           Clash.Core.Var                   (Id, varName, varType)
import           Clash.Core.VarEnv
  (VarEnv, elemVarSet, eltsVarEnv, emptyInScopeSet, emptyVarEnv,
   extendVarEnv, lookupVarEnv, mapVarEnv, mapMaybeVarEnv, mkInScopeSet,
   mkVarEnv, mkVarSet, notElemVarEnv, notElemVarSet, nullVarEnv, unionVarEnv)
import           Clash.Driver.Types
  (BindingMap, ClashOpts (..), DebugLevel (..))
import           Clash.Netlist.Types
  (HWType (..), HWMap, FilteredHWType(..))
import           Clash.Netlist.Util
  (splitNormalized, coreTypeToHWType')
import           Clash.Normalize.Strategy
import           Clash.Normalize.Transformations
  (appProp, bindConstantVar, caseCon, flattenLet, reduceConst, topLet,
   reduceNonRepPrim, removeUnusedExpr)
import           Clash.Normalize.Types
import           Clash.Normalize.Util
import           Clash.Primitives.Types           (CompiledPrimMap)
import           Clash.Rewrite.Combinators        ((>->),(!->))
import           Clash.Rewrite.Types
  (RewriteEnv (..), RewriteState (..), bindings, curFun, dbgLevel, extra,
   tcCache, topEntities, typeTranslator, customReprs)
import           Clash.Rewrite.Util
  (apply, isUntranslatableType, runRewrite, runRewriteSession)
import           Clash.Signal.Internal            (ResetKind (..))
import           Clash.Util

-- | Run a NormalizeSession in a given environment
runNormalization
  :: ClashOpts
  -- ^ Level of debug messages to print
  -> Supply
  -- ^ UniqueSupply
  -> BindingMap
  -- ^ Global Binders
  -> (CustomReprs -> TyConMap -> Type ->
      State HWMap (Maybe (Either String FilteredHWType)))
  -- ^ Hardcoded Type -> HWType translator
  -> CustomReprs
  -> TyConMap
  -- ^ TyCon cache
  -> IntMap TyConName
  -- ^ Tuple TyCon cache
  -> PrimEvaluator
  -- ^ Hardcoded evaluator (delta-reduction)
  -> CompiledPrimMap
  -- ^ Primitive Definitions
  -> VarEnv Bool
  -- ^ Map telling whether a components is part of a recursive group
  -> [Id]
  -- ^ topEntities
  -> NormalizeSession a
  -- ^ NormalizeSession to run
  -> a
runNormalization opts supply globals typeTrans reprs tcm tupTcm eval primMap rcsMap topEnts
  = runRewriteSession rwEnv rwState
  where
    rwEnv     = RewriteEnv
                  (opt_dbgLevel opts)
                  typeTrans
                  tcm
                  tupTcm
                  eval
                  (mkVarSet topEnts)
                  reprs

    rwState   = RewriteState
                  0
                  globals
                  supply
                  (error $ $(curLoc) ++ "Report as bug: no curFun",noSrcSpan)
                  0
                  (IntMap.empty, 0)
                  normState

    normState = NormalizeState
                  emptyVarEnv
                  Map.empty
                  emptyVarEnv
                  (opt_specLimit opts)
                  emptyVarEnv
                  (opt_inlineLimit opts)
                  (opt_inlineFunctionLimit opts)
                  (opt_inlineConstantLimit opts)
                  primMap
                  Map.empty
                  rcsMap
                  (opt_newInlineStrat opts)
                  (opt_ultra opts)


normalize
  :: [Id]
  -> NormalizeSession BindingMap
normalize []  = return emptyVarEnv
normalize top = do
  (new,topNormalized) <- unzip <$> mapM normalize' top
  newNormalized <- normalize (concat new)
  return (unionVarEnv (mkVarEnv topNormalized) newNormalized)

normalize'
  :: Id
  -> NormalizeSession ([Id],(Id,(Id,SrcSpan,InlineSpec,Term)))
normalize' nm = do
  exprM <- lookupVarEnv nm <$> Lens.use bindings
  let nmS = showPpr (varName nm)
  case exprM of
    Just (nm',sp,inl,tm) -> do
      tcm <- Lens.view tcCache
      let (_,resTy) = splitCoreFunForallTy tcm (varType nm')
      resTyRep <- not <$> isUntranslatableType False resTy
      if resTyRep
         then do
            tmNorm <- normalizeTopLvlBndr nm (nm',sp,inl,tm)
            let usedBndrs = Lens.toListOf globalIds (tmNorm ^. _4)
            traceIf (nm `elem` usedBndrs)
                    (concat [ $(curLoc),"Expr belonging to bndr: ",nmS ," (:: "
                            , showPpr (varType (tmNorm ^. _1))
                            , ") remains recursive after normalization:\n"
                            , showPpr (tmNorm ^. _4) ])
                    (return ())
            prevNorm <- mapVarEnv (Lens.view _1) <$> Lens.use (extra.normalized)
            topEnts  <- Lens.view topEntities
            let toNormalize = filter (`notElemVarSet` topEnts)
                            $ filter (`notElemVarEnv` (extendVarEnv nm nm prevNorm)) usedBndrs
            return (toNormalize,(nm,tmNorm))
         else do
            let usedBndrs = Lens.toListOf globalIds tm
            prevNorm <- mapVarEnv (Lens.view _1) <$> Lens.use (extra.normalized)
            topEnts  <- Lens.view topEntities
            let toNormalize = filter (`notElemVarSet` topEnts)
                            $ filter (`notElemVarEnv` (extendVarEnv nm nm prevNorm)) usedBndrs
            lvl <- Lens.view dbgLevel
            traceIf (lvl >= DebugFinal)
                    (concat [$(curLoc), "Expr belonging to bndr: ", nmS, " (:: "
                            , showPpr (varType nm')
                            , ") has a non-representable return type."
                            , " Not normalising:\n", showPpr tm] )
                    (return (toNormalize,(nm,(nm',sp,inl,tm))))
    Nothing -> error $ $(curLoc) ++ "Expr belonging to bndr: " ++ nmS ++ " not found"

-- | Check whether the normalized bindings are non-recursive. Errors when one
-- of the components is recursive.
checkNonRecursive
  :: BindingMap
  -- ^ List of normalized binders
  -> BindingMap
checkNonRecursive norm = case mapMaybeVarEnv go norm of
  rcs | nullVarEnv rcs  -> norm
  rcs -> error $ $(curLoc) ++ "Callgraph after normalisation contains following recursive components: "
                   ++ show (vcat [ ppr a <> ppr b
                                 | (a,b) <- eltsVarEnv rcs
                                 ])
 where
  go (nm,_,_,tm) =
    if nm `globalIdOccursIn` tm
       then Just (nm,tm)
       else Nothing


-- | Perform general \"clean up\" of the normalized (non-recursive) function
-- hierarchy. This includes:
--
--   * Inlining functions that simply \"wrap\" another function
cleanupGraph
  :: Id
  -> BindingMap
  -> NormalizeSession BindingMap
cleanupGraph topEntity norm
  | Just ct <- mkCallTree [] norm topEntity
  = do ctFlat <- flattenCallTree ct
       return (mkVarEnv $ snd $ callTreeToList [] ctFlat)
cleanupGraph _ norm = return norm

data CallTree = CLeaf   (Id,(Id,SrcSpan,InlineSpec,Term))
              | CBranch (Id,(Id,SrcSpan,InlineSpec,Term)) [CallTree]

mkCallTree
  :: [Id]
  -- ^ Visited
  -> BindingMap
  -- ^ Global binders
  -> Id
  -- ^ Root of the call graph
  -> Maybe CallTree
mkCallTree visited bindingMap root
  | Just rootTm <- lookupVarEnv root bindingMap
  = let used   = Set.toList $ Lens.setOf globalIds $ (rootTm ^. _4)
        other  = Maybe.mapMaybe (mkCallTree (root:visited) bindingMap) (filter (`notElem` visited) used)
    in  case used of
          [] -> Just (CLeaf   (root,rootTm))
          _  -> Just (CBranch (root,rootTm) other)
mkCallTree _ _ _ = Nothing

stripArgs
  :: [Id]
  -> [Id]
  -> [Either Term Type]
  -> Maybe [Either Term Type]
stripArgs _      (_:_) []   = Nothing
stripArgs allIds []    args = if any mentionsId args
                                then Nothing
                                else Just args
  where
    mentionsId t = not $ null (either (Lens.toListOf freeLocalIds) (const []) t
                              `intersect`
                              allIds)

stripArgs allIds (id_:ids) (Left (Var nm):args)
      | id_ == nm = stripArgs allIds ids args
      | otherwise = Nothing
stripArgs _ _ _ = Nothing

flattenNode
  :: CallTree
  -> NormalizeSession (Either CallTree ((Id,Term),[CallTree]))
flattenNode c@(CLeaf (_,(_,_,NoInline,_))) = return (Left c)
flattenNode c@(CLeaf (nm,(_,_,_,e))) = do
  isTopEntity <- elemVarSet nm <$> Lens.view topEntities
  if isTopEntity then return (Left c) else do
    tcm  <- Lens.view tcCache
    let norm = splitNormalized tcm e
    case norm of
      Right (ids,[(bId,bExpr)],_) -> do
        let (fun,args) = collectArgs bExpr
        case stripArgs ids (reverse ids) (reverse args) of
          Just remainder | bId `localIdDoesNotOccurIn` bExpr ->
               return (Right ((nm,mkApps fun (reverse remainder)),[]))
          _ -> return (Right ((nm,e),[]))
      _ -> return (Right ((nm,e),[]))
flattenNode b@(CBranch (_,(_,_,NoInline,_)) _) =
  return (Left b)
flattenNode b@(CBranch (nm,(_,_,_,e)) us) = do
  isTopEntity <- elemVarSet nm <$> Lens.view topEntities
  if isTopEntity then return (Left b) else do
    tcm  <- Lens.view tcCache
    let norm = splitNormalized tcm e
    case norm of
      Right (ids,[(bId,bExpr)],_) -> do
        let (fun,args) = collectArgs bExpr
        case stripArgs ids (reverse ids) (reverse args) of
          Just remainder | bId `localIdDoesNotOccurIn` bExpr ->
               return (Right ((nm,mkApps fun (reverse remainder)),us))
          _ -> return (Right ((nm,e),us))
      _ -> do
        newInlineStrat <- Lens.use (extra.newInlineStrategy)
        if newInlineStrat || isCheapFunction e
           then return (Right ((nm,e),us))
           else return (Left b)

flattenCallTree
  :: CallTree
  -> NormalizeSession CallTree
flattenCallTree c@(CLeaf _) = return c
flattenCallTree (CBranch (nm,(nm',sp,inl,tm)) used) = do
  flattenedUsed   <- mapM flattenCallTree used
  (newUsed,il_ct) <- partitionEithers <$> mapM flattenNode flattenedUsed
  let (toInline,il_used) = unzip il_ct
      subst = extendGblSubstList (mkSubst emptyInScopeSet) toInline
  newExpr <- case toInline of
               [] -> return tm
               _  -> do -- To have a cheap `appProp` transformation we need to
                        -- deshadow, see also Note [AppProp no-shadow invariant]
                        let tm1 = deShadowTerm emptyInScopeSet (substTm "flattenCallTree.flattenExpr" subst tm)
                        rewriteExpr ("flattenExpr",flatten) (showPpr nm, tm1) (nm', sp)
  let allUsed = newUsed ++ concat il_used
  -- inline all components when the resulting expression after flattening
  -- is still considered "cheap". This happens often at the topEntity which
  -- wraps another functions and has some selectors and data-constructors.
  if inl /= NoInline && isCheapFunction newExpr
     then do
        let (toInline',allUsed') = unzip (map goCheap allUsed)
            subst' = extendGblSubstList (mkSubst emptyInScopeSet) toInline'
        -- To have a cheap `appProp` transformation we need to
        -- deshadow, see also Note [AppProp no-shadow invariant]
        let tm1 = deShadowTerm emptyInScopeSet (substTm "flattenCallTree.flattenCheap" subst' newExpr)
        newExpr' <- rewriteExpr ("flattenCheap",flatten) (showPpr nm, tm1) (nm', sp)
        return (CBranch (nm,(nm',sp,inl,newExpr')) (concat allUsed'))
     else return (CBranch (nm,(nm',sp,inl,newExpr)) allUsed)
  where
    flatten =
      innerMost (apply "appProp" appProp >->
                 apply "bindConstantVar" bindConstantVar >->
                 apply "caseCon" caseCon >->
                 apply "reduceConst" reduceConst >->
                 apply "reduceNonRepPrim" reduceNonRepPrim >->
                 apply "removeUnusedExpr" removeUnusedExpr >->
                 apply "flattenLet" flattenLet) !->
      topdownSucR (apply "topLet" topLet)

    goCheap (CLeaf   (nm2,(_,_,_,e)))    = ((nm2,e),[])
    goCheap (CBranch (nm2,(_,_,_,e)) us) = ((nm2,e),us)

callTreeToList
  :: [Id]
  -> CallTree
  -> ([Id],[(Id,(Id,SrcSpan,InlineSpec,Term))])
callTreeToList visited (CLeaf (nm,bndr))
  | nm `elem` visited = (visited,[])
  | otherwise         = (nm:visited,[(nm,bndr)])
callTreeToList visited (CBranch (nm,bndr) used)
  | nm `elem` visited = (visited,[])
  | otherwise         = (visited',(nm,bndr):(concat others))
  where
    (visited',others) = mapAccumL callTreeToList (nm:visited) used
