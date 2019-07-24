{-|
  Copyright  :  (C) 2012-2016, University of Twente,
                    2016-2017, Myrtle Software Ltd
                    2018     , Google Inc.
  License    :  BSD2 (see the file LICENSE)
  Maintainer :  Christiaan Baaij <christiaan.baaij@gmail.com>

  Type and instance definitions for Primitive
-}

{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveFunctor     #-}
{-# LANGUAGE DeriveFoldable    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns      #-}

module Clash.Primitives.Types
  ( TemplateSource(..)
  , TemplateKind(..)
  , TemplateFormat(..)
  , BlackBoxFunctionName(..)
  , Primitive(..)
  , GuardedCompiledPrimitive
  , GuardedResolvedPrimitive
  , PrimMap
  , UnresolvedPrimitive
  , ResolvedPrimitive
  , ResolvedPrimMap
  , CompiledPrimitive
  , CompiledPrimMap
  ) where

import {-# SOURCE #-} Clash.Netlist.Types
import           Clash.Annotations.Primitive  (PrimitiveGuard)
import           Clash.Core.Term (WorkInfo (..))
import           Clash.Netlist.BlackBox.Types
  (BlackBoxFunction, BlackBoxTemplate, TemplateKind (..))
import           Control.Applicative          ((<|>))
import           Control.DeepSeq              (NFData)
import           Data.Aeson
  (FromJSON (..), Value (..), (.:), (.:?), (.!=))
import           Data.Binary                  (Binary)
import           Data.Char                    (isUpper, isLower, isAlphaNum)
import           Data.Either                  (lefts)
import           Data.Hashable                (Hashable)
import qualified Data.HashMap.Strict          as H
import           Data.List                    (intercalate)
import qualified Data.Text                    as S
import           Data.Text.Lazy               (Text)
import           GHC.Generics                 (Generic)
import           GHC.Stack                    (HasCallStack)

-- | An unresolved primitive still contains pointers to files.
type UnresolvedPrimitive = Primitive Text ((TemplateFormat,BlackBoxFunctionName),Maybe TemplateSource) (Maybe S.Text) (Maybe TemplateSource)

-- | A parsed primitive does not contain pointers to filesystem files anymore,
-- but holds uncompiled @BlackBoxTemplate@s and @BlackBoxFunction@s.
type ResolvedPrimitive        = Primitive Text ((TemplateFormat,BlackBoxFunctionName),Maybe Text) () (Maybe Text)
type GuardedResolvedPrimitive = PrimitiveGuard ResolvedPrimitive
type ResolvedPrimMap          = PrimMap GuardedResolvedPrimitive

-- | A compiled primitive has compiled all templates and functions from its
-- @ResolvedPrimitive@ counterpart. The Int in the tuple is a hash of the
-- (uncompiled) BlackBoxFunction.
type CompiledPrimitive        = Primitive BlackBoxTemplate BlackBox () (Int, BlackBoxFunction)
type GuardedCompiledPrimitive = PrimitiveGuard CompiledPrimitive
type CompiledPrimMap          = PrimMap GuardedCompiledPrimitive

-- | A @PrimMap@ maps primitive names to a @Primitive@
type PrimMap a = H.HashMap S.Text a

-- | A BBFN is a parsed version of a fully qualified function name. It is
-- guaranteed to have at least one module name which is not /Main/.
data BlackBoxFunctionName =
  BlackBoxFunctionName [String] String
    deriving (Eq, Generic, NFData, Binary, Hashable)

instance Show BlackBoxFunctionName where
  show (BlackBoxFunctionName mods funcName) =
    "BBFN<" ++ intercalate "." mods ++ "." ++ funcName ++ ">"

-- | Quick and dirty implementation of Text.splitOn for Strings
splitOn :: String -> String -> [String]
splitOn (S.pack -> sep) (S.pack -> str) =
  map S.unpack $ S.splitOn sep str

-- | Parses a string into a list of modules and a function name. I.e., it parses
-- the string "Clash.Primitives.Types.parseBBFN" to ["Clash", "Primitives",
-- "Types"] and "parseBBFN". The result is stored as a BlackBoxFunctionName.
parseBBFN
  :: HasCallStack
  => String
  -> Either String BlackBoxFunctionName
parseBBFN bbfn =
  case splitOn "." bbfn of
    []  -> Left $ "Empty function name: " ++ bbfn
    [_] -> Left $ "No module or function defined: " ++ bbfn
    nms ->
      let (mods, func) = (init nms, last nms) in
      let errs = lefts $ checkFunc func : map checkMod mods in
      case errs of
        [] -> Right $ BlackBoxFunctionName mods func
        _  -> Left $ "Error while parsing " ++ show bbfn ++ ": " ++ head errs
  where
    checkMod mod'
      | isLower (head mod') =
          Left $ "Module name cannot start with lowercase: " ++ mod'
      | any (not . isAlphaNum) mod' =
          Left $ "Module name must be alphanumerical: " ++ mod'
      | otherwise =
          Right mod'

    checkFunc func
      | isUpper (head func) =
          Left $ "Function name must start with lowercase: " ++ func
      | otherwise =
          Right func

data TemplateSource
  = TFile FilePath
  -- ^ Template source stored in file on filesystem
  | TInline Text
  -- ^ Template stored inline
  deriving (Show, Eq)


data TemplateFormat
  = TTemplate
  | THaskell
  deriving (Show, Generic, Hashable, NFData)

-- | Externally defined primitive
data Primitive a b c d
  -- | Primitive template written in a Clash specific templating language
  = BlackBox
  { name      :: !S.Text
    -- ^ Name of the primitive
  , workInfo  :: WorkInfo
    -- ^ Whether the primitive does any work, i.e. takes chip area
  , kind      :: TemplateKind
    -- ^ Whether this results in an expression or a declaration
  , warning  :: c
    -- ^ A warning to be outputted when the primitive is instantiated.
    -- This is intended to be used as a warning for primitives that are not
    -- synthesizable, but may also be used for other purposes.
  , outputReg :: Bool
    -- ^ Verilog only: whether the result should be a /reg/(@True@) or /wire/
    -- (@False@); when not specified in the /.json/ file, the value will default
    -- to @False@ (i.e. /wire/).
  , libraries :: [a]
    -- ^ VHDL only: add /library/ declarations for the given names
  , imports   :: [a]
    -- ^ VHDL only: add /use/ declarations for the given names
  , includes  :: [((S.Text,S.Text),b)]
    -- ^ Create files to be included with the generated primitive. The fields
    -- are ((name, extension), content), where content is a template of the file
    -- Defaults to @[]@ when not specified in the /.json/ file
  , template :: b
    -- ^ Used to indiciate type of template (declaration or expression). Will be
    -- filled with @Template@ or an @Either decl expr@.
  }
  -- | Primitive template rendered by a Haskell function (given as raw source code)
  | BlackBoxHaskell
  { name :: !S.Text
    -- ^ Name of the primitive
  , workInfo  :: WorkInfo
    -- ^ Whether the primitive does any work, i.e. takes chip area
  , functionName :: BlackBoxFunctionName
  , function :: d
    -- ^ Used to indicate type of template (declaration or expression).
  }
  -- | A primitive that carries additional information. These are "real"
  -- primitives, hardcoded in the compiler. For example: 'mapSignal' in
  -- @GHC2Core.coreToTerm@.
  | Primitive
  { name     :: !S.Text
    -- ^ Name of the primitive
  , workInfo  :: WorkInfo
    -- ^ Whether the primitive does any work, i.e. takes chip area
  , primSort :: !Text
    -- ^ Additional information
  }
  deriving (Show, Generic, NFData, Binary, Hashable, Functor)

instance FromJSON UnresolvedPrimitive where
  parseJSON (Object v) =
    case H.toList v of
      [(conKey,Object conVal)] ->
        case conKey of
          "BlackBoxHaskell"  -> do
            name' <- conVal .: "name"
            wf    <- ((conVal .:? "workInfo" >>= maybe (pure Nothing) parseWorkInfo) .!= WorkVariable)
            fName <- conVal .: "templateFunction"
            templ <- (Just . TInline <$> conVal .: "template")
                 <|> (Just . TFile   <$> conVal .: "file")
                 <|> (pure Nothing)

            fName' <- either fail return (parseBBFN fName)

            return (BlackBoxHaskell name' wf fName' templ)
          "BlackBox"  ->
            BlackBox <$> conVal .: "name"
                     <*> (conVal .:? "workInfo" >>= maybe (pure Nothing) parseWorkInfo) .!= WorkVariable
                     <*> (conVal .: "kind" >>= parseTemplateKind)
                     <*> conVal .:? "warning"
                     <*> conVal .:? "outputReg" .!= False
                     <*> conVal .:? "libraries" .!= []
                     <*> conVal .:? "imports" .!= []
                     <*> (conVal .:? "includes" .!= [] >>= traverse parseInclude)
                     <*> parseTemplate conVal
          "Primitive" ->
            Primitive <$> conVal .: "name"
                      <*> (conVal .:? "workInfo" >>= maybe (pure Nothing) parseWorkInfo) .!= WorkVariable
                      <*> conVal .: "primType"

          e -> fail $ "[1] Expected: BlackBox or Primitive object, got: " ++ show e
      e -> fail $ "[2] Expected: BlackBox or Primitive object, got: " ++ show e
    where
      parseTemplate c =
        (,) <$> ((,) <$> (c .:? "format" >>= traverse parseTemplateFormat) .!= TTemplate
                     <*> (c .:? "templateFunction" >>= traverse parseBBFN') .!= defTemplateFunction)
            <*> (Just . TInline <$> c .: "template" <|>
                 Just . TFile   <$> c .: "file" <|>
                 pure Nothing)

      parseInclude c =
        (,) <$> ((,) <$> c .: "name" <*> c .: "extension")
            <*> parseTemplate c

      parseTemplateKind (String "Declaration") = pure TDecl
      parseTemplateKind (String "Expression")  = pure TExpr
      parseTemplateKind c = fail ("[4] Expected: Declaration or Expression, got " ++ show c)

      parseTemplateFormat (String "Template") = pure TTemplate
      parseTemplateFormat (String "Haskell")  = pure THaskell
      parseTemplateFormat c = fail ("[5] unexpected format: " ++ show c)

      parseWorkInfo (String "Constant") = pure (Just WorkConstant)
      parseWorkInfo (String "Never")    = pure (Just WorkNever)
      parseWorkInfo (String "Variable") = pure (Just WorkVariable)
      parseWorkInfo (String "Always")   = pure (Just WorkAlways)
      parseWorkInfo c = fail ("[6] unexpected workInfo: " ++ show c)

      parseBBFN' = either fail return . parseBBFN

      defTemplateFunction = BlackBoxFunctionName ["Template"] "template"

  parseJSON unexpected =
    fail $ "[3] Expected: BlackBox or Primitive object, got: " ++ show unexpected
