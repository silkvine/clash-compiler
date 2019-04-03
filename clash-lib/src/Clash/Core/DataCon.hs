{-|
  Copyright   :  (C) 2012-2016, University of Twente,
                          2017, Google Inc.
  License     :  BSD2 (see the file LICENSE)
  Maintainer  :  Christiaan Baaij <christiaan.baaij@gmail.com>

  Data Constructors in CoreHW
-}

{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}

module Clash.Core.DataCon
  ( DataCon (..)
  , DcName
  , ConTag
  )
where

import Control.DeepSeq                        (NFData(..))
import Data.Binary                            (Binary)
import Data.Hashable                          (Hashable)
import qualified Data.Text                    as Text
import GHC.Generics                           (Generic)

import Clash.Core.Name                        (Name (..))
import {-# SOURCE #-} Clash.Core.Type         (Type)
import Clash.Core.Var                         (TyVar)
import Clash.Unique
import Clash.Util

-- | Data Constructor
data DataCon
  = MkData
  { dcName :: !DcName
  -- ^ Name of the DataCon
  , dcUniq :: {-# UNPACK #-} !Unique
  , dcTag :: !ConTag
  -- ^ Syntactical position in the type definition
  , dcType :: !Type
  -- ^ Type of the 'DataCon
  , dcUnivTyVars :: [TyVar]
  -- ^ Universally quantified type-variables, these type variables are also part
  -- of the result type of the DataCon
  , dcExtTyVars :: [TyVar]
  -- ^ Existentially quantified type-variables, these type variables are not
  -- part of the result of the DataCon, but only of the arguments.
  , dcArgTys :: [Type]
  -- ^ Argument types
  , dcFieldLabels :: [Text.Text]
  -- ^ Names of fields. Used when data constructor is referring to a record type.
  } deriving (Generic,NFData,Hashable,Binary)

instance Show DataCon where
  show = show . dcName

instance Eq DataCon where
  (==) = (==) `on` dcUniq
  (/=) = (/=) `on` dcUniq

instance Ord DataCon where
  compare = compare `on` dcUniq

instance Uniquable DataCon where
  getUnique = dcUniq

-- | Syntactical position of the DataCon in the type definition
type ConTag = Int
-- | DataCon reference
type DcName = Name DataCon
