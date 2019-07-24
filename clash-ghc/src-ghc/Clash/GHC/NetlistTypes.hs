{-|
  Copyright   :  (C) 2013-2016, University of Twente,
                     2016-2017, Myrtle Software Ltd
  License     :  BSD2 (see the file LICENSE)
  Maintainer  :  Christiaan Baaij <christiaan.baaij@gmail.com>
-}

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE ViewPatterns      #-}

module Clash.GHC.NetlistTypes
  (ghcTypeToHWType)
where

import Data.Coerce                      (coerce)
import Data.Functor.Identity            (Identity (..))
import Data.Text                        (pack)
import Control.Monad.State.Strict       (State)
import Control.Monad.Trans.Except
  (Except, ExceptT (..), mapExceptT, runExceptT, throwE)
import Control.Monad.Trans.Maybe        (MaybeT (..))
import Language.Haskell.TH.Syntax       (showName)

import Clash.Core.DataCon               (DataCon (..))
import Clash.Core.Name                  (Name (..))
import Clash.Core.Pretty                (showPpr)
import Clash.Core.TyCon                 (TyConMap, tyConDataCons)
import Clash.Core.Type
  (LitTy (..), Type (..), TypeView (..), coreView, tyView)
import Clash.Core.Util                  (tyNatSize, substArgTys)
import Clash.Netlist.Util               (coreTypeToHWType, stripFiltered)
import Clash.Netlist.Types
  (HWType(..), HWMap, FilteredHWType(..), PortDirection (..))
import Clash.Signal.Internal
  (ResetPolarity(..), ActiveEdge(..), ResetKind(..)
  ,InitBehavior(..))
