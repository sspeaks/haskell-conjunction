{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | Minimal ntfy publish client.
--
-- Mirrors the @http-client@ + @http-client-tls@ usage in
-- "SpaceTrack.Client": a shared TLS 'Manager' is created once and reused for
-- every POST. Each visible conjunction is published to @<server>/<topic>@ with
-- the message as the request body and the ntfy metadata supplied as headers
-- (@Title@, @Tags@, optional @Priority@, optional @Authorization: Bearer@).
module ConjunctionNotify.Ntfy
  ( NtfyTarget (..)
  , NtfyError (..)
  , newNtfyManager
  , publish
  ) where

import Control.Exception (Exception, throwIO)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Network.HTTP.Client
  ( Manager
  , Response
  , RequestBody (RequestBodyBS)
  , httpLbs
  , method
  , parseRequest
  , requestBody
  , requestHeaders
  , responseBody
  , responseStatus
  )
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Status (statusCode)

-- | Everything needed to publish to one ntfy topic.
data NtfyTarget = NtfyTarget
  { ntServer :: !String
  -- ^ Base URL, for example @https://ntfy.sh@.
  , ntTopic :: !String
  , ntTitle :: !String
  , ntTags :: !String
  , ntPriority :: !(Maybe String)
  , ntToken :: !(Maybe String)
  -- ^ Access token sent as @Authorization: Bearer@ when present.
  }
  deriving (Eq, Show)

-- | A non-2xx response from the ntfy server.
data NtfyError = NtfyHttpError !Int !Text
  deriving (Eq, Show)

instance Exception NtfyError

-- | Create the shared TLS manager used for every publish.
newNtfyManager :: IO Manager
newNtfyManager = newTlsManager

-- | Publish a single message. Throws 'NtfyError' on a non-2xx response and
-- propagates any underlying @http-client@ exception; callers decide whether a
-- failure is fatal.
publish :: Manager -> NtfyTarget -> Text -> IO ()
publish manager NtfyTarget {..} message = do
  baseRequest <- parseRequest (publishUrl ntServer ntTopic)
  let request =
        baseRequest
          { method = "POST"
          , requestBody = RequestBodyBS (TE.encodeUtf8 message)
          , requestHeaders = headers
          }
  response <- httpLbs request manager
  let code = statusCode (responseStatus response)
  if code >= 200 && code < 300
    then pure ()
    else throwIO (NtfyHttpError code (responseText response))
 where
  headers :: [Header]
  headers =
    [ ("Title", TE.encodeUtf8 (T.pack ntTitle))
    , ("Tags", BS8.pack ntTags)
    ]
      <> maybe [] (\p -> [("Priority", BS8.pack p)]) ntPriority
      <> maybe [] (\tok -> [("Authorization", "Bearer " <> BS8.pack tok)]) ntToken

-- | Join the server base URL and topic into a publish URL, tolerating a
-- trailing slash on the server.
publishUrl :: String -> String -> String
publishUrl server topic = dropTrailingSlash server <> "/" <> topic

dropTrailingSlash :: String -> String
dropTrailingSlash s =
  case reverse s of
    '/' : rest -> reverse rest
    _ -> s

responseText :: Response LBS.ByteString -> Text
responseText = TE.decodeUtf8With TEE.lenientDecode . LBS.toStrict . responseBody
