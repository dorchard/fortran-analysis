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
{-# LANGUAGE TemplateHaskell, ImplicitParams, DeriveDataTypeable #-}


{- Provides various data types and type class instances for the Units extension -}

module Camfort.Specification.Units.Environment where

import qualified Data.Label
import Data.Label.Mono (Lens)
import Data.Label.Monadic hiding (modify)
import Control.Monad.State.Strict hiding (gets)
import Language.Fortran


import Data.Char
import Data.Data
import Data.List
import Data.Matrix


type EqualityConstrained = Bool

data Solver = LAPACK | Custom deriving (Show, Read, Eq, Data)
data AssumeLiterals = Poly | Unitless | Mixed deriving (Show, Read, Eq, Data)

{- Represents a constant unit expression (i.e. one without unit variables) for the RHSs of the Gaussian matrix.
    e.g. Unitful [("a", 2/3), ("b",2)] represents the linear term  2/3 log a + 2 log b
         UnitlessC marks unitless i.e., 1
-}
data UnitConstant = Unitful [(MeasureUnit, Rational)] | UnitlessC Rational deriving (Eq, Show)

-- Column of the Guassian matrix associated with a variable
newtype VarCol = VarCol Col deriving (Eq, Show)

-- Map from Variable names to their column paired with any column of their indices
--   e.g., for a(i,k) we have a map from 'a' to its column paired with
--       a two element list of the columns for 'i' and 'j'

newtype VarBinder = VarBinder (Variable, SrcSpan) deriving Show
type VarColEnv = [(VarBinder, (VarCol, [VarCol]))]

data UnitVarCategory = Literal EqualityConstrained | Temporary | Variable | Argument | Magic deriving (Eq, Show)



type DerivedUnitEnv = [(MeasureUnit, UnitConstant)]

type ProcedureNames = (String, Maybe Variable, [Variable])
type Procedure = (Maybe VarCol, [VarCol])
type ProcedureEnv = [(String, Procedure)]

type LinearSystem = (Matrix Rational, [UnitConstant])

type Row = Int
type Col = Int

type DebugInfo = [(Col, (SrcSpan, String))]

data UnitEnv = UnitEnv {
  _report              :: [String],
  _varColEnv           :: VarColEnv,
  _derivedUnitEnv      :: DerivedUnitEnv,
  _procedureEnv        :: ProcedureEnv,
  _calls               :: ProcedureEnv,
  _unitVarCats         :: [UnitVarCategory],
  _reorderedCols       :: [Int],
  _underdeterminedCols :: [Int],
  _linearSystem        :: LinearSystem,
  _debugInfo           :: DebugInfo,
  _tmpRowsAdded        :: [Int],
  _tmpColsAdded        :: [Int],
  _success             :: Bool,
  -- This part of the state is just for some evaluation metrics
  _evUnitsAdded        :: (Int, [String]),
  _evCriticals         :: [Int]
} deriving Show

emptyUnitEnv = UnitEnv { _report              = [],
                         _varColEnv          = [],
                         _derivedUnitEnv      = [],
                         _procedureEnv        = [],
                         _calls               = [],
                         _unitVarCats         = [Magic],
                         _reorderedCols       = [],
                         _underdeterminedCols = [],
                         _linearSystem        = (fromLists [[1]], [Unitful []]),
                         _debugInfo           = [],
                         _tmpRowsAdded        = [],
                         _tmpColsAdded        = [],
                         _success             = True,
                         ---
                         _evUnitsAdded        = (0, []),
                         _evCriticals         = []
                       }

Data.Label.mkLabels [''UnitEnv]

{- HELPERS -}

-- Update a list state by consing
infix 2 <<
(<<) :: MonadState f m => Lens (->) f [o] -> o -> m ()
(<<) lens o = lens =. (o:)

-- Update a list state by appending
infix 2 <<++
(<<++) lens o = lens =. (++ [o])


-- *** Operations on unit environments
addCol :: UnitVarCategory -> State UnitEnv Int
addCol category =
  do (matrix, vector) <- gets linearSystem
     let m = ncols matrix + 1
     linearSystem =: (extendTo 0 0 m matrix, vector)
     unitVarCats <<++ category
     tmpColsAdded << m
     return m

addRow :: State UnitEnv Int
addRow = addRow' (Unitful [])

addRow' :: UnitConstant -> State UnitEnv Int
addRow' uc =
  do (matrix, vector) <- gets linearSystem
     let n = nrows matrix + 1
     linearSystem =: (extendTo 0 n 0 matrix, vector ++ [uc])
     tmpRowsAdded << n
     return n

liftUnitEnv :: (Matrix Rational -> Matrix Rational) -> UnitEnv -> UnitEnv
liftUnitEnv f = Data.Label.modify linearSystem $ \(matrix, vector) -> (f matrix, vector)

extractUnit :: Attr a -> [State UnitEnv UnitConstant]
extractUnit attr = case attr of
                     MeasureUnit _ unit -> [convertUnit unit]
                     _ -> []

convertUnit :: MeasureUnitSpec a -> State UnitEnv UnitConstant
convertUnit (UnitProduct _ units) = convertUnits units
convertUnit (UnitQuotient _ units1 units2) = liftM2 (-) (convertUnits units1) (convertUnits units2)
convertUnit (UnitNone _) = return $ Unitful []

convertUnits :: [(MeasureUnit, Fraction a)] -> State UnitEnv UnitConstant
convertUnits units =
  foldl (+) (Unitful []) `liftM` sequence [convertSingleUnit unit (fromFraction f) | (unit, f) <- units]

convertSingleUnit :: MeasureUnit -> Rational -> State UnitEnv UnitConstant
convertSingleUnit unit f =
  do denv <- gets derivedUnitEnv
     let uc f' = Unitful [(unit, f')]
     case lookup unit denv of
       Just uc' -> return $ uc' * (fromRational f)
       Nothing  -> derivedUnitEnv << (unit, uc 1) >> return (uc f)

