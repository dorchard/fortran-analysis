{-
   Copyright 2016, Dominic Orchard, Andrew Rice, Mistral Contrastin, Matthew Danish

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
-}

{-

This files gives an executable implementation of the model for
abstract stencil specifications. This model is used to drive both
the specification checking and program synthesis features.

-}

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE StandaloneDeriving #-}

module Camfort.Specification.Stencils.LatticeModel ( Interval(..)
                                                   , Bound(..)
                                                   , Offsets(..)
                                                   , UnionNF(..)
                                                   , ioCompare
                                                   , Approximation(..)
                                                   , lowerBound, upperBound
                                                   , fromExact
                                                   , Multiplicity(..)
                                                   , Peelable(..)
                                                   ) where

import qualified Control.Monad as CM

import           Algebra.Lattice
import           Data.Semigroup
import qualified Data.List.NonEmpty as NE
import qualified Data.Set as S
import           Data.Foldable
import           Data.SBV
import           Data.Data
import           Data.Typeable

import qualified Camfort.Helpers.Vec as V

-- Utility container
class Container a where
  type MemberTyp a
  type CompTyp a

  member :: MemberTyp a -> a -> Bool
  compile :: a -> (CompTyp a -> SBool)

--------------------------------------------------------------------------------
-- Arbitrary sets representing offsets
--------------------------------------------------------------------------------

data Offsets =
    Offsets (S.Set Int64)
  | SetOfIntegers
  deriving Eq

instance Container Offsets where
  type MemberTyp Offsets = Int64
  type CompTyp Offsets = SInt64

  member i (Offsets s) = i `S.member` s
  member _ _ = True

  compile (Offsets s) i = i `sElem` map fromIntegral (S.toList s)
  compile SetOfIntegers _ = true

