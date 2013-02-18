{- |
Module           : $Header$
Description      : The interface to a symbolic backend
Stability        : provisional
Point-of-contact : jstanley
-}

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes       #-}
{-# LANGUAGE TypeFamilies     #-}

module Verifier.LLVM.Backend
  ( module Verifier.LLVM.Backend
  , BitWidth
  , IntArithOp(..)
  , TypedExpr(..)
  , structFieldOffset
  , GEPOffset(..)
  ) where

import Data.Bits (testBit)
import           Text.PrettyPrint.HughesPJ
import qualified Text.LLVM.AST   as L
import Data.LLVM.Symbolic.AST

-- | SBETerm yields the type used to represent terms in particular SBE interface
-- implementation.
type family SBETerm (sbe :: * -> *)

-- | SBEClosedTerm yields the newtype-wrapped, isomorphic-to-tuple type used to
-- represent SBE interface terms together with any SBE-specific state necessary
-- to perform certain operations (e.g. constant projection/injection) on those
-- terms.
type family SBEClosedTerm (sbe :: * -> *)

-- | SBEMemory yields the type used to represent the memory in a particular SBE
-- interface implementation.
type family SBEMemory (sbe :: * -> *)

-- | A result returned by an operation that is partial on symbolic operations.
-- The first element is the verification condition needed to show the result
-- is valie, result, while the second is the verification condition
-- needed to show the result is valid.
type SBEPartialResult m r  = (SBETerm m, r)

-- | Represents a partial result of trying to obtain a concrete value from
-- a symbolic term.
data LookupSymbolResult
  = Result L.Symbol -- ^ The definition associated with the address.
  | Indeterminate -- ^ The value of the operation could not be determined.
  | Invalid -- ^ The operation failed, because it had an invalid value.
  deriving Show

-- | Result returned by @stackAlloca@ (defined below).
data StackAllocaResult t m
  -- | @SAResult c p m@ is returned when allocation succeeded. @c@ is a symbolic
  -- path constraint that the allocation must satisfy for allocation to have
  -- succeeded, @m@ is the new memory state, and @p@ is a @ptr@ to the newly
  -- allocated space.  @c@ is false if the allocation failed due to
  -- insufficient space.
  = SAResult t t m
  -- | Returned if stackAlloca given a symbolic length and the implementation
  -- does not support this.
  | SASymbolicCountUnsupported

-- | Result returned by @heapAlloc@ (defined below). Currently
-- isomorphic to StackAllocResult, but that might change.
data HeapAllocResult t m
  -- | @HAResult c p m@ is returned when allocation succeeded. @c@
  -- is a symbolic path constraint that the allocation must satisfy
  -- for allocation to have succeeded, @m@ is the new memory state,
  -- and @p@ is a @ptr@ to the newly
  -- allocated space. @c@ is false if the allocation failed due to
  -- insufficient space.
  = HAResult t t m
  -- | Returned if heapAlloc given a symbolic length and the
  -- implementation does not support this.
  | HASymbolicCountUnsupported

data SBE m = SBE
  {
    ----------------------------------------------------------------------------
    -- Term creation, operators
        
    -- | @termBool b@ creates a term representing the constant boolean
    -- (1-bit) value @b@
    termBool :: Bool -> m (SBETerm m)

    -- | @termInt w n@ creates a term representing the constant @w@-bit
    -- value @n@
  , termInt  :: BitWidth -> Integer -> m (SBETerm m)

    -- | @freshInt w@ creates a term representing a symbolic @w@-bit value
  , freshInt :: Int -> m (SBETerm m)
    
    -- | Create an SBE term for the given concrete floating point value.
  , termDouble :: Double -> m (SBETerm m)
  
    -- | Create an SBE term for the given concrete floating point value.
  , termFloat :: Float -> m (SBETerm m)
    
    -- | @termArray tp ts@ creates a term representing an array with element terms
    -- @ts@ (which must be nonempty).  Each element must have type tp.  
  , termArray :: L.Type -> [SBETerm m] -> m (SBETerm m)

    -- | Create an struct of terms, which may have different types.
  , termStruct :: [L.Typed (SBETerm m)] -> m (SBETerm m)

    -- | @termDecomp tys t@ decomposes the given term into @(length tys)@ terms,
    --  with each taking their type from the corresponding element of @tys@.
  , termDecomp :: [L.Type] -> SBETerm m -> m [L.Typed (SBETerm m)]

    ----------------------------------------------------------------------------
    -- Term operator application

    -- | @applyIte a b c@ creates an if-then-else term
  , applyIte    :: L.Type -> SBETerm m -> SBETerm m -> SBETerm m -> m (SBETerm m)
    -- | @applyBNot @a@ performs negation of a boolean term
  , applyBNot :: SBETerm m -> m (SBETerm m)
    -- | Perform addition with overflow, returning carry bit as a 1-bit integer, and result.
  , applyUAddWithOverflow :: BitWidth -> SBETerm m -> SBETerm m -> m (SBETerm m, SBETerm m)

    -- | Evaluate a typed expression.
  , applyTypedExpr :: TypedExpr (SBETerm m) -> m (SBETerm m)

    ----------------------------------------------------------------------------
    -- Term miscellany

  , closeTerm   :: SBETerm m -> SBEClosedTerm m
  , prettyTermD :: SBETerm m -> Doc
    -- | Interpret the term as a concrete boolean if it can be.
  , asBool :: SBETerm m -> Maybe Bool
    -- | Interpret the term as a concrete unsigned integer if it can be.
    -- The first int is the bitwidth.
  , asUnsignedInteger :: SBETerm m -> Maybe (Int,Integer)
    ----------------------------------------------------------------------------
    -- Memory model interface

    -- | @memDump h@ prints the contents of the memory model; the first
    -- parameter optionally constrains address ranges.
  , memDump :: SBEMemory m -> Maybe [(Integer, Integer)] -> m ()

    -- | @memLoad m p@ returns a pair @(c,v)@ where @v@ denotes the value at
    -- address @p@ in memory @m@, and @c@ denotes an additional path constraint
    -- that ensures the address @p@ is a valid memory location in @m@.
    -- In other words, @p@ is a valid memory location if @c@ is true.
  , memLoad :: SBEMemory m
            -> L.Typed (SBETerm m)
            -> m (SBEPartialResult m (SBETerm m))
    -- | @memStore m v p@ returns a pair @(c,m')@ where @m'@ denotes the memory
    -- obtained by storing value @v@ at address @p@, and @c@ denotes an
    -- additional path constraint that ensures the address @p@ is a valid memory
    -- location in @m@.
  , memStore :: SBEMemory m
             -> L.Typed (SBETerm m)
             -> SBETerm m
             -> m (SBEPartialResult m (SBEMemory m))
    -- | @memAddDefine mem d blocks@ adds a definition of @d@ with block
    -- labels @blocks@ to the memory @mem@ and returns a pointer to
    -- the definition, and updated memory if space is available.  If space
    -- is unavailable, then this returns nothing.
    -- It is undefined to call this function with a symbol that has already
    -- been defined in the memory.
  , memAddDefine :: SBEMemory m
                 -> L.Symbol
                 -> [L.BlockLabel]
                 -> m (Maybe (SBETerm m, SBEMemory m))
    -- | @memInitGlobal mem data@ attempts to write @data@ to a newly
    -- allocated region of memory in address space for globals.  If
    -- space is available, returns a pointer to the region
    -- and updated memory.  Otherwise returns @Nothing@.
  , memInitGlobal :: SBEMemory m
                  -> L.Typed (SBETerm m)
                  -> m (Maybe (SBETerm m, SBEMemory m))
    -- | @codeBlockAddress mem d l@ returns the address of basic block with
    -- label @l@ in definition @d@.
  , codeBlockAddress :: SBEMemory m -> L.Symbol -> L.BlockLabel -> m (SBETerm m)
    -- | @codeLookupSymbol ptr@ returns the symbol at the given address.
    -- Lookup may fail if the pointer does not point to a symbol, or if
    -- the pointer is a symbolic value without a clear meaning.
    -- TODO: Consider moving this function to the symbolic simulator.
  , codeLookupSymbol :: SBEMemory m -> SBETerm m -> m LookupSymbolResult
    -- | @stackAlloca h tp i align@ allocates memory on the stack for the given
    -- @i@ elements with the type @tp@ with an address aligned at a @2^align@
    -- byte boundary.
  , stackAlloca :: SBEMemory m
                -> L.Type
                -> L.Typed (SBETerm m)
                -> Int
                -> m (StackAllocaResult (SBETerm m) (SBEMemory m))
    -- | @stackPushFrame mem@ returns the memory obtained by pushing a new
    -- stack frame to @mem@.
  , stackPushFrame :: SBEMemory m -> m (SBEPartialResult m (SBEMemory m))
    -- | @stackPushFrame mem@ returns the memory obtained by popping a new
    -- stack frame from @mem@.
  , stackPopFrame :: SBEMemory m -> m (SBEMemory m)
    -- | @heapAlloc h tp i align@ allocates memory in the heap for the given
    -- @i@ elements with the type @tp@ with an address aligned at a @2^align@
    -- byte boundary.
  , heapAlloc :: SBEMemory m
              -> L.Type
              -> L.Typed (SBETerm m)
              -> Int
              -> m (HeapAllocResult (SBETerm m) (SBEMemory m))
    -- | @memcpy mem dst src len align@ copies @len@ bytes from @src@ to @dst@,
    -- both of which must be aligned according to @align@ and must refer to
    -- non-overlapping regions.
  , memCopy :: SBEMemory m
            -> SBETerm m -- ^ Destination pointer
            -> SBETerm m -- ^ Source pointer
            -> SBETerm m -- ^ Number of bytes to copy
            -> SBETerm m -- ^ Alignment in bytes
            -> m (SBEPartialResult m (SBEMemory m))
    -- | @memPushMerge mem@ returns a memory with an intra-procedural merge frame
    -- pushed.  Merge frames should have no impact on the semantics of the memory,
    -- but let the memory modify it's behavior based on when it may be shared
    -- across multiple symbolic path executions.
  , memPushMergeFrame :: SBEMemory m -> m (SBEMemory m)
    -- | @memPopMerge mem@ returns a memory with the top merge frame removed.
  , memPopMergeFrame :: SBEMemory m -> m (SBEMemory m)
    -- | @memMerge c t f@ returns a memory that corresponds to @t@ if @c@ is
    -- true and @f@ otherwise.  The memory should have the same number of stack
    -- and merge frames.
  , memMerge :: SBETerm m -> SBEMemory m -> SBEMemory m -> m (SBEMemory m)

    ----------------------------------------------------------------------------
    -- Output functions

    -- | @writeAiger f ts@ writes an AIG reprsentation of (juxtaposed) @ts@ into
    -- file @f@ in the Aiger format.
  , writeAiger :: String -> [SBETerm m] -> m ()

    -- | @writeCnf f t@ writes a CNF representation of @t /= 0@ into
    -- file @f@.
  , writeCnf :: String -> SBETerm m -> m [Int]

    -- | @evalAiger inps t@ evaluates an AIG with the given concrete inputs;
    -- result is always a concrete term.
  , evalAiger :: [Bool] -> SBETerm m -> m (SBETerm m)
    -- | Run sbe computation in IO.
  , sbeRunIO :: forall v . m v -> IO v 
  }

-- | Return conjunction of two terms.
applyAnd :: SBE m -> SBETerm m -> SBETerm m -> m (SBETerm m)
applyAnd sbe x y = applyTypedExpr sbe (IntArith And Nothing 1 x y)

applySub :: SBE m -> OptVectorLength -> BitWidth -> SBETerm m -> SBETerm m -> m (SBETerm m)
applySub sbe mn w x y = applyTypedExpr sbe (IntArith (Sub False False) mn w x y)
 
-- | Return predicate indicating if two terms are equal.
applyIEq :: SBE m -> BitWidth -> SBETerm m -> SBETerm m -> m (SBETerm m)
applyIEq sbe w x y = applyTypedExpr sbe (IntCmp L.Ieq Nothing w x y)

applyIne :: SBE m -> BitWidth -> SBETerm m -> SBETerm m -> m (SBETerm m)
applyIne sbe w x y = applyTypedExpr sbe (IntCmp L.Ine Nothing w x y)

-- | Interpret the term as a concrete signed integer if it can be.
asSignedInteger :: SBE m -> SBETerm m -> Maybe (Int,Integer)
asSignedInteger sbe t = s2u `fmap` (asUnsignedInteger sbe t :: Maybe (Int, Integer))
  where s2u (0,v) = (0,v)  
        s2u (w,v) | v `testBit` (w-1) = (w,v - 2^w) 
                  | otherwise = (w,v)

-- | @applySExt iw rw t@ assumes that @iw < rw@, and sign extends an
-- integer @t@ with @iw@ bits to an integer with @rw@ bits.
applySExt :: SBE m -> BitWidth -> BitWidth -> SBETerm m -> m (SBETerm m)
applySExt sbe iw rw t = applyTypedExpr sbe (SExt iw t rw)