import Clash.Unique                     (lookupUniqMap')
import Clash.Util                       (curLoc)

import Clash.Annotations.BitRepresentation.Internal
  (CustomReprs)

ghcTypeToHWType
  :: Int
  -- ^ Integer width. The width Clash assumes an Integer to be (instead of it
  -- begin an arbitrarily large, runtime sized construct).
  -> Bool
  -- ^ Float support
  -> CustomReprs
  -- ^ Custom bit representations
  -> TyConMap
  -- ^ Type constructor map
  -> Type
  -- ^ Type to convert to HWType
  -> State HWMap (Maybe (Either String FilteredHWType))
ghcTypeToHWType iw floatSupport = go
  where
    -- returnN :: HWType ->
    returnN t = return (FilteredHWType t [])

    go :: CustomReprs -> TyConMap -> Type -> State HWMap (Maybe (Either String FilteredHWType))
    go reprs m (AnnType attrs typ) = fmap Just . runExceptT $ do
      FilteredHWType typ' areVoids <- ExceptT $ coreTypeToHWType go reprs m typ
      return (FilteredHWType (Annotated attrs typ') areVoids)

    go reprs m ty@(tyView -> TyConApp tc args) = runMaybeT . runExceptT $
      case nameOcc tc of
        "GHC.Int.Int8"                  -> returnN (Signed 8)
        "GHC.Int.Int16"                 -> returnN (Signed 16)
        "GHC.Int.Int32"                 -> returnN (Signed 32)
        "GHC.Int.Int64"                 ->
          if iw < 64
             then case tyConDataCons (m `lookupUniqMap'` tc) of
                    [dc] -> case dcArgTys dc of
                      [tyView -> TyConApp nm _]
                        | nameOcc nm == "GHC.Prim.Int#"   ->
                            throwE $ unlines ["Int64 not supported in forced 32-bit mode on a 64-bit machine."
                                             ,"Run Clash with `-fclash-intwidth=64`."
                                             ]
                        | nameOcc nm == "GHC.Prim.Int64#" ->
                            returnN (Signed 64)
                      _  -> throwE $ $(curLoc) ++ "Int64 DC has unexpected amount of arguments"
                    _    -> throwE $ $(curLoc) ++ "Int64 TC has unexpected amount of DCs"
             else returnN (Signed 64)
        "GHC.Word.Word8"                -> returnN (Unsigned 8)
        "GHC.Word.Word16"               -> returnN (Unsigned 16)
        "GHC.Word.Word32"               -> returnN (Unsigned 32)
        "GHC.Word.Word64"               ->
          if iw < 64
             then case tyConDataCons (m `lookupUniqMap'` tc) of
                    [dc] -> case dcArgTys dc of
                      [tyView -> TyConApp nm _]
                        | nameOcc nm == "GHC.Prim.Word#"   ->
                            throwE $ unlines ["Word64 not supported in forced 32-bit mode on a 64-bit machine."
                                             ,"Run Clash with `-fclash-intwidth=64`."
                                             ]
                        | nameOcc nm == "GHC.Prim.Word64#" ->
                            returnN (Unsigned 64)
                      _  -> throwE $ $(curLoc) ++ "Word64 DC has unexpected amount of arguments"
                    _    -> throwE $ $(curLoc) ++ "Word64 TC has unexpected amount of DCs"
             else returnN (Unsigned 64)
        "GHC.Integer.Type.Integer"      -> returnN (Signed iw)
        "GHC.Natural.Natural"           -> returnN (Unsigned iw)
        "GHC.Prim.Char#"                -> returnN (Unsigned 21)
        "GHC.Prim.Int#"                 -> returnN (Signed iw)
        "GHC.Prim.Word#"                -> returnN (Unsigned iw)
        "GHC.Prim.Int64#"               -> returnN (Signed 64)
        "GHC.Prim.Word64#"              -> returnN (Unsigned 64)
        "GHC.Prim.Float#" | floatSupport -> returnN (BitVector 32)
        "GHC.Prim.Double#" | floatSupport -> returnN (BitVector 64)
        "GHC.Prim.ByteArray#"           ->
          throwE $ "Can't translate type: " ++ showPpr ty

        "GHC.Types.Bool"                -> returnN Bool
        "GHC.Types.Float" | floatSupport-> returnN (BitVector 32)
        "GHC.Types.Double" | floatSupport -> returnN (BitVector 64)
        "GHC.Prim.~#"                   -> returnN (Void Nothing)

        "GHC.Prim.Any" -> returnN (Void Nothing)

        "Clash.Signal.Internal.Signal" ->
          ExceptT $ MaybeT $ Just <$> coreTypeToHWType go reprs m (args !! 1)

        "Clash.Signal.BiSignal.BiSignalIn" -> do
          let [_, _, szTy] = args
          let fType ty1 = FilteredHWType ty1 []
          (fType . BiDirectional In . BitVector . fromInteger) <$>
            liftE (tyNatSize m szTy)

        "Clash.Signal.BiSignal.BiSignalOut" -> do
          let [_, _, szTy] = args
          let fType ty1 = FilteredHWType ty1 []
          (fType . Void . Just . BiDirectional Out . BitVector . fromInteger) <$>
            liftE (tyNatSize m szTy)

        -- XXX: this is a hack to get a KnownDomain from a KnownConfiguration
        "GHC.Classes.(%,%)"
          | [arg0@(tyView -> TyConApp kdNm _), _] <- args
          , nameOcc kdNm == "Clash.Signal.Internal.KnownDomain"
          -> ExceptT (MaybeT (go reprs m arg0))

        "Clash.Signal.Internal.KnownDomain"
          -> case tyConDataCons (m `lookupUniqMap'` tc) of
               [dc] -> case substArgTys dc args of
                 [_,tyView -> TyConApp _ [_,dom]] -> case tyView (coreView m dom) of
                   TyConApp _ [tag0, period0, edge0, rstKind0, init0, polarity0] -> do
                     tag1      <- domTag tag0
                     period1   <- domPeriod period0
                     edge1     <- domEdge m edge0
                     rstKind1  <- domResetKind m rstKind0
                     init1     <- domInitBehavior m init0
                     polarity1 <- domResetPolarity m polarity0
                     let kd = KnownDomain (pack tag1) period1 edge1 rstKind1 init1 polarity1
                     returnN (Void (Just kd))
                   _ -> ExceptT (MaybeT (pure Nothing))
                 _ -> ExceptT (MaybeT (pure Nothing))
               _ -> ExceptT (MaybeT (pure Nothing))

        "Clash.Signal.Internal.Clock"
          | [tag0] <- args
          -> do
            tag1 <- domTag tag0
            returnN (Clock (pack tag1))

        "Clash.Signal.Internal.Reset"
          | [tag0] <- args
          -> do
            tag1 <- domTag tag0
            returnN (Reset (pack tag1))

        "Clash.Sized.Internal.BitVector.Bit" -> returnN Bit

        "Clash.Sized.Internal.BitVector.BitVector" -> do
          n <- liftE (tyNatSize m (head args))
          case n of
            0 -> returnN (Void (Just (BitVector (fromInteger n))))
            _ -> returnN (BitVector (fromInteger n))

        "Clash.Sized.Internal.Index.Index" -> do
          n <- liftE (tyNatSize m (head args))
          if n < 2
             then returnN (Void (Just (Index (fromInteger n))))
             else returnN (Index (fromInteger n))

        "Clash.Sized.Internal.Signed.Signed" -> do
          n <- liftE (tyNatSize m (head args))
          if n == 0
             then returnN (Void (Just (Signed (fromInteger n))))
             else returnN (Signed (fromInteger n))

        "Clash.Sized.Internal.Unsigned.Unsigned" -> do
          n <- liftE (tyNatSize m (head args))
          if n == 0
             then returnN (Void (Just (Unsigned (fromInteger n))))
             else returnN (Unsigned (fromInteger n))

        "Clash.Sized.Vector.Vec" -> do
          let [szTy,elTy] = args
          sz0     <- liftE (tyNatSize m szTy)
          fElHWTy <- ExceptT $ MaybeT $ Just <$> coreTypeToHWType go reprs m elTy

          -- Treat Vec as a product type with a single constructor and N
          -- constructor fields.
          let sz1    = fromInteger sz0 :: Int
              elHWTy = stripFiltered fElHWTy

          let
            (isVoid, vecHWTy) =
              case elHWTy of
                Void {}      -> (True, Void (Just (Vector sz1 elHWTy)))
                _ | sz1 == 0 -> (True, Void (Just (Vector sz1 elHWTy)))
                _            -> (False, Vector sz1 elHWTy)

          let filtered = [replicate sz1 (isVoid, fElHWTy)]
          return (FilteredHWType vecHWTy filtered)

        "Clash.Sized.RTree.RTree" -> do
          let [szTy,elTy] = args
          sz0     <- liftE (tyNatSize m szTy)
          fElHWTy <- ExceptT $ MaybeT $ Just <$> coreTypeToHWType go reprs m elTy

          -- Treat RTree as a product type with a single constructor and 2^N
          -- constructor fields.
          let sz1    = fromInteger sz0 :: Int
              elHWTy = stripFiltered fElHWTy

          let
            (isVoid, vecHWTy) =
              case elHWTy of
                Void {} -> (True, Void (Just (RTree sz1 elHWTy)))
                _       -> (False, RTree sz1 elHWTy)

          let filtered = [replicate (2^sz1) (isVoid, fElHWTy)]
          return (FilteredHWType vecHWTy filtered)

        "String" -> returnN String
        "GHC.Types.[]" -> case tyView (head args) of
          (TyConApp (nameOcc -> "GHC.Types.Char") []) -> returnN String
          _ -> throwE $ "Can't translate type: " ++ showPpr ty

        _ -> ExceptT (MaybeT (pure Nothing))

    go _ _ _ = pure Nothing

liftE
  :: Applicative m
  => Except e a
  -> ExceptT e (MaybeT m) a
liftE = mapExceptT (MaybeT . pure . Just . coerce)

domTag :: Monad m => Type -> ExceptT String (MaybeT m) String
domTag (LitTy (SymTy tag)) = pure tag
domTag ty = throwE $ "Can't translate domain tag" ++ showPpr ty

domPeriod :: Monad m => Type -> ExceptT String (MaybeT m) Integer
domPeriod (LitTy (NumTy period)) = pure period
domPeriod ty = throwE $ "Can't translate domain period" ++ showPpr ty

fromType
  :: Monad m
  => String
  -- ^ Name of type (for error reporting)
  -> [(String, a)]
  -- ^ [(Fully qualified constructor name, constructor value)
  -> TyConMap
  -- ^ Constructor map (used to look through newtypes)
  -> Type
  -- ^ Type representing some constructor
  -> ExceptT String (MaybeT m) a
fromType tyNm constrs m ty =
  case tyView (coreView m ty) of
    TyConApp tcNm [] ->
      go constrs (nameOcc tcNm)
    _ ->
      throwE $ "Can't translate " ++ tyNm ++ showPpr ty
 where
  go ((cName,c):cs) tcNm =
    if pack cName == tcNm then
      pure c
    else
      go cs tcNm
  go [] _ =
    throwE $ "Can't translate " ++ tyNm ++ showPpr ty

domEdge
  :: Monad m
  => TyConMap
  -> Type
  -> ExceptT String (MaybeT m) ActiveEdge
domEdge =
  fromType
    (showName ''ActiveEdge)
    [ (showName 'Rising, Rising)
    , (showName 'Falling, Falling) ]

domResetKind
  :: Monad m
  => TyConMap
  -> Type
  -> ExceptT String (MaybeT m) ResetKind
domResetKind =
  fromType
    (showName ''ResetKind)
    [ (showName 'Synchronous, Synchronous)
    , (showName 'Asynchronous, Asynchronous) ]

domInitBehavior
  :: Monad m
  => TyConMap
  -> Type
  -> ExceptT String (MaybeT m) InitBehavior
domInitBehavior =
  fromType
    (showName ''InitBehavior)
    [ (showName 'Defined, Defined)
    , (showName 'Unknown, Unknown) ]

domResetPolarity
  :: Monad m
  => TyConMap
  -> Type
  -> ExceptT String (MaybeT m) ResetPolarity
domResetPolarity =
  fromType
    (showName ''ResetPolarity)
    [ (showName 'ActiveHigh, ActiveHigh)
    , (showName 'ActiveLow, ActiveLow) ]
