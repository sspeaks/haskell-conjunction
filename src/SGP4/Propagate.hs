{-# LANGUAGE BangPatterns #-}

module SGP4.Propagate
  ( propagate
  , propagateMany
  , propagateTLE
  , propagateTLEMany
  ) where

import Foreign.C.Types (CDouble, CInt)
import Foreign.Marshal.Array (allocaArray, withArray)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peekElemOff)
import SGP4.Bindings (c_sgp4c_propagate_many, c_sgp4c_propagate_state, withSatrec)
import SGP4.TLE (TLE, initializeFromTLE)
import SGP4.Types
  ( Satellite (Satellite)
  , Sgp4Error
  , StateVector (StateVector)
  , Vec3 (Vec3)
  , sgp4ErrorFromCode
  )
import System.IO.Unsafe (unsafePerformIO)

propagate :: Satellite -> Double -> IO (Either Sgp4Error StateVector)
propagate (Satellite satrec) tsinceMinutes =
  withSatrec satrec $ \satrecPtr ->
    allocaArray 6 $ \statePtr -> do
      code <- c_sgp4c_propagate_state satrecPtr (realToFrac tsinceMinutes) statePtr
      case sgp4ErrorFromCode (fromIntegral code) of
        Just err -> pure (Left err)
        Nothing -> do
          position <- peekVec3At statePtr 0
          velocity <- peekVec3At statePtr 3
          pure (Right (StateVector position velocity tsinceMinutes))

propagateMany :: Satellite -> [Double] -> IO [Either Sgp4Error StateVector]
propagateMany _ [] = pure []
propagateMany satellite tsinceMinutes
  | count < batchThreshold = traverse (propagate satellite) tsinceMinutes
  | otherwise = propagateManyBatched satellite tsinceMinutes
 where
  !count = length tsinceMinutes

batchThreshold :: Int
batchThreshold = 16

propagateManyBatched :: Satellite -> [Double] -> IO [Either Sgp4Error StateVector]
propagateManyBatched (Satellite satrec) tsinceMinutes =
  withSatrec satrec $ \satrecPtr ->
    withArray cTimes $ \timesPtr ->
      allocaArray outputCount $ \rPtr ->
        allocaArray outputCount $ \vPtr ->
          allocaArray count $ \errorPtr -> do
            _ <- c_sgp4c_propagate_many satrecPtr timesPtr (fromIntegral count) rPtr vPtr errorPtr
            traverse (peekState errorPtr rPtr vPtr) indexedTimes
 where
  !count = length tsinceMinutes
  !outputCount = count * 3
  cTimes = map realToFrac tsinceMinutes
  indexedTimes = zip [0 ..] tsinceMinutes

  peekState ::
    Ptr CInt ->
    Ptr CDouble ->
    Ptr CDouble ->
    (Int, Double) ->
    IO (Either Sgp4Error StateVector)
  peekState errorPtr rPtr vPtr (index, tsince) = do
    code <- fromIntegral <$> peekElemOff errorPtr index
    case sgp4ErrorFromCode code of
      Just err -> pure (Left err)
      Nothing -> do
        position <- peekVec3At rPtr (index * 3)
        velocity <- peekVec3At vPtr (index * 3)
        pure (Right (StateVector position velocity tsince))

-- The pure API is safe only because each call allocates a fresh C++ record and
-- never exposes that mutable handle to callers.
propagateTLE :: TLE -> Double -> Either Sgp4Error StateVector
propagateTLE tle tsinceMinutes =
  unsafePerformIO $ do
    initialized <- initializeFromTLE tle
    case initialized of
      Left err -> pure (Left err)
      Right satellite -> propagate satellite tsinceMinutes
{-# NOINLINE propagateTLE #-}

propagateTLEMany :: TLE -> [Double] -> Either Sgp4Error [StateVector]
propagateTLEMany tle tsinceMinutes =
  unsafePerformIO $ do
    initialized <- initializeFromTLE tle
    case initialized of
      Left err -> pure (Left err)
      Right satellite -> sequenceA <$> propagateMany satellite tsinceMinutes
{-# NOINLINE propagateTLEMany #-}

peekVec3At :: Ptr CDouble -> Int -> IO Vec3
peekVec3At ptr offset = do
  !x <- realToFrac <$> peekElemOff ptr offset
  !y <- realToFrac <$> peekElemOff ptr (offset + 1)
  !z <- realToFrac <$> peekElemOff ptr (offset + 2)
  pure (Vec3 x y z)
