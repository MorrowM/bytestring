{-# LANGUAGE CPP, ForeignFunctionInterface, BangPatterns #-}
{-# LANGUAGE UnliftedFFITypes, MagicHash,
            UnboxedTuples #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE PatternSynonyms, ViewPatterns #-}
{-# LANGUAGE Unsafe #-}
{-# LANGUAGE TemplateHaskellQuotes #-}
{-# OPTIONS_HADDOCK not-home #-}

-- |
-- Module      : Data.ByteString.Internal.Type
-- Copyright   : (c) Don Stewart 2006-2008
--               (c) Duncan Coutts 2006-2012
-- License     : BSD-style
-- Maintainer  : dons00@gmail.com, duncan@community.haskell.org
-- Stability   : unstable
-- Portability : non-portable
--
-- The 'ByteString' type, its instances, and whatever related
-- utilities the bytestring developers see fit to use internally.
--
module Data.ByteString.Internal.Type (

        -- * The @ByteString@ type and representation
        ByteString
        ( BS
        , PS -- backwards compatibility shim
        ),

        StrictByteString,

        -- * Internal indexing
        findIndexOrLength,

        -- * Conversion with lists: packing and unpacking
        packBytes, packUptoLenBytes, unsafePackLenBytes,
        packChars, packUptoLenChars, unsafePackLenChars,
        unpackBytes, unpackAppendBytesLazy, unpackAppendBytesStrict,
        unpackChars, unpackAppendCharsLazy, unpackAppendCharsStrict,
        unsafePackAddress, unsafePackLenAddress,
        unsafePackLiteral, unsafePackLenLiteral,

        -- * Low level imperative construction
        empty,
        createFp,
        createFpUptoN,
        createFpUptoN',
        createFpAndTrim,
        createFpAndTrim',
        unsafeCreateFp,
        unsafeCreateFpUptoN,
        unsafeCreateFpUptoN',
        create,
        createUptoN,
        createUptoN',
        createAndTrim,
        createAndTrim',
        unsafeCreate,
        unsafeCreateUptoN,
        unsafeCreateUptoN',
        mallocByteString,

        -- * Conversion to and from ForeignPtrs
        mkDeferredByteString,
        fromForeignPtr,
        toForeignPtr,
        fromForeignPtr0,
        toForeignPtr0,

        -- * Utilities
        nullForeignPtr,
        peekFp,
        pokeFp,
        peekFpByteOff,
        pokeFpByteOff,
        minusForeignPtr,
        memcpyFp,
        deferForeignPtrAvailability,
        unsafeDupablePerformIO,
        checkedAdd,

        -- * Standard C Functions
        c_strlen,
        c_free_finalizer,

        memchr,
        memcmp,
        memcpy,
        memset,

        -- * cbits functions
        c_reverse,
        c_intersperse,
        c_maximum,
        c_minimum,
        c_count,
        c_sort,

        -- * Chars
        w2c, c2w, isSpaceWord8, isSpaceChar8,

        -- * Deprecated and unmentionable
        accursedUnutterablePerformIO,

        -- * Exported compatibility shim
        plusForeignPtr,
        unsafeWithForeignPtr
  ) where

import Prelude hiding (concat, null)
import qualified Data.List as List

import Foreign.ForeignPtr       (ForeignPtr, withForeignPtr)
import Foreign.Ptr              (Ptr, FunPtr, plusPtr)
import Foreign.Storable         (Storable(..))
import Foreign.C.Types          (CInt(..), CSize(..))
import Foreign.C.String         (CString)
import Foreign.Marshal.Utils

#if MIN_VERSION_base(4,13,0)
import Data.Semigroup           (Semigroup (sconcat, stimes))
#else
import Data.Semigroup           (Semigroup ((<>), sconcat, stimes))
#endif
import Data.List.NonEmpty       (NonEmpty ((:|)))

import Control.DeepSeq          (NFData(rnf))

import Data.String              (IsString(..))

import Control.Exception        (assert)

import Data.Bits                ((.&.))
import Data.Char                (ord)
import Data.Word

import Data.Data                (Data(..), mkNoRepType)

import GHC.Base                 (nullAddr#,realWorld#,unsafeChr)
import GHC.Exts                 (IsList(..), Addr#, minusAddr#)
import GHC.CString              (unpackCString#)
import GHC.Magic                (runRW#, lazy)

import GHC.IO                   (IO(IO))
import GHC.ForeignPtr           (ForeignPtr(ForeignPtr)
#if __GLASGOW_HASKELL__ < 900
                                , newForeignPtr_
#endif
                                , mallocPlainForeignPtrBytes)

#if MIN_VERSION_base(4,10,0)
import GHC.ForeignPtr           (plusForeignPtr)
#else
import GHC.Prim                 (plusAddr#)
#endif

#if __GLASGOW_HASKELL__ >= 811
import GHC.CString              (cstringLength#)
import GHC.ForeignPtr           (ForeignPtrContents(FinalPtr))
#else
import GHC.Ptr                  (Ptr(..))
#endif

import GHC.Types                (Int (..))

#if MIN_VERSION_base(4,15,0)
import GHC.ForeignPtr           (unsafeWithForeignPtr)
#endif

import qualified Language.Haskell.TH.Lib as TH
import qualified Language.Haskell.TH.Syntax as TH

#if !MIN_VERSION_base(4,15,0)
unsafeWithForeignPtr :: ForeignPtr a -> (Ptr a -> IO b) -> IO b
unsafeWithForeignPtr = withForeignPtr
#endif

-- CFILES stuff is Hugs only
{-# CFILES cbits/fpstring.c #-}

#if !MIN_VERSION_base(4,10,0)
-- |Advances the given address by the given offset in bytes.
--
-- The new 'ForeignPtr' shares the finalizer of the original,
-- equivalent from a finalization standpoint to just creating another
-- reference to the original. That is, the finalizer will not be
-- called before the new 'ForeignPtr' is unreachable, nor will it be
-- called an additional time due to this call, and the finalizer will
-- be called with the same address that it would have had this call
-- not happened, *not* the new address.
plusForeignPtr :: ForeignPtr a -> Int -> ForeignPtr b
plusForeignPtr (ForeignPtr addr guts) (I# offset) = ForeignPtr (plusAddr# addr offset) guts
{-# INLINE [0] plusForeignPtr #-}
{-# RULES
"ByteString plusForeignPtr/0" forall fp .
   plusForeignPtr fp 0 = fp
 #-}
#endif

minusForeignPtr :: ForeignPtr a -> ForeignPtr b -> Int
minusForeignPtr (ForeignPtr addr1 _) (ForeignPtr addr2 _)
  = I# (minusAddr# addr1 addr2)

peekFp :: Storable a => ForeignPtr a -> IO a
peekFp fp = unsafeWithForeignPtr fp peek

pokeFp :: Storable a => ForeignPtr a -> a -> IO ()
pokeFp fp val = unsafeWithForeignPtr fp $ \p -> poke p val

peekFpByteOff :: Storable a => ForeignPtr a -> Int -> IO a
peekFpByteOff fp off = unsafeWithForeignPtr fp $ \p ->
  peekByteOff p off

pokeFpByteOff :: Storable a => ForeignPtr b -> Int -> a -> IO ()
pokeFpByteOff fp off val = unsafeWithForeignPtr fp $ \p ->
  pokeByteOff p off val

-- | Most operations on a 'ByteString' need to read from the buffer
-- given by its @ForeignPtr Word8@ field.  But since most operations
-- on @ByteString@ are (nominally) pure, their implementations cannot
-- see the IO state thread that was used to initialize the contents of
-- that buffer.  This means that under some circumstances, these
-- buffer-reads may be executed before the writes used to initialize
-- the buffer are executed, with unpredictable results.
--
-- 'deferForeignPtrAvailability' exists to help solve this problem.
-- At runtime, a call @'deferForeignPtrAvailability' x@ is equivalent
-- to @pure $! x@, but the former is more opaque to the simplifier, so
-- that reads from the pointer in its result cannot be executed until
-- the @'deferForeignPtrAvailability' x@ call is complete.
--
-- The opaque bits evaporate during CorePrep, so using
-- 'deferForeignPtrAvailability' incurs no direct overhead.
--
-- @since 0.11.5.0
deferForeignPtrAvailability :: ForeignPtr a -> IO (ForeignPtr a)
deferForeignPtrAvailability (ForeignPtr addr0# guts) = IO $ \s0 ->
  case lazy runRW# (\_ -> (# s0, addr0# #)) of
    (# s1, addr1# #) -> (# s1, ForeignPtr addr1# guts #)

-- | Variant of 'fromForeignPtr0' that calls 'deferForeignPtrAvailability'
--
-- @since 0.11.5.0
mkDeferredByteString :: ForeignPtr Word8 -> Int -> IO ByteString
mkDeferredByteString fp len = do
  deferredFp <- deferForeignPtrAvailability fp
  pure $! BS deferredFp len

unsafeDupablePerformIO :: IO a -> a
-- Why does this exist? In base-4.15.1.0 until at least base-4.18.0.0,
-- the version of unsafeDupablePerformIO in base prevents unboxing of
-- its results with an opaque call to GHC.Exts.lazy, for reasons described
-- in Note [unsafePerformIO and strictness] in GHC.IO.Unsafe. (See
-- https://hackage.haskell.org/package/base-4.18.0.0/docs/src/GHC.IO.Unsafe.html#line-30 .)
-- Even if we accept the (very questionable) premise that the sort of
-- function described in that note should work, we expect no such
-- calls to be made in the context of bytestring.  (And we really want
-- unboxing!)
unsafeDupablePerformIO (IO act) = case runRW# act of (# _, res #) -> res



-- -----------------------------------------------------------------------------

-- | A space-efficient representation of a 'Word8' vector, supporting many
-- efficient operations.
--
-- A 'ByteString' contains 8-bit bytes, or by using the operations from
-- "Data.ByteString.Char8" it can be interpreted as containing 8-bit
-- characters.
--
data ByteString = BS {-# UNPACK #-} !(ForeignPtr Word8) -- payload
                     {-# UNPACK #-} !Int                -- length
                     -- ^ @since 0.11.0.0

-- | Type synonym for the strict flavour of 'ByteString'.
--
-- @since 0.11.2.0
type StrictByteString = ByteString

-- |
-- @'PS' foreignPtr offset length@ represents a 'ByteString' with data
-- backed by a given @foreignPtr@, starting at a given @offset@ in bytes
-- and of a specified @length@.
--
-- This pattern is used to emulate the legacy 'ByteString' data
-- constructor, so that pre-existing code generally doesn't need to
-- change to benefit from the simplified 'BS' constructor and can
-- continue to function unchanged.
--
-- /Note:/ Matching with this constructor will always be given a 0 offset,
-- as the base will be manipulated by 'plusForeignPtr' instead.
--
pattern PS :: ForeignPtr Word8 -> Int -> Int -> ByteString
pattern PS fp zero len <- BS fp ((0,) -> (zero, len)) where
  PS fp o len = BS (plusForeignPtr fp o) len
#if __GLASGOW_HASKELL__ >= 802
{-# COMPLETE PS #-}
#endif

instance Eq  ByteString where
    (==)    = eq

instance Ord ByteString where
    compare = compareBytes

instance Semigroup ByteString where
    (<>)    = append
    sconcat (b:|bs) = concat (b:bs)
    stimes  = times

instance Monoid ByteString where
    mempty  = empty
    mappend = (<>)
    mconcat = concat

instance NFData ByteString where
    rnf BS{} = ()

instance Show ByteString where
    showsPrec p ps r = showsPrec p (unpackChars ps) r

instance Read ByteString where
    readsPrec p str = [ (packChars x, y) | (x, y) <- readsPrec p str ]

-- | @since 0.10.12.0
instance IsList ByteString where
  type Item ByteString = Word8
  fromList = packBytes
  toList   = unpackBytes

-- | Beware: 'fromString' truncates multi-byte characters to octets.
-- e.g. "枯朶に烏のとまりけり秋の暮" becomes �6k�nh~�Q��n�
instance IsString ByteString where
    {-# INLINE fromString #-}
    fromString = packChars

instance Data ByteString where
  gfoldl f z txt = z packBytes `f` unpackBytes txt
  toConstr _     = error "Data.ByteString.ByteString.toConstr"
  gunfold _ _    = error "Data.ByteString.ByteString.gunfold"
  dataTypeOf _   = mkNoRepType "Data.ByteString.ByteString"

-- | @since 0.11.2.0
instance TH.Lift ByteString where
#if MIN_VERSION_template_haskell(2,16,0)
  lift (BS ptr len) = [| unsafePackLenLiteral |]
    `TH.appE` TH.litE (TH.integerL (fromIntegral len))
    `TH.appE` TH.litE (TH.BytesPrimL $ TH.Bytes ptr 0 (fromIntegral len))
#else
  lift bs@(BS _ len) = [| unsafePackLenLiteral |]
    `TH.appE` TH.litE (TH.integerL (fromIntegral len))
    `TH.appE` TH.litE (TH.StringPrimL $ unpackBytes bs)
#endif

#if MIN_VERSION_template_haskell(2,17,0)
  liftTyped = TH.unsafeCodeCoerce . TH.lift
#elif MIN_VERSION_template_haskell(2,16,0)
  liftTyped = TH.unsafeTExpCoerce . TH.lift
#endif

------------------------------------------------------------------------
-- Internal indexing

-- | 'findIndexOrLength' is a variant of findIndex, that returns the length
-- of the string if no element is found, rather than Nothing.
findIndexOrLength :: (Word8 -> Bool) -> ByteString -> Int
findIndexOrLength k (BS x l) =
    accursedUnutterablePerformIO $ g x
  where
    g ptr = go 0
      where
        go !n | n >= l    = return l
              | otherwise = do w <- peekFp $ ptr `plusForeignPtr` n
                               if k w
                                 then return n
                                 else go (n+1)
{-# INLINE findIndexOrLength #-}

------------------------------------------------------------------------
-- Packing and unpacking from lists

packBytes :: [Word8] -> ByteString
packBytes ws = unsafePackLenBytes (List.length ws) ws

packChars :: [Char] -> ByteString
packChars cs = unsafePackLenChars (List.length cs) cs

{-# INLINE [0] packChars #-}

{-# RULES
"ByteString packChars/packAddress" forall s .
   packChars (unpackCString# s) = unsafePackLiteral s
 #-}

unsafePackLenBytes :: Int -> [Word8] -> ByteString
unsafePackLenBytes len xs0 =
    unsafeCreateFp len $ \p -> go p xs0
  where
    go !_ []     = return ()
    go !p (x:xs) = pokeFp p x >> go (p `plusForeignPtr` 1) xs

unsafePackLenChars :: Int -> [Char] -> ByteString
unsafePackLenChars len cs0 =
    unsafeCreateFp len $ \p -> go p cs0
  where
    go !_ []     = return ()
    go !p (c:cs) = pokeFp p (c2w c) >> go (p `plusForeignPtr` 1) cs


-- | /O(n)/ Pack a null-terminated sequence of bytes, pointed to by an
-- Addr\# (an arbitrary machine address assumed to point outside the
-- garbage-collected heap) into a @ByteString@. A much faster way to
-- create an 'Addr#' is with an unboxed string literal, than to pack a
-- boxed string. A unboxed string literal is compiled to a static @char
-- []@ by GHC. Establishing the length of the string requires a call to
-- @strlen(3)@, so the 'Addr#' must point to a null-terminated buffer (as
-- is the case with @\"string\"\#@ literals in GHC). Use 'Data.ByteString.Unsafe.unsafePackAddressLen'
-- if you know the length of the string statically.
--
-- An example:
--
-- > literalFS = unsafePackAddress "literal"#
--
-- This function is /unsafe/. If you modify the buffer pointed to by the
-- original 'Addr#' this modification will be reflected in the resulting
-- @ByteString@, breaking referential transparency.
--
-- Note this also won't work if your 'Addr#' has embedded @\'\\0\'@ characters in
-- the string, as @strlen@ will return too short a length.
--
unsafePackAddress :: Addr# -> IO ByteString
unsafePackAddress addr# = do
#if __GLASGOW_HASKELL__ >= 811
    unsafePackLenAddress (I# (cstringLength# addr#)) addr#
#else
    l <- c_strlen (Ptr addr#)
    unsafePackLenAddress (fromIntegral l) addr#
#endif
{-# INLINE unsafePackAddress #-}

-- | See 'unsafePackAddress'. This function is similar,
-- but takes an additional length argument rather then computing
-- it with @strlen@.
-- Therefore embedding @\'\\0\'@ characters is possible.
--
-- @since 0.11.2.0
unsafePackLenAddress :: Int -> Addr# -> IO ByteString
unsafePackLenAddress len addr# = do
#if __GLASGOW_HASKELL__ >= 811
    return (BS (ForeignPtr addr# FinalPtr) len)
#else
    p <- newForeignPtr_ (Ptr addr#)
    return $ BS p len
#endif
{-# INLINE unsafePackLenAddress #-}

-- | See 'unsafePackAddress'. This function has similar behavior. Prefer
-- this function when the address in known to be an @Addr#@ literal. In
-- that context, there is no need for the sequencing guarantees that 'IO'
-- provides. On GHC 9.0 and up, this function uses the @FinalPtr@ data
-- constructor for @ForeignPtrContents@.
--
-- @since 0.11.1.0
unsafePackLiteral :: Addr# -> ByteString
unsafePackLiteral addr# =
#if __GLASGOW_HASKELL__ >= 811
  unsafePackLenLiteral (I# (cstringLength# addr#)) addr#
#else
  let len = accursedUnutterablePerformIO (c_strlen (Ptr addr#))
   in unsafePackLenLiteral (fromIntegral len) addr#
#endif
{-# INLINE unsafePackLiteral #-}


-- | See 'unsafePackLiteral'. This function is similar,
-- but takes an additional length argument rather then computing
-- it with @strlen@.
-- Therefore embedding @\'\\0\'@ characters is possible.
--
-- @since 0.11.2.0
unsafePackLenLiteral :: Int -> Addr# -> ByteString
unsafePackLenLiteral len addr# =
#if __GLASGOW_HASKELL__ >= 811
  BS (ForeignPtr addr# FinalPtr) len
#else
  -- newForeignPtr_ allocates a MutVar# internally. If that MutVar#
  -- gets commoned up with the MutVar# of some unrelated ForeignPtr,
  -- it may prevent automatic finalization for that other ForeignPtr.
  -- So we avoid accursedUnutterablePerformIO here.
  BS (unsafeDupablePerformIO (newForeignPtr_ (Ptr addr#))) len
#endif
{-# INLINE unsafePackLenLiteral #-}

packUptoLenBytes :: Int -> [Word8] -> (ByteString, [Word8])
packUptoLenBytes len xs0 =
    unsafeCreateFpUptoN' len $ \p0 ->
      let p_end = plusForeignPtr p0 len
          go !p []              = return (p `minusForeignPtr` p0, [])
          go !p xs | p == p_end = return (len, xs)
          go !p (x:xs)          = pokeFp p x >> go (p `plusForeignPtr` 1) xs
      in go p0 xs0

packUptoLenChars :: Int -> [Char] -> (ByteString, [Char])
packUptoLenChars len cs0 =
    unsafeCreateFpUptoN' len $ \p0 ->
      let p_end = plusForeignPtr p0 len
          go !p []              = return (p `minusForeignPtr` p0, [])
          go !p cs | p == p_end = return (len, cs)
          go !p (c:cs)          = pokeFp p (c2w c) >> go (p `plusForeignPtr` 1) cs
      in go p0 cs0

-- Unpacking bytestrings into lists efficiently is a tradeoff: on the one hand
-- we would like to write a tight loop that just blasts the list into memory, on
-- the other hand we want it to be unpacked lazily so we don't end up with a
-- massive list data structure in memory.
--
-- Our strategy is to combine both: we will unpack lazily in reasonable sized
-- chunks, where each chunk is unpacked strictly.
--
-- unpackBytes and unpackChars do the lazy loop, while unpackAppendBytes and
-- unpackAppendChars do the chunks strictly.

unpackBytes :: ByteString -> [Word8]
unpackBytes bs = unpackAppendBytesLazy bs []

unpackChars :: ByteString -> [Char]
unpackChars bs = unpackAppendCharsLazy bs []

unpackAppendBytesLazy :: ByteString -> [Word8] -> [Word8]
unpackAppendBytesLazy (BS fp len) xs
  | len <= 100 = unpackAppendBytesStrict (BS fp len) xs
  | otherwise  = unpackAppendBytesStrict (BS fp 100) remainder
  where
    remainder  = unpackAppendBytesLazy (BS (plusForeignPtr fp 100) (len-100)) xs

  -- Why 100 bytes you ask? Because on a 64bit machine the list we allocate
  -- takes just shy of 4k which seems like a reasonable amount.
  -- (5 words per list element, 8 bytes per word, 100 elements = 4000 bytes)

unpackAppendCharsLazy :: ByteString -> [Char] -> [Char]
unpackAppendCharsLazy (BS fp len) cs
  | len <= 100 = unpackAppendCharsStrict (BS fp len) cs
  | otherwise  = unpackAppendCharsStrict (BS fp 100) remainder
  where
    remainder  = unpackAppendCharsLazy (BS (plusForeignPtr fp 100) (len-100)) cs

-- For these unpack functions, since we're unpacking the whole list strictly we
-- build up the result list in an accumulator. This means we have to build up
-- the list starting at the end. So our traversal starts at the end of the
-- buffer and loops down until we hit the sentinal:

unpackAppendBytesStrict :: ByteString -> [Word8] -> [Word8]
unpackAppendBytesStrict (BS fp len) xs =
    accursedUnutterablePerformIO $ unsafeWithForeignPtr fp $ \base ->
      loop (base `plusPtr` (-1)) (base `plusPtr` (-1+len)) xs
  where
    loop !sentinal !p acc
      | p == sentinal = return acc
      | otherwise     = do x <- peek p
                           loop sentinal (p `plusPtr` (-1)) (x:acc)

unpackAppendCharsStrict :: ByteString -> [Char] -> [Char]
unpackAppendCharsStrict (BS fp len) xs =
    accursedUnutterablePerformIO $ unsafeWithForeignPtr fp $ \base ->
      loop (base `plusPtr` (-1)) (base `plusPtr` (-1+len)) xs
  where
    loop !sentinal !p acc
      | p == sentinal = return acc
      | otherwise     = do x <- peek p
                           loop sentinal (p `plusPtr` (-1)) (w2c x:acc)

------------------------------------------------------------------------

-- | The 0 pointer. Used to indicate the empty Bytestring.
nullForeignPtr :: ForeignPtr Word8
#if __GLASGOW_HASKELL__ >= 811
nullForeignPtr = ForeignPtr nullAddr# FinalPtr
#else
nullForeignPtr = ForeignPtr nullAddr# (error "nullForeignPtr")
#endif

-- ---------------------------------------------------------------------
-- Low level constructors

-- | /O(1)/ Build a ByteString from a ForeignPtr.
--
-- If you do not need the offset parameter then you should be using
-- 'Data.ByteString.Unsafe.unsafePackCStringLen' or
-- 'Data.ByteString.Unsafe.unsafePackCStringFinalizer' instead.
--
fromForeignPtr :: ForeignPtr Word8
               -> Int -- ^ Offset
               -> Int -- ^ Length
               -> ByteString
fromForeignPtr fp o = BS (plusForeignPtr fp o)
{-# INLINE fromForeignPtr #-}

-- | @since 0.11.0.0
fromForeignPtr0 :: ForeignPtr Word8
                -> Int -- ^ Length
                -> ByteString
fromForeignPtr0 = BS
{-# INLINE fromForeignPtr0 #-}

-- | /O(1)/ Deconstruct a ForeignPtr from a ByteString
toForeignPtr :: ByteString -> (ForeignPtr Word8, Int, Int) -- ^ (ptr, offset, length)
toForeignPtr (BS ps l) = (ps, 0, l)
{-# INLINE toForeignPtr #-}

-- | /O(1)/ Deconstruct a ForeignPtr from a ByteString
--
-- @since 0.11.0.0
toForeignPtr0 :: ByteString -> (ForeignPtr Word8, Int) -- ^ (ptr, length)
toForeignPtr0 (BS ps l) = (ps, l)
{-# INLINE toForeignPtr0 #-}

-- | A way of creating ByteStrings outside the IO monad. The @Int@
-- argument gives the final size of the ByteString.
unsafeCreateFp :: Int -> (ForeignPtr Word8 -> IO ()) -> ByteString
unsafeCreateFp l f = unsafeDupablePerformIO (createFp l f)
{-# INLINE unsafeCreateFp #-}

-- | Like 'unsafeCreateFp' but instead of giving the final size of the
-- ByteString, it is just an upper bound. The inner action returns
-- the actual size. Unlike 'createFpAndTrim' the ByteString is not
-- reallocated if the final size is less than the estimated size.
unsafeCreateFpUptoN :: Int -> (ForeignPtr Word8 -> IO Int) -> ByteString
unsafeCreateFpUptoN l f = unsafeDupablePerformIO (createFpUptoN l f)
{-# INLINE unsafeCreateFpUptoN #-}

unsafeCreateFpUptoN'
  :: Int -> (ForeignPtr Word8 -> IO (Int, a)) -> (ByteString, a)
unsafeCreateFpUptoN' l f = unsafeDupablePerformIO (createFpUptoN' l f)
{-# INLINE unsafeCreateFpUptoN' #-}

-- | Create ByteString of size @l@ and use action @f@ to fill its contents.
createFp :: Int -> (ForeignPtr Word8 -> IO ()) -> IO ByteString
createFp l action = do
    fp <- mallocByteString l
    action fp
    mkDeferredByteString fp l
{-# INLINE createFp #-}

-- | Given a maximum size @l@ and an action @f@ that fills the 'ByteString'
-- starting at the given 'Ptr' and returns the actual utilized length,
-- @`createFpUptoN'` l f@ returns the filled 'ByteString'.
createFpUptoN :: Int -> (ForeignPtr Word8 -> IO Int) -> IO ByteString
createFpUptoN l action = do
    fp <- mallocByteString l
    l' <- action fp
    assert (l' <= l) $ mkDeferredByteString fp l'
{-# INLINE createFpUptoN #-}

-- | Like 'createFpUptoN', but also returns an additional value created by the
-- action.
createFpUptoN' :: Int -> (ForeignPtr Word8 -> IO (Int, a)) -> IO (ByteString, a)
createFpUptoN' l action = do
    fp <- mallocByteString l
    (l', res) <- action fp
    bs <- mkDeferredByteString fp l'
    assert (l' <= l) $ pure (bs, res)
{-# INLINE createFpUptoN' #-}

-- | Given the maximum size needed and a function to make the contents
-- of a ByteString, createFpAndTrim makes the 'ByteString'. The generating
-- function is required to return the actual final size (<= the maximum
-- size), and the resulting byte array is reallocated to this size.
--
-- createFpAndTrim is the main mechanism for creating custom, efficient
-- ByteString functions, using Haskell or C functions to fill the space.
--
createFpAndTrim :: Int -> (ForeignPtr Word8 -> IO Int) -> IO ByteString
createFpAndTrim l action = do
    fp <- mallocByteString l
    l' <- action fp
    if assert (0 <= l' && l' <= l) $ l' >= l
        then mkDeferredByteString fp l
        else createFp l' $ \dest -> memcpyFp dest fp l'
{-# INLINE createFpAndTrim #-}

createFpAndTrim' :: Int -> (ForeignPtr Word8 -> IO (Int, Int, a)) -> IO (ByteString, a)
createFpAndTrim' l action = do
    fp <- mallocByteString l
    (off, l', res) <- action fp
    bs <- if assert (0 <= l' && l' <= l) $ l' >= l
        then mkDeferredByteString fp l -- entire buffer used => offset is zero
        else createFp l' $ \dest ->
               memcpyFp dest (fp `plusForeignPtr` off) l'
    return (bs, res)
{-# INLINE createFpAndTrim' #-}


wrapAction :: (Ptr Word8 -> IO res) -> ForeignPtr Word8 -> IO res
wrapAction = flip withForeignPtr
  -- Cannot use unsafeWithForeignPtr, because action can diverge

-- | A way of creating ByteStrings outside the IO monad. The @Int@
-- argument gives the final size of the ByteString.
unsafeCreate :: Int -> (Ptr Word8 -> IO ()) -> ByteString
unsafeCreate l f = unsafeCreateFp l (wrapAction f)
{-# INLINE unsafeCreate #-}

-- | Like 'unsafeCreate' but instead of giving the final size of the
-- ByteString, it is just an upper bound. The inner action returns
-- the actual size. Unlike 'createAndTrim' the ByteString is not
-- reallocated if the final size is less than the estimated size.
unsafeCreateUptoN :: Int -> (Ptr Word8 -> IO Int) -> ByteString
unsafeCreateUptoN l f = unsafeCreateFpUptoN l (wrapAction f)
{-# INLINE unsafeCreateUptoN #-}

-- | @since 0.10.12.0
unsafeCreateUptoN' :: Int -> (Ptr Word8 -> IO (Int, a)) -> (ByteString, a)
unsafeCreateUptoN' l f = unsafeCreateFpUptoN' l (wrapAction f)
{-# INLINE unsafeCreateUptoN' #-}

-- | Create ByteString of size @l@ and use action @f@ to fill its contents.
create :: Int -> (Ptr Word8 -> IO ()) -> IO ByteString
create l action = createFp l (wrapAction action)
{-# INLINE create #-}

-- | Given a maximum size @l@ and an action @f@ that fills the 'ByteString'
-- starting at the given 'Ptr' and returns the actual utilized length,
-- @`createUptoN'` l f@ returns the filled 'ByteString'.
createUptoN :: Int -> (Ptr Word8 -> IO Int) -> IO ByteString
createUptoN l action = createFpUptoN l (wrapAction action)
{-# INLINE createUptoN #-}

-- | Like 'createUptoN', but also returns an additional value created by the
-- action.
--
-- @since 0.10.12.0
createUptoN' :: Int -> (Ptr Word8 -> IO (Int, a)) -> IO (ByteString, a)
createUptoN' l action = createFpUptoN' l (wrapAction action)
{-# INLINE createUptoN' #-}

-- | Given the maximum size needed and a function to make the contents
-- of a ByteString, createAndTrim makes the 'ByteString'. The generating
-- function is required to return the actual final size (<= the maximum
-- size), and the resulting byte array is reallocated to this size.
--
-- createAndTrim is the main mechanism for creating custom, efficient
-- ByteString functions, using Haskell or C functions to fill the space.
--
createAndTrim :: Int -> (Ptr Word8 -> IO Int) -> IO ByteString
createAndTrim l action = createFpAndTrim l (wrapAction action)
{-# INLINE createAndTrim #-}

createAndTrim' :: Int -> (Ptr Word8 -> IO (Int, Int, a)) -> IO (ByteString, a)
createAndTrim' l action = createFpAndTrim' l (wrapAction action)
{-# INLINE createAndTrim' #-}


-- | Wrapper of 'Foreign.ForeignPtr.mallocForeignPtrBytes' with faster implementation for GHC
--
mallocByteString :: Int -> IO (ForeignPtr a)
mallocByteString = mallocPlainForeignPtrBytes
{-# INLINE mallocByteString #-}

------------------------------------------------------------------------
-- Implementations for Eq, Ord and Monoid instances

eq :: ByteString -> ByteString -> Bool
eq a@(BS fp len) b@(BS fp' len')
  | len /= len' = False    -- short cut on length
  | fp == fp'   = True     -- short cut for the same string
  | otherwise   = compareBytes a b == EQ
{-# INLINE eq #-}
-- ^ still needed

compareBytes :: ByteString -> ByteString -> Ordering
compareBytes (BS _   0)    (BS _   0)    = EQ  -- short cut for empty strings
compareBytes (BS fp1 len1) (BS fp2 len2) =
    accursedUnutterablePerformIO $
      unsafeWithForeignPtr fp1 $ \p1 ->
      unsafeWithForeignPtr fp2 $ \p2 -> do
        i <- memcmp p1 p2 (min len1 len2)
        return $! case i `compare` 0 of
                    EQ  -> len1 `compare` len2
                    x   -> x


-- | /O(1)/ The empty 'ByteString'
empty :: ByteString
-- This enables bypassing #457 by not using (polymorphic) mempty in
-- any definitions used by the (Monoid ByteString) instance
empty = BS nullForeignPtr 0

append :: ByteString -> ByteString -> ByteString
append (BS _   0)    b                  = b
append a             (BS _   0)    = a
append (BS fp1 len1) (BS fp2 len2) =
    unsafeCreateFp (len1+len2) $ \destptr1 -> do
      let destptr2 = destptr1 `plusForeignPtr` len1
      memcpyFp destptr1 fp1 len1
      memcpyFp destptr2 fp2 len2

concat :: [ByteString] -> ByteString
concat = \bss0 -> goLen0 bss0 bss0
    -- The idea here is we first do a pass over the input list to determine:
    --
    --  1. is a copy necessary? e.g. @concat []@, @concat [mempty, "hello"]@,
    --     and @concat ["hello", mempty, mempty]@ can all be handled without
    --     copying.
    --  2. if a copy is necessary, how large is the result going to be?
    --
    -- If a copy is necessary then we create a buffer of the appropriate size
    -- and do another pass over the input list, copying the chunks into the
    -- buffer. Also, since foreign calls aren't entirely free we skip over
    -- empty chunks while copying.
    --
    -- We pass the original [ByteString] (bss0) through as an argument through
    -- goLen0, goLen1, and goLen since we will need it again in goCopy. Passing
    -- it as an explicit argument avoids capturing it in these functions'
    -- closures which would result in unnecessary closure allocation.
  where
    -- It's still possible that the result is empty
    goLen0 _    []                     = empty
    goLen0 bss0 (BS _ 0     :bss)    = goLen0 bss0 bss
    goLen0 bss0 (bs           :bss)    = goLen1 bss0 bs bss

    -- It's still possible that the result is a single chunk
    goLen1 _    bs []                  = bs
    goLen1 bss0 bs (BS _ 0  :bss)    = goLen1 bss0 bs bss
    goLen1 bss0 bs (BS _ len:bss)    = goLen bss0 (checkedAdd "concat" len' len) bss
      where BS _ len' = bs

    -- General case, just find the total length we'll need
    goLen bss0 !total (BS _ len:bss) = goLen bss0 total' bss
      where total' = checkedAdd "concat" total len
    goLen bss0 total [] =
      unsafeCreateFp total $ \ptr -> goCopy bss0 ptr

    -- Copy the data
    goCopy []                  !_   = return ()
    goCopy (BS _  0  :bss) !ptr = goCopy bss ptr
    goCopy (BS fp len:bss) !ptr = do
      memcpyFp ptr fp len
      goCopy bss (ptr `plusForeignPtr` len)
{-# NOINLINE concat #-}

{-# RULES
"ByteString concat [] -> empty"
   concat [] = empty
"ByteString concat [bs] -> bs" forall x.
   concat [x] = x
 #-}

-- | /O(log n)/ Repeats the given ByteString n times.
times :: Integral a => a -> ByteString -> ByteString
times n (BS fp len)
  | n < 0 = error "stimes: non-negative multiplier expected"
  | n == 0 = empty
  | n == 1 = BS fp len
  | len == 0 = empty
  | len == 1 = unsafeCreateFp size $ \destfptr -> do
      byte <- peekFp fp
      unsafeWithForeignPtr destfptr $ \destptr ->
        fillBytes destptr byte n
  | otherwise = unsafeCreateFp size $ \destptr -> do
      memcpyFp destptr fp len
      fillFrom destptr len
  where
    size = len * fromIntegral n

    fillFrom :: ForeignPtr Word8 -> Int -> IO ()
    fillFrom destptr copied
      | 2 * copied <= size = do
        memcpyFp (destptr `plusForeignPtr` copied) destptr copied
        fillFrom destptr (copied * 2)
      | otherwise = memcpyFp (destptr `plusForeignPtr` copied) destptr (size - copied)

-- | Add two non-negative numbers. Errors out on overflow.                                   ...
checkedAdd :: String -> Int -> Int -> Int
checkedAdd fun x y
  | r >= 0    = r
  | otherwise = overflowError fun
  where r = x + y
{-# INLINE checkedAdd #-}

------------------------------------------------------------------------

-- | Conversion between 'Word8' and 'Char'. Should compile to a no-op.
w2c :: Word8 -> Char
w2c = unsafeChr . fromIntegral
{-# INLINE w2c #-}

-- | Unsafe conversion between 'Char' and 'Word8'. This is a no-op and
-- silently truncates to 8 bits Chars > '\255'. It is provided as
-- convenience for ByteString construction.
c2w :: Char -> Word8
c2w = fromIntegral . ord
{-# INLINE c2w #-}

-- | Selects words corresponding to white-space characters in the Latin-1 range
isSpaceWord8 :: Word8 -> Bool
isSpaceWord8 w8 =
    -- Avoid the cost of narrowing arithmetic results to Word8,
    -- the conversion from Word8 to Word is free.
    let w :: Word
        !w = fromIntegral w8
     in w .&. 0x50 == 0    -- Quick non-whitespace filter
        && w - 0x21 > 0x7e -- Second non-whitespace filter
        && ( w == 0x20     -- SP
          || w == 0xa0     -- NBSP
          || w - 0x09 < 5) -- HT, NL, VT, FF, CR
{-# INLINE isSpaceWord8 #-}

-- | Selects white-space characters in the Latin-1 range
isSpaceChar8 :: Char -> Bool
isSpaceChar8 = isSpaceWord8 . c2w
{-# INLINE isSpaceChar8 #-}

overflowError :: String -> a
overflowError fun = error $ "Data.ByteString." ++ fun ++ ": size overflow"

------------------------------------------------------------------------

-- | This \"function\" has a superficial similarity to 'System.IO.Unsafe.unsafePerformIO' but
-- it is in fact a malevolent agent of chaos. It unpicks the seams of reality
-- (and the 'IO' monad) so that the normal rules no longer apply. It lulls you
-- into thinking it is reasonable, but when you are not looking it stabs you
-- in the back and aliases all of your mutable buffers. The carcass of many a
-- seasoned Haskell programmer lie strewn at its feet.
--
-- Witness the trail of destruction:
--
-- * <https://github.com/haskell/bytestring/commit/71c4b438c675aa360c79d79acc9a491e7bbc26e7>
--
-- * <https://github.com/haskell/bytestring/commit/210c656390ae617d9ee3b8bcff5c88dd17cef8da>
--
-- * <https://github.com/haskell/aeson/commit/720b857e2e0acf2edc4f5512f2b217a89449a89d>
--
-- * <https://ghc.haskell.org/trac/ghc/ticket/3486>
--
-- * <https://ghc.haskell.org/trac/ghc/ticket/3487>
--
-- * <https://ghc.haskell.org/trac/ghc/ticket/7270>
--
-- * <https://gitlab.haskell.org/ghc/ghc/-/issues/22204>
--
-- Do not talk about \"safe\"! You do not know what is safe!
--
-- Yield not to its blasphemous call! Flee traveller! Flee or you will be
-- corrupted and devoured!
--
{-# INLINE accursedUnutterablePerformIO #-}
accursedUnutterablePerformIO :: IO a -> a
accursedUnutterablePerformIO (IO m) = case m realWorld# of (# _, r #) -> r

-- ---------------------------------------------------------------------
--
-- Standard C functions
--

foreign import ccall unsafe "string.h strlen" c_strlen
    :: CString -> IO CSize

foreign import ccall unsafe "static stdlib.h &free" c_free_finalizer
    :: FunPtr (Ptr Word8 -> IO ())

foreign import ccall unsafe "string.h memchr" c_memchr
    :: Ptr Word8 -> CInt -> CSize -> IO (Ptr Word8)

memchr :: Ptr Word8 -> Word8 -> CSize -> IO (Ptr Word8)
memchr p w sz = c_memchr p (fromIntegral w) sz

foreign import ccall unsafe "string.h memcmp" c_memcmp
    :: Ptr Word8 -> Ptr Word8 -> CSize -> IO CInt

memcmp :: Ptr Word8 -> Ptr Word8 -> Int -> IO CInt
memcmp p q s = c_memcmp p q (fromIntegral s)

{-# DEPRECATED memcpy "Use Foreign.Marshal.Utils.copyBytes instead" #-}
-- | deprecated since @bytestring-0.11.5.0@
memcpy :: Ptr Word8 -> Ptr Word8 -> Int -> IO ()
memcpy = copyBytes

memcpyFp :: ForeignPtr Word8 -> ForeignPtr Word8 -> Int -> IO ()
memcpyFp fp fq s = unsafeWithForeignPtr fp $ \p ->
                     unsafeWithForeignPtr fq $ \q -> copyBytes p q s

foreign import ccall unsafe "string.h memset" c_memset
    :: Ptr Word8 -> CInt -> CSize -> IO (Ptr Word8)

{-# DEPRECATED memset "Use Foreign.Marshal.Utils.fillBytes instead" #-}
-- | deprecated since @bytestring-0.11.5.0@
memset :: Ptr Word8 -> Word8 -> CSize -> IO (Ptr Word8)
memset p w sz = c_memset p (fromIntegral w) sz

-- ---------------------------------------------------------------------
--
-- Uses our C code
--

foreign import ccall unsafe "static fpstring.h fps_reverse" c_reverse
    :: Ptr Word8 -> Ptr Word8 -> CSize -> IO ()

foreign import ccall unsafe "static fpstring.h fps_intersperse" c_intersperse
    :: Ptr Word8 -> Ptr Word8 -> CSize -> Word8 -> IO ()

foreign import ccall unsafe "static fpstring.h fps_maximum" c_maximum
    :: Ptr Word8 -> CSize -> IO Word8

foreign import ccall unsafe "static fpstring.h fps_minimum" c_minimum
    :: Ptr Word8 -> CSize -> IO Word8

foreign import ccall unsafe "static fpstring.h fps_count" c_count
    :: Ptr Word8 -> CSize -> Word8 -> IO CSize

foreign import ccall unsafe "static fpstring.h fps_sort" c_sort
    :: Ptr Word8 -> CSize -> IO ()
