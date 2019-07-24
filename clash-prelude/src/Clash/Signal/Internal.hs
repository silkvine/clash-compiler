{-|
Copyright  :  (C) 2013-2016, University of Twente,
                  2017-2019, Myrtle Software Ltd
                  2017,      Google Inc.
License    :  BSD2 (see the file LICENSE)
Maintainer :  Christiaan Baaij <christiaan.baaij@gmail.com>
-}

{-# LANGUAGE AllowAmbiguousTypes    #-}
{-# LANGUAGE ConstraintKinds        #-}
{-# LANGUAGE CPP                    #-}
{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE DeriveAnyClass         #-}
{-# LANGUAGE DeriveDataTypeable     #-}
{-# LANGUAGE DeriveGeneric          #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE GADTs                  #-}
{-# LANGUAGE MagicHash              #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE StandaloneDeriving     #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE TypeApplications       #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE ViewPatterns           #-}
#if __GLASGOW_HASKELL__ < 806
{-# LANGUAGE TypeInType #-}
#endif

{-# LANGUAGE Unsafe #-}

-- See: https://github.com/clash-lang/clash-compiler/commit/721fcfa9198925661cd836668705f817bddaae3c
-- as to why we need this.
{-# OPTIONS_GHC -fno-cpr-anal #-}

{-# OPTIONS_HADDOCK show-extensions not-home #-}

module Clash.Signal.Internal
  ( -- * Datatypes
    Signal(..)
  , head#
  , tail#
    -- * Domains
  , Domain
  , KnownDomain(..)
  , KnownConfiguration
  , knownDomainByName
  , ActiveEdge(..)
  , SActiveEdge(..)
  , InitBehavior(..)
  , SInitBehavior(..)
  , ResetKind(..)
  , SResetKind(..)
  , ResetPolarity(..)
  , SResetPolarity(..)
  , DomainConfiguration(..)
  , SDomainConfiguration(..)
    -- ** Default domains
  , System
  , XilinxSystem
  , IntelSystem
  , vSystem
  , vIntelSystem
  , vXilinxSystem
    -- ** Domain utilities
  , VDomainConfiguration(..)
  , vDomain
  , createDomain
  , knownVDomain
  , isSensitiveToRisingEdge
  , isAsynchronous
  , hasDefinedInitialValues
  , isActiveHigh
    -- * Clocks
  , Clock (..)
  , clockTag
  , clockPeriod
    -- ** Enabling
  , Enable(..)
  , toEnable
  , fromEnable
  , enableGen
    -- * Resets
  , Reset(..)
  , unsafeToReset
  , unsafeFromReset
  , unsafeToHighPolarity
  , unsafeToLowPolarity
  , unsafeFromHighPolarity
  , unsafeFromLowPolarity
  , invertReset
    -- * Basic circuits
  , delay#
  , register#
  , mux
    -- * Simulation and testbench functions
  , clockGen
  , tbClockGen
  , tbEnableGen
  , resetGen
    -- * Boolean connectives
  , (.&&.), (.||.)
    -- * Simulation functions (not synthesizable)
  , simulate
    -- ** lazy version
  , simulate_lazy
    -- * List \<-\> Signal conversion (not synthesizable)
  , sample
  , sampleN
  , fromList
    -- ** lazy versions
  , sample_lazy
  , sampleN_lazy
  , fromList_lazy
    -- * QuickCheck combinators
  , testFor
    -- * Type classes
    -- ** 'Eq'-like
  , (.==.), (./=.)
    -- ** 'Ord'-like
  , (.<.), (.<=.), (.>=.), (.>.)
    -- ** 'Functor'
  , mapSignal#
    -- ** 'Applicative'
  , signal#
  , appSignal#
    -- ** 'Foldable'
  , foldr#
    -- ** 'Traversable'
  , traverse#
  -- * EXTREMELY EXPERIMENTAL
  , joinSignal#
  )
where

import Type.Reflection            (Typeable)
import Control.Applicative        (liftA2, liftA3)
import Control.DeepSeq            (NFData)
import Clash.Annotations.Primitive (hasBlackBox)
import Data.Binary                (Binary)
import Data.Char                  (isAsciiUpper, isAlphaNum, isAscii)
import Data.Coerce                (coerce)
import Data.Data                  (Data)
import Data.Default.Class         (Default (..))
import Data.Hashable              (Hashable)
import GHC.Generics               (Generic)
import GHC.TypeLits               (KnownSymbol, Nat, Symbol)
import Language.Haskell.TH.Syntax -- (Lift (..), Q, Dec)
import Numeric.Natural            (Natural)
import Test.QuickCheck            (Arbitrary (..), CoArbitrary(..), Property,
                                   property)

import Clash.Promoted.Nat         (SNat (..), snatToNum, snatToNatural)
import Clash.Promoted.Symbol      (SSymbol (..), ssymbolToString)
import Clash.XException
  (Undefined, errorX, deepseqX, defaultSeqX, deepErrorX)

{- $setup
>>> :set -XDataKinds
>>> :set -XMagicHash
>>> :set -XTypeApplications
>>> import Clash.Promoted.Nat
>>> import Clash.XException
>>> type System = "System"
>>> let systemClockGen = clockGen @System
>>> let systemResetGen = resetGen @System
>>> import Clash.Explicit.Signal (register)
>>> let registerS = register
>>> let registerA = register
-}


-- * Signal

-- | Determines clock edge memory elements are sensitive to. Not yet
-- implemented.
data ActiveEdge
  -- TODO: Implement in blackboxes:
  = Rising
  -- ^ Elements are sensitive to the rising edge (low-to-high) of the clock.
  | Falling
  -- ^ Elements are sensitive to the falling edge (high-to-low) of the clock.
  deriving (Show, Eq, Ord, Generic, NFData, Data, Hashable, Binary)

data SActiveEdge (edge :: ActiveEdge) where
  SRising  :: SActiveEdge 'Rising
  -- See 'Rising' ^
  SFalling :: SActiveEdge 'Falling
  -- See 'Falling' ^

instance Show (SActiveEdge edge) where
  show SRising = "SRising"
  show SFalling = "SFalling"

data ResetKind
  = Asynchronous
  -- ^ Elements respond /asynchronously/ to changes in their reset input. This
  -- means that they do /not/ wait for the next active clock edge, but respond
  -- immediately instead. Common on Intel FPGA platforms.
  | Synchronous
  -- ^ Elements respond /synchronously/ to changes in their reset input. This
  -- means that changes in their reset input won't take effect until the next
  -- active clock edge. Common on Xilinx FPGA platforms.
  deriving (Show, Eq, Ord, Generic, NFData, Data, Hashable)

-- | Singleton version of 'ResetKind'
data SResetKind (resetKind :: ResetKind) where
  SAsynchronous :: SResetKind 'Asynchronous
  -- See 'Asynchronous' ^

  SSynchronous  :: SResetKind 'Synchronous
  -- See 'Synchronous' ^

instance Show (SResetKind reset) where
  show SAsynchronous = "SAsynchronous"
  show SSynchronous = "SSynchronous"

-- | Determines the value for which a reset line is considered "active"
data ResetPolarity
  = ActiveHigh
  -- ^ Reset is considered active if underlying signal is 'True'.
  | ActiveLow
  -- ^ Reset is considered active if underlying signal is 'False'.
  deriving (Eq, Ord, Show, Generic, NFData, Data, Hashable)

-- | Singleton version of 'ResetPolarity'
data SResetPolarity (polarity :: ResetPolarity) where
  SActiveHigh :: SResetPolarity 'ActiveHigh
  -- See: 'ActiveHigh' ^

  SActiveLow :: SResetPolarity 'ActiveLow
  -- See: 'ActiveLow' ^

instance Show (SResetPolarity polarity) where
  show SActiveHigh = "SActiveHigh"
  show SActiveLow = "SActiveLow"

data InitBehavior
  = Unknown
  -- ^ Power up value of memory elements is /unknown/.
  | Defined
  -- ^ If applicable, power up value of a memory element is defined. Applies to
  -- 'register's for example, but not to 'blockRam'.
  deriving (Show, Eq, Ord, Generic, NFData, Data, Hashable)

data SInitBehavior (init :: InitBehavior) where
  SUnknown :: SInitBehavior 'Unknown
  -- See: 'Unknown' ^

  SDefined :: SInitBehavior 'Defined
  -- See: 'Defined' ^

instance Show (SInitBehavior init) where
  show SUnknown = "SUnknown"
  show SDefined = "SDefined"

-- | A domain with a name (@Domain@). Configures the behavior of various aspects
-- of a circuits. See the documentation of this record's field types for more
-- information on the options.
--
-- See module documentation of "Clash.Explicit.Signal" for more information on
-- how to create custom synthesis domains.
data DomainConfiguration
  = DomainConfiguration
  { _name :: Domain
  -- ^ Domain name
  , _period :: Nat
  -- ^ Period of clock in /ps/
  , _edge :: ActiveEdge
  -- ^ Active edge of the clock (not yet
  -- implemented)
  , _reset :: ResetKind
  -- ^ Whether resets are synchronous (edge-sensitive) or asynchronous (level-sensitive)
  , _init :: InitBehavior
  -- ^ Whether the initial (or "power up") value of memory elements is
  -- unknown/undefined, or configurable to a specific value
  , _polarity :: ResetPolarity
  -- ^ Whether resets are active high or active low
  }
  deriving (Typeable)

-- | Singleton version of 'DomainConfiguration'
data SDomainConfiguration (dom :: Domain) (conf :: DomainConfiguration) where
  SDomainConfiguration
    :: SSymbol dom
    -- Domain name ^
    -> SNat period
    -- Period of clock in /ps/ ^
    -> SActiveEdge edge
    -- Active edge of the clock (not yet
    -- implemented) ^
    -> SResetKind reset
    -- Whether resets are synchronous (edge-sensitive) or asynchronous (level-sensitive) ^
    -> SInitBehavior init
    -- Whether the initial (or "power up") value of memory elements is
    -- unknown/undefined, or configurable to a specific value ^
    -> SResetPolarity polarity
    -- Whether resets are active high or active low ^
    -> SDomainConfiguration dom ('DomainConfiguration dom period edge reset init polarity)

instance Show (SDomainConfiguration dom conf) where
  show (SDomainConfiguration dom period edge reset init_ polarity) =
    unwords
      [ "SDomainConfiguration"
      , show dom
      , show period
      , show edge
      , show reset
      , show init_
      , show polarity
      ]

type KnownConfiguration dom conf = (KnownDomain dom, KnownConf dom ~ conf)

-- | A 'KnownDomain' constraint indicates that a circuit's behavior depends on
-- some properties of a domain. See 'DomainConfiguration' for more information.
class KnownSymbol dom => KnownDomain (dom :: Domain) where
  type KnownConf dom :: DomainConfiguration
  -- | Returns 'SDomainConfiguration' corresponding to an instance's 'DomainConfiguration'.
  --
  -- Example usage:
  -- > knownDomain @System
  --
  knownDomain :: SDomainConfiguration dom (KnownConf dom)


-- | Whether domain's memory elements are sensitive to a rising edge
isSensitiveToRisingEdge
  :: forall dom
   . KnownDomain dom
  => Bool
isSensitiveToRisingEdge =
  case knownDomain @dom of
    SDomainConfiguration _dom _period SRising _sync _init _polarity -> True
    SDomainConfiguration _dom _period SFalling _sync _init _polarity -> False
{-# INLINE isSensitiveToRisingEdge #-}

-- | Whether domain has asynchronous resets
isAsynchronous
  :: forall dom
   . KnownDomain dom
  => Bool
isAsynchronous =
  case knownDomain @dom of
    SDomainConfiguration _dom _period _edge SAsynchronous _init _polarity -> True
    SDomainConfiguration _dom _period _edge SSynchronous _init _polarity -> False
{-# INLINE isAsynchronous #-}

-- | Whether domain has defined initial values
hasDefinedInitialValues
  :: forall dom
   . KnownDomain dom
  => Bool
hasDefinedInitialValues =
  case knownDomain @dom of
    SDomainConfiguration _dom _period _edge _sync SDefined _polarity -> True
    SDomainConfiguration _dom _period _edge _sync SUnknown _polarity -> False
{-# INLINE hasDefinedInitialValues #-}

-- | Whether resets are active high
isActiveHigh
  :: forall dom
   . KnownDomain dom
  => Bool
isActiveHigh =
  case knownDomain @dom of
    SDomainConfiguration _dom _period _edge _sync _init SActiveHigh -> True
    SDomainConfiguration _dom _period _edge _sync _init SActiveLow -> False
{-# INLINE isActiveHigh #-}

-- | Version of 'knownDomain accepts a SSymbol. For example:
--
-- >>> knownDomainByName (SSymbol @"System")
-- SDomainConfiguration System d10000 SRising SAsynchronous SDefined SActiveHigh
knownDomainByName
  :: forall dom
   . KnownDomain dom
  => SSymbol dom
  -> SDomainConfiguration dom (KnownConf dom)
knownDomainByName =
  const knownDomain
{-# INLINE knownDomainByName #-}

-- | A /clock/ (and /reset/) dom with clocks running at 100 MHz
instance KnownDomain System where
  type KnownConf System = 'DomainConfiguration System 10000 'Rising 'Asynchronous 'Defined 'ActiveHigh
  knownDomain = SDomainConfiguration SSymbol SNat SRising SAsynchronous SDefined SActiveHigh

-- | System instance with defaults set for Xilinx FPGAs
instance KnownDomain XilinxSystem where
  type KnownConf XilinxSystem = 'DomainConfiguration XilinxSystem 10000 'Rising 'Synchronous 'Defined 'ActiveHigh
  knownDomain = SDomainConfiguration SSymbol SNat SRising SSynchronous SDefined SActiveHigh

-- | System instance with defaults set for Intel FPGAs
instance KnownDomain IntelSystem where
  type KnownConf IntelSystem = 'DomainConfiguration IntelSystem 10000 'Rising 'Asynchronous 'Defined 'ActiveHigh
  knownDomain = SDomainConfiguration SSymbol SNat SRising SAsynchronous SDefined SActiveHigh

-- | Convenience value to allow easy "subclassing" of System domain. Should
-- be used in combination with 'createDomain'. For example, if you just want to
-- change the period but leave all other settings in tact use:
--
-- > createDomain vSystem{vTag="System10", vPeriod=10}
--
vSystem :: VDomainConfiguration
vSystem = vDomain (knownDomain @System)

-- | A clock (and reset) dom with clocks running at 100 MHz. Memory elements
-- respond to the rising edge of the clock, and asynchronously to changes in
-- reset signals. It has defined initial values, and active-high resets.
--
-- See module documentation of "Clash.Explicit.Signal" for more information on
-- how to create custom synthesis domains.
type System = ("System" :: Domain)


-- | Convenience value to allow easy "subclassing" of IntelSystem domain. Should
-- be used in combination with 'createDomain'. For example, if you just want to
-- change the period but leave all other settings in tact use:
--
-- > createDomain vIntelSystem{vTag="Intel10", vPeriod=10}
--
vIntelSystem :: VDomainConfiguration
vIntelSystem = vDomain (knownDomain @IntelSystem)

-- | A clock (and reset) dom with clocks running at 100 MHz. Memory elements
-- respond to the rising edge of the clock, and asynchronously to changes in
-- reset signals. It has defined initial values, and active-high resets.
--
-- See module documentation of "Clash.Explicit.Signal" for more information on
-- how to create custom synthesis domains.
type IntelSystem = ("IntelSystem" :: Domain)

-- | Convenience value to allow easy "subclassing" of XilinxSystem domain. Should
-- be used in combination with 'createDomain'. For example, if you just want to
-- change the period but leave all other settings in tact use:
--
-- > createDomain vXilinxSystem{vTag="Xilinx10", vPeriod=10}
--
vXilinxSystem :: VDomainConfiguration
vXilinxSystem = vDomain (knownDomain @XilinxSystem)

-- | A clock (and reset) dom with clocks running at 100 MHz. Memory elements
-- respond to the rising edge of the clock, and synchronously to changes in
-- reset signals. It has defined initial values, and active-high resets.
--
-- See module documentation of "Clash.Explicit.Signal" for more information on
-- how to create custom synthesis domains.
type XilinxSystem = ("XilinxSystem" :: Domain)

-- | Same as SDomainConfiguration but allows for easy updates through record update syntax.
-- Should be used in combination with 'vDomain' and 'createDomain'. Example:
--
-- > createDomain (knownVDomain @System){vTag="System10", vPeriod=10}
--
-- This duplicates the settings in the "System" domain, replaces the name and
-- period, and creates an instance for it. As most users often want to update
-- the system domain, a shortcut is available in the form:
--
-- > createDomain vSystem{vTag="System10", vPeriod=10}
--
data VDomainConfiguration
  = VDomainConfiguration
  { vTag    :: String
  -- ^ Corresponds to '_name' on 'DomainConfiguration'
  , vPeriod :: Natural
  -- ^ Corresponds to '_period' on 'DomainConfiguration'
  , vEdge   :: ActiveEdge
  -- ^ Corresponds to '_edge' on 'DomainConfiguration'
  , vReset  :: ResetKind
  -- ^ Corresponds to '_reset' on 'DomainConfiguration'
  , vInit   :: InitBehavior
  -- ^ Corresponds to '_init' on 'DomainConfiguration'
  , vPolarity :: ResetPolarity
  -- ^ Corresponds to '_polarity' on 'DomainConfiguration'
  }

-- | Like 'knownDomain but yields a 'VDomainConfiguration'. Should only be used
-- in combination with 'createDomain'.
knownVDomain
  :: forall dom
   . KnownDomain dom
  => VDomainConfiguration
knownVDomain =
  vDomain (knownDomain @dom)

-- | Convert 'SDomainConfiguration' to 'VDomainConfiguration'. Should be used in combination with
-- 'createDomain' only.
vDomain :: SDomainConfiguration dom conf -> VDomainConfiguration
vDomain (SDomainConfiguration dom period edge reset init_ polarity) =
  VDomainConfiguration
    (ssymbolToString dom)
    (snatToNatural period)
    (case edge of {SRising -> Rising; SFalling -> Falling})
    (case reset of {SAsynchronous -> Asynchronous; SSynchronous -> Synchronous})
    (case init_ of {SDefined -> Defined; SUnknown -> Unknown})
    (case polarity of {SActiveHigh -> ActiveHigh; SActiveLow -> ActiveLow})

-- TODO: Function might reject valid type names. Figure out what's allowed.
isValidDomainName :: String -> Bool
isValidDomainName (x:xs) = isAsciiUpper x && all isAscii xs && all isAlphaNum xs
isValidDomainName _ = False

-- | Convenience method to express new domains in terms of others.
--
-- > createDomain (knownVDomain @System){vTag="System10", vPeriod=10}
--
-- This duplicates the settings in the "System" domain, replaces the name and
-- period, and creates an instance for it. As most users often want to update
-- the system domain, a shortcut is available in the form:
--
-- > createDomain vSystem{vTag="System10", vPeriod=10}
--
-- The function will create two extra identifiers. The first:
--
-- > type System10 = ..
--
-- You can use that to dom Clocks/Resets/Enables/Signals. For example:
-- @Signal System10 Int@. Additionally, it will create a 'VDomainConfiguration' that you can
-- use in later calls to 'createDomain':
--
-- > vSystem10 = 'knownVDomain' @System10
--
createDomain :: VDomainConfiguration -> Q [Dec]
createDomain (VDomainConfiguration name period edge reset init_ polarity) =
  if isValidDomainName name then do
    kdType <- [t| KnownDomain $nameT |]
    kcType <- [t| ('DomainConfiguration $nameT $periodT $edgeT $resetKindT $initT $polarityT) |]
    sDom <- [| SDomainConfiguration SSymbol SNat $edgeE $resetKindE $initE $polarityE |]
    let vTagImpl = AppTypeE (VarE 'knownVDomain) (LitT (StrTyLit name))
    let kdImpl = FunD 'knownDomain [Clause [] (NormalB sDom) []]
    let kcImpl = TySynInstD ''KnownConf (TySynEqn [LitT (StrTyLit name)] kcType)
    pure  [ InstanceD Nothing [] kdType [kcImpl, kdImpl]
          , TySynD (mkName name) [] (LitT (StrTyLit name)  `SigT`  ConT ''Domain)
          , FunD (mkName ('v':name)) [Clause [] (NormalB vTagImpl) []]
          ]
  else
    error ("Domain names should be a valid Haskell type name, not: " ++ name)
 where

  edgeE =
    pure $
    case edge of
      Rising -> ConE 'SRising
      Falling -> ConE 'SFalling

  resetKindE =
    pure $
    case reset of
      Asynchronous -> ConE 'SAsynchronous
      Synchronous -> ConE 'SSynchronous

  initE =
    pure $
    case init_ of
      Unknown -> ConE 'SUnknown
      Defined -> ConE 'SDefined

  polarityE =
    pure $
    case polarity of
      ActiveHigh -> ConE 'SActiveHigh
      ActiveLow -> ConE 'SActiveLow

  nameT   = pure (LitT (StrTyLit name))
  periodT = pure (LitT (NumTyLit (toInteger period)))

  edgeT =
    pure $
    case edge of
      Rising -> PromotedT 'Rising
      Falling -> PromotedT 'Falling

  resetKindT =
    pure $
    case reset of
      Asynchronous -> PromotedT 'Asynchronous
      Synchronous -> PromotedT 'Synchronous

  initT =
    pure $
    case init_ of
      Unknown -> PromotedT 'Unknown
      Defined -> PromotedT 'Defined

  polarityT =
    pure $
    case polarity of
      ActiveHigh -> PromotedT 'ActiveHigh
      ActiveLow -> PromotedT 'ActiveLow


type Domain = Symbol

infixr 5 :-
{- | Clash has synchronous 'Signal's in the form of:

@
'Signal' (dom :: 'Domain') a
@

Where /a/ is the type of the value of the 'Signal', for example /Int/ or /Bool/,
and /dom/ is the /clock-/ (and /reset-/) domain to which the memory elements
manipulating these 'Signal's belong.

The type-parameter, /dom/, is of the kind 'Domain' - a simple string. That
string refers to a single /synthesis domain/. A synthesis domain describes the
behavior of certain aspects of memory elements in it.

* __NB__: \"Bad things\"™  happen when you actually use a clock period of @0@,
so do __not__ do that!
* __NB__: You should be judicious using a clock with period of @1@ as you can
never create a clock that goes any faster!
* __NB__: For the best compatibility make sure your period is divisible by 2,
because some VHDL simulators don't support fractions of picoseconds.
* __NB__: Whether 'System' has good defaults depends on your target platform.
Check out 'IntelSystem' and 'XilinxSystem' too!

See the module documentation of "Clash.Signal" for more information about
domains.
-}
data Signal (dom :: Domain) a
  -- | The constructor, @(':-')@, is __not__ synthesizable.
  = a :- Signal dom a

head# :: Signal dom a -> a
head# (x' :- _ )  = x'

tail# :: Signal dom a -> Signal dom a
tail# (_  :- xs') = xs'

instance Show a => Show (Signal dom a) where
  show (x :- xs) = show x ++ " " ++ show xs

instance Lift a => Lift (Signal dom a) where
  lift ~(x :- _) = [| signal# x |]

instance Default a => Default (Signal dom a) where
  def = signal# def

instance Functor (Signal dom) where
  fmap = mapSignal#

mapSignal# :: (a -> b) -> Signal dom a -> Signal dom b
mapSignal# f (a :- as) = f a :- mapSignal# f as
{-# NOINLINE mapSignal# #-}
{-# ANN mapSignal# hasBlackBox #-}

instance Applicative (Signal dom) where
  pure  = signal#
  (<*>) = appSignal#

signal# :: a -> Signal dom a
signal# a = let s = a :- s in s
{-# NOINLINE signal# #-}
{-# ANN signal# hasBlackBox #-}

appSignal# :: Signal dom (a -> b) -> Signal dom a -> Signal dom b
appSignal# (f :- fs) xs@(~(a :- as)) = f a :- (xs `seq` appSignal# fs as) -- See [NOTE: Lazy ap]
{-# NOINLINE appSignal# #-}
{-# ANN appSignal# hasBlackBox #-}

{- NOTE: Lazy ap
Signal's ap, i.e (Applicative.<*>), must be lazy in it's second argument:

> appSignal :: Signal' clk (a -> b) -> Signal' clk a -> Signal' clk b
> appSignal (f :- fs) ~(a :- as) = f a :- appSignal fs as

because some feedback loops, such as the loop described in 'system' in the
example at http://hackage.haskell.org/package/clash-prelude-0.10.10/docs/Clash-Prelude-BlockRam.html,
will lead to "Exception <<loop>>".

However, this "naive" lazy version is _too_ lazy and induces spaceleaks.
The current version:

> appSignal# :: Signal' clk (a -> b) -> Signal' clk a -> Signal' clk b
> appSignal# (f :- fs) xs@(~(a :- as)) = f a :- (xs `seq` appSignal# fs as)

Is lazy enough to handle the earlier mentioned feedback loops, but doesn't leak
(as much) memory like the "naive" lazy version, because the Signal constructor
of the second argument is evaluated as soon as the tail of the result is evaluated.
-}


-- | __WARNING: EXTREMELY EXPERIMENTAL__
--
-- The circuit semantics of this operation are unclear and/or non-existent.
-- There is a good reason there is no 'Monad' instance for 'Signal''.
--
-- Is currently treated as 'id' by the Clash compiler.
joinSignal# :: Signal dom (Signal dom a) -> Signal dom a
joinSignal# ~(xs :- xss) = head# xs :- joinSignal# (mapSignal# tail# xss)
{-# NOINLINE joinSignal# #-}
{-# ANN joinSignal# hasBlackBox #-}

instance Num a => Num (Signal dom a) where
  (+)         = liftA2 (+)
  (-)         = liftA2 (-)
  (*)         = liftA2 (*)
  negate      = fmap negate
  abs         = fmap abs
  signum      = fmap signum
  fromInteger = signal# . fromInteger

-- | __NB__: Not synthesizable
--
-- __NB__: In \"@'foldr' f z s@\":
--
-- * The function @f@ should be /lazy/ in its second argument.
-- * The @z@ element will never be used.
instance Foldable (Signal dom) where
  foldr = foldr#

-- | __NB__: Not synthesizable
--
-- __NB__: In \"@'foldr#' f z s@\":
--
-- * The function @f@ should be /lazy/ in its second argument.
-- * The @z@ element will never be used.
foldr# :: (a -> b -> b) -> b -> Signal dom a -> b
foldr# f z (a :- s) = a `f` (foldr# f z s)
{-# NOINLINE foldr# #-}
{-# ANN foldr# hasBlackBox #-}

instance Traversable (Signal dom) where
  traverse = traverse#

traverse# :: Applicative f => (a -> f b) -> Signal dom a -> f (Signal dom b)
traverse# f (a :- s) = (:-) <$> f a <*> traverse# f s
{-# NOINLINE traverse# #-}
{-# ANN traverse# hasBlackBox #-}

-- * Clocks, resets, and enables

-- | A signal of booleans, indicating whether a component is enabled. No special
-- meaning is implied, it's up to the component itself to decide how to respond
-- to its enable line. It is used throughout Clash as a global enable signal.
newtype Enable dom = Enable (Signal dom Bool)

-- | Convert 'Enable' construct to its underlying representation: a signal of
-- bools.
fromEnable :: Enable dom -> Signal dom Bool
fromEnable = coerce
{-# INLINE fromEnable #-}

-- | Convert a signal of bools to an 'Enable' construct
toEnable :: Signal dom Bool -> Enable dom
toEnable = coerce
{-# INLINE toEnable #-}

-- | Enable generator for some domain. Is simply always True.
enableGen :: Enable dom
enableGen = toEnable (pure True)

-- | A clock signal belonging to a domain named /dom/.
data Clock (dom :: Domain) = Clock (SSymbol dom)

instance Show (Clock dom) where
  show (Clock dom) = "<Clock: " ++ show dom ++ ">"

-- | Get the clock period of a 'Clock' (in /ps/) as a 'Num'
clockPeriod
  :: forall dom  a
   . KnownDomain dom
  => Num a
  => Clock dom
  -> a
clockPeriod (Clock _) =
  case knownDomain @dom of
    SDomainConfiguration _dom period _edge _reset _init _polarity ->
      snatToNum period

-- | Extract dom symbol from Clock
clockTag
  :: Clock dom
  -> SSymbol dom
clockTag (Clock dom) = dom

-- | Clock generator for simulations. Do __not__ use this clock generator for
-- for the /testBench/ function, use 'tbClockGen' instead.
--
-- To be used like:
--
-- @
-- clkSystem = clockGen @System
-- @
--
-- See 'DomainConfiguration' for more information on how to use synthesis domains.
clockGen
  :: KnownDomain dom
  => Clock dom
clockGen = Clock SSymbol
{-# NOINLINE clockGen #-}
{-# ANN clockGen hasBlackBox #-}

-- | Clock generator to be used in the /testBench/ function.
--
-- To be used like:
--
-- @
-- clkSystem en = tbClockGen @System en
-- @
--
-- === __Example__
--
-- @
-- module Example where
--
-- import "Clash.Explicit.Prelude"
-- import "Clash.Explicit.Testbench"
--
-- -- Fast domain: twice as fast as \"Slow\"
-- 'createDomain' 'vSystem'{vTag=\"Fast\", vPeriod=10}
--
-- -- Slow domain: twice as slow as "Fast"
-- 'createDomain' 'vSystem'{vTag=\"Slow\", vPeriod=20}
--
-- topEntity
--   :: 'Clock' \"Fast\"
--   -> 'Reset' \"Fast\"
--   -> 'Enable' \"Fast\"
--   -> 'Clock' \"Slow\"
--   -> 'Signal' \"Fast\" (Unsigned 8)
--   -> 'Signal' \"Slow\" (Unsigned 8, Unsigned 8)
-- topEntity clk1 rst1 en1 clk2 i =
--   let h = register clk1 rst1 en1 0 (register clk1 rst1 en1 0 i)
--       l = register clk1 rst1 en1 0 i
--   in  unsafeSynchronizer clk1 clk2 (bundle (h, l))
--
-- testBench
--   :: 'Signal' \"Slow\" Bool
-- testBench = done
--   where
--     testInput      = 'Clash.Explicit.Testbench.stimuliGenerator' clkA1 rstA1 $('listToVecTH' [1::Unsigned 8,2,3,4,5,6,7,8])
--     expectedOutput = 'Clash.Explicit.Testbench.outputVerifier'   clkB2 rstB2 $('listToVecTH' [(0,0) :: (Unsigned 8, Unsigned 8),(1,2),(3,4),(5,6),(7,8)])
--     done           = expectedOutput (topEntity clkA1 rstA1 enableGen clkB2 testInput)
--     done'          = not \<$\> done
--     clkA1          = 'tbClockGen' \@\"Fast\" (unsafeSynchronizer clkB2 clkA1 done')
--     clkB2          = 'tbClockGen' \@\"Slow\" done'
--     rstA1          = 'resetGen' \@\"Fast\"
--     rstB2          = 'resetGen' \@\"Slow\"
-- @
tbClockGen
  :: KnownDomain dom
  => Signal dom Bool
  -> Clock dom
tbClockGen _clk = clockGen
{-# NOINLINE tbClockGen #-}
{-# ANN tbClockGen hasBlackBox #-}

-- | Opaque enable signal that's always enabled. Won't be optimized away.
tbEnableGen :: Enable tag
tbEnableGen = toEnable (pure True)
{-# NOINLINE tbEnableGen #-}
{-# ANN tbEnableGen hasBlackBox #-}

-- | Reset generator
--
-- To be used like:
--
-- @
-- rstSystem = resetGen @System
-- @
--
-- See 'tbClockGen' for example usage.
--
resetGen
  :: forall dom
   . KnownDomain dom
  => Reset dom
resetGen =
  if isActiveHigh @dom then
    Reset (True :- pure False)
  else
    Reset (False :- pure True)
{-# NOINLINE resetGen #-}
{-# ANN resetGen hasBlackBox #-}

-- | A reset signal belonging to a domain called /dom/.
--
-- The underlying representation of resets is 'Bool'.
data Reset (dom :: Domain) = Reset (Signal dom Bool)

-- | Convert a reset to an active high reset. Has no effect if reset is already
-- an active high reset. Is unsafe because it can introduce:
--
-- * <Clash-Explicit-Signal.html#metastability meta-stability>
--
-- For asynchronous resets it is unsafe because it can cause combinatorial
-- loops. In case of synchronous resets it can lead to
-- <Clash-Explicit-Signal.html#metastability meta-stability> in the presence of
-- asynchronous resets.
unsafeToHighPolarity
  :: forall dom
   . KnownDomain dom
  => Reset dom
  -> Signal dom Bool
unsafeToHighPolarity (unsafeFromReset -> r) =
  if isActiveHigh @dom then r else not <$> r
{-# INLINE unsafeToHighPolarity #-}

-- | Convert a reset to an active low reset. Has no effect if reset is already
-- an active low reset. It is unsafe because it can introduce:
--
-- * <Clash-Explicit-Signal.html#metastability meta-stability>
--
-- For asynchronous resets it is unsafe because it can cause combinatorial
-- loops. In case of synchronous resets it can lead to
-- <Clash-Explicit-Signal.html#metastability meta-stability> in the presence of
-- asynchronous resets.
unsafeToLowPolarity
  :: forall dom
   . KnownDomain dom
  => Reset dom
  -> Signal dom Bool
unsafeToLowPolarity (unsafeFromReset -> r) =
  if isActiveHigh @dom then not <$> r else r
{-# INLINE unsafeToLowPolarity #-}

-- | 'unsafeFromReset' is unsafe because it can introduce:
--
-- * <Clash-Explicit-Signal.html#metastability meta-stability>
--
-- For asynchronous resets it is unsafe because it can cause combinatorial
-- loops. In case of synchronous resets it can lead to
-- <Clash-Explicit-Signal.html#metastability meta-stability> in the presence of
-- asynchronous resets.
--
-- __NB__: You probably want to use 'unsafeToLowPolarity' or
-- 'unsafeToHighPolarity'.
unsafeFromReset
  :: Reset dom
  -> Signal dom Bool
unsafeFromReset (Reset r) = r
{-# NOINLINE unsafeFromReset #-}
{-# ANN unsafeFromReset hasBlackBox #-}

-- | 'unsafeToReset' is unsafe. For asynchronous resets it is unsafe
-- because it can introduce combinatorial loops. In case of synchronous resets
-- it can lead to <Clash-Explicit-Signal.html#metastability meta-stability>
-- issues in the presence of asynchronous resets.
--
-- __NB__: You probably want to use 'unsafeFromLowPolarity' or
-- 'unsafeFromHighPolarity'.
unsafeToReset
  :: KnownDomain dom
  => Signal dom Bool
  -> Reset dom
unsafeToReset r = Reset r
{-# NOINLINE unsafeToReset #-}
{-# ANN unsafeToReset hasBlackBox #-}

-- | Interpret a signal of bools as an active high reset and convert it to
-- a reset signal corresponding to the domain's setting.
--
-- For asynchronous resets it is unsafe because it can cause combinatorial
-- loops. In case of synchronous resets it can lead to
-- <Clash-Explicit-Signal.html#metastability meta-stability> in the presence of
-- asynchronous resets.
unsafeFromHighPolarity
  :: forall dom
   . KnownDomain dom
  => Signal dom Bool
  -- ^ Reset signal that's 'True' when active, and 'False' when inactive.
  -> Reset dom
unsafeFromHighPolarity r =
  unsafeToReset (if isActiveHigh @dom then r else not <$> r)

-- | Interpret a signal of bools as an active low reset and convert it to
-- a reset signal corresponding to the domain's setting.
--
-- For asynchronous resets it is unsafe because it can cause combinatorial
-- loops. In case of synchronous resets it can lead to
-- <Clash-Explicit-Signal.html#metastability meta-stability> in the presence of
-- asynchronous resets.
unsafeFromLowPolarity
  :: forall dom
   . KnownDomain dom
  => Signal dom Bool
  -- ^ Reset signal that's 'False' when active, and 'True' when inactive.
  -> Reset dom
unsafeFromLowPolarity r =
  unsafeToReset (if isActiveHigh @dom then not <$> r else r)

-- | Invert reset signal
invertReset :: KnownDomain dom => Reset dom -> Reset dom
invertReset = unsafeToReset . fmap not . unsafeFromReset


infixr 2 .||.
-- | The above type is a generalization for:
--
-- @
-- __(.||.)__ :: 'Clash.Signal.Signal' 'Bool' -> 'Clash.Signal.Signal' 'Bool' -> 'Clash.Signal.Signal' 'Bool'
-- @
--
-- It is a version of ('||') that returns a 'Clash.Signal.Signal' of 'Bool'
(.||.) :: Applicative f => f Bool -> f Bool -> f Bool
(.||.) = liftA2 (||)

infixr 3 .&&.
-- | The above type is a generalization for:
--
-- @
-- __(.&&.)__ :: 'Clash.Signal.Signal' 'Bool' -> 'Clash.Signal.Signal' 'Bool' -> 'Clash.Signal.Signal' 'Bool'
-- @
--
-- It is a version of ('&&') that returns a 'Clash.Signal.Signal' of 'Bool'
(.&&.) :: Applicative f => f Bool -> f Bool -> f Bool
(.&&.) = liftA2 (&&)

-- [Note: register strictness annotations]
--
-- In order to produce the first (current) value of the register's output
-- signal, 'o', we don't need to know the shape of either input (enable or
-- value-in).  This is important, because both values might be produced from
-- the output in a feedback loop, so we can't know their shape (pattern
-- match) them until we have produced output.
--
-- Thus, we use lazy pattern matching to delay inspecting the shape of
-- either argument until output has been produced.
--
-- However, both arguments need to be evaluated to WHNF as soon as possible
-- to avoid a space-leak.  Below, we explicitly reduce the value-in signal
-- using 'seq' as the tail of our output signal is produced.  On the other
-- hand, because the value of the tail depends on the value of the enable
-- signal 'e', it will be forced by the 'if'/'then' statement and we don't
-- need to 'seq' it explicitly.

delay#
  :: forall dom a
   . ( KnownDomain dom
     , Undefined a )
  => Clock dom
  -> Enable dom
  -> a
  -> Signal dom a
  -> Signal dom a
delay# (Clock dom) (fromEnable -> en) powerUpVal0 =
    go powerUpVal1 en
  where
    powerUpVal1 :: a
    powerUpVal1 =
      case knownDomainByName dom of
        SDomainConfiguration _dom _period _edge _sync SDefined _polarity ->
          powerUpVal0
        SDomainConfiguration _dom _period _edge _sync SUnknown _polarity ->
          deepErrorX ("First value of `delay` unknown on domain " ++ show dom)

    go o (e :- es) as@(~(x :- xs)) =
      let o' = if e then x else o
      -- See [Note: register strictness annotations]
      in  o `defaultSeqX` o :- (as `seq` go o' es xs)
{-# NOINLINE delay# #-}
{-# ANN delay# hasBlackBox #-}

-- | A register with a power up and reset value. Power up values are not
-- supported on all platforms, please consult the manual of your target platform
-- and check the notes below.
--
-- Xilinx: power up values and reset values MUST be the same. If they are not,
-- the Xilinx tooling __will ignore the reset value__ and use the power up value
-- instead. Source: MIA
--
-- Intel: power up values and reset values MUST be the same. If they are not,
-- the Intel tooling __will ignore the power up value__ and use the reset value
-- instead. Source: https://www.intel.com/content/www/us/en/programmable/support/support-resources/knowledge-base/solutions/rd01072011_91.html
register#
  :: forall dom  a
   . ( KnownDomain dom
     , Undefined a )
  => Clock dom
  -> Reset dom
  -> Enable dom
  -> a
  -- ^ Power up value
  -> a
  -- ^ Reset value
  -> Signal dom a
  -> Signal dom a
register# (Clock dom) rst (fromEnable -> ena) powerUpVal0 resetVal =
  case knownDomainByName dom of
    SDomainConfiguration _name _period _edge SSynchronous _init _polarity ->
      goSync powerUpVal1 (unsafeToHighPolarity rst) ena
    SDomainConfiguration _name _period _edge SAsynchronous _init _polarity ->
      goAsync powerUpVal1 (unsafeToHighPolarity rst) ena
 where
  powerUpVal1 :: a
  powerUpVal1 =
    case knownDomainByName dom of
      SDomainConfiguration _dom _period _edge _sync SDefined _polarity ->
        powerUpVal0
      SDomainConfiguration _dom _period _edge _sync SUnknown _polarity ->
        deepErrorX ("First value of register undefined on domain " ++ show dom)

  goSync
    :: a
    -> Signal dom Bool
    -> Signal dom Bool
    -> Signal dom a
    -> Signal dom a
  goSync o rt@(~(r :- rs)) enas@(~(e :- es)) as@(~(x :- xs)) =
    let oE = if e then x else o
        oR = if r then resetVal else oE
        -- [Note: register strictness annotations]
    in  o `defaultSeqX` o :- (rt `seq` enas `seq` as `seq` goSync oR rs es xs)

  goAsync
    :: a
    -> Signal dom Bool
    -> Signal dom Bool
    -> Signal dom a
    -> Signal dom a
  goAsync o (r :- rs) enas@(~(e :- es)) as@(~(x :- xs)) =
    let oR = if r then resetVal else o
        oE = if r then resetVal else (if e then x else o)
        -- [Note: register strictness annotations]
    in  oR `defaultSeqX` oR :- (as `seq` enas `seq` goAsync oE rs es xs)
{-# NOINLINE register# #-}
{-# ANN register# hasBlackBox #-}

-- | The above type is a generalization for:
--
-- @
-- __mux__ :: 'Clash.Signal.Signal' 'Bool' -> 'Clash.Signal.Signal' a -> 'Clash.Signal.Signal' a -> 'Clash.Signal.Signal' a
-- @
--
-- A multiplexer. Given "@'mux' b t f@", output @t@ when @b@ is 'True', and @f@
-- when @b@ is 'False'.
mux :: Applicative f => f Bool -> f a -> f a -> f a
mux = liftA3 (\b t f -> if b then t else f)
{-# INLINE mux #-}

infix 4 .==.
-- | The above type is a generalization for:
--
-- @
-- __(.==.)__ :: 'Eq' a => 'Clash.Signal.Signal' a -> 'Clash.Signal.Signal' a -> 'Clash.Signal.Signal' 'Bool'
-- @
--
-- It is a version of ('==') that returns a 'Clash.Signal.Signal' of 'Bool'
(.==.) :: (Eq a, Applicative f) => f a -> f a -> f Bool
(.==.) = liftA2 (==)

infix 4 ./=.
-- | The above type is a generalization for:
--
-- @
-- __(./=.)__ :: 'Eq' a => 'Clash.Signal.Signal' a -> 'Clash.Signal.Signal' a -> 'Clash.Signal.Signal' 'Bool'
-- @
--
-- It is a version of ('/=') that returns a 'Clash.Signal.Signal' of 'Bool'
(./=.) :: (Eq a, Applicative f) => f a -> f a -> f Bool
(./=.) = liftA2 (/=)

infix 4 .<.
-- | The above type is a generalization for:
--
-- @
-- __(.<.)__ :: 'Ord' a => 'Clash.Signal.Signal' a -> 'Clash.Signal.Signal' a -> 'Clash.Signal.Signal' 'Bool'
-- @
--
-- It is a version of ('<') that returns a 'Clash.Signal.Signal' of 'Bool'
(.<.) :: (Ord a, Applicative f) => f a -> f a -> f Bool
(.<.) = liftA2 (<)

infix 4 .<=.
-- | The above type is a generalization for:
--
-- @
-- __(.<=.)__ :: 'Ord' a => 'Clash.Signal.Signal' a -> 'Clash.Signal.Signal' a -> 'Clash.Signal.Signal' 'Bool'
-- @
--
-- It is a version of ('<=') that returns a 'Clash.Signal.Signal' of 'Bool'
(.<=.) :: (Ord a, Applicative f) => f a -> f a -> f Bool
(.<=.) = liftA2 (<=)

infix 4 .>.
-- | The above type is a generalization for:
--
-- @
-- __(.>.)__ :: 'Ord' a => 'Clash.Signal.Signal' a -> 'Clash.Signal.Signal' a -> 'Clash.Signal.Signal' 'Bool'
-- @
--
-- It is a version of ('>') that returns a 'Clash.Signal.Signal' of 'Bool'
(.>.) :: (Ord a, Applicative f) => f a -> f a -> f Bool
(.>.) = liftA2 (>)

infix 4 .>=.
-- | The above type is a generalization for:
--
-- @
-- __(.>=.)__ :: 'Ord' a => 'Clash.Signal.Signal' a -> 'Clash.Signal.Signal' a -> 'Clash.Signal.Signal' 'Bool'
-- @
--
--  It is a version of ('>=') that returns a 'Clash.Signal.Signal' of 'Bool'
(.>=.) :: (Ord a, Applicative f) => f a -> f a -> f Bool
(.>=.) = liftA2 (>=)

instance Fractional a => Fractional (Signal dom a) where
  (/)          = liftA2 (/)
  recip        = fmap recip
  fromRational = signal# . fromRational

instance Arbitrary a => Arbitrary (Signal dom a) where
  arbitrary = liftA2 (:-) arbitrary arbitrary

instance CoArbitrary a => CoArbitrary (Signal dom a) where
  coarbitrary xs gen = do
    n <- arbitrary
    coarbitrary (take (abs n) (sample_lazy xs)) gen

-- | The above type is a generalization for:
--
-- @
-- __testFor__ :: 'Int' -> 'Clash.Signal.Signal' Bool -> 'Property'
-- @
--
-- @testFor n s@ tests the signal @s@ for @n@ cycles.
testFor :: Foldable f => Int -> f Bool -> Property
testFor n = property . and . take n . sample

-- * List \<-\> Signal conversion (not synthesizable)

-- | The above type is a generalization for:
--
-- @
-- __sample__ :: 'Clash.Signal.Signal' a -> [a]
-- @
--
-- Get an infinite list of samples from a 'Clash.Signal.Signal'
--
-- The elements in the list correspond to the values of the 'Clash.Signal.Signal'
-- at consecutive clock cycles
--
-- > sample s == [s0, s1, s2, s3, ...
--
-- __NB__: This function is not synthesizable
sample :: (Foldable f, Undefined a) => f a -> [a]
sample = foldr (\a b -> deepseqX a (a : b)) []

-- | The above type is a generalization for:
--
-- @
-- __sampleN__ :: Int -> 'Clash.Signal.Signal' a -> [a]
-- @
--
-- Get a list of @n@ samples from a 'Clash.Signal.Signal'
--
-- The elements in the list correspond to the values of the 'Clash.Signal.Signal'
-- at consecutive clock cycles
--
-- > sampleN 3 s == [s0, s1, s2]
--
-- __NB__: This function is not synthesizable
sampleN :: (Foldable f, Undefined a) => Int -> f a -> [a]
sampleN n = take n . sample

-- | Create a 'Clash.Signal.Signal' from a list
--
-- Every element in the list will correspond to a value of the signal for one
-- clock cycle.
--
-- >>> sampleN 2 (fromList [1,2,3,4,5])
-- [1,2]
--
-- __NB__: This function is not synthesizable
fromList :: Undefined a => [a] -> Signal dom a
fromList = Prelude.foldr (\a b -> deepseqX a (a :- b)) (errorX "finite list")

-- * Simulation functions (not synthesizable)

-- | Simulate a (@'Clash.Signal.Signal' a -> 'Clash.Signal.Signal' b@) function
-- given a list of samples of type @a@
--
-- >>> simulate (register systemClockGen resetGen enableGen 8) [1, 1, 2, 3]
-- [8,8,1,2,3...
-- ...
--
-- __NB__: This function is not synthesizable
simulate :: (Undefined a, Undefined b) => (Signal dom1 a -> Signal dom2 b) -> [a] -> [b]
simulate f = sample . f . fromList

-- | The above type is a generalization for:
--
-- @
-- __sample__ :: 'Clash.Signal.Signal' a -> [a]
-- @
--
-- Get an infinite list of samples from a 'Clash.Signal.Signal'
--
-- The elements in the list correspond to the values of the 'Clash.Signal.Signal'
-- at consecutive clock cycles
--
-- > sample s == [s0, s1, s2, s3, ...
--
-- __NB__: This function is not synthesizable
sample_lazy :: Foldable f => f a -> [a]
sample_lazy = foldr (:) []

-- | The above type is a generalization for:
--
-- @
-- __sampleN__ :: Int -> 'Clash.Signal.Signal' a -> [a]
-- @
--
-- Get a list of @n@ samples from a 'Clash.Signal.Signal'
--
-- The elements in the list correspond to the values of the 'Clash.Signal.Signal'
-- at consecutive clock cycles
--
-- > sampleN 3 s == [s0, s1, s2]
--
-- __NB__: This function is not synthesizable
sampleN_lazy :: Foldable f => Int -> f a -> [a]
sampleN_lazy n = take n . sample_lazy

-- | Create a 'Clash.Signal.Signal' from a list
--
-- Every element in the list will correspond to a value of the signal for one
-- clock cycle.
--
-- >>> sampleN 2 (fromList [1,2,3,4,5] :: Signal System Int)
-- [1,2]
--
-- __NB__: This function is not synthesizable
fromList_lazy :: [a] -> Signal dom a
fromList_lazy = Prelude.foldr (:-) (error "finite list")

-- * Simulation functions (not synthesizable)

-- | Simulate a (@'Clash.Signal.Signal' a -> 'Clash.Signal.Signal' b@) function
-- given a list of samples of type @a@
--
-- >>> simulate (register systemClockGen resetGen enableGen 8) [1, 1, 2, 3]
-- [8,8,1,2,3...
-- ...
--
-- __NB__: This function is not synthesizable
simulate_lazy :: (Signal dom1 a -> Signal dom2 b) -> [a] -> [b]
simulate_lazy f = sample_lazy . f . fromList_lazy