instance JoinSemiLattice Offsets where
  (Offsets s) \/ (Offsets s') = Offsets $ s `S.union` s'
  _ \/ _ = SetOfIntegers

instance MeetSemiLattice Offsets where
  (Offsets s) /\ (Offsets s') = Offsets $ s `S.intersection` s'
  off@Offsets{} /\ _ = off
  _ /\ o = o

instance Lattice Offsets

instance BoundedJoinSemiLattice Offsets where
  bottom = Offsets S.empty

instance BoundedMeetSemiLattice Offsets where
  top = SetOfIntegers

instance BoundedLattice Offsets

--------------------------------------------------------------------------------
-- Interval as defined in the paper
--------------------------------------------------------------------------------

data Bound = Arbitrary | Standard

-- | Interval data structure assumes the following:
-- 1. The first num. param. is less than the second;
-- 2. For holed intervals, first num. param. <= 0 <= second num. param.;
data Interval a where
  IntervArbitrary :: Int64 -> Int64 -> Interval Arbitrary
  IntervHoled     :: Int64 -> Int64 -> Bool -> Interval Standard
  IntervInfinite  :: Interval Standard

deriving instance Eq (Interval a)

data Elongated = Elongated (Interval Standard) | Original (Interval Standard)

toHoledInterv :: Interval Arbitrary -> Elongated
toHoledInterv (IntervArbitrary a b)
  | a > b = error
    "Interval condition violated: lower bound is bigger than the upper bound."
  | a <=  0, b >=  0 = Original  $ IntervHoled a b True
  | a <= -1, b == -1 = Original  $ IntervHoled a 0 False
  | a ==  1, b >=  1 = Original  $ IntervHoled 0 b False
  | a >   1, b >   1 = Elongated $ IntervHoled 0 b False
  | a <  -1, b <  -1 = Elongated $ IntervHoled a 0 False

instance Container (Interval Standard) where
  type MemberTyp (Interval Standard) = Int64
  type CompTyp (Interval Standard) = SInt64

  member 0 (IntervHoled _ _ b) = b
  member i (IntervHoled a b _) = i >= a && i <= b
  member _ _ = True

  compile (IntervHoled i1 i2 b) i
    | b = inRange i range
    | otherwise = inRange i range &&& i ./= 0
    where
      range = (fromIntegral i1, fromIntegral i2)
  compile IntervInfinite _ = true

instance JoinSemiLattice (Interval Standard) where
  (IntervHoled lb ub noHole) \/ (IntervHoled lb' ub' noHole') =
    IntervHoled (min lb lb') (max ub ub') (noHole || noHole')
  _ \/ _ = top

instance MeetSemiLattice (Interval Standard) where
  (IntervHoled lb ub noHole) /\ (IntervHoled lb' ub' noHole') =
    IntervHoled (max lb lb') (min ub ub') (noHole && noHole')
  int@IntervHoled{} /\ _ = int
  _ /\ int = int

instance Lattice (Interval Standard)

instance BoundedJoinSemiLattice (Interval Standard) where
  bottom = IntervHoled 0 0 False

instance BoundedMeetSemiLattice (Interval Standard) where
  top = IntervInfinite

instance BoundedLattice (Interval Standard)

--------------------------------------------------------------------------------
-- Union of cartesian products normal form
--------------------------------------------------------------------------------

type UnionNF n a = NE.NonEmpty (V.Vec n a)

instance Container a => Container (UnionNF n a) where
  type MemberTyp (UnionNF n a) = V.Vec n (MemberTyp a)
  type CompTyp (UnionNF n a) = V.Vec n (CompTyp a)
  member is = any (member' is)
    where
      member' is space = and $ V.zipWith member is space

  compile spaces is = foldr1 (|||) $ NE.map (`compile'` is) spaces
    where
      compile' space is =
        foldr' (\(set, i) -> (&&&) $ compile set i) true $ V.zip space is

instance JoinSemiLattice (UnionNF n a) where
  oi \/ oi' = oi <> oi'

instance BoundedLattice a => MeetSemiLattice (UnionNF n a) where
  (/\) = CM.liftM2 (V.zipWith (/\))

instance BoundedLattice a => Lattice (UnionNF n a)

ioCompare :: forall a b n . ( Container a,          Container b
                            , MemberTyp a ~ Int64,  MemberTyp b ~ Int64
                            , CompTyp a ~ SInt64,   CompTyp b ~ SInt64
                            )
          => UnionNF n a -> UnionNF n b -> IO Ordering
ioCompare oi oi' = do
    thmRes <- prove pred
    if modelExists thmRes
      then do
        ce <- counterExample thmRes
        case V.fromList ce of
          V.VecBox cev ->
            case V.proveEqSize (NE.head oi) cev of
              Just V.ReflEq ->
                -- TODO: The bit below is defensive programming the second member
                -- check should not be necessary unless the counter example is
                -- bogus (it shouldn't be). Delete if it adversely effects the
                -- performance.
                return $
                  if cev `member` oi
                    then GT
                    else
                      if cev `member` oi'
                        then LT
                        else error "Impossible: counter example is in neither of the oeprands"
      else return EQ
  where
    counterExample :: ThmResult -> IO [ Int64 ]
    counterExample thmRes =
      case getModel thmRes of
        Right (False, ce) -> return ce
        Right (True, _) -> fail "Returned probable model."
        Left str -> fail str

    pred :: Predicate
    pred = do
      freeVars <- (mkFreeVars . dimensionality) oi :: Symbolic [ SInt64 ]
      case V.fromList freeVars of
        V.VecBox freeVarVec ->
          case V.proveEqSize (NE.head oi) freeVarVec of
            Just V.ReflEq -> return $ compile oi freeVarVec .== compile oi' freeVarVec
            Nothing -> fail "Impossible: Length free variables doesn't match that of the union parameter." :: Symbolic SBool
    dimensionality = V.length . NE.head

--------------------------------------------------------------------------------
-- Injections for multiplicity and exactness
--------------------------------------------------------------------------------

data Approximation a = Exact a | Bound (Maybe a) (Maybe a)
  deriving (Eq, Show, Functor, Data, Typeable)

fromExact :: Approximation a -> a
fromExact (Exact a) = a
fromExact _ = error "Can't retrieve from bounded as if it was exact."

lowerBound :: Approximation a -> a
lowerBound (Bound (Just a) _) = a
lowerBound (Bound Nothing _) = error "Approximation doesn't have a lower bound."
lowerBound (Exact a) = a

upperBound :: Approximation a -> a
upperBound (Bound _ (Just a)) = a
upperBound (Bound _ Nothing) = error "Approximation doesn't have a upper bound."
upperBound (Exact a) = a

class Peelable a where
  peel :: a b -> b

data Multiplicity a = Mult a | Once a
  deriving (Eq, Show, Functor, Data, Typeable)

instance Peelable Multiplicity where
  peel (Mult a) = a
  peel (Once a) = a

{-
data Approximation a = Exact a | Lower a | Upper a
  deriving (Eq, Show, Functor, Data, Typeable)

instance Peelable Approximation where
  peel (Exact a) = a
  peel (Lower a) = a
  peel (Upper a) = a
-}
