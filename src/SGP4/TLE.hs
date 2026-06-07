module SGP4.TLE
  ( TLE (..)
  , initializeFromTLE
  , initializeFromTLEWith
  , satelliteEpoch
  , satelliteNumber
  ) where

import Foreign.C.String (castCCharToChar, withCString)
import Foreign.C.Types (CChar, CDouble)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Array (peekArray)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek)
import SGP4.Bindings
  ( c_sgp4c_satrec_epoch_jd
  , c_sgp4c_satrec_satnum
  , c_sgp4c_twoline2rv
  , newSatrec
  , withSatrec
  )
import SGP4.Types
  ( GravConst (WGS72)
  , OpsMode (AFSPC)
  , Satellite (Satellite)
  , Sgp4Error
  , gravConstToCInt
  , opsModeToCChar
  , sgp4ErrorFromCode
  )

data TLE = TLE
  { tleLine1 :: !String
  , tleLine2 :: !String
  }
  deriving (Eq, Show)

initializeFromTLE :: TLE -> IO (Either Sgp4Error Satellite)
initializeFromTLE = initializeFromTLEWith WGS72 AFSPC

initializeFromTLEWith :: GravConst -> OpsMode -> TLE -> IO (Either Sgp4Error Satellite)
initializeFromTLEWith gravConst opsMode tle = do
  satrec <- newSatrec
  result <-
    withSatrec satrec $ \satrecPtr ->
      withCString (tleLine1 tle) $ \line1Ptr ->
        withCString (tleLine2 tle) $ \line2Ptr -> do
          code <-
            c_sgp4c_twoline2rv
              satrecPtr
              line1Ptr
              line2Ptr
              (opsModeToCChar opsMode)
              (gravConstToCInt gravConst)
              nullPtr
              nullPtr
              nullPtr
          pure (sgp4ErrorFromCode (fromIntegral code))
  case result of
    Nothing -> pure (Right (Satellite satrec))
    Just err -> pure (Left err)

satelliteEpoch :: Satellite -> IO (Double, Double)
satelliteEpoch (Satellite satrec) =
  withSatrec satrec $ \satrecPtr ->
    alloca $ \jdPtr ->
      alloca $ \jdFracPtr -> do
        c_sgp4c_satrec_epoch_jd satrecPtr jdPtr jdFracPtr
        jd <- realToFrac <$> peekDouble jdPtr
        jdFrac <- realToFrac <$> peekDouble jdFracPtr
        pure (jd, jdFrac)

satelliteNumber :: Satellite -> IO String
satelliteNumber (Satellite satrec) =
  withSatrec satrec $ \satrecPtr ->
    withSixCharBuffer $ \satnumPtr -> do
      c_sgp4c_satrec_satnum satrecPtr satnumPtr
      chars <- peekArray 6 satnumPtr
      pure (takeWhile (/= '\0') (map castCCharToChar chars))

peekDouble :: Ptr CDouble -> IO CDouble
peekDouble = peek

withSixCharBuffer :: (Ptr CChar -> IO a) -> IO a
withSixCharBuffer = allocaBytes 6
