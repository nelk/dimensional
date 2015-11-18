{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-} -- for Vector instances only
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Numeric.Units.Dimensional.Internal
(
  KnownVariant(..),
  Dimensional(..),
  type Unit, type Quantity, type SQuantity,
  siUnit, showIn,
  liftUntyped, liftUntyped2,
  liftUntypedQ, liftUntyped2Q
)
where

import Control.Applicative
import Control.DeepSeq
import Control.Monad (liftM)
import Data.Coerce (coerce)
import Data.Data
import Data.ExactPi
import qualified Data.ExactPi.TypeLevel as E
import Data.Monoid (Monoid(..))
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (Storable(..))
import GHC.Generics
import Numeric.Units.Dimensional.Dimensions
import Numeric.Units.Dimensional.Variants hiding (type (*))
import qualified Numeric.Units.Dimensional.Variants as V
import Numeric.Units.Dimensional.UnitNames hiding ((*), (/), (^), weaken, strengthen)
import qualified Numeric.Units.Dimensional.UnitNames.Internal as Name
import Numeric.Units.Dimensional.UnitNames.InterchangeNames (HasInterchangeName(..))
import qualified Data.Vector.Generic.Mutable as M
import qualified Data.Vector.Generic as G
import qualified Data.Vector.Unboxed.Base as U
import Prelude
  ( Show, Eq(..), Ord, Bounded(..), Num, Fractional, Functor
  , String, Maybe(..)
  , (.), ($), (++), (+), (/)
  , show, otherwise, undefined, error, fmap
  )

