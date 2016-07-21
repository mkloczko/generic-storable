{-#LANGUAGE DeriveGeneric#-}
{-#LANGUAGE FlexibleInstances #-}
{-#LANGUAGE FlexibleContexts #-}
{-#LANGUAGE DefaultSignatures #-}
{-#LANGUAGE TypeOperators #-}
{-#LANGUAGE ScopedTypeVariables #-}
{-#LANGUAGE UndecidableInstances #-}

module Foreign.Storable.Generic.Internal where

import GHC.Generics
import Foreign.Ptr
import Foreign.Storable
import Foreign.Marshal.Alloc
import Foreign.C.Types

import Data.Int

import Debug.Trace

import Foreign.Storable.Generic.Tools

-- Defining the generics ---

class GStorable' f where
    -- | Read the element at a given offset. Additional information about the offests 
    -- of the subfields are needed.
    gpeekByteOff' :: [Int]    -- ^ List of fields' offsets for the type/struct. 
                  -> Ptr b    -- ^ The pointer to the type/struct.
                  -> Int      -- ^ Global offset.
                  -> IO (f a) -- ^ The result, wrapped in GHC.Generic metadata.
    -- | Write the element at a given offset. Additional information about the offests 
    -- of the subfields are needed.
    gpokeByteOff' :: [Int]  -- ^ List of fields' offsets for the type/struct.
                  -> Ptr b  -- ^ The pointer to the type/struct.
                  -> Int    -- ^ Global offset.
                  -> (f a)  -- ^ The element to write, wrapped in GHC.Generic metadata.
                  -> IO ()

    -- | Calculates the number of type's/struct's fields.
    gnumberOf' :: f a -- ^ GHC.Generic information about a given type/struct.
               -> Int -- ^ Size.

    -- | Calculates the sizes of type's/struct's fields.
    glistSizeOf' :: f a   -- ^ GHC.Generic information about a given type/struct. 
                 -> [Int] -- ^ List of sizes.

    -- | Calculates the alignments of type's/struct's fields.
    glistAlignment' :: f a   -- ^ GHC.Generic information about a given type/struct.
                    -> [Int] -- ^ List of alignments.


instance (GStorable' f) => GStorable' (M1 i t f) where
    -- Wrap the peeked value in metadata.
    gpeekByteOff' offsets ptr offset = M1 <$> gpeekByteOff' offsets ptr offset
    -- Discard the metadata and go further.
    gpokeByteOff' offsets ptr offset (M1 x) = gpokeByteOff' offsets ptr offset x 
    

    gnumberOf' (M1 v) = gnumberOf' v
    glistSizeOf' _ = glistSizeOf' (undefined :: f p)
    glistAlignment' _ = glistAlignment' (undefined :: f p)

------------------------------------------
--   The important part of the code!    --
------------------------------------------

instance (GStorable' f, GStorable' g) => GStorable' (f :*: g) where
    -- Tree-like traversal for reading the type.
    gpeekByteOff' offsets ptr offset = if is_ok then (:*:) <$> peeker offs1 <*>  peeker offs2 else error_action
        where n1 = gnumberOf' (undefined :: f a)               -- Number of elements for the left part of the tree.
              n2 = gnumberOf' (undefined :: g a)               -- Number of elements for the right part of the tree
              is_ok = n1+n2 == length offsets                  -- Check if offset number is the same as the number of subelements.
              error_action = error "Foreign.Storable.Generic.Internal.gpeekByteOff': Mismatch between number of fields and number of offsets"
              (offs1,offs2) = splitAt n1 offsets               -- Offsets for the left and right part of the tree.
              peeker offs = gpeekByteOff' offs ptr offset      -- gpeekByteOff' wrapped to peek into subtrees.
    -- Tree like traversal for writing the type.
    gpokeByteOff' offsets ptr offset (x :*: y) = if is_ok then peeker offs1 x >> peeker offs2 y else error_action
        where n1 = gnumberOf' (undefined :: f a)               -- Number of elements for the left part of the tree.
              n2 = gnumberOf' (undefined :: g a)               -- Number of elements for the right part of the tree.
              is_ok = n1+n2 == length offsets                  -- Check if offset number is the same as the number of subelements.
              error_action = error "Foreign.Storable.Generic.Internal.gpokeByteOff': Mismatch between number of fields and number of offsets"
              (offs1,offs2) = splitAt n1 offsets               -- Offsets for the left and right part of the tree.
              peeker offs z = gpokeByteOff' offs ptr offset z  -- gpokeByteOff' wrapped to peek into the subtree




    gnumberOf' _ = gnumberOf' (undefined :: f a) + gnumberOf' (undefined :: g a)
    -- Concatenate the lists. 
    glistSizeOf' _ = glistSizeOf' (undefined :: f a) ++ glistSizeOf' (undefined :: g a)
    -- Concatenate the lists.
    glistAlignment' _ = glistAlignment' (undefined :: f a) ++ glistAlignment' (undefined :: g a)

instance (GStorable a) => GStorable' (K1 i a) where
    gpeekByteOff' [off1]  ptr offset = K1 <$> gpeekByteOff ptr (off1 + offset) 
    gpeekByteOff' offsets ptr offset = error "Foreign.Storable.Generic.Internal.gpeekByteOff': Incorrect number of field offsets for K1"    
    gpokeByteOff' [off1]  ptr offset (K1 x) = gpokeByteOff ptr (off1 + offset) x
    gpokeByteOff' offsets ptr offset (K1 x) = error "Foreign.Storable.Generic.Internal.gpokeByteOff': Incorrect number of field offsets for K1"


    -- When we use the contructor, just return one.
    gnumberOf' _ = 1
    -- When the constructor is used, return the size of 
    -- the constructed type in a list.
    glistSizeOf' _ = [gsizeOf (undefined :: a)]
    -- When the constructor is used, return the alignment of 
    -- the constructed type in a list.
    glistAlignment' _ = [galignment (undefined :: a)]  


-- These functions were moved outside GStorable type class.
-- They take generic representations as input.

-- | Calculates the size of generic data-type.
internalSizeOf :: forall f p. (GStorable' f)
               => f p  -- ^ Generic representation 
               -> Int  -- ^ Resulting size
internalSizeOf _  = calcSize $ (zip sizes aligns) ++ [(0 ,max_align)]
    where sizes  = glistSizeOf'    (undefined :: f p)
          aligns = glistAlignment' (undefined :: f p)
          max_align = calcAlignment aligns

-- | Calculates the alignment of generic data-type.
internalAlignment :: forall f p. (GStorable' f) 
                  => f p -- ^ Generic representation
                  -> Int -- ^ Resulting alignment
internalAlignment  _  = calcAlignment aligns
    where aligns = glistAlignment' (undefined :: f p)

-- | View the variable under a pointer, with offset.
internalPeekByteOff :: forall f p b. (GStorable' f) 
                    => Ptr b    -- ^ Pointer to peek 
                    -> Int      -- ^ Offset 
                    -> IO (f p) -- ^ Resulting generic representation
internalPeekByteOff ptr off  = gpeekByteOff' offsets ptr off
    where offsets = internalOffsets (undefined :: f p)

-- | Write the variable under the pointer, with offset.
internalPokeByteOff :: forall f p b. (GStorable' f) 
                    => Ptr b -- ^ Pointer to write to
                    -> Int   -- ^ Offset 
                    -> f p   -- ^ Written generic representation 
                    -> IO () 
internalPokeByteOff ptr off rep = gpokeByteOff' offsets ptr off rep
    where offsets = internalOffsets (undefined :: f p)

internalOffsets :: forall f p. (GStorable' f)
                => f p
                -> [Int]
internalOffsets _ = calcOffsets $ zip sizes aligns
    where sizes = glistSizeOf'    (undefined :: f p)
          aligns= glistAlignment' (undefined :: f p)
          max_align = calcAlignment aligns

-- | The class uses the default Generic based implementations to 
-- provide Storable instances for types made from primitive types.
-- Does not work on Algebraic Data Types with more than one constructor.
class GStorable a where
    -- | Calculate the size of the type.
    gsizeOf :: a   -- ^ Element of a given type. Can be undefined.
            -> Int -- ^ Size.
    default gsizeOf :: (Generic a, GStorable' (Rep a))
                    => a -> Int
    gsizeOf _ = internalSizeOf (undefined :: Rep a p) 
    
    -- | Calculate the alignment of the type.
    galignment :: a   -- ^ Element of a given type. Can be undefined  
               -> Int -- ^ Alignment.
    default galignment :: (Generic a, GStorable' (Rep a))
                         => a -> Int
    galignment _ = internalAlignment (undefined :: Rep a p) 

    -- | Read the variable from a given pointer.
    gpeekByteOff :: Ptr b -- ^ Pointer to the variable
                 -> Int   -- ^ Offset
                 -> IO a  -- ^ Returned variable.
    default gpeekByteOff :: (Generic a, GStorable' (Rep a))
                         => Ptr b -> Int -> IO a
    gpeekByteOff ptr offset = to <$> internalPeekByteOff ptr offset

-- | Write the variable to a pointer. 
    gpokeByteOff :: Ptr b -- ^ Pointer to the variable. 
                 -> Int   -- ^ Offset.
                 -> a     -- ^ The variable
                 -> IO ()
    default gpokeByteOff :: (Generic a, GStorable' (Rep a))
                         => Ptr b -> Int -> a -> IO ()
    gpokeByteOff ptr offset x = internalPokeByteOff ptr offset (from x)