fromFraction :: Fraction a -> Rational
fromFraction (IntegerConst _ n) = fromInteger $ read n
fromFraction (FractionConst _ p q) = fromInteger (read p) / fromInteger (read q)
fromFraction (NullFraction _) = 1


resetTemps :: State UnitEnv ()
resetTemps = do tmpRowsAdded =: []
                tmpColsAdded =: []

--------------------------------------------
-- Lookup helpers

lookupCaseInsensitive :: String -> [(String, a)] -> Maybe a
lookupCaseInsensitive x m = let x' = map toUpper x in (find (\(k, v) -> (map toUpper k) == x') m) >>= (return . snd)

lookupWithoutSrcSpan :: Variable -> [(VarBinder, a)] -> Maybe a
lookupWithoutSrcSpan v env = snd `fmap` find f env
  where
    f (VarBinder (w, _), _) = map toUpper w == v'
    v'   = map toUpper v

lookupWithSrcSpan :: Variable -> SrcSpan -> [(VarBinder, a)] -> Maybe a
lookupWithSrcSpan v s env = snd `fmap` find f env
  where
    f (VarBinder (w, t), _) = map toUpper w == v' && s == t
    v'   = map toUpper v

---------------------------------------------

trim = filter $ \(unit, r) -> r /= 0

{- Treat 'UnitConstant's as numbers -}
instance Num UnitConstant where
  (Unitful u1) + (Unitful u2) = Unitful $ trim $ merge u1 u2
    where merge [] u2 = u2
          merge u1 [] = u1
          merge ((unit1, r1) : u1) ((unit2, r2) : u2)
            | unit1 == unit2 = (unit1, r1 + r2) : merge u1 u2
            | unit1 <  unit2 = (unit1, r1) : merge u1 ((unit2, r2) : u2)
            | otherwise      = (unit2, r2) : merge ((unit1, r1) : u1) u2
  (UnitlessC n1) + (UnitlessC n2) = UnitlessC (n1 + n2)
  (Unitful units) * (UnitlessC n) = Unitful $ trim [(unit, r * n) | (unit, r) <- units]
  (UnitlessC n) * (Unitful units) = Unitful $ trim [(unit, n * r) | (unit, r) <- units]
  (UnitlessC n1) * (UnitlessC n2) = UnitlessC (n1 * n2)
  negate (Unitful units) = Unitful [(unit, -r) | (unit, r) <- units]
  negate (UnitlessC n) = UnitlessC (-n)
  abs (Unitful units) = Unitful [(unit, abs r) | (unit, r) <- units]
  abs (UnitlessC n) = UnitlessC $ abs n
  signum (Unitful units) = Unitful [(unit, signum r) | (unit, r) <- units]
  signum (UnitlessC n) = UnitlessC $ signum n
  fromInteger = UnitlessC . fromInteger

{- Treat 'UnitConstant's as fractionals -}
instance Fractional UnitConstant where
  (Unitful units) / (UnitlessC n) = Unitful [(unit, r / n) | (unit, r) <- units]
  (UnitlessC n1) / (UnitlessC n2) = UnitlessC (n1 / n2)
  fromRational = UnitlessC . fromRational

data Consistency a = Ok a | Bad a Int (UnitConstant, [Rational]) deriving Show

efmap :: (a -> a) -> Consistency a -> Consistency a
efmap f (Ok x)      = Ok (f x)
efmap f (Bad x l msg) = Bad x l msg

ifDebug :: (?debug :: Bool, Monad m) => m a -> m ()
ifDebug e = if ?debug then e >> return () else return ()