-- | A unit of measurement.
type Unit (m :: Metricality) = Dimensional ('DUnit m)

-- | A dimensional quantity.
type Quantity = SQuantity E.One

-- | A dimensional quantity, stored as an 'ExactPi'' multiple of its value in its dimension's SI coherent unit.
--
-- The name is an abbreviation for scaled quantity.
type SQuantity s = Dimensional ('DQuantity s)

-- | A physical quantity or unit.
--
-- We call this data type 'Dimensional' to capture the notion that the
-- units and quantities it represents have physical dimensions.
-- 
-- The type variable 'a' is the only non-phantom type variable and
-- represents the numerical value of a quantity or the scale (w.r.t.
-- SI units) of a unit. For SI units the scale will always be 1. For
-- non-SI units the scale is the ratio of the unit to the SI unit with
-- the same physical dimension.
--
-- Since 'a' is the only non-phantom type we were able to define
-- 'Dimensional' as a newtype, avoiding boxing at runtime.
class KnownVariant (v :: Variant) where
  -- | A dimensional value, either a 'Quantity' or a 'Unit', parameterized by its 'Dimension' and representation.
  data Dimensional v :: Dimension -> * -> *
  -- | A scale factor by which the numerical value of this dimensional value is implicitly multiplied.
  type ScaleFactor v :: E.ExactPi'
  extractValue :: Dimensional v d a -> (a, Maybe ExactPi)
  extractName :: Dimensional v d a -> Maybe (UnitName 'NonMetric)
  injectValue :: (Maybe (UnitName 'NonMetric)) -> (a, Maybe ExactPi) -> Dimensional v d a
  -- | Maps over the underlying representation of a dimensional value.
  -- The caller is responsible for ensuring that the supplied function respects the dimensional abstraction.
  -- This means that the function must preserve numerical values, or linearly scale them while preserving the origin.
  dmap :: (a1 -> a2) -> Dimensional v d a1 -> Dimensional v d a2

deriving instance Typeable Dimensional

instance (E.KnownExactPi s) => KnownVariant ('DQuantity s) where
  newtype Dimensional ('DQuantity s) d a = Quantity a
    deriving (Eq, Ord, Data, Generic, Generic1
#if MIN_VERSION_base(4,8,0)
     , Typeable -- GHC 7.8 doesn't support deriving this instance
#endif
    )
  type (ScaleFactor ('DQuantity s)) = s
  extractValue (Quantity x) = (x, Nothing)
  extractName _ = Nothing
  injectValue _ (x, _) = Quantity x
  dmap f (Quantity x) = Quantity (f x)

instance (Typeable m) => KnownVariant ('DUnit m) where
  data Dimensional ('DUnit m) d a = Unit !(UnitName m) !ExactPi !a
    deriving (Generic, Generic1
#if MIN_VERSION_base(4,8,0)
     , Typeable -- GHC 7.8 doesn't support deriving this instance
#endif
    )
  type (ScaleFactor ('DUnit m)) = E.One
  extractValue (Unit _ e x) = (x, Just e)
  extractName (Unit n _ _) = Just . Name.weaken $ n
  injectValue (Just n) (x, Just e) | Just n' <- relax n = Unit n' e x
                                   | otherwise          = error "Shouldn't be reachable. Needed a metric name but got a non-metric one."
  injectValue _        _ = error "Shouldn't be reachable. Needed to name a quantity."
  dmap f (Unit n e x) = Unit n e (f x)

-- GHC is somewhat unclear about why, but it won't derive this instance, so we give it explicitly.
instance (Bounded a) => Bounded (Quantity d a) where
  minBound = Quantity minBound
  maxBound = Quantity maxBound

instance HasInterchangeName (Unit m d a) where
  interchangeName (Unit n _ _) = interchangeName n

{-
Since quantities form a monoid under addition, but not under multiplication unless they are dimensionless,
we will define a monoid instance that adds.
-}

-- | 'Quantity's of a given 'Dimension' form a 'Monoid' under addition.
instance (Num a) => Monoid (SQuantity s d a) where
  mempty = Quantity 0
  mappend = liftUntyped2Q (+)

{-

= Dimensionless =

For dimensionless quantities pretty much any operation is applicable.
We provide this freedom by making 'Dimensionless' an instance of
'Functor'.
-}

instance (E.KnownExactPi s) => Functor (SQuantity s DOne) where
  fmap = dmap

instance (KnownDimension d) => HasDimension (Dimensional v d a) where
  dimension _ = dimension (Proxy :: Proxy d)

-- | A polymorphic 'Unit' which can be used in place of the coherent
-- SI base unit of any dimension. This allows polymorphic quantity
-- creation and destruction without exposing the 'Dimensional' constructor.
siUnit :: forall d a.(KnownDimension d, Num a) => Unit 'NonMetric d a
siUnit = Unit (baseUnitName $ dimension (Proxy :: Proxy d)) 1 1

instance NFData a => NFData (Quantity d a) -- instance is derived from Generic instance

instance Storable a => Storable (Quantity d a) where
  sizeOf _ = sizeOf (undefined::a)
  {-# INLINE sizeOf #-}
  alignment _ = alignment (undefined::a)
  {-# INLINE alignment #-}
  poke ptr = poke (castPtr ptr :: Ptr a) . coerce
  {-# INLINE poke #-}
  peek ptr = liftM Quantity (peek (castPtr ptr :: Ptr a))
  {-# INLINE peek #-}

{-
Instances for vectors of quantities.
-}
newtype instance U.Vector (Quantity d a)    =  V_Quantity {unVQ :: U.Vector a}
newtype instance U.MVector s (Quantity d a) = MV_Quantity {unMVQ :: U.MVector s a}
instance U.Unbox a => U.Unbox (Quantity d a)

instance (M.MVector U.MVector a) => M.MVector U.MVector (Quantity d a) where
  basicLength          = M.basicLength . unMVQ
  {-# INLINE basicLength #-}
  basicUnsafeSlice m n = MV_Quantity . M.basicUnsafeSlice m n . unMVQ
  {-# INLINE basicUnsafeSlice #-}
  basicOverlaps u v    = M.basicOverlaps (unMVQ u) (unMVQ v)
  {-# INLINE basicOverlaps #-}
  basicUnsafeNew       = liftM MV_Quantity . M.basicUnsafeNew
  {-# INLINE basicUnsafeNew #-}
  basicUnsafeRead v    = liftM Quantity . M.basicUnsafeRead (unMVQ v)
  {-# INLINE basicUnsafeRead #-}
  basicUnsafeWrite v i = M.basicUnsafeWrite (unMVQ v) i . coerce
  {-# INLINE basicUnsafeWrite #-}
#if MIN_VERSION_vector(0,11,0)
  basicInitialize      = M.basicInitialize . unMVQ
  {-# INLINE basicInitialize #-}
#endif

instance (G.Vector U.Vector a) => G.Vector U.Vector (Quantity d a) where
  basicUnsafeFreeze    = liftM V_Quantity  . G.basicUnsafeFreeze . unMVQ
  {-# INLINE basicUnsafeFreeze #-}
  basicUnsafeThaw      = liftM MV_Quantity . G.basicUnsafeThaw   . unVQ
  {-# INLINE basicUnsafeThaw #-}
  basicLength          = G.basicLength . unVQ
  {-# INLINE basicLength #-}
  basicUnsafeSlice m n = V_Quantity . G.basicUnsafeSlice m n . unVQ
  {-# INLINE basicUnsafeSlice #-}
  basicUnsafeIndexM v  = liftM Quantity . G.basicUnsafeIndexM (unVQ v)
  {-# INLINE basicUnsafeIndexM #-}

{-
We will conclude by providing a reasonable 'Show' instance for
quantities. The SI unit of the quantity is inferred
from its dimension.
-}
instance (KnownDimension d, Show a, Fractional a) => Show (Quantity d a) where
  show = showIn siUnit

-- | Shows the value of a 'Quantity' expressed in a specified 'Unit' of the same 'Dimension'.
showIn :: (KnownDimension d, Show a, Fractional a) => Unit m d a -> Quantity d a -> String
showIn (Unit n _ y) (Quantity x) | Name.weaken n == nOne = show (x / y)
                                 | otherwise             = (show (x / y)) ++ " " ++ (show n)

instance (KnownDimension d, Show a) => Show (Unit m d a) where
  show (Unit n e x) = "The unit " ++ show n ++ ", with value " ++ show e ++ " (or " ++ show x ++ ")"

-- Operates on a dimensional value using a unary operation on values, possibly yielding a Unit.
liftUntyped :: (KnownVariant v1, KnownVariant v2) => (ExactPi -> ExactPi) -> (a -> b) -> UnitNameTransformer -> (Dimensional v1 d1 a) -> (Dimensional v2 d2 b)
liftUntyped fe f nt x = let (x', e') = extractValue x
                            n = extractName x
                            n' = (liftA nt) n
                         in injectValue n' (f x', fmap fe e')

-- Operates on a dimensional value using a unary operation on values, yielding a Quantity.
liftUntypedQ :: (a -> a) -> SQuantity s1 d1 a -> SQuantity s2 d2 a
liftUntypedQ f (Quantity x) = Quantity (f x)

-- Combines two dimensional values using a binary operation on values, possibly yielding a Unit.
liftUntyped2 :: (KnownVariant v1, KnownVariant v2, KnownVariant (v1 V.* v2)) => (ExactPi -> ExactPi -> ExactPi) -> (a -> a -> a) -> UnitNameTransformer2 -> Dimensional v1 d1 a -> Dimensional v2 d2 a -> Dimensional (v1 V.* v2) d3 a
liftUntyped2 fe f nt x1 x2 = let (x1', e1') = extractValue x1
                                 (x2', e2') = extractValue x2
                                 n1 = extractName x1
                                 n2 = extractName x2
                                 n' = (liftA2 nt) n1 n2
                              in injectValue n' (f x1' x2', fe <$> e1' <*> e2')

-- Combines two dimensional values using a binary operation on values, yielding a Quantity.
liftUntyped2Q :: (a -> a -> a) -> SQuantity s1 d1 a -> SQuantity s2 d2 a -> SQuantity s3 d3 a
liftUntyped2Q f (Quantity x1) (Quantity x2) = Quantity (f x1 x2)
