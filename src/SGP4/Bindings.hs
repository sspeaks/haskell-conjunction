module SGP4.Bindings
  ( c_sgp4c_twoline2rv
  , c_sgp4c_propagate
  , c_sgp4c_propagate_many
  , c_sgp4c_propagate_state
  , c_sgp4c_satrec_error
  , c_sgp4c_satrec_epoch_jd
  , c_sgp4c_satrec_satnum
  , newSatrec
  , withSatrec
  ) where

import Foreign.C.String (CString)
import Foreign.C.Types (CChar (..), CDouble (..), CInt (..), CSize (..))
import Foreign.ForeignPtr (ForeignPtr, newForeignPtr, withForeignPtr)
import Foreign.Marshal.Error (throwIfNull)
import Foreign.Ptr (FunPtr, Ptr)
import SGP4.Types (Satrec)

foreign import ccall unsafe "sgp4_capi.h sgp4c_satrec_alloc"
  c_sgp4c_satrec_alloc :: IO (Ptr Satrec)

foreign import ccall unsafe "sgp4_capi.h &sgp4c_satrec_free"
  c_sgp4c_satrec_free :: FunPtr (Ptr Satrec -> IO ())

foreign import ccall unsafe "sgp4_capi.h sgp4c_twoline2rv"
  c_sgp4c_twoline2rv ::
    Ptr Satrec ->
    CString ->
    CString ->
    CChar ->
    CInt ->
    Ptr CDouble ->
    Ptr CDouble ->
    Ptr CDouble ->
    IO CInt

foreign import ccall unsafe "sgp4_capi.h sgp4c_propagate"
  c_sgp4c_propagate ::
    Ptr Satrec ->
    CDouble ->
    Ptr CDouble ->
    Ptr CDouble ->
    IO CInt

foreign import ccall unsafe "sgp4_capi.h sgp4c_propagate_state"
  c_sgp4c_propagate_state ::
    Ptr Satrec ->
    CDouble ->
    Ptr CDouble ->
    IO CInt

foreign import ccall safe "sgp4_capi.h sgp4c_propagate_many"
  c_sgp4c_propagate_many ::
    Ptr Satrec ->
    Ptr CDouble ->
    CSize ->
    Ptr CDouble ->
    Ptr CDouble ->
    Ptr CInt ->
    IO CInt

foreign import ccall unsafe "sgp4_capi.h sgp4c_satrec_error"
  c_sgp4c_satrec_error :: Ptr Satrec -> IO CInt

foreign import ccall unsafe "sgp4_capi.h sgp4c_satrec_epoch_jd"
  c_sgp4c_satrec_epoch_jd :: Ptr Satrec -> Ptr CDouble -> Ptr CDouble -> IO ()

foreign import ccall unsafe "sgp4_capi.h sgp4c_satrec_satnum"
  c_sgp4c_satrec_satnum :: Ptr Satrec -> CString -> IO ()

newSatrec :: IO (ForeignPtr Satrec)
newSatrec = do
  ptr <- throwIfNull "sgp4c_satrec_alloc" c_sgp4c_satrec_alloc
  newForeignPtr c_sgp4c_satrec_free ptr

withSatrec :: ForeignPtr Satrec -> (Ptr Satrec -> IO a) -> IO a
withSatrec = withForeignPtr